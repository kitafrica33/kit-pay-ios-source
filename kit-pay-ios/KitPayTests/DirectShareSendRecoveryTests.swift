import CryptoKit
import XCTest
@testable import KitPay

final class DirectShareSendRecoveryTests: XCTestCase {
    private let account = "10000000-0000-4000-8000-000000000001"
    private let session = "20000000-0000-4000-8000-000000000002"
    private let conversation = "30000000-0000-4000-8000-000000000003"
    private let recipient = "40000000-0000-4000-8000-000000000004"
    private let device = "50000000-0000-4000-8000-000000000005"
    private var root: URL!
    private let key = Data(repeating: 0x51, count: 32)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private var destination: SharedInboxDestination {
        .init(conversationID: conversation, recipientUserID: recipient,
              displayName: "Recipient", kind: .direct, memberCount: nil)
    }
    private var enrollment: SecureMessagingEnrollmentBinding {
        .init(userID: account, serverDeviceID: device, signalDeviceID: 1,
              registrationID: 42, enrollmentEpoch: 1, identityKeySHA256: String(repeating: "a", count: 64),
              bundleVersion: 1, signedPreKeyID: 5, signedPreKeySHA256: String(repeating: "b", count: 64),
              pqLastResortPreKeyID: 6, pqLastResortPreKeySHA256: String(repeating: "c", count: 64))
    }
    private func broker(check: (() throws -> Void)? = nil) -> MessagingProcessBroker {
        MessagingProcessBroker(rootURL: root.appendingPathComponent("broker"), key: key,
                               recordCommitCheck: check)
    }
    private func prepare(_ broker: MessagingProcessBroker, seedCrypto: Bool = true) throws -> SecureMessagingPersistentState {
        var crypto = SecureMessagingPersistentState.empty
        crypto.enrollment = enrollment
        try broker.withLock { locked in
            var authority = MessagingProcessBroker.Authority.revoked
            authority.allowsLegacyMessagingImport = true
            authority.session = SessionTokens(accessToken: "access", refreshToken: "refresh", tokenType: "Bearer",
                                              accessExpiresAt: nil, refreshExpiresAt: nil,
                                              sessionId: session, accountId: account)
            try locked.saveAuthorityLocked(authority)
            if seedCrypto { try locked.saveRecordLocked(.init(generation: authority.generation, accountID: account, crypto: crypto)) }
        }
        try broker.publishApprovedDestinations([destination], accountID: account, requiresBiometricUnlock: false)
        try broker.setSharingEnabled(true, accountID: account)
        return crypto
    }
    private func privateState(crypto: SecureMessagingPersistentState) -> PersistedState {
        var state = PersistedState.empty
        state.profile = UserProfile(id: account, name: "Private wallet owner", email: nil, phone: "+256700000001",
                                    tag: nil, kycStatus: "verified", paymentPinSet: true, mfaEnabled: true,
                                    profileSetupRequired: false)
        state.communicationOwnerUserID = account
        state.secureMessaging = crypto
        state.messages = [LocalMessage(id: UUID(), conversationId: conversation, senderId: account,
                                       body: "before committed journal", createdAt: Date(), sentAt: nil,
                                       state: .queued, failureReason: nil, isOutgoing: true)]
        return state
    }
    private func store(_ broker: MessagingProcessBroker) -> SecureLocalStore {
        SecureLocalStore(stateURL: root.appendingPathComponent("state.secure"),
                         keyData: Data(repeating: 0x92, count: 32), messagingBroker: broker)
    }

    func testWalletOnlyUpdateAdoptsExtensionCryptoAndStaleInboundCannotOverwriteIt() async throws {
        let appBroker = broker(), sibling = broker()
        let initial = try prepare(appBroker, seedCrypto: false)
        let local = store(appBroker)
        try await local.replace(privateState(crypto: initial))
        let baseline = await local.snapshot().secureMessaging
        let scope = try sibling.scope()
        try sibling.updateOutgoing(scope: scope) { $0.crypto?.syncCursor = "extension-ratchet-advance" }
        try await local.update { $0.selectedWalletId = "selected-wallet" }
        let walletUpdate = await local.snapshot()
        XCTAssertEqual(walletUpdate.selectedWalletId, "selected-wallet")
        XCTAssertEqual(walletUpdate.secureMessaging?.syncCursor, "extension-ratchet-advance")
        do {
            try await local.commitSecureMessaging(forUserID: account, expectedState: baseline, nextState: initial)
            XCTFail("Stale inbound decryption must fail CAS")
        } catch let error as SecureMessagingCryptoError { XCTAssertEqual(error, .staleState) }
        XCTAssertEqual(try sibling.snapshot(scope: scope).crypto?.syncCursor, "extension-ratchet-advance")
    }

    func testFailureAfterSharedReplacementRetainsAndRecoversPrivateJournal() async throws {
        let fault = DirectShareWriteFault(), appBroker = broker(check: { try fault.check() })
        let initial = try prepare(appBroker, seedCrypto: false), local = store(appBroker)
        try await local.replace(privateState(crypto: initial))
        let expected = await local.snapshot().secureMessaging
        var next = try XCTUnwrap(expected)
        next.syncCursor = "committed-shared-before-private-move"
        fault.enabled = true
        do {
            try await local.commitSecureMessaging(forUserID: account, expectedState: expected, nextState: next) {
                $0.messages[0].body = "after committed journal"
            }
            XCTFail("Injected post-replacement failure must be reported")
        } catch {}
        fault.enabled = false
        let journalFiles = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "journal" }
        XCTAssertEqual(journalFiles.count, 1, "An uncertain shared commit must retain its private WAL")
        let reopened = store(broker())
        let restored = await reopened.snapshot()
        XCTAssertEqual(restored.messages.first?.body, "after committed journal")
        XCTAssertEqual(restored.secureMessaging?.syncCursor, "committed-shared-before-private-move")
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalFiles[0].path))
    }

    func testRevocationBeforePrivateRecoveryPreservesCommittedHistory() async throws {
        let fault = DirectShareWriteFault(), appBroker = broker(check: { try fault.check() })
        let initial = try prepare(appBroker, seedCrypto: false), local = store(appBroker)
        try await local.replace(privateState(crypto: initial))
        let expected = await local.snapshot().secureMessaging
        var next = try XCTUnwrap(expected)
        next.syncCursor = "committed-before-signout"
        fault.enabled = true
        do {
            try await local.commitSecureMessaging(forUserID: account, expectedState: expected, nextState: next) {
                $0.messages[0].body = "history committed before signout"
            }
        } catch {}
        fault.enabled = false
        let sessions = SessionStore(account: "direct-share-test-session", messagingBroker: appBroker)
        try await sessions.clear()
        try await local.clearFinancialAndSessionProjections(preserveCommunicationHistory: true)
        let cleared = await local.snapshot()
        XCTAssertNil(cleared.profile)
        XCTAssertEqual(cleared.messages.first?.body, "history committed before signout")
        XCTAssertNil(try appBroker.withLock { try $0.recordLocked() })
    }

    func testSameAccountLogoutCrashAndReloginCannotRestoreOldRatchetsOrQueue() async throws {
        let appBroker = broker(), initial = try prepare(appBroker, seedCrypto: false)
        let local = store(appBroker)
        var state = privateState(crypto: initial)
        state.outbox = [OfflineCommand(id: UUID(), kind: .secureMessage, createdAt: Date(),
                                      nextAttemptAt: Date(), attemptCount: 0, conversationId: conversation,
                                      messageId: state.messages[0].id, recipientUserIds: [recipient],
                                      recipientName: "Recipient", video: nil, expiresAt: nil)]
        try await local.replace(state)
        let oldGeneration = try appBroker.scope().generation
        let sessions = SessionStore(account: "crashed-private-clear", messagingBroker: appBroker)
        try await sessions.clear()
        // Simulate death before clearFinancialAndSessionProjections, then a fresh same-account login.
        try await sessions.save(SessionTokens(accessToken: "new-access", refreshToken: "new-refresh", tokenType: "Bearer",
                                              accessExpiresAt: nil, refreshExpiresAt: nil,
                                              sessionId: UUID().uuidString.lowercased(), accountId: account))
        let reopened = store(broker())
        let restored = await reopened.snapshot()
        XCTAssertNotEqual(restored.messagingBrokerGeneration, oldGeneration)
        XCTAssertNil(restored.secureMessaging)
        XCTAssertTrue(restored.outbox.isEmpty)
        XCTAssertEqual(restored.messages.first?.body, "before committed journal")
        XCTAssertEqual(restored.messages.first?.state, .failed)
        XCTAssertNil(try appBroker.withLock { try $0.recordLocked()?.crypto })
    }

    func testUnboundLegacySnapshotCannotCrossRevocationAndReplacement() async throws {
        let appBroker = broker(), initial = try prepare(appBroker, seedCrypto: false)
        let legacy = privateState(crypto: initial)
        let privateOnly = SecureLocalStore(stateURL: root.appendingPathComponent("state.secure"),
                                           keyData: Data(repeating: 0x92, count: 32))
        try await privateOnly.replace(legacy)
        let sessions = SessionStore(account: "legacy-before-migration", messagingBroker: appBroker)
        try await sessions.clear()
        try await sessions.save(SessionTokens(accessToken: "new-access", refreshToken: "new-refresh", tokenType: "Bearer",
                                              accessExpiresAt: nil, refreshExpiresAt: nil,
                                              sessionId: UUID().uuidString.lowercased(), accountId: account))
        let reopened = store(broker())
        let safe = await reopened.snapshot()
        XCTAssertNil(safe.secureMessaging)
        XCTAssertEqual(safe.messages.first?.state, .failed)
        do { try await reopened.replace(legacy); XCTFail("Stale unbound snapshot must not reintroduce old crypto") }
        catch {}
        let afterRejectedReplace = await reopened.snapshot()
        XCTAssertNil(afterRejectedReplace.secureMessaging)
    }

    func testFirstMigrationImportsLegacyOnlyForItsApprovedCredentialGeneration() async throws {
        let appBroker = broker(), initial = try prepare(appBroker, seedCrypto: false)
        let privateOnly = SecureLocalStore(stateURL: root.appendingPathComponent("state.secure"),
                                           keyData: Data(repeating: 0x92, count: 32))
        try await privateOnly.replace(privateState(crypto: initial))
        let reopened = store(appBroker), migrated = await reopened.snapshot()
        XCTAssertEqual(migrated.secureMessaging, initial)
        XCTAssertNotNil(migrated.messagingBrokerGeneration)
    }

    private func confirmedSend(
        scope: MessagingProcessBroker.Scope, withMedia: Bool = false
    ) throws -> DirectShareSendRecord {
        let id = UUID(), mediaID = UUID(), storageKey = UUID().uuidString.lowercased()
        let media: [DirectShareSendRecord.Media] = withMedia ? [.init(
            item: .init(id: mediaID, fileName: "\(mediaID.uuidString).jpg", mediaType: "image/jpeg",
                        displayName: "Photo", byteCount: 100),
            keyMaterial: Data(repeating: 0x21, count: 64), ciphertextBytes: 160,
            ciphertextSHA256: String(repeating: "f", count: 64), storageKey: storageKey
        )] : []
        let body = withMedia ? try KitMediaMessageDescriptor(
            attachmentID: mediaID.uuidString.lowercased(), storageKey: storageKey,
            mediaType: "image/jpeg", ciphertextByteSize: 160,
            ciphertextSHA256: String(repeating: "f", count: 64),
            keyMaterial: Data(repeating: 0x21, count: 64), plaintextByteSize: 100,
            caption: "Confirmed photo"
        ).encoded : "Confirmed text"
        return DirectShareSendRecord(
            id: id, generation: scope.generation, accountID: account, sessionID: session,
            destination: destination, createdAt: Date(), text: "Confirmed share", media: media,
            conversation: .init(id: conversation, recipientUserID: recipient,
                                memberUserIDs: [account, recipient], title: "Recipient", updatedAt: Date(),
                                conversationType: SecureMessagingWire.directConversationType,
                                groupMemberRoles: nil, groupDescription: nil, groupPhotoURL: nil, memberIdentities: nil),
            body: body,
            fanout: .init(clientMessageID: id.uuidString.lowercased(), conversationID: conversation,
                          rosterRevision: "v1:sha256:" + String(repeating: "d", count: 64),
                          replyToMessageID: nil, rosterDevices: [], envelopes: []),
            wireRequest: Data("exact accepted request".utf8), enrollment: enrollment,
            serverMessageID: UUID().uuidString.lowercased(), sentAt: Date()
        )
    }

    private func importConfirmedSend(
        _ appBroker: MessagingProcessBroker, withMedia: Bool = false
    ) async throws -> (SecureLocalStore, DirectShareSendRecord, MessagingProcessBroker.Scope) {
        let initial = try prepare(appBroker, seedCrypto: false), local = store(appBroker)
        try await local.replace(privateState(crypto: initial))
        let scope = try appBroker.scope()
        var send = try confirmedSend(scope: scope, withMedia: withMedia)
        if withMedia { send.localMediaImported = true }
        try appBroker.updateOutgoing(scope: scope) { $0.outgoing = [send] }
        try await local.update { _ in }
        return (local, send, scope)
    }

    func testImportedCompletionSucceedsWithoutNetworkOrCryptoWork() async throws {
        let appBroker = broker(), (local, send, scope) = try await importConfirmedSend(appBroker)
        let imported = try appBroker.snapshot(scope: scope)
        XCTAssertTrue(imported.outgoing.isEmpty)
        XCTAssertEqual(imported.completionReceipts?.map(\.id), [send.id])
        XCTAssertTrue(try appBroker.containsEnqueued(id: send.id, inputSHA256: send.inputFingerprint(), scope: scope))
        let transport = DirectShareUncertainTransport(enrollment: enrollment)
        try await DirectShareSendCoordinator(broker: broker(), transport: transport).send(id: send.id, expectedScope: scope)
        let networkCount = await transport.networkCount()
        XCTAssertEqual(networkCount, 0)
        XCTAssertEqual(try appBroker.snapshot(scope: scope).crypto, imported.crypto)
        let privateSnapshot = await local.snapshot()
        XCTAssertEqual(privateSnapshot.messages.first { $0.id == send.id }?.state, .sent)
    }

    func testImportedMediaEnqueueRetryRecognizesExactInputAfterStagingWasDeleted() async throws {
        let appBroker = broker(), (_, send, scope) = try await importConfirmedSend(appBroker, withMedia: true)
        let media = try XCTUnwrap(send.media.first)
        XCTAssertThrowsError(try DirectShareSendRecord.stagingStore.fileURL(for: media.item, in: send.id))
        let before = try appBroker.snapshot(scope: scope)
        let transport = DirectShareUncertainTransport(enrollment: enrollment)
        let coordinator = DirectShareSendCoordinator(broker: broker(), transport: transport)
        try await coordinator.enqueue(id: send.id, ownerAccountID: account, destination: send.destination,
                                      items: send.media.map(\.item), text: send.text, expectedScope: scope)
        try await coordinator.send(id: send.id, expectedScope: scope)
        let after = try appBroker.snapshot(scope: scope), networkCount = await transport.networkCount()
        XCTAssertEqual(networkCount, 0)
        XCTAssertTrue(after.outgoing.isEmpty)
        XCTAssertEqual(after.crypto, before.crypto)
        XCTAssertEqual(after.completionReceipts, before.completionReceipts)
    }

    func testImportedInputStillResolvesAfterRecipientDirectoryChanges() async throws {
        let appBroker = broker(), (_, send, scope) = try await importConfirmedSend(appBroker)
        try appBroker.publishApprovedDestinations([], accountID: account, requiresBiometricUnlock: false)
        let transport = DirectShareUncertainTransport(enrollment: enrollment)
        let coordinator = DirectShareSendCoordinator(broker: appBroker, transport: transport)
        try await coordinator.enqueue(id: send.id, ownerAccountID: account, destination: send.destination,
                                      items: [], text: send.text, expectedScope: scope)
        try await coordinator.send(id: send.id, expectedScope: scope)
        let count = await transport.networkCount()
        XCTAssertEqual(count, 0)
        do {
            try await coordinator.enqueue(id: UUID(), ownerAccountID: account, destination: send.destination,
                                          items: [], text: send.text, expectedScope: scope)
            XCTFail("A new enqueue still requires an approved destination")
        } catch {}
    }

    func testCompletionRejectsChangedPayloadUnderSameID() async throws {
        let appBroker = broker(), (_, send, scope) = try await importConfirmedSend(appBroker)
        let changed = try DirectShareSendRecord.inputFingerprint(destination: send.destination, items: [], text: "Different message")
        XCTAssertThrowsError(try appBroker.containsEnqueued(id: send.id, inputSHA256: changed, scope: scope))
        let coordinator = DirectShareSendCoordinator(broker: appBroker, transport: DirectShareUncertainTransport(enrollment: enrollment))
        do {
            try await coordinator.enqueue(id: send.id, ownerAccountID: account, destination: send.destination,
                                          items: [], text: "Different message", expectedScope: scope)
            XCTFail("Changed input cannot inherit an earlier send's confirmation")
        } catch {}
        XCTAssertTrue(try appBroker.snapshot(scope: scope).outgoing.isEmpty)
        XCTAssertEqual(try appBroker.snapshot(scope: scope).completionReceipts?.first?.inputSHA256, try send.inputFingerprint())
    }

    func testCompletionCannotCrossSessionAccountOrGenerationReplacement() async throws {
        let appBroker = broker(), (_, send, scope) = try await importConfirmedSend(appBroker)
        try appBroker.withLock { locked in
            var authority = try XCTUnwrap(locked.authorityLocked())
            authority.session = SessionTokens(accessToken: "replacement", refreshToken: "replacement", tokenType: "Bearer",
                accessExpiresAt: nil, refreshExpiresAt: nil, sessionId: UUID().uuidString.lowercased(), accountId: account)
            try locked.saveAuthorityLocked(authority)
        }
        let changedSession = try appBroker.scope()
        XCTAssertThrowsError(try appBroker.isConfirmed(id: send.id, scope: scope))
        XCTAssertFalse(try appBroker.isConfirmed(id: send.id, scope: changedSession))
        XCTAssertThrowsError(try appBroker.containsEnqueued(id: send.id, inputSHA256: send.inputFingerprint(), scope: changedSession))
        let transport = DirectShareUncertainTransport(enrollment: enrollment)
        let coordinator = DirectShareSendCoordinator(broker: appBroker, transport: transport)
        do {
            try await coordinator.enqueue(id: UUID(), ownerAccountID: account, destination: destination,
                                          items: [], text: "Cannot adopt replacement", expectedScope: scope)
            XCTFail("The actor must honor the pre-hop scope")
        } catch {}
        do { try await coordinator.send(id: send.id, expectedScope: scope); XCTFail("Old scope") } catch {}
        try appBroker.withLock { locked in
            var authority = try XCTUnwrap(locked.authorityLocked())
            authority.session = SessionTokens(accessToken: "other", refreshToken: "other", tokenType: "Bearer",
                accessExpiresAt: nil, refreshExpiresAt: nil, sessionId: changedSession.sessionID, accountId: recipient)
            try locked.saveAuthorityLocked(authority)
        }
        XCTAssertThrowsError(try appBroker.isConfirmed(id: send.id, scope: appBroker.scope()))
        _ = try prepare(appBroker)
        let replacement = try appBroker.scope()
        XCTAssertNotEqual(replacement.generation, scope.generation)
        XCTAssertFalse(try appBroker.isConfirmed(id: send.id, scope: replacement))
        let count = await transport.networkCount()
        XCTAssertEqual(count, 0)
    }

    func testCompletionReceiptRetainsPrivateWALWhenImportCommitIsUncertain() async throws {
        let fault = DirectShareWriteFault(), appBroker = broker(check: { try fault.check() })
        let initial = try prepare(appBroker, seedCrypto: false), local = store(appBroker)
        try await local.replace(privateState(crypto: initial))
        let scope = try appBroker.scope(), send = try confirmedSend(scope: scope)
        try appBroker.updateOutgoing(scope: scope) { $0.outgoing = [send] }
        fault.enabled = true
        do { try await local.update { _ in }; XCTFail("Post-replacement failure") } catch {}
        fault.enabled = false
        XCTAssertTrue(try broker().isConfirmed(id: send.id, scope: scope))
        XCTAssertTrue(try broker().snapshot(scope: scope).outgoing.isEmpty)
        let restored = await store(broker()).snapshot()
        XCTAssertEqual(restored.messages.first { $0.id == send.id }?.body, send.body)
        XCTAssertEqual(restored.messages.first { $0.id == send.id }?.state, .sent)
    }

    func testCompletionReceiptsRemainBoundedAndRejectMalformedDecodeOrSave() async throws {
        let appBroker = broker(), (local, _, scope) = try await importConfirmedSend(appBroker)
        var latestID: UUID?
        for _ in 0 ..< 9 {
            let completed = try (0 ..< 16).map { _ in try confirmedSend(scope: scope) }
            latestID = completed.last?.id
            try appBroker.updateOutgoing(scope: scope) { $0.outgoing = completed }
            try await local.update { _ in }
        }
        let record = try appBroker.snapshot(scope: scope)
        XCTAssertEqual(record.completionReceipts?.count, DirectShareSendRecord.maximumCompletionReceipts)
        XCTAssertEqual(record.completionReceipts?.last?.id, latestID)
        var malformed = record
        malformed.completionReceipts?.append(try XCTUnwrap(record.completionReceipts?.first))
        XCTAssertThrowsError(try appBroker.withLock { try $0.saveRecordLocked(malformed) })
        XCTAssertThrowsError(try JSONDecoder().decode(MessagingProcessBroker.Record.self, from: JSONEncoder().encode(malformed)))
        var duplicate = record
        duplicate.completionReceipts = Array(repeating: try XCTUnwrap(record.completionReceipts?.first), count: 2)
        XCTAssertThrowsError(try appBroker.withLock { try $0.saveRecordLocked(duplicate) })
        XCTAssertThrowsError(try JSONDecoder().decode(MessagingProcessBroker.Record.self, from: JSONEncoder().encode(duplicate)))
        var wrongGeneration = record
        wrongGeneration.generation = UUID()
        XCTAssertThrowsError(try appBroker.withLock { try $0.saveRecordLocked(wrongGeneration) })
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        var receipts = try XCTUnwrap(object["completionReceipts"] as? [[String: Any]])
        receipts[0]["inputSHA256"] = Data([1]).base64EncodedString()
        object["completionReceipts"] = receipts
        XCTAssertThrowsError(try JSONDecoder().decode(MessagingProcessBroker.Record.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    func testConfirmedTextAndMediaSurviveLogoutBeforePrivateImport() async throws {
        let appBroker = broker(), initial = try prepare(appBroker, seedCrypto: false), local = store(appBroker)
        try await local.replace(privateState(crypto: initial))
        let scope = try appBroker.scope()
        let sends = try [confirmedSend(scope: scope), confirmedSend(scope: scope, withMedia: true)]
        try appBroker.updateOutgoing(scope: scope) { $0.outgoing = sends }
        let sessions = SessionStore(account: "confirmed-history-logout", messagingBroker: appBroker)
        try await sessions.clear()
        let retained = try appBroker.withLock { try $0.retiredHistoryLocked(accountID: account) }
        XCTAssertEqual(retained.count, 2)
        XCTAssertTrue(retained.allSatisfy { $0.fanout == nil && $0.wireRequest == nil && $0.enrollment == nil && $0.media.isEmpty })
        try await local.clearFinancialAndSessionProjections(preserveCommunicationHistory: true)
        let restored = await store(broker()).snapshot()
        XCTAssertNil(restored.profile)
        XCTAssertNil(restored.secureMessaging)
        XCTAssertTrue(restored.outbox.isEmpty)
        for send in sends {
            let message = try XCTUnwrap(restored.messages.first { $0.id == send.id })
            XCTAssertEqual(message.body, send.body)
            XCTAssertEqual(message.state, .sent)
            XCTAssertEqual(message.serverMessageId, send.serverMessageID)
        }
        XCTAssertTrue(try appBroker.withLock { try $0.retiredHistoryLocked(accountID: account) }.isEmpty)
    }

    func testFailedRetiredHistoryImportRetainsReceiptUntilSuccessfulReopen() async throws {
        let appBroker = broker(), initial = try prepare(appBroker, seedCrypto: false), local = store(appBroker)
        try await local.replace(privateState(crypto: initial))
        let scope = try appBroker.scope(), send = try confirmedSend(scope: scope)
        try appBroker.updateOutgoing(scope: scope) { $0.outgoing = [send] }
        try await SessionStore(account: "confirmed-history-failure", messagingBroker: appBroker).clear()
        let failing = SecureLocalStore(
            stateURL: root.appendingPathComponent("state.secure"), keyData: Data(repeating: 0x92, count: 32),
            stateDataPersist: { _, _ in throw CocoaError(.fileWriteNoPermission) }, messagingBroker: broker()
        )
        let readiness = await failing.prepareForRestore()
        XCTAssertEqual(readiness, .temporarilyUnavailable)
        XCTAssertEqual(try appBroker.withLock { try $0.retiredHistoryLocked(accountID: account) }.map(\.id), [send.id])
        let restored = await store(broker()).snapshot()
        XCTAssertEqual(restored.messages.first { $0.id == send.id }?.body, send.body)
        XCTAssertTrue(try appBroker.withLock { try $0.retiredHistoryLocked(accountID: account) }.isEmpty)
    }

    func testOtherOwnerCannotImportOrConsumeRetiredHistory() async throws {
        let appBroker = broker(), initial = try prepare(appBroker, seedCrypto: false), local = store(appBroker)
        try await local.replace(privateState(crypto: initial))
        let scope = try appBroker.scope(), send = try confirmedSend(scope: scope)
        try appBroker.updateOutgoing(scope: scope) { $0.outgoing = [send] }
        try await SessionStore(account: "confirmed-history-owner", messagingBroker: appBroker).clear()
        let otherURL = root.appendingPathComponent("other-state.secure")
        var otherState = PersistedState.empty
        otherState.communicationOwnerUserID = recipient
        let otherPrivate = SecureLocalStore(stateURL: otherURL, keyData: Data(repeating: 0x92, count: 32))
        try await otherPrivate.replace(otherState)
        let other = SecureLocalStore(stateURL: otherURL, keyData: Data(repeating: 0x92, count: 32), messagingBroker: broker())
        let otherSnapshot = await other.snapshot()
        XCTAssertTrue(otherSnapshot.messages.isEmpty)
        XCTAssertEqual(try appBroker.withLock { try $0.retiredHistoryLocked(accountID: account) }.map(\.id), [send.id])
        let restored = await local.snapshot()
        XCTAssertEqual(restored.messages.first { $0.id == send.id }?.state, .sent)
    }

    func testAcceptedDeletionDoesNotPreserveConfirmedShares() async throws {
        let appBroker = broker(), initial = try prepare(appBroker, seedCrypto: false), local = store(appBroker)
        try await local.replace(privateState(crypto: initial))
        let scope = try appBroker.scope(), send = try confirmedSend(scope: scope, withMedia: true)
        try appBroker.updateOutgoing(scope: scope) { $0.outgoing = [send] }
        let sessions = SessionStore(account: "confirmed-history-delete", messagingBroker: appBroker)
        let result = try await sessions.clearAcceptedDeletionTarget(accountID: account, sessionID: session)
        XCTAssertEqual(result, .cleared)
        XCTAssertNil(try appBroker.withLock { try $0.recordLocked() })
        XCTAssertNil(try appBroker.withLock { try $0.privateReceiptLocked(accountID: account) })
        XCTAssertTrue(try appBroker.withLock { try $0.retiredHistoryLocked(accountID: account) }.isEmpty)
        try await local.clearFinancialAndSessionProjections(preserveCommunicationHistory: false)
        let restored = await store(broker()).snapshot()
        XCTAssertTrue(restored.messages.isEmpty)
    }

    func testAcceptedDeletionRetriesRetainedFileCleanupAfterSessionAlreadyRevoked() async throws {
        let fault = DirectShareWriteFault()
        let appBroker = MessagingProcessBroker(
            rootURL: root.appendingPathComponent("broker"), key: key,
            fileRemovalCheck: { name in if name.hasPrefix("confirmed-history-") { try fault.check() } }
        )
        _ = try prepare(appBroker)
        let scope = try appBroker.scope(), send = try confirmedSend(scope: scope)
        try appBroker.updateOutgoing(scope: scope) { $0.outgoing = [send]; $0.privateTransactionID = UUID() }
        let sessions = SessionStore(account: "confirmed-history-delete-retry", messagingBroker: appBroker)
        try await sessions.clear()
        XCTAssertEqual(try appBroker.withLock { try $0.retiredHistoryLocked(accountID: account) }.map(\.id), [send.id])
        XCTAssertNotNil(try appBroker.withLock { try $0.privateReceiptLocked(accountID: account) })
        // A fresh login can be deleted before its older confirmed history was imported.
        _ = try prepare(appBroker)
        fault.enabled = true
        do {
            _ = try await sessions.clearAcceptedDeletionTarget(accountID: account, sessionID: session)
            XCTFail("Injected removal failure")
        } catch {}
        let absent = try await sessions.acceptedDeletionDisposition(accountID: account, sessionID: session)
        XCTAssertEqual(absent, .alreadyAbsent)
        XCTAssertNotNil(try appBroker.withLock { try $0.recordLocked() })
        fault.enabled = false
        let retried = try await sessions.clearAcceptedDeletionTarget(accountID: account, sessionID: session)
        XCTAssertEqual(retried, .alreadyAbsent)
        XCTAssertNil(try appBroker.withLock { try $0.recordLocked() })
        XCTAssertNil(try appBroker.withLock { try $0.privateReceiptLocked(accountID: account) })
        XCTAssertTrue(try appBroker.withLock { try $0.retiredHistoryLocked(accountID: account) }.isEmpty)
    }

    private func sealedPending(
        _ appBroker: MessagingProcessBroker, withMedia: Bool = false, prepareStore: Bool = true
    ) throws -> (UUID, Data, MessagingProcessBroker.Scope) {
        if prepareStore { _ = try prepare(appBroker) }
        let scope = try appBroker.scope(), id = UUID()
        let fanout = SecureMessagingCommittedFanout(clientMessageID: id.uuidString.lowercased(), conversationID: conversation,
            rosterRevision: "v1:sha256:" + String(repeating: "d", count: 64), replyToMessageID: nil,
            rosterDevices: [], envelopes: [])
        let bytes = Data("exact previously persisted Signal request".utf8)
        let media: [DirectShareSendRecord.Media] = withMedia ? [.init(
            item: SharedInboxItem(id: UUID(), fileName: "attachment.jpg", mediaType: "image/jpeg",
                                  displayName: "Attachment", byteCount: 100), keyMaterial: Data(repeating: 0x21, count: 64),
            ciphertextBytes: 160, ciphertextSHA256: String(repeating: "f", count: 64), storageKey: UUID().uuidString.lowercased()
        )] : []
        try appBroker.updateOutgoing(scope: scope) { record in
            record.outgoing.append(.init(id: id, generation: scope.generation, accountID: account, sessionID: session,
                                         destination: destination, createdAt: Date(), text: "Message", media: media,
                                         conversation: try confirmedSend(scope: scope).conversation,
                                         body: "Message", fanout: fanout, wireRequest: bytes, enrollment: enrollment))
        }
        return (id, bytes, scope)
    }

    func testMismatchedSuccessReceiptKeepsJournalAndCannotMarkSent() async throws {
        let appBroker = broker(), (id, bytes, scope) = try sealedPending(appBroker)
        let transport = DirectShareUncertainTransport(enrollment: enrollment, outcome: .mismatchedReceipt)
        do { try await DirectShareSendCoordinator(broker: appBroker, transport: transport).send(id: id); XCTFail("Wrong echo") }
        catch {}
        let record = try XCTUnwrap(appBroker.snapshot(scope: scope).outgoing.first)
        XCTAssertEqual(record.wireRequest, bytes)
        XCTAssertFalse(record.isComplete)
    }

    func testDefinitiveRosterRejectionPreservesUploadedMediaAndCrypto() async throws {
        let appBroker = broker(), (id, _, scope) = try sealedPending(appBroker, withMedia: true)
        let before = try appBroker.snapshot(scope: scope)
        let transport = DirectShareUncertainTransport(enrollment: enrollment, outcome: .rejection("MESSAGING_ROSTER_CHANGED"))
        do { try await DirectShareSendCoordinator(broker: appBroker, transport: transport).send(id: id) } catch {}
        let after = try appBroker.snapshot(scope: scope), record = try XCTUnwrap(after.outgoing.first)
        XCTAssertNil(record.fanout)
        XCTAssertNil(record.wireRequest)
        XCTAssertEqual(record.media.first?.storageKey, before.outgoing.first?.media.first?.storageKey)
        XCTAssertEqual(record.media.first?.ciphertextSHA256, before.outgoing.first?.media.first?.ciphertextSHA256)
        XCTAssertEqual(after.crypto, before.crypto)
        let uploads = await transport.uploadCount()
        XCTAssertEqual(uploads, 0)
    }

    func testLateRejectionCannotEraseSiblingConfirmedFanout() async throws {
        let appBroker = broker(), (id, bytes, scope) = try sealedPending(appBroker)
        let transport = DirectShareUncertainTransport(
            enrollment: enrollment, outcome: .rejection("MESSAGING_ROSTER_CHANGED"), beforeReply: {
                try appBroker.updateOutgoing(scope: scope) { record in
                    record.outgoing[0].serverMessageID = UUID().uuidString.lowercased()
                    record.outgoing[0].sentAt = Date()
                }
            }
        )
        do { try await DirectShareSendCoordinator(broker: appBroker, transport: transport).send(id: id) } catch {}
        let after = try XCTUnwrap(appBroker.snapshot(scope: scope).outgoing.first)
        XCTAssertTrue(after.isComplete)
        XCTAssertEqual(after.wireRequest, bytes)
        XCTAssertNotNil(after.fanout)
    }

    private func assertSiblingImportResolvesConfirmation(_ outcome: DirectShareUncertainTransport.Outcome) async throws {
            let appBroker = broker(), initial = try prepare(appBroker, seedCrypto: false), local = store(appBroker)
            try await local.replace(privateState(crypto: initial))
            let (id, bytes, scope) = try sealedPending(appBroker, prepareStore: false)
            let transport = DirectShareUncertainTransport(enrollment: enrollment, outcome: outcome, beforeReply: {
                try appBroker.updateOutgoing(scope: scope) { record in
                    record.outgoing[0].serverMessageID = UUID().uuidString.lowercased()
                    record.outgoing[0].sentAt = Date()
                }
                try await local.update { _ in }
            })
            try await DirectShareSendCoordinator(broker: appBroker, transport: transport).send(id: id, expectedScope: scope)
            let bodies = await transport.recordedBodies(), after = try appBroker.snapshot(scope: scope)
            XCTAssertEqual(bodies, [bytes])
            XCTAssertTrue(after.outgoing.isEmpty)
            XCTAssertEqual(after.completionReceipts?.last?.id, id)
            XCTAssertEqual(after.crypto, initial)
    }

    func testSiblingImportDuringTimeoutResolvesConfirmation() async throws {
        try await assertSiblingImportResolvesConfirmation(.timeout)
    }

    func testSiblingImportDuringMalformedResponseResolvesConfirmation() async throws {
        try await assertSiblingImportResolvesConfirmation(.mismatchedReceipt)
    }

    func testSiblingImportDuringRejectionUpdateResolvesConfirmation() async throws {
        try await assertSiblingImportResolvesConfirmation(.rejection("MESSAGING_ROSTER_CHANGED"))
    }

    func testUncertainPostAndProcessRestartReuseExactWireBytesWithoutCryptoAdvance() async throws {
        let appBroker = broker()
        _ = try prepare(appBroker)
        let scope = try appBroker.scope(), id = UUID()
        // This fixture represents a previously sealed request. The transport deliberately
        // never acknowledges it; cryptographic receipt acceptance is covered by mapper tests.
        let fanout = SecureMessagingCommittedFanout(
            clientMessageID: id.uuidString.lowercased(), conversationID: conversation,
            rosterRevision: "v1:sha256:" + String(repeating: "d", count: 64), replyToMessageID: nil,
            rosterDevices: [], envelopes: [.init(recipientDeviceID: recipient, envelopeType: "message", ciphertext: Data([1, 2, 3]))]
        )
        let bytes = Data("{\"exact\":\"persisted encrypted fanout\",\"attempt\":1}".utf8)
        try appBroker.updateOutgoing(scope: scope) { record in
            record.outgoing.append(.init(id: id, generation: scope.generation, accountID: account,
                                         sessionID: session, destination: destination, createdAt: Date(), text: "Message",
                                         media: [], body: "Message", fanout: fanout, wireRequest: bytes,
                                         enrollment: enrollment))
        }
        let before = try appBroker.snapshot(scope: scope).crypto
        let firstTransport = DirectShareUncertainTransport(enrollment: enrollment)
        let first = DirectShareSendCoordinator(broker: appBroker, transport: firstTransport)
        do { try await first.send(id: id); XCTFail("Timeout must not mark sent") } catch {}
        let reopened = broker(), secondTransport = DirectShareUncertainTransport(enrollment: enrollment)
        let second = DirectShareSendCoordinator(broker: reopened, transport: secondTransport)
        do { try await second.send(id: id); XCTFail("Retry is still uncertain") } catch {}
        let firstBodies = await firstTransport.recordedBodies(), secondBodies = await secondTransport.recordedBodies()
        XCTAssertEqual(firstBodies, [bytes])
        XCTAssertEqual(secondBodies, [bytes])
        let retained = try reopened.snapshot(scope: scope)
        XCTAssertEqual(retained.crypto, before)
        XCTAssertEqual(retained.outgoing.first?.wireRequest, bytes)
        XCTAssertFalse(try XCTUnwrap(retained.outgoing.first).isComplete)
    }
}

private final class DirectShareWriteFault: @unchecked Sendable {
    var enabled = false
    func check() throws { if enabled { throw CocoaError(.fileWriteUnknown) } }
}

private actor DirectShareUncertainTransport: DirectShareTransporting {
    let enrollment: SecureMessagingEnrollmentBinding
    enum Outcome { case timeout, mismatchedReceipt, rejection(String) }
    let outcome: Outcome
    let beforeReply: (() async throws -> Void)?
    var bodies: [Data] = []
    var uploads = 0
    var requests = 0
    init(enrollment: SecureMessagingEnrollmentBinding, outcome: Outcome = .timeout,
         beforeReply: (() async throws -> Void)? = nil) {
        self.enrollment = enrollment
        self.outcome = outcome
        self.beforeReply = beforeReply
    }
    func recordedBodies() -> [Data] { bodies }
    func uploadCount() -> Int { uploads }
    func networkCount() -> Int { requests + uploads }
    func capabilities(scope: MessagingProcessBroker.Scope) async throws -> DirectShareCapabilitiesDTO {
        requests += 1
        return try decode([
            "features": ["messaging": true],
            "protocols": ["messaging": ["ready": true, "version": SecureMessagingWire.protocolVersion,
                                        "suite": SecureMessagingWire.protocolSuite, "post_quantum": true]],
        ])
    }
    func send<Response: Decodable, Body: Encodable>(
        _ endpoint: MessagingAPIEndpoint, body: Body, scope: MessagingProcessBroker.Scope
    ) async throws -> Response {
        requests += 1
        guard endpoint.path == MessagingAPIEndpoint.keyStatus.path else { throw URLError(.badURL) }
        return try decode([
            "enrolled": true, "enrollment_epoch": enrollment.enrollmentEpoch,
            "device_id": enrollment.serverDeviceID, "signal_device_id": enrollment.signalDeviceID,
            "protocol_version": SecureMessagingWire.protocolVersion, "registration_id": enrollment.registrationID,
            "identity_key_sha256": enrollment.identityKeySHA256, "bundle_version": enrollment.bundleVersion,
            "signed_prekey_id": enrollment.signedPreKeyID, "signed_prekey_sha256": enrollment.signedPreKeySHA256,
            "pq_last_resort_prekey_id": enrollment.pqLastResortPreKeyID,
            "pq_last_resort_prekey_sha256": enrollment.pqLastResortPreKeySHA256,
        ])
    }
    func request<Response: Decodable>(
        _ endpoint: MessagingAPIEndpoint, body: Data?, scope: MessagingProcessBroker.Scope,
        contentType: String, headers: [String: String], allowRefresh: Bool
    ) async throws -> Response {
        requests += 1
        if let body { bodies.append(body) }
        try await beforeReply?()
        switch outcome {
        case .timeout: throw URLError(.timedOut)
        case .mismatchedReceipt:
            return try decode(["id": UUID().uuidString.lowercased(),
                               "client_message_id": UUID().uuidString.lowercased(),
                               "conversation_id": UUID().uuidString.lowercased()])
        case .rejection(let code): throw APIErrorPayload(code: code, message: "Definitive rejection", httpStatus: 409)
        }
    }
    func upload(
        ciphertextURL: URL, attachmentID: String, mediaType: String, byteSize: Int64,
        sha256: String, scope: MessagingProcessBroker.Scope, allowRefresh: Bool
    ) async throws -> MessagingAttachmentUploadDTO { uploads += 1; throw URLError(.unsupportedURL) }
    private func decode<T: Decodable>(_ value: [String: Any]) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value))
    }
}
