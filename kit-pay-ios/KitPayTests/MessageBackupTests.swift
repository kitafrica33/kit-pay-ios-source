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
            XCTAssertEqual(error as? MessageBackupError, .invalidBackup)
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
            XCTAssertEqual(error as? MessageBackupError, .invalidBackup)
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
}
