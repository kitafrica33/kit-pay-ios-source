import CryptoKit
import XCTest
@testable import KitPay

final class MessageBackupTests: XCTestCase {
    private let userID = "0a1b2c3d-0000-4000-8000-00000000aaaa"
    private let otherUserID = "0a1b2c3d-0000-4000-8000-00000000bbbb"
    private let conversationID = "0a1b2c3d-0000-4000-8000-000000001111"
    private let key = Data(repeating: 3, count: MessageBackupCrypto.keyBytes)

    private func makeState() -> PersistedState {
        var state = PersistedState.empty
        state.conversations = [
            Conversation(
                id: conversationID,
                title: "Florence",
                participantUserIds: [userID, otherUserID],
                unreadCount: 2,
                updatedAt: Date(timeIntervalSince1970: 1_700_000_500)
            ),
        ]
        state.messages = [
            LocalMessage(
                id: UUID(uuidString: "0a1b2c3d-0000-4000-8000-00000000cccc")!,
                serverMessageId: "0a1b2c3d-0000-4000-8000-00000000dddd",
                conversationId: conversationID,
                senderId: userID,
                body: "hello",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                sentAt: Date(timeIntervalSince1970: 1_700_000_001),
                state: .sent,
                failureReason: nil,
                isOutgoing: true
            ),
        ]
        state.pinnedConversationIds = [conversationID]
        return state
    }

    // MARK: Crypto

    func testEncryptDecryptRoundTripPreservesPayload() throws {
        let payload = MessageBackupPayload.snapshot(
            of: makeState(),
            userID: userID,
            deviceName: "Kit iPhone",
            includesMedia: true,
            createdAt: Date(timeIntervalSince1970: 1_700_001_000)
        )
        let encrypted = try MessageBackupCrypto.encrypt(payload, key: key)
        XCTAssertTrue(encrypted.starts(with: MessageBackupCrypto.envelopePrefix))
        XCTAssertFalse(encrypted.range(of: Data("hello".utf8)) != nil)

        let decrypted = try MessageBackupCrypto.decrypt(encrypted, key: key)
        XCTAssertEqual(decrypted.userID, userID)
        XCTAssertEqual(decrypted.messages.count, 1)
        XCTAssertEqual(decrypted.messages.first?.body, "hello")
        XCTAssertNil(decrypted.messages.first?.attachmentData)
        XCTAssertEqual(decrypted.conversations.first?.id, conversationID)
        XCTAssertEqual(decrypted.pinnedConversationIds, [conversationID])
        XCTAssertEqual(decrypted.deviceName, "Kit iPhone")
    }

    func testSnapshotWithoutMediaStripsAttachmentData() {
        let payload = MessageBackupPayload.snapshot(
            of: makeState(),
            userID: userID,
            deviceName: "Kit iPhone",
            includesMedia: false
        )
        XCTAssertNil(payload.messages.first?.attachmentData)
        XCTAssertEqual(payload.messages.first?.body, "hello")
    }

    func testSnapshotExcludesEveryNonterminalMessageWithoutBackingUpTheOutbox() {
        var state = makeState()
        let excludedStates: [MessageDeliveryState] = [.queued, .encrypting, .sending, .failed]
        for (offset, deliveryState) in excludedStates.enumerated() {
            state.messages.append(LocalMessage(
                id: UUID(uuidString: String(
                    format: "0a1b2c3d-0000-4000-8000-%012d",
                    offset + 1
                ))!,
                conversationId: conversationID,
                senderId: userID,
                body: "must not restore without its outbox command",
                createdAt: Date(timeIntervalSince1970: 1_700_000_100 + Double(offset)),
                sentAt: nil,
                state: deliveryState,
                failureReason: nil,
                isOutgoing: true
            ))
        }

        let payload = MessageBackupPayload.snapshot(
            of: state,
            userID: userID,
            deviceName: "Kit iPhone",
            includesMedia: false
        )

        XCTAssertEqual(payload.messages.map(\.body), ["hello"])
    }

    func testSnapshotExcludesServerLifecycleNoticesWithoutRestorableProvenance() throws {
        var state = makeState()
        state.messages.append(LocalMessage(
            id: UUID(uuidString: "0a1b2c3d-0000-4000-8000-00000000eeee")!,
            conversationId: conversationID,
            senderId: otherUserID,
            body: try XCTUnwrap(KitSystemMessage(
                kind: .memberLeft,
                subjectUserID: otherUserID,
                actorUserID: nil
            )).encoded,
            createdAt: Date(timeIntervalSince1970: 1_700_000_100),
            sentAt: Date(timeIntervalSince1970: 1_700_000_100),
            state: .received,
            failureReason: nil,
            isOutgoing: false
        ))

        let payload = MessageBackupPayload.snapshot(
            of: state,
            userID: userID,
            deviceName: "Kit iPhone",
            includesMedia: false
        )

        XCTAssertEqual(payload.messages.map(\.body), ["hello"])
    }

    func testSnapshotOmitsLegacyDepartedGroupMessageThatCannotBeRestored() throws {
        let departedUserID = "0a1b2c3d-0000-4000-8000-00000000dddd"
        var state = makeState()
        state.conversations[0].conversationType = SecureMessagingWire.groupConversationType
        var legacyMessage = authenticatedDepartedMemberMessage(senderID: departedUserID)
        let metadata = try XCTUnwrap(legacyMessage.secureMessagingHistory)
        legacyMessage.secureMessagingHistory = SecureMessagingRetainedMessageMetadata(
            clientMessageID: metadata.clientMessageID,
            senderUserID: nil,
            senderDeviceID: metadata.senderDeviceID,
            senderEnrollmentEpoch: metadata.senderEnrollmentEpoch,
            senderSignalDeviceID: metadata.senderSignalDeviceID,
            rosterRevision: metadata.rosterRevision,
            kind: metadata.kind,
            replyToMessageID: metadata.replyToMessageID
        )
        state.messages.append(legacyMessage)

        let payload = MessageBackupPayload.snapshot(
            of: state,
            userID: userID,
            deviceName: "Kit iPhone",
            includesMedia: false,
            createdAt: Date(timeIntervalSince1970: 1_700_001_000)
        )

        XCTAssertEqual(payload.messages.map(\.body), ["hello"])
        XCTAssertNoThrow(try MessageBackupValidationPolicy.validate(
            payload,
            expectedUserID: userID,
            now: validationNow
        ))
    }

    func testSnapshotRetainsSenderBoundReadMessageFromDepartedGroupMember() throws {
        let departedUserID = "0a1b2c3d-0000-4000-8000-00000000dddd"
        var state = makeState()
        state.conversations[0].conversationType = SecureMessagingWire.groupConversationType
        var authenticatedMessage = authenticatedDepartedMemberMessage(senderID: departedUserID)
        authenticatedMessage.state = .read
        state.messages.append(authenticatedMessage)

        let payload = MessageBackupPayload.snapshot(
            of: state,
            userID: userID,
            deviceName: "Kit iPhone",
            includesMedia: false,
            createdAt: Date(timeIntervalSince1970: 1_700_001_000)
        )

        XCTAssertTrue(payload.messages.contains { $0.id == authenticatedMessage.id })
        XCTAssertNoThrow(try MessageBackupValidationPolicy.validate(
            payload,
            expectedUserID: userID,
            now: validationNow
        ))
    }

    func testValidationRejectsNonterminalMessagesFromAnOlderArchive() {
        var state = makeState()
        state.messages[0].state = .queued
        let unsafe = MessageBackupPayload(
            userID: userID,
            createdAt: Date(timeIntervalSince1970: 1_700_001_000),
            deviceName: "Old iPhone",
            conversations: state.conversations,
            messages: state.messages
        )
        XCTAssertThrowsError(try MessageBackupCrypto.encrypt(unsafe, key: key)) { error in
            XCTAssertEqual(error as? MessageBackupError, .invalidBackup)
        }
    }

    func testTamperedCiphertextIsRejected() throws {
        let payload = MessageBackupPayload.snapshot(
            of: makeState(),
            userID: userID,
            deviceName: "Kit iPhone",
            includesMedia: true
        )
        var encrypted = try MessageBackupCrypto.encrypt(payload, key: key)
        encrypted[encrypted.count - 1] ^= 0x01
        XCTAssertThrowsError(try MessageBackupCrypto.decrypt(encrypted, key: key)) { error in
            XCTAssertEqual(error as? MessageBackupError, .authenticationFailed)
        }
    }

    func testWrongKeyIsRejected() throws {
        let payload = MessageBackupPayload.snapshot(
            of: makeState(),
            userID: userID,
            deviceName: "Kit iPhone",
            includesMedia: true
        )
        let encrypted = try MessageBackupCrypto.encrypt(payload, key: key)
        let otherKey = Data(repeating: 9, count: MessageBackupCrypto.keyBytes)
        XCTAssertThrowsError(try MessageBackupCrypto.decrypt(encrypted, key: otherKey)) { error in
            XCTAssertEqual(error as? MessageBackupError, .authenticationFailed)
        }
    }

    func testInvalidKeyLengthIsRejectedBeforeUse() {
        let payload = MessageBackupPayload.snapshot(
            of: makeState(),
            userID: userID,
            deviceName: "Kit iPhone",
            includesMedia: true
        )
        XCTAssertThrowsError(
            try MessageBackupCrypto.encrypt(payload, key: Data(repeating: 1, count: 16))
        ) { error in
            XCTAssertEqual(error as? MessageBackupError, .keyUnavailable)
        }
    }

    func testEnvelopeWithoutPrefixIsRejected() {
        XCTAssertThrowsError(
            try MessageBackupCrypto.decrypt(Data(repeating: 0, count: 128), key: key)
        ) { error in
            XCTAssertEqual(error as? MessageBackupError, .invalidBackup)
        }
    }

    func testAuthenticatedUndecodablePayloadIsReportedAsIncompatible() throws {
        let encrypted = try encryptedEnvelope(containing: Data("not-json".utf8))

        XCTAssertThrowsError(try MessageBackupCrypto.decrypt(encrypted, key: key)) { error in
            XCTAssertEqual(error as? MessageBackupError, .incompatibleBackup)
        }
    }

    func testAuthenticatedPayloadRejectedByCurrentPolicyIsReportedAsIncompatible() throws {
        var payload = MessageBackupPayload.snapshot(
            of: makeState(),
            userID: userID,
            deviceName: "Kit iPhone",
            includesMedia: false,
            createdAt: Date(timeIntervalSince1970: 1_700_001_000)
        )
        payload.schemaVersion = MessageBackupPayload.currentSchemaVersion + 1
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let encrypted = try encryptedEnvelope(containing: encoder.encode(payload))

        XCTAssertThrowsError(try MessageBackupCrypto.decrypt(encrypted, key: key)) { error in
            XCTAssertEqual(error as? MessageBackupError, .incompatibleBackup)
        }
    }

    func testExistingCloudBackupWithoutSyncedKeyNeverMintsReplacement() {
        var createdKey = false

        XCTAssertThrowsError(try MessageBackupUploadKeyPolicy.resolve(
            existingBackup: true,
            existingKey: nil,
            createKey: {
                createdKey = true
                return self.key
            }
        )) { error in
            XCTAssertEqual(error as? MessageBackupError, .keyUnavailable)
        }
        XCTAssertFalse(createdKey)
    }

    func testFirstCloudBackupMayMintKey() throws {
        var createdKey = false

        let resolved = try MessageBackupUploadKeyPolicy.resolve(
            existingBackup: false,
            existingKey: nil,
            createKey: {
                createdKey = true
                return self.key
            }
        )

        XCTAssertTrue(createdKey)
        XCTAssertEqual(resolved, key)
    }

    // MARK: Validation policy

    func testValidationAcceptsRetainedGroupAfterOwnerRemoval() throws {
        let retainedGroup = Conversation(
            id: conversationID,
            title: "Retained group",
            participantUserIds: [otherUserID],
            unreadCount: 0,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_500),
            conversationType: SecureMessagingWire.groupConversationType
        )
        // The owner's already-sent history remains valid even though the current group roster
        // no longer contains the owner; older projections may not have retained E2E metadata.
        let payload = backupPayload(
            conversation: retainedGroup,
            messages: [makeState().messages[0]]
        )

        XCTAssertNoThrow(try MessageBackupValidationPolicy.validate(
            payload,
            expectedUserID: userID,
            now: validationNow
        ))
    }

    func testValidationRejectsDirectConversationWithInvalidCardinality() {
        let thirdUserID = "0a1b2c3d-0000-4000-8000-00000000cccc"
        for participants in [
            [userID],
            [userID, otherUserID, thirdUserID],
        ] {
            let direct = Conversation(
                id: conversationID,
                title: "Invalid direct",
                participantUserIds: participants,
                unreadCount: 0,
                updatedAt: Date(timeIntervalSince1970: 1_700_000_500)
            )

            XCTAssertThrowsError(try MessageBackupValidationPolicy.validate(
                backupPayload(conversation: direct),
                expectedUserID: userID,
                now: validationNow
            )) { error in
                XCTAssertEqual(error as? MessageBackupError, .invalidBackup)
            }
        }
    }

    func testValidationRejectsUnknownConversationType() {
        let unknown = Conversation(
            id: conversationID,
            title: "Unknown",
            participantUserIds: [userID, otherUserID],
            unreadCount: 0,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_500),
            conversationType: "channel"
        )

        XCTAssertThrowsError(try MessageBackupValidationPolicy.validate(
            backupPayload(conversation: unknown),
            expectedUserID: userID,
            now: validationNow
        )) { error in
            XCTAssertEqual(error as? MessageBackupError, .invalidBackup)
        }
    }

    func testValidationRejectsGroupAboveProtocolMemberLimit() {
        let oversizedParticipants = (0 ... SecureMessagingWire.maximumGroupMembers).map {
            String(format: "10000000-0000-4000-8000-%012d", $0)
        }
        XCTAssertEqual(
            oversizedParticipants.count,
            SecureMessagingWire.maximumGroupMembers + 1
        )
        let oversizedGroup = Conversation(
            id: conversationID,
            title: "Oversized group",
            participantUserIds: oversizedParticipants,
            unreadCount: 0,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_500),
            conversationType: SecureMessagingWire.groupConversationType
        )

        XCTAssertThrowsError(try MessageBackupValidationPolicy.validate(
            backupPayload(conversation: oversizedGroup),
            expectedUserID: userID,
            now: validationNow
        )) { error in
            XCTAssertEqual(error as? MessageBackupError, .invalidBackup)
        }
    }

    func testValidationAcceptsAuthenticatedHistoryFromDepartedGroupMember() throws {
        let departedUserID = "0a1b2c3d-0000-4000-8000-00000000dddd"
        let group = Conversation(
            id: conversationID,
            title: "Current group",
            participantUserIds: [userID, otherUserID],
            unreadCount: 0,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_500),
            conversationType: SecureMessagingWire.groupConversationType
        )
        let message = authenticatedDepartedMemberMessage(senderID: departedUserID)

        XCTAssertNoThrow(try MessageBackupValidationPolicy.validate(
            backupPayload(conversation: group, messages: [message]),
            expectedUserID: userID,
            now: validationNow
        ))
    }

    func testValidationRejectsUnprovenOrPartialDepartedGroupSender() {
        let departedUserID = "0a1b2c3d-0000-4000-8000-00000000dddd"
        let group = Conversation(
            id: conversationID,
            title: "Current group",
            participantUserIds: [userID, otherUserID],
            unreadCount: 0,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_500),
            conversationType: SecureMessagingWire.groupConversationType
        )
        let authenticated = authenticatedDepartedMemberMessage(senderID: departedUserID)
        var candidates: [LocalMessage] = []

        var missingHistory = authenticated
        missingHistory.secureMessagingHistory = nil
        candidates.append(missingHistory)

        var missingServerID = authenticated
        missingServerID.serverMessageId = nil
        candidates.append(missingServerID)

        var missingServerTime = authenticated
        missingServerTime.sentAt = nil
        candidates.append(missingServerTime)

        var missingSenderBinding = authenticated
        if let metadata = authenticated.secureMessagingHistory {
            missingSenderBinding.secureMessagingHistory = SecureMessagingRetainedMessageMetadata(
                clientMessageID: metadata.clientMessageID,
                senderUserID: nil,
                senderDeviceID: metadata.senderDeviceID,
                senderEnrollmentEpoch: metadata.senderEnrollmentEpoch,
                senderSignalDeviceID: metadata.senderSignalDeviceID,
                rosterRevision: metadata.rosterRevision,
                kind: metadata.kind,
                replyToMessageID: metadata.replyToMessageID
            )
        }
        candidates.append(missingSenderBinding)

        var mismatchedSenderBinding = authenticated
        if let metadata = authenticated.secureMessagingHistory {
            mismatchedSenderBinding.secureMessagingHistory =
                SecureMessagingRetainedMessageMetadata(
                    clientMessageID: metadata.clientMessageID,
                    senderUserID: otherUserID,
                    senderDeviceID: metadata.senderDeviceID,
                    senderEnrollmentEpoch: metadata.senderEnrollmentEpoch,
                    senderSignalDeviceID: metadata.senderSignalDeviceID,
                    rosterRevision: metadata.rosterRevision,
                    kind: metadata.kind,
                    replyToMessageID: metadata.replyToMessageID
                )
        }
        candidates.append(mismatchedSenderBinding)

        var malformedHistory = authenticated
        malformedHistory.secureMessagingHistory = SecureMessagingRetainedMessageMetadata(
            clientMessageID: "not-a-uuid",
            senderUserID: departedUserID,
            senderDeviceID: "0a1b2c3d-0000-4000-8000-00000000eeee",
            senderEnrollmentEpoch: 1,
            senderSignalDeviceID: 2,
            rosterRevision: "v1:sha256:\(String(repeating: "a", count: 64))",
            kind: .encrypted,
            replyToMessageID: nil
        )
        candidates.append(malformedHistory)

        for candidate in candidates {
            XCTAssertThrowsError(try MessageBackupValidationPolicy.validate(
                backupPayload(conversation: group, messages: [candidate]),
                expectedUserID: userID,
                now: validationNow
            )) { error in
                XCTAssertEqual(error as? MessageBackupError, .invalidBackup)
            }
        }
    }

    func testValidationRejectsSystemNoticeWithoutServerEventProvenance() throws {
        let group = Conversation(
            id: conversationID,
            title: "Current group",
            participantUserIds: [userID, otherUserID],
            unreadCount: 0,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_500),
            conversationType: SecureMessagingWire.groupConversationType
        )
        let notice = LocalMessage(
            id: UUID(uuidString: "0a1b2c3d-0000-4000-8000-00000000eeee")!,
            conversationId: conversationID,
            senderId: otherUserID,
            body: try XCTUnwrap(KitSystemMessage(
                kind: .memberLeft,
                subjectUserID: otherUserID,
                actorUserID: nil
            )).encoded,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            sentAt: Date(timeIntervalSince1970: 1_700_000_001),
            state: .received,
            failureReason: nil,
            isOutgoing: false
        )

        XCTAssertThrowsError(try MessageBackupValidationPolicy.validate(
            backupPayload(conversation: group, messages: [notice]),
            expectedUserID: userID,
            now: validationNow
        )) { error in
            XCTAssertEqual(error as? MessageBackupError, .invalidBackup)
        }
    }

    // MARK: Schedule policy

    func testBackupNeverDueWhenOff() {
        XCTAssertFalse(
            MessageBackupSchedulePolicy.isBackupDue(frequency: .off, lastBackupAt: nil)
        )
        XCTAssertFalse(
            MessageBackupSchedulePolicy.isBackupDue(
                frequency: .off,
                lastBackupAt: Date(timeIntervalSince1970: 0)
            )
        )
    }

    func testFirstBackupIsDueImmediatelyWhenScheduled() {
        for frequency in [MessageBackupFrequency.daily, .weekly, .monthly] {
            XCTAssertTrue(
                MessageBackupSchedulePolicy.isBackupDue(frequency: frequency, lastBackupAt: nil),
                "expected first backup due for \(frequency)"
            )
        }
    }

    func testDailyWeeklyMonthlyIntervalsGateBackups() {
        let now = Date(timeIntervalSince1970: 100 * 24 * 60 * 60)

        XCTAssertFalse(MessageBackupSchedulePolicy.isBackupDue(
            frequency: .daily,
            lastBackupAt: now.addingTimeInterval(-23 * 60 * 60),
            now: now
        ))
        XCTAssertTrue(MessageBackupSchedulePolicy.isBackupDue(
            frequency: .daily,
            lastBackupAt: now.addingTimeInterval(-24 * 60 * 60),
            now: now
        ))

        XCTAssertFalse(MessageBackupSchedulePolicy.isBackupDue(
            frequency: .weekly,
            lastBackupAt: now.addingTimeInterval(-6 * 24 * 60 * 60),
            now: now
        ))
        XCTAssertTrue(MessageBackupSchedulePolicy.isBackupDue(
            frequency: .weekly,
            lastBackupAt: now.addingTimeInterval(-7 * 24 * 60 * 60),
            now: now
        ))

        XCTAssertFalse(MessageBackupSchedulePolicy.isBackupDue(
            frequency: .monthly,
            lastBackupAt: now.addingTimeInterval(-29 * 24 * 60 * 60),
            now: now
        ))
        XCTAssertTrue(MessageBackupSchedulePolicy.isBackupDue(
            frequency: .monthly,
            lastBackupAt: now.addingTimeInterval(-30 * 24 * 60 * 60),
            now: now
        ))
    }

    // MARK: Multi-device conflict merge

    func testConflictMergeCollapsesSameServerMessageWithDifferentLocalIDs() throws {
        let original = MessageBackupPayload.snapshot(
            of: makeState(),
            userID: userID,
            deviceName: "Originating iPhone",
            includesMedia: true,
            createdAt: Date(timeIntervalSince1970: 1_700_001_000)
        )
        var syncedState = makeState()
        let syncedLocalID = UUID(
            uuidString: "0a1b2c3d-0000-4000-8000-00000000eeee"
        )!
        syncedState.messages[0] = LocalMessage(
            id: syncedLocalID,
            serverMessageId: original.messages[0].serverMessageId,
            conversationId: conversationID,
            senderId: userID,
            body: "hello",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            sentAt: Date(timeIntervalSince1970: 1_700_000_002),
            state: .read,
            failureReason: nil,
            isOutgoing: true
        )
        let synced = MessageBackupPayload.snapshot(
            of: syncedState,
            userID: userID,
            deviceName: "Second iPhone",
            includesMedia: true,
            createdAt: Date(timeIntervalSince1970: 1_700_001_100)
        )

        let merged = try MessageBackupConflictPolicy.merge(original, synced)
        let reverseMerged = try MessageBackupConflictPolicy.merge(synced, original)

        XCTAssertEqual(merged.messages.count, 1)
        XCTAssertEqual(merged.messages.first?.id, syncedLocalID)
        XCTAssertEqual(merged.messages.first?.state, .read)
        XCTAssertEqual(merged.messages.first?.serverMessageId, original.messages[0].serverMessageId)
        XCTAssertEqual(merged.messages, reverseMerged.messages)
    }

    func testConflictMergePrefersSenderBoundHistoryForSameServerMessage() throws {
        let departedUserID = "0a1b2c3d-0000-4000-8000-00000000dddd"
        let legacyConversation = Conversation(
            id: conversationID,
            title: "Current group",
            participantUserIds: [userID, otherUserID, departedUserID],
            unreadCount: 0,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_400),
            conversationType: SecureMessagingWire.groupConversationType
        )
        let currentConversation = Conversation(
            id: conversationID,
            title: "Current group",
            participantUserIds: [userID, otherUserID, departedUserID],
            unreadCount: 0,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_500),
            conversationType: SecureMessagingWire.groupConversationType
        )
        let collisionBody = "history before departure 3"
        let senderBoundMessage = authenticatedDepartedMemberMessage(
            senderID: departedUserID,
            body: collisionBody
        )
        var legacyMessage = authenticatedDepartedMemberMessage(
            senderID: departedUserID,
            id: UUID(uuidString: "0a1b2c3d-0000-4000-8000-00000000eeed")!,
            body: collisionBody
        )
        let metadata = try XCTUnwrap(senderBoundMessage.secureMessagingHistory)
        legacyMessage.secureMessagingHistory = SecureMessagingRetainedMessageMetadata(
            clientMessageID: metadata.clientMessageID,
            senderUserID: nil,
            senderDeviceID: metadata.senderDeviceID,
            senderEnrollmentEpoch: metadata.senderEnrollmentEpoch,
            senderSignalDeviceID: metadata.senderSignalDeviceID,
            rosterRevision: metadata.rosterRevision,
            kind: metadata.kind,
            replyToMessageID: metadata.replyToMessageID
        )
        let legacy = backupPayload(
            conversation: legacyConversation,
            messages: [legacyMessage]
        )
        let current = backupPayload(
            conversation: currentConversation,
            messages: [senderBoundMessage]
        )

        let merged = try MessageBackupConflictPolicy.merge(legacy, current)
        let reverseMerged = try MessageBackupConflictPolicy.merge(current, legacy)

        XCTAssertEqual(merged, reverseMerged)
        XCTAssertEqual(
            merged.conversations.first?.participantUserIds,
            [userID, otherUserID, departedUserID]
        )
        XCTAssertEqual(
            merged.messages.first?.secureMessagingHistory?.senderUserID,
            departedUserID
        )
    }

    func testConflictMergeDropsOnlyUnboundHistoryInvalidatedByNewerGroupRoster() throws {
        let departedUserID = "0a1b2c3d-0000-4000-8000-00000000dddd"
        let legacyConversation = Conversation(
            id: conversationID,
            title: "Current group",
            participantUserIds: [userID, otherUserID, departedUserID],
            unreadCount: 0,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_400),
            conversationType: SecureMessagingWire.groupConversationType
        )
        let currentConversation = Conversation(
            id: conversationID,
            title: "Current group",
            participantUserIds: [userID, otherUserID],
            unreadCount: 0,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_500),
            conversationType: SecureMessagingWire.groupConversationType
        )
        let senderBoundMessage = authenticatedDepartedMemberMessage(senderID: departedUserID)
        var legacyMessage = senderBoundMessage
        let metadata = try XCTUnwrap(senderBoundMessage.secureMessagingHistory)
        legacyMessage.secureMessagingHistory = SecureMessagingRetainedMessageMetadata(
            clientMessageID: metadata.clientMessageID,
            senderUserID: nil,
            senderDeviceID: metadata.senderDeviceID,
            senderEnrollmentEpoch: metadata.senderEnrollmentEpoch,
            senderSignalDeviceID: metadata.senderSignalDeviceID,
            rosterRevision: metadata.rosterRevision,
            kind: metadata.kind,
            replyToMessageID: metadata.replyToMessageID
        )
        let oldUnbound = backupPayload(
            conversation: legacyConversation,
            messages: [legacyMessage]
        )
        let oldBound = backupPayload(
            conversation: legacyConversation,
            messages: [senderBoundMessage]
        )
        let currentWithoutMessage = backupPayload(conversation: currentConversation)

        for merged in [
            try MessageBackupConflictPolicy.merge(oldUnbound, currentWithoutMessage),
            try MessageBackupConflictPolicy.merge(currentWithoutMessage, oldUnbound),
        ] {
            XCTAssertEqual(merged.conversations.first?.participantUserIds, [userID, otherUserID])
            XCTAssertTrue(merged.messages.isEmpty)
            XCTAssertNoThrow(try MessageBackupValidationPolicy.validate(
                merged,
                expectedUserID: userID,
                now: validationNow
            ))
        }

        for merged in [
            try MessageBackupConflictPolicy.merge(oldBound, currentWithoutMessage),
            try MessageBackupConflictPolicy.merge(currentWithoutMessage, oldBound),
        ] {
            XCTAssertEqual(merged.messages, [senderBoundMessage])
            XCTAssertNoThrow(try MessageBackupValidationPolicy.validate(
                merged,
                expectedUserID: userID,
                now: validationNow
            ))
        }
    }

    // MARK: Restore merge

    func testRestoreFillsGapsWithoutOverwritingLocalHistory() throws {
        var state = makeState()
        let localMessageID = state.messages[0].id

        var payloadState = PersistedState.empty
        payloadState.conversations = [
            // Same conversation, older timestamp: local copy must win.
            Conversation(
                id: conversationID,
                title: "Old Florence",
                participantUserIds: [userID, otherUserID],
                unreadCount: 9,
                updatedAt: Date(timeIntervalSince1970: 1_699_999_000)
            ),
            // New conversation from the backup: restored with zero unread.
            Conversation(
                id: "0a1b2c3d-0000-4000-8000-000000002222",
                title: "Moses",
                participantUserIds: [userID, otherUserID],
                unreadCount: 4,
                updatedAt: Date(timeIntervalSince1970: 1_700_000_800)
            ),
        ]
        payloadState.messages = [
            // Duplicate of the local message (would clobber): must be ignored.
            LocalMessage(
                id: localMessageID,
                serverMessageId: nil,
                conversationId: conversationID,
                senderId: userID,
                body: "stale copy",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                sentAt: Date(timeIntervalSince1970: 1_700_000_001),
                state: .sent,
                failureReason: nil,
                isOutgoing: true
            ),
            LocalMessage(
                id: UUID(uuidString: "0a1b2c3d-0000-4000-8000-00000000eeee")!,
                serverMessageId: "0a1b2c3d-0000-4000-8000-00000000eeee",
                conversationId: "0a1b2c3d-0000-4000-8000-000000002222",
                senderId: otherUserID,
                body: "restored",
                createdAt: Date(timeIntervalSince1970: 1_700_000_700),
                sentAt: Date(timeIntervalSince1970: 1_700_000_701),
                state: .received,
                failureReason: nil,
                isOutgoing: false
            ),
        ]
        let payload = MessageBackupPayload.snapshot(
            of: payloadState,
            userID: userID,
            deviceName: "Old iPhone",
            includesMedia: true
        )

        try MessageBackupRestorePolicy.merge(payload, into: &state, currentUserID: userID)

        XCTAssertEqual(state.conversations.count, 2)
        let conv1 = state.conversations.first { $0.id == conversationID }
        XCTAssertEqual(conv1?.title, "Florence")
        XCTAssertEqual(conv1?.unreadCount, 2)
        let conv2 = state.conversations.first {
            $0.id == "0a1b2c3d-0000-4000-8000-000000002222"
        }
        XCTAssertEqual(conv2?.unreadCount, 0)

        XCTAssertEqual(state.messages.count, 2)
        XCTAssertEqual(
            state.messages.first { $0.id == localMessageID }?.body,
            "hello",
            "local message must win over the backup copy"
        )
        XCTAssertTrue(state.messages.contains { $0.body == "restored" })
    }

    func testRestoreDoesNotDuplicateSameServerMessageWithDifferentLocalIDs() throws {
        var state = makeState()
        let retainedID = state.messages[0].id
        let serverMessageID = state.messages[0].serverMessageId
        var backupState = makeState()
        backupState.messages[0] = LocalMessage(
            id: UUID(uuidString: "0a1b2c3d-0000-4000-8000-00000000eeee")!,
            serverMessageId: serverMessageID,
            conversationId: conversationID,
            senderId: userID,
            body: "synced duplicate",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            sentAt: Date(timeIntervalSince1970: 1_700_000_002),
            state: .read,
            failureReason: nil,
            isOutgoing: true
        )
        let payload = MessageBackupPayload.snapshot(
            of: backupState,
            userID: userID,
            deviceName: "Second iPhone",
            includesMedia: true,
            createdAt: Date(timeIntervalSince1970: 1_700_001_100)
        )

        try MessageBackupRestorePolicy.merge(payload, into: &state, currentUserID: userID)

        XCTAssertEqual(state.messages.count, 1)
        XCTAssertEqual(state.messages.first?.id, retainedID)
        XCTAssertEqual(state.messages.first?.body, "hello")
    }

    func testRestoreRejectsAnotherAccountsBackup() {
        var state = makeState()
        let payload = MessageBackupPayload.snapshot(
            of: PersistedState.empty,
            userID: "0a1b2c3d-0000-4000-8000-00000000ffff",
            deviceName: "Other iPhone",
            includesMedia: true
        )
        XCTAssertThrowsError(
            try MessageBackupRestorePolicy.merge(payload, into: &state, currentUserID: userID)
        ) { error in
            XCTAssertEqual(error as? MessageBackupError, .accountMismatch)
        }
    }

    // MARK: Preferences backward compatibility

    func testPreferencesDecodeFromEmptyJSONWithDefaults() throws {
        let decoded = try JSONDecoder().decode(
            MessageBackupPreferences.self,
            from: Data("{}".utf8)
        )
        XCTAssertEqual(decoded.frequency, .off)
        XCTAssertFalse(decoded.includesMedia)
        XCTAssertNil(decoded.lastBackupAt)
    }

    func testPersistedStateWithoutBackupFieldsStillDecodes() throws {
        let legacy = Data(#"{"wallets":[],"transactions":[],"conversations":[],"messages":[],"calls":[],"outbox":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(PersistedState.self, from: legacy)
        XCTAssertNil(decoded.messageBackupPreferences)
        XCTAssertNil(decoded.pinnedConversationIds)
        XCTAssertNil(decoded.mutedConversationIds)
    }

    func testRetainedHistoryMetadataWithoutSenderBindingStillDecodes() throws {
        let legacy = Data(#"{"clientMessageID":"0a1b2c3d-0000-4000-8000-00000000ffff","senderDeviceID":"0a1b2c3d-0000-4000-8000-00000000eeee","senderEnrollmentEpoch":1,"senderSignalDeviceID":2,"rosterRevision":"v1:sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","kind":"encrypted","replyToMessageID":null}"#.utf8)

        let decoded = try JSONDecoder().decode(
            SecureMessagingRetainedMessageMetadata.self,
            from: legacy
        )

        XCTAssertNil(decoded.senderUserID)
        XCTAssertEqual(decoded.senderSignalDeviceID, 2)
    }

    func testBackupRequiresReactionKindAndTargetToMatchAuthenticatedHistory() throws {
        let target = "0a1b2c3d-0000-4000-8000-00000000dddd"
        let reaction = try XCTUnwrap(KitMessageReaction(
            operation: .add,
            targetServerMessageID: target,
            emoji: "👍"
        ))
        let messageID = UUID(uuidString: "0a1b2c3d-0000-4000-8000-00000000eeee")!
        var message = LocalMessage(
            id: messageID,
            serverMessageId: messageID.uuidString.lowercased(),
            conversationId: conversationID,
            senderId: otherUserID,
            body: reaction.encoded,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            sentAt: Date(timeIntervalSince1970: 1_700_000_001),
            state: .received,
            failureReason: nil,
            isOutgoing: false,
            secureMessagingHistory: SecureMessagingRetainedMessageMetadata(
                clientMessageID: "0a1b2c3d-0000-4000-8000-00000000ffff",
                senderUserID: otherUserID,
                senderDeviceID: "0a1b2c3d-0000-4000-8000-000000000001",
                senderEnrollmentEpoch: 1,
                senderSignalDeviceID: 2,
                rosterRevision: "v1:sha256:" + String(repeating: "a", count: 64),
                kind: .encryptedReaction,
                replyToMessageID: target
            )
        )
        let conversation = makeState().conversations[0]
        let targetMessage = authenticatedDepartedMemberMessage(
            senderID: otherUserID,
            id: UUID(uuidString: target)!,
            serverMessageID: target,
            clientMessageID: "0a1b2c3d-0000-4000-8000-00000000cccc",
            body: "Message with a reaction"
        )
        XCTAssertNoThrow(try MessageBackupValidationPolicy.validate(
            backupPayload(conversation: conversation, messages: [targetMessage, message]),
            expectedUserID: userID,
            now: validationNow
        ))
        XCTAssertThrowsError(try MessageBackupValidationPolicy.validate(
            backupPayload(conversation: conversation, messages: [message]),
            expectedUserID: userID,
            now: validationNow
        ), "A committed reaction cannot outlive its target")

        let metadata = try XCTUnwrap(message.secureMessagingHistory)
        message.secureMessagingHistory = SecureMessagingRetainedMessageMetadata(
            clientMessageID: metadata.clientMessageID,
            senderUserID: metadata.senderUserID,
            senderDeviceID: metadata.senderDeviceID,
            senderEnrollmentEpoch: metadata.senderEnrollmentEpoch,
            senderSignalDeviceID: metadata.senderSignalDeviceID,
            rosterRevision: metadata.rosterRevision,
            kind: .encrypted,
            replyToMessageID: nil
        )
        XCTAssertThrowsError(try MessageBackupValidationPolicy.validate(
            backupPayload(conversation: conversation, messages: [targetMessage, message]),
            expectedUserID: userID,
            now: validationNow
        ))
        message.secureMessagingHistory = nil
        XCTAssertThrowsError(try MessageBackupValidationPolicy.validate(
            backupPayload(conversation: conversation, messages: [targetMessage, message]),
            expectedUserID: userID,
            now: validationNow
        ))
    }

    func testBackupRejectsReactionWithoutServerIDOrExactSenderProvenance() throws {
        let target = "0a1b2c3d-0000-4000-8000-00000000dddd"
        let reaction = try XCTUnwrap(KitMessageReaction(
            operation: .add,
            targetServerMessageID: target,
            emoji: "👍"
        ))
        let reactionID = UUID(uuidString: "0a1b2c3d-0000-4000-8000-00000000eeee")!
        let targetMessage = authenticatedDepartedMemberMessage(
            senderID: otherUserID,
            id: UUID(uuidString: target)!,
            serverMessageID: target,
            clientMessageID: "0a1b2c3d-0000-4000-8000-00000000cccc",
            body: "Message with a reaction"
        )
        let metadata = SecureMessagingRetainedMessageMetadata(
            clientMessageID: "0a1b2c3d-0000-4000-8000-00000000ffff",
            senderUserID: otherUserID,
            senderDeviceID: "0a1b2c3d-0000-4000-8000-000000000001",
            senderEnrollmentEpoch: 1,
            senderSignalDeviceID: 2,
            rosterRevision: "v1:sha256:" + String(repeating: "a", count: 64),
            kind: .encryptedReaction,
            replyToMessageID: target
        )
        func candidate(
            serverMessageID: String?,
            senderUserID: String?
        ) -> LocalMessage {
            LocalMessage(
                id: reactionID,
                serverMessageId: serverMessageID,
                conversationId: conversationID,
                senderId: otherUserID,
                body: reaction.encoded,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                sentAt: Date(timeIntervalSince1970: 1_700_000_001),
                state: .received,
                failureReason: nil,
                isOutgoing: false,
                secureMessagingHistory: SecureMessagingRetainedMessageMetadata(
                    clientMessageID: metadata.clientMessageID,
                    senderUserID: senderUserID,
                    senderDeviceID: metadata.senderDeviceID,
                    senderEnrollmentEpoch: metadata.senderEnrollmentEpoch,
                    senderSignalDeviceID: metadata.senderSignalDeviceID,
                    rosterRevision: metadata.rosterRevision,
                    kind: metadata.kind,
                    replyToMessageID: metadata.replyToMessageID
                )
            )
        }
        let conversation = makeState().conversations[0]
        for invalid in [
            candidate(serverMessageID: nil, senderUserID: otherUserID),
            candidate(serverMessageID: reactionID.uuidString.lowercased(), senderUserID: nil),
            candidate(serverMessageID: reactionID.uuidString.lowercased(), senderUserID: userID),
        ] {
            XCTAssertThrowsError(try MessageBackupValidationPolicy.validate(
                backupPayload(conversation: conversation, messages: [targetMessage, invalid]),
                expectedUserID: userID,
                now: validationNow
            ))
        }
    }

    private var validationNow: Date {
        Date(timeIntervalSince1970: 1_800_000_000)
    }

    private func encryptedEnvelope(containing cleartext: Data) throws -> Data {
        let sealed = try ChaChaPoly.seal(cleartext, using: SymmetricKey(data: key))
        return MessageBackupCrypto.envelopePrefix + sealed.combined
    }

    private func backupPayload(
        conversation: Conversation,
        messages: [LocalMessage] = []
    ) -> MessageBackupPayload {
        MessageBackupPayload(
            userID: userID,
            createdAt: Date(timeIntervalSince1970: 1_700_001_000),
            deviceName: "Kit iPhone",
            conversations: [conversation],
            messages: messages
        )
    }

    private func authenticatedDepartedMemberMessage(
        senderID: String,
        id: UUID = UUID(uuidString: "0a1b2c3d-0000-4000-8000-00000000eeee")!,
        serverMessageID: String = "0a1b2c3d-0000-4000-8000-00000000eeee",
        clientMessageID: String = "0a1b2c3d-0000-4000-8000-00000000ffff",
        body: String = "history before departure"
    ) -> LocalMessage {
        LocalMessage(
            id: id,
            serverMessageId: serverMessageID,
            conversationId: conversationID,
            senderId: senderID,
            body: body,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            sentAt: Date(timeIntervalSince1970: 1_700_000_001),
            state: .received,
            failureReason: nil,
            isOutgoing: false,
            secureMessagingHistory: SecureMessagingRetainedMessageMetadata(
                clientMessageID: clientMessageID,
                senderUserID: senderID,
                senderDeviceID: "0a1b2c3d-0000-4000-8000-00000000eeee",
                senderEnrollmentEpoch: 1,
                senderSignalDeviceID: 2,
                rosterRevision: "v1:sha256:\(String(repeating: "a", count: 64))",
                kind: .encrypted,
                replyToMessageID: nil
            )
        )
    }
}
