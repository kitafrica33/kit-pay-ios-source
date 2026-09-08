import CryptoKit
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
    private func credential(_ broker: MessagingProcessBroker) throws -> MessagingBiometricCredential {
        try broker.withLock { try XCTUnwrap($0.authorityLocked()?.biometricCredential) }
    }
    private func assertShareFails(
        _ broker: MessagingProcessBroker, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do { _ = try await broker.authorizeShare(); XCTFail(message, file: file, line: line) }
        catch {}
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

    /// Drives the same publication decision as AppModel, with the real broker underneath it.
    /// The callbacks below deterministically interleave publication with Security work outside
    /// the broker lock; no timing sleeps or simulated successful broker responses are used.
    @discardableResult
    private func publishDuringApproval(
        _ broker: MessagingProcessBroker, gate: inout SharedMessagingApprovalPublicationGate,
        epoch: UUID, accountID: String? = nil, securityEligible: Bool = true,
        destinations: [SharedInboxDestination]? = nil
    ) throws -> SharedMessagingApprovalPublicationGate.PublicationDecision {
        let owner = accountID ?? account
        let binding = gate.operation.flatMap {
            try? broker.biometricBinding(accountID: owner, sessionID: $0.binding.sessionID)
        }
        let decision = gate.publicationDecision(
            accountEpoch: epoch, accountID: owner, currentBinding: binding,
            securityEligible: securityEligible
        )
        switch decision {
        case .deferUntilApprovalFinishes:
            break
        case .deny:
            gate.invalidate()
            try broker.setSharingEnabled(false, accountID: nil)
        case .publish:
            do {
                try broker.restoreBiometricSharingDestinations(destinations ?? [destination], accountID: owner)
            } catch {
                try broker.setSharingEnabled(false, accountID: nil)
            }
        }
        return decision
    }

    func testUncoordinatedFirstApprovalReproducesPublicationDenialRace() throws {
        let bio = authenticator(), app = broker(biometrics: bio)
        try prepare(app)
        try installUnapprovedBiometricAuthority(app, legacyDomain: Data("legacy92".utf8))
        var noApprovalCoordination = SharedMessagingApprovalPublicationGate()
        bio.onCreate = {
            try self.publishDuringApproval(app, gate: &noApprovalCoordination, epoch: UUID())
        }

        XCTAssertThrowsError(try approve(app))
        XCTAssertNil(try app.withLock { try $0.authorityLocked()?.biometricCredential })
        XCTAssertThrowsError(try app.scope())
    }

    func testApprovalPublicationDefersMigrationRefreshUntilCredentialCommits() async throws {
        let bio = authenticator(), app = broker(biometrics: bio)
        try prepare(app)
        try installUnapprovedBiometricAuthority(app, legacyDomain: Data("legacy92".utf8))
        let epoch = UUID(), binding = try app.biometricBinding(accountID: account, sessionID: session)
        var gate = SharedMessagingApprovalPublicationGate()
        let operation = try XCTUnwrap(gate.begin(accountEpoch: epoch, binding: binding))
        let updated = SharedInboxDestination(conversationID: nil, recipientUserID: recipient,
                                            displayName: "Updated recipient", kind: .contact, memberCount: nil)
        var deferred = 0
        bio.onCreate = {
            for _ in 0..<3 {
                XCTAssertEqual(try self.publishDuringApproval(
                    app, gate: &gate, epoch: epoch, destinations: [updated]
                ), .deferUntilApprovalFinishes)
                deferred += 1
            }
        }

        try approve(app)
        XCTAssertEqual(deferred, 3)
        XCTAssertTrue(gate.finish(operation))
        XCTAssertNil(gate.operation)
        XCTAssertEqual(try publishDuringApproval(app, gate: &gate, epoch: epoch, destinations: [updated]), .publish)
        let share = broker()
        let directory = try await share.authorizeShare()
        XCTAssertEqual(directory.destinations, [updated])
        XCTAssertThrowsError(try app.scope(), "Publishing must not grant the main app the extension's lease")
    }

    func testUncoordinatedCredentialReuseReproducesChangedDirectoryRace() throws {
        let bio = authenticator(), app = broker(biometrics: bio)
        try prepare(app, biometric: true)
        try app.suspendSharingForBiometricLock(accountID: account)
        let original = try credential(app)
        var noApprovalCoordination = SharedMessagingApprovalPublicationGate()
        let updated = SharedInboxDestination(conversationID: nil, recipientUserID: recipient,
                                            displayName: "Changed while unlocking", kind: .contact, memberCount: nil)
        bio.onCredentialExists = {
            try self.publishDuringApproval(app, gate: &noApprovalCoordination,
                                           epoch: UUID(), destinations: [updated])
        }

        XCTAssertThrowsError(try approve(app))
        XCTAssertEqual(try credential(app), original)
        XCTAssertThrowsError(try app.scope())
    }

    func testApprovalPublicationDefersChangedDirectoryWhileReusingCredential() async throws {
        let bio = authenticator(), app = broker(biometrics: bio)
        try prepare(app, biometric: true)
        try app.suspendSharingForBiometricLock(accountID: account)
        let original = try credential(app)
        let epoch = UUID(), binding = try app.biometricBinding(accountID: account, sessionID: session)
        var gate = SharedMessagingApprovalPublicationGate()
        let operation = try XCTUnwrap(gate.begin(accountEpoch: epoch, binding: binding))
        let updated = SharedInboxDestination(conversationID: nil, recipientUserID: recipient,
                                            displayName: "Latest chat order", kind: .contact, memberCount: nil)
        bio.onCredentialExists = {
            XCTAssertEqual(try self.publishDuringApproval(
                app, gate: &gate, epoch: epoch, destinations: [updated]
            ), .deferUntilApprovalFinishes)
        }

        try approve(app)
        bio.onCredentialExists = nil
        XCTAssertEqual(try credential(app), original)
        XCTAssertEqual(bio.creations, 1, "An unchanged credential must not be recreated")
        XCTAssertTrue(gate.finish(operation))
        try publishDuringApproval(app, gate: &gate, epoch: epoch, destinations: [updated])
        let directory = try await broker().authorizeShare()
        XCTAssertEqual(directory.destinations, [updated])
    }

    func testApprovalPublicationNeverDefersSecurityDenialDuringCreation() throws {
        let bio = authenticator(), app = broker(biometrics: bio)
        try prepare(app)
        let epoch = UUID(), binding = try app.biometricBinding(accountID: account, sessionID: session)
        var gate = SharedMessagingApprovalPublicationGate()
        let operation = try XCTUnwrap(gate.begin(accountEpoch: epoch, binding: binding))
        bio.onCreate = {
            XCTAssertEqual(try self.publishDuringApproval(
                app, gate: &gate, epoch: epoch, securityEligible: false
            ), .deny)
        }

        XCTAssertThrowsError(try approve(app))
        XCTAssertNil(gate.operation)
        XCTAssertFalse(gate.finish(operation))
        XCTAssertNil(try app.withLock { try $0.authorityLocked()?.biometricCredential })
        XCTAssertThrowsError(try app.scope())
    }

    func testApprovalPublicationRejectsChangedAccountEpochDuringCreation() throws {
        let bio = authenticator(), app = broker(biometrics: bio)
        try prepare(app)
        var gate = SharedMessagingApprovalPublicationGate()
        let operation = try XCTUnwrap(gate.begin(
            accountEpoch: UUID(), binding: app.biometricBinding(accountID: account, sessionID: session)
        ))
        bio.onCreate = {
            XCTAssertEqual(try self.publishDuringApproval(app, gate: &gate, epoch: UUID()), .deny)
        }

        XCTAssertThrowsError(try approve(app))
        XCTAssertFalse(gate.finish(operation))
        XCTAssertNil(gate.operation)
        XCTAssertThrowsError(try app.scope())
    }

    func testApprovalPublicationRejectsSameAccountReplacementSession() throws {
        let bio = authenticator(), app = broker(biometrics: bio)
        try prepare(app)
        let epoch = UUID(), binding = try app.biometricBinding(accountID: account, sessionID: session)
        var gate = SharedMessagingApprovalPublicationGate()
        let operation = try XCTUnwrap(gate.begin(accountEpoch: epoch, binding: binding))
        let replacement = tokens("replacement", sessionID: UUID().uuidString.lowercased())
        bio.onCreate = {
            try app.withLock { locked in
                var authority = MessagingProcessBroker.Authority.revoked
                authority.session = replacement
                try locked.saveAuthorityLocked(authority)
            }
            XCTAssertEqual(try self.publishDuringApproval(app, gate: &gate, epoch: epoch), .deny)
        }

        XCTAssertThrowsError(try approve(app))
        XCTAssertFalse(gate.finish(operation))
        XCTAssertNil(gate.operation)
        XCTAssertEqual(try app.withLock { try $0.authorityLocked()?.session }, replacement)
        XCTAssertNil(try app.withLock { try $0.authorityLocked()?.biometricCredential })
    }

    func testApprovalPublicationCleanupCannotRetireSuccessorOrSurviveCancellation() throws {
        let app = broker()
        try prepare(app)
        let binding = try app.biometricBinding(accountID: account, sessionID: session)
        var gate = SharedMessagingApprovalPublicationGate()
        let old = try XCTUnwrap(gate.begin(accountEpoch: UUID(), binding: binding))
        gate.invalidate()
        let current = try XCTUnwrap(gate.begin(accountEpoch: UUID(), binding: binding))
        XCTAssertFalse(gate.finish(old))
        XCTAssertTrue(gate.owns(current))

        do {
            defer { gate.finish(current) }
            try approve(app, confirmPrivateKey: { throw CancellationError() })
            XCTFail("A cancelled private-key confirmation must not approve sharing")
        } catch is CancellationError {}
        XCTAssertNil(gate.operation)
        XCTAssertNil(try app.withLock { try $0.authorityLocked()?.biometricCredential })
        XCTAssertThrowsError(try app.scope())
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
        let bio = authenticator(), app = broker()
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

    func testInvalidatedGuardCannotAuthenticateOrSilentlyRepair() async throws {
        let bio = authenticator(), app = broker(biometrics: bio)
        try prepare(app, biometric: true)
        try app.suspendSharingForBiometricLock(accountID: account)
        let original = try credential(app)
        guardBackend.invalidate(original)
        await assertShareFails(app, "An invalidated OS guard must reject sharing")
        XCTAssertThrowsError(try app.scope())
        try app.publishApprovedDestinations(
            [destination], accountID: account, requiresBiometricUnlock: true
        )
        try app.restoreBiometricSharingDestinations([destination], accountID: account)
        await assertShareFails(app, "Directory publication and restore must not repair a guard")
        XCTAssertEqual(try credential(app), original)
        XCTAssertEqual(bio.creations, 1)
        XCTAssertFalse(guardBackend.isAvailable(original))
        XCTAssertThrowsError(try app.scope())
    }

    func testHardDenialWinsEvenWhenKeychainUpdateFails() async throws {
        let failWrites = BrokerTestClock(), bio = authenticator()
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
        let bio = authenticator(), app = broker(biometrics: bio)
        try prepare(app, biometric: true)
        try app.suspendSharingForBiometricLock(accountID: account)
        bio.onAuthenticate = { try app.setSharingEnabled(false, accountID: self.account) }
        do { _ = try await app.authorizeShare(); XCTFail("Revoked authentication result must be discarded") }
        catch { XCTAssertThrowsError(try app.scope()) }
    }

    func testSessionReplacementDuringAuthenticationCannotInstallLease() async throws {
        let bio = authenticator(), app = broker(biometrics: bio)
        try prepare(app, biometric: true)
        try app.suspendSharingForBiometricLock(accountID: account)
        let sessionStore = SessionStore(account: "authentication-replacement", messagingBroker: app)
        let replacement = tokens("replacement", sessionID: UUID().uuidString.lowercased())
        bio.onAuthenticate = { try await sessionStore.save(replacement) }
        do { _ = try await app.authorizeShare(); XCTFail("Account/session generation changed") }
        catch { XCTAssertThrowsError(try app.scope()) }
        XCTAssertNil(try app.withLock { try $0.authorityLocked()?.biometricCredential })
    }

    func testBackgroundRestoreRequiresExistingCredentialAndStillRequiresAuthentication() async throws {
        let bio = authenticator(), app = broker(biometrics: bio)
        try prepare(app)
        try app.setSharingEnabled(false, accountID: account)
        XCTAssertThrowsError(try app.restoreBiometricSharingDestinations([destination], accountID: account))
        XCTAssertEqual(bio.creations, 0)
        try approve(app)
        try app.publishApprovedDestinations([destination], accountID: account, requiresBiometricUnlock: true)
        try app.setSharingEnabled(true, accountID: account)
        try app.setSharingEnabled(false, accountID: account)
        try app.restoreBiometricSharingDestinations([destination], accountID: account)
        XCTAssertThrowsError(try app.scope())
        _ = try await app.authorizeShare()
        _ = try app.scope()
        XCTAssertEqual(bio.authentications, 1)
        XCTAssertEqual(bio.creations, 1)
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

    func testDifferentProcessDomainsUseSameGuardAndSeparateAuthentication() async throws {
        let appBio = authenticator(domain: "app-opaque-domain")
        let shareBio = authenticator(domain: "extension-opaque-domain")
        let app = broker(biometrics: appBio), share = broker(biometrics: shareBio)
        try prepare(app, biometric: true)
        XCTAssertNotEqual(appBio.processLocalDomain, shareBio.processLocalDomain)
        XCTAssertEqual(try credential(app), try credential(share))
        try app.suspendSharingForBiometricLock(accountID: account)

        let authorized = try await share.authorizeShare()
        XCTAssertEqual(authorized.destinations, [destination])
        XCTAssertEqual(appBio.authentications, 0)
        XCTAssertEqual(shareBio.authentications, 1)
        XCTAssertEqual(appBio.creations, 1)
        XCTAssertEqual(shareBio.creations, 0)
        XCTAssertThrowsError(try app.scope(), "The app must not inherit the extension's proof")

        _ = try await app.authorizeShare()
        XCTAssertEqual(appBio.authentications, 1)
        XCTAssertEqual(try app.scope(), try share.scope())
    }

    func testMissingGuardCannotAuthenticateOrBeRecreatedBySharePaths() async throws {
        let appBio = authenticator(), shareBio = authenticator()
        let app = broker(biometrics: appBio), share = broker(biometrics: shareBio)
        try prepare(app, biometric: true)
        try app.suspendSharingForBiometricLock(accountID: account)
        let original = try credential(app)
        guardBackend.remove(original)

        await assertShareFails(share, "A missing protected item must reject sharing")
        XCTAssertThrowsError(try share.scope())
        try app.publishApprovedDestinations([destination], accountID: account, requiresBiometricUnlock: true)
        try app.restoreBiometricSharingDestinations([destination], accountID: account)
        await assertShareFails(share, "Refreshing the directory must not recreate a deleted guard")
        XCTAssertEqual(try credential(app), original)
        XCTAssertEqual(appBio.creations, 1)
        XCTAssertEqual(shareBio.creations, 0)
        XCTAssertFalse(guardBackend.isAvailable(original))
        XCTAssertThrowsError(try share.scope())
    }

    func testGuardRemovedAfterProtectedReadCannotInstallLease() async throws {
        let bio = authenticator(), app = broker(biometrics: bio)
        try prepare(app, biometric: true)
        try app.suspendSharingForBiometricLock(accountID: account)
        let original = try credential(app), backend = try XCTUnwrap(guardBackend)
        bio.onAuthenticate = { backend.remove(original) }

        await assertShareFails(app, "An old successful read cannot authorize a now-missing guard")
        XCTAssertEqual(bio.authentications, 1)
        XCTAssertThrowsError(try app.scope())
        XCTAssertThrowsError(try broker().scope())
    }

    func testGuardInvalidatedAfterProtectedReadCannotInstallLease() async throws {
        let bio = authenticator(), app = broker(biometrics: bio)
        try prepare(app, biometric: true)
        try app.suspendSharingForBiometricLock(accountID: account)
        let original = try credential(app), backend = try XCTUnwrap(guardBackend)
        bio.onAuthenticate = { backend.invalidate(original) }

        await assertShareFails(app, "Known guard invalidation after a valid OS read must reject the result")
        XCTAssertEqual(bio.authentications, 1)
        XCTAssertThrowsError(try app.scope())
    }

    func testPublicationRestoreAndAuthorizationCannotCreateFirstCredential() async throws {
        let bio = authenticator(), app = broker(biometrics: bio)
        try prepare(app)
        try installUnapprovedBiometricAuthority(app)

        XCTAssertThrowsError(try app.publishApprovedDestinations(
            [destination], accountID: account, requiresBiometricUnlock: true
        ))
        XCTAssertThrowsError(try app.restoreBiometricSharingDestinations([destination], accountID: account))
        await assertShareFails(app, "Only explicit main-app proof may create the first credential")
        XCTAssertEqual(bio.creations, 0)
        XCTAssertEqual(bio.authentications, 0)
        XCTAssertNil(try app.withLock { try $0.authorityLocked()?.biometricCredential })
        XCTAssertThrowsError(try app.scope())
    }

    func testLegacyDomainOnlyAuthorityRequiresExplicitMainProofMigration() async throws {
        let bio = authenticator(domain: "extension-domain"), app = broker(biometrics: bio)
        let legacy = Data("build-92-app-domain".utf8)
        try prepare(app)
        try installUnapprovedBiometricAuthority(app, legacyDomain: legacy)
        XCTAssertEqual(try app.withLock { try $0.authorityLocked()?.biometricDomainState }, legacy)
        XCTAssertThrowsError(try app.publishApprovedDestinations(
            [destination], accountID: account, requiresBiometricUnlock: true
        ))
        XCTAssertThrowsError(try app.restoreBiometricSharingDestinations([destination], accountID: account))
        await assertShareFails(app, "Legacy opaque domain metadata is not a sharing credential")
        XCTAssertEqual(bio.creations, 0)

        try approve(app)
        XCTAssertEqual(bio.creations, 1)
        XCTAssertNil(try app.withLock { try $0.authorityLocked()?.biometricDomainState })
        XCTAssertTrue(try credential(app).isStructurallyValid)
        XCTAssertThrowsError(try app.scope(), "Migration itself must leave sharing denied")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("destinations.secure").path))
        try app.restoreBiometricSharingDestinations([destination], accountID: account)
        XCTAssertThrowsError(try app.scope())
        _ = try await app.authorizeShare()
        XCTAssertEqual(bio.authentications, 1)
        _ = try app.scope()
    }

    func testStaleOrMismatchedBindingCannotCreateCredential() throws {
        let bio = authenticator(), app = broker(biometrics: bio)
        try prepare(app)
        let current = try app.biometricBinding(accountID: account, sessionID: session)
        let mismatches = [
            MessagingBiometricBinding(generation: UUID(), accountID: account, sessionID: session),
            MessagingBiometricBinding(generation: current.generation, accountID: recipient, sessionID: session),
            MessagingBiometricBinding(generation: current.generation, accountID: account, sessionID: recipient),
        ]
        for binding in mismatches {
            XCTAssertThrowsError(try app.approveBiometricSharing(
                binding: binding, enrollmentKeyID: enrollmentKeyID, confirmPrivateKey: {}
            ))
        }
        XCTAssertThrowsError(try app.biometricBinding(accountID: recipient, sessionID: session))
        XCTAssertThrowsError(try app.biometricBinding(accountID: account, sessionID: recipient))
        XCTAssertEqual(bio.creations, 0)
        XCTAssertNil(try app.withLock { try $0.authorityLocked()?.biometricCredential })
    }

    func testInvalidEnrollmentKeyCannotCreateCredential() throws {
        let bio = authenticator(), app = broker(biometrics: bio)
        try prepare(app)
        for invalidKey in ["", String(repeating: "a", count: 63), String(repeating: "A", count: 64),
                           String(repeating: "g", count: 64), String(repeating: "a", count: 65)] {
            XCTAssertThrowsError(try approve(app, enrollmentKeyID: invalidKey))
        }
        XCTAssertEqual(bio.creations, 0)
    }

    func testExplicitMainProofRepairReplacesGuardAndFencesOldShareLease() async throws {
        let appBio = authenticator(), app = broker(biometrics: appBio), share = broker()
        try prepare(app, biometric: true)
        try app.suspendSharingForBiometricLock(accountID: account)
        _ = try await share.authorizeShare()
        let oldScope = try share.scope(), original = try credential(app)
        guardBackend.invalidate(original)

        try approve(app)
        let replacement = try credential(app)
        XCTAssertNotEqual(replacement.id, original.id)
        XCTAssertTrue(guardBackend.isAvailable(replacement))
        XCTAssertEqual(appBio.creations, 2)
        XCTAssertThrowsError(try share.snapshot(scope: oldScope))
        XCTAssertThrowsError(try share.scope())
        await assertShareFails(share, "Repair must not clear durable denial or publish a directory")

        try app.restoreBiometricSharingDestinations([destination], accountID: account)
        _ = try await share.authorizeShare()
        XCTAssertNotEqual(try share.scope(), oldScope)
        XCTAssertEqual(try share.approvedDestinations(scope: share.scope()), [destination])
        XCTAssertEqual(appBio.authentications, 0)
    }

    func testRepairDuringAuthenticationRejectsProofForRetiredCredential() async throws {
        let shareBio = authenticator(), app = broker(), share = broker(biometrics: shareBio)
        try prepare(app, biometric: true)
        try app.suspendSharingForBiometricLock(accountID: account)
        let original = try credential(app)
        shareBio.onAuthenticate = {
            try self.approve(app, enrollmentKeyID: String(repeating: "b", count: 64))
            try app.restoreBiometricSharingDestinations([self.destination], accountID: self.account)
        }

        await assertShareFails(share, "An old credential's proof cannot grant a lease after repair")
        XCTAssertNotEqual(try credential(app), original)
        XCTAssertThrowsError(try share.scope())
        shareBio.onAuthenticate = nil
        _ = try await share.authorizeShare()
        _ = try share.scope()
        XCTAssertEqual(shareBio.authentications, 2)
    }

    func testSessionReplacementDuringGuardCreationRemovesUncommittedGuard() throws {
        let bio = authenticator(), app = broker(biometrics: bio)
        try prepare(app)
        let replacement = tokens("new-session", sessionID: UUID().uuidString.lowercased())
        bio.onCreate = {
            try app.withLock { locked in
                var next = MessagingProcessBroker.Authority.revoked
                next.session = replacement
                try locked.saveAuthorityLocked(next)
                try locked.saveRecordLocked(.init(generation: next.generation, accountID: self.account, crypto: .empty))
            }
        }

        XCTAssertThrowsError(try approve(app))
        let staged = try XCTUnwrap(bio.createdCredentials.last)
        XCTAssertFalse(guardBackend.isAvailable(staged))
        XCTAssertTrue(bio.removedCredentials.contains(staged))
        XCTAssertNil(try app.withLock { try $0.authorityLocked()?.biometricCredential })
        XCTAssertEqual(try app.withLock { try $0.authorityLocked()?.session }, replacement)
        XCTAssertThrowsError(try app.scope())
    }

    func testLogoutDuringGuardCreationRemovesUncommittedGuard() throws {
        let bio = authenticator(), app = broker(biometrics: bio)
        try prepare(app)
        let binding = try app.biometricBinding(accountID: account, sessionID: session)
        bio.onCreate = {
            try app.withLock { try $0.revokeSessionLocked(generation: binding.generation) }
        }

        XCTAssertThrowsError(try approve(app))
        let staged = try XCTUnwrap(bio.createdCredentials.last)
        XCTAssertFalse(guardBackend.isAvailable(staged))
        XCTAssertTrue(bio.removedCredentials.contains(staged))
        XCTAssertNil(try app.withLock { try $0.authorityLocked()?.session })
        XCTAssertThrowsError(try broker().scope())
    }

    func testRepeatedHardDenialDuringGuardCreationRejectsApproval() throws {
        let bio = authenticator(), app = broker(biometrics: bio)
        try prepare(app)
        bio.onCreate = {
            XCTAssertEqual(try app.withLock { try $0.authorityLocked()?.sharingEnabled }, false)
            // Approval has already reserved a hard denial. This fresh denial must still fence it.
            try app.setSharingEnabled(false, accountID: self.account)
        }

        XCTAssertThrowsError(try approve(app))
        let staged = try XCTUnwrap(bio.createdCredentials.last)
        XCTAssertFalse(guardBackend.isAvailable(staged))
        XCTAssertTrue(bio.removedCredentials.contains(staged))
        XCTAssertNil(try app.withLock { try $0.authorityLocked()?.biometricCredential })
        XCTAssertThrowsError(try app.scope())
    }

    func testPrivateKeyConfirmationFailureRemovesUncommittedGuardAndKeepsDenial() async throws {
        let bio = authenticator(), app = broker(biometrics: bio)
        try prepare(app)
        XCTAssertThrowsError(try approve(app, confirmPrivateKey: {
            XCTAssertEqual(bio.creations, 1, "Confirmation must run after current-set ACL insertion")
            throw MessagingBiometricCredentialError.invalidatedCredential
        }))
        let staged = try XCTUnwrap(bio.createdCredentials.last)
        XCTAssertFalse(guardBackend.isAvailable(staged))
        XCTAssertTrue(bio.removedCredentials.contains(staged))
        XCTAssertNil(try app.withLock { try $0.authorityLocked()?.biometricCredential })
        XCTAssertThrowsError(try app.scope())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("destinations.secure").path))
        await assertShareFails(app, "Enrollment changes during insertion must preserve durable denial")
        XCTAssertEqual(bio.authentications, 0)
    }

    func testDenialDuringPrivateKeyConfirmationRejectsNewGuard() throws {
        let bio = authenticator(), app = broker(biometrics: bio)
        try prepare(app)
        XCTAssertThrowsError(try approve(app, confirmPrivateKey: {
            try app.setSharingEnabled(false, accountID: self.account)
        }))
        let staged = try XCTUnwrap(bio.createdCredentials.last)
        XCTAssertFalse(guardBackend.isAvailable(staged))
        XCTAssertTrue(bio.removedCredentials.contains(staged))
        XCTAssertNil(try app.withLock { try $0.authorityLocked()?.biometricCredential })
        XCTAssertThrowsError(try app.scope())
    }

    func testAuthorityWriteFailureAfterCreationKeepsGuardAndDurableDenial() async throws {
        let failWrites = BrokerTestClock(), bio = authenticator()
        let app = broker(biometrics: bio, check: { authority in
            if failWrites.value > 0, authority.biometricCredential != nil {
                throw CocoaError(.fileWriteNoPermission)
            }
        })
        try prepare(app)
        failWrites.value = 1
        XCTAssertThrowsError(try approve(app))
        let staged = try XCTUnwrap(bio.createdCredentials.last)
        // An uncertain authority write may have published the descriptor; do not destroy its guard.
        XCTAssertTrue(guardBackend.isAvailable(staged))
        XCTAssertFalse(bio.removedCredentials.contains(staged))
        XCTAssertEqual(try app.withLock { try $0.authorityLocked()?.sharingEnabled }, false)
        XCTAssertThrowsError(try app.scope())
        XCTAssertThrowsError(try broker().scope())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("destinations.secure").path))
        await assertShareFails(app, "An uncertain authority write must leave sharing durably denied")
        XCTAssertEqual(bio.authentications, 0)
    }

    func testReusingCredentialConfirmsPrivateKeyWithoutRotatingLease() async throws {
        let bio = authenticator(), app = broker(biometrics: bio), share = broker()
        try prepare(app, biometric: true)
        try app.suspendSharingForBiometricLock(accountID: account)
        _ = try await share.authorizeShare()
        let original = try credential(app), scope = try share.scope()
        var confirmations = 0
        try approve(app, confirmPrivateKey: { confirmations += 1 })
        XCTAssertEqual(confirmations, 1)
        XCTAssertEqual(bio.creations, 1)
        XCTAssertEqual(try credential(app), original)
        XCTAssertEqual(try share.scope(), scope)
    }

    func testCredentialReuseRechecksDenialAfterMetadataProbe() throws {
        let bio = authenticator(), app = broker(biometrics: bio)
        try prepare(app, biometric: true)
        bio.onCredentialExists = { try app.setSharingEnabled(false, accountID: self.account) }
        XCTAssertThrowsError(try approve(app))
        XCTAssertEqual(bio.creations, 1)
        XCTAssertThrowsError(try app.scope())
    }

    func testCredentialReuseRechecksDenialAfterPrivateKeyConfirmation() throws {
        let bio = authenticator(), app = broker(biometrics: bio)
        try prepare(app, biometric: true)
        XCTAssertThrowsError(try approve(app, confirmPrivateKey: {
            try app.setSharingEnabled(false, accountID: self.account)
        }))
        XCTAssertEqual(bio.creations, 1)
        XCTAssertThrowsError(try app.scope())
    }

    func testOrdinaryPublicationCannotDisableExistingBiometricRequirement() async throws {
        let app = broker()
        try prepare(app, biometric: true)
        try app.suspendSharingForBiometricLock(accountID: account)
        let original = try credential(app)
        XCTAssertThrowsError(try app.publishApprovedDestinations(
            [destination], accountID: account, requiresBiometricUnlock: false
        ))
        XCTAssertEqual(try credential(app), original)
        XCTAssertEqual(try app.withLock { try $0.authorityLocked()?.requiresBiometricUnlock }, true)
        XCTAssertThrowsError(try app.scope())
        _ = try await app.authorizeShare()
        _ = try app.scope()
    }

    func testOrdinaryPublicationCannotDisableLegacyBiometricRequirement() async throws {
        let bio = authenticator(), app = broker(biometrics: bio)
        let legacy = Data("legacy-required-enrollment".utf8)
        try prepare(app)
        try installUnapprovedBiometricAuthority(app, legacyDomain: legacy)
        XCTAssertThrowsError(try app.publishApprovedDestinations(
            [destination], accountID: account, requiresBiometricUnlock: false
        ))
        XCTAssertEqual(try app.withLock { try $0.authorityLocked()?.requiresBiometricUnlock }, true)
        XCTAssertEqual(try app.withLock { try $0.authorityLocked()?.biometricDomainState }, legacy)
        await assertShareFails(app, "A background publication must not bypass legacy biometric approval")
        XCTAssertEqual(bio.creations, 0)
        XCTAssertEqual(bio.authentications, 0)
        XCTAssertThrowsError(try app.scope())
    }

    func testExplicitBoundDisableClearsCredentialButRequiresFreshPublication() async throws {
        let app = broker(), shareBio = authenticator(), share = broker(biometrics: shareBio)
        try prepare(app, biometric: true)
        try app.suspendSharingForBiometricLock(accountID: account)
        _ = try await share.authorizeShare()
        let oldScope = try share.scope()
        let binding = try app.biometricBinding(accountID: account, sessionID: session)

        // Models an explicitly verified settings change or server-verified PIN recovery.
        try app.disableBiometricSharing(binding: binding)
        XCTAssertNil(try app.withLock { try $0.authorityLocked()?.biometricCredential })
        XCTAssertNil(try app.withLock { try $0.authorityLocked()?.biometricDomainState })
        XCTAssertEqual(try app.withLock { try $0.authorityLocked()?.requiresBiometricUnlock }, false)
        XCTAssertThrowsError(try share.snapshot(scope: oldScope))
        XCTAssertThrowsError(try share.scope())
        await assertShareFails(share, "Disabling the biometric setting must not itself publish sharing access")
        XCTAssertEqual(shareBio.authentications, 1)

        try app.publishApprovedDestinations([destination], accountID: account, requiresBiometricUnlock: false)
        try app.setSharingEnabled(true, accountID: account)
        _ = try await share.authorizeShare()
        XCTAssertNotEqual(try share.scope(), oldScope)
        XCTAssertEqual(shareBio.authentications, 1)
    }

    func testStaleBindingCannotDisableSuccessorSessionBiometrics() async throws {
        let app = broker()
        try prepare(app, biometric: true)
        let stale = try app.biometricBinding(accountID: account, sessionID: session)
        let replacement = tokens("successor", sessionID: UUID().uuidString.lowercased())
        let sessionStore = SessionStore(account: "disable-successor", messagingBroker: app)
        try await sessionStore.save(replacement)
        XCTAssertNil(try app.withLock { try $0.authorityLocked()?.biometricCredential })
        let binding = try app.biometricBinding(accountID: account, sessionID: replacement.sessionId)
        try app.approveBiometricSharing(
            binding: binding, enrollmentKeyID: enrollmentKeyID, confirmPrivateKey: {}
        )
        let successorCredential = try credential(app)

        XCTAssertThrowsError(try app.disableBiometricSharing(binding: stale))
        XCTAssertEqual(try credential(app), successorCredential)
        XCTAssertEqual(try app.withLock { try $0.authorityLocked()?.requiresBiometricUnlock }, true)
        XCTAssertEqual(try app.withLock { try $0.authorityLocked()?.session }, replacement)
    }

    func testExplicitDisableWriteFailureKeepsDurableDenial() async throws {
        let failWrites = BrokerTestClock(), bio = authenticator()
        let app = broker(biometrics: bio, check: { _ in
            if failWrites.value > 0 { throw CocoaError(.fileWriteNoPermission) }
        })
        try prepare(app, biometric: true)
        let oldScope = try app.scope()
        let binding = try app.biometricBinding(accountID: account, sessionID: session)
        failWrites.value = 1

        XCTAssertThrowsError(try app.disableBiometricSharing(binding: binding))
        XCTAssertThrowsError(try app.snapshot(scope: oldScope))
        XCTAssertThrowsError(try broker().scope())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("destinations.secure").path))
        await assertShareFails(app, "A failed settings write must preserve durable denial")
        XCTAssertEqual(bio.authentications, 0)
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
