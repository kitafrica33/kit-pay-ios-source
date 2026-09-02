import XCTest
@testable import KitPay

final class OutboxPolicyTests: XCTestCase {
    func testNextWakeDateSchedulesDeferredOfflineMessagesForEncryption() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var unsafeMessage = command(
            id: "05000000-0000-0000-0000-000000000001",
            kind: .secureMessage,
            createdAt: now.addingTimeInterval(-2),
            nextAttemptAt: now.addingTimeInterval(-1)
        )
        unsafeMessage.secureMessageFanout = nil
        let call = command(
            id: "05000000-0000-0000-0000-000000000002",
            kind: .callAttempt,
            createdAt: now,
            nextAttemptAt: now.addingTimeInterval(12)
        )

        XCTAssertEqual(OutboxPolicy.nextWakeDate([unsafeMessage, call]), unsafeMessage.nextAttemptAt)
        XCTAssertEqual(OutboxPolicy.nextWakeDate([unsafeMessage]), unsafeMessage.nextAttemptAt)
        XCTAssertNil(OutboxPolicy.nextWakeDate([call]))
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testReadyCommandsExcludeEveryLegacyCallAttemptAndReplayMessagesOldestFirst() {
        let oldest = command(
            id: "10000000-0000-0000-0000-000000000001",
            kind: .secureMessage,
            createdAt: now.addingTimeInterval(-30),
            nextAttemptAt: now.addingTimeInterval(-1)
        )
        let exactBoundary = command(
            id: "10000000-0000-0000-0000-000000000002",
            kind: .callAttempt,
            createdAt: now.addingTimeInterval(-10),
            nextAttemptAt: now,
            expiresAt: now.addingTimeInterval(60)
        )
        let future = command(
            id: "10000000-0000-0000-0000-000000000003",
            kind: .callAttempt,
            createdAt: now.addingTimeInterval(-60),
            nextAttemptAt: now.addingTimeInterval(1),
            expiresAt: now.addingTimeInterval(60)
        )

        let ready = OutboxPolicy.readyCommands([exactBoundary, future, oldest], at: now)

        XCTAssertEqual(ready.map(\.id), [oldest.id])
    }

    func testLegacyCallAttemptsAreRemovedWithoutDeletingAuthenticatedHistory() {
        let legacy = command(
            id: "12000000-0000-0000-0000-000000000001",
            kind: .callAttempt,
            createdAt: now,
            nextAttemptAt: now,
            expiresAt: now.addingTimeInterval(600)
        )
        let messageCommand = command(
            id: "12000000-0000-0000-0000-000000000002",
            kind: .secureMessage,
            createdAt: now,
            nextAttemptAt: now
        )
        let terminalCommand = command(
            id: "12000000-0000-0000-0000-000000000003",
            kind: .callAttempt,
            createdAt: now.addingTimeInterval(-30),
            nextAttemptAt: now
        )
        var terminal = callRecord(for: terminalCommand, state: .completed)
        terminal.isDeferredAttempt = false
        var state = PersistedState.empty
        state.outbox = [legacy, messageCommand]
        state.calls = [callRecord(for: legacy, state: .queued), terminal]

        XCTAssertEqual(OutboxPolicy.removeLegacyCallAttempts(in: &state), 1)
        XCTAssertEqual(state.outbox.map(\.id), [messageCommand.id])
        XCTAssertEqual(state.calls.map(\.id), [terminal.id])
        XCTAssertEqual(OutboxPolicy.removeLegacyCallAttempts(in: &state), 0)
    }

    func testMessagesRemainFIFOWithinConversationAcrossRetryBackoff() {
        var olderRetry = command(
            id: "11000000-0000-0000-0000-000000000001",
            kind: .secureMessage,
            createdAt: now.addingTimeInterval(-30),
            nextAttemptAt: now.addingTimeInterval(30)
        )
        olderRetry.conversationId = "550e8400-e29b-41d4-a716-446655440001"
        var newerReady = command(
            id: "11000000-0000-0000-0000-000000000002",
            kind: .secureMessage,
            createdAt: now.addingTimeInterval(-20),
            nextAttemptAt: now.addingTimeInterval(-1)
        )
        newerReady.conversationId = olderRetry.conversationId
        var independentReady = command(
            id: "11000000-0000-0000-0000-000000000003",
            kind: .secureMessage,
            createdAt: now.addingTimeInterval(-10),
            nextAttemptAt: now.addingTimeInterval(-1)
        )
        independentReady.conversationId = "550e8400-e29b-41d4-a716-446655440002"

        XCTAssertEqual(
            OutboxPolicy.readyCommands(
                [newerReady, independentReady, olderRetry],
                at: now
            ).map(\.id),
            [independentReady.id]
        )
        XCTAssertEqual(
            OutboxPolicy.nextWakeDate([newerReady, olderRetry]),
            olderRetry.nextAttemptAt
        )

        olderRetry.nextAttemptAt = now
        XCTAssertEqual(
            OutboxPolicy.readyCommands([newerReady, olderRetry], at: now).map(\.id),
            [olderRetry.id]
        )
    }

    func testMessagingConversationIDsMustBeServerIssuedUUIDs() {
        XCTAssertEqual(
            OutboxPolicy.canonicalConversationID(" 550E8400-E29B-41D4-A716-446655440000 "),
            "550e8400-e29b-41d4-a716-446655440000"
        )
        XCTAssertNil(OutboxPolicy.canonicalConversationID("direct:550e8400-e29b-41d4-a716-446655440000"))
        XCTAssertNil(OutboxPolicy.canonicalConversationID("conversation-1"))
        XCTAssertNil(OutboxPolicy.canonicalConversationID(nil))
    }

    func testPrototypeMessageWithoutServerConversationIsQuarantined() {
        var invalid = command(
            id: "25000000-0000-0000-0000-000000000001",
            kind: .secureMessage,
            createdAt: now,
            nextAttemptAt: now
        )
        invalid.conversationId = "direct:550e8400-e29b-41d4-a716-446655440000"
        var canonical = command(
            id: "25000000-0000-0000-0000-000000000002",
            kind: .secureMessage,
            createdAt: now,
            nextAttemptAt: now
        )
        canonical.conversationId = "550e8400-e29b-41d4-a716-446655440001"
        var state = PersistedState.empty
        state.outbox = [invalid, canonical]
        state.messages = [
            message(for: invalid, conversationId: invalid.conversationId!),
            message(for: canonical, conversationId: canonical.conversationId!),
        ]

        XCTAssertEqual(
            OutboxPolicy.quarantineMessagesWithoutServerConversation(in: &state),
            1
        )

        XCTAssertEqual(state.outbox.map(\.id), [canonical.id])
        XCTAssertEqual(state.messages[0].state, .failed)
        XCTAssertEqual(state.messages[0].failureReason, OutboxPolicy.unavailableMessageFailure)
        XCTAssertEqual(state.messages[1].state, .queued)
        XCTAssertNil(state.messages[1].failureReason)
    }

    func testRetryUsesExponentialBackoffCappedAtTwoMinutes() {
        let queued = command(
            id: "30000000-0000-0000-0000-000000000001",
            kind: .secureMessage,
            createdAt: now,
            nextAttemptAt: now
        )
        var state = PersistedState.empty
        state.outbox = [queued]
        let expectedDelays: [TimeInterval] = [10, 20, 40, 80, 120, 120]

        for (offset, expectedDelay) in expectedDelays.enumerated() {
            let failureTime = now.addingTimeInterval(TimeInterval(offset * 1_000))
            OutboxPolicy.scheduleRetry(for: queued, in: &state, at: failureTime)
            XCTAssertEqual(state.outbox[0].attemptCount, offset + 1)
            XCTAssertEqual(
                state.outbox[0].nextAttemptAt,
                failureTime.addingTimeInterval(expectedDelay)
            )
        }
    }

    func testRetryHonorsLongerBoundedServerGuidance() {
        let queued = command(
            id: "31000000-0000-0000-0000-000000000001",
            kind: .secureMessage,
            createdAt: now,
            nextAttemptAt: now
        )
        var state = PersistedState.empty
        state.outbox = [queued]

        OutboxPolicy.scheduleRetry(
            for: queued,
            in: &state,
            at: now,
            retryAfter: 45
        )

        XCTAssertEqual(state.outbox[0].nextAttemptAt, now.addingTimeInterval(45))
        XCTAssertEqual(state.outbox[0].attemptCount, 1)
    }

    func testRetryHonorsServerGuidanceBeyondTheClientBackoffCeiling() {
        let queued = command(
            id: "31000000-0000-0000-0000-000000000002",
            kind: .secureMessage,
            createdAt: now,
            nextAttemptAt: now
        )
        var state = PersistedState.empty
        state.outbox = [queued]

        OutboxPolicy.scheduleRetry(for: queued, in: &state, at: now, retryAfter: 600)

        XCTAssertEqual(state.outbox[0].nextAttemptAt, now.addingTimeInterval(600))
    }

    func testRetryBoundsAnImplausibleServerRequestedDelay() {
        let queued = command(
            id: "31000000-0000-0000-0000-000000000003",
            kind: .secureMessage,
            createdAt: now,
            nextAttemptAt: now
        )
        var state = PersistedState.empty
        state.outbox = [queued]

        OutboxPolicy.scheduleRetry(for: queued, in: &state, at: now, retryAfter: 86_400)

        XCTAssertEqual(
            state.outbox[0].nextAttemptAt,
            now.addingTimeInterval(OutboxPolicy.maximumServerRequestedDelay)
        )
    }

    func testRetryIgnoresServerGuidanceShorterThanTheClientBackoff() {
        let queued = command(
            id: "31000000-0000-0000-0000-000000000004",
            kind: .secureMessage,
            createdAt: now,
            nextAttemptAt: now
        )
        var state = PersistedState.empty
        state.outbox = [queued]

        OutboxPolicy.scheduleRetry(for: queued, in: &state, at: now, retryAfter: 1)

        XCTAssertEqual(state.outbox[0].nextAttemptAt, now.addingTimeInterval(10))
    }

    func testPermanentMessageFailureStopsAutomaticReplayWithoutBlockingNewerMessages() {
        var failed = command(
            id: "32000000-0000-0000-0000-000000000001",
            kind: .secureMessage,
            createdAt: now.addingTimeInterval(-10),
            nextAttemptAt: now
        )
        failed.conversationId = "550e8400-e29b-41d4-a716-446655440000"
        var newer = command(
            id: "32000000-0000-0000-0000-000000000002",
            kind: .secureMessage,
            createdAt: now,
            nextAttemptAt: now
        )
        newer.conversationId = failed.conversationId
        var state = PersistedState.empty
        state.outbox = [failed, newer]
        state.messages = [
            message(for: failed, conversationId: failed.conversationId!),
            message(for: newer, conversationId: newer.conversationId!),
        ]

        OutboxPolicy.markPermanentFailure(
            for: failed,
            reason: "This conversation is no longer available.",
            in: &state
        )

        XCTAssertEqual(state.outbox[0].failureDisposition, .requiresUserRetry)
        XCTAssertEqual(state.messages[0].state, .failed)
        XCTAssertEqual(
            OutboxPolicy.readyCommands(state.outbox, at: now).map(\.id),
            [newer.id]
        )
        XCTAssertNil(OutboxPolicy.nextWakeDate([state.outbox[0]]))
    }

    func testExplicitRetryResumesOnlyTheSelectedFailedMessage() {
        let failed = command(
            id: "33000000-0000-0000-0000-000000000001",
            kind: .secureMessage,
            createdAt: now,
            nextAttemptAt: now
        )
        var state = PersistedState.empty
        state.outbox = [failed]
        state.messages = [message(for: failed, conversationId: failed.conversationId!)]
        OutboxPolicy.markPermanentFailure(
            for: failed,
            reason: "Blocked",
            in: &state
        )

        XCTAssertTrue(OutboxPolicy.canRetryMessage(failed.messageId!, in: state.outbox))
        XCTAssertTrue(
            OutboxPolicy.resumeFailedMessage(
                messageID: failed.messageId!,
                in: &state,
                at: now.addingTimeInterval(1)
            )
        )
        XCTAssertNil(state.outbox[0].failureDisposition)
        XCTAssertNil(state.outbox[0].lastFailureReason)
        XCTAssertEqual(state.outbox[0].attemptCount, 0)
        XCTAssertEqual(state.messages[0].state, .queued)
        XCTAssertNil(state.messages[0].failureReason)
    }

    func testSessionFailuresPauseUntilAuthenticatedResume() {
        let queued = command(
            id: "34000000-0000-0000-0000-000000000001",
            kind: .secureMessage,
            createdAt: now,
            nextAttemptAt: now
        )
        var state = PersistedState.empty
        state.outbox = [queued]

        OutboxPolicy.markAwaitingSession(
            for: queued,
            reason: "Sign in again to continue.",
            in: &state
        )

        XCTAssertTrue(OutboxPolicy.readyCommands(state.outbox, at: now).isEmpty)
        XCTAssertNil(OutboxPolicy.nextWakeDate(state.outbox))
        XCTAssertEqual(
            OutboxPolicy.resumeSessionDeferredCommands(
                in: &state,
                at: now.addingTimeInterval(2)
            ),
            1
        )
        XCTAssertEqual(
            OutboxPolicy.readyCommands(state.outbox, at: now.addingTimeInterval(2)).map(\.id),
            [queued.id]
        )
    }

    func testFailureClassificationRetriesOnlyTransientConditions() {
        XCTAssertEqual(
            OutboxPolicy.failureDecision(
                for: APIErrorPayload(
                    code: "TOO_MANY_REQUESTS",
                    message: "Wait",
                    httpStatus: 429,
                    retryAfter: 30
                )
            ),
            .retry(after: 30)
        )
        XCTAssertEqual(
            OutboxPolicy.failureDecision(
                for: APIErrorPayload(
                    code: "CONVERSATION_NOT_FOUND",
                    message: "Missing",
                    httpStatus: 404
                )
            ),
            .permanent
        )
        XCTAssertEqual(
            OutboxPolicy.failureDecision(
                for: APIErrorPayload(
                    code: "CALL_ATTEMPT_NOT_EXPIRED",
                    message: "Wait for the original ringing window to close.",
                    httpStatus: 422,
                    retryAfter: 7
                )
            ),
            .retry(after: 7)
        )
        XCTAssertEqual(
            OutboxPolicy.failureDecision(for: APIClientError.signedOut),
            .awaitSession
        )
        XCTAssertEqual(
            OutboxPolicy.failureDecision(
                for: APIErrorPayload(
                    code: "CALL_ATTEMPT_NOT_EXPIRED",
                    message: "Unauthenticated",
                    httpStatus: 401,
                    retryAfter: 30
                )
            ),
            .awaitSession
        )
        XCTAssertEqual(
            OutboxPolicy.failureDecision(for: URLError(.networkConnectionLost)),
            .retry(after: nil)
        )
        XCTAssertEqual(
            OutboxPolicy.failureDecision(for: APIClientError.invalidURL),
            .permanent
        )
        XCTAssertEqual(
            OutboxPolicy.failureDecision(
                for: SecureMessagingActivationError.incompleteServerStatus
            ),
            .retry(after: nil)
        )
        XCTAssertEqual(
            OutboxPolicy.failureDecision(
                for: SecureMessagingActivationError.replenishmentRejected
            ),
            .retry(after: nil)
        )
        XCTAssertEqual(
            OutboxPolicy.failureDecision(
                for: SecureMessagingActivationError.accountChanged
            ),
            .retry(after: nil),
            "A replacement account is already authenticated, so waiting for another login would strand its command."
        )
        for activationError in [
            SecureMessagingActivationError.invalidUser,
            .missingLocalEnrollment,
            .serverEnrollmentChanged,
        ] {
            XCTAssertEqual(
                OutboxPolicy.failureDecision(for: activationError),
                .awaitSession
            )
        }
        XCTAssertEqual(
            OutboxPolicy.failureDecision(
                for: SecureMessagingExchangeError.groupCapabilityUnavailable
            ),
            .retry(after: nil)
        )
        XCTAssertEqual(
            OutboxPolicy.failureDecision(
                for: SecureMessagingExchangeError.richMediaCapabilityUnavailable
            ),
            .retry(after: nil)
        )
        XCTAssertEqual(
            OutboxPolicy.failureDecision(
                for: SecureMessagingExchangeError.mediaMessageCapabilityUnavailable
            ),
            .retry(after: nil)
        )
        XCTAssertEqual(
            OutboxPolicy.failureDecision(for: SecureMediaAttachmentError.incompatibleRecipient),
            .retry(after: nil)
        )
        XCTAssertEqual(
            OutboxPolicy.failureDecision(for: SecureMediaAttachmentError.invalidMedia),
            .permanent
        )
        XCTAssertEqual(
            OutboxPolicy.failureDecision(
                for: SecureMessagingExchangeError.reactionCapabilityUnavailable
            ),
            .permanent
        )
    }

    func testUnsupportedReactionIsRetiredWithoutBlockingLaterText() throws {
        let now = Date(timeIntervalSince1970: 1_777_777_777)
        let reactionMessageID = UUID()
        let laterMessageID = UUID()
        let reaction = try XCTUnwrap(
            KitMessageReaction(
                operation: .add,
                targetServerMessageID: UUID().uuidString.lowercased(),
                emoji: "👍"
            )
        )
        var reactionCommand = command(
            id: reactionMessageID.uuidString,
            kind: .secureMessage,
            createdAt: now,
            nextAttemptAt: now
        )
        reactionCommand.conversationId = "550e8400-e29b-41d4-a716-446655440000"
        var laterCommand = command(
            id: laterMessageID.uuidString,
            kind: .secureMessage,
            createdAt: now.addingTimeInterval(1),
            nextAttemptAt: now.addingTimeInterval(1)
        )
        laterCommand.conversationId = reactionCommand.conversationId
        var state = PersistedState.empty
        state.messages = [
            LocalMessage(
                id: reactionMessageID,
                conversationId: reactionCommand.conversationId!,
                senderId: "current-user",
                body: reaction.encoded,
                createdAt: now,
                sentAt: nil,
                state: .queued,
                failureReason: nil,
                isOutgoing: true
            ),
            LocalMessage(
                id: laterMessageID,
                conversationId: laterCommand.conversationId!,
                senderId: "current-user",
                body: "still sends",
                createdAt: now.addingTimeInterval(1),
                sentAt: nil,
                state: .queued,
                failureReason: nil,
                isOutgoing: true
            ),
        ]
        state.outbox = [reactionCommand, laterCommand]

        OutboxPolicy.markPermanentFailure(
            for: reactionCommand,
            reason: SecureMessagingExchangeError.reactionCapabilityUnavailable.localizedDescription,
            in: &state
        )

        XCTAssertEqual(state.outbox.map(\.id), [laterCommand.id])
        XCTAssertEqual(state.messages.map(\.id), [laterMessageID])
        XCTAssertEqual(
            OutboxPolicy.readyCommands(state.outbox, at: now.addingTimeInterval(2)).map(\.id),
            [laterCommand.id]
        )
    }

    func testLegacyOutboxCommandDecodesWithoutFailureDispositionFields() throws {
        let original = command(
            id: "35000000-0000-0000-0000-000000000001",
            kind: .secureMessage,
            createdAt: now,
            nextAttemptAt: now
        )
        let encoded = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "failureDisposition")
        object.removeValue(forKey: "lastFailureReason")

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let restored = try JSONDecoder().decode(OfflineCommand.self, from: legacyData)

        XCTAssertEqual(restored.id, original.id)
        XCTAssertNil(restored.failureDisposition)
        XCTAssertNil(restored.lastFailureReason)
    }

    func testAcknowledgedTerminationClearsAllMatchingReplaysAndPreservesTerminalHistory() {
        let callID = "550e8400-e29b-41d4-a716-446655440000"
        var decline = command(
            id: "45000000-0000-0000-0000-000000000001",
            kind: .callTermination,
            createdAt: now,
            nextAttemptAt: now
        )
        decline.callId = callID
        decline.terminationKind = .decline
        var staleEnd = command(
            id: "45000000-0000-0000-0000-000000000002",
            kind: .callTermination,
            createdAt: now,
            nextAttemptAt: now
        )
        staleEnd.callId = callID.uppercased()
        staleEnd.terminationKind = .end
        let unrelated = command(
            id: "45000000-0000-0000-0000-000000000003",
            kind: .secureMessage,
            createdAt: now,
            nextAttemptAt: now.addingTimeInterval(30)
        )
        var state = PersistedState.empty
        state.outbox = [decline, staleEnd, unrelated]
        state.calls = [
            CallRecord(
                id: callID,
                name: "Alice",
                participantUserIds: [],
                direction: "incoming",
                type: "voice",
                video: false,
                state: .ringing,
                startedAt: now.addingTimeInterval(-10),
                endedAt: nil,
                isDeferredAttempt: false
            ),
        ]

        OutboxPolicy.acknowledgeTermination(
            callId: callID,
            kind: .decline,
            in: &state,
            at: now
        )

        XCTAssertEqual(state.outbox.map(\.id), [unrelated.id])
        XCTAssertEqual(state.calls[0].state, .declined)
        XCTAssertEqual(state.calls[0].endedAt, now)

        state.calls[0].state = .missed
        let authoritativeEnd = now.addingTimeInterval(-1)
        state.calls[0].endedAt = authoritativeEnd
        OutboxPolicy.acknowledgeTermination(
            callId: callID,
            kind: .decline,
            in: &state,
            at: now.addingTimeInterval(1)
        )
        XCTAssertEqual(state.calls[0].state, .missed)
        XCTAssertEqual(state.calls[0].endedAt, authoritativeEnd)
    }

    private func command(
        id: String,
        kind: OfflineCommandKind,
        createdAt: Date,
        nextAttemptAt: Date,
        recipientUserIds: [String]? = ["recipient-1"],
        video: Bool? = false,
        expiresAt: Date? = nil
    ) -> OfflineCommand {
        OfflineCommand(
            id: UUID(uuidString: id)!,
            kind: kind,
            createdAt: createdAt,
            nextAttemptAt: nextAttemptAt,
            attemptCount: 0,
            conversationId: kind == .secureMessage ? "conversation-1" : nil,
            messageId: kind == .secureMessage ? UUID(uuidString: id)! : nil,
            recipientUserIds: recipientUserIds,
            recipientName: kind == .callAttempt ? "Offline recipient" : nil,
            video: video,
            expiresAt: expiresAt
        )
    }

    private func callRecord(for command: OfflineCommand, state: CallState) -> CallRecord {
        CallRecord(
            id: command.id.uuidString.lowercased(),
            name: "Offline recipient",
            participantUserIds: command.recipientUserIds ?? [],
            direction: "outgoing",
            type: command.video == true ? "video" : "voice",
            video: command.video == true,
            state: state,
            startedAt: command.createdAt,
            endedAt: nil,
            isDeferredAttempt: true
        )
    }

    private func message(for command: OfflineCommand, conversationId: String) -> LocalMessage {
        LocalMessage(
            id: command.messageId!,
            conversationId: conversationId,
            senderId: "current-user",
            body: "Locally encrypted text",
            createdAt: command.createdAt,
            sentAt: nil,
            state: .queued,
            failureReason: nil,
            isOutgoing: true
        )
    }

}
