import AVFoundation
import CallKit
import CryptoKit
import Foundation
import PushKit
import UIKit
import UserNotifications

struct PushTokenRegistration: Equatable, Sendable {
    let provider: String
    let token: String
}

struct VisibleMessageNotificationDescriptor: Equatable, Sendable {
    let requestIdentifier: String
    let threadIdentifier: String
    let conversationID: String
    let accountFingerprint: String
    let version: MessageNotificationVersion
}

struct MessageNotificationVersion: Equatable, Comparable, Sendable {
    let messageDigest: String
    let sentAtEpochSecond: Int64
    let sentAtNanosecond: Int

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.sentAtEpochSecond != rhs.sentAtEpochSecond {
            return lhs.sentAtEpochSecond < rhs.sentAtEpochSecond
        }
        if lhs.sentAtNanosecond != rhs.sentAtNanosecond {
            return lhs.sentAtNanosecond < rhs.sentAtNanosecond
        }
        return lhs.messageDigest < rhs.messageDigest
    }
}

enum MessageNotificationContract {
    static let categoryIdentifier = "africa.kit.pay.message"
    static let replyActionIdentifier = "africa.kit.pay.message.reply"
    static let localType = "messaging.local"
    static let messagingScope = "messaging"
    static let maximumReplyBytes = 4_096

    static var category: UNNotificationCategory {
        // The backend wake stays strictly opaque. This category is attached only to a local
        // notification created after authenticated Signal decryption and durable projection.
        let reply = UNTextInputNotificationAction(
            identifier: replyActionIdentifier,
            title: "Reply",
            options: [.authenticationRequired],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Reply securely"
        )
        return UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [reply],
            intentIdentifiers: [],
            options: []
        )
    }

    static func accountFingerprint(for userID: String?) -> String? {
        guard let userID = canonicalUUID(userID) else { return nil }
        return digest(userID)
    }

    static func messageIdentifier(for messageID: String?) -> String? {
        canonicalUUID(messageID).map { identifier(scope: "message", value: $0) }
    }

    static func conversationRequestIdentifier(for conversationID: String?) -> String? {
        canonicalUUID(conversationID).map { identifier(scope: "message", value: $0) }
    }

    static func messageDigest(for messageID: String?) -> String? {
        canonicalUUID(messageID).map { digest($0) }
    }

    static func messageVersion(
        for messageID: String?,
        sentAt: Date
    ) -> MessageNotificationVersion? {
        guard let messageDigest = messageDigest(for: messageID) else { return nil }
        let interval = sentAt.timeIntervalSince1970
        let wholeSeconds = floor(interval)
        // Authenticated server dates are RFC 3339 values. Keeping this conversion inside the
        // representable RFC 3339 year range also prevents a malformed Date from trapping Int64.
        guard interval.isFinite,
              wholeSeconds >= -62_135_596_800,
              wholeSeconds <= 253_402_300_799
        else { return nil }

        var epochSecond = Int64(wholeSeconds)
        var nanosecond = Int(((interval - wholeSeconds) * 1_000_000_000).rounded())
        if nanosecond == 1_000_000_000 {
            epochSecond += 1
            nanosecond = 0
        }
        guard (0 ..< 1_000_000_000).contains(nanosecond) else { return nil }
        return MessageNotificationVersion(
            messageDigest: messageDigest,
            sentAtEpochSecond: epochSecond,
            sentAtNanosecond: nanosecond
        )
    }

    static func isMessageRequestIdentifier(_ value: String) -> Bool {
        let prefix = "africa.kit.pay.message."
        guard value.hasPrefix(prefix) else { return false }
        return isIdentifierDigest(String(value.dropFirst(prefix.count)))
    }

    static func isIdentifierDigest(_ value: String) -> Bool {
        let bytes = value.utf8
        return bytes.count == 64 && bytes.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    static func threadIdentifier(for conversationID: String?) -> String? {
        canonicalUUID(conversationID).map { identifier(scope: "thread", value: $0) }
    }

    static func canonicalUUID(_ value: String?) -> String? {
        guard let value,
              let uuid = UUID(uuidString: value),
              uuid.uuidString.caseInsensitiveCompare(value) == .orderedSame
        else { return nil }
        return uuid.uuidString.lowercased()
    }

    static func deterministicUUID(scope: String, values: [String]) -> UUID {
        var bytes = Array(SHA256.hash(
            data: Data(([scope] + values).joined(separator: "\u{0}").utf8)
        ).prefix(16))
        // RFC 9562's custom version/variant bits make these stable identifiers valid UUIDs while
        // keeping their namespace separate from randomly generated client-message identifiers.
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func identifier(scope: String, value: String) -> String {
        "africa.kit.pay.\(scope).\(digest(value))"
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// The APNs category used by the backend for claimable Kit-to-Kit payment state changes.
/// The category deliberately has no one-tap money-movement action: accepting or reversing still
/// requires the authenticated in-app flow and its existing step-up checks. A visible alert is
/// rendered by iOS even while Kit Pay is suspended or terminated.
enum ClaimablePaymentNotificationContract {
    static let categoryIdentifier = "africa.kit.pay.payment.claimable"

    static var category: UNNotificationCategory {
        UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
    }
}

private struct MessageNotificationMetadata {
    let conversationID: String
    let accountFingerprint: String
    let threadIdentifier: String
    let version: MessageNotificationVersion?
}

private enum MessageNotificationMetadataPolicy {
    private static let legacyKeys = Set([
        "type", "scope", "conversation_id", "account_fingerprint", "thread_identifier",
    ])
    private static let currentKeys = legacyKeys.union([
        "message_digest", "sent_at_epoch_second", "sent_at_nanosecond",
    ])

    static func metadata(
        requestIdentifier: String,
        threadIdentifier: String,
        userInfo: [AnyHashable: Any]
    ) -> MessageNotificationMetadata? {
        let keys = Set(userInfo.keys.compactMap { $0 as? String })
        guard keys.count == userInfo.count,
              keys == legacyKeys || keys == currentKeys,
              MessageNotificationContract.isMessageRequestIdentifier(requestIdentifier),
              userInfo["type"] as? String == MessageNotificationContract.localType,
              userInfo["scope"] as? String == MessageNotificationContract.messagingScope,
              let conversationID = MessageNotificationContract.canonicalUUID(
                  userInfo["conversation_id"] as? String
              ),
              let expectedThreadIdentifier = MessageNotificationContract.threadIdentifier(
                  for: conversationID
              ),
              threadIdentifier == expectedThreadIdentifier,
              userInfo["thread_identifier"] as? String == expectedThreadIdentifier,
              let accountFingerprint = userInfo["account_fingerprint"] as? String,
              MessageNotificationContract.isIdentifierDigest(accountFingerprint)
        else { return nil }

        let version: MessageNotificationVersion?
        if keys == currentKeys {
            guard requestIdentifier == MessageNotificationContract.conversationRequestIdentifier(
                for: conversationID
            ),
                  let messageDigest = userInfo["message_digest"] as? String,
                  MessageNotificationContract.isIdentifierDigest(messageDigest),
                  let sentAtEpochSecond = exactInt64(userInfo["sent_at_epoch_second"]),
                  let sentAtNanosecondValue = exactInt64(userInfo["sent_at_nanosecond"]),
                  (0 ..< 1_000_000_000).contains(sentAtNanosecondValue)
            else { return nil }
            version = MessageNotificationVersion(
                messageDigest: messageDigest,
                sentAtEpochSecond: sentAtEpochSecond,
                sentAtNanosecond: Int(sentAtNanosecondValue)
            )
        } else {
            // Five-key notifications were emitted by earlier builds with a message-specific
            // request ID. They remain actionable during an upgrade, but have no freshness value.
            version = nil
        }

        return MessageNotificationMetadata(
            conversationID: conversationID,
            accountFingerprint: accountFingerprint,
            threadIdentifier: expectedThreadIdentifier,
            version: version
        )
    }

    private static func exactInt64(_ value: Any?) -> Int64? {
        guard !(value is Bool) else { return nil }
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        guard let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        guard double.isFinite,
              double.rounded(.towardZero) == double,
              double >= Double(Int64.min),
              double < Double(Int64.max)
        else { return nil }
        let integer = number.int64Value
        return Double(integer) == double ? integer : nil
    }
}

struct MessageNotificationAction: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case open
        case reply(String)
    }

    let requestIdentifier: String
    let conversationID: String
    let accountFingerprint: String
    let messageDigest: String?
    let kind: Kind

    var deduplicationKey: String {
        let notificationIdentity = messageDigest ?? requestIdentifier
        let route = "\(accountFingerprint):\(conversationID):\(notificationIdentity)"
        switch kind {
        case .open:
            return "\(route):open"
        case .reply:
            return "\(route):reply"
        }
    }

    var replyClientMessageID: UUID? {
        guard case .reply = kind else { return nil }
        let notificationIdentity = messageDigest ?? requestIdentifier
        return MessageNotificationContract.deterministicUUID(
            scope: "notification-reply-client-message",
            values: [accountFingerprint, conversationID, notificationIdentity]
        )
    }
}

struct MessageConversationNavigationRequest: Equatable, Identifiable, Sendable {
    let id: UUID
    let conversationID: String
    let messageID: UUID?

    init(id: UUID = UUID(), conversationID: String, messageID: UUID? = nil) {
        self.id = id
        self.conversationID = conversationID
        self.messageID = messageID
    }
}

struct WalletClaimNavigationRequest: Equatable, Identifiable, Sendable {
    let id: UUID
    let claimID: String

    init(id: UUID = UUID(), claimID: String) {
        self.id = id
        self.claimID = claimID
    }
}

enum MessageNotificationTargetPolicy {
    /// Resolves the privacy-preserving digest from a locally generated notification back to one
    /// exact, already authenticated server message. Ambiguous or stale projections open the
    /// conversation without inventing a target.
    static func messageID(
        forDigest digest: String?,
        conversationID: String,
        messages: [LocalMessage]
    ) -> UUID? {
        guard let digest,
              MessageNotificationContract.isIdentifierDigest(digest),
              let conversationID = MessageNotificationContract.canonicalUUID(conversationID)
        else { return nil }
        let matches = messages.filter { message in
            guard MessageNotificationContract.canonicalUUID(message.conversationId)
                    == conversationID,
                  let serverMessageID = MessageNotificationContract.canonicalUUID(
                      message.serverMessageId
                  )
            else { return false }
            return MessageNotificationContract.messageDigest(for: serverMessageID) == digest
        }
        guard matches.count == 1 else { return nil }
        return matches[0].id
    }
}

enum MessageNotificationConversationPolicy {
    static func conversation(
        id: String,
        in conversations: [Conversation]
    ) -> Conversation? {
        guard let target = MessageNotificationContract.canonicalUUID(id) else { return nil }
        let matches = conversations.filter {
            MessageNotificationContract.canonicalUUID($0.id) == target
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    static func recipientUserID(
        in conversation: Conversation,
        currentUserID: String?
    ) -> String? {
        // A group thread has no single reply recipient; notification replies to groups stay
        // fail-closed until group replies are wired end to end (even for two-member groups).
        guard !conversation.isGroup,
              let current = MessageNotificationContract.canonicalUUID(currentUserID),
              MessageNotificationContract.canonicalUUID(conversation.id) != nil
        else { return nil }
        let participants = conversation.participantUserIds.compactMap {
            MessageNotificationContract.canonicalUUID($0)
        }
        guard participants.count == 2,
              participants.count == conversation.participantUserIds.count
        else { return nil }
        let unique = Set(participants)
        guard unique.count == 2,
              unique.contains(current)
        else { return nil }
        return unique.first { $0 != current }
    }
}

enum MessageNotificationResponsePolicy {
    static func action(
        actionIdentifier: String,
        requestIdentifier: String,
        categoryIdentifier: String,
        threadIdentifier: String,
        userInfo: [AnyHashable: Any],
        userText: String? = nil
    ) -> MessageNotificationAction? {
        guard categoryIdentifier == MessageNotificationContract.categoryIdentifier,
              let metadata = MessageNotificationMetadataPolicy.metadata(
                  requestIdentifier: requestIdentifier,
                  threadIdentifier: threadIdentifier,
                  userInfo: userInfo
              )
        else { return nil }

        let kind: MessageNotificationAction.Kind
        switch actionIdentifier {
        case UNNotificationDefaultActionIdentifier:
            kind = .open
        case MessageNotificationContract.replyActionIdentifier:
            guard let userText else { return nil }
            let reply = userText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reply.isEmpty,
                  reply.utf8.count <= MessageNotificationContract.maximumReplyBytes,
                  !reply.unicodeScalars.contains(where: { $0.value == 0 }),
                  SecureMessageReservedPrefixPolicy.allowsUserAuthoredText(reply)
            else { return nil }
            kind = .reply(reply)
        default:
            return nil
        }

        return MessageNotificationAction(
            requestIdentifier: requestIdentifier,
            conversationID: metadata.conversationID,
            accountFingerprint: metadata.accountFingerprint,
            messageDigest: metadata.version?.messageDigest,
            kind: kind
        )
    }
}

actor MessageNotificationActionDispatcher {
    typealias Handler = @MainActor @Sendable (MessageNotificationAction) async -> Bool

    static let shared = MessageNotificationActionDispatcher()

    private var handler: Handler?
    private var pending: [MessageNotificationAction] = []
    private var pendingKeys: Set<String> = []
    private var activeKeys: Set<String> = []
    private var completedKeys: Set<String> = []
    private var completedOrder: [String] = []
    private let maximumCompletedKeys = 128

    func install(_ handler: @escaping Handler) async {
        // Notification responses can arrive while SwiftUI is still constructing AppModel during
        // a cold launch. Retain that process-local intent until the account-bound model exists.
        self.handler = handler
        let buffered = pending
        pending.removeAll()
        pendingKeys.removeAll()
        for action in buffered {
            guard !completedKeys.contains(action.deduplicationKey),
                  activeKeys.insert(action.deduplicationKey).inserted
            else { continue }
            let completed = await handler(action)
            activeKeys.remove(action.deduplicationKey)
            if completed { recordCompletion(action.deduplicationKey) }
        }
    }

    func dispatch(_ action: MessageNotificationAction) async {
        guard !completedKeys.contains(action.deduplicationKey),
              !pendingKeys.contains(action.deduplicationKey),
              activeKeys.insert(action.deduplicationKey).inserted
        else { return }
        guard let handler else {
            activeKeys.remove(action.deduplicationKey)
            pending.append(action)
            pendingKeys.insert(action.deduplicationKey)
            return
        }
        let completed = await handler(action)
        activeKeys.remove(action.deduplicationKey)
        if completed { recordCompletion(action.deduplicationKey) }
    }

    private func recordCompletion(_ key: String) {
        guard completedKeys.insert(key).inserted else { return }
        completedOrder.append(key)
        while completedOrder.count > maximumCompletedKeys {
            completedKeys.remove(completedOrder.removeFirst())
        }
    }
}

struct ClaimablePaymentNotificationAction: Equatable, Sendable {
    let notificationID: String
    let claimID: String
    let conversationID: String?
    let groupPaymentID: String?

    var deduplicationKey: String {
        "\(notificationID):\(claimID)"
    }
}

enum ClaimablePaymentNotificationResponsePolicy {
    private static let supportedTypes: Set<String> = [
        "wallet.transfer_claim.opened",
        "wallet.transfer_claim.reminder",
        "wallet.transfer_claim.accepted",
        "wallet.transfer_claim.rejected",
        "wallet.transfer_claim.reversed",
        "wallet.transfer_claim.expired",
    ]

    static func action(
        actionIdentifier: String,
        categoryIdentifier: String,
        threadIdentifier: String,
        userInfo: [AnyHashable: Any]
    ) -> ClaimablePaymentNotificationAction? {
        guard actionIdentifier == UNNotificationDefaultActionIdentifier,
              categoryIdentifier == ClaimablePaymentNotificationContract.categoryIdentifier,
              userInfo["action"] as? String == "open_transfer_claim",
              let type = userInfo["type"] as? String,
              supportedTypes.contains(type),
              let notificationID = MessageNotificationContract.canonicalUUID(
                  userInfo["notification_id"] as? String
              ),
              let claimID = MessageNotificationContract.canonicalUUID(
                  userInfo["claim_id"] as? String
              )
        else { return nil }

        let expectedTag = "wallet-transfer-claim:\(claimID)"
        guard userInfo["notification_tag"] as? String == expectedTag,
              threadIdentifier == expectedTag,
              userInfo["deep_link"] as? String
                == "kitwallet://payment/claim?claim_id=\(claimID)"
        else { return nil }

        let conversationID: String?
        if let rawConversationID = userInfo["conversation_id"] {
            guard let rawConversationID = rawConversationID as? String,
                  let canonical = MessageNotificationContract.canonicalUUID(rawConversationID)
            else { return nil }
            conversationID = canonical
        } else {
            conversationID = nil
        }

        let groupPaymentID: String?
        if let rawGroupPaymentID = userInfo["group_payment_id"] {
            guard let rawGroupPaymentID = rawGroupPaymentID as? String,
                  let canonical = MessageNotificationContract.canonicalUUID(rawGroupPaymentID)
            else { return nil }
            groupPaymentID = canonical
        } else {
            groupPaymentID = nil
        }

        // Pending notifications carry a server expiry. It is routing metadata only, but malformed
        // values are refused so arbitrary strings never gain influence over an authenticated path.
        if let expiresAt = userInfo["expires_at"] {
            let fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let expiresAt = expiresAt as? String,
                  ISO8601DateFormatter().date(from: expiresAt) != nil
                    || fractionalFormatter.date(from: expiresAt) != nil
            else { return nil }
        }

        return ClaimablePaymentNotificationAction(
            notificationID: notificationID,
            claimID: claimID,
            conversationID: conversationID,
            groupPaymentID: groupPaymentID
        )
    }

}

enum ClaimablePaymentNotificationRoutingPolicy {
    static func authorizesWallet(
        action: ClaimablePaymentNotificationAction,
        claim: TransferAcceptanceDTO,
        currentUserID: String?
    ) -> Bool {
        guard let claimID = canonicalUUID(claim.id),
              claimID == action.claimID,
              claim.knownStatus != nil,
              let currentUserID = canonicalUUID(currentUserID),
              let senderID = canonicalUUID(claim.senderUserId),
              let recipientID = canonicalUUID(claim.recipientUserId),
              senderID != recipientID
        else { return false }
        return currentUserID == senderID || currentUserID == recipientID
    }

    static func conversation(
        action: ClaimablePaymentNotificationAction,
        claim: TransferAcceptanceDTO,
        conversations: [Conversation],
        currentUserID: String?
    ) -> Conversation? {
        guard authorizesWallet(action: action, claim: claim, currentUserID: currentUserID),
              let conversationID = action.conversationID,
              let currentUserID = canonicalUUID(currentUserID),
              let senderID = canonicalUUID(claim.senderUserId),
              let recipientID = canonicalUUID(claim.recipientUserId)
        else { return nil }
        let matches = conversations.filter {
            canonicalUUID($0.id) == conversationID
        }
        guard matches.count == 1,
              let conversation = matches.first,
              conversation.isGroup,
              let participants = canonicalRoster(conversation.participantUserIds),
              participants.contains(currentUserID),
              participants.contains(senderID),
              participants.contains(recipientID)
        else { return nil }
        return conversation
    }

    static func targetMessageID(
        action: ClaimablePaymentNotificationAction,
        claim: TransferAcceptanceDTO,
        conversation: Conversation,
        messages: [LocalMessage]
    ) -> UUID? {
        let matches = messages.filter { message in
            guard canonicalUUID(message.conversationId) == canonicalUUID(conversation.id)
            else { return false }
            if let descriptor = KitPaymentMessage.parse(message.body) {
                return descriptor.action == .transfer
                    && descriptor.paymentRequestId == action.claimID
                    && descriptor.matchesAuthoritativeTransfer(claim)
            }
            if let groupPaymentID = action.groupPaymentID,
               let descriptor = KitGroupPaymentMessage.parse(message.body) {
                return descriptor.groupPaymentId == groupPaymentID
            }
            return false
        }
        guard matches.count == 1 else { return nil }
        return matches[0].id
    }

    private static func canonicalRoster(_ values: [String]) -> Set<String>? {
        var roster: Set<String> = []
        for value in values {
            guard let participantID = canonicalUUID(value),
                  roster.insert(participantID).inserted
            else { return nil }
        }
        return roster
    }

    private static func canonicalUUID(_ value: String?) -> String? {
        MessageNotificationContract.canonicalUUID(value)
    }
}

actor ClaimablePaymentNotificationActionDispatcher {
    typealias Handler = @MainActor @Sendable (ClaimablePaymentNotificationAction) async -> Bool

    static let shared = ClaimablePaymentNotificationActionDispatcher()

    private var handler: Handler?
    private var pending: [ClaimablePaymentNotificationAction] = []
    private var pendingKeys: Set<String> = []
    private var activeKeys: Set<String> = []
    private var completedKeys: Set<String> = []
    private var completedOrder: [String] = []
    private let maximumCompletedKeys = 128

    func install(_ handler: @escaping Handler) async {
        self.handler = handler
        let buffered = pending
        pending.removeAll()
        pendingKeys.removeAll()
        for action in buffered {
            guard !completedKeys.contains(action.deduplicationKey),
                  activeKeys.insert(action.deduplicationKey).inserted
            else { continue }
            let completed = await handler(action)
            activeKeys.remove(action.deduplicationKey)
            if completed { recordCompletion(action.deduplicationKey) }
        }
    }

    func dispatch(_ action: ClaimablePaymentNotificationAction) async {
        guard !completedKeys.contains(action.deduplicationKey),
              !pendingKeys.contains(action.deduplicationKey),
              activeKeys.insert(action.deduplicationKey).inserted
        else { return }
        guard let handler else {
            activeKeys.remove(action.deduplicationKey)
            pending.append(action)
            pendingKeys.insert(action.deduplicationKey)
            return
        }
        let completed = await handler(action)
        activeKeys.remove(action.deduplicationKey)
        if completed { recordCompletion(action.deduplicationKey) }
    }

    private func recordCompletion(_ key: String) {
        guard completedKeys.insert(key).inserted else { return }
        completedOrder.append(key)
        while completedOrder.count > maximumCompletedKeys {
            completedKeys.remove(completedOrder.removeFirst())
        }
    }
}

struct VisibleMessageNotificationAuthorization: Equatable, Sendable {
    let status: UNAuthorizationStatus
    let alertSetting: UNNotificationSetting

    var permitsVisibleAlerts: Bool {
        let authorized = switch status {
        case .authorized, .provisional, .ephemeral: true
        case .notDetermined, .denied: false
        @unknown default: false
        }
        return authorized && alertSetting == .enabled
    }
}

enum VisibleMessageNotificationPolicy {
    static let title = "New Kit Pay message"
    static let body = "Open Kit Pay to read your encrypted message."
    static let customSoundFileName = "knock_brush.caf"

    static func descriptors(
        previousServerMessageIDs: Set<String>,
        messages: [LocalMessage],
        suppressedConversationID: String?,
        ownerUserID: String?,
        mutedConversationIDs: Set<String> = []
    ) -> [VisibleMessageNotificationDescriptor] {
        guard let accountFingerprint = MessageNotificationContract.accountFingerprint(
            for: ownerUserID
        ) else { return [] }
        let previous = Set(previousServerMessageIDs.compactMap {
            MessageNotificationContract.canonicalUUID($0)
        })
        let suppressed = MessageNotificationContract.canonicalUUID(suppressedConversationID)
        let muted = Set(mutedConversationIDs.compactMap {
            MessageNotificationContract.canonicalUUID($0)
        })
        var newestByConversation: [String: MessageNotificationVersion] = [:]

        for message in messages where !message.isOutgoing && message.state == .received {
            guard let serverID = MessageNotificationContract.canonicalUUID(message.serverMessageId),
                  !previous.contains(serverID),
                  let conversationID = MessageNotificationContract.canonicalUUID(
                      message.conversationId
                  ),
                  conversationID != suppressed,
                  !muted.contains(conversationID),
                  let version = MessageNotificationContract.messageVersion(
                      for: serverID,
                      sentAt: message.sentAt ?? message.createdAt
                  )
            else { continue }
            if let current = newestByConversation[conversationID], current >= version {
                continue
            }
            newestByConversation[conversationID] = version
        }

        return newestByConversation
            .map { (conversationID: $0.key, version: $0.value) }
            .sorted { lhs, rhs in
                if lhs.version != rhs.version {
                    return lhs.version < rhs.version
                }
                return lhs.conversationID < rhs.conversationID
            }
            .compactMap { candidate in
                guard let requestIdentifier = MessageNotificationContract
                    .conversationRequestIdentifier(
                        for: candidate.conversationID
                    ),
                      let threadIdentifier = MessageNotificationContract.threadIdentifier(
                          for: candidate.conversationID
                      )
                else { return nil }
                return VisibleMessageNotificationDescriptor(
                    requestIdentifier: requestIdentifier,
                    threadIdentifier: threadIdentifier,
                    conversationID: candidate.conversationID,
                    accountFingerprint: accountFingerprint,
                    version: candidate.version
                )
            }
    }

    static func bundledCustomSoundName(in bundle: Bundle = .main) -> String? {
        bundle.url(forResource: "knock_brush", withExtension: "caf") == nil
            ? nil
            : customSoundFileName
    }

}

struct VisibleMessageNotificationRecord: Equatable, Sendable {
    enum Location: Equatable, Hashable, Sendable {
        case pending
        case delivered
    }

    let requestIdentifier: String
    let threadIdentifier: String
    let conversationID: String
    let accountFingerprint: String
    let version: MessageNotificationVersion?
    let location: Location
    let deliveredAt: Date?
}

struct VisibleMessageNotificationPublicationPlan: Equatable, Sendable {
    let descriptorsToPublish: [VisibleMessageNotificationDescriptor]
    let recordsToRemove: [VisibleMessageNotificationRecord]
}

enum VisibleMessageNotificationPublicationPolicy {
    // Apple documents a package-wide pending-request ceiling of 64. Reserving half for call and
    // other product notifications matches Android's 32-row secure-message allowance.
    static let maximumActiveNotifications = 32

    private enum Candidate {
        case active(Int)
        case incoming(VisibleMessageNotificationDescriptor)
    }

    private struct Winner {
        let threadIdentifier: String
        let candidate: Candidate
    }

    private struct RecordIdentity: Hashable {
        let requestIdentifier: String
        let location: VisibleMessageNotificationRecord.Location
    }

    static func plan(
        active: [VisibleMessageNotificationRecord],
        incoming: [VisibleMessageNotificationDescriptor]
    ) -> VisibleMessageNotificationPublicationPlan {
        var incomingByThread: [String: VisibleMessageNotificationDescriptor] = [:]
        for descriptor in incoming {
            if let current = incomingByThread[descriptor.threadIdentifier] {
                if current.version > descriptor.version { continue }
                if current.version == descriptor.version,
                   current.accountFingerprint >= descriptor.accountFingerprint {
                    continue
                }
            }
            incomingByThread[descriptor.threadIdentifier] = descriptor
        }

        var activeByThread: [String: [Int]] = [:]
        for index in active.indices {
            activeByThread[active[index].threadIdentifier, default: []].append(index)
        }
        let threads = Set(activeByThread.keys).union(incomingByThread.keys).sorted()
        var winners: [Winner] = []

        for threadIdentifier in threads {
            let activeIndices = activeByThread[threadIdentifier] ?? []
            if let descriptor = incomingByThread[threadIdentifier] {
                let comparable = activeIndices.filter {
                    active[$0].accountFingerprint == descriptor.accountFingerprint
                        && active[$0].version != nil
                }
                if let best = preferredActiveIndex(in: comparable, active: active),
                   let activeVersion = active[best].version,
                   activeVersion >= descriptor.version {
                    winners.append(Winner(
                        threadIdentifier: threadIdentifier,
                        candidate: .active(best)
                    ))
                } else {
                    winners.append(Winner(
                        threadIdentifier: threadIdentifier,
                        candidate: .incoming(descriptor)
                    ))
                }
            } else if let best = preferredActiveIndex(in: activeIndices, active: active) {
                winners.append(Winner(
                    threadIdentifier: threadIdentifier,
                    candidate: .active(best)
                ))
            }
        }

        let ranked = winners.sorted { lhs, rhs in
            if winner(lhs, isNewerThan: rhs, active: active) { return true }
            if winner(rhs, isNewerThan: lhs, active: active) { return false }
            return lhs.threadIdentifier < rhs.threadIdentifier
        }
        let retainedThreads = Set(
            ranked.prefix(maximumActiveNotifications).map(\.threadIdentifier)
        )
        let retainedWinners = winners.filter { retainedThreads.contains($0.threadIdentifier) }
        let retainedActiveIndices = Set(retainedWinners.compactMap { winner -> Int? in
            guard case .active(let index) = winner.candidate else { return nil }
            return index
        })
        let retainedRecordIdentities = Set(retainedActiveIndices.map {
            RecordIdentity(
                requestIdentifier: active[$0].requestIdentifier,
                location: active[$0].location
            )
        })

        let removals = active.indices.compactMap { index -> VisibleMessageNotificationRecord? in
            guard !retainedActiveIndices.contains(index) else { return nil }
            let record = active[index]
            // Notification Center removes by identifier within each location. If it ever returns
            // an exact duplicate identity, removing it would also remove the retained copy.
            guard !retainedRecordIdentities.contains(RecordIdentity(
                requestIdentifier: record.requestIdentifier,
                location: record.location
            )) else { return nil }
            return record
        }.sorted { lhs, rhs in
            if lhs.location != rhs.location {
                return lhs.location == .pending
            }
            return lhs.requestIdentifier < rhs.requestIdentifier
        }

        let publications = retainedWinners.compactMap {
            winner -> VisibleMessageNotificationDescriptor? in
            guard case .incoming(let descriptor) = winner.candidate else { return nil }
            return descriptor
        }.sorted { lhs, rhs in
            if lhs.version != rhs.version { return lhs.version < rhs.version }
            return lhs.threadIdentifier < rhs.threadIdentifier
        }

        return VisibleMessageNotificationPublicationPlan(
            descriptorsToPublish: publications,
            recordsToRemove: removals
        )
    }

    private static func preferredActiveIndex(
        in indices: [Int],
        active: [VisibleMessageNotificationRecord]
    ) -> Int? {
        guard var best = indices.first else { return nil }
        for candidate in indices.dropFirst()
        where activeRecord(active[candidate], isPreferredOver: active[best]) {
            best = candidate
        }
        return best
    }

    private static func activeRecord(
        _ lhs: VisibleMessageNotificationRecord,
        isPreferredOver rhs: VisibleMessageNotificationRecord
    ) -> Bool {
        if lhs.version != rhs.version {
            switch (lhs.version, rhs.version) {
            case (.some(let lhsVersion), .some(let rhsVersion)):
                return lhsVersion > rhsVersion
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                break
            }
        }
        if lhs.deliveredAt != rhs.deliveredAt {
            return (lhs.deliveredAt ?? .distantPast) > (rhs.deliveredAt ?? .distantPast)
        }
        if lhs.location != rhs.location {
            return lhs.location == .delivered
        }
        if lhs.accountFingerprint != rhs.accountFingerprint {
            return lhs.accountFingerprint > rhs.accountFingerprint
        }
        return lhs.requestIdentifier > rhs.requestIdentifier
    }

    private static func winner(
        _ lhs: Winner,
        isNewerThan rhs: Winner,
        active: [VisibleMessageNotificationRecord]
    ) -> Bool {
        let lhsVersion = version(of: lhs.candidate, active: active)
        let rhsVersion = version(of: rhs.candidate, active: active)
        if lhsVersion != rhsVersion {
            switch (lhsVersion, rhsVersion) {
            case (.some(let lhsValue), .some(let rhsValue)):
                return lhsValue > rhsValue
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                break
            }
        }
        let lhsDate = deliveredAt(of: lhs.candidate, active: active) ?? .distantPast
        let rhsDate = deliveredAt(of: rhs.candidate, active: active) ?? .distantPast
        return lhsDate > rhsDate
    }

    private static func version(
        of candidate: Candidate,
        active: [VisibleMessageNotificationRecord]
    ) -> MessageNotificationVersion? {
        switch candidate {
        case .active(let index): active[index].version
        case .incoming(let descriptor): descriptor.version
        }
    }

    private static func deliveredAt(
        of candidate: Candidate,
        active: [VisibleMessageNotificationRecord]
    ) -> Date? {
        guard case .active(let index) = candidate else { return nil }
        return active[index].deliveredAt
    }
}

@MainActor
protocol VisibleMessageNotificationCenter: AnyObject {
    func authorization() async -> VisibleMessageNotificationAuthorization
    func activeMessageNotifications() async -> [VisibleMessageNotificationRecord]
    func removePendingRequests(withIdentifiers identifiers: [String])
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
    func add(_ request: UNNotificationRequest) async throws
}

@MainActor
final class SystemVisibleMessageNotificationCenter: VisibleMessageNotificationCenter {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func authorization() async -> VisibleMessageNotificationAuthorization {
        let settings = await center.notificationSettings()
        return VisibleMessageNotificationAuthorization(
            status: settings.authorizationStatus,
            alertSetting: settings.alertSetting
        )
    }

    func activeMessageNotifications() async -> [VisibleMessageNotificationRecord] {
        async let pending = center.pendingNotificationRequests()
        async let delivered = center.deliveredNotifications()
        let (pendingRequests, deliveredNotifications) = await (pending, delivered)
        return pendingRequests.compactMap {
            record(
                request: $0,
                location: .pending,
                deliveredAt: nil
            )
        } + deliveredNotifications.compactMap {
            record(
                request: $0.request,
                location: .delivered,
                deliveredAt: $0.date
            )
        }
    }

    func removePendingRequests(withIdentifiers identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await center.add(request)
    }

    private func record(
        request: UNNotificationRequest,
        location: VisibleMessageNotificationRecord.Location,
        deliveredAt: Date?
    ) -> VisibleMessageNotificationRecord? {
        let content = request.content
        guard content.categoryIdentifier == MessageNotificationContract.categoryIdentifier,
              let metadata = MessageNotificationMetadataPolicy.metadata(
                  requestIdentifier: request.identifier,
                  threadIdentifier: content.threadIdentifier,
                  userInfo: content.userInfo
              )
        else { return nil }
        return VisibleMessageNotificationRecord(
            requestIdentifier: request.identifier,
            threadIdentifier: metadata.threadIdentifier,
            conversationID: metadata.conversationID,
            accountFingerprint: metadata.accountFingerprint,
            version: metadata.version,
            location: location,
            deliveredAt: deliveredAt
        )
    }
}

@MainActor
final class VisibleMessageNotificationCoordinator {
    static let shared = VisibleMessageNotificationCoordinator()

    private let center: any VisibleMessageNotificationCenter
    private let bundle: Bundle
    private var schedulingTail: Task<Int, Never>?
    private var publicationGeneration: UInt64 = 0
    private var publicationEnabled = true

    init(
        center: (any VisibleMessageNotificationCenter)? = nil,
        bundle: Bundle = .main
    ) {
        self.center = center ?? SystemVisibleMessageNotificationCenter()
        self.bundle = bundle
    }

    @discardableResult
    func schedule(_ descriptors: [VisibleMessageNotificationDescriptor]) async -> Int {
        guard !descriptors.isEmpty, publicationEnabled else { return 0 }
        let expectedGeneration = publicationGeneration
        let previous = schedulingTail
        let operation = Task { @MainActor [weak self] in
            if let previous { _ = await previous.value }
            guard let self else { return 0 }
            return await self.performSchedule(
                descriptors,
                expectedGeneration: expectedGeneration
            )
        }
        schedulingTail = operation
        return await operation.value
    }

    private func performSchedule(
        _ descriptors: [VisibleMessageNotificationDescriptor],
        expectedGeneration: UInt64
    ) async -> Int {
        guard publicationIsPermitted(expectedGeneration), !Task.isCancelled else { return 0 }
        guard (await center.authorization()).permitsVisibleAlerts else { return 0 }
        guard publicationIsPermitted(expectedGeneration), !Task.isCancelled else { return 0 }

        let activeNotifications = await center.activeMessageNotifications()
        // The system-center read suspends. Ownership may enter quarantine while it is in flight;
        // a stale plan must not remove notifications that now belong to a recovered account.
        guard publicationIsPermitted(expectedGeneration), !Task.isCancelled else { return 0 }
        let plan = VisibleMessageNotificationPublicationPolicy.plan(
            active: activeNotifications,
            incoming: descriptors
        )
        let pendingIdentifiers = Set(plan.recordsToRemove.compactMap {
            $0.location == .pending ? $0.requestIdentifier : nil
        }).sorted()
        let deliveredIdentifiers = Set(plan.recordsToRemove.compactMap {
            $0.location == .delivered ? $0.requestIdentifier : nil
        }).sorted()
        if !pendingIdentifiers.isEmpty {
            center.removePendingRequests(withIdentifiers: pendingIdentifiers)
        }
        if !deliveredIdentifiers.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: deliveredIdentifiers)
        }

        var scheduledCount = 0
        for descriptor in plan.descriptorsToPublish {
            guard publicationIsPermitted(expectedGeneration), !Task.isCancelled else {
                return scheduledCount
            }
            let content = UNMutableNotificationContent()
            content.title = VisibleMessageNotificationPolicy.title
            content.body = VisibleMessageNotificationPolicy.body
            content.categoryIdentifier = MessageNotificationContract.categoryIdentifier
            content.threadIdentifier = descriptor.threadIdentifier
            content.targetContentIdentifier = descriptor.threadIdentifier
            content.userInfo = [
                "type": MessageNotificationContract.localType,
                "scope": MessageNotificationContract.messagingScope,
                "conversation_id": descriptor.conversationID,
                "account_fingerprint": descriptor.accountFingerprint,
                "thread_identifier": descriptor.threadIdentifier,
                "message_digest": descriptor.version.messageDigest,
                "sent_at_epoch_second": descriptor.version.sentAtEpochSecond,
                "sent_at_nanosecond": descriptor.version.sentAtNanosecond,
            ]
            if let customSound = VisibleMessageNotificationPolicy.bundledCustomSoundName(
                in: bundle
            ) {
                content.sound = UNNotificationSound(
                    named: UNNotificationSoundName(rawValue: customSound)
                )
            } else {
                content.sound = .default
            }

            let request = UNNotificationRequest(
                identifier: descriptor.requestIdentifier,
                content: content,
                trigger: nil
            )
            do {
                try await center.add(request)
                guard publicationIsPermitted(expectedGeneration), !Task.isCancelled else {
                    center.removePendingRequests(withIdentifiers: [request.identifier])
                    center.removeDeliveredNotifications(withIdentifiers: [request.identifier])
                    return scheduledCount
                }
                scheduledCount += 1
            } catch {
                // Message sync is authoritative and already durable. Notification delivery is
                // best-effort and must never turn a successful encrypted sync into a failure.
            }
        }
        return scheduledCount
    }

    func beginPrivacyQuarantine() {
        publicationGeneration &+= 1
        publicationEnabled = false
        schedulingTail?.cancel()
        schedulingTail = nil
    }

    func resumeAfterOwnershipRecovery() {
        publicationGeneration &+= 1
        publicationEnabled = true
    }

    private func publicationIsPermitted(_ expectedGeneration: UInt64) -> Bool {
        publicationEnabled && publicationGeneration == expectedGeneration
    }
}

/// Keeps the current process' Apple tokens until an authenticated model is ready to upload them.
/// PushKit can deliver credentials during application launch, before SwiftUI has installed its
/// notification observers, so treating the callback as a one-shot event loses incoming calls.
final class PushTokenCache: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String: String] = [:]

    func store(_ registration: PushTokenRegistration) {
        lock.lock()
        tokens[registration.provider] = registration.token
        lock.unlock()
    }

    func remove(provider: String) {
        lock.lock()
        tokens.removeValue(forKey: provider)
        lock.unlock()
    }

    func registrations() -> [PushTokenRegistration] {
        lock.lock()
        let snapshot = tokens
        lock.unlock()
        return snapshot.keys.sorted().compactMap { provider in
            snapshot[provider].map { PushTokenRegistration(provider: provider, token: $0) }
        }
    }
}

enum PushRegistrationRetryDecision: Equatable, Sendable {
    case retry(after: TimeInterval)
    case stop
}

enum PushRegistrationRetryPolicy {
    private static let exponentialDelays: [TimeInterval] = [2, 4, 8]
    private static let maximumDelay: TimeInterval = 300

    static func decision(
        for error: Error,
        automaticRetryCount: Int,
        jitterUnitInterval: Double = Double.random(in: 0 ... 1)
    ) -> PushRegistrationRetryDecision {
        guard exponentialDelays.indices.contains(automaticRetryCount),
              isRetryable(error)
        else { return .stop }

        let exponentialDelay = exponentialDelays[automaticRetryCount]
        let serverDelay = retryAfter(from: error).map { min(maximumDelay, max(0, $0)) }
        let minimumDelay = max(exponentialDelay, serverDelay ?? 0)
        // Add only positive jitter: a client must never retry before the server's Retry-After.
        let jitter = min(1, max(0, jitterUnitInterval))
        return .retry(after: min(maximumDelay, minimumDelay * (1 + (0.1 * jitter))))
    }

    static func cooldownAfterStopping(for error: Error) -> TimeInterval {
        if let urlError = error as? URLError,
           connectivityGatedURLErrorCodes.contains(urlError.code) {
            // Connectivity restoration already replays cached Apple tokens. Do not make that
            // replay wait behind a cooldown created while the phone was offline.
            return 0
        }
        if let clientError = error as? APIClientError,
           case .signedOut = clientError {
            return 0
        }
        return 300
    }

    private static func retryAfter(from error: Error) -> TimeInterval? {
        if let payload = error as? APIErrorPayload { return payload.retryAfter }
        if let clientError = error as? APIClientError,
           case .httpResponse(_, let retryAfter) = clientError {
            return retryAfter
        }
        return nil
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if let payload = error as? APIErrorPayload {
            if let status = payload.httpStatus {
                return status == 408 || status == 425 || status == 429
                    || (500 ... 599).contains(status)
            }
            return retryableAPICodes.contains(payload.code.uppercased())
        }
        if let clientError = error as? APIClientError {
            switch clientError {
            case .invalidResponse:
                return true
            case .invalidPayload(let status), .httpStatus(let status):
                return status == 408 || status == 425 || status == 429
                    || (500 ... 599).contains(status)
            case .httpResponse(let status, _):
                return status == 408 || status == 425 || status == 429
                    || (500 ... 599).contains(status)
            case .signedOut, .invalidURL:
                return false
            }
        }
        guard let urlError = error as? URLError else { return false }
        return retryableURLErrorCodes.contains(urlError.code)
    }

    private static let retryableAPICodes: Set<String> = [
        "GATEWAY_TIMEOUT",
        "INTERNAL_ERROR",
        "RATE_LIMIT_EXCEEDED",
        "RATE_LIMITED",
        "REQUEST_TIMEOUT",
        "SERVICE_UNAVAILABLE",
        "TOO_MANY_REQUESTS",
        "UPSTREAM_UNAVAILABLE",
    ]

    private static let retryableURLErrorCodes: Set<URLError.Code> = [
        .cannotConnectToHost,
        .cannotFindHost,
        .dnsLookupFailed,
        .networkConnectionLost,
        .resourceUnavailable,
        .timedOut,
    ]

    private static let connectivityGatedURLErrorCodes: Set<URLError.Code> = [
        .dataNotAllowed,
        .internationalRoamingOff,
        .notConnectedToInternet,
    ]
}

enum PushRegistrationOutcome: Hashable, Sendable {
    case registered
    case alreadyRegistered
    case deferred
    case failed
    case cancelled
}

/// Coalesces token replays from APNs, PushKit, login, and connectivity restoration. Successful
/// account/provider/token tuples are persisted as one-way fingerprints, so neither raw device
/// tokens nor account identifiers are written to preferences.
actor PushRegistrationManager {
    typealias Operation = @Sendable () async throws -> Bool
    typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

    static let shared = PushRegistrationManager()

    private struct RegistrationKey: Hashable, Sendable {
        let accountFingerprint: String
        let provider: String
        let tokenFingerprint: String

        var receiptKey: String { "\(accountFingerprint).\(provider)" }
    }

    private struct Flight {
        let id: UUID
        let task: Task<ExecutionResult, Never>
    }

    private enum ExecutionResult: Equatable, Sendable {
        case registered
        case failed(cooldown: TimeInterval)
        case cancelled
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private let receiptLifetime: TimeInterval
    private let now: @Sendable () -> Date
    private let sleeper: Sleeper
    private let jitter: @Sendable () -> Double
    private var inFlight: [RegistrationKey: Flight] = [:]
    private var retryNotBefore: [RegistrationKey: Date] = [:]

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "kit-pay-push-registration-receipts-v1",
        receiptLifetime: TimeInterval = 7 * 24 * 60 * 60,
        now: @escaping @Sendable () -> Date = { Date() },
        sleeper: @escaping Sleeper = { delay in
            try await Task<Never, Never>.sleep(for: .seconds(delay))
        },
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0 ... 1) }
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.receiptLifetime = receiptLifetime
        self.now = now
        self.sleeper = sleeper
        self.jitter = jitter
    }

    func register(
        accountID: String,
        provider rawProvider: String,
        token rawToken: String,
        operation: @escaping Operation
    ) async -> PushRegistrationOutcome {
        let provider = rawProvider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !accountID.isEmpty, !provider.isEmpty, !token.isEmpty else { return .failed }

        let key = RegistrationKey(
            accountFingerprint: Self.fingerprint(accountID.lowercased()),
            provider: provider,
            tokenFingerprint: Self.fingerprint(token)
        )
        var receipts = registrationReceipts()
        if isFreshReceipt(receipts[key.receiptKey], for: key) {
            return .alreadyRegistered
        }
        if receipts.removeValue(forKey: key.receiptKey) != nil {
            saveRegistrationReceipts(receipts)
        }
        if let retryDate = retryNotBefore[key], retryDate > now() {
            return .deferred
        }
        retryNotBefore.removeValue(forKey: key)

        if let flight = inFlight[key] {
            return await finish(flight: flight, for: key)
        }

        // A newly issued token supersedes an older token for the same account/provider.
        let staleKeys = inFlight.keys.filter {
            $0.accountFingerprint == key.accountFingerprint
                && $0.provider == key.provider
                && $0.tokenFingerprint != key.tokenFingerprint
        }
        for staleKey in staleKeys {
            inFlight.removeValue(forKey: staleKey)?.task.cancel()
            retryNotBefore.removeValue(forKey: staleKey)
        }

        let flightID = UUID()
        let sleeper = self.sleeper
        let jitter = self.jitter
        let task = Task {
            await Self.execute(operation: operation, sleeper: sleeper, jitter: jitter)
        }
        let flight = Flight(id: flightID, task: task)
        inFlight[key] = flight
        return await finish(flight: flight, for: key)
    }

    /// Cancels retries and removes durable success for an account. Sign-out calls this before
    /// deleting the server registration so a later login correctly uploads both Apple tokens.
    func reset(accountID: String, provider rawProvider: String? = nil) {
        let accountFingerprint = Self.fingerprint(accountID.lowercased())
        let provider = rawProvider?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let matchingKeys = inFlight.keys.filter {
            $0.accountFingerprint == accountFingerprint
                && (provider == nil || $0.provider == provider)
        }
        for key in matchingKeys {
            inFlight.removeValue(forKey: key)?.task.cancel()
            retryNotBefore.removeValue(forKey: key)
        }
        let cooldownKeys = retryNotBefore.keys.filter {
            $0.accountFingerprint == accountFingerprint
                && (provider == nil || $0.provider == provider)
        }
        cooldownKeys.forEach { retryNotBefore.removeValue(forKey: $0) }

        var receipts = registrationReceipts()
        let prefix = "\(accountFingerprint)."
        receipts = receipts.filter { receiptKey, _ in
            guard receiptKey.hasPrefix(prefix) else { return true }
            guard let provider else { return false }
            return receiptKey != "\(prefix)\(provider)"
        }
        saveRegistrationReceipts(receipts)
    }

    func cancelAll() {
        inFlight.values.forEach { $0.task.cancel() }
        inFlight.removeAll()
        retryNotBefore.removeAll()
    }

    private func finish(
        flight: Flight,
        for key: RegistrationKey
    ) async -> PushRegistrationOutcome {
        let result = await flight.task.value
        guard inFlight[key]?.id == flight.id else {
            if result == .registered,
               isFreshReceipt(registrationReceipts()[key.receiptKey], for: key) {
                return .alreadyRegistered
            }
            return result == .cancelled ? .cancelled : .deferred
        }
        inFlight.removeValue(forKey: key)

        switch result {
        case .registered:
            var receipts = registrationReceipts()
            receipts[key.receiptKey] = "\(key.tokenFingerprint):\(now().timeIntervalSince1970)"
            saveRegistrationReceipts(receipts)
            retryNotBefore.removeValue(forKey: key)
            return .registered
        case .failed(let cooldown):
            retryNotBefore[key] = now().addingTimeInterval(cooldown)
            return .failed
        case .cancelled:
            return .cancelled
        }
    }

    private static func execute(
        operation: @escaping Operation,
        sleeper: @escaping Sleeper,
        jitter: @escaping @Sendable () -> Double
    ) async -> ExecutionResult {
        var automaticRetryCount = 0
        while true {
            do {
                try Task.checkCancellation()
                guard try await operation() else { return .failed(cooldown: 900) }
                try Task.checkCancellation()
                return .registered
            } catch is CancellationError {
                return .cancelled
            } catch {
                switch PushRegistrationRetryPolicy.decision(
                    for: error,
                    automaticRetryCount: automaticRetryCount,
                    jitterUnitInterval: jitter()
                ) {
                case .retry(let delay):
                    automaticRetryCount += 1
                    do {
                        try await sleeper(delay)
                    } catch {
                        return .cancelled
                    }
                case .stop:
                    return .failed(
                        cooldown: PushRegistrationRetryPolicy.cooldownAfterStopping(for: error)
                    )
                }
            }
        }
    }

    private func registrationReceipts() -> [String: String] {
        defaults.dictionary(forKey: storageKey) as? [String: String] ?? [:]
    }

    private func saveRegistrationReceipts(_ receipts: [String: String]) {
        defaults.set(receipts, forKey: storageKey)
    }

    private func isFreshReceipt(
        _ receipt: String?,
        for key: RegistrationKey
    ) -> Bool {
        guard let receipt,
              let separator = receipt.lastIndex(of: ":"),
              String(receipt[..<separator]) == key.tokenFingerprint,
              let registeredAt = TimeInterval(receipt[receipt.index(after: separator)...])
        else { return false }
        let age = now().timeIntervalSince1970 - registeredAt
        return age >= 0 && age < receiptLifetime
    }

    private static func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

actor SecureMessagingWakeDispatcher {
    typealias Handler = @Sendable (SecureMessagingRemoteWake) async -> UIBackgroundFetchResult

    static let shared = SecureMessagingWakeDispatcher()

    private var handler: Handler?

    func install(_ handler: @escaping Handler) {
        self.handler = handler
    }

    func dispatch(_ wake: SecureMessagingRemoteWake) async -> UIBackgroundFetchResult {
        for _ in 0..<20 {
            if let handler { return await handler(wake) }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return .noData
    }
}

enum CallKitAnswerActionDisposition: Equatable {
    case answerPrimary
    case mergeWaiting
    case reject
}

/// A provider End callback does not identify whether it came from an ordinary hang-up or from the
/// destructive half of CallKit's End & Accept transaction. Preserve the connected call only when
/// exactly one earlier Answer callback already established that intent for this exact active UUID.
/// End alone is never merge authority.
enum CallKitActiveEndActionPolicy {
    static func preservesActiveCall(
        actionCallUUID: UUID,
        connectedActiveCallUUID: UUID?,
        wasExplicitlyRequestedInApp: Bool,
        priorAnswerActiveCallUUIDs: [UUID]
    ) -> Bool {
        guard !wasExplicitlyRequestedInApp,
              connectedActiveCallUUID == actionCallUUID
        else { return false }
        return priorAnswerActiveCallUUIDs.filter { $0 == actionCallUUID }.count == 1
    }
}

/// Keeps the CallKit answer boundary independent from media setup. A different authenticated call
/// may be translated to Android-parity Merge only while one exact media call is already connected;
/// malformed or contradictory ownership fails closed instead of replacing that media session.
enum CallKitAnswerActionPolicy {
    static func disposition(
        actionCallID: String,
        authenticatedIncomingCallID: String?,
        activeCallID: String?,
        mediaState: CallWaitingMediaState
    ) -> CallKitAnswerActionDisposition {
        guard let actionCallID = canonicalUUID(actionCallID),
              canonicalUUID(authenticatedIncomingCallID) == actionCallID
        else { return .reject }

        guard mediaState == .connected || mediaState == .reconnecting else {
            return .answerPrimary
        }
        guard let activeCallID = canonicalUUID(activeCallID) else { return .reject }
        return activeCallID == actionCallID ? .answerPrimary : .mergeWaiting
    }

    private static func canonicalUUID(_ value: String?) -> String? {
        guard let value,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              let identifier = UUID(uuidString: value)
        else { return nil }
        return identifier.uuidString.lowercased()
    }
}

extension Notification.Name {
    static let kitPushTokenReceived = Notification.Name("africa.kit.pay.push-token")
    static let kitPushTokenInvalidated = Notification.Name("africa.kit.pay.push-token-invalidated")
    static let kitRemoteWakeReceived = Notification.Name("africa.kit.pay.remote-wake")
    static let kitCallMediaFailed = Notification.Name("africa.kit.pay.call-media-failed")
    static let kitCallLifecycleEvent = Notification.Name("africa.kit.pay.call-lifecycle-event")
    static let kitPendingOutgoingCallEnded = Notification.Name(
        "africa.kit.pay.pending-outgoing-call-ended"
    )
}

/// An immutable PushKit payload that can cross a `@Sendable` boundary.
///
/// `PKPushPayload.dictionaryPayload` is `[AnyHashable: Any]`, which Swift cannot prove is safe to
/// send. The dictionary is a property-list snapshot Apple hands over once and nothing mutates it,
/// so it is wrapped rather than copied element by element.
struct RemoteWakePayload: @unchecked Sendable {
    let values: [AnyHashable: Any]
}

final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate, PKPushRegistryDelegate {
    static let shared = NotificationCoordinator()

    private struct QuarantinedIncomingCall {
        let push: IncomingCallPush
        let expiresAt: Date
        var verificationEventID: UUID?
        var verificationFailureCount: Int
        var verificationRetryNotBefore: Date?
    }

    private let callProvider: CXProvider
    private let callController = CXCallController()
    /// Constructed with the process-wide notification coordinator so background suspension is
    /// observed even before the first call action reaches the audio layer.
    private let callSounds = CallProgressSoundPlayer.shared
    private let pushTokens = PushTokenCache()
    private let pendingCallEvents = PendingCallEventCache()
    private var voipRegistry: PKPushRegistry?
    private var registrationEnabled = false
    private var privacyQuarantineActive = false
    private var communicationOwnerFingerprint: String?
    private var suppressPushTokenInvalidation = false
    private var backendCallIds: [UUID: String] = [:]
    private var incomingCalls: [UUID: AuthenticatedIncomingCall] = [:]
    private var answeredCalls: Set<UUID> = []
    private var outgoingCalls: Set<UUID> = []
    private var connectedOutgoingCalls: Set<UUID> = []
    private var pendingOutgoingMedia: [UUID: AuthenticatedCallMediaHandoff] = [:]
    private var videoCalls: [UUID: Bool] = [:]
    private var ringExpiryTasks: [UUID: Task<Void, Never>] = [:]
    private var quarantinedIncomingCalls: [UUID: QuarantinedIncomingCall] = [:]
    private var quarantineExpiryTasks: [UUID: Task<Void, Never>] = [:]
    private var verificationRetryTasks: [UUID: Task<Void, Never>] = [:]
    private var callDisplayNames: [UUID: String] = [:]
    private var callAdmissionGenerations: [UUID: UInt64] = [:]
    private var callRegistryGeneration: UInt64 = 0
    /// Distinguishes an in-app hang-up from CallKit's synthetic active-call End action in an
    /// End & Accept transaction. Only the exact UUID inserted by `requestEndCall` may bypass the
    /// waiting-call interception below.
    private var explicitlyRequestedEndCallUUIDs: Set<UUID> = []
    /// Owns the one authenticated waiting call while its caller is being invited into the current
    /// room. The marker deduplicates Answer/End & Accept and prevents a concurrent decline action.
    private var waitingCallMergeUUIDs: Set<UUID> = []
    /// Binds an authenticated CallKit Answer intent to the exact active room it was answering from.
    /// A plain End callback never writes this map.
    private var callKitAnswerMergeOwners: [UUID: UUID] = [:]
    /// Remembers an Answer intent received on Apple's generic pre-verification surface, bound to
    /// the exact active call. It cannot publish until `admit` establishes caller authority, and it
    /// is discarded rather than retargeted if that active room changes first.
    private var pendingAuthenticatedMergeIntents: [UUID: UUID] = [:]
    /// Retains only the system Answer action while an opaque PushKit call is being authenticated.
    /// Caller identity, media credentials, and backend authority remain absent until promotion.
    private var deferredPrimaryAnswerGate = DeferredCallKitAnswerGate()
    private var deferredPrimaryAnswerActions: [UUID: CXAnswerCallAction] = [:]
    /// Fences CallKit audio callbacks that were queued before a later deactivate, reset, or account
    /// transition. The expected-active bit prevents an older activation task from winning last.
    private var callKitAudioTransitionGeneration: UInt64 = 0
    private var callKitAudioExpectedActive = false
    /// Set when Apple reports that APNs registration failed.
    ///
    /// Registration was previously attempted exactly once per sign-in and the failure callback was
    /// empty, so a device that was offline or transiently rejected at that moment never asked
    /// again: alerts, background message wakes and call-state sync stayed dead for the rest of the
    /// session, with no token cached to replay. Connectivity recovery now retries.
    private var needsRemoteRegistrationRetry = false

    override init() {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = true
        // One connected room plus one authenticated waiting call. Kit Pay deliberately does not
        // expose hold/swap or two simultaneous media rooms; answering the waiting CallKit surface
        // is translated into Android-parity invite-and-decline merge semantics below.
        configuration.maximumCallGroups = 2
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]
        configuration.includesCallsInRecents = true
        configuration.ringtoneSound = CallRingtonePolicy.customSoundName
        callProvider = CXProvider(configuration: configuration)
        super.init()
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.setNotificationCategories([
            MessageNotificationContract.category,
            ClaimablePaymentNotificationContract.category,
        ])
        notificationCenter.delegate = self
        callProvider.setDelegate(self, queue: .main)
    }

    private func invalidateCallActionOwnership(
        includingDeferredPrimaryAnswers: Bool = true
    ) {
        explicitlyRequestedEndCallUUIDs.removeAll(keepingCapacity: true)
        waitingCallMergeUUIDs.removeAll(keepingCapacity: true)
        callKitAnswerMergeOwners.removeAll(keepingCapacity: true)
        pendingAuthenticatedMergeIntents.removeAll(keepingCapacity: true)
        if includingDeferredPrimaryAnswers {
            failDeferredPrimaryAnswers(
                deferredPrimaryAnswerGate.invalidateAll()
                    .union(deferredPrimaryAnswerActions.keys)
            )
        }
    }

    private func failDeferredPrimaryAnswers(_ callUUIDs: Set<UUID>) {
        for callUUID in callUUIDs {
            deferredPrimaryAnswerActions.removeValue(forKey: callUUID)?.fail()
        }
    }

    private func failDeferredPrimaryAnswer(for callUUID: UUID) {
        deferredPrimaryAnswerGate.remove(callUUID: callUUID)
        deferredPrimaryAnswerActions.removeValue(forKey: callUUID)?.fail()
    }

    private func invalidateCallKitAudio(resetSounds: Bool) {
        callKitAudioTransitionGeneration &+= 1
        callKitAudioExpectedActive = false
        if resetSounds {
            callSounds.resetForSessionReplacement()
        } else {
            callSounds.callKitAudioDidDeactivate()
        }
    }

    @MainActor
    func requestAuthorizationAndRegister(forAccountID accountID: String) {
        guard enableRegistration(afterOwnershipRecoveryFor: accountID) else { return }
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .badge, .sound, .timeSensitive]
        ) { _, _ in
            // Alert permission and APNs registration are independent. Keep a normal APNs token
            // for silent call-state synchronization even when the user declines visible alerts.
            //
            // Apple delivers this on an arbitrary thread through a `@Sendable` closure, so the
            // coordinator is reached through its process-wide instance on the main actor rather
            // than captured across that boundary.
            Task { @MainActor in
                NotificationCoordinator.shared.registerForRemoteNotificationsIfEnabled()
            }
        }
    }

    @MainActor
    func registerForRemoteNotificationsIfEnabled() {
        guard registrationEnabled else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Re-asks APNs for a token after a reported registration failure. Called when connectivity
    /// returns, which is the condition that most often caused the failure in the first place.
    @MainActor
    func retryRemoteRegistrationIfNeeded() {
        guard needsRemoteRegistrationRetry, registrationEnabled else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    @MainActor
    fileprivate func recordRemoteRegistrationFailure() {
        needsRemoteRegistrationRetry = true
    }

    /// Restores token delivery after launch without presenting the notification prompt again.
    /// PushKit and background APNs registration have no user-facing permission UI.
    @MainActor
    func resumeRegistration(afterOwnershipRecoveryFor accountID: String) {
        guard enableRegistration(afterOwnershipRecoveryFor: accountID) else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// PushKit must be constructed promptly on a VoIP cold launch, but account-bound caller
    /// metadata is quarantined until AppModel finishes protected-state/deletion recovery.
    @MainActor
    func prepareForProtectedStateRestore() {
        registrationEnabled = false
        privacyQuarantineActive = true
        invalidateCallActionOwnership()
        invalidateCallKitAudio(resetSounds: true)
        communicationOwnerFingerprint = nil
        ProtectedCommunicationAdmissionGate.shared.quarantine()
        VisibleMessageNotificationCoordinator.shared.beginPrivacyQuarantine()
        suppressPushTokenInvalidation = false
        ensureVoIPRegistry()
        UIApplication.shared.registerForRemoteNotifications()
    }

    @MainActor
    @discardableResult
    private func enableRegistration(afterOwnershipRecoveryFor accountID: String) -> Bool {
        guard let recoveredFingerprint = MessageNotificationContract.accountFingerprint(
            for: accountID
        ) else { return false }
        let previousOwner = communicationOwnerFingerprint
        if registrationEnabled,
           !privacyQuarantineActive,
           previousOwner == recoveredFingerprint {
            ensureVoIPRegistry()
            replayCurrentPushTokens()
            return true
        }
        let reusesAuthenticatedCalls =
            RetainedCallOwnerRecoveryPolicy.mayReuseAuthenticatedCalls(
                previousOwnerFingerprint: previousOwner,
                recoveredOwnerFingerprint: recoveredFingerprint
            )
        callRegistryGeneration &+= 1
        invalidateCallActionOwnership(includingDeferredPrimaryAnswers: false)
        failDeferredPrimaryAnswers(
            deferredPrimaryAnswerGate.rebindForInitialOwnershipRecovery(
                previousOwnerFingerprint: previousOwner,
                quarantinedCallUUIDs: Set(quarantinedIncomingCalls.keys),
                newGeneration: callRegistryGeneration
            )
        )
        privacyQuarantineActive = false
        registrationEnabled = true
        communicationOwnerFingerprint = recoveredFingerprint
        ProtectedCommunicationAdmissionGate.shared.restore(forAccountID: accountID)
        VisibleMessageNotificationCoordinator.shared.resumeAfterOwnershipRecovery()
        suppressPushTokenInvalidation = false
        ensureVoIPRegistry()
        if reusesAuthenticatedCalls {
            for callUUID in backendCallIds.keys {
                callAdmissionGenerations[callUUID] = callRegistryGeneration
            }
            for incoming in incomingCalls.values where !answeredCalls.contains(incoming.callUUID) {
                scheduleRingExpiry(for: incoming)
            }
            revealRetainedCallIdentity()
        } else {
            for callUUID in Array(backendCallIds.keys) {
                clearCall(callUUID)
                callProvider.reportCall(with: callUUID, endedAt: Date(), reason: .failed)
            }
        }
        for callUUID in Array(quarantinedIncomingCalls.keys) {
            guard var pending = quarantinedIncomingCalls[callUUID] else { continue }
            verificationRetryTasks.removeValue(forKey: callUUID)?.cancel()
            if let staleEventID = pending.verificationEventID {
                pendingCallEvents.acknowledge(staleEventID)
            }
            pending.verificationEventID = nil
            if !reusesAuthenticatedCalls {
                pending.verificationFailureCount = 0
                pending.verificationRetryNotBefore = nil
            }
            quarantinedIncomingCalls[callUUID] = pending
            callAdmissionGenerations[callUUID] = callRegistryGeneration
        }
        requestVerificationForQuarantinedIncomingCalls()
        replayCurrentPushTokens()
        return true
    }

    @MainActor
    private func ensureVoIPRegistry() {
        if let voipRegistry {
            voipRegistry.desiredPushTypes = [.voIP]
            return
        }
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        voipRegistry = registry
    }

    /// Stops delivery to a signed-out account after the backend registrations have been removed.
    /// A later sign-in calls `requestAuthorizationAndRegister()` and obtains fresh credentials.
    @MainActor
    func suspendRegistrationAfterSignOut() {
        registrationEnabled = false
        privacyQuarantineActive = true
        invalidateCallActionOwnership()
        invalidateCallKitAudio(resetSounds: true)
        communicationOwnerFingerprint = nil
        ProtectedCommunicationAdmissionGate.shared.quarantine()
        VisibleMessageNotificationCoordinator.shared.beginPrivacyQuarantine()
        suppressPushTokenInvalidation = true
        UIApplication.shared.unregisterForRemoteNotifications()
        voipRegistry?.desiredPushTypes = []
        pushTokens.remove(provider: "apns")
        pushTokens.remove(provider: "apns_voip")
        discardQuarantinedIncomingCalls()
    }

    /// Revokes call admission and clears CallKit state without deleting cached push tokens. AppModel
    /// invokes this before its first sign-out suspension, then unregisters those tokens remotely.
    @MainActor
    func beginAccountSignOut() {
        registrationEnabled = false
        privacyQuarantineActive = true
        invalidateCallActionOwnership()
        ProtectedCommunicationAdmissionGate.shared.quarantine()
        VisibleMessageNotificationCoordinator.shared.beginPrivacyQuarantine()
        callRegistryGeneration &+= 1
        invalidateCallKitAudio(resetSounds: true)
        let activeCalls = backendCallIds
        ringExpiryTasks.values.forEach { $0.cancel() }
        ringExpiryTasks.removeAll()
        discardQuarantinedIncomingCalls()
        for (callUUID, _) in activeCalls {
            clearCall(callUUID)
            callProvider.reportCall(with: callUUID, endedAt: Date(), reason: .failed)
        }
        backendCallIds.removeAll()
        incomingCalls.removeAll()
        answeredCalls.removeAll()
        outgoingCalls.removeAll()
        connectedOutgoingCalls.removeAll()
        pendingOutgoingMedia.removeAll()
        videoCalls.removeAll()
        callDisplayNames.removeAll()
        callAdmissionGenerations.removeAll()
        pendingCallEvents.removeAll()
        communicationOwnerFingerprint = nil
    }

    /// Conceals account-bound communication while protected state or deletion ownership is
    /// unresolved. A known target retires only that owner's surfaces; a proven replacement owner
    /// is retained in memory, but remains generic and non-interactive until AppModel re-proves it.
    /// Apple credentials stay cached so quarantine is reversible without losing registration.
    @MainActor
    func beginPrivacyQuarantine(targetAccountID: String?) {
        let targetFingerprint = MessageNotificationContract.accountFingerprint(
            for: targetAccountID
        )
        registrationEnabled = false
        privacyQuarantineActive = true
        invalidateCallActionOwnership()
        invalidateCallKitAudio(resetSounds: true)
        ProtectedCommunicationAdmissionGate.shared.quarantine()
        VisibleMessageNotificationCoordinator.shared.beginPrivacyQuarantine()
        callRegistryGeneration &+= 1
        verificationRetryTasks.values.forEach { $0.cancel() }
        verificationRetryTasks.removeAll()
        suppressPushTokenInvalidation = false

        let ownerIsUnproven = communicationOwnerFingerprint == nil
        let targetsCurrentOwner = targetFingerprint != nil
            && targetFingerprint == communicationOwnerFingerprint
        if ownerIsUnproven || targetsCurrentOwner {
            let visibleCallUUIDs = Set(backendCallIds.keys).union(quarantinedIncomingCalls.keys)
            for callUUID in visibleCallUUIDs {
                clearCall(callUUID)
                callProvider.reportCall(with: callUUID, endedAt: Date(), reason: .failed)
            }
            discardQuarantinedIncomingCalls()
            pendingCallEvents.removeAll()
            communicationOwnerFingerprint = nil
        } else {
            for incoming in incomingCalls.values where !answeredCalls.contains(incoming.callUUID) {
                scheduleRingExpiry(for: incoming)
            }
            concealRetainedCallIdentity()
        }
    }

    /// Replays credentials that Apple delivered before authentication or before `AppModel`
    /// installed its observers. Backend registration remains authenticated and authoritative.
    func replayCurrentPushTokens() {
        guard registrationEnabled, !privacyQuarantineActive else { return }
        pushTokens.registrations().forEach(publishPushToken)
    }

    fileprivate func recordAndPublishPushToken(_ registration: PushTokenRegistration) {
        needsRemoteRegistrationRetry = false
        pushTokens.store(registration)
        guard registrationEnabled, !privacyQuarantineActive else { return }
        publishPushToken(registration)
    }

    private func publishPushToken(_ registration: PushTokenRegistration) {
        NotificationCenter.default.post(name: .kitPushTokenReceived, object: registration)
    }

    /// Replays unacknowledged lifecycle events after `AppModel` installs its observer. The model
    /// deduplicates event IDs, so replay can safely race with a live delegate callback.
    func replayPendingCallEvents() {
        pendingCallEvents.pendingEvents().forEach(publishCallEvent)
    }

    func acknowledgeCallEvent(_ eventId: UUID) {
        pendingCallEvents.acknowledge(eventId)
    }

    private func recordAndPublishCallEvent(_ event: CallLifecycleEvent) {
        pendingCallEvents.store(event)
        publishCallEvent(event)
    }

    private func publishCallEvent(_ event: CallLifecycleEvent) {
        NotificationCenter.default.post(name: .kitCallLifecycleEvent, object: event)
    }

    @MainActor
    func reportCallEnded(_ callUUID: UUID, reason: CXCallEndedReason) {
        clearCall(callUUID)
        callProvider.reportCall(with: callUUID, endedAt: Date(), reason: reason)
    }

    @MainActor
    func requestStartOutgoingCall(_ request: AuthenticatedCallMediaHandoff) {
        let handoff = request.handoff
        guard registrationEnabled, !privacyQuarantineActive else {
            Task {
                await CallMediaCoordinator.shared.callKitStartFailed(
                    request,
                    error: CancellationError()
                )
            }
            return
        }
        guard let callUUID = UUID(uuidString: handoff.callId) else {
            Task {
                await CallMediaCoordinator.shared.callKitStartFailed(
                    request,
                    error: CallQueueError.invalidRTC
                )
            }
            return
        }
        backendCallIds[callUUID] = handoff.callId.lowercased()
        callAdmissionGenerations[callUUID] = callRegistryGeneration
        outgoingCalls.insert(callUUID)
        pendingOutgoingMedia[callUUID] = request
        videoCalls[callUUID] = handoff.video
        callDisplayNames[callUUID] = handoff.participantName

        let handle = CXHandle(type: .generic, value: handoff.participantName)
        let action = CXStartCallAction(call: callUUID, handle: handle)
        action.isVideo = handoff.video
        callController.request(CXTransaction(action: action)) { error in
            guard let error else { return }
            Task { @MainActor in
                NotificationCoordinator.shared.clearCall(callUUID)
                await CallMediaCoordinator.shared.callKitStartFailed(request, error: error)
            }
        }
    }

    private func hasCurrentCallRegistryOwnership(_ callUUID: UUID) -> Bool {
        guard callAdmissionGenerations[callUUID] == callRegistryGeneration,
              let backendCallID = backendCallIds[callUUID],
              let backendCallUUID = UUID(uuidString: backendCallID),
              backendCallUUID == callUUID
        else { return false }
        return true
    }

    private func currentCallKitAudioOwnerUUID() -> UUID? {
        let candidates = backendCallIds.keys.filter { callUUID in
            hasCurrentCallRegistryOwnership(callUUID)
                && (answeredCalls.contains(callUUID) || outgoingCalls.contains(callUUID))
        }
        guard candidates.count == 1 else { return nil }
        return candidates[0]
    }

    private func authenticatedUnansweredIncomingCall(
        _ callUUID: UUID,
        requiresUnexpiredRing: Bool
    ) -> AuthenticatedIncomingCall? {
        guard hasCurrentCallRegistryOwnership(callUUID),
              let backendCallID = backendCallIds[callUUID],
              let incoming = incomingCalls[callUUID],
              incoming.callUUID == callUUID,
              let incomingRecordUUID = UUID(uuidString: incoming.record.id),
              incomingRecordUUID == callUUID,
              backendCallID.caseInsensitiveCompare(incoming.record.id) == .orderedSame,
              !answeredCalls.contains(callUUID),
              !outgoingCalls.contains(callUUID),
              incoming.record.state == .ringing,
              incoming.record.direction.caseInsensitiveCompare("incoming") == .orderedSame,
              !requiresUnexpiredRing || incoming.ringExpiryDate > Date()
        else { return nil }
        return incoming
    }

    @MainActor
    private func connectedActiveMediaCallUUID() -> UUID? {
        let mediaCoordinator = CallMediaCoordinator.shared
        guard mediaCoordinator.state == .connected || mediaCoordinator.state == .reconnecting,
              let activeCallID = mediaCoordinator.activeCall?.id,
              let activeCallUUID = UUID(uuidString: activeCallID),
              hasCurrentCallRegistryOwnership(activeCallUUID),
              backendCallIds[activeCallUUID]?.caseInsensitiveCompare(activeCallID) == .orderedSame
        else { return nil }
        return activeCallUUID
    }

    private func currentPriorAnswerActiveCallUUIDs() -> [UUID] {
        var activeCallUUIDs: [UUID] = []
        activeCallUUIDs.reserveCapacity(
            callKitAnswerMergeOwners.count + pendingAuthenticatedMergeIntents.count
        )
        for (waitingCallUUID, activeCallUUID) in callKitAnswerMergeOwners {
            guard authenticatedUnansweredIncomingCall(
                waitingCallUUID,
                requiresUnexpiredRing: false
            ) != nil else { continue }
            activeCallUUIDs.append(activeCallUUID)
        }
        for (waitingCallUUID, activeCallUUID) in pendingAuthenticatedMergeIntents {
            guard callAdmissionGenerations[waitingCallUUID] == callRegistryGeneration,
                  quarantinedIncomingCalls[waitingCallUUID] != nil
            else { continue }
            activeCallUUIDs.append(activeCallUUID)
        }
        return activeCallUUIDs
    }

    @MainActor
    @discardableResult
    private func markAndPublishCallKitAnswerMergeIfNeeded(
        callUUID: UUID,
        expectedActiveCallUUID: UUID
    ) -> Bool {
        guard let incoming = authenticatedUnansweredIncomingCall(
                  callUUID,
                  requiresUnexpiredRing: true
              ),
              let activeCallUUID = connectedActiveMediaCallUUID(),
              activeCallUUID == expectedActiveCallUUID,
              activeCallUUID != callUUID
        else { return false }

        if let existingOwner = callKitAnswerMergeOwners[callUUID],
           existingOwner != expectedActiveCallUUID {
            return false
        }
        callKitAnswerMergeOwners[callUUID] = expectedActiveCallUUID
        guard waitingCallMergeUUIDs.insert(callUUID).inserted else { return false }

        recordAndPublishCallEvent(
            .systemAction(CallSystemAction(
                callId: incoming.record.id,
                callUUID: callUUID,
                kind: .mergeWaiting,
                presentation: ActiveCallPresentation(
                    id: incoming.record.id,
                    participantName: incoming.record.name,
                    video: incoming.record.video,
                    direction: "incoming"
                )
            ))
        )
        return true
    }

    /// Marks the exact authenticated waiting call before AppModel crosses the invitation request.
    /// While marked, CallKit decline actions for this UUID fail instead of racing the mutation.
    @MainActor
    func beginWaitingCallMergeAttempt(callId: String) {
        guard let callUUID = UUID(uuidString: callId),
              authenticatedUnansweredIncomingCall(
                  callUUID,
                  requiresUnexpiredRing: true
              ) != nil,
              let activeCallUUID = connectedActiveMediaCallUUID(),
              activeCallUUID != callUUID
        else { return }
        waitingCallMergeUUIDs.insert(callUUID)
    }

    /// Releases merge ownership and restores the original absolute ring deadline. Scheduling is
    /// asynchronous even when that deadline has passed, giving a successful merge in this actor
    /// turn a chance to retire the CallKit record before timeout publication.
    @MainActor
    func finishWaitingCallMergeAttempt(callId: String) {
        guard let callUUID = UUID(uuidString: callId) else { return }
        callKitAnswerMergeOwners.removeValue(forKey: callUUID)
        pendingAuthenticatedMergeIntents.removeValue(forKey: callUUID)
        guard waitingCallMergeUUIDs.remove(callUUID) != nil,
              let incoming = authenticatedUnansweredIncomingCall(
                  callUUID,
                  requiresUnexpiredRing: false
              )
        else { return }
        scheduleRingExpiry(for: incoming)
    }

    @MainActor
    /// Returns whether a CallKit end transaction was actually submitted. A hang-up must never
    /// depend silently on CallKit accepting the call: when any admission guard fails, the caller
    /// runs `endCallBypassingCallKit` so the user is never stranded on a live call with a dead
    /// End button.
    @discardableResult
    func requestEndCall(callId: String) -> Bool {
        guard let callUUID = UUID(uuidString: callId) else { return false }
        // A transaction for this call is already in flight; report accepted so the caller does
        // not race it with a duplicate fallback teardown.
        guard !explicitlyRequestedEndCallUUIDs.contains(callUUID) else { return true }
        guard registrationEnabled, !privacyQuarantineActive,
              hasCurrentCallRegistryOwnership(callUUID),
              backendCallIds[callUUID]?.caseInsensitiveCompare(callId) == .orderedSame,
              explicitlyRequestedEndCallUUIDs.insert(callUUID).inserted
        else { return false }
        callController.request(CXTransaction(action: CXEndCallAction(call: callUUID))) { error in
            guard let error else { return }
            Task { @MainActor in
                let coordinator = NotificationCoordinator.shared
                guard coordinator.explicitlyRequestedEndCallUUIDs.remove(callUUID) != nil
                else { return }
                await coordinator.endCallBypassingCallKit(callId: callId)
                CallMediaCoordinator.shared.recordControlError(error)
            }
        }
        return true
    }

    /// Ends a call that CallKit cannot (or will not) terminate: tears the CallKit record down if
    /// one exists, publishes the authenticated `.end` action so the backend termination replays,
    /// and disconnects media directly.
    @MainActor
    func endCallBypassingCallKit(callId: String) async {
        let backendCallId: String
        if let callUUID = UUID(uuidString: callId) {
            backendCallId = backendCallIds[callUUID] ?? callId.lowercased()
            clearCall(callUUID)
            callProvider.reportCall(with: callUUID, endedAt: Date(), reason: .failed)
            recordAndPublishCallEvent(
                .systemAction(CallSystemAction(
                    callId: backendCallId,
                    callUUID: callUUID,
                    kind: .end
                ))
            )
        } else {
            backendCallId = callId.lowercased()
        }
        await CallMediaCoordinator.shared.disconnectFromCallKit(callId: backendCallId)
    }

    /// Declines one unanswered incoming CallKit call without touching the connected media call.
    /// The normal provider callback publishes the authenticated backend decline action; the
    /// fallback does the same if CallKit can no longer accept the transaction.
    @MainActor
    func requestDeclineIncomingCall(callId: String) {
        guard registrationEnabled, !privacyQuarantineActive,
              let callUUID = UUID(uuidString: callId),
              !waitingCallMergeUUIDs.contains(callUUID),
              let incoming = authenticatedUnansweredIncomingCall(
                  callUUID,
                  requiresUnexpiredRing: false
              ),
              let backendCallID = backendCallIds[callUUID],
              backendCallID.caseInsensitiveCompare(incoming.record.id) == .orderedSame
        else { return }
        callController.request(CXTransaction(action: CXEndCallAction(call: callUUID))) { error in
            guard error != nil else { return }
            Task { @MainActor in
                let coordinator = NotificationCoordinator.shared
                guard coordinator.backendCallIds[callUUID]?
                        .caseInsensitiveCompare(backendCallID) == .orderedSame,
                      coordinator.incomingCalls[callUUID] != nil,
                      !coordinator.answeredCalls.contains(callUUID)
                else { return }
                coordinator.clearCall(callUUID)
                coordinator.callProvider.reportCall(
                    with: callUUID,
                    endedAt: Date(),
                    reason: .declinedElsewhere
                )
                coordinator.recordAndPublishCallEvent(
                    .systemAction(CallSystemAction(
                        callId: backendCallID,
                        callUUID: callUUID,
                        kind: .decline
                    ))
                )
            }
        }
    }

    /// Retires the separate waiting CallKit record after its caller was invited into the current
    /// room. Backend decline/retry ownership stays with AppModel and no second lifecycle action is
    /// emitted here.
    @MainActor
    func reportWaitingCallMerged(callId: String) {
        guard let callUUID = UUID(uuidString: callId),
              backendCallIds[callUUID]?.caseInsensitiveCompare(callId) == .orderedSame
        else { return }
        clearCall(callUUID)
        callProvider.reportCall(with: callUUID, endedAt: Date(), reason: .declinedElsewhere)
    }

    @MainActor
    /// Returns whether a CallKit mute transaction was submitted. When CallKit cannot take the
    /// request (registration suspended, quarantine, unknown call), the caller applies the mute
    /// directly to media so the button always works; the same direct path repairs a transaction
    /// that CallKit accepts and then fails.
    @discardableResult
    func requestMuted(_ muted: Bool, callId: String) -> Bool {
        guard registrationEnabled, !privacyQuarantineActive,
              let callUUID = UUID(uuidString: callId),
              backendCallIds[callUUID]?.caseInsensitiveCompare(callId) == .orderedSame
        else { return false }
        let action = CXSetMutedCallAction(call: callUUID, muted: muted)
        callController.request(CXTransaction(action: action)) { error in
            guard let error else { return }
            Task { @MainActor in
                try? await CallMediaCoordinator.shared.applyCallKitMute(muted, callId: callId)
                CallMediaCoordinator.shared.recordControlError(error)
            }
        }
        return true
    }

    /// Promotes or demotes the CallKit record when the user turns their camera on or off during a
    /// call. Without this the Lock Screen, Dynamic Island, and Recents keep the state the call was
    /// created with, so an escalated audio call still looks like a voice call to the system.
    @MainActor
    func reportCallVideoChanged(callId: String, hasVideo: Bool) {
        guard registrationEnabled,
              !privacyQuarantineActive,
              let callUUID = UUID(uuidString: callId),
              backendCallIds[callUUID]?.caseInsensitiveCompare(callId) == .orderedSame,
              videoCalls[callUUID] != hasVideo
        else { return }
        videoCalls[callUUID] = hasVideo
        // `privacyQuarantineActive` is already excluded above, so the retained identity is the
        // revealed one here and republishing it cannot leak a concealed caller name.
        let visibleName = callDisplayNames[callUUID] ?? "Kit Pay contact"
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: visibleName)
        update.hasVideo = hasVideo
        update.localizedCallerName = visibleName
        configureCallCapabilities(update)
        callProvider.reportCall(with: callUUID, updated: update)
    }

    @MainActor
    func reportMediaConnectionFailed(callId: String) {
        guard let callUUID = UUID(uuidString: callId) else { return }
        clearCall(callUUID)
        callProvider.reportCall(with: callUUID, endedAt: Date(), reason: .failed)
    }

    @MainActor
    func reportRemoteCallEnded(callId: String) {
        guard let callUUID = UUID(uuidString: callId) else { return }
        clearCall(callUUID)
        callProvider.reportCall(with: callUUID, endedAt: Date(), reason: .remoteEnded)
    }

    @MainActor
    func reportOutgoingCallConnected(callId: String, connectedAt: Date) {
        guard registrationEnabled,
              !privacyQuarantineActive,
              let callUUID = UUID(uuidString: callId),
              backendCallIds[callUUID]?.caseInsensitiveCompare(callId) == .orderedSame,
              outgoingCalls.contains(callUUID),
              connectedOutgoingCalls.insert(callUUID).inserted
        else { return }
        callSounds.remoteParticipantConnected(callID: callId)
        callProvider.reportOutgoingCall(with: callUUID, connectedAt: connectedAt)
    }

    /// Another device on this account took the call, so this device stops offering it: the
    /// CallKit call — revealed or still quarantined — ends as answered-elsewhere rather than
    /// ringing on until the invite expires and recording a miss. The device that actually
    /// answered and a caller's outgoing leg are fenced out and left untouched.
    @MainActor
    func reportCallAnsweredElsewhere(callId: String) {
        guard let callUUID = UUID(uuidString: callId) else { return }
        let offersQuarantinedRing = quarantinedIncomingCalls[callUUID] != nil
        let offersRevealedRing =
            backendCallIds[callUUID]?.caseInsensitiveCompare(callId) == .orderedSame
                && !answeredCalls.contains(callUUID)
                && !outgoingCalls.contains(callUUID)
        guard offersQuarantinedRing || offersRevealedRing else { return }
        clearCall(callUUID)
        callProvider.reportCall(with: callUUID, endedAt: Date(), reason: .answeredElsewhere)
    }

    @MainActor
    private func clearCall(_ callUUID: UUID) {
        let callID = backendCallIds[callUUID] ?? callUUID.uuidString.lowercased()
        callSounds.callEnded(callID: callID)
        failDeferredPrimaryAnswer(for: callUUID)
        explicitlyRequestedEndCallUUIDs.remove(callUUID)
        let authenticatedDependents = callKitAnswerMergeOwners.compactMap {
            waitingCallUUID, activeCallUUID in
            activeCallUUID == callUUID ? waitingCallUUID : nil
        }
        for waitingCallUUID in authenticatedDependents {
            callKitAnswerMergeOwners.removeValue(forKey: waitingCallUUID)
            if waitingCallMergeUUIDs.remove(waitingCallUUID) != nil,
               let incoming = authenticatedUnansweredIncomingCall(
                   waitingCallUUID,
                   requiresUnexpiredRing: false
               ) {
                scheduleRingExpiry(for: incoming)
            }
        }
        let pendingDependents = pendingAuthenticatedMergeIntents.compactMap {
            waitingCallUUID, activeCallUUID in
            activeCallUUID == callUUID ? waitingCallUUID : nil
        }
        for waitingCallUUID in pendingDependents {
            pendingAuthenticatedMergeIntents.removeValue(forKey: waitingCallUUID)
        }
        waitingCallMergeUUIDs.remove(callUUID)
        callKitAnswerMergeOwners.removeValue(forKey: callUUID)
        pendingAuthenticatedMergeIntents.removeValue(forKey: callUUID)
        ringExpiryTasks.removeValue(forKey: callUUID)?.cancel()
        quarantineExpiryTasks.removeValue(forKey: callUUID)?.cancel()
        verificationRetryTasks.removeValue(forKey: callUUID)?.cancel()
        if let verificationEventID = quarantinedIncomingCalls
            .removeValue(forKey: callUUID)?.verificationEventID {
            pendingCallEvents.acknowledge(verificationEventID)
        }
        backendCallIds.removeValue(forKey: callUUID)
        incomingCalls.removeValue(forKey: callUUID)
        answeredCalls.remove(callUUID)
        outgoingCalls.remove(callUUID)
        connectedOutgoingCalls.remove(callUUID)
        pendingOutgoingMedia.removeValue(forKey: callUUID)
        videoCalls.removeValue(forKey: callUUID)
        callDisplayNames.removeValue(forKey: callUUID)
        callAdmissionGenerations.removeValue(forKey: callUUID)
    }

    @MainActor
    private func quarantine(_ incoming: IncomingCallPush) {
        let callUUID = incoming.callUUID
        explicitlyRequestedEndCallUUIDs.remove(callUUID)
        waitingCallMergeUUIDs.remove(callUUID)
        callKitAnswerMergeOwners.removeValue(forKey: callUUID)
        let receivedAt = Date()
        let expiry = IncomingCallQuarantinePolicy.expiry(
            pushExpiry: incoming.ringExpiryDate,
            receivedAt: receivedAt
        )
        if let staleEventID = quarantinedIncomingCalls[callUUID]?.verificationEventID {
            pendingCallEvents.acknowledge(staleEventID)
        }
        verificationRetryTasks.removeValue(forKey: callUUID)?.cancel()
        quarantinedIncomingCalls[callUUID] = QuarantinedIncomingCall(
            push: incoming,
            expiresAt: expiry,
            verificationEventID: nil,
            verificationFailureCount: 0,
            verificationRetryNotBefore: nil
        )
        callAdmissionGenerations[callUUID] = callRegistryGeneration
        quarantineExpiryTasks.removeValue(forKey: callUUID)?.cancel()
        let seconds = max(0, expiry.timeIntervalSinceNow)
        quarantineExpiryTasks[callUUID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(seconds))
            } catch {
                return
            }
            guard let self, self.quarantinedIncomingCalls[callUUID] != nil else { return }
            self.clearCall(callUUID)
            self.callProvider.reportCall(
                with: callUUID,
                endedAt: Date(),
                reason: .unanswered
            )
        }
    }

    @MainActor
    private func requestVerificationForQuarantinedIncomingCalls() {
        guard registrationEnabled, !privacyQuarantineActive else { return }
        for callUUID in Array(quarantinedIncomingCalls.keys) {
            guard var pending = quarantinedIncomingCalls[callUUID] else { continue }
            let incoming = pending.push
            let now = Date()
            guard pending.expiresAt > now else {
                clearCall(callUUID)
                callProvider.reportCall(
                    with: callUUID,
                    endedAt: Date(),
                    reason: .unanswered
                )
                continue
            }
            guard pending.verificationEventID == nil else { continue }
            if let retryNotBefore = pending.verificationRetryNotBefore {
                guard retryNotBefore < pending.expiresAt else { continue }
                if retryNotBefore > now {
                    scheduleIncomingCallVerificationRetry(
                        callUUID: callUUID,
                        after: retryNotBefore.timeIntervalSince(now),
                        admissionGeneration: callRegistryGeneration
                    )
                    continue
                }
                pending.verificationRetryNotBefore = nil
            }
            verificationRetryTasks.removeValue(forKey: callUUID)?.cancel()
            let request = IncomingCallVerificationRequest(
                push: incoming,
                admissionGeneration: callRegistryGeneration
            )
            pending.verificationEventID = request.eventId
            quarantinedIncomingCalls[callUUID] = pending
            callAdmissionGenerations[callUUID] = callRegistryGeneration
            recordAndPublishCallEvent(.verificationRequested(request))
        }
    }

    @MainActor
    func isAwaitingIncomingCallVerification(
        _ request: IncomingCallVerificationRequest
    ) -> Bool {
        guard registrationEnabled, !privacyQuarantineActive,
              let pending = quarantinedIncomingCalls[request.push.callUUID]
        else { return false }
        return IncomingCallVerificationAdmissionPolicy.permits(
            request,
            callUUID: request.push.callUUID,
            pendingEventID: pending.verificationEventID,
            admissionGeneration: callAdmissionGenerations[request.push.callUUID],
            currentGeneration: callRegistryGeneration
        )
    }

    @MainActor
    @discardableResult
    func promoteAuthenticatedIncomingCall(
        _ incoming: AuthenticatedIncomingCall,
        for request: IncomingCallVerificationRequest
    ) -> Bool {
        guard isAwaitingIncomingCallVerification(request),
              incoming.callUUID == request.push.callUUID,
              incoming.record.id == request.push.callId,
              incoming.ringExpiryDate > Date()
        else { return false }
        let deferredAnswer: CXAnswerCallAction?
        if deferredPrimaryAnswerActions[incoming.callUUID] != nil,
           deferredPrimaryAnswerGate.consumeAuthenticated(
               callUUID: incoming.callUUID,
               admissionGeneration: callAdmissionGenerations[incoming.callUUID],
               currentGeneration: callRegistryGeneration
           ) {
            deferredAnswer = deferredPrimaryAnswerActions.removeValue(
                forKey: incoming.callUUID
            )
        } else {
            deferredAnswer = nil
            failDeferredPrimaryAnswer(for: incoming.callUUID)
        }
        quarantineExpiryTasks.removeValue(forKey: incoming.callUUID)?.cancel()
        quarantinedIncomingCalls.removeValue(forKey: incoming.callUUID)
        callProvider.reportCall(
            with: incoming.callUUID,
            updated: callUpdate(for: incoming)
        )
        admit(incoming)
        if let deferredAnswer {
            performAnswerCallAction(deferredAnswer)
        }
        return true
    }

    @MainActor
    func rejectIncomingCallVerification(
        _ request: IncomingCallVerificationRequest
    ) {
        guard isAwaitingIncomingCallVerification(request) else { return }
        clearCall(request.push.callUUID)
        callProvider.reportCall(
            with: request.push.callUUID,
            endedAt: Date(),
            reason: .failed
        )
    }

    /// A transport/server outage does not prove that the call belongs to another account. Keep the
    /// CallKit surface generic and retry with bounded backoff, never before Retry-After or at/after
    /// the locally bounded ring expiry.
    @MainActor
    func retryIncomingCallVerificationAfterTransientFailure(
        _ request: IncomingCallVerificationRequest,
        retryAfter: TimeInterval? = nil
    ) {
        guard isAwaitingIncomingCallVerification(request),
              var pending = quarantinedIncomingCalls[request.push.callUUID]
        else { return }
        pendingCallEvents.acknowledge(request.eventId)
        pending.verificationEventID = nil
        pending.verificationFailureCount = min(pending.verificationFailureCount, 1_000) + 1

        let now = Date()
        let remaining = pending.expiresAt.timeIntervalSince(now)
        guard remaining > 0 else {
            quarantinedIncomingCalls[request.push.callUUID] = pending
            clearCall(request.push.callUUID)
            callProvider.reportCall(
                with: request.push.callUUID,
                endedAt: Date(),
                reason: .unanswered
            )
            return
        }
        verificationRetryTasks.removeValue(forKey: request.push.callUUID)?.cancel()
        guard let retryDelay = IncomingCallLookupRetryPolicy.delay(
            failureCount: pending.verificationFailureCount,
            retryAfter: retryAfter,
            remainingLifetime: remaining
        ) else {
            // The existing quarantine-expiry task will retire the generic CallKit surface. Do not
            // violate Retry-After merely to squeeze in one final request before that deadline.
            pending.verificationRetryNotBefore = pending.expiresAt
            quarantinedIncomingCalls[request.push.callUUID] = pending
            return
        }
        pending.verificationRetryNotBefore = now.addingTimeInterval(retryDelay)
        quarantinedIncomingCalls[request.push.callUUID] = pending
        scheduleIncomingCallVerificationRetry(
            callUUID: request.push.callUUID,
            after: retryDelay,
            admissionGeneration: request.admissionGeneration
        )
    }

    @MainActor
    private func scheduleIncomingCallVerificationRetry(
        callUUID: UUID,
        after delay: TimeInterval,
        admissionGeneration: UInt64
    ) {
        verificationRetryTasks.removeValue(forKey: callUUID)?.cancel()
        verificationRetryTasks[callUUID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self,
                  self.registrationEnabled,
                  !self.privacyQuarantineActive,
                  self.callRegistryGeneration == admissionGeneration,
                  self.callAdmissionGenerations[callUUID] == admissionGeneration,
                  self.quarantinedIncomingCalls[callUUID]?.verificationEventID == nil
            else { return }
            self.verificationRetryTasks.removeValue(forKey: callUUID)
            self.requestVerificationForQuarantinedIncomingCalls()
        }
    }

    @MainActor
    func discardQuarantinedIncomingCalls() {
        let callUUIDs = Array(quarantinedIncomingCalls.keys)
        for callUUID in callUUIDs {
            clearCall(callUUID)
            callProvider.reportCall(with: callUUID, endedAt: Date(), reason: .failed)
        }
    }

    @MainActor
    private func admit(_ incoming: AuthenticatedIncomingCall) {
        let uuid = incoming.callUUID
        guard incoming.ringExpiryDate > Date() else {
            callProvider.reportCall(with: uuid, endedAt: Date(), reason: .unanswered)
            return
        }
        backendCallIds[uuid] = incoming.record.id
        callAdmissionGenerations[uuid] = callRegistryGeneration
        incomingCalls[uuid] = incoming
        videoCalls[uuid] = incoming.record.video
        callDisplayNames[uuid] = incoming.record.name
        scheduleRingExpiry(for: incoming)
        recordAndPublishCallEvent(.incoming(IncomingCallNotice(call: incoming)))
        if let expectedActiveCallUUID = pendingAuthenticatedMergeIntents.removeValue(
            forKey: uuid
        ), connectedActiveMediaCallUUID() == expectedActiveCallUUID {
            // Preserve cache order: the authenticated notice must authorize the caller before the
            // Answer intent can be translated into the invite-current-plus-decline action. Never
            // retarget that intent to a room that became active while verification was suspended.
            markAndPublishCallKitAnswerMergeIfNeeded(
                callUUID: uuid,
                expectedActiveCallUUID: expectedActiveCallUUID
            )
        }
    }

    private func genericIncomingCallUpdate() -> CXCallUpdate {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: "Kit Pay call")
        update.hasVideo = false
        update.localizedCallerName = "Kit Pay call"
        configureCallCapabilities(update)
        return update
    }

    private func callUpdate(for incoming: AuthenticatedIncomingCall) -> CXCallUpdate {
        let visibleName = incoming.record.name
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: visibleName)
        update.hasVideo = incoming.record.video
        update.localizedCallerName = visibleName
        configureCallCapabilities(update)
        return update
    }

    private func configureCallCapabilities(_ update: CXCallUpdate) {
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
    }

    @MainActor
    private func concealRetainedCallIdentity() {
        for callUUID in backendCallIds.keys {
            let update = CXCallUpdate()
            update.remoteHandle = CXHandle(type: .generic, value: "Kit Pay call")
            update.hasVideo = false
            update.localizedCallerName = "Kit Pay call"
            configureCallCapabilities(update)
            callProvider.reportCall(with: callUUID, updated: update)
        }
    }

    @MainActor
    private func revealRetainedCallIdentity() {
        for callUUID in backendCallIds.keys {
            let visibleName = callDisplayNames[callUUID] ?? "Kit Pay contact"
            let update = CXCallUpdate()
            update.remoteHandle = CXHandle(type: .generic, value: visibleName)
            update.hasVideo = videoCalls[callUUID] == true
            update.localizedCallerName = visibleName
            configureCallCapabilities(update)
            callProvider.reportCall(with: callUUID, updated: update)
        }
    }

    @MainActor
    private func scheduleRingExpiry(for incoming: AuthenticatedIncomingCall) {
        let expiry = incoming.ringExpiryDate
        let callUUID = incoming.callUUID
        let callID = incoming.record.id
        ringExpiryTasks.removeValue(forKey: callUUID)?.cancel()
        let seconds = max(0, expiry.timeIntervalSinceNow)
        let maximumSeconds = Double(UInt64.max / 1_000_000_000)
        let nanoseconds = UInt64(min(seconds, maximumSeconds) * 1_000_000_000)
        ringExpiryTasks[callUUID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard let self,
                  self.backendCallIds[callUUID]?.caseInsensitiveCompare(callID) == .orderedSame,
                  !self.answeredCalls.contains(callUUID)
            else { return }
            if self.waitingCallMergeUUIDs.contains(callUUID) {
                // The merge owns this exact waiting call. `finishWaitingCallMergeAttempt` restores
                // the same absolute deadline if the invitation does not retire the CallKit record.
                self.ringExpiryTasks.removeValue(forKey: callUUID)
                return
            }
            self.clearCall(callUUID)
            self.callProvider.reportCall(with: callUUID, endedAt: Date(), reason: .unanswered)
            self.recordAndPublishCallEvent(
                .systemAction(CallSystemAction(
                    callId: callID,
                    callUUID: callUUID,
                    kind: .timedOut
                ))
            )
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        guard registrationEnabled, !privacyQuarantineActive else {
            completionHandler([])
            return
        }
        completionHandler([.banner, .badge, .sound, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let content = response.notification.request.content
        guard registrationEnabled, !privacyQuarantineActive else {
            completionHandler()
            return
        }
        let userText = (response as? UNTextInputNotificationResponse)?.userText
        if let action = MessageNotificationResponsePolicy.action(
            actionIdentifier: response.actionIdentifier,
            requestIdentifier: response.notification.request.identifier,
            categoryIdentifier: content.categoryIdentifier,
            threadIdentifier: content.threadIdentifier,
            userInfo: content.userInfo,
            userText: userText
        ) {
            Task {
                await MessageNotificationActionDispatcher.shared.dispatch(action)
                completionHandler()
            }
            return
        }
        if let action = ClaimablePaymentNotificationResponsePolicy.action(
            actionIdentifier: response.actionIdentifier,
            categoryIdentifier: content.categoryIdentifier,
            threadIdentifier: content.threadIdentifier,
            userInfo: content.userInfo
        ) {
            Task {
                await ClaimablePaymentNotificationActionDispatcher.shared.dispatch(action)
                completionHandler()
            }
            return
        }
        NotificationCenter.default.post(
            name: .kitRemoteWakeReceived,
            object: content.userInfo
        )
        completionHandler()
    }

    @MainActor
    func clearMessageNotifications(
        accountFingerprint: String? = nil,
        conversationID: String? = nil
    ) async {
        if let accountFingerprint,
           !MessageNotificationContract.isIdentifierDigest(accountFingerprint) {
            return
        }
        let canonicalConversationID = conversationID.flatMap {
            MessageNotificationContract.canonicalUUID($0)
        }
        if conversationID != nil, canonicalConversationID == nil { return }

        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let pendingIdentifiers = pending.compactMap { request -> String? in
            shouldClearMessageNotification(
                requestIdentifier: request.identifier,
                content: request.content,
                accountFingerprint: accountFingerprint,
                conversationID: canonicalConversationID
            ) ? request.identifier : nil
        }
        if !pendingIdentifiers.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: pendingIdentifiers)
        }

        let delivered = await center.deliveredNotifications()
        let deliveredIdentifiers = delivered.compactMap { notification -> String? in
            let request = notification.request
            return shouldClearMessageNotification(
                requestIdentifier: request.identifier,
                content: request.content,
                accountFingerprint: accountFingerprint,
                conversationID: canonicalConversationID
            ) ? request.identifier : nil
        }
        if !deliveredIdentifiers.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: deliveredIdentifiers)
        }
    }

    private func shouldClearMessageNotification(
        requestIdentifier: String,
        content: UNNotificationContent,
        accountFingerprint: String?,
        conversationID: String?
    ) -> Bool {
        guard content.categoryIdentifier == MessageNotificationContract.categoryIdentifier else {
            return false
        }
        guard let metadata = MessageNotificationMetadataPolicy.metadata(
            requestIdentifier: requestIdentifier,
            threadIdentifier: content.threadIdentifier,
            userInfo: content.userInfo
        ) else {
            // A malformed Kit Pay message notification has no safe owner and must not remain
            // visible while account ownership is being reconciled.
            return true
        }
        if let accountFingerprint,
           metadata.accountFingerprint != accountFingerprint {
            return false
        }
        if let conversationID,
           metadata.conversationID != conversationID {
            return false
        }
        return true
    }

    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        recordAndPublishPushToken(
            PushTokenRegistration(provider: "apns_voip", token: token)
        )
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        pushTokens.remove(provider: "apns_voip")
        guard registrationEnabled,
              !privacyQuarantineActive,
              !suppressPushTokenInvalidation
        else { return }
        NotificationCenter.default.post(name: .kitPushTokenInvalidated, object: "apns_voip")
    }

    func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        guard type == .voIP else { completion(); return }
        let values = RemoteWakePayload(values: payload.dictionaryPayload)
        guard let incoming = IncomingCallPush(payload: values.values) else {
            // iOS 13+ requires every VoIP push to report an incoming call. Failing to do so
            // triggers the watchdog: the process is terminated and further VoIP pushes may be
            // withheld. Use generic metadata so malformed or wrong-account payloads disclose no
            // identity before protected-state ownership recovery.
            let placeholderUUID = UUID()
            callProvider.reportNewIncomingCall(
                with: placeholderUUID,
                update: genericIncomingCallUpdate()
            ) { error in
                Task { @MainActor in
                    if error == nil {
                        NotificationCoordinator.shared.callProvider.reportCall(
                            with: placeholderUUID,
                            endedAt: Date(),
                            reason: .failed
                        )
                    }
                    completion()
                }
            }
            return
        }
        let uuid = incoming.callUUID
        let receivedGeneration = callRegistryGeneration
        // PushKit identifies only an app-level token, not the currently recovered account. Report
        // promptly with generic metadata, then reveal/admit only after an authenticated lookup.
        let update = genericIncomingCallUpdate()
        callProvider.reportNewIncomingCall(with: uuid, update: update) { error in
            Task { @MainActor in
                let coordinator = NotificationCoordinator.shared
                if error == nil, coordinator.callRegistryGeneration == receivedGeneration {
                    // The phone is now ringing. Resolving the media host during the ring removes
                    // that handshake from the gap between answering and hearing the caller.
                    CallMediaPrewarmer.shared.prewarm()
                    coordinator.quarantine(incoming)
                    if coordinator.registrationEnabled, !coordinator.privacyQuarantineActive {
                        coordinator.requestVerificationForQuarantinedIncomingCalls()
                    }
                } else if error == nil {
                    coordinator.callProvider.reportCall(
                        with: uuid,
                        endedAt: Date(),
                        reason: .failed
                    )
                }
                NotificationCenter.default.post(
                    name: .kitRemoteWakeReceived,
                    object: values.values
                )
                completion()
            }
        }
    }
}

extension NotificationCoordinator: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        callRegistryGeneration &+= 1
        invalidateCallActionOwnership()
        invalidateCallKitAudio(resetSounds: true)
        let calls = backendCallIds
        if registrationEnabled, !privacyQuarantineActive {
            for (callUUID, callId) in calls {
                let kind: CallSystemActionKind = answeredCalls.contains(callUUID)
                    || outgoingCalls.contains(callUUID) ? .end : .decline
                recordAndPublishCallEvent(
                    .systemAction(CallSystemAction(
                        callId: callId,
                        callUUID: callUUID,
                        kind: kind
                    ))
                )
            }
        }
        ringExpiryTasks.values.forEach { $0.cancel() }
        ringExpiryTasks.removeAll()
        quarantineExpiryTasks.values.forEach { $0.cancel() }
        quarantineExpiryTasks.removeAll()
        verificationRetryTasks.values.forEach { $0.cancel() }
        verificationRetryTasks.removeAll()
        for pending in quarantinedIncomingCalls.values {
            if let verificationEventID = pending.verificationEventID {
                pendingCallEvents.acknowledge(verificationEventID)
            }
        }
        quarantinedIncomingCalls.removeAll()
        backendCallIds.removeAll()
        incomingCalls.removeAll()
        answeredCalls.removeAll()
        outgoingCalls.removeAll()
        connectedOutgoingCalls.removeAll()
        pendingOutgoingMedia.removeAll()
        videoCalls.removeAll()
        callDisplayNames.removeAll()
        callAdmissionGenerations.removeAll()
        Task { @MainActor in
            for callId in calls.values {
                await CallMediaCoordinator.shared.disconnectFromCallKit(callId: callId)
            }
        }
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        guard registrationEnabled, !privacyQuarantineActive else {
            action.fail()
            return
        }
        guard callAdmissionGenerations[action.callUUID] == callRegistryGeneration else {
            action.fail()
            return
        }
        guard let request = pendingOutgoingMedia[action.callUUID] else {
            action.fail()
            Task { @MainActor [weak self] in self?.clearCall(action.callUUID) }
            return
        }
        let handoff = request.handoff
        pendingOutgoingMedia.removeValue(forKey: action.callUUID)
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: handoff.participantName)
        update.hasVideo = handoff.video
        update.localizedCallerName = handoff.participantName
        configureCallCapabilities(update)
        provider.reportCall(with: action.callUUID, updated: update)
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
        // The authenticated handoff exists only after the server accepted POST /calls. Keeping
        // this after CallKit admission ensures offline queued attempts can never ring locally.
        callSounds.beginServerAcceptedOutgoingRinging(
            callID: handoff.callId
        )
        action.fulfill()
        Task { @MainActor [weak self] in
            guard self?.backendCallIds[action.callUUID] != nil else { return }
            do {
                try await CallMediaCoordinator.shared.connectAuthenticated(request)
                guard self?.backendCallIds[action.callUUID] != nil else {
                    await CallMediaCoordinator.shared.disconnectFromCallKit(
                        callId: handoff.callId
                    )
                    return
                }
                if let connectedAt = CallMediaCoordinator.shared.media.remoteParticipantConnectedAt {
                    self?.reportOutgoingCallConnected(
                        callId: handoff.callId,
                        connectedAt: connectedAt
                    )
                }
            } catch is CancellationError {
                // A racing end/replacement action superseded this connect and owns the
                // CallKit ended report; a duplicate `.failed` here would end the wrong call.
            } catch {
                // The action was already fulfilled; without an explicit ended report the system
                // call would stay live with no backing media. A user-initiated end already
                // cleared this call from tracking, so only report media failures.
                if self?.backendCallIds[action.callUUID] != nil {
                    provider.reportCall(with: action.callUUID, endedAt: Date(), reason: .failed)
                }
                self?.clearCall(action.callUUID)
            }
        }
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor [weak self] in
            guard let self else {
                action.fail()
                return
            }
            self.performAnswerCallAction(action)
        }
    }

    @MainActor
    private func performAnswerCallAction(_ action: CXAnswerCallAction) {
        if quarantinedIncomingCalls[action.callUUID] != nil,
           callAdmissionGenerations[action.callUUID] == callRegistryGeneration,
           connectedActiveMediaCallUUID() == nil {
            guard deferredPrimaryAnswerGate.retain(
                callUUID: action.callUUID,
                admissionGeneration: callAdmissionGenerations[action.callUUID],
                currentGeneration: callRegistryGeneration
            ) else {
                action.fail()
                return
            }
            deferredPrimaryAnswerActions[action.callUUID] = action
            return
        }
        guard registrationEnabled, !privacyQuarantineActive else {
            action.fail()
            return
        }
        guard callAdmissionGenerations[action.callUUID] == callRegistryGeneration else {
            action.fail()
            return
        }
        if quarantinedIncomingCalls[action.callUUID] != nil,
           let activeCallUUID = connectedActiveMediaCallUUID(),
           activeCallUUID != action.callUUID {
            if let existingOwner = pendingAuthenticatedMergeIntents[action.callUUID],
               existingOwner != activeCallUUID {
                action.fail()
                return
            }
            pendingAuthenticatedMergeIntents[action.callUUID] = activeCallUUID
            action.fail()
            return
        }
        guard let callId = backendCallIds[action.callUUID],
              let incoming = incomingCalls[action.callUUID]
        else {
            action.fail()
            return
        }

        let mediaCoordinator = CallMediaCoordinator.shared
        let mediaState: CallWaitingMediaState
        switch mediaCoordinator.state {
        case .idle: mediaState = .idle
        case .preparing: mediaState = .preparing
        case .connecting: mediaState = .connecting
        case .reconnecting: mediaState = .reconnecting
        case .connected: mediaState = .connected
        case .ending: mediaState = .ending
        }
        switch CallKitAnswerActionPolicy.disposition(
            actionCallID: callId,
            authenticatedIncomingCallID: incoming.record.id,
            activeCallID: mediaCoordinator.activeCall?.id,
            mediaState: mediaState
        ) {
        case .reject:
            action.fail()
            return

        case .mergeWaiting:
            // Fulfilling would tell CallKit that a second media call was answered. Fail that system
            // operation honestly, retain its ringing record, and let AppModel perform the audited
            // invite-current-plus-decline-waiting transaction before retiring the record.
            action.fail()
            if let activeCallUUID = connectedActiveMediaCallUUID() {
                markAndPublishCallKitAnswerMergeIfNeeded(
                    callUUID: action.callUUID,
                    expectedActiveCallUUID: activeCallUUID
                )
            }
            return

        case .answerPrimary:
            break
        }

        ringExpiryTasks.removeValue(forKey: action.callUUID)?.cancel()
        answeredCalls.insert(action.callUUID)
        callSounds.incomingCallAnswered(callID: callId)
        action.fulfill()
        recordAndPublishCallEvent(
            .systemAction(CallSystemAction(
                callId: callId,
                callUUID: action.callUUID,
                kind: .answer,
                presentation: ActiveCallPresentation(
                    id: callId,
                    participantName: incoming.record.name,
                    video: incoming.record.video,
                    direction: "incoming"
                )
            ))
        )
    }

    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        Task { @MainActor [weak self] in
            if let answer = action as? CXAnswerCallAction,
               let retained = self?.deferredPrimaryAnswerActions[answer.callUUID],
               retained === answer {
                self?.deferredPrimaryAnswerGate.remove(callUUID: answer.callUUID)
                self?.deferredPrimaryAnswerActions.removeValue(forKey: answer.callUUID)
            }
            action.fail()
        }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor [weak self] in
            guard let self else {
                action.fail()
                return
            }
            self.performEndCallAction(action)
        }
    }

    @MainActor
    private func performEndCallAction(_ action: CXEndCallAction) {
        if quarantinedIncomingCalls[action.callUUID] != nil {
            clearCall(action.callUUID)
            action.fulfill()
            return
        }
        guard registrationEnabled, !privacyQuarantineActive else {
            action.fail()
            return
        }
        guard callAdmissionGenerations[action.callUUID] == callRegistryGeneration else {
            action.fail()
            return
        }

        // A marked waiting call is already crossing the non-idempotent invite boundary. Neither a
        // system Decline nor the second half of End & Accept may race that request.
        if waitingCallMergeUUIDs.contains(action.callUUID) {
            explicitlyRequestedEndCallUUIDs.remove(action.callUUID)
            action.fail()
            return
        }

        let wasExplicitlyRequested = explicitlyRequestedEndCallUUIDs.remove(action.callUUID) != nil
        if CallKitActiveEndActionPolicy.preservesActiveCall(
            actionCallUUID: action.callUUID,
            connectedActiveCallUUID: connectedActiveMediaCallUUID(),
            wasExplicitlyRequestedInApp: wasExplicitlyRequested,
            priorAnswerActiveCallUUIDs: currentPriorAnswerActiveCallUUIDs()
        ) {
            // CallKit may deliver Answer before the destructive End half of End & Accept. Only that
            // earlier, exact Answer intent may preserve this active room. A plain End continues as
            // an ordinary hang-up and can never create or publish merge authority.
            action.fail()
            return
        }

        let callId = backendCallIds[action.callUUID]
            ?? action.callUUID.uuidString.lowercased()
        let kind: CallSystemActionKind = outgoingCalls.contains(action.callUUID)
            || answeredCalls.contains(action.callUUID) ? .end : .decline
        clearCall(action.callUUID)
        action.fulfill()
        Task { @MainActor in
            self.recordAndPublishCallEvent(
                .systemAction(CallSystemAction(
                    callId: callId,
                    callUUID: action.callUUID,
                    kind: kind
                ))
            )
            await CallMediaCoordinator.shared.disconnectFromCallKit(callId: callId)
        }
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        guard registrationEnabled, !privacyQuarantineActive else {
            action.fail()
            return
        }
        guard callAdmissionGenerations[action.callUUID] == callRegistryGeneration else {
            action.fail()
            return
        }
        guard let callId = backendCallIds[action.callUUID] else {
            action.fail()
            return
        }
        Task { @MainActor in
            do {
                // Before the room connects (ringing, app-level reconnect) the room is nil.
                // System-UI/lock-screen mute must still stick: `applyCallKitMute` buffers the
                // intent — it is re-applied on (re)connect — instead of bouncing the toggle.
                try await CallMediaCoordinator.shared.applyCallKitMute(
                    action.isMuted,
                    callId: callId
                )
                action.fulfill()
            } catch {
                action.fail()
            }
        }
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        guard registrationEnabled, !privacyQuarantineActive else {
            invalidateCallKitAudio(resetSounds: false)
            return
        }
        callKitAudioTransitionGeneration &+= 1
        let transitionGeneration = callKitAudioTransitionGeneration
        let registryGeneration = callRegistryGeneration
        callKitAudioExpectedActive = true
        guard let expectedCallUUID = currentCallKitAudioOwnerUUID() else {
            callKitAudioExpectedActive = false
            callSounds.callKitAudioDidDeactivate()
            return
        }
        Task { @MainActor [weak self] in
            guard let self,
                  self.callKitAudioTransitionGeneration == transitionGeneration,
                  self.callKitAudioExpectedActive,
                  self.callRegistryGeneration == registryGeneration,
                  self.hasCurrentCallRegistryOwnership(expectedCallUUID),
                  self.answeredCalls.contains(expectedCallUUID)
                    || self.outgoingCalls.contains(expectedCallUUID)
            else { return }
            do {
                try CallMediaCoordinator.shared.activateAudioSession(
                    audioSession,
                    video: self.videoCalls[expectedCallUUID]
                )
                guard self.callKitAudioTransitionGeneration == transitionGeneration,
                      self.callKitAudioExpectedActive,
                      self.callRegistryGeneration == registryGeneration,
                      self.hasCurrentCallRegistryOwnership(expectedCallUUID)
                else { return }
                self.callSounds.callKitAudioDidActivate()
            } catch {
                guard self.callKitAudioTransitionGeneration == transitionGeneration else { return }
                self.callKitAudioExpectedActive = false
                self.callSounds.callKitAudioDidDeactivate()
                CallMediaCoordinator.shared.recordControlError(error)
            }
        }
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        callKitAudioTransitionGeneration &+= 1
        let transitionGeneration = callKitAudioTransitionGeneration
        callKitAudioExpectedActive = false
        callSounds.callKitAudioDidDeactivate()
        Task { @MainActor [weak self] in
            guard let self,
                  self.callKitAudioTransitionGeneration == transitionGeneration,
                  !self.callKitAudioExpectedActive
            else { return }
            do {
                try CallMediaCoordinator.shared.deactivateAudioSession()
            } catch {
                guard self.callKitAudioTransitionGeneration == transitionGeneration else { return }
                CallMediaCoordinator.shared.recordControlError(error)
            }
        }
    }
}

enum CallInterfaceOrientationPolicy {
    static func mask(isActiveCallPresented: Bool) -> UIInterfaceOrientationMask {
        isActiveCallPresented ? .allButUpsideDown : .portrait
    }
}

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    private var isActiveCallPresented = false

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
#if DEBUG && APP_STORE_SCREENSHOTS
        guard !AppStoreScreenshotFixture.isActive else { return true }
#endif
        ContactBackgroundRefreshScheduler.shared.register()
        CommunicationBackgroundReplayScheduler.shared.register()
        MessageBackupRefreshScheduler.shared.register()
        NotificationCoordinator.shared.prepareForProtectedStateRestore()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        NotificationCoordinator.shared.recordAndPublishPushToken(
            PushTokenRegistration(provider: "apns", token: token)
        )
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Nothing is retried automatically by iOS. Record the failure so the next connectivity
        // recovery asks again instead of leaving the install permanently without a token.
        NotificationCoordinator.shared.recordRemoteRegistrationFailure()
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        CallInterfaceOrientationPolicy.mask(
            isActiveCallPresented: isActiveCallPresented
        )
    }

    func setActiveCallPresented(_ presented: Bool) {
        isActiveCallPresented = presented
        let mask = CallInterfaceOrientationPolicy.mask(
            isActiveCallPresented: presented
        )
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            guard scene.activationState == .foregroundActive
                    || scene.activationState == .foregroundInactive
            else { continue }
            for window in scene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
        }
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        if let wake = SecureMessagingRemoteWake(userInfo) {
            Task {
                completionHandler(
                    await SecureMessagingWakeDispatcher.shared.dispatch(wake)
                )
            }
            return
        }
        NotificationCenter.default.post(name: .kitRemoteWakeReceived, object: userInfo)
        completionHandler(.newData)
    }
}
