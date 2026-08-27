import Foundation

/// Turning a group payment into the one or two lines a member actually reads in the chat.
///
/// Two rules run through all of it. Nobody is told an amount the server did not disclose to them,
/// so a custom split announces itself without a figure and the recipient learns their own share
/// from the card. And nothing here claims more than it can know: an outcome line describes the
/// action of the member who authored it and no one else's.
enum GroupPaymentCopy {
    /// How many names to spell out before falling back to counting the rest.
    static let maximumNamedRecipients = 3

    /// "Ama", "Ama and Ben", "Ama, Ben and Cara", "Ama, Ben and 4 others".
    static func nameList(_ names: [String], totalCount: Int? = nil) -> String? {
        let names = names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let total = max(totalCount ?? names.count, names.count)
        guard !names.isEmpty else { return nil }

        if names.count >= total, total <= maximumNamedRecipients {
            switch names.count {
            case 1: return names[0]
            case 2: return "\(names[0]) and \(names[1])"
            default:
                return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
            }
        }

        let shown = Array(names.prefix(maximumNamedRecipients))
        let remaining = total - shown.count
        guard remaining > 0 else { return shown.joined(separator: ", ") }
        let others = remaining == 1 ? "1 other" : "\(remaining) others"
        return shown.joined(separator: ", ") + " and " + others
    }

    /// The announcement line: who paid whom, and how much when the group is allowed to know.
    ///
    /// - Parameters:
    ///   - senderName: display name of the member who sent, ignored when `isViewerSender`.
    ///   - recipientNames: resolved names for `descriptor.recipientUserIds`, in that order.
    ///   - totalOverride: a total the server disclosed to *this* viewer that the descriptor is not
    ///     allowed to carry — in practice the sender's own view of a custom split.
    static func announcement(
        for descriptor: KitGroupPaymentMessage,
        senderName: String,
        isViewerSender: Bool,
        recipientNames: [String],
        totalOverride: String? = nil
    ) -> String {
        let who = isViewerSender ? "You" : senderName
        let amount = disclosedTotal(for: descriptor, totalOverride: totalOverride)

        let audience: String
        switch descriptor.audience {
        case .all:
            audience = "everyone"
        case .selected, nil:
            audience = nameList(recipientNames, totalCount: descriptor.recipientCount)
                ?? memberCount(descriptor.recipientCount)
        }

        guard let amount else {
            // A custom split with no figure to show. "Payments", plural and unquantified, is the
            // most this viewer is allowed to be told.
            return "\(who) sent payments to \(audience)"
        }
        return "\(who) sent \(amount) to \(audience)"
    }

    /// The per-member line under the announcement of an even split, so a recipient can see what is
    /// coming to them before the card has loaded. Absent when the pot was never disclosed.
    static func evenShareSubtitle(for descriptor: KitGroupPaymentMessage) -> String? {
        guard descriptor.splitMode == .even,
              let shareMinor = descriptor.evenShareMinor,
              let code = descriptor.currencyCode,
              let scale = descriptor.currencyScale,
              let recipientCount = descriptor.recipientCount,
              recipientCount > 1
        else { return nil }
        let share = KitMoney.formatted(minorUnits: shareMinor, code: code, scale: scale)
        // The odd minor unit has to land somewhere, so an inexact division is described as
        // "about" rather than quoting a figure one member will not receive.
        return descriptor.dividesEvenly ? "\(share) each" : "About \(share) each"
    }

    /// The small centred line an outcome posts into the thread. Deliberately only ever about the
    /// member who authored it.
    static func outcome(
        _ action: KitGroupPaymentMessageAction,
        actorName: String,
        isViewerActor: Bool
    ) -> String? {
        let who = isViewerActor ? "You" : actorName
        switch action {
        case .accepted:
            return isViewerActor ? "You took your share" : "\(who) took their share"
        case .rejected:
            return isViewerActor ? "You declined your share" : "\(who) declined their share"
        case .returned:
            return isViewerActor
                ? "You returned the unclaimed shares"
                : "\(who) returned the unclaimed shares"
        case .sent:
            return nil
        }
    }

    /// Progress for the sender: counts only, so it means the same thing to a member who was never
    /// shown the amounts.
    static func progress(for payment: GroupPaymentDTO) -> String {
        let total = max(payment.recipientCount, payment.resolvedCount)
        guard total > 0 else { return "No shares" }
        if payment.pendingCount == 0 {
            return payment.returnedCount == 0
                ? "All \(total) shares taken"
                : "\(payment.acceptedCount) of \(total) taken, \(payment.returnedCount) returned"
        }
        return "\(payment.acceptedCount) of \(total) taken, \(payment.pendingCount) waiting"
    }

    /// What a recipient's own card says about where their share stands.
    static func shareStatus(_ status: GroupPaymentShareStatus) -> String {
        switch status {
        case .pending: "Waiting for you"
        case .accepted: "In your wallet"
        case .rejected: "You declined this"
        case .reversed: "Returned to the sender"
        case .expired: "Expired and returned"
        }
    }

    /// Where a recipient's line in the sender's list has got to.
    static func recipientStatus(_ status: GroupPaymentShareStatus) -> String {
        switch status {
        case .pending: "Waiting"
        case .accepted: "Taken"
        case .rejected: "Declined"
        case .reversed: "Returned"
        case .expired: "Expired"
        }
    }

    /// Said on the card itself, because it is the whole reason there is no accept button in the
    /// transfers inbox for this money.
    static let groupOnlyClaimNote = "Money sent to a group is claimed here, in the group."

    private static func disclosedTotal(
        for descriptor: KitGroupPaymentMessage,
        totalOverride: String?
    ) -> String? {
        guard let code = descriptor.currencyCode, let scale = descriptor.currencyScale else {
            return nil
        }
        if let totalOverride, !totalOverride.isEmpty {
            return KitMoney.formatted(totalOverride, code: code, scale: scale)
        }
        guard let minor = descriptor.totalAmountMinor else { return nil }
        return KitMoney.formatted(minorUnits: minor, code: code, scale: scale)
    }

    private static func memberCount(_ count: Int?) -> String {
        guard let count, count > 0 else { return "the group" }
        return count == 1 ? "1 member" : "\(count) members"
    }
}

/// Which bubbles in a group thread carry their sender's name.
///
/// A name is a heading for a run, not a label on every line: it appears on the first message of a
/// stretch by one member and stays off until somebody else speaks, a card or call interrupts, or
/// the day changes. Messages that render nothing — album followers, reaction events, forged system
/// wire — are skipped rather than treated as a change of speaker, so a silent event by another
/// member cannot make the same person be introduced twice in a row.
enum ConversationSenderRunPolicy {
    static func namedMessageIDs(
        in items: [ConversationTimelineItem],
        isGroup: Bool,
        isRendered: (LocalMessage) -> Bool = { _ in true }
    ) -> Set<UUID> {
        guard isGroup else { return [] }

        var named: Set<UUID> = []
        var runSender: String?

        for item in items {
            switch item {
            case .message(let message):
                guard isRendered(message) else { continue }
                // Outgoing bubbles never show a name, but they do end somebody else's run: the
                // next incoming message needs its heading back.
                guard !message.isOutgoing else {
                    runSender = "self"
                    continue
                }
                let sender = message.senderId.lowercased()
                if sender != runSender {
                    named.insert(message.id)
                    runSender = sender
                }
            case .payment, .groupPayment, .groupPaymentEvent, .call, .dateSeparator:
                // A full-width card, a call row, or a new day is a visual break; whoever speaks
                // next is introduced again.
                runSender = nil
            }
        }
        return named
    }
}
