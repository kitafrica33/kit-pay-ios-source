import Foundation

/// When a message this person sent reached each of the people it was addressed to.
///
/// Three moments, and only three, because they are the only ones the server genuinely witnessed:
/// it accepted the message for sending, a recipient's device acknowledged carrying the ciphertext
/// away, and that recipient's read marker reached it. Nothing here is derived from what was said —
/// the server has never been able to read that, and this screen does not change it.
struct MessageDeliveryInfo: Equatable, Sendable {
    let messageID: String
    let conversationID: String
    let sentAt: Date
    let recipients: [MessageDeliveryRecipient]

    /// Whether the message has reached everyone's device.
    ///
    /// A thread with nobody else in it reports neither, so a group somebody is alone in shows the
    /// truth rather than a hopeful pair of ticks about an audience of no one.
    var everyoneReceived: Bool {
        !recipients.isEmpty && recipients.allSatisfy { $0.deliveredAt != nil }
    }

    var everyoneRead: Bool {
        !recipients.isEmpty && recipients.allSatisfy { $0.readAt != nil }
    }

    var receivedCount: Int { recipients.lazy.filter { $0.deliveredAt != nil }.count }

    var readCount: Int { recipients.lazy.filter { $0.readAt != nil }.count }
}

/// One person the message was addressed to, and how far it got with them.
///
/// Delivery is the earliest of that person's devices rather than the last, because a phone left in
/// a pocket should not make a laptop's delivery look undelivered. A nil moment means the server
/// has not witnessed it, which is not the same as it having failed.
struct MessageDeliveryRecipient: Equatable, Sendable, Identifiable {
    let userID: String
    /// The server's name for this person, kept only as a fallback: the screen prefers the name
    /// this phone's own address book has for them.
    let serverName: String
    let deliveredAt: Date?
    let readAt: Date?

    var id: String { userID }
}

/// How one witnessed moment is written on the delivery screen.
///
/// Times only, never "3 minutes ago": somebody opens this screen precisely because they want to
/// know when, and a relative phrase makes them do the arithmetic the phone already did.
enum MessageDeliveryMomentFormatter {
    static func label(
        for moment: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let time = timeFormatter(calendar: calendar, locale: locale).string(from: moment)
        if calendar.isDate(moment, inSameDayAs: now) { return "Today at \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(moment, inSameDayAs: yesterday) {
            return "Yesterday at \(time)"
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        // The year is only worth the width when it is not the current one.
        let sameYear = calendar.component(.year, from: moment) == calendar.component(.year, from: now)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "d MMM" : "d MMM yyyy")
        return "\(formatter.string(from: moment)) at \(time)"
    }

    private static func timeFormatter(calendar: Calendar, locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }
}

/// Turns the delivery-info response into something the screen may show, or into nothing.
///
/// Fail closed like every other messaging response: a reply that names another message, repeats a
/// recipient, addresses nobody, or carries a moment that cannot have happened is refused whole
/// rather than shown in part. Half of a delivery record reads as fact just as readily as all of it.
enum MessageDeliveryInfoMapper {
    /// The server's own ceiling on a group, so a response cannot ask this screen to render an
    /// unbounded list of strangers.
    private static let maximumRecipients = SecureMessagingWire.maximumGroupMembers

    /// Long enough for any name a person actually has, short enough that a hostile one cannot push
    /// the rest of the row off the screen.
    private static let maximumNameUTF8Bytes = 256

    /// - Parameter expectedRecipientIDs: A recipient set this device already knows for certain,
    ///   supplied only where certainty exists. A direct chat qualifies: its counterpart cannot
    ///   change, so anybody else named in the reply is somebody the server invented. A group does
    ///   not, because the record is historical to the message — a member added afterwards is
    ///   rightly absent and one since removed is rightly present — so measuring a group against
    ///   today's roster would reject exactly the truthful answers this screen exists to give.
    static func make(
        _ response: MessagingMessageInfoDTO,
        expectedConversationID: String,
        expectedMessageID: String,
        expectedRecipientIDs: Set<String>? = nil
    ) -> MessageDeliveryInfo? {
        guard let messageID = response.messageId,
              let conversationID = response.conversationId,
              messageID == expectedMessageID,
              conversationID == expectedConversationID,
              SecureMessagingWirePolicy.isCanonicalUUID(messageID),
              SecureMessagingWirePolicy.isCanonicalUUID(conversationID),
              let sentAtText = response.sentAt,
              let sentAt = serverDate(sentAtText),
              let rawRecipients = response.recipients,
              // A message this account sent went to somebody. An empty list is the server
              // declining to say rather than reporting that nobody was addressed, and a screen
              // headed "Read by 0 of 0" states that absence as though it were a finding.
              !rawRecipients.isEmpty,
              rawRecipients.count <= maximumRecipients
        else { return nil }

        var recipients: [MessageDeliveryRecipient] = []
        var seen = Set<String>()
        for entry in rawRecipients {
            guard let entry,
                  let userID = entry.userId,
                  SecureMessagingWirePolicy.isCanonicalUUID(userID),
                  seen.insert(userID).inserted,
                  let name = displayableName(entry.name),
                  let deliveredAt = witnessedMoment(entry.deliveredAt, notBefore: sentAt),
                  let readAt = witnessedMoment(entry.readAt, notBefore: sentAt)
            else { return nil }
            // Nobody opens a message that never arrived. A read moment without a delivery, or one
            // that precedes it, describes a sequence of events that cannot have happened, and the
            // sensible reading of an impossible record is that it is not a record.
            if let read = readAt.date {
                guard let delivered = deliveredAt.date, read >= delivered else { return nil }
            }
            recipients.append(
                MessageDeliveryRecipient(
                    userID: userID,
                    serverName: name,
                    deliveredAt: deliveredAt.date,
                    readAt: readAt.date
                )
            )
        }

        if let expectedRecipientIDs, seen != expectedRecipientIDs { return nil }

        return MessageDeliveryInfo(
            messageID: messageID,
            conversationID: conversationID,
            sentAt: sentAt,
            recipients: recipients
        )
    }

    /// A moment the server either witnessed or has not yet.
    ///
    /// This exists to keep "not yet" apart from "unreadable". Both show nothing on the row, but
    /// only the second is a reason to refuse the whole response, and a plain `Date??` would let
    /// one quietly become the other.
    private enum WitnessedMoment {
        case notYet
        case at(Date)

        var date: Date? {
            switch self {
            case .notYet: nil
            case .at(let moment): moment
            }
        }
    }

    private static func witnessedMoment(
        _ rawValue: String?,
        notBefore floor: Date
    ) -> WitnessedMoment? {
        guard let rawValue else { return .notYet }
        // Nothing can be delivered or read before it was sent, so a moment that claims otherwise
        // is a response this screen should not be reading at all.
        guard let moment = serverDate(rawValue), moment >= floor else { return nil }
        return .at(moment)
    }

    private static func displayableName(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maximumNameUTF8Bytes else { return nil }
        return trimmed
    }

    /// The server sends microseconds to clients that can read them and whole seconds to the rest,
    /// so both spellings have to parse here.
    private static func serverDate(_ rawValue: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: rawValue) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: rawValue)
    }
}
