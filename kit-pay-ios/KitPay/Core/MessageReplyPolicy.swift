import CoreGraphics
import Foundation

/// Pure geometry for the swipe-to-reply gesture, kept out of the view so the feel of it can be
/// tested without a simulator. The numbers are the same ones the Android build uses, so the
/// gesture arms at the same place in the drag on both platforms.
enum SwipeToReplyPolicy {
    enum DragAxis: Equatable {
        case undecided
        case horizontal
        case vertical
    }

    /// How far the bubble is ever allowed to travel under the finger.
    static let maximumTravel: CGFloat = 68
    /// How far the drag has to reach before letting go composes an answer.
    static let replyTrigger: CGFloat = 52
    /// Let the scroll view's ten-point pan recognizer establish vertical movement before a
    /// message row considers adopting the same touch for reply.
    static let activationDistance: CGFloat = 20
    /// A diagonal drag belongs to reading history. Reply adopts only a deliberately sideways
    /// gesture, and the first direction decision stays locked until that finger lifts.
    static let horizontalDominance: CGFloat = 1.5

    /// Past `maximumTravel` the bubble keeps moving, but only barely — enough that the drag
    /// still feels alive under the finger without sliding the whole conversation sideways.
    private static let overshootRate: CGFloat = 0.18
    private static let maximumOvershoot: CGFloat = 1.2

    /// Classifies and permanently locks one drag's intent. A vertical decision is sticky: a
    /// scrolling finger that curves sideways later must never wake a row gesture halfway through
    /// the scroll. Once the threshold is crossed, every ambiguous diagonal is treated as vertical
    /// so reading history always wins over an accidental reply.
    static func lockedAxis(
        current: DragAxis,
        translation: CGSize,
        minimumDistance: CGFloat = activationDistance,
        horizontalRatio: CGFloat = horizontalDominance
    ) -> DragAxis {
        guard current == .undecided else { return current }
        guard minimumDistance >= 0, horizontalRatio > 1 else { return .vertical }

        let horizontal = abs(translation.width)
        let vertical = abs(translation.height)
        guard max(horizontal, vertical) >= minimumDistance else { return .undecided }
        return horizontal > vertical * horizontalRatio ? .horizontal : .vertical
    }

    /// Where the bubble sits for a given raw finger displacement. One-for-one up to the limit,
    /// then heavily damped, and never past `maximumTravel * maximumOvershoot`.
    static func travel(drag: CGFloat, maximum: CGFloat = maximumTravel) -> CGFloat {
        guard maximum > 0 else { return 0 }
        let magnitude = abs(drag)
        let eased = magnitude <= maximum
            ? magnitude
            : maximum + (magnitude - maximum) * overshootRate
        return (drag < 0 ? -1 : 1) * min(eased, maximum * maximumOvershoot)
    }

    /// Whether letting go here answers the message. Symmetric: a drag either way replies, so a
    /// left-hander and a right-hander reach it the same way.
    static func shouldReply(travel: CGFloat, trigger: CGFloat = replyTrigger) -> Bool {
        trigger > 0 && abs(travel) >= trigger
    }

    /// How lit the reply arrow is, 0 at rest and 1 once the gesture would fire.
    static func progress(travel: CGFloat, trigger: CGFloat = replyTrigger) -> CGFloat {
        guard trigger > 0 else { return 0 }
        return min(max(abs(travel) / trigger, 0), 1)
    }
}

/// What one quoted message reads as above the answer that points at it.
struct MessageReplyQuote: Equatable, Hashable, Sendable {
    /// The message being answered, so tapping the quote can jump to it.
    let targetServerMessageID: String
    /// Who wrote it, already resolved to a display name — or nil when this device cannot name
    /// them, in which case the view falls back to the thread's own naming.
    let authorName: String?
    /// Whether the quoted message is the reader's own, so the quote can read "You".
    let authorIsSelf: Bool
    /// One line standing in for the quoted message: its words, its caption, or its kind.
    let preview: String
}

/// Resolves the quote block shown above an answer. Quotes are built here, on the device, from
/// history it already holds — the wire carries only the pointer, never a second copy of the
/// quoted plaintext, so answering a message can never republish it to anyone.
enum MessageReplyQuotePolicy {
    /// Stand-in text for a message that has no words of its own. A v1 body contributes at most
    /// its caption; a multi-attachment body quotes §8-style — kind label, +count, caption
    /// garnish — through `mediaAlbumQuoteLabel`, with a validated caption's bytes preserved
    /// exactly (nil/non-nil is the whole test; Foundation trims would eat NBSP/U+0085/U+2028/
    /// U+2029, which the contract admits). A reserved-family body this build cannot parse —
    /// and a pending batch whose persisted bytes fail the structural gate — is never quotable
    /// prose (§4 rule 6) and reads as the generic placeholder instead.
    static func previewText(for message: LocalMessage) -> String {
        if let batch = message.pendingMediaBatch {
            guard batch.isStructurallyValid else {
                return KitMediaMessageFamilyPresentation.genericAttachmentLabel
            }
            return KitMediaMessageFamilyPresentation.mediaAlbumQuoteLabel(
                forMediaTypes: batch.items.map(\.mediaType),
                caption: batch.caption
            )
        }
        switch KitMediaMessageFamilyPresentation.content(for: message.body) {
        case .mediaV1(let descriptor):
            let caption = descriptor.caption?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let caption, !caption.isEmpty { return caption }
            return KitChatMediaKind(mediaType: descriptor.mediaType).previewLabel
        case .mediaV2(let descriptor):
            return KitMediaMessageFamilyPresentation.mediaAlbumQuoteLabel(
                forMediaTypes: descriptor.items.map(\.mediaType),
                caption: descriptor.caption
            )
        case .confinedPlaceholder:
            return KitMediaMessageFamilyPresentation.genericAttachmentLabel
        case .text(let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Message" : trimmed
        }
    }

    /// Whether a message can be answered at all. It has to exist on the server for the pointer
    /// to mean anything to the other side, and it has to be something a person actually said —
    /// not a reaction, and not one of the lifecycle notices the app writes for itself.
    static func canReply(to message: LocalMessage) -> Bool {
        guard message.serverMessageId != nil,
              message.secureMessagingHistory?.kind.isTimelineMetadata != true,
              KitSystemMessage.parse(message.body) == nil,
              KitMessageReaction.parse(message.body) == nil,
              KitMessageEdit.parse(message.body) == nil
        else { return false }
        return !SecureMessageReservedPrefixPolicy.beginsWithReservedPrefix(
            message.body,
            prefix: KitSystemMessage.prefix
        )
    }

    /// The pointer an answer carries, whichever way it reached this device: set locally when the
    /// sender swiped, or authenticated on the envelope when it arrived from someone else.
    /// Reactions and corrections are excluded — each points at a message without being an
    /// answer to it.
    static func targetServerMessageID(of message: LocalMessage) -> String? {
        guard message.secureMessagingHistory?.kind.isTimelineMetadata != true,
              KitMessageReaction.parse(message.body) == nil,
              KitMessageEdit.parse(message.body) == nil
        else { return nil }
        let pointer = message.replyToServerMessageID
            ?? message.secureMessagingHistory?.replyToMessageID
        guard let pointer, !pointer.isEmpty else { return nil }
        return pointer.lowercased()
    }

    /// Builds the quote for `message` out of `conversation`. Returns nil when the message is not
    /// an answer, or when the message it answers is not on this device — history from before
    /// this installation, or a page that has not been loaded yet. A missing target leaves the
    /// answer plain rather than inventing a quote for it.
    static func quote(
        for message: LocalMessage,
        in conversation: [LocalMessage],
        currentUserID: String?,
        displayName: (String) -> String?
    ) -> MessageReplyQuote? {
        guard let targetID = targetServerMessageID(of: message) else { return nil }
        guard message.serverMessageId?.lowercased() != targetID else { return nil }
        guard let target = conversation.first(where: {
            $0.serverMessageId?.lowercased() == targetID
                && $0.conversationId == message.conversationId
        }) else { return nil }
        let isSelf = target.isOutgoing
            || (currentUserID.map { $0.lowercased() == target.senderId.lowercased() } ?? false)
        return MessageReplyQuote(
            targetServerMessageID: targetID,
            authorName: isSelf ? nil : displayName(target.senderId),
            authorIsSelf: isSelf,
            preview: previewText(for: target)
        )
    }
}
