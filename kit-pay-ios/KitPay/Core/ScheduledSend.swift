import Foundation

/// Pure rules for Send Later.
///
/// A scheduled item is an ordinary outbox command whose first attempt is dated in the future.
/// Nothing about the transport, the encryption, or the idempotency of a send changes: the queue
/// already replays commands whose `nextAttemptAt` has arrived, already survives restarts, and
/// already waits out an offline device. Scheduling therefore adds a date, not a second pipeline —
/// which is what keeps a scheduled message from ever being delivered twice.
enum ScheduledSendPolicy {
    /// Below this the picker's own confirmation tap would already be late, and "later" stops
    /// meaning anything to the person choosing it.
    static let minimumLeadTime: TimeInterval = 60

    /// One year. Past that a "message" is really a reminder, and the account-bound encrypted
    /// state would be holding someone's plaintext far longer than they meant to agree to.
    static let maximumHorizon: TimeInterval = 365 * 24 * 60 * 60

    /// Seconds are dropped: the picker is minute-resolution, so storing 18:30:47 would show
    /// "18:30" and then send 47 seconds after the minute it promised.
    static func normalize(
        _ date: Date,
        now: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date? {
        let candidate = canonicalMinute(date, calendar: calendar)
        guard isSchedulable(candidate, now: now) else { return nil }
        return candidate
    }

    /// The minute a request would normalize to, independent of the clock. Idempotent retries
    /// compare this against a stored schedule whose eligibility window has since moved: the
    /// instant was admissible when first queued, and a later retry is still the same send.
    static func canonicalMinute(
        _ date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date {
        var components = calendar.dateComponents(
            [.era, .year, .month, .day, .hour, .minute],
            from: date
        )
        components.second = 0
        return calendar.date(from: components) ?? date
    }

    static func isSchedulable(_ date: Date, now: Date) -> Bool {
        let lead = date.timeIntervalSince(now)
        return lead >= minimumLeadTime && lead <= maximumHorizon
    }

    /// True while the item is still waiting for its moment. A due-but-unsent item (the device was
    /// offline, or the app was closed) is deliberately no longer "scheduled": it is queued, and
    /// the ordinary queued/sending affordances describe it honestly.
    static func isPending(scheduledAt: Date?, now: Date) -> Bool {
        guard let scheduledAt else { return false }
        return scheduledAt > now
    }

    static func earliestSelectableDate(now: Date) -> Date {
        now.addingTimeInterval(minimumLeadTime)
    }

    static func latestSelectableDate(now: Date) -> Date {
        now.addingTimeInterval(maximumHorizon)
    }

    /// The date the picker opens on: the next whole hour, or tomorrow morning once the day is
    /// nearly over, so the common case needs no scrolling at all.
    static func defaultSuggestion(
        now: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date {
        if let nextHour = calendar.nextDate(
            after: now,
            matching: DateComponents(minute: 0, second: 0),
            matchingPolicy: .nextTime
        ), nextHour.timeIntervalSince(now) >= minimumLeadTime,
           calendar.component(.hour, from: nextHour) >= 7,
           calendar.component(.hour, from: nextHour) <= 21 {
            return nextHour
        }
        return tomorrowMorning(now: now, calendar: calendar)
    }

    static func tomorrowMorning(
        now: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date {
        let startOfTomorrow = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: now)
        ) ?? now.addingTimeInterval(24 * 60 * 60)
        return calendar.date(
            bySettingHour: 8,
            minute: 0,
            second: 0,
            of: startOfTomorrow
        ) ?? startOfTomorrow
    }

    /// The one-tap choices offered above the picker. Anything that has already passed, or that
    /// lands inside the lead time, is dropped rather than shown greyed out.
    static func quickChoices(
        now: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [ScheduledSendChoice] {
        var choices: [ScheduledSendChoice] = []
        let inAnHour = now.addingTimeInterval(60 * 60)
        choices.append(ScheduledSendChoice(title: "In an hour", date: inAnHour))

        if let thisEvening = calendar.nextDate(
            after: now,
            matching: DateComponents(hour: 18, minute: 0, second: 0),
            matchingPolicy: .nextTime
        ), calendar.isDate(thisEvening, inSameDayAs: now) {
            choices.append(ScheduledSendChoice(title: "This evening", date: thisEvening))
        }

        choices.append(
            ScheduledSendChoice(
                title: "Tomorrow morning",
                date: tomorrowMorning(now: now, calendar: calendar)
            )
        )
        return choices.filter { isSchedulable($0.date, now: now) }
    }

    /// "Today at 18:30" / "Tomorrow at 08:00" / "Fri 29 Aug at 08:00", localized by the caller's
    /// formatters. Kept here so the bubble, the composer chip and the confirmation all agree.
    static func label(
        for date: Date,
        now: Date,
        calendar: Calendar,
        time: (Date) -> String,
        day: (Date) -> String
    ) -> String {
        let clock = time(date)
        if calendar.isDate(date, inSameDayAs: now) { return "Today at \(clock)" }
        let tomorrow = calendar.startOfDay(for: now.addingTimeInterval(24 * 60 * 60))
        if calendar.isDate(date, inSameDayAs: tomorrow) { return "Tomorrow at \(clock)" }
        return "\(day(date)) at \(clock)"
    }

    /// Shown under a scheduled bubble while the device has no connection: the promise the app can
    /// actually keep is "as soon as you are back online", not "at 18:30 exactly".
    static let offlineFootnote = "Kit sends this as soon as you're back online."
}

struct ScheduledSendChoice: Identifiable, Equatable, Sendable {
    let title: String
    let date: Date

    var id: String { title }
}

/// Everything the request composer has decided, handed to whoever owns the outbox. Kept as one
/// value so the scheduling closure cannot be called with a recipient from one screen and an amount
/// from another.
struct PaymentRequestScheduleDraft: Equatable, Sendable {
    let destinationWalletID: String
    let recipientUserID: String
    let recipientName: String
    /// Canonical API amount, already normalized to the wallet's scale.
    let amount: String
    let currencyCode: String
    let note: String?
    let deliverAt: Date
}

/// One item waiting for its send time, projected for the conversation timeline. Scheduled text and
/// media live in `messages`; a scheduled payment request has no message yet (its descriptor needs
/// a server-confirmed request id), so it is projected straight from its outbox command.
struct ScheduledChatItem: Identifiable, Equatable, Sendable {
    enum Content: Equatable, Sendable {
        case message(UUID)
        case paymentRequest(commandID: UUID)
    }

    let id: UUID
    let conversationID: String
    let scheduledAt: Date
    let content: Content
    /// One line describing what will be sent — the message text, the attachment kind, or the
    /// requested amount. Never the ciphertext, and never more than the bubble can show.
    let preview: String

    var isPaymentRequest: Bool {
        if case .paymentRequest = content { return true }
        return false
    }
}
