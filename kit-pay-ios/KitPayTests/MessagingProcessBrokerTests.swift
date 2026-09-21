import CryptoKit
import Darwin
import XCTest
@testable import KitPay

final class MessagingProcessBrokerTests: XCTestCase {
    private let account = "10000000-0000-4000-8000-000000000001"
    private let session = "20000000-0000-4000-8000-000000000002"
    private let recipient = "30000000-0000-4000-8000-000000000003"
    private let enrollmentKeyID = String(repeating: "a", count: 64)
    private var root: URL!
    private var guardBackend: BrokerTestGuardBackend!
    private let key = Data(repeating: 0x43, count: 32)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guardBackend = BrokerTestGuardBackend()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private var destination: SharedInboxDestination {
        SharedInboxDestination(conversationID: nil, recipientUserID: recipient,
                               displayName: "Private recipient name", kind: .contact, memberCount: nil)
    }
    private func tokens(
        _ suffix: String = "one", sessionID: String? = nil, accountID: String? = nil
    ) -> SessionTokens {
        SessionTokens(accessToken: "access-\(suffix)", refreshToken: "refresh-\(suffix)",
                      tokenType: "Bearer", accessExpiresAt: nil, refreshExpiresAt: nil,
                      sessionId: sessionID ?? session, accountId: accountID ?? account)
    }
    private func broker(
        biometrics: BrokerTestBiometrics? = nil, clock: BrokerTestClock = BrokerTestClock(),
        check: ((MessagingProcessBroker.Authority) throws -> Void)? = nil
    ) -> MessagingProcessBroker {
        MessagingProcessBroker(rootURL: root, key: key, biometrics: biometrics ?? authenticator(),
                               uptime: { clock.value }, authorityWriteCheck: check)
    }
    private func authenticator(domain: String = "main-process-domain") -> BrokerTestBiometrics {
        BrokerTestBiometrics(backend: guardBackend, processLocalDomain: Data(domain.utf8))
    }
    private func approve(
        _ broker: MessagingProcessBroker, enrollmentKeyID: String? = nil,
        confirmPrivateKey: () throws -> Void = {}
    ) throws {
        // Models the main-app boundary AFTER fresh proof using its private biometric key.
        // That proof is separate from, and never grants, a share-process authentication lease.
        let binding = try broker.biometricBinding(accountID: account, sessionID: session)
        try broker.approveBiometricSharing(
            binding: binding, enrollmentKeyID: enrollmentKeyID ?? self.enrollmentKeyID,
            confirmPrivateKey: confirmPrivateKey
        )
    }
    /// Names the refusal instead of merely asserting a throw. Build 105 collapsed six
    /// conditions into one message, which is why its report could not be acted on.
    private func assertShareRefusal(
        _ broker: MessagingProcessBroker, _ expected: ShareAuthorizationPolicy.Refusal,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await broker.authorizeShare()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual((error as? MessagingProcessBroker.Failure)?.shareRefusal, expected,
                           file: file, line: line)
        }
    }
    private func installUnapprovedBiometricAuthority(
        _ broker: MessagingProcessBroker, legacyDomain: Data? = nil
    ) throws {
        try broker.withLock { locked in
            var authority = try XCTUnwrap(locked.authorityLocked())
            authority.requiresBiometricUnlock = true
            authority.sharingEnabled = false
            authority.sharingGeneration = UUID()
            var object = try XCTUnwrap(JSONSerialization.jsonObject(
                with: JSONEncoder().encode(authority)
            ) as? [String: Any])
            // Write the old on-disk schema directly: no new encoder can accidentally migrate it.
            object.removeValue(forKey: "biometricCredential")
            if let legacyDomain { object["biometricDomainState"] = legacyDomain.base64EncodedString() }
            else { object.removeValue(forKey: "biometricDomainState") }
            let plaintext = try JSONSerialization.data(withJSONObject: object)
            let ciphertext = try XCTUnwrap(AES.GCM.seal(plaintext, using: SymmetricKey(data: key)).combined)
            try MessagingProcessBroker.durableWrite(ciphertext, to: root.appendingPathComponent("test-authority.secure"))
            let denial = try JSONSerialization.data(withJSONObject: [
                "reason": "biometric", "id": UUID().uuidString
            ])
            try MessagingProcessBroker.durableWrite(denial, to: root.appendingPathComponent("sharing.denied"))
        }
    }
    private func prepare(_ broker: MessagingProcessBroker, biometric: Bool = false) throws {
        try broker.withLock { locked in
            var authority = MessagingProcessBroker.Authority.revoked
            authority.session = tokens()
            try locked.saveAuthorityLocked(authority)
            try locked.saveRecordLocked(.init(generation: authority.generation, accountID: account, crypto: .empty))
        }
        if biometric { try approve(broker) }
        try broker.publishApprovedDestinations([destination], accountID: account, requiresBiometricUnlock: biometric)
        try broker.setSharingEnabled(true, accountID: account)
    }

    func testSeparateBrokerInstancesObserveOneCanonicalCryptoStore() throws {
        let app = broker(), share = broker()
        try prepare(app)
        let scope = try app.scope()
        let initial = try app.snapshot(scope: scope).crypto
        try share.updateOutgoing(scope: scope) { record in
            record.crypto?.syncCursor = "extension-advanced"
        }
        XCTAssertEqual(try app.snapshot(scope: scope).crypto?.syncCursor, "extension-advanced")
        XCTAssertThrowsError(try app.updateOutgoing(scope: scope) { record in
            guard record.crypto == initial else { throw MessagingProcessBroker.Failure.staleState }
            record.crypto?.syncCursor = "stale-main-overwrite"
        })
        XCTAssertEqual(try share.snapshot(scope: scope).crypto?.syncCursor, "extension-advanced")
    }

    // MARK: The 1.0.17 (105) share-sheet defect
    //
    // The owner's signed-in handset refused every share with one sentence:
    //
    //     Nothing was sent. Sharing is locked or your account changed.
    //     Unlock Kit Pay and share again. Tap Retry to check sharing access again.
    //
    // Sharing had been made a consequence of the app's *screen* lock: publication demanded a
    // `.biometryCurrentSet` Keychain credential, the share sheet demanded a process-local
    // unlock lease it could never hold, and a failure at either point wrote a hard denial that
    // also deleted the published recipients — so the only way back was the publication that
    // was failing. Biometrics are a payment control (owner directive, 2026-09-21). These cases
    // hold that line against the real broker and a real app-group directory.

    /// The reported defect, reproduced from a signed-in fixture with the app "locked", then
    /// shown to share. The extension's authenticator is handed in so the test fails if the
    /// broker so much as asks it a question.
    func testSignedInLockedAppStillShares() async throws {
        let app = broker()
        try prepare(app, biometric: true)
        try app.suspendSharingForBiometricLock(accountID: account)   // the app's UI lock
        let extensionBiometrics = authenticator(domain: "share-extension-domain")
        let share = broker(biometrics: extensionBiometrics)
        let directory = try await share.authorizeShare()
        XCTAssertEqual(directory.destinations, [destination])
        XCTAssertEqual(directory.accountID, account)
        XCTAssertEqual(extensionBiometrics.authentications, 0,
                       "the share sheet must never wait on Face ID")
        XCTAssertEqual(try share.approvedDestinations(scope: share.scope()), [destination])
    }

    /// The recipients stay encrypted at rest whether the app is locked or not: removing the
    /// lock gate removed a gate, not the encryption.
    func testPublishedRecipientsRemainEncryptedAtRest() throws {
        let app = broker()
        try prepare(app, biometric: true)
        let encrypted = try Data(contentsOf: root.appendingPathComponent("destinations.secure"))
        XCTAssertNil(encrypted.range(of: Data(destination.displayName.utf8)))
        XCTAssertNil(encrypted.range(of: Data(recipient.utf8)))
    }

    /// A handset upgrading from 105 still carries that build's wreckage: an authority that
    /// claims `requiresBiometricUnlock`, no credential to satisfy it, and a `.biometric`
    /// denial marker. It must share anyway, with no repair step the customer has to find.
    func testLegacyBuild105ContainerSharesWithoutAnyRepair() async throws {
        let app = broker()
        try prepare(app)
        try installUnapprovedBiometricAuthority(app)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("sharing.denied").path))
        let share = broker()
        let afterLegacyContainer = try await share.authorizeShare().destinations
        XCTAssertEqual(afterLegacyContainer, [destination])
    }

    /// Ordinary publication migrates the legacy fields away rather than honouring them, so the
    /// next launch is not still carrying a requirement nothing can satisfy.
    func testPublicationRetiresLegacyBiometricAuthorityFields() throws {
        let app = broker()
        try prepare(app)
        try installUnapprovedBiometricAuthority(app)
        try app.publishApprovedDestinations([destination], accountID: account,
                                            requiresBiometricUnlock: true)
        let authority = try app.withLock { try XCTUnwrap($0.authorityLocked()) }
        XCTAssertNil(authority.requiresBiometricUnlock)
        XCTAssertNil(authority.biometricCredential)
        XCTAssertNil(authority.biometricDomainState)
        XCTAssertFalse(try app.biometricSharingRequired(accountID: account, sessionID: session))
    }

    /// The app's lock observer used to write the `.biometric` denial. It now clears one, and
    /// still may not touch a real revocation.
    func testLockStateClearsALegacyBiometricDenialButNeverAHardOne() async throws {
        let app = broker()
        try prepare(app)
        try installUnapprovedBiometricAuthority(app)
        try app.suspendSharingForBiometricLock(accountID: account)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("sharing.denied").path))
        try app.setSharingEnabled(false, accountID: nil)          // a real revocation
        try app.suspendSharingForBiometricLock(accountID: account)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("sharing.denied").path))
        await assertShareRefusal(broker(), .revoked)
    }

    /// A cold launch that restores the account while the UI stays locked publishes and enables
    /// sharing like any other launch; it used to publish and then deny.
    func testLockedColdLaunchRestorePublishesAndEnablesSharing() async throws {
        let app = broker()
        try app.withLock { locked in
            var authority = MessagingProcessBroker.Authority.revoked
            authority.session = tokens()
            try locked.saveAuthorityLocked(authority)
            try locked.saveRecordLocked(.init(generation: authority.generation, accountID: account,
                                              crypto: .empty))
        }
        try app.restoreBiometricSharingDestinations([destination], accountID: account)
        let afterRestore = try await broker().authorizeShare().destinations
        XCTAssertEqual(afterRestore, [destination])
        XCTAssertTrue(try app.withLock { try XCTUnwrap($0.authorityLocked()).sharingEnabled })
    }

    /// Switching the app lock off is a settings change, not a sharing revocation. Build 105
    /// hard-denied here, which deleted the directory and left nothing able to restore it.
    func testTurningTheAppLockOffKeepsSharingAlive() async throws {
        let app = broker()
        try prepare(app, biometric: true)
        let binding = try app.biometricBinding(accountID: account, sessionID: session)
        try app.disableBiometricSharing(binding: binding)
        let afterLockOff = try await broker().authorizeShare().destinations
        XCTAssertEqual(afterLockOff, [destination])
    }

    /// A biometric approval can no longer deny anything either — but it still requires the
    /// caller's fresh private-key proof, so a rejected proof is still an error.
    func testApprovalKeepsItsProofContractAndCannotDenySharing() async throws {
        let app = broker()
        try prepare(app)
        struct ProofRejected: Error {}
        let binding = try app.biometricBinding(accountID: account, sessionID: session)
        XCTAssertThrowsError(try app.approveBiometricSharing(
            binding: binding, enrollmentKeyID: enrollmentKeyID,
            confirmPrivateKey: { throw ProofRejected() }
        ))
        let afterRejectedProof = try await broker().authorizeShare().destinations
        XCTAssertEqual(afterRejectedProof, [destination],
                       "a failed wallet proof must not take the share sheet away")
        try approve(app)
        let afterProof = try await broker().authorizeShare().destinations
        XCTAssertEqual(afterProof, [destination])
    }

    // MARK: The refusals that survive

    /// Signing out is still a revocation: the marker and the deletion of the directory happen
    /// in the same locked section.
    func testRevocationStillClosesSharingAndRemovesTheDirectory() async throws {
        let app = broker()
        try prepare(app)
        try app.setSharingEnabled(false, accountID: nil)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("destinations.secure").path))
        await assertShareRefusal(broker(), .revoked)
    }

    /// An empty container is "signed out", not "locked or your account changed".
    func testEmptyContainerRefusesAsSignedOut() async throws {
        await assertShareRefusal(broker(), .signedOut)
    }

    /// Signed in but nothing published yet: recoverable by opening the app, and said so.
    func testUnpublishedAccountRefusesAsNotPrepared() async throws {
        let app = broker()
        try app.withLock { locked in
            var authority = MessagingProcessBroker.Authority.revoked
            authority.session = tokens()
            try locked.saveAuthorityLocked(authority)
            try locked.saveRecordLocked(.init(generation: authority.generation, accountID: account,
                                              crypto: .empty))
        }
        await assertShareRefusal(broker(), .notPrepared)
    }

    /// "Account changed" now means exactly that, and only that.
    func testReplacedSessionStillFailsClosedForTheCapturedScope() throws {
        let app = broker()
        try prepare(app)
        let captured = try app.scope()
        try app.withLock { locked in
            var next = MessagingProcessBroker.Authority.revoked
            next.session = tokens("second-login", sessionID: "40000000-0000-4000-8000-000000000004")
            try locked.saveAuthorityLocked(next)
            try locked.saveRecordLocked(.init(generation: next.generation, accountID: account,
                                              crypto: .empty))
        }
        XCTAssertThrowsError(try broker().snapshot(scope: captured)) { error in
            XCTAssertEqual((error as? MessagingProcessBroker.Failure)?.shareRefusal, .sessionReplaced)
        }
    }

    /// No refusal this broker can produce may repeat the sentence the owner was shown.
    func testNoRefusalRepeatsTheReportedSentence() throws {
        let reported = "Sharing is locked or your account changed. Unlock Kit Pay and share again."
        var failures: [MessagingProcessBroker.Failure] = [
            .unavailable, .corrupt, .accountChanged, .staleState, .queueFull,
        ]
        failures += ShareAuthorizationPolicy.Refusal.allCases.map { .shareRefused($0) }
        for failure in failures {
            let message = try XCTUnwrap(failure.errorDescription)
            XCTAssertNotEqual(message, reported)
            XCTAssertFalse(message.lowercased().contains("is locked"), message)
        }
    }

    func testDurableRevocationFencesOldTokensWithoutKeychainTombstone() throws {
        let app = broker()
        try prepare(app)
        let scope = try app.scope()
        try app.withLock { locked in try locked.revokeSessionLocked(generation: scope.generation) }
        let sibling = broker()
        XCTAssertNil(try sibling.withLock { try $0.authorityLocked()?.session })
        XCTAssertThrowsError(try sibling.snapshot(scope: scope))
    }

    func testRevokedGenerationCleanupKeepsPrivateReceiptAndCannotDeleteReplacement() throws {
        let app = broker()
        try prepare(app)
        let scope = try app.scope(), receipt = UUID()
        try app.updateOutgoing(scope: scope) { $0.privateTransactionID = receipt }
        try app.withLock { locked in
            try locked.revokeSessionLocked(generation: scope.generation)
            try locked.purgeRevokedGenerationLocked(scope.generation)
            XCTAssertNil(try locked.recordLocked())
            XCTAssertEqual(try locked.privateReceiptLocked(accountID: account), receipt)
            var next = MessagingProcessBroker.Authority.revoked
            next.session = tokens("new-login")
            try locked.saveAuthorityLocked(next)
            try locked.saveRecordLocked(.init(generation: next.generation, accountID: account, crypto: .empty))
            try locked.purgeRevokedGenerationLocked(scope.generation)
            XCTAssertEqual(try locked.recordLocked()?.generation, next.generation)
        }
    }

    func testRepeatedFailedTombstonesAndFailedReplacementCannotResurrectCredentials() async throws {
        let failWrites = BrokerTestClock()
        let app = broker(check: { _ in
            if failWrites.value > 0 { throw CocoaError(.fileWriteNoPermission) }
        })
        try prepare(app)
        let sessionStore = SessionStore(account: "failed-tombstone", messagingBroker: app)
        failWrites.value = 1
        for _ in 0 ..< 2 {
            do { try await sessionStore.clear(); XCTFail("Injected failure") } catch {}
            let current = await sessionStore.current()
            XCTAssertNil(current)
            XCTAssertNil(try broker().withLock { try $0.authorityLocked()?.session })
        }
        do { try await sessionStore.save(tokens("replacement")); XCTFail("Injected replacement failure") } catch {}
        XCTAssertNil(try broker().withLock { try $0.authorityLocked()?.session })
    }

    func testConcurrentRefreshesShareNonceAndAdoptOnlyNewerCredentials() async throws {
        let app = broker(), sibling = broker()
        try prepare(app)
        let first = SessionStore(account: "test-broker-session", messagingBroker: app)
        let second = SessionStore(account: "test-broker-session", messagingBroker: sibling)
        async let nonce1 = first.replayNonce(for: tokens())
        async let nonce2 = second.replayNonce(for: tokens())
        let nonces = try await (nonce1, nonce2)
        XCTAssertEqual(nonces.0, nonces.1)
        let winner = try await first.adoptRefresh(tokens("winner"), ifCurrent: tokens())
        let adopted = try await second.adoptRefresh(tokens("stale-response"), ifCurrent: tokens())
        XCTAssertEqual(winner, adopted)
        XCTAssertEqual(adopted, tokens("winner"))
    }
}

private final class BrokerTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: TimeInterval = 0
    var value: TimeInterval {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
/// Shared fake OS storage; each broker still has its own authenticator and counters.
private final class BrokerTestGuardBackend: @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: [UUID: MessagingBiometricCredential] = [:]
    private var invalidated: Set<UUID> = []

    func create(binding: MessagingBiometricBinding, enrollmentKeyID: String) -> MessagingBiometricCredential {
        let id = UUID()
        let credential = MessagingBiometricCredential(
            id: id, binding: binding, enrollmentKeyID: enrollmentKeyID,
            secretSHA256: Data(SHA256.hash(data: Data(id.uuidString.utf8)))
        )
        lock.withLock { credentials[id] = credential }
        return credential
    }

    func isAvailable(_ credential: MessagingBiometricCredential) -> Bool {
        lock.withLock {
            credential.isStructurallyValid && credentials[credential.id] == credential
                && !invalidated.contains(credential.id)
        }
    }

    func requireProtectedRead(_ credential: MessagingBiometricCredential) throws {
        try lock.withLock {
            guard credential.isStructurallyValid, credentials[credential.id] == credential else {
                throw MessagingBiometricCredentialError.missingCredential
            }
            guard !invalidated.contains(credential.id) else {
                throw MessagingBiometricCredentialError.invalidatedCredential
            }
        }
    }

    func invalidate(_ credential: MessagingBiometricCredential) {
        _ = lock.withLock { invalidated.insert(credential.id) }
    }

    func remove(_ credential: MessagingBiometricCredential) {
        lock.withLock {
            _ = credentials.removeValue(forKey: credential.id)
            _ = invalidated.remove(credential.id)
        }
    }
}

private final class BrokerTestBiometrics: MessagingBiometricAuthenticating, @unchecked Sendable {
    private let lock = NSLock()
    private let backend: BrokerTestGuardBackend
    // Deliberately different across app/extension fixtures; the protocol never consults it.
    let processLocalDomain: Data
    private var created: [MessagingBiometricCredential] = []
    private var removed: [MessagingBiometricCredential] = []
    private var authenticationCount = 0
    private var createCallback: (() throws -> Void)?
    private var existsCallback: (() throws -> Void)?
    private var authenticationCallback: (() async throws -> Void)?

    init(backend: BrokerTestGuardBackend, processLocalDomain: Data) {
        self.backend = backend
        self.processLocalDomain = processLocalDomain
    }

    var creations: Int { lock.withLock { created.count } }
    var createdCredentials: [MessagingBiometricCredential] { lock.withLock { created } }
    var removedCredentials: [MessagingBiometricCredential] { lock.withLock { removed } }
    var authentications: Int { lock.withLock { authenticationCount } }
    var onCreate: (() throws -> Void)? {
        get { lock.withLock { createCallback } }
        set { lock.withLock { createCallback = newValue } }
    }
    var onCredentialExists: (() throws -> Void)? {
        get { lock.withLock { existsCallback } }
        set { lock.withLock { existsCallback = newValue } }
    }
    var onAuthenticate: (() async throws -> Void)? {
        get { lock.withLock { authenticationCallback } }
        set { lock.withLock { authenticationCallback = newValue } }
    }

    func createCredential(
        binding: MessagingBiometricBinding, enrollmentKeyID: String
    ) throws -> MessagingBiometricCredential {
        let credential = backend.create(binding: binding, enrollmentKeyID: enrollmentKeyID)
        let callback = lock.withLock {
            created.append(credential)
            return createCallback
        }
        try callback?()
        return credential
    }

    func credentialExists(_ credential: MessagingBiometricCredential) throws -> Bool {
        let exists = backend.isAvailable(credential)
        let callback = onCredentialExists
        try callback?()
        return exists
    }

    func authenticate(credential: MessagingBiometricCredential) async throws {
        let callback = lock.withLock {
            authenticationCount += 1
            return authenticationCallback
        }
        // Production may prompt before discovering that the protected item is unusable.
        try backend.requireProtectedRead(credential)
        // Deliver an already-valid OS result after the callback, even if the callback revoked
        // the guard. The broker, rather than the mock, must discard that stale result.
        try await callback?()
    }

    func removeCredential(_ credential: MessagingBiometricCredential) throws {
        backend.remove(credential)
        lock.withLock { removed.append(credential) }
    }
}

/// TestFlight 1.0.17 (102) was killed by RunningBoard with `0xdead10cc` while a background
/// outbox flush held this broker's `flock`. These cases pin the assertion that keeps the
/// process awake for exactly as long as the file lock is held.
final class SharedLockActivityTests: XCTestCase {
    private var root: URL!
    private let key = Data(repeating: 0x51, count: 32)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        SharedLockActivity.install(nil)
        try? FileManager.default.removeItem(at: root)
    }

    private func broker() -> MessagingProcessBroker {
        MessagingProcessBroker(rootURL: root, key: key)
    }

    /// True only while nothing else in this process holds the broker's file lock: `flock` is
    /// owned by the open file description, so a second descriptor here still blocks.
    private func fileLockIsFree() -> Bool {
        let path = root.appendingPathComponent("MessagingBroker/transaction.lock").path
        let descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return false }
        flock(descriptor, LOCK_UN)
        return true
    }

    func testLockedSectionRunsInsideOneActivityAssertion() throws {
        var begun = 0
        var ended = 0
        SharedLockActivity.install {
            begun += 1
            return { ended += 1 }
        }
        var observedInsideBody: (Int, Int)?
        try broker().withLock { _ in
            observedInsideBody = (begun, ended)
        }
        XCTAssertEqual(observedInsideBody?.0, 1, "the assertion is taken before the body runs")
        XCTAssertEqual(observedInsideBody?.1, 0, "the assertion stays open for the whole body")
        XCTAssertEqual(begun, 1)
        XCTAssertEqual(ended, 1, "the assertion is always ended")
    }

    func testAssertionIsEndedWhenTheLockedBodyThrows() {
        var begun = 0
        var ended = 0
        SharedLockActivity.install {
            begun += 1
            return { ended += 1 }
        }
        struct Failure: Error {}
        XCTAssertThrowsError(try broker().withLock { _ in throw Failure() })
        XCTAssertEqual(begun, 1)
        XCTAssertEqual(ended, 1, "a throwing body must not strand the assertion")
    }

    /// The window has to contain the file lock itself, not merely the body: a suspension
    /// between `flock(LOCK_EX)` and `flock(LOCK_UN)` is what RunningBoard kills with
    /// 0xdead10cc. This pins the acquisition side, which is observable. The release side —
    /// that the handler runs only after `flock(fd, LOCK_UN)` — is pinned by the defer order
    /// in `.github/scripts/tests/test_shared_lock_activity.py`; probing for a *released*
    /// lock from this same process is not dependable on the test host.
    func testTheFileLockIsHeldForTheWholeAssertionWindow() throws {
        var open = 0
        SharedLockActivity.install {
            open += 1
            return { open -= 1 }
        }
        var observedInsideBody: (Int, Bool)?
        try broker().withLock { _ in
            observedInsideBody = (open, self.fileLockIsFree() == false)
        }
        XCTAssertEqual(observedInsideBody?.0, 1, "the assertion is open for the locked section")
        XCTAssertEqual(observedInsideBody?.1, true, "the probe must detect the held file lock")
        XCTAssertEqual(open, 0, "the assertion is always ended")
    }

    func testMissingProviderStillReturnsABalancedHandler() throws {
        SharedLockActivity.install(nil)
        XCTAssertNoThrow(try broker().withLock { _ in })
        let end = SharedLockActivity.begin()
        end()
    }

    // MARK: The share extension's ProcessInfo-backed provider
    //
    // KitPayShare compiles the broker and takes the same flock, but
    // APPLICATION_EXTENSION_API_ONLY removes UIApplication.shared, so it cannot install the
    // app's background-task provider. Left on the no-op default it holds the app-group lock
    // with no assertion at all, in the process the system suspends most readily: the sheet is
    // torn down the instant Send is tapped, while the send is still being journalled.

    /// `performExpiringActivity` asserts for exactly as long as its block runs. A provider that
    /// let the block return early would assert nothing at all.
    func testTheExpiringActivityBlockOutlivesTheLockedSection() throws {
        let state = ActivityProbe()
        SharedLockActivity.installExpiringActivityProvider(
            perform: { reason, body in
                state.record(reason: reason)
                Thread.detachNewThread {
                    state.markBlockRunning()
                    body(false)
                    state.markBlockFinished()
                }
            }
        )
        var runningInsideBody = false
        try broker().withLock { _ in
            runningInsideBody = state.waitForBlockRunning()
            XCTAssertFalse(state.blockHasFinished, "the activity must not end mid-section")
        }
        XCTAssertTrue(runningInsideBody, "the activity block must be running inside the lock")
        XCTAssertTrue(state.waitForBlockFinished(), "ending the assertion releases the block")
        XCTAssertEqual(state.reason, "africa.kit.pay.shared-store-lock")
    }

    /// RunningBoard refuses or revokes assertions under pressure. That must cost the caller
    /// nothing: the locked section still has to run, exactly as it did before the provider.
    func testARefusedExpiringActivityNeitherBlocksNorStrandsTheCaller() throws {
        let state = ActivityProbe()
        SharedLockActivity.installExpiringActivityProvider(
            perform: { reason, body in
                state.record(reason: reason)
                body(true)
                state.markBlockFinished()
            },
            grantTimeout: 5
        )
        let started = Date()
        var ranBody = false
        try broker().withLock { _ in ranBody = true }
        XCTAssertTrue(ranBody, "a refused assertion must not skip the locked section")
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 1,
            "an expired activity returns immediately instead of waiting to be released"
        )
        XCTAssertTrue(state.blockHasFinished, "a refused activity holds no worker thread")
    }

    /// If the system never schedules the block, the caller waits out the grant timeout once and
    /// then proceeds unprotected — which is the old behaviour, not a hang.
    func testAnUnscheduledExpiringActivityReleasesTheCallerAfterTheGrantTimeout() throws {
        SharedLockActivity.installExpiringActivityProvider(
            perform: { _, _ in },
            grantTimeout: 0.05
        )
        let started = Date()
        var ranBody = false
        try broker().withLock { _ in ranBody = true }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertTrue(ranBody, "the locked section still runs")
        XCTAssertGreaterThanOrEqual(elapsed, 0.05, "the caller waits for the grant it asked for")
        XCTAssertLessThan(elapsed, 3, "and never waits on a block that will not arrive")
    }
}

/// Test-only recorder. `perform` is called from the locked section and its block runs on
/// another thread, so every field crosses threads and needs its own lock.
private final class ActivityProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let running = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private var recordedReason: String?
    private var didFinish = false

    var reason: String? {
        lock.lock()
        defer { lock.unlock() }
        return recordedReason
    }

    var blockHasFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didFinish
    }

    func record(reason: String) {
        lock.lock()
        recordedReason = reason
        lock.unlock()
    }

    func markBlockRunning() { running.signal() }

    func markBlockFinished() {
        lock.lock()
        didFinish = true
        lock.unlock()
        finished.signal()
    }

    func waitForBlockRunning() -> Bool { running.wait(timeout: .now() + 5) == .success }

    func waitForBlockFinished() -> Bool { finished.wait(timeout: .now() + 5) == .success }
}
