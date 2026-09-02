import CryptoKit
import XCTest
@testable import KitPay

final class SecureLocalStoreTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KitPayTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testEncryptedStateRoundTripsAcrossStoreInstancesWithoutPlaintextAtRest() async throws {
        let url = temporaryDirectory.appendingPathComponent("state.secure")
        let key = Data(repeating: 0xA5, count: 32)
        let expected = communicationState()
        let store = SecureLocalStore(stateURL: url, keyData: key)

        try await store.replace(expected)

        let encrypted = try Data(contentsOf: url)
        XCTAssertGreaterThan(encrypted.count, 28, "AES-GCM output must include nonce and tag")
        XCTAssertNil(encrypted.range(of: Data("persisted secret message".utf8)))
        XCTAssertNil(encrypted.range(of: Data("unfinished private draft".utf8)))
        XCTAssertNil(encrypted.range(of: Data("Private conversation".utf8)))
        XCTAssertNil(encrypted.range(of: Data("+256700000001".utf8)))
        XCTAssertNil(encrypted.range(of: Data("callHistoryBackfillReceipt".utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(PersistedState.self, from: encrypted))

        let reopened = SecureLocalStore(stateURL: url, keyData: key)
        let restored = await reopened.snapshot()
        XCTAssertEqual(restored.profile, expected.profile)
        XCTAssertEqual(restored.communicationOwnerUserID, expected.communicationOwnerUserID)
        XCTAssertEqual(restored.sessionAssurance, expected.sessionAssurance)
        XCTAssertEqual(restored.contacts, expected.contacts)
        XCTAssertEqual(restored.conversations, expected.conversations)
        XCTAssertEqual(restored.conversationDrafts, expected.conversationDrafts)
        XCTAssertEqual(restored.messages, expected.messages)
        XCTAssertEqual(restored.calls, expected.calls)
        XCTAssertEqual(restored.callHistoryBackfillReceipt, expected.callHistoryBackfillReceipt)
        XCTAssertEqual(restored.outbox, expected.outbox)
        XCTAssertEqual(restored.secureMessaging, expected.secureMessaging)
        XCTAssertEqual(
            restored.pendingProfileAvatarAttachment,
            expected.pendingProfileAvatarAttachment
        )
    }

    func testPendingProfileAvatarAttachmentRoundTripsWithoutPlaintextAtRest() async throws {
        let url = temporaryDirectory.appendingPathComponent("state.secure")
        let key = Data(repeating: 0xA6, count: 32)
        var expected = communicationState()
        let pendingAttachment = pendingAvatarAttachment()
        expected.pendingProfileAvatarAttachment = pendingAttachment
        let store = SecureLocalStore(stateURL: url, keyData: key)

        try await store.replace(expected)

        let encrypted = try Data(contentsOf: url)
        XCTAssertNil(encrypted.range(of: Data(pendingAttachment.assetID.utf8)))
        XCTAssertNil(encrypted.range(of: Data(pendingAttachment.sessionID.utf8)))
        XCTAssertNil(encrypted.range(of: Data(pendingAttachment.sourceSHA256.utf8)))

        let reopened = SecureLocalStore(stateURL: url, keyData: key)
        let restored = await reopened.snapshot()
        XCTAssertEqual(restored.pendingProfileAvatarAttachment, pendingAttachment)
        XCTAssertEqual(restored.profile, expected.profile)
    }

    func testLegacyISO8601StateStillLoadsAfterLosslessDateMigration() async throws {
        let url = temporaryDirectory.appendingPathComponent("legacy-iso8601-state.secure")
        let keyData = Data(repeating: 0xA7, count: 32)
        let expected = communicationState()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let clear = try encoder.encode(expected)
        let sealed = try AES.GCM.seal(clear, using: SymmetricKey(data: keyData))
        let combined = try XCTUnwrap(sealed.combined)
        try combined.write(to: url, options: .atomic)

        let reopened = SecureLocalStore(stateURL: url, keyData: keyData)
        let restored = await reopened.snapshot()

        XCTAssertEqual(restored.profile, expected.profile)
        XCTAssertEqual(restored.messages, expected.messages)
        XCTAssertEqual(restored.calls, expected.calls)
        XCTAssertEqual(restored.secureMessaging, expected.secureMessaging)
    }

    func testTamperedCiphertextFailsClosedWithoutReturningPartialHistory() async throws {
        let url = temporaryDirectory.appendingPathComponent("state.secure")
        let key = Data(repeating: 0x3C, count: 32)
        let store = SecureLocalStore(stateURL: url, keyData: key)
        try await store.replace(communicationState())

        var encrypted = try Data(contentsOf: url)
        let last = encrypted.index(before: encrypted.endIndex)
        encrypted[last] = encrypted[last] ^ 0x01
        try encrypted.write(to: url, options: .atomic)

        let reopened = SecureLocalStore(stateURL: url, keyData: key)
        assertEmpty(await reopened.snapshot())
    }

    func testCiphertextCannotBeRestoredWithAnotherKey() async throws {
        let url = temporaryDirectory.appendingPathComponent("state.secure")
        let writer = SecureLocalStore(
            stateURL: url,
            keyData: Data(repeating: 0x11, count: 32)
        )
        try await writer.replace(communicationState())

        let wrongKeyReader = SecureLocalStore(
            stateURL: url,
            keyData: Data(repeating: 0x22, count: 32)
        )
        let readiness = await wrongKeyReader.prepareForRestore()
        XCTAssertEqual(readiness, .invalid)
        assertEmpty(await wrongKeyReader.snapshot())
        let originalCiphertext = try Data(contentsOf: url)
        do {
            _ = try await wrongKeyReader.purgeAcceptedAccountDeletion(
                accountID: "current-user"
            )
            XCTFail("An unreadable existing state file must not be mistaken for empty")
        } catch {
            // Support-assisted recovery keeps the unknown protected file and marker intact.
        }
        XCTAssertEqual(try Data(contentsOf: url), originalCiphertext)
    }

    func testProtectedFileReadRetriesAfterDeviceDataBecomesAvailable() async throws {
        let url = temporaryDirectory.appendingPathComponent("temporarily-locked.secure")
        let key = Data(repeating: 0x23, count: 32)
        let writer = SecureLocalStore(stateURL: url, keyData: key)
        let original = communicationState()
        try await writer.replace(original)

        let loader = TemporarilyUnavailableStateDataLoader()
        let reopened = SecureLocalStore(
            stateURL: url,
            keyData: key,
            stateDataLoad: { try loader.load($0) }
        )
        assertEmpty(await reopened.snapshot())

        let readiness = await reopened.prepareForRestore()
        XCTAssertEqual(readiness, .ready)
        let restored = await reopened.snapshot()
        XCTAssertEqual(restored.profile?.id, original.profile?.id)
        XCTAssertEqual(restored.messages, original.messages)
    }

    /// The starter milestones are facts about one owner: a routine history-preserving sign-out
    /// keeps them, a different account never inherits them, and ownerless legacy state carrying
    /// one cannot be assigned to a replacement account.
    func testStarterMilestonesFollowTheOwnerAndNeverAnotherAccount() async throws {
        let store = SecureLocalStore(
            stateURL: temporaryDirectory.appendingPathComponent("state.secure"),
            keyData: Data(repeating: 0x47, count: 32)
        )
        var original = communicationState()
        original.starterFirstTransactionAt = Date(timeIntervalSince1970: 1_756_000_000)
        original.starterFirstMessageAt = Date(timeIntervalSince1970: 1_756_000_100)
        let originalProfile = try XCTUnwrap(original.profile)
        try await store.replace(original)

        try await store.clearFinancialAndSessionProjections(preserveCommunicationHistory: true)
        let signedOut = await store.snapshot()
        XCTAssertEqual(
            signedOut.starterFirstTransactionAt,
            original.starterFirstTransactionAt,
            "A same-owner sign-out forgot the transaction milestone."
        )
        XCTAssertEqual(signedOut.starterFirstMessageAt, original.starterFirstMessageAt)

        try await store.update { state in
            state.bindAuthenticatedProfile(originalProfile)
        }
        let sameOwner = await store.snapshot()
        XCTAssertEqual(sameOwner.starterFirstTransactionAt, original.starterFirstTransactionAt)
        XCTAssertEqual(sameOwner.starterFirstMessageAt, original.starterFirstMessageAt)

        let replacement = UserProfile(
            id: "different-user",
            name: "Different User",
            email: nil,
            phone: "+256700000002",
            tag: "different_user",
            kycStatus: "pending",
            paymentPinSet: true,
            mfaEnabled: false,
            profileSetupRequired: false
        )
        try await store.update { state in
            state.bindAuthenticatedProfile(replacement)
        }
        let differentOwner = await store.snapshot()
        XCTAssertNil(differentOwner.starterFirstTransactionAt)
        XCTAssertNil(differentOwner.starterFirstMessageAt)

        // Ownerless legacy state carrying only a milestone is unowned account data: binding a
        // new profile must wipe rather than adopt it.
        var legacy = PersistedState.empty
        legacy.starterFirstMessageAt = Date(timeIntervalSince1970: 1_756_000_200)
        legacy.bindAuthenticatedProfile(replacement)
        XCTAssertNil(legacy.starterFirstMessageAt)
        XCTAssertNil(legacy.starterFirstTransactionAt)
        XCTAssertEqual(legacy.profile, replacement)
    }

    func testAccountProjectionClearRemovesCachedContactsButKeepsCommunicationHistory() async throws {
        let url = temporaryDirectory.appendingPathComponent("state.secure")
        let store = SecureLocalStore(
            stateURL: url,
            keyData: Data(repeating: 0x44, count: 32)
        )
        let original = communicationState()
        try await store.replace(original)

        try await store.clearFinancialAndSessionProjections(preserveCommunicationHistory: true)
        let cleared = await store.snapshot()

        XCTAssertNil(cleared.profile)
        XCTAssertEqual(cleared.communicationOwnerUserID, original.profile?.id)
        XCTAssertTrue(cleared.contacts?.isEmpty != false)
        XCTAssertNil(cleared.sessionAssurance)
        XCTAssertEqual(cleared.conversations, original.conversations)
        XCTAssertEqual(cleared.conversationDrafts, original.conversationDrafts)
        XCTAssertEqual(
            ConversationDraftPolicy.body(
                conversationID: original.conversations[0].id,
                ownerUserID: try XCTUnwrap(original.profile?.id),
                in: cleared
            ),
            "",
            "A signed-out projection must not expose its retained draft"
        )
        XCTAssertEqual(cleared.messages.count, original.messages.count)
        XCTAssertEqual(cleared.messages[0].body, original.messages[0].body)
        XCTAssertEqual(cleared.messages[0].state, .failed)
        XCTAssertEqual(
            cleared.messages[0].failureReason,
            CustomerFacingMessagingCopy.deliveryUnconfirmedBeforeSignOut
        )
        XCTAssertEqual(cleared.calls.count, original.calls.count)
        XCTAssertEqual(cleared.calls[0].state, .failed)
        XCTAssertNotNil(cleared.calls[0].endedAt)
        XCTAssertEqual(cleared.calls[0].conversationId, original.calls[0].conversationId)
        XCTAssertEqual(cleared.calls[0].answeredAt, original.calls[0].answeredAt)
        XCTAssertEqual(
            cleared.callHistoryBackfillReceipt,
            original.callHistoryBackfillReceipt
        )
        XCTAssertTrue(cleared.outbox.isEmpty)
        XCTAssertNil(cleared.secureMessaging)
    }

    func testFinancialChatRecoveryJournalsStayWithTheirOwnerAcrossSignOut() async throws {
        let owner = "10000000-0000-4000-8000-000000000001"
        let peer = "10000000-0000-4000-8000-000000000002"
        let third = "10000000-0000-4000-8000-000000000003"
        let wallet = "20000000-0000-4000-8000-000000000001"
        let destinationWallet = "20000000-0000-4000-8000-000000000002"
        let conversation = "30000000-0000-4000-8000-000000000001"
        let requestID = "40000000-0000-4000-8000-000000000001"
        let currency = CurrencyDTO(code: "UGX", scale: "2")
        let profile = UserProfile(
            id: owner,
            name: "Recovery Owner",
            email: nil,
            phone: "+256700000001",
            tag: "recovery_owner",
            kycStatus: "verified",
            paymentPinSet: true,
            mfaEnabled: false,
            profileSetupRequired: false
        )
        let request = PaymentRequestDTO(
            id: requestID,
            type: "payment_request",
            status: "pending",
            destinationWalletId: destinationWallet,
            requestedFromUserId: peer,
            amount: "10.00",
            currency: currency,
            note: "Lunch",
            expiresAt: nil,
            walletTransactionId: nil,
            paidAt: nil,
            createdAt: "2026-09-01T00:00:00Z"
        )
        let descriptor = try XCTUnwrap(KitPaymentMessage(action: .request, paymentRequest: request))
        let groupBody = CreateGroupPaymentBody(
            sourceWalletId: wallet,
            splitMode: GroupPaymentSplitMode.even.rawValue,
            audience: GroupPaymentAudience.selected.rawValue,
            totalAmount: "20.00",
            note: nil,
            recipients: [peer, third].map {
                CreateGroupPaymentBody.Recipient(userId: $0, amount: nil)
            }
        )

        var original = PersistedState.empty
        original.bindAuthenticatedProfile(profile)
        original.pendingTransferChatReceipts = [try XCTUnwrap(
            TransferChatReceiptRecoveryRecord(
                ownerUserID: owner,
                sourceWalletID: wallet,
                destinationWalletID: destinationWallet,
                recipientUserID: peer,
                recipientName: "Peer",
                conversationID: conversation,
                amount: "10.00",
                currency: currency,
                note: "Lunch"
            )
        )]
        original.pendingPaymentRequestChatReceipts = [try XCTUnwrap(
            PaymentRequestChatReceiptRecoveryRecord(
                ownerUserID: owner,
                destinationWalletID: destinationWallet,
                recipientUserID: peer,
                recipientName: "Peer",
                conversationID: conversation,
                amount: "10.00",
                currency: currency,
                note: "Lunch",
                idempotencyKey: "ios-request-create-owner-test"
            )
        )]
        original.pendingPaymentRequestResolutionChatReceipts = [try XCTUnwrap(
            PaymentRequestResolutionChatReceiptRecoveryRecord(
                ownerUserID: owner,
                conversationID: conversation,
                recipientUserID: peer,
                recipientName: "Peer",
                request: request,
                descriptor: descriptor,
                sourceWalletID: nil,
                operation: .cancelled,
                idempotencyKey: "ios-request-cancel-owner-test"
            )
        )]
        original.pendingGroupPaymentChatReceipts = [try XCTUnwrap(
            GroupPaymentChatReceiptRecoveryRecord(
                ownerUserID: owner,
                conversationID: conversation,
                expectedRecipientUserIDs: [peer, third],
                currency: currency,
                body: groupBody,
                idempotencyKey: "ios-group-payment-owner-test"
            )
        )]
        original.pendingGroupContributionChatReceipts = [try XCTUnwrap(
            GroupContributionChatReceiptRecoveryRecord(
                ownerUserID: owner,
                conversationID: conversation,
                announcementSenderUserID: peer,
                requestID: requestID,
                sourceWalletID: wallet,
                amount: "5.00",
                currency: currency,
                idempotencyKey: "ios-group-contribution-owner-test"
            )
        )]

        let url = temporaryDirectory.appendingPathComponent("financial-recovery-state.secure")
        let key = Data(repeating: 0x4B, count: 32)
        let store = SecureLocalStore(stateURL: url, keyData: key)
        try await store.replace(original)
        try await store.clearFinancialAndSessionProjections(preserveCommunicationHistory: true)

        let reopened = SecureLocalStore(stateURL: url, keyData: key)
        let signedOut = await reopened.snapshot()
        XCTAssertEqual(signedOut.pendingTransferChatReceipts, original.pendingTransferChatReceipts)
        XCTAssertEqual(
            signedOut.pendingPaymentRequestChatReceipts,
            original.pendingPaymentRequestChatReceipts
        )
        XCTAssertEqual(
            signedOut.pendingPaymentRequestResolutionChatReceipts,
            original.pendingPaymentRequestResolutionChatReceipts
        )
        XCTAssertEqual(
            signedOut.pendingGroupPaymentChatReceipts,
            original.pendingGroupPaymentChatReceipts
        )
        XCTAssertEqual(
            signedOut.pendingGroupContributionChatReceipts,
            original.pendingGroupContributionChatReceipts
        )

        try await reopened.update { state in state.bindAuthenticatedProfile(profile) }
        let rebound = await reopened.snapshot()
        XCTAssertEqual(
            rebound.pendingTransferChatReceipts,
            original.pendingTransferChatReceipts
        )

        let replacement = UserProfile(
            id: "10000000-0000-4000-8000-000000000099",
            name: "Replacement",
            email: nil,
            phone: "+256700000099",
            tag: "replacement",
            kycStatus: "verified",
            paymentPinSet: true,
            mfaEnabled: false,
            profileSetupRequired: false
        )
        try await reopened.update { state in state.bindAuthenticatedProfile(replacement) }
        let switched = await reopened.snapshot()
        XCTAssertNil(switched.pendingTransferChatReceipts)
        XCTAssertNil(switched.pendingPaymentRequestChatReceipts)
        XCTAssertNil(switched.pendingPaymentRequestResolutionChatReceipts)
        XCTAssertNil(switched.pendingGroupPaymentChatReceipts)
        XCTAssertNil(switched.pendingGroupContributionChatReceipts)
    }

    func testAcceptedDeletionPurgeDurablyErasesOnlyItsExactOwner() async throws {
        let url = temporaryDirectory.appendingPathComponent("accepted-deletion.secure")
        let key = Data(repeating: 0x49, count: 32)
        let store = SecureLocalStore(stateURL: url, keyData: key)
        let original = communicationState()
        try await store.replace(original)

        let wrongOwnerResult = try await store.purgeAcceptedAccountDeletion(
            accountID: "different-user"
        )
        XCTAssertEqual(wrongOwnerResult, .ownerConflict)
        let wrongOwnerSnapshot = await store.snapshot()
        XCTAssertEqual(wrongOwnerSnapshot.messages, original.messages)

        let ownerResult = try await store.purgeAcceptedAccountDeletion(
            accountID: "current-user"
        )
        XCTAssertEqual(ownerResult, .purged)
        assertEmpty(await store.snapshot())

        let reopened = SecureLocalStore(stateURL: url, keyData: key)
        assertEmpty(await reopened.snapshot())
    }

    func testFailedAcceptedDeletionWriteConcealsTargetUntilDurableRetry() async throws {
        let url = temporaryDirectory.appendingPathComponent("accepted-deletion-failure.secure")
        let store = SecureLocalStore(
            stateURL: url,
            keyData: Data(repeating: 0x4B, count: 32)
        )
        try await store.replace(communicationState())
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)

        do {
            _ = try await store.purgeAcceptedAccountDeletion(accountID: "current-user")
            XCTFail("A blocked protected-state write must retain the durable purge marker")
        } catch {
            // Expected. The actor must still stop exposing the accepted deletion target.
        }
        assertEmpty(await store.snapshot())

        try FileManager.default.removeItem(at: url)
        let retried = try await store.purgeAcceptedAccountDeletion(
            accountID: "current-user"
        )
        XCTAssertEqual(retried, .purged)
        let reopened = SecureLocalStore(
            stateURL: url,
            keyData: Data(repeating: 0x4B, count: 32)
        )
        assertEmpty(await reopened.snapshot())
    }

    func testAcceptedDeletionConcealmentUnlocksOnlyAfterVerifiedEmptyProjection() async throws {
        let emptyURL = temporaryDirectory.appendingPathComponent("accepted-deletion-empty.secure")
        let emptyStore = SecureLocalStore(
            stateURL: emptyURL,
            keyData: Data(repeating: 0x4D, count: 32)
        )
        try await emptyStore.replace(communicationState())
        _ = try await emptyStore.purgeAcceptedAccountDeletion(accountID: "current-user")
        await emptyStore.concealStateForUnresolvedAcceptedAccountDeletion()

        let emptyResolved = try await emptyStore
            .resolveAcceptedDeletionConcealmentAfterVerifiedEmptyState()
        XCTAssertTrue(emptyResolved)
        try await emptyStore.update { $0.communicationOwnerUserID = "replacement-user" }
        let replacementSnapshot = await emptyStore.snapshot()
        XCTAssertEqual(replacementSnapshot.communicationOwnerUserID, "replacement-user")

        let conflictURL = temporaryDirectory.appendingPathComponent(
            "accepted-deletion-nonempty.secure"
        )
        let conflictStore = SecureLocalStore(
            stateURL: conflictURL,
            keyData: Data(repeating: 0x4E, count: 32)
        )
        try await conflictStore.replace(communicationState())
        await conflictStore.concealStateForUnresolvedAcceptedAccountDeletion()

        let conflictResolved = try await conflictStore
            .resolveAcceptedDeletionConcealmentAfterVerifiedEmptyState()
        XCTAssertFalse(conflictResolved)
        assertEmpty(await conflictStore.snapshot())
        do {
            try await conflictStore.update { $0.messages = [] }
            XCTFail("A nonempty conflicting projection must remain mutation-locked")
        } catch {
            XCTAssertEqual(error as? StoreError, .acceptedDeletionCleanupPending)
        }
    }

    func testAcceptedDeletionPurgeRejectsAmbiguousOrConflictingOwnership() async throws {
        let url = temporaryDirectory.appendingPathComponent("accepted-deletion-conflict.secure")
        let store = SecureLocalStore(
            stateURL: url,
            keyData: Data(repeating: 0x4C, count: 32)
        )
        var ambiguous = communicationState()
        ambiguous.profile = nil
        ambiguous.communicationOwnerUserID = nil
        try await store.replace(ambiguous)

        let ambiguousResult = try await store.purgeAcceptedAccountDeletion(
            accountID: "current-user"
        )
        XCTAssertEqual(ambiguousResult, .ownerConflict)
        let ambiguousSnapshot = await store.snapshot()
        XCTAssertEqual(ambiguousSnapshot.messages, ambiguous.messages)

        var conflicting = communicationState()
        conflicting.communicationOwnerUserID = "different-user"
        try await store.replace(conflicting)
        let conflictingResult = try await store.purgeAcceptedAccountDeletion(
            accountID: "current-user"
        )
        XCTAssertEqual(conflictingResult, .ownerConflict)
        let conflictingSnapshot = await store.snapshot()
        XCTAssertEqual(conflictingSnapshot.profile, conflicting.profile)

        try await store.replace(.empty)
        let emptyResult = try await store.purgeAcceptedAccountDeletion(
            accountID: "current-user"
        )
        XCTAssertEqual(emptyResult, .alreadyEmpty)
    }

    func testSignOutProjectionClearDurablyRemovesPendingProfileAvatarAttachment() async throws {
        let url = temporaryDirectory.appendingPathComponent("state.secure")
        let key = Data(repeating: 0x47, count: 32)
        let store = SecureLocalStore(stateURL: url, keyData: key)
        var original = communicationState()
        original.pendingProfileAvatarAttachment = pendingAvatarAttachment()
        try await store.replace(original)

        try await store.clearFinancialAndSessionProjections(
            preserveCommunicationHistory: true
        )

        let cleared = await store.snapshot()
        XCTAssertNil(cleared.pendingProfileAvatarAttachment)
        let reopened = SecureLocalStore(stateURL: url, keyData: key)
        let restored = await reopened.snapshot()
        XCTAssertNil(restored.pendingProfileAvatarAttachment)
    }

    func testPrivacyCacheIsEncryptedAccountBoundAndRemovedAtSignOut() async throws {
        let ownerUserID = "10000000-0000-4000-8000-000000000001"
        let blockedUserID = "20000000-0000-4000-8000-000000000001"
        let url = temporaryDirectory.appendingPathComponent("privacy-state.secure")
        let key = Data(repeating: 0x4A, count: 32)
        let store = SecureLocalStore(stateURL: url, keyData: key)
        var state = PersistedState.empty
        state.profile = UserProfile(
            id: ownerUserID,
            name: "Privacy Owner",
            email: nil,
            phone: "+256750000002",
            tag: "privacy_owner",
            kycStatus: "verified",
            paymentPinSet: true,
            mfaEnabled: false,
            profileSetupRequired: false
        )
        state.communicationOwnerUserID = ownerUserID
        state.communicationPrivacy = try privacyCache(
            ownerUserID: ownerUserID,
            blockedUserID: blockedUserID
        )

        try await store.replace(state)
        let ciphertext = try Data(contentsOf: url)
        XCTAssertNil(ciphertext.range(of: Data(blockedUserID.utf8)))

        let reopened = SecureLocalStore(stateURL: url, keyData: key)
        let restored = await reopened.snapshot()
        XCTAssertEqual(restored.communicationPrivacy, state.communicationPrivacy)
        XCTAssertEqual(restored.communicationPrivacy?.ownerUserId, ownerUserID)

        try await reopened.clearFinancialAndSessionProjections(
            preserveCommunicationHistory: true
        )
        let signedOutSnapshot = await reopened.snapshot()
        XCTAssertNil(signedOutSnapshot.communicationPrivacy)
    }

    func testCommunicationHistoryIsNeverInheritedByAnotherAuthenticatedAccount() async throws {
        let store = SecureLocalStore(
            stateURL: temporaryDirectory.appendingPathComponent("state.secure"),
            keyData: Data(repeating: 0x45, count: 32)
        )
        let original = communicationState()
        let originalProfile = try XCTUnwrap(original.profile)
        try await store.replace(original)
        try await store.clearFinancialAndSessionProjections(
            preserveCommunicationHistory: true
        )

        try await store.update { state in
            state.bindAuthenticatedProfile(originalProfile)
        }
        let sameAccount = await store.snapshot()
        XCTAssertEqual(sameAccount.communicationOwnerUserID, originalProfile.id)
        XCTAssertEqual(sameAccount.conversations, original.conversations)
        XCTAssertEqual(sameAccount.conversationDrafts, original.conversationDrafts)
        XCTAssertEqual(
            ConversationDraftPolicy.body(
                conversationID: original.conversations[0].id,
                ownerUserID: originalProfile.id,
                in: sameAccount
            ),
            "unfinished private draft"
        )
        XCTAssertEqual(sameAccount.messages.count, original.messages.count)
        XCTAssertEqual(sameAccount.calls.count, original.calls.count)
        XCTAssertEqual(
            sameAccount.callHistoryBackfillReceipt,
            original.callHistoryBackfillReceipt
        )

        let otherProfile = UserProfile(
            id: "different-user",
            name: "Different User",
            email: nil,
            phone: "+256700000002",
            tag: "different_user",
            kycStatus: "verified",
            paymentPinSet: true,
            mfaEnabled: false,
            profileSetupRequired: false
        )
        try await store.update { state in
            state.bindAuthenticatedProfile(otherProfile)
        }
        let differentAccount = await store.snapshot()
        XCTAssertEqual(differentAccount.profile, otherProfile)
        XCTAssertEqual(differentAccount.communicationOwnerUserID, otherProfile.id)
        XCTAssertTrue(differentAccount.conversations.isEmpty)
        XCTAssertNil(differentAccount.conversationDrafts)
        XCTAssertTrue(differentAccount.messages.isEmpty)
        XCTAssertTrue(differentAccount.calls.isEmpty)
        XCTAssertNil(differentAccount.callHistoryBackfillReceipt)
        XCTAssertTrue(differentAccount.outbox.isEmpty)
        XCTAssertNil(differentAccount.secureMessaging)
    }

    func testAuthenticatedAccountSwitchClearsPendingProfileAvatarAttachment() async throws {
        let store = SecureLocalStore(
            stateURL: temporaryDirectory.appendingPathComponent("state.secure"),
            keyData: Data(repeating: 0x48, count: 32)
        )
        var original = communicationState()
        original.pendingProfileAvatarAttachment = pendingAvatarAttachment()
        try await store.replace(original)

        let otherProfile = UserProfile(
            id: "different-user",
            name: "Different User",
            email: nil,
            phone: "+256700000002",
            tag: "different_user",
            kycStatus: "verified",
            paymentPinSet: true,
            mfaEnabled: false,
            profileSetupRequired: false
        )
        try await store.update { state in
            state.bindAuthenticatedProfile(otherProfile)
        }

        let switched = await store.snapshot()
        XCTAssertEqual(switched.profile, otherProfile)
        XCTAssertNil(switched.pendingProfileAvatarAttachment)
    }

    func testLegacyUnownedSignedOutHistoryFailsClosedAtAuthentication() async throws {
        let store = SecureLocalStore(
            stateURL: temporaryDirectory.appendingPathComponent("state.secure"),
            keyData: Data(repeating: 0x46, count: 32)
        )
        var legacy = communicationState()
        let profile = try XCTUnwrap(legacy.profile)
        legacy.profile = nil
        legacy.communicationOwnerUserID = nil
        legacy.wallets = []
        legacy.transactions = []
        legacy.contacts = nil
        legacy.outbox = []
        legacy.secureMessaging = nil
        try await store.replace(legacy)

        try await store.update { state in
            state.bindAuthenticatedProfile(profile)
        }
        let rebound = await store.snapshot()
        XCTAssertEqual(rebound.profile, profile)
        XCTAssertEqual(rebound.communicationOwnerUserID, profile.id)
        XCTAssertTrue(rebound.conversations.isEmpty)
        XCTAssertNil(rebound.conversationDrafts)
        XCTAssertTrue(rebound.messages.isEmpty)
        XCTAssertTrue(rebound.calls.isEmpty)
    }

    func testFailedAtomicWriteDoesNotAdvanceInMemoryState() async throws {
        let url = temporaryDirectory.appendingPathComponent("state.secure")
        let store = SecureLocalStore(
            stateURL: url,
            keyData: Data(repeating: 0x73, count: 32)
        )
        let original = communicationState()
        try await store.replace(original)

        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)

        do {
            try await store.update { state in
                state.messages[0].body = "ratchet advanced without durable ciphertext"
                state.secureMessaging?.syncCursor = "uncommitted-cursor"
            }
            XCTFail("A state file path occupied by a directory must reject the write")
        } catch {
            // Expected: the candidate never becomes the actor's committed state.
        }

        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.messages, original.messages)
        XCTAssertEqual(snapshot.conversationDrafts, original.conversationDrafts)
        XCTAssertEqual(snapshot.secureMessaging, original.secureMessaging)
    }

    func testSecureMessagingCommitRejectsAStaleRatchetWithoutChangingProjection() async throws {
        let url = temporaryDirectory.appendingPathComponent("state.secure")
        let store = SecureLocalStore(
            stateURL: url,
            keyData: Data(repeating: 0x74, count: 32)
        )
        let original = communicationState()
        let baseline = try XCTUnwrap(original.secureMessaging)
        try await store.replace(original)

        var firstAdvance = baseline
        firstAdvance.syncCursor = "cursor-committed-first"
        try await store.commitSecureMessaging(
            forUserID: "current-user",
            expectedState: baseline,
            nextState: firstAdvance
        ) { state in
            state.messages[0].body = "first committed plaintext projection"
        }

        let committed = await store.snapshot()
        XCTAssertEqual(committed.secureMessaging?.transactionRevision, 1)
        XCTAssertEqual(committed.secureMessaging?.syncCursor, "cursor-committed-first")
        XCTAssertEqual(committed.messages[0].body, "first committed plaintext projection")

        var staleAdvance = baseline
        staleAdvance.syncCursor = "cursor-that-must-not-win"
        do {
            try await store.commitSecureMessaging(
                forUserID: "current-user",
                expectedState: baseline,
                nextState: staleAdvance
            ) { state in
                state.messages[0].body = "stale projection"
            }
            XCTFail("A detached crypto result must not overwrite the committed ratchet")
        } catch let error as SecureMessagingCryptoError {
            XCTAssertEqual(error, .staleState)
        }

        let afterRejectedCommit = await store.snapshot()
        XCTAssertEqual(afterRejectedCommit.secureMessaging, committed.secureMessaging)
        XCTAssertEqual(afterRejectedCommit.messages, committed.messages)
    }

    func testStateWrittenBeforeContactCachingStillDecodes() throws {
        let original = communicationState()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let currentData = try encoder.encode(original)
        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: currentData) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "contacts")
        legacyObject.removeValue(forKey: "callHistoryBackfillReceipt")
        legacyObject.removeValue(forKey: "conversationDrafts")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(PersistedState.self, from: legacyData)

        XCTAssertNil(restored.contacts)
        XCTAssertNil(restored.callHistoryBackfillReceipt)
        XCTAssertNil(restored.conversationDrafts)
        XCTAssertEqual(restored.profile, original.profile)
        XCTAssertEqual(restored.messages, original.messages)
        XCTAssertEqual(restored.calls, original.calls)
    }

    func testSuccessfulQueueClearsOnlyTheExactSubmittedDraft() throws {
        let conversationID = "11111111-1111-4111-8111-111111111111"
        var state = communicationState()
        state.conversations = [
            Conversation(
                id: conversationID,
                title: "ExampleContact",
                participantUserIds: ["current-user", "recipient-user"],
                unreadCount: 0,
                updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
            ),
        ]
        state.conversationDrafts = nil

        XCTAssertTrue(ConversationDraftPolicy.store(
            "First version",
            conversationID: conversationID,
            ownerUserID: "current-user",
            in: &state
        ))
        XCTAssertTrue(ConversationDraftPolicy.store(
            "New text typed while sending",
            conversationID: conversationID,
            ownerUserID: "current-user",
            in: &state
        ))

        XCTAssertFalse(ConversationDraftPolicy.clearAfterSuccessfulQueue(
            submittedBody: "First version",
            conversationID: conversationID,
            ownerUserID: "current-user",
            in: &state
        ))
        XCTAssertEqual(
            ConversationDraftPolicy.body(
                conversationID: conversationID,
                ownerUserID: "current-user",
                in: state
            ),
            "New text typed while sending"
        )

        XCTAssertTrue(ConversationDraftPolicy.clearAfterSuccessfulQueue(
            submittedBody: "New text typed while sending",
            conversationID: conversationID,
            ownerUserID: "current-user",
            in: &state
        ))
        XCTAssertNil(state.conversationDrafts)
    }

    func testDraftPolicyRejectsAnotherAccountAndBoundsComposerText() throws {
        let conversationID = "11111111-1111-4111-8111-111111111111"
        var state = communicationState()
        state.conversations = [
            Conversation(
                id: conversationID,
                title: "ExampleContact",
                participantUserIds: ["current-user", "recipient-user"],
                unreadCount: 0,
                updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
            ),
        ]
        state.conversationDrafts = nil

        XCTAssertFalse(ConversationDraftPolicy.store(
            "Must not cross accounts",
            conversationID: conversationID,
            ownerUserID: "different-user",
            in: &state
        ))
        XCTAssertNil(state.conversationDrafts)

        let oversized = String(repeating: "a", count: ConversationDraftPolicy.maximumBodyScalars + 1)
        XCTAssertTrue(ConversationDraftPolicy.store(
            oversized,
            conversationID: conversationID,
            ownerUserID: "current-user",
            in: &state
        ))
        XCTAssertEqual(
            state.conversationDrafts?[conversationID]?.body.unicodeScalars.count,
            ConversationDraftPolicy.maximumBodyScalars
        )
    }

    func testDraftsAreScopedToOneCanonicalConversationIdentity() {
        let firstID = "11111111-1111-4111-8111-111111111111"
        let secondID = "22222222-2222-4222-8222-222222222222"
        var state = communicationState()
        state.conversations = [
            Conversation(
                id: firstID,
                title: "ExampleContact",
                participantUserIds: ["current-user", "first-recipient"],
                unreadCount: 0,
                updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
            ),
            Conversation(
                id: secondID,
                title: "ExampleMerchant",
                participantUserIds: ["current-user", "second-recipient"],
                unreadCount: 0,
                updatedAt: Date(timeIntervalSince1970: 1_800_000_100)
            ),
        ]
        state.conversationDrafts = nil

        XCTAssertTrue(ConversationDraftPolicy.store(
            "ExampleContact draft",
            conversationID: firstID,
            ownerUserID: "current-user",
            in: &state
        ))
        XCTAssertEqual(
            ConversationDraftPolicy.body(
                conversationID: firstID,
                ownerUserID: "current-user",
                in: state
            ),
            "ExampleContact draft"
        )
        XCTAssertEqual(
            ConversationDraftPolicy.body(
                conversationID: secondID,
                ownerUserID: "current-user",
                in: state
            ),
            ""
        )
    }

    func testDelayedDraftWriteCannotOverwriteNewerTextOrResurrectQueuedText() {
        let conversationID = "11111111-1111-4111-8111-111111111111"
        let writerID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        var state = communicationState()
        state.conversations = [
            Conversation(
                id: conversationID,
                title: "ExampleContact",
                participantUserIds: ["current-user", "recipient-user"],
                unreadCount: 0,
                updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
            ),
        ]
        state.conversationDrafts = nil

        let stale = ConversationDraftWriteVersion(writerID: writerID, sequence: 1)
        let latest = ConversationDraftWriteVersion(writerID: writerID, sequence: 2)
        let queued = ConversationDraftWriteVersion(writerID: writerID, sequence: 3)

        XCTAssertTrue(ConversationDraftPolicy.store(
            "Latest text",
            conversationID: conversationID,
            ownerUserID: "current-user",
            writeVersion: latest,
            in: &state
        ))
        XCTAssertFalse(ConversationDraftPolicy.store(
            "Stale debounce text",
            conversationID: conversationID,
            ownerUserID: "current-user",
            writeVersion: stale,
            in: &state
        ))
        XCTAssertEqual(
            ConversationDraftPolicy.body(
                conversationID: conversationID,
                ownerUserID: "current-user",
                in: state
            ),
            "Latest text"
        )

        XCTAssertTrue(ConversationDraftPolicy.clearAfterSuccessfulQueue(
            submittedBody: "Latest text",
            conversationID: conversationID,
            ownerUserID: "current-user",
            writeVersion: queued,
            in: &state
        ))
        XCTAssertEqual(
            ConversationDraftPolicy.body(
                conversationID: conversationID,
                ownerUserID: "current-user",
                in: state
            ),
            ""
        )
        XCTAssertFalse(ConversationDraftPolicy.store(
            "Stale debounce text",
            conversationID: conversationID,
            ownerUserID: "current-user",
            writeVersion: stale,
            in: &state
        ))
        XCTAssertEqual(state.conversationDrafts?[conversationID]?.writeVersion, queued)
        XCTAssertEqual(state.conversationDrafts?[conversationID]?.body, "")
        XCTAssertFalse(ConversationDraftPolicy.shouldApplySnapshotDraft(
            ConversationDraft(
                body: "Stale debounce text",
                updatedAt: Date(),
                writeVersion: stale
            ),
            over: state.conversationDrafts?[conversationID]
        ))
    }

    func testDraftMediaManifestSurvivesTextWritesAndClearsAtomicallyWithExactSend() throws {
        let conversationID = "11111111-1111-4111-8111-111111111111"
        let writerID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let mediaID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        var state = communicationState()
        state.conversations = [Conversation(
            id: conversationID,
            title: "ExampleContact",
            participantUserIds: ["current-user", "recipient-user"],
            unreadCount: 0,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )]
        let attachment = ConversationDraftMediaAttachment(
            id: mediaID,
            storageKind: .protectedFile,
            mediaType: "application/pdf",
            originalMediaType: nil,
            byteCount: 4_096,
            displayName: "Receipt.pdf",
            duration: nil,
            acceptedAt: Date(timeIntervalSince1970: 1_800_000_001),
            clientMessageID: nil,
            preprocessingOutputStorageKey: nil
        )
        let first = ConversationDraftWriteVersion(writerID: writerID, sequence: 1)
        let textUpdate = ConversationDraftWriteVersion(writerID: writerID, sequence: 2)
        let send = ConversationDraftWriteVersion(writerID: writerID, sequence: 3)

        XCTAssertTrue(ConversationDraftPolicy.store(
            "",
            conversationID: conversationID,
            ownerUserID: "current-user",
            writeVersion: first,
            mediaAttachments: [attachment],
            in: &state
        ))
        XCTAssertEqual(
            ConversationDraftPolicy.mediaAttachments(
                conversationID: conversationID,
                ownerUserID: "current-user",
                in: state
            ),
            [attachment]
        )
        // A text-only debounce omits the media argument and must preserve the durable manifest.
        XCTAssertTrue(ConversationDraftPolicy.store(
            "Caption",
            conversationID: conversationID,
            ownerUserID: "current-user",
            writeVersion: textUpdate,
            in: &state
        ))
        XCTAssertEqual(state.conversationDrafts?[conversationID]?.mediaAttachments, [attachment])

        var mismatched = attachment
        let encoded = try JSONEncoder().encode(mismatched)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["displayName"] = "Different.pdf"
        mismatched = try JSONDecoder().decode(
            ConversationDraftMediaAttachment.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertFalse(ConversationDraftPolicy.clearAfterSuccessfulQueue(
            submittedBody: "Caption",
            conversationID: conversationID,
            ownerUserID: "current-user",
            writeVersion: send,
            submittedMediaAttachments: [mismatched],
            in: &state
        ))
        XCTAssertEqual(state.conversationDrafts?[conversationID]?.mediaAttachments, [attachment])
        XCTAssertTrue(ConversationDraftPolicy.clearAfterSuccessfulQueue(
            submittedBody: "Caption",
            conversationID: conversationID,
            ownerUserID: "current-user",
            writeVersion: send,
            submittedMediaAttachments: [attachment],
            in: &state
        ))
        XCTAssertNil(state.conversationDrafts?[conversationID]?.mediaAttachments)
        XCTAssertFalse(ConversationDraftPolicy.store(
            "Caption",
            conversationID: conversationID,
            ownerUserID: "current-user",
            writeVersion: textUpdate,
            mediaAttachments: [attachment],
            in: &state
        ))
    }

    func testDraftMediaManifestRejectsOutputCollisionWithAnotherSource() {
        let conversationID = "11111111-1111-4111-8111-111111111111"
        let firstID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        let secondID = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
        var state = communicationState()
        state.conversations = [Conversation(
            id: conversationID,
            title: "ExampleContact",
            participantUserIds: ["current-user", "recipient-user"],
            unreadCount: 0,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )]
        let draftsBefore = state.conversationDrafts
        func image(_ id: UUID, output: String) -> ConversationDraftMediaAttachment {
            ConversationDraftMediaAttachment(
                id: id,
                storageKind: .protectedFile,
                mediaType: "image/jpeg",
                originalMediaType: "image/heic",
                byteCount: 1_024,
                displayName: "Photo",
                duration: nil,
                acceptedAt: Date(timeIntervalSince1970: 1_800_000_001),
                clientMessageID: nil,
                preprocessingOutputStorageKey: output
            )
        }
        XCTAssertFalse(ConversationDraftPolicy.store(
            "",
            conversationID: conversationID,
            ownerUserID: "current-user",
            mediaAttachments: [
                image(firstID, output: secondID.uuidString.lowercased()),
                image(secondID, output: UUID().uuidString.lowercased()),
            ],
            in: &state
        ))
        XCTAssertEqual(state.conversationDrafts, draftsBefore)
    }

    func testMediaOnlyDraftOutlivesTrueTombstoneAtDraftCapacity() {
        let conversationIDs = (0 ... ConversationDraftPolicy.maximumDraftCount).map { _ in
            UUID().uuidString.lowercased()
        }
        let mediaConversationID = conversationIDs[0]
        let tombstoneConversationID = conversationIDs[1]
        let newConversationID = conversationIDs.last!
        let mediaID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        let attachment = ConversationDraftMediaAttachment(
            id: mediaID,
            storageKind: .protectedFile,
            mediaType: "application/pdf",
            originalMediaType: nil,
            byteCount: 4_096,
            displayName: "Receipt.pdf",
            duration: nil,
            acceptedAt: Date(timeIntervalSince1970: 1_800_000_000),
            clientMessageID: nil,
            preprocessingOutputStorageKey: nil
        )
        var state = communicationState()
        state.conversations = conversationIDs.map { id in
            Conversation(
                id: id,
                title: "Draft",
                participantUserIds: ["current-user", "recipient-user"],
                unreadCount: 0,
                updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        }
        var drafts: [String: ConversationDraft] = [
            mediaConversationID: ConversationDraft(
                body: "",
                updatedAt: Date(timeIntervalSince1970: 1),
                mediaAttachments: [attachment]
            ),
            tombstoneConversationID: ConversationDraft(
                body: "",
                updatedAt: Date(timeIntervalSince1970: 2),
                writeVersion: ConversationDraftWriteVersion(writerID: UUID(), sequence: 1)
            ),
        ]
        for index in 2 ..< ConversationDraftPolicy.maximumDraftCount {
            drafts[conversationIDs[index]] = ConversationDraft(
                body: "Draft \(index)",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index + 2))
            )
        }
        state.conversationDrafts = drafts

        XCTAssertTrue(ConversationDraftPolicy.store(
            "Newest draft",
            conversationID: newConversationID,
            ownerUserID: "current-user",
            in: &state
        ))

        XCTAssertEqual(state.conversationDrafts?.count, ConversationDraftPolicy.maximumDraftCount)
        XCTAssertNotNil(state.conversationDrafts?[mediaConversationID])
        XCTAssertEqual(
            state.conversationDrafts?[mediaConversationID]?.mediaAttachments,
            [attachment]
        )
        XCTAssertNil(state.conversationDrafts?[tombstoneConversationID])
    }

    func testDraftStorageOwnershipIncludesPreprocessingOutputsAndExemptsOnlyExactSend() {
        let firstConversationID = "11111111-1111-4111-8111-111111111111"
        let secondConversationID = "22222222-2222-4222-8222-222222222222"
        let writerID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let firstSource = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        let firstOutput = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        let secondSource = UUID(uuidString: "dddddddd-dddd-4ddd-8ddd-dddddddddddd")!
        func image(
            _ id: UUID,
            output: String,
            clientMessageID: UUID? = nil
        ) -> ConversationDraftMediaAttachment {
            ConversationDraftMediaAttachment(
                id: id,
                storageKind: .protectedFile,
                mediaType: "image/jpeg",
                originalMediaType: "image/heic",
                byteCount: 1_024,
                displayName: "Photo",
                duration: nil,
                acceptedAt: Date(timeIntervalSince1970: 1_800_000_001),
                clientMessageID: clientMessageID,
                preprocessingOutputStorageKey: output
            )
        }
        let submitted = image(firstSource, output: firstOutput)
        let unrelated = image(
            secondSource,
            output: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
        )
        let currentVersion = ConversationDraftWriteVersion(writerID: writerID, sequence: 7)
        let clearVersion = ConversationDraftWriteVersion(writerID: writerID, sequence: 8)
        var state = communicationState()
        state.conversationDrafts = [
            firstConversationID: ConversationDraft(
                body: "Caption",
                updatedAt: Date(),
                writeVersion: currentVersion,
                mediaAttachments: [submitted]
            ),
            secondConversationID: ConversationDraft(
                body: "Other",
                updatedAt: Date(),
                writeVersion: currentVersion,
                mediaAttachments: [unrelated]
            ),
        ]

        XCTAssertEqual(Set(state.conversationDrafts![firstConversationID]!.localMediaStorageKeys), [
            firstSource.uuidString.lowercased(), firstOutput,
        ])
        XCTAssertEqual(
            ConversationDraftPolicy.localMediaStorageKeysOwnedByDrafts(in: state),
            [
                firstSource.uuidString.lowercased(), firstOutput,
                secondSource.uuidString.lowercased(),
                "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
            ]
        )
        XCTAssertEqual(
            ConversationDraftPolicy.localMediaStorageKeysOwnedByDrafts(
                in: state,
                excludingSubmittedDraftFor: firstConversationID,
                submittedBody: "Caption",
                submittedMediaAttachments: [submitted],
                draftClearVersion: clearVersion,
                consumingStorageKeys: [firstSource.uuidString.lowercased(), firstOutput]
            ),
            [
                secondSource.uuidString.lowercased(),
                "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
            ]
        )
        XCTAssertTrue(ConversationDraftPolicy.localMediaStorageKeysOwnedByDrafts(
            in: state,
            excludingSubmittedDraftFor: firstConversationID,
            submittedBody: "Changed caption",
            submittedMediaAttachments: [submitted],
            draftClearVersion: clearVersion,
            consumingStorageKeys: [firstSource.uuidString.lowercased(), firstOutput]
        ).contains(firstOutput))
        XCTAssertTrue(ConversationDraftPolicy.localMediaStorageKeysOwnedByDrafts(
            in: state,
            excludingSubmittedDraftFor: firstConversationID,
            submittedBody: "Caption",
            submittedMediaAttachments: [submitted],
            draftClearVersion: currentVersion,
            consumingStorageKeys: [firstSource.uuidString.lowercased(), firstOutput]
        ).contains(firstOutput))
        XCTAssertTrue(ConversationDraftPolicy.localMediaStorageKeysOwnedByDrafts(
            in: state,
            excludingSubmittedDraftFor: firstConversationID,
            submittedBody: "Caption",
            submittedMediaAttachments: [submitted],
            draftClearVersion: ConversationDraftWriteVersion(
                writerID: UUID(),
                sequence: 1
            ),
            consumingStorageKeys: [firstSource.uuidString.lowercased(), firstOutput]
        ).contains(firstOutput), "a different writer cannot claim the draft exemption")
        XCTAssertTrue(ConversationDraftPolicy.localMediaStorageKeysOwnedByDrafts(
            in: state,
            excludingSubmittedDraftFor: firstConversationID,
            submittedBody: "Caption",
            submittedMediaAttachments: [submitted],
            draftClearVersion: clearVersion,
            consumingStorageKeys: [firstSource.uuidString.lowercased()]
        ).contains(firstOutput), "a partial queue cannot consume a larger media draft")
    }

    func testDraftStoreRejectsKeysAlreadyOwnedByAnotherDraft() {
        let firstConversationID = "11111111-1111-4111-8111-111111111111"
        let secondConversationID = "22222222-2222-4222-8222-222222222222"
        let sharedOutput = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        func image(_ source: UUID) -> ConversationDraftMediaAttachment {
            ConversationDraftMediaAttachment(
                id: source,
                storageKind: .protectedFile,
                mediaType: "image/jpeg",
                originalMediaType: "image/heic",
                byteCount: 1_024,
                displayName: "Photo",
                duration: nil,
                acceptedAt: Date(timeIntervalSince1970: 1_800_000_001),
                clientMessageID: nil,
                preprocessingOutputStorageKey: sharedOutput
            )
        }
        var state = communicationState()
        state.conversations = [firstConversationID, secondConversationID].map { id in
            Conversation(
                id: id,
                title: "Draft",
                participantUserIds: ["current-user", "recipient-user"],
                unreadCount: 0,
                updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        }
        XCTAssertTrue(ConversationDraftPolicy.store(
            "",
            conversationID: firstConversationID,
            ownerUserID: "current-user",
            mediaAttachments: [image(UUID())],
            in: &state
        ))
        XCTAssertFalse(ConversationDraftPolicy.store(
            "",
            conversationID: secondConversationID,
            ownerUserID: "current-user",
            mediaAttachments: [image(UUID())],
            in: &state
        ))
        XCTAssertNil(state.conversationDrafts?[secondConversationID])
    }

    func testDraftStoreRejectsPreprocessingOutputOwnedByAnotherRecordsSpoolID() throws {
        let conversationID = "11111111-1111-4111-8111-111111111111"
        let existingConversationID = "22222222-2222-4222-8222-222222222222"
        let spoolID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        let existingSource = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
        let existingMessageID = UUID()
        let existingRecord = try XCTUnwrap(LocalMediaRecordPolicy.queuedOutgoing(
            id: spoolID,
            messageID: existingMessageID,
            conversationID: existingConversationID,
            mediaType: "application/pdf",
            fileSize: 1_024,
            localStorageKey: existingSource,
            storesInline: false,
            now: Date(),
            localStorageKind: .protectedFile
        ))
        var state = communicationState()
        state.conversations = [conversationID, existingConversationID].map { id in
            Conversation(
                id: id,
                title: "Draft",
                participantUserIds: ["current-user", "recipient-user"],
                unreadCount: 0,
                updatedAt: Date()
            )
        }
        state.messages = [LocalMessage(
            id: existingMessageID,
            conversationId: existingConversationID,
            senderId: "current-user",
            body: "Document",
            createdAt: Date(),
            sentAt: nil,
            state: .queued,
            failureReason: nil,
            isOutgoing: true,
            pendingAttachment: LocalPendingAttachment(
                mediaType: "application/pdf",
                caption: nil,
                localStorageKey: existingSource,
                byteCount: 1_024
            ),
            localMediaRecords: [existingRecord]
        )]
        let draftAttachment = ConversationDraftMediaAttachment(
            id: UUID(),
            storageKind: .protectedFile,
            mediaType: "image/jpeg",
            originalMediaType: "image/heic",
            byteCount: 1_024,
            displayName: "Photo",
            duration: nil,
            acceptedAt: Date(),
            clientMessageID: nil,
            preprocessingOutputStorageKey: spoolID
        )
        let draftsBefore = state.conversationDrafts

        XCTAssertFalse(ConversationDraftPolicy.store(
            "",
            conversationID: conversationID,
            ownerUserID: "current-user",
            mediaAttachments: [draftAttachment],
            in: &state
        ))
        XCTAssertEqual(state.conversationDrafts, draftsBefore)
    }

    func testStateWrittenBeforePendingAvatarPersistenceDecodesWithNoAttachment() throws {
        var original = communicationState()
        original.pendingProfileAvatarAttachment = pendingAvatarAttachment()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let currentData = try encoder.encode(original)
        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: currentData) as? [String: Any]
        )
        let removedAttachment = legacyObject.removeValue(
            forKey: "pendingProfileAvatarAttachment"
        )
        XCTAssertNotNil(removedAttachment)
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(PersistedState.self, from: legacyData)

        XCTAssertNil(restored.pendingProfileAvatarAttachment)
        XCTAssertEqual(restored.profile, original.profile)
        XCTAssertEqual(restored.messages, original.messages)
    }

    private func communicationState() -> PersistedState {
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        let messageId = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let commandId = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let conversationID = "11111111-1111-4111-8111-111111111111"
        var state = PersistedState.empty
        state.communicationOwnerUserID = "current-user"
        state.profile = UserProfile(
            id: "current-user",
            name: "Private User",
            email: "private@example.test",
            phone: "+256700000001",
            tag: "private_user",
            kycStatus: "verified",
            paymentPinSet: true,
            mfaEnabled: true,
            profileSetupRequired: false
        )
        state.contacts = [
            WalletContactDTO(
                id: "550e8400-e29b-41d4-a716-446655440015",
                contactId: "example_contact-contact",
                name: "ExampleContact",
                phone: "+256700000001",
                isKitUser: true,
                favorite: false,
                status: nil,
                tag: "example_contact",
                avatarURL: nil,
                receivingWalletId: nil
            ),
        ]
        state.sessionAssurance = SessionAssuranceDTO(
            deviceIdentity: DeviceIdentityAssuranceDTO(
                status: "verified",
                required: true,
                epoch: 1,
                verifiedAt: "2026-08-18T12:00:00Z"
            ),
            loginUnlock: LoginUnlockAssuranceDTO(
                status: "unlocked",
                required: true,
                method: "pin",
                methods: ["pin"],
                unlockedAt: "2026-08-18T12:01:00Z"
            ),
            access: "full"
        )
        state.conversations = [
            Conversation(
                id: conversationID,
                title: "Private conversation",
                participantUserIds: ["recipient-1"],
                unreadCount: 0,
                updatedAt: createdAt
            ),
        ]
        state.conversationDrafts = [
            conversationID: ConversationDraft(
                body: "unfinished private draft",
                updatedAt: createdAt.addingTimeInterval(10)
            ),
        ]
        state.messages = [
            LocalMessage(
                id: messageId,
                conversationId: conversationID,
                senderId: "current-user",
                body: "persisted secret message",
                createdAt: createdAt,
                sentAt: nil,
                state: .queued,
                failureReason: nil,
                isOutgoing: true
            ),
        ]
        state.calls = [
            CallRecord(
                id: commandId.uuidString.lowercased(),
                name: "Offline recipient",
                participantUserIds: ["recipient-1"],
                direction: "outgoing",
                type: "voice",
                video: false,
                state: .active,
                startedAt: createdAt,
                endedAt: nil,
                isDeferredAttempt: false,
                conversationId: conversationID,
                answeredAt: createdAt.addingTimeInterval(2)
            ),
        ]
        state.callHistoryBackfillReceipt = CallHistoryBackfillReceipt(
            ownerUserID: "current-user",
            schemaVersion: CallHistoryBackfillPolicy.schemaVersion,
            completedAt: createdAt.addingTimeInterval(-60)
        )
        state.outbox = [
            OfflineCommand(
                id: messageId,
                kind: .secureMessage,
                createdAt: createdAt,
                nextAttemptAt: createdAt,
                attemptCount: 0,
                conversationId: conversationID,
                messageId: messageId,
                recipientUserIds: nil,
                recipientName: nil,
                video: nil,
                expiresAt: nil
            ),
            OfflineCommand(
                id: commandId,
                kind: .callAttempt,
                createdAt: createdAt.addingTimeInterval(1),
                nextAttemptAt: createdAt.addingTimeInterval(1),
                attemptCount: 0,
                conversationId: nil,
                messageId: nil,
                recipientUserIds: ["recipient-1"],
                recipientName: "Offline recipient",
                video: false,
                expiresAt: createdAt.addingTimeInterval(600)
            ),
        ]
        var secureMessaging = SecureMessagingPersistentState.empty
        secureMessaging.identityKeyPair = Data("account-bound-identity".utf8)
        secureMessaging.registrationID = 7
        secureMessaging.syncCursor = "cursor-before-logout"
        state.secureMessaging = secureMessaging
        return state
    }

    private func pendingAvatarAttachment() -> PendingProfileAvatarAttachment {
        PendingProfileAvatarAttachment(
            assetID: "30000000-0000-0000-0000-000000000003",
            ownerUserID: "current-user",
            sessionID: "40000000-0000-0000-0000-000000000004",
            sourceSHA256: String(repeating: "ab", count: 32),
            finalizedAt: Date(timeIntervalSince1970: 1_800_000_120)
        )
    }

    private func privacyCache(
        ownerUserID: String,
        blockedUserID: String
    ) throws -> CommunicationPrivacyCache {
        let preferencesData = try XCTUnwrap(
            """
            {
              "version": 3,
              "phone_discoverable": false,
              "direct_message_requests_enabled": true,
              "incoming_calls_enabled": true,
              "messaging_presence_visible": true,
              "updated_at": "2026-08-20T08:30:00Z"
            }
            """.data(using: .utf8)
        )
        let blockData = try XCTUnwrap(
            """
            {
              "user_id": "\(blockedUserID)",
              "blocked": true,
              "blocked_at": "2026-08-20T08:00:00Z",
              "unblocked_at": null
            }
            """.data(using: .utf8)
        )
        let decoder = JSONDecoder()
        let preferences = try decoder.decode(
            CommunicationPreferencesDTO.self,
            from: preferencesData
        )
        let block = try decoder.decode(CommunicationBlockDTO.self, from: blockData)
        return try XCTUnwrap(CommunicationPrivacyCache(
            ownerUserId: ownerUserID,
            preferences: preferences,
            blocks: [block],
            refreshedAt: Date(timeIntervalSince1970: 1_777_777_777)
        ))
    }

    private func assertEmpty(
        _ state: PersistedState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNil(state.profile, file: file, line: line)
        XCTAssertNil(state.communicationOwnerUserID, file: file, line: line)
        XCTAssertNil(state.sessionAssurance, file: file, line: line)
        XCTAssertTrue(state.wallets.isEmpty, file: file, line: line)
        XCTAssertTrue(state.transactions.isEmpty, file: file, line: line)
        XCTAssertTrue(state.contacts?.isEmpty != false, file: file, line: line)
        XCTAssertNil(state.communicationPrivacy, file: file, line: line)
        XCTAssertTrue(state.conversations.isEmpty, file: file, line: line)
        XCTAssertNil(state.conversationDrafts, file: file, line: line)
        XCTAssertTrue(state.messages.isEmpty, file: file, line: line)
        XCTAssertTrue(state.calls.isEmpty, file: file, line: line)
        XCTAssertNil(state.callHistoryBackfillReceipt, file: file, line: line)
        XCTAssertTrue(state.outbox.isEmpty, file: file, line: line)
        XCTAssertNil(state.secureMessaging, file: file, line: line)
        XCTAssertNil(state.pendingProfileAvatarAttachment, file: file, line: line)
    }
}

private final class TemporarilyUnavailableStateDataLoader: @unchecked Sendable {
    private let lock = NSLock()
    private var failsNextRead = true

    func load(_ url: URL) throws -> Data {
        lock.lock()
        let shouldFail = failsNextRead
        failsNextRead = false
        lock.unlock()
        if shouldFail { throw CocoaError(.fileReadNoPermission) }
        return try Data(contentsOf: url)
    }
}
