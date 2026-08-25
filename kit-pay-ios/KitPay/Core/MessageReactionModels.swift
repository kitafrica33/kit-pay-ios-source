import Foundation

enum KitMessageReactionOperation: String, Equatable, Sendable, CaseIterable {
    case add
    case remove
}

enum MessagingReactionCapabilityPolicy {
    /// The server advertises this only after every supported peer client understands the
    /// encrypted KITRXN1 event. Until then, sending stays hidden so older clients never render
    /// protocol text as a chat bubble.
    static let featureKey = "messaging_reactions_e2ee_v1"
    static let deviceCapabilityKey = "messaging_reactions_e2ee_v1"
    static let minimumIOSRelease = MessagingBuild24CompatibilityPolicy.minimumIOSRelease

    static func isEnabled(features: [String: Bool?]?) -> Bool {
        guard let features, let value = features[featureKey] else { return false }
        return value == true
    }

    static func supports(
        roster: MessagingDeviceRosterDTO,
        conversationID: String,
        currentDeviceID: String,
        memberUserIDs: Set<String>
    ) -> Bool {
        guard MessagingRosterCapabilityPolicy.supports(
            deviceCapabilityKey: deviceCapabilityKey,
            roster: roster,
            conversationID: conversationID,
            currentDeviceID: currentDeviceID,
            memberUserIDs: memberUserIDs
        ), let devices = roster.devices?.compactMap({ $0 }) else { return false }
        return devices.allSatisfy { device in
            guard device.deviceId != currentDeviceID,
                  device.client?.platform?.lowercased() == "ios"
            else { return true }
            return MessagingBuild24CompatibilityPolicy.supportsIOS(
                version: device.client?.version,
                build: device.client?.build
            )
        }
    }
}

/// Canonical reaction descriptor carried inside the end-to-end encrypted message body.
/// Like `KITPAY1`, its fixed field order and strict re-encoding form the `KITRXN1` wire
/// contract shared with Android: any body that does not re-encode byte-for-byte is refused
/// rather than repaired, so both platforms aggregate exactly the same reaction stream.
struct KitMessageReaction: Equatable, Sendable {
    static let prefix = "KITRXN1:"
    static let maximumDescriptorLength = 256
    static let maximumEmojiUTF8Bytes = 32

    let operation: KitMessageReactionOperation
    /// Canonical lowercase server message UUID of the message being reacted to. The server id
    /// (not the client idempotency id) is the only identifier both participants share.
    let targetServerMessageID: String
    /// The reacted emoji, bounded but deliberately not validated as "is an emoji": ZWJ
    /// sequences, skin-tone modifiers, and variation selectors evolve faster than any local
    /// allowlist, so the contract only caps size and refuses whitespace.
    let emoji: String

    init?(
        operation: KitMessageReactionOperation,
        targetServerMessageID: String,
        emoji: String
    ) {
        let canonicalEmoji = emoji.precomposedStringWithCanonicalMapping
        guard Self.isCanonicalUUID(targetServerMessageID),
              Self.isValidEmojiToken(canonicalEmoji)
        else { return nil }
        self.operation = operation
        self.targetServerMessageID = targetServerMessageID
        self.emoji = canonicalEmoji
        guard encoded.utf16.count <= Self.maximumDescriptorLength else { return nil }
    }

    var encoded: String {
        var value = Self.prefix
        value += "v=1"
        value += "&a=\(operation.rawValue)"
        value += "&t=\(Self.percentEncode(targetServerMessageID))"
        value += "&e=\(Self.percentEncode(emoji))"
        return value
    }

    static func isReactionText(_ text: String) -> Bool {
        text.hasPrefix(prefix)
    }

    static func parse(_ text: String) -> KitMessageReaction? {
        guard text.hasPrefix(prefix), text.utf16.count <= maximumDescriptorLength else {
            return nil
        }

        var fields: [String: String] = [:]
        for pair in text.dropFirst(prefix.count).split(
            separator: "&",
            omittingEmptySubsequences: false
        ) {
            guard let separator = pair.firstIndex(of: "="), separator != pair.startIndex else {
                return nil
            }
            let key = String(pair[..<separator])
            let encodedValue = String(pair[pair.index(after: separator)...])
            guard fields[key] == nil, let value = percentDecode(encodedValue) else { return nil }
            fields[key] = value
        }

        // Exactly {v, a, t, e}: an unknown key is a newer or foreign descriptor and must fail
        // closed instead of being partially honored.
        guard fields.count == 4,
              fields["v"] == "1",
              let operation = fields["a"].flatMap(KitMessageReactionOperation.init(rawValue:)),
              let targetServerMessageID = fields["t"],
              let emoji = fields["e"],
              let descriptor = KitMessageReaction(
                  operation: operation,
                  targetServerMessageID: targetServerMessageID,
                  emoji: emoji
              ),
              descriptor.encoded == text
        else { return nil }
        return descriptor
    }

    /// A UTF-16 whitespace check is insufficient here; scalar-level filtering also refuses
    /// separators that could visually pad a reaction chip.
    private static func isValidEmojiToken(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumEmojiUTF8Bytes
            && value.unicodeScalars.count <= 4
            && !value.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.contains($0)
                    || $0.value == 0x0085
            })
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        value.range(
            of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,
            options: .regularExpression
        ) != nil
    }

    /// Java `URLEncoder`'s safe byte set, with its `+` spaces canonicalized to `%20`.
    private static func percentEncode(_ value: String) -> String {
        let hex = Array("0123456789ABCDEF".utf8)
        var encoded = ""
        encoded.reserveCapacity(value.utf8.count * 3)
        for byte in value.utf8 {
            switch byte {
            case 48 ... 57, 65 ... 90, 97 ... 122, 45, 46, 95, 42:
                encoded.unicodeScalars.append(UnicodeScalar(byte))
            default:
                encoded.unicodeScalars.append("%")
                encoded.unicodeScalars.append(UnicodeScalar(hex[Int(byte >> 4)]))
                encoded.unicodeScalars.append(UnicodeScalar(hex[Int(byte & 0x0F)]))
            }
        }
        return encoded
    }

    private static func percentDecode(_ value: String) -> String? {
        value.replacingOccurrences(of: "+", with: "%20").removingPercentEncoding
    }
}

/// One aggregated reaction chip under a message bubble.
struct MessageReactionTally: Equatable, Identifiable {
    let emoji: String
    /// Number of participants currently holding this reaction.
    let count: Int
    /// Lowercased reactor user IDs in first-reaction order; a reactor who removes and later
    /// re-adds rejoins at the end.
    let reactorUserIDs: [String]
    let includesCurrentUser: Bool

    var id: String { emoji }
}

/// Pure fold from a conversation's local messages to per-target reaction state.
///
/// A reactor's identity is the E2E-authenticated `senderId` of the reaction message; the
/// descriptor body cannot claim to react on someone else's behalf. Events are applied in
/// canonical `(sentAt, serverMessageId)` ascending order so replays and out-of-order sync pages
/// settle on the same result on every device. Optimistic events that do not have server metadata
/// yet fall back to their local creation identity. Everything after that sort is one linear pass.
enum MessageReactionAggregationPolicy {
    /// The default long-press palette, mirrored on Android.
    static let quickReactions = ["👍", "✅", "❤️", "😂", "😮", "🙏"]

    /// Reaction descriptors are transport events, never bubbles. Failed outgoing reactions are
    /// still suppressed: they surface through retry affordances, not as a visible message row.
    static func suppressedMessageIDs(in messages: [LocalMessage]) -> Set<UUID> {
        var suppressed: Set<UUID> = []
        for message in messages where authenticatedReaction(in: message) != nil {
            suppressed.insert(message.id)
        }
        return suppressed
    }

    /// Aggregated tallies keyed by lowercase target server message UUID. Targets whose
    /// reactions have all been removed are omitted entirely. Tallies are sorted by count
    /// descending, then emoji ascending, for a stable chip row.
    static func tallies(
        in messages: [LocalMessage],
        currentUserID: String?
    ) -> [String: [MessageReactionTally]] {
        let states = reactorStates(
            in: messages,
            validTargets: validTargetKeys(in: messages)
        )
        let normalizedCurrentUser = currentUserID?.lowercased()
        var result: [String: [MessageReactionTally]] = [:]
        result.reserveCapacity(states.count)
        for (target, reactors) in states {
            var entriesByEmoji: [String: [(order: Int, reactor: String)]] = [:]
            for (reactor, reaction) in reactors {
                entriesByEmoji[reaction.emoji, default: []].append((reaction.order, reactor))
            }
            guard !entriesByEmoji.isEmpty else { continue }
            result[target] = entriesByEmoji
                .map { emoji, entries in
                    let orderedReactors = entries.sorted { $0.order < $1.order }.map(\.reactor)
                    return MessageReactionTally(
                        emoji: emoji,
                        count: orderedReactors.count,
                        reactorUserIDs: orderedReactors,
                        includesCurrentUser: normalizedCurrentUser
                            .map(orderedReactors.contains) ?? false
                    )
                }
                .sorted { lhs, rhs in
                    lhs.count != rhs.count ? lhs.count > rhs.count : lhs.emoji < rhs.emoji
                }
        }
        return result
    }

    /// The emoji the current user currently holds on the target, or nil. Because a user holds
    /// at most one reaction per message, this is the value a reaction picker pre-selects.
    static func currentUserReaction(
        to targetServerMessageID: String,
        in messages: [LocalMessage],
        currentUserID: String?
    ) -> String? {
        guard let currentUserID else { return nil }
        return reactorStates(
            in: messages,
            validTargets: validTargetKeys(in: messages)
        )[targetServerMessageID.lowercased()]?[
            currentUserID.lowercased()
        ]?.emoji
    }

    /// Filters newly decrypted rows at the persistence boundary. An authenticated reaction can
    /// only affect an ordinary server-backed message in the same conversation. Invalid protocol
    /// rows remain acknowledged by sync, but are not committed to durable history.
    static func retainingValidReactionTargets(
        _ candidates: [LocalMessage],
        among messages: [LocalMessage]
    ) -> [LocalMessage] {
        let validTargets = validTargetKeys(in: messages)
        return candidates.filter { message in
            guard let reaction = authenticatedReaction(in: message) else { return true }
            return validTargets.contains(
                TargetKey(
                    conversationID: message.conversationId.lowercased(),
                    serverMessageID: reaction.targetServerMessageID
                )
            )
        }
    }

    static func hasValidTarget(
        for reactionMessage: LocalMessage,
        among messages: [LocalMessage]
    ) -> Bool {
        guard let reaction = authenticatedReaction(in: reactionMessage) else { return false }
        return validTargetKeys(in: messages).contains(
            TargetKey(
                conversationID: reactionMessage.conversationId.lowercased(),
                serverMessageID: reaction.targetServerMessageID
            )
        )
    }

    private struct ReactorReaction {
        let emoji: String
        /// Global add sequence used to reconstruct first-reaction order without per-event
        /// array surgery.
        let order: Int
    }

    private struct TargetKey: Hashable {
        let conversationID: String
        let serverMessageID: String
    }

    private static func validTargetKeys(in messages: [LocalMessage]) -> Set<TargetKey> {
        Set(messages.compactMap { message in
            guard message.secureMessagingHistory?.kind != .encryptedReaction,
                  let serverMessageID = message.serverMessageId?.lowercased(),
                  SecureMessagingWirePolicy.isCanonicalUUID(serverMessageID)
            else { return nil }
            return TargetKey(
                conversationID: message.conversationId.lowercased(),
                serverMessageID: serverMessageID
            )
        })
    }

    /// Current reaction per (lowercase target, lowercase reactor). WhatsApp semantics: an add
    /// implicitly replaces the reactor's previous emoji on that target — a user holds at most
    /// one reaction per message — and a remove only clears the emoji it names, so a stale
    /// remove that raced a newer add cannot erase the newer reaction.
    private static func reactorStates(
        in messages: [LocalMessage],
        validTargets: Set<TargetKey>
    ) -> [String: [String: ReactorReaction]] {
        var events: [(message: LocalMessage, reaction: KitMessageReaction)] = []
        for message in messages {
            // A failed outgoing send never reached the peer, so it must not count locally
            // either; both sides would otherwise disagree about the tally forever.
            guard message.state != .failed,
                  let reaction = authenticatedReaction(in: message),
                  validTargets.contains(TargetKey(
                      conversationID: message.conversationId.lowercased(),
                      serverMessageID: reaction.targetServerMessageID
                  ))
            else { continue }
            events.append((message, reaction))
        }
        // Canonical server order (`sentAt`, then server id) makes every device fold
        // acknowledged ops identically. Local (createdAt, client id) would diverge from
        // receivers whenever two ops share a server timestamp; only a not-yet-acknowledged
        // optimistic send falls back to its local order. Android must implement this exact key.
        events.sort {
            orderingKey(for: $0.message) < orderingKey(for: $1.message)
        }

        var states: [String: [String: ReactorReaction]] = [:]
        var nextOrder = 0
        for (message, reaction) in events {
            let reactor = message.senderId.lowercased()
            let target = reaction.targetServerMessageID
            switch reaction.operation {
            case .add:
                // Re-adding the emoji already held is idempotent and keeps the original
                // first-reaction position.
                guard states[target]?[reactor]?.emoji != reaction.emoji else { continue }
                states[target, default: [:]][reactor] = ReactorReaction(
                    emoji: reaction.emoji,
                    order: nextOrder
                )
                nextOrder += 1
            case .remove:
                if states[target]?[reactor]?.emoji == reaction.emoji {
                    states[target]?[reactor] = nil
                }
            }
        }
        return states
    }

    /// A server-backed row is a reaction only when its authenticated outer metadata says so and
    /// binds the same target. The sole metadata-free exception is a locally queued outgoing
    /// command that has not received a server identity yet. This prevents restored legacy text
    /// or a pre-v24 ordinary encrypted message beginning with KITRXN1 from impersonating an event.
    static func authenticatedReaction(in message: LocalMessage) -> KitMessageReaction? {
        guard let reaction = KitMessageReaction.parse(message.body) else { return nil }
        if let history = message.secureMessagingHistory {
            guard message.serverMessageId.map(SecureMessagingWirePolicy.isCanonicalUUID) == true,
                  history.senderUserID == message.senderId,
                  history.kind == .encryptedReaction,
                  history.replyToMessageID == reaction.targetServerMessageID
            else { return nil }
            return reaction
        }
        guard message.isOutgoing,
              message.serverMessageId == nil,
              message.sentAt == nil,
              [.queued, .encrypting, .sending, .failed].contains(message.state)
        else { return nil }
        return reaction
    }

    /// Server acknowledgement installs both values atomically. If an imported legacy record has
    /// only half of that pair, treat it as local instead of constructing a hybrid order key no
    /// other device can reproduce.
    private static func orderingKey(for message: LocalMessage) -> (Date, String) {
        if let sentAt = message.sentAt, let serverMessageID = message.serverMessageId {
            return (sentAt, serverMessageID.lowercased())
        }
        return (message.createdAt, message.id.uuidString.lowercased())
    }
}

/// Curated full-picker catalog. Every entry is a single-scalar emoji with default emoji
/// presentation, so each is trivially within `KitMessageReaction`'s size bounds and renders
/// consistently across iOS and Android keyboards without variation selectors.
enum MessageReactionCatalog {
    static let sections: [(title: String, emojis: [String])] = [
        (
            "Smileys",
            [
                "😀", "😃", "😄", "😁", "😆", "😅", "😂", "🙂",
                "🙃", "😉", "😊", "😇", "😍", "😘", "😗", "😙",
                "😚", "😋", "😛", "😜", "🤪", "😝", "🤗", "🤔",
                "🤐", "😐", "😑", "😶", "😏", "😒", "🙄", "😬",
                "😌", "😔", "😪", "😴", "😷", "🤒", "🤕", "🤢",
                "🤧", "😵", "😎", "🤓", "😕", "😟", "🙁", "😮",
            ]
        ),
        (
            "Gestures",
            [
                "👍", "👎", "👊", "✊", "🤛", "🤜", "👏", "🙌",
                "👐", "🤲", "🤝", "🙏", "💪", "👋", "🤚", "✋",
                "🖖", "👌", "🤏", "🤞", "🤟", "🤘", "🤙", "👉",
            ]
        ),
        (
            "Hearts",
            [
                "💛", "💚", "💙", "💜", "🖤", "🤍", "🤎", "💔",
                "💕", "💞", "💓", "💗", "💖", "💘", "💝", "💟",
            ]
        ),
        (
            "Animals",
            [
                "🐶", "🐱", "🐭", "🐹", "🐰", "🦊", "🐻", "🐼",
                "🐨", "🐯", "🦁", "🐮", "🐷", "🐸", "🐵", "🐔",
            ]
        ),
        (
            "Food",
            [
                "🍎", "🍌", "🍇", "🍓", "🍒", "🍑", "🍍", "🥭",
                "🥑", "🍕", "🍔", "🍟", "🌮", "🍣", "🍩", "🍰",
            ]
        ),
        (
            "Symbols",
            [
                "⭐", "🌟", "✨", "⚡", "🔥", "🌈", "🎉", "🎊",
                "🎁", "🏆", "🎯", "🎵", "🎶", "💯", "💫", "💥",
            ]
        ),
    ]
}
