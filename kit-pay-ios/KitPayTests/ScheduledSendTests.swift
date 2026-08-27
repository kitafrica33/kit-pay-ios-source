import XCTest
@testable import KitPay

final class ScheduledSendTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let conversationID = "550e8400-e29b-41d4-a716-446655440000"

    // MARK: - Policy

    func testNormalizeDropsSecondsAndRejectsAnythingInsideTheLeadTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let normalized = ScheduledSendPolicy.normalize(
            now.addingTimeInterval(3_600 + 47),
            now: now,
            calendar: calendar
        )
        let seconds = normalized.map { calendar.component(.second, from: $0) }
        XCTAssertEqual(seconds, 0)

        XCTAssertNil(
            ScheduledSendPolicy.normalize(
                now.addingTimeInterval(30),
                now: now,
                calendar: calendar
            ),
            "A time inside the lead time is not schedulable."
        )
        XCTAssertNil(
            ScheduledSendPolicy.normalize(
                now.addingTimeInterval(-3_600),
                now: now,
                calendar: calendar
            ),
            "The past is never schedulable."
        )
        XCTAssertNil(
            ScheduledSendPolicy.normalize(
                now.addingTimeInterval(ScheduledSendPolicy.maximumHorizon + 60),
                now: now,
                calendar: calendar
            ),
            "Beyond the horizon the app would be holding plaintext indefinitely."
        )
    }

    func testPendingStopsAtTheScheduledMinute() {
        XCTAssertTrue(
            ScheduledSendPolicy.isPending(scheduledAt: now.addingTimeInterval(60), now: now)
        )
        XCTAssertFalse(
            ScheduledSendPolicy.isPending(scheduledAt: now, now: now),
            "A due item is queued, not scheduled — the ordinary sending affordances describe it."
        )
        XCTAssertFalse(ScheduledSendPolicy.isPending(scheduledAt: nil, now: now))
    }

    func testQuickChoicesNeverOfferATimeThatHasAlreadyPassed() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // 23:20 UTC: "this evening" is gone and only forward-looking choices may remain.
        let lateNight = calendar.date(
            from: DateComponents(year: 2027, month: 1, day: 15, hour: 23, minute: 20)
        )!

        let choices = ScheduledSendPolicy.quickChoices(now: lateNight, calendar: calendar)

        XCTAssertFalse(choices.isEmpty)
        for choice in choices {
            XCTAssertTrue(
                ScheduledSendPolicy.isSchedulable(choice.date, now: lateNight),
                "\(choice.title) was offered but is not schedulable."
            )
        }
        XCTAssertFalse(choices.contains { $0.title == "This evening" })
    }

    // MARK: - Queue integration

    func testScheduledMessageDoesNotBlockLaterMessagesInTheSameConversation() {
        let scheduled = scheduledMessageCommand(
            id: "40000000-0000-0000-0000-000000000001",
            createdAt: now,
            scheduledAt: now.addingTimeInterval(3_600)
        )
        var later = messageCommand(
            id: "40000000-0000-0000-0000-000000000002",
            createdAt: now.addingTimeInterval(5),
            nextAttemptAt: now.addingTimeInterval(5)
        )
        later.conversationId = conversationID

        let ready = OutboxPolicy.readyCommands(
            [scheduled, later],
            at: now.addingTimeInterval(10)
        )

        XCTAssertEqual(
            ready.map(\.id),
            [later.id],
            "A message typed after a Send Later item must not wait for that item's send time."
        )
    }

    func testScheduledMessageStillArmsTheWakeTimer() {
        let scheduled = scheduledMessageCommand(
            id: "41000000-0000-0000-0000-000000000001",
            createdAt: now,
            scheduledAt: now.addingTimeInterval(3_600)
        )

        XCTAssertEqual(
            OutboxPolicy.nextWakeDate([scheduled], at: now),
            scheduled.nextAttemptAt,
            "Without a wake the message would only leave the device the next time something else did."
        )
    }

    func testScheduledMessageBecomesRunnableAtItsMinuteAndKeepsItsPlaceInOrder() {
        let scheduled = scheduledMessageCommand(
            id: "42000000-0000-0000-0000-000000000001",
            createdAt: now,
            scheduledAt: now.addingTimeInterval(3_600)
        )
        var later = messageCommand(
            id: "42000000-0000-0000-0000-000000000002",
            createdAt: now.addingTimeInterval(600),
            nextAttemptAt: now.addingTimeInterval(600)
        )
        later.conversationId = conversationID

        let due = now.addingTimeInterval(3_600)
        let ready = OutboxPolicy.readyCommands([later, scheduled], at: due)

        XCTAssertEqual(
            ready.map(\.id),
            [scheduled.id],
            "Once due it is an ordinary message again: oldest first, one head per conversation."
        )
    }

    func testReleasingAScheduledItemKeepsTheSameCommandSoNothingIsSentTwice() {
        var state = PersistedState.empty
        let scheduled = scheduledMessageCommand(
            id: "43000000-0000-0000-0000-000000000001",
            createdAt: now,
            scheduledAt: now.addingTimeInterval(3_600)
        )
        state.outbox = [scheduled]
        state.messages = [localMessage(for: scheduled)]

        XCTAssertTrue(
            OutboxPolicy.releaseScheduledCommand(scheduled.id, in: &state, at: now)
        )

        XCTAssertEqual(state.outbox.count, 1)
        XCTAssertEqual(state.outbox[0].id, scheduled.id)
        XCTAssertEqual(state.outbox[0].nextAttemptAt, now)
        XCTAssertEqual(state.messages[0].scheduledAt, now)
        XCTAssertEqual(
            OutboxPolicy.readyCommands(state.outbox, at: now).map(\.id),
            [scheduled.id]
        )
    }

    func testReschedulingRefusesATimeThatIsNoLongerSchedulable() {
        var state = PersistedState.empty
        let scheduled = scheduledMessageCommand(
            id: "44000000-0000-0000-0000-000000000001",
            createdAt: now,
            scheduledAt: now.addingTimeInterval(3_600)
        )
        state.outbox = [scheduled]
        state.messages = [localMessage(for: scheduled)]

        XCTAssertFalse(
            OutboxPolicy.rescheduleCommand(
                scheduled.id,
                to: now.addingTimeInterval(-60),
                in: &state,
                at: now
            ),
            "A stale picker must not park an item in the past, where it would send at once."
        )
        XCTAssertEqual(state.outbox[0].scheduledAt, scheduled.scheduledAt)

        XCTAssertTrue(
            OutboxPolicy.rescheduleCommand(
                scheduled.id,
                to: now.addingTimeInterval(7_200),
                in: &state,
                at: now
            )
        )
        XCTAssertEqual(state.outbox[0].scheduledAt, now.addingTimeInterval(7_200))
        XCTAssertEqual(state.outbox[0].nextAttemptAt, now.addingTimeInterval(7_200))
        XCTAssertEqual(state.messages[0].scheduledAt, now.addingTimeInterval(7_200))
    }

    func testCancellingRemovesBothTheCommandAndItsUnsentMessage() {
        var state = PersistedState.empty
        let scheduled = scheduledMessageCommand(
            id: "45000000-0000-0000-0000-000000000001",
            createdAt: now,
            scheduledAt: now.addingTimeInterval(3_600)
        )
        state.outbox = [scheduled]
        state.messages = [localMessage(for: scheduled)]

        let removed = OutboxPolicy.cancelScheduledCommand(scheduled.id, in: &state, at: now)

        XCTAssertEqual(removed?.body, "Locally encrypted text")
        XCTAssertTrue(state.outbox.isEmpty)
        XCTAssertTrue(state.messages.isEmpty)
    }

    func testDeferringADueCommandWaitsRatherThanSpendingItsAttempt() {
        var state = PersistedState.empty
        var request = scheduledMessageCommand(
            id: "46000000-0000-0000-0000-000000000001",
            createdAt: now,
            scheduledAt: now
        )
        request.attemptCount = 0
        state.outbox = [request]

        XCTAssertTrue(OutboxPolicy.deferScheduledCommand(request.id, in: &state, at: now))

        XCTAssertEqual(state.outbox[0].attemptCount, 0)
        XCTAssertEqual(state.outbox[0].scheduledAt, now, "The promised time is what the sender saw.")
        XCTAssertTrue(state.outbox[0].nextAttemptAt > now)
        XCTAssertNil(state.outbox[0].failureDisposition)
    }

    func testAFailedScheduledPaymentRequestIsRetainedSoTheSenderCanSeeIt() {
        var state = PersistedState.empty
        let request = OfflineCommand(
            id: UUID(uuidString: "47000000-0000-0000-0000-000000000001")!,
            kind: .scheduledPaymentRequest,
            createdAt: now,
            nextAttemptAt: now,
            attemptCount: 0,
            conversationId: conversationID,
            messageId: nil,
            recipientUserIds: ["recipient-1"],
            recipientName: "Scheduled recipient",
            video: nil,
            expiresAt: nil,
            scheduledAt: now
        )
        state.outbox = [request]

        OutboxPolicy.markPermanentFailure(
            for: request,
            reason: "That wallet is no longer available.",
            in: &state
        )

        XCTAssertEqual(state.outbox.count, 1)
        XCTAssertEqual(state.outbox[0].failureDisposition, .requiresUserRetry)
        XCTAssertEqual(state.outbox[0].lastFailureReason, "That wallet is no longer available.")
        XCTAssertTrue(
            OutboxPolicy.readyCommands(state.outbox, at: now).isEmpty,
            "A failed request must not keep replaying on its own."
        )

        XCTAssertTrue(
            OutboxPolicy.releaseScheduledCommand(request.id, in: &state, at: now),
            "The sender can still ask for it to be tried again."
        )
        XCTAssertNil(state.outbox[0].failureDisposition)
    }

    func testTimelinePositionFollowsTheScheduledMinuteNotComposition() {
        let composed = now
        let promised = now.addingTimeInterval(48 * 3_600)
        var message = localMessage(
            for: scheduledMessageCommand(
                id: "48000000-0000-0000-0000-000000000001",
                createdAt: composed,
                scheduledAt: promised
            )
        )
        message.scheduledAt = promised

        XCTAssertEqual(message.timelineDate, promised)
        message.scheduledAt = nil
        XCTAssertEqual(message.timelineDate, composed)
    }

    // MARK: - Fixtures

    private func messageCommand(
        id: String,
        createdAt: Date,
        nextAttemptAt: Date
    ) -> OfflineCommand {
        OfflineCommand(
            id: UUID(uuidString: id)!,
            kind: .secureMessage,
            createdAt: createdAt,
            nextAttemptAt: nextAttemptAt,
            attemptCount: 0,
            conversationId: conversationID,
            messageId: UUID(uuidString: id)!,
            recipientUserIds: ["recipient-1"],
            recipientName: "Scheduled recipient",
            video: nil,
            expiresAt: nil
        )
    }

    private func scheduledMessageCommand(
        id: String,
        createdAt: Date,
        scheduledAt: Date
    ) -> OfflineCommand {
        var command = messageCommand(
            id: id,
            createdAt: createdAt,
            nextAttemptAt: scheduledAt
        )
        command.scheduledAt = scheduledAt
        return command
    }

    private func localMessage(for command: OfflineCommand) -> LocalMessage {
        LocalMessage(
            id: command.messageId ?? command.id,
            conversationId: command.conversationId ?? conversationID,
            senderId: "current-user",
            body: "Locally encrypted text",
            createdAt: command.createdAt,
            sentAt: nil,
            state: .queued,
            failureReason: nil,
            isOutgoing: true,
            scheduledAt: command.scheduledAt
        )
    }
}
