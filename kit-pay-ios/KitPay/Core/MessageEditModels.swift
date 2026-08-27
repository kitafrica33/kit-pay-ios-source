import Foundation

enum MessagingMessageEditCapabilityPolicy {
    /// The server advertises this only once every supported peer client understands the
    /// encrypted `KITEDIT1` descriptor. Until then the affordance stays hidden, so an older
    /// client never renders a correction as a chat bubble full of protocol text.
    static let featureKey = "messaging_message_edits_v1"
    static let deviceCapabilityKey = "messaging_message_edits_v1"

    static func isEnabled(features: [String: Bool?]?) -> Bool {
        guard let features, let value = features[featureKey] else { return false }
        return value == true
    }

    /// The first iOS release that understands `KITEDIT1`. Checked here as well as server-side so
    /// a misconfigured capability map cannot deliver a correction to a client that would render
    /// its descriptor as a chat bubble.
    static let minimumIOSVersion = [1, 0, 16]
    static let minimumIOSBuild = 31
    static let minimumIOSRelease = "1.0.16-r31"

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
            // A device that will not say which release it runs is read as one that cannot show a
            // correction. The floor exists precisely so an older client never renders a `KITEDIT1`
            // descriptor as a chat bubble, and an unstated version proves nothing against it.
            guard let version = device.client?.version else { return false }
            return MessagingBuild24CompatibilityPolicy.supportsIOS(
                version: version,
                build: device.client?.build,
                minimumVersion: minimumIOSVersion,
                minimumBuild: minimumIOSBuild
            )
        }
    }
}

/// Canonical correction descriptor carried inside the end-to-end encrypted message body.
///
/// `KITEDIT1:v=1&t=<target>&b=<replacement wording>`. Riding the ordinary message pipeline is what
/// makes a correction durable: it inherits the ordering, deduplication, sync cursor, offline
/// outbox, retry and per-device fanout that already work, and the replacement wording stays as
/// hidden from the server as the original was.
///
/// The author is deliberately not a field. Identity comes from the authenticated Signal sender of
/// the carrying message, so a peer cannot pass off a correction as somebody else's second thought.
///
/// Unlike `KITRXN1`, the body is the last field and is carried unencoded: everything after `&b=`
/// is the replacement, so an ampersand or an equals sign someone typed stays exactly what they
/// typed, and the wording costs the wire no more than it did the first time. Android encodes the
/// same bytes, and the length ceiling is counted in UTF-16 units so both platforms accept and
/// refuse precisely the same corrections.
struct KitMessageEdit: Equatable, Sendable {
    static let prefix = "KITEDIT1:"
    private static let header = prefix + "v=1&t="
    private static let bodySeparator = "&b="
    /// The same ceiling the ordinary text profile enforces, so a correction can be as long as the
    /// message it replaces was allowed to be.
    static let maximumDescriptorLength = 8_000
    /// How long after sending its author may still replace the wording. The same figure the
    /// server enforces, so "fifteen minutes to edit" means one thing on screen and another
    /// nowhere.
    static let editWindow: TimeInterval = 15 * 60

    /// Canonical lowercase server message UUID of the message whose wording this replaces.
    let targetServerMessageID: String
    /// The replacement wording, already trimmed to what the composer would have sent.
    let body: String

    init?(targetServerMessageID: String, body: String) {
        guard SecureMessagingWirePolicy.isCanonicalUUID(targetServerMessageID),
              Self.isAcceptableBody(body)
        else { return nil }
        self.targetServerMessageID = targetServerMessageID
        self.body = body
        guard encoded.utf16.count <= Self.maximumDescriptorLength else { return nil }
    }

    var encoded: String {
        Self.header + targetServerMessageID + Self.bodySeparator + body
    }

    static func isEditText(_ text: String) -> Bool {
        text.hasPrefix(prefix)
    }

    /// Whether `body` is wording a correction may carry.
    ///
    /// It has to be something the composer could have sent in the first place: present, already
    /// trimmed, within the text profile, and not itself a descriptor in one of Kit Pay's reserved
    /// namespaces — otherwise editing would become a way to author content the composer refuses.
    static func isAcceptableBody(_ body: String) -> Bool {
        guard !body.isEmpty,
              body == body.trimmingCharacters(in: .whitespacesAndNewlines),
              header.utf16.count + 36 + bodySeparator.utf16.count + body.utf16.count
                  <= maximumDescriptorLength,
              // `allowsUserAuthoredText` already refuses this namespace along with every
              // other reserved one, so a correction cannot smuggle in a descriptor either.
              SecureMessageReservedPrefixPolicy.allowsUserAuthoredText(body)
        else { return false }
        return true
    }

    static func parse(_ text: String) -> KitMessageEdit? {
        guard text.hasPrefix(header), text.utf16.count <= maximumDescriptorLength else {
            return nil
        }
        let afterHeader = text.dropFirst(header.count)
        guard afterHeader.count > 36 + bodySeparator.count else { return nil }
        let targetServerMessageID = String(afterHeader.prefix(36))
        let remainder = afterHeader.dropFirst(36)
        guard remainder.hasPrefix(bodySeparator) else { return nil }
        let body = String(remainder.dropFirst(bodySeparator.count))
        guard let descriptor = KitMessageEdit(
            targetServerMessageID: targetServerMessageID,
            body: body
        ),
        // The authenticated descriptor has one canonical spelling, so a future parser cannot
        // assign a second meaning to already-authenticated content.
        descriptor.encoded == text
        else { return nil }
        return descriptor
    }
}

/// One correction, resolved against the message it replaces.
struct AppliedMessageEdit: Equatable, Sendable {
    /// The replacement wording to render in place of the original.
    let body: String
    /// When the correction itself was sent, for the "Edited" marker's accessibility text.
    let editedAt: Date
}

/// Pure fold from a conversation's local messages to the wording each message currently reads as.
///
/// The author of a correction is the E2E-authenticated `senderId` of the carrying message; the
/// descriptor cannot claim to correct on someone else's behalf. Corrections are applied in
/// canonical `(sentAt, serverMessageId)` ascending order so replays and out-of-order sync pages
/// settle on the same wording on every device.
///
/// The fifteen-minute window is deliberately *not* re-checked here. The server authorises the edit
/// and holds the only untampered clock for both messages, so a reader that re-judged the deadline
/// against its own clock could keep displaying words their author has already withdrawn.
enum MessageEditAggregationPolicy {
    /// Correction descriptors are transport events, never bubbles.
    static func suppressedMessageIDs(in messages: [LocalMessage]) -> Set<UUID> {
        var suppressed: Set<UUID> = []
        for message in messages where authenticatedEdit(in: message) != nil {
            suppressed.insert(message.id)
        }
        return suppressed
    }

    /// The wording each corrected message currently reads as, keyed by lowercase target server
    /// message UUID. Messages nobody corrected are absent.
    static func appliedEdits(in messages: [LocalMessage]) -> [String: AppliedMessageEdit] {
        let originals = originalsByServerMessageID(in: messages)
        var events: [(message: LocalMessage, edit: KitMessageEdit)] = []
        for message in messages {
            // A failed outgoing send never reached the peer, so it must not reword anything
            // locally either; both sides would otherwise disagree about the wording forever.
            guard message.state != .failed,
                  let edit = authenticatedEdit(in: message),
                  let original = originals[
                      TargetKey(
                          conversationID: message.conversationId.lowercased(),
                          serverMessageID: edit.targetServerMessageID
                      )
                  ],
                  original.senderId.lowercased() == message.senderId.lowercased()
            else { continue }
            events.append((message, edit))
        }
        events.sort { orderingKey(for: $0.message) < orderingKey(for: $1.message) }

        var applied: [String: AppliedMessageEdit] = [:]
        for (message, edit) in events {
            applied[edit.targetServerMessageID] = AppliedMessageEdit(
                body: edit.body,
                editedAt: message.sentAt ?? message.createdAt
            )
        }
        return applied
    }

    /// Filters newly decrypted rows at the persistence boundary, exactly as reactions are
    /// filtered: an authenticated correction can only reword an ordinary server-backed message
    /// written by the same person in the same conversation.
    static func retainingValidEditTargets(
        _ candidates: [LocalMessage],
        among messages: [LocalMessage]
    ) -> [LocalMessage] {
        let originals = originalsByServerMessageID(in: messages)
        return candidates.filter { message in
            guard let edit = authenticatedEdit(in: message) else { return true }
            return isAuthoredCorrection(of: edit, by: message, among: originals)
        }
    }

    static func hasValidTarget(
        for editMessage: LocalMessage,
        among messages: [LocalMessage]
    ) -> Bool {
        guard let edit = authenticatedEdit(in: editMessage) else { return false }
        return isAuthoredCorrection(
            of: edit,
            by: editMessage,
            among: originalsByServerMessageID(in: messages)
        )
    }

    /// Whether the composer should offer to reword this message: one's own, already acknowledged
    /// by the server, something a person actually said, and still inside its fifteen minutes.
    static func canEdit(_ message: LocalMessage, now: Date = Date()) -> Bool {
        guard message.isOutgoing,
              [.sent, .delivered, .read].contains(message.state),
              let sentAt = message.sentAt,
              message.serverMessageId != nil,
              KitMediaMessageDescriptor.parse(message.body) == nil,
              message.secureMessagingHistory?.kind != .encryptedAttachment,
              MessageReplyQuotePolicy.canReply(to: message),
              authenticatedEdit(in: message) == nil
        else { return false }
        return editWindowRemaining(for: message, now: now) > 0 && sentAt <= now
    }

    /// How much of the fifteen minutes is left, or zero once it has run out.
    static func editWindowRemaining(for message: LocalMessage, now: Date = Date()) -> TimeInterval {
        guard let sentAt = message.sentAt else { return 0 }
        return max(0, sentAt.addingTimeInterval(KitMessageEdit.editWindow).timeIntervalSince(now))
    }

    /// A server-backed row is a correction only when its authenticated outer metadata says so and
    /// binds the same target. The sole metadata-free exception is a locally queued outgoing
    /// command that has not received a server identity yet — the same carve-out reactions get,
    /// and for the same reason.
    static func authenticatedEdit(in message: LocalMessage) -> KitMessageEdit? {
        guard let edit = KitMessageEdit.parse(message.body) else { return nil }
        if let history = message.secureMessagingHistory {
            guard message.serverMessageId.map(SecureMessagingWirePolicy.isCanonicalUUID) == true,
                  history.senderUserID == message.senderId,
                  history.kind == .encryptedEdit,
                  history.replyToMessageID == edit.targetServerMessageID
            else { return nil }
            return edit
        }
        guard message.isOutgoing,
              message.serverMessageId == nil,
              message.sentAt == nil,
              [.queued, .encrypting, .sending, .failed].contains(message.state)
        else { return nil }
        return edit
    }

    private struct TargetKey: Hashable {
        let conversationID: String
        let serverMessageID: String
    }

    /// Only a message that is itself a bubble of words can be reworded. Correcting a reaction or
    /// an earlier correction would be a change with nothing to show for it, and a photo, a voice
    /// note or a document is not wording at all — replacing its descriptor with a sentence would
    /// strand the media its recipients have already downloaded.
    private static func originalsByServerMessageID(
        in messages: [LocalMessage]
    ) -> [TargetKey: LocalMessage] {
        var originals: [TargetKey: LocalMessage] = [:]
        for message in messages {
            guard message.secureMessagingHistory?.kind.isTimelineMetadata != true,
                  message.secureMessagingHistory?.kind != .encryptedAttachment,
                  KitMessageReaction.parse(message.body) == nil,
                  KitMessageEdit.parse(message.body) == nil,
                  KitMediaMessageDescriptor.parse(message.body) == nil,
                  KitSystemMessage.parse(message.body) == nil,
                  let serverMessageID = message.serverMessageId?.lowercased(),
                  SecureMessagingWirePolicy.isCanonicalUUID(serverMessageID)
            else { continue }
            originals[
                TargetKey(
                    conversationID: message.conversationId.lowercased(),
                    serverMessageID: serverMessageID
                )
            ] = message
        }
        return originals
    }

    private static func isAuthoredCorrection(
        of edit: KitMessageEdit,
        by message: LocalMessage,
        among originals: [TargetKey: LocalMessage]
    ) -> Bool {
        guard let original = originals[
            TargetKey(
                conversationID: message.conversationId.lowercased(),
                serverMessageID: edit.targetServerMessageID
            )
        ] else { return false }
        return original.senderId.lowercased() == message.senderId.lowercased()
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
