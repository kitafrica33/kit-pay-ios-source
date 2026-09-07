import CryptoKit
import XCTest
@testable import KitPay

final class MessagingProcessBrokerTests: XCTestCase {
    private let account = "10000000-0000-4000-8000-000000000001"
    private let session = "20000000-0000-4000-8000-000000000002"
    private let recipient = "30000000-0000-4000-8000-000000000003"
    private var root: URL!
    private let key = Data(repeating: 0x43, count: 32)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private var destination: SharedInboxDestination {
        SharedInboxDestination(conversationID: nil, recipientUserID: recipient,
                               displayName: "Private recipient name", kind: .contact, memberCount: nil)
    }
    private func tokens(_ suffix: String = "one") -> SessionTokens {
        SessionTokens(accessToken: "access-\(suffix)", refreshToken: "refresh-\(suffix)",
                      tokenType: "Bearer", accessExpiresAt: nil, refreshExpiresAt: nil,
                      sessionId: session, accountId: account)
    }
    private func broker(
        biometrics: BrokerTestBiometrics = BrokerTestBiometrics(), clock: BrokerTestClock = BrokerTestClock(),
        check: ((MessagingProcessBroker.Authority) throws -> Void)? = nil
    ) -> MessagingProcessBroker {
        MessagingProcessBroker(rootURL: root, key: key, biometrics: biometrics,
                               uptime: { clock.value }, authorityWriteCheck: check)
    }
    private func prepare(_ broker: MessagingProcessBroker, biometric: Bool = false) throws {
        try broker.withLock { locked in
            var authority = MessagingProcessBroker.Authority.revoked
            authority.session = tokens()
            try locked.saveAuthorityLocked(authority)
            try locked.saveRecordLocked(.init(generation: authority.generation, accountID: account, crypto: .empty))
        }
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

    func testBiometricLockKeepsOnlyEncryptedDirectoryAndAuthenticatesLocally() async throws {
        let bio = BrokerTestBiometrics(), app = broker()
        try prepare(app, biometric: true)
        try app.suspendSharingForBiometricLock(accountID: account)
        let share = broker(biometrics: bio)
        XCTAssertThrowsError(try share.scope())
        let result = try await share.authorizeShare()
        XCTAssertEqual(result.destinations, [destination])
        XCTAssertEqual(bio.authentications, 1)
        XCTAssertEqual(try share.approvedDestinations(scope: share.scope()), [destination])
        XCTAssertThrowsError(try app.scope(), "The sibling process must not inherit the share lease")
        let encrypted = try Data(contentsOf: root.appendingPathComponent("destinations.secure"))
        XCTAssertNil(encrypted.range(of: Data(destination.displayName.utf8)))
    }

    func testLeaseExpiresAtFiveMinutesAndCannotBeReusedAcrossRestart() async throws {
        let clock = BrokerTestClock(), app = broker(clock: clock)
        try prepare(app, biometric: true)
        try app.suspendSharingForBiometricLock(accountID: account)
        _ = try await app.authorizeShare()
        let scope = try app.scope()
        clock.value = 299
        _ = try app.snapshot(scope: scope)
        clock.value = 300
        XCTAssertThrowsError(try app.snapshot(scope: scope))
        XCTAssertThrowsError(try broker().scope())
    }

    func testChangedBiometricDomainCannotAuthenticateOrSilentlyRepin() async throws {
        let bio = BrokerTestBiometrics(), app = broker(biometrics: bio)
        try prepare(app, biometric: true)
        try app.suspendSharingForBiometricLock(accountID: account)
        bio.domain = Data("replacement-enrollment".utf8)
        do { _ = try await app.authorizeShare(); XCTFail("Changed biometrics must fail") }
        catch { XCTAssertEqual(bio.authentications, 0) }
        XCTAssertThrowsError(try app.publishApprovedDestinations(
            [destination], accountID: account, requiresBiometricUnlock: true
        ))
        XCTAssertThrowsError(try app.restoreBiometricSharingDestinations([destination], accountID: account))
    }

    func testHardDenialWinsEvenWhenKeychainUpdateFails() async throws {
        let failWrites = BrokerTestClock(), bio = BrokerTestBiometrics()
        let app = broker(biometrics: bio, check: { _ in
            if failWrites.value > 0 { throw CocoaError(.fileWriteNoPermission) }
        })
        try prepare(app, biometric: true)
        _ = try await app.authorizeShare()
        let scope = try app.scope()
        failWrites.value = 1
        XCTAssertThrowsError(try app.setSharingEnabled(false, accountID: account))
        XCTAssertThrowsError(try app.snapshot(scope: scope))
        XCTAssertThrowsError(try broker().scope())
        do { _ = try await app.authorizeShare(); XCTFail("Hard denial must block another biometric prompt") }
        catch { XCTAssertEqual(bio.authentications, 1) }
    }

    func testHardDenialDuringAuthenticationCannotInstallLease() async throws {
        let bio = BrokerTestBiometrics(), app = broker(biometrics: bio)
        try prepare(app, biometric: true)
        try app.suspendSharingForBiometricLock(accountID: account)
        bio.onAuthenticate = { try app.setSharingEnabled(false, accountID: self.account) }
        do { _ = try await app.authorizeShare(); XCTFail("Revoked authentication result must be discarded") }
        catch { XCTAssertThrowsError(try app.scope()) }
    }

    func testSessionReplacementDuringAuthenticationCannotInstallLease() async throws {
        let bio = BrokerTestBiometrics(), app = broker(biometrics: bio)
        try prepare(app, biometric: true)
        try app.suspendSharingForBiometricLock(accountID: account)
        bio.onAuthenticate = {
            try app.withLock { locked in
                var authority = try XCTUnwrap(locked.authorityLocked())
                authority.generation = UUID()
                try locked.saveAuthorityLocked(authority)
            }
        }
        do { _ = try await app.authorizeShare(); XCTFail("Account/session generation changed") }
        catch { XCTAssertThrowsError(try app.scope()) }
    }

    func testBackgroundRestoreRequiresExistingPinAndStillRequiresAuthentication() async throws {
        let app = broker()
        try prepare(app)
        try app.setSharingEnabled(false, accountID: account)
        XCTAssertThrowsError(try app.restoreBiometricSharingDestinations([destination], accountID: account))
        try app.publishApprovedDestinations([destination], accountID: account, requiresBiometricUnlock: true)
        try app.setSharingEnabled(true, accountID: account)
        try app.setSharingEnabled(false, accountID: account)
        try app.restoreBiometricSharingDestinations([destination], accountID: account)
        XCTAssertThrowsError(try app.scope())
        _ = try await app.authorizeShare()
        _ = try app.scope()
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

    func testIdenticalBiometricBackgroundRestoreDoesNotInvalidateActiveShareLease() async throws {
        let app = broker(), share = broker()
        try prepare(app, biometric: true)
        try app.suspendSharingForBiometricLock(accountID: account)
        _ = try await share.authorizeShare()
        let scope = try share.scope()
        try app.restoreBiometricSharingDestinations([destination], accountID: account)
        XCTAssertEqual(try share.scope(), scope)
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
private final class BrokerTestBiometrics: MessagingBiometricAuthenticating, @unchecked Sendable {
    var domain = Data("approved-enrollment".utf8)
    var authentications = 0
    var onAuthenticate: (() throws -> Void)?
    func domainState() throws -> Data { domain }
    func authenticate(expectedDomain: Data) async throws {
        guard domain == expectedDomain else { throw MessagingProcessBroker.Failure.biometricEnrollmentChanged }
        authentications += 1
        try onAuthenticate?()
        guard domain == expectedDomain else { throw MessagingProcessBroker.Failure.biometricEnrollmentChanged }
    }
}
