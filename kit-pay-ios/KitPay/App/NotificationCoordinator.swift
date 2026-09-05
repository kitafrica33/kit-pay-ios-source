import AVFoundation
import CallKit
import CryptoKit
import Foundation
import OSLog
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

/// An OS-rendered fallback for new encrypted content. No sender, conversation or message body
/// crosses APNs; authenticated sync supplies those only after the exact recipient is restored.
struct RemoteMessageAvailableNotification: Equatable, Sendable {
    static let type = "messaging.message_available"
    let notificationID: UUID
    let recipientUserID: String
    let messageID: String

    var accountFingerprint: String {
        MessageNotificationContract.accountFingerprint(for: recipientUserID)!
    }

    var messageDigest: String {
        MessageNotificationContract.messageDigest(for: messageID)!
    }

    var deduplicationKey: String { "\(accountFingerprint):\(messageDigest)" }

    init?(_ object: Any?) {
        guard let envelope = object as? [AnyHashable: Any], envelope.count <= 24 else { return nil }
        // Firebase adds transport/analytics metadata around the APNs payload. Strip only its
        // documented scalar metadata namespace; the application data contract stays exact.
        let payload = envelope.filter { key, value in
            guard let key = key as? String,
                  key == "gcm.message_id" || key == "google.c.sender.id"
                    || key == "google.c.fid" || key.hasPrefix("google.c.a."),
                  (value as? String).map({ $0.utf8.count <= 512 }) == true || value is NSNumber
            else { return true }
            return false
        }
        guard
              payload["type"] as? String == Self.type,
              payload["scope"] as? String == "messaging",
              let rawNotificationID = payload["notification_id"] as? String,
              let notificationID = UUID(uuidString: rawNotificationID),
              let recipient = MessageNotificationContract.canonicalUUID(
                  payload["recipient_user_id"] as? String
              ),
              let message = MessageNotificationContract.canonicalUUID(
                  payload["message_id"] as? String
              ),
              payload.count == 6,
              Set(payload.keys.compactMap { $0 as? String }) == Set([
                  "type", "scope", "notification_id", "message_id", "recipient_user_id", "aps",
              ]),
              let aps = payload["aps"] as? [AnyHashable: Any],
              (aps.count == 2 || aps.count == 3),
              (aps["content-available"] == nil
                  || (aps["content-available"] as? NSNumber)?.doubleValue == 1),
              Set(aps.keys.compactMap { $0 as? String }).isSubset(of: [
                  "alert", "sound", "content-available",
              ]),
              aps["sound"] as? String == "default",
              let alert = aps["alert"] as? [AnyHashable: Any],
              alert.count == 2,
              alert["title"] as? String == "Kit Pay",
              alert["body"] as? String == "You have a new message."
        else { return nil }
        self.notificationID = notificationID
        recipientUserID = recipient
        messageID = message
    }
}

struct RemoteMessageNotificationRecord: Equatable, Sendable {
    let requestIdentifier: String
    let notice: RemoteMessageAvailableNotification
}

struct NotificationInboxItems: Decodable, Sendable {
    let items: [NotificationInboxItem]
}

struct NotificationPreferenceSnapshot: Codable, Equatable, Sendable {
    static let maximumWireInteger = 9_007_199_254_740_991
    static let maximumExpectedRevision = maximumWireInteger - 1
    let enrollmentEpoch: Int
    let revision: Int
    let encryptedMessageAlerts: Bool
    let mutedConversationIDs: [String]
    enum CodingKeys: String, CodingKey {
        case enrollmentEpoch = "enrollment_epoch", revision
        case encryptedMessageAlerts = "encrypted_message_alerts"
        case mutedConversationIDs = "muted_conversation_ids"
    }

    var isValid: Bool {
        (1...Self.maximumWireInteger).contains(enrollmentEpoch)
            && (0...Self.maximumWireInteger).contains(revision)
            && mutedConversationIDs.count <= 2_048
            && Set(mutedConversationIDs).count == mutedConversationIDs.count
            && mutedConversationIDs.allSatisfy { MessageNotificationContract.canonicalUUID($0) == $0 }
    }
}

struct NotificationPreferenceUpdate: Encodable, Sendable {
    let expectedEnrollmentEpoch: Int
    let expectedRevision: Int
    let encryptedMessageAlerts: Bool
    let mutedConversationIDs: [String]
    enum CodingKeys: String, CodingKey {
        case expectedEnrollmentEpoch = "expected_enrollment_epoch"
        case expectedRevision = "expected_revision"
        case encryptedMessageAlerts = "encrypted_message_alerts"
        case mutedConversationIDs = "muted_conversation_ids"
    }
}

struct DesiredNotificationPreferences: Equatable, Sendable {
    let encryptedMessageAlerts: Bool
    let mutedConversationIDs: [String]

    init(localMutedConversationIDs: Set<String>) {
        let canonical = Set(localMutedConversationIDs.compactMap(MessageNotificationContract.canonicalUUID))
        let valid = canonical.count == localMutedConversationIDs.count && canonical.count <= 2_048
        encryptedMessageAlerts = valid
        mutedConversationIDs = valid ? canonical.sorted() : []
    }

    func matches(_ snapshot: NotificationPreferenceSnapshot) -> Bool {
        snapshot.isValid && encryptedMessageAlerts == snapshot.encryptedMessageAlerts
            && Set(mutedConversationIDs) == Set(snapshot.mutedConversationIDs)
    }

    var fingerprint: String {
        MessageNotificationContract.deterministicUUID(
            scope: "notification-preferences",
            values: [encryptedMessageAlerts ? "enabled" : "disabled"] + mutedConversationIDs
        ).uuidString.lowercased()
    }
}

@MainActor
final class NotificationPreferenceSynchronizer {
    enum Outcome: Equatable { case synchronized, retry, retryAfter(TimeInterval), unsupportedServer }
    static let shared = NotificationPreferenceSynchronizer()
    static let pendingMessage = "Notification preference change is waiting to sync."
    private let defaults: UserDefaults
    private struct PossiblyEnabled: Codable {
        let enrollmentEpoch: Int
        let expectedRevision: Int
        let desiredFingerprint: String

        var isValid: Bool {
            (1...NotificationPreferenceSnapshot.maximumWireInteger).contains(enrollmentEpoch)
                && (0...NotificationPreferenceSnapshot.maximumExpectedRevision).contains(expectedRevision)
                && MessageNotificationContract.canonicalUUID(desiredFingerprint) == desiredFingerprint
        }
    }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func needsPendingStatus(ownerUserID: String, localMutedConversationIDs: Set<String>) -> Bool {
        guard let key = storageKey(ownerUserID) else { return false }
        let desired = DesiredNotificationPreferences(localMutedConversationIDs: localMutedConversationIDs)
        if let bytes = defaults.data(forKey: key + ".possibly-enabled"), bytes.count <= 1_024,
           let pending = try? JSONDecoder().decode(PossiblyEnabled.self, from: bytes),
           pending.isValid {
            return !localMutedConversationIDs.isEmpty || desired.fingerprint != pending.desiredFingerprint
        }
        guard let data = defaults.data(forKey: key), data.count <= 100 * 1_024,
              let acknowledged = try? JSONDecoder().decode(NotificationPreferenceSnapshot.self, from: data),
              acknowledged.isValid, acknowledged.encryptedMessageAlerts else { return false }
        return !desired.matches(acknowledged)
    }

    func synchronize(
        ownerUserID: String,
        isCurrent: @MainActor () async -> Bool,
        latestLocalMuteIDs: @MainActor () async -> Set<String>?,
        fetch: @MainActor () async throws -> NotificationPreferenceSnapshot,
        update: @MainActor (NotificationPreferenceUpdate) async throws -> NotificationPreferenceSnapshot
    ) async -> Outcome {
        guard let key = storageKey(ownerUserID), !Task.isCancelled, await isCurrent() else { return .retry }
        do {
            let remote = try await fetch()
            guard remote.isValid, !Task.isCancelled, await isCurrent(),
                  let latest = await latestLocalMuteIDs(),
                  !Task.isCancelled, await isCurrent() else { return .retry }
            let desired = DesiredNotificationPreferences(localMutedConversationIDs: latest)
            let pending = defaults.data(forKey: key + ".possibly-enabled").flatMap { data -> PossiblyEnabled? in
                guard data.count <= 1_024,
                      let pending = try? JSONDecoder().decode(PossiblyEnabled.self, from: data),
                      pending.isValid else { return nil }
                return pending
            }
            // A GET at the same revision cannot rule out a delayed enabling PUT. Advance the
            // revision even for an equal desired value so the server rejects that obsolete write.
            let needsWriteFence = pending?.enrollmentEpoch == remote.enrollmentEpoch
                && pending?.expectedRevision == remote.revision
            let acknowledged: NotificationPreferenceSnapshot
            if desired.matches(remote), !needsWriteFence {
                acknowledged = remote
            } else {
                guard remote.revision <= NotificationPreferenceSnapshot.maximumExpectedRevision,
                      !Task.isCancelled, await isCurrent() else { return .retry }
                if desired.encryptedMessageAlerts {
                    // A timed-out PUT may still commit on the server. Persist uncertainty before
                    // sending it so a later offline mute cannot falsely promise background silence.
                    guard let bytes = try? JSONEncoder().encode(PossiblyEnabled(
                        enrollmentEpoch: remote.enrollmentEpoch, expectedRevision: remote.revision,
                        desiredFingerprint: desired.fingerprint
                    )) else { return .retry }
                    defaults.set(bytes, forKey: key + ".possibly-enabled")
                }
                acknowledged = try await update(NotificationPreferenceUpdate(
                    expectedEnrollmentEpoch: remote.enrollmentEpoch, expectedRevision: remote.revision,
                    encryptedMessageAlerts: desired.encryptedMessageAlerts,
                    mutedConversationIDs: desired.mutedConversationIDs
                ))
                guard acknowledged.enrollmentEpoch == remote.enrollmentEpoch,
                      acknowledged.revision == remote.revision + 1 else { return .retry }
            }
            guard desired.matches(acknowledged), !Task.isCancelled, await isCurrent(),
                  let after = await latestLocalMuteIDs(),
                  DesiredNotificationPreferences(localMutedConversationIDs: after) == desired,
                  !Task.isCancelled, await isCurrent(),
                  let data = try? JSONEncoder().encode(acknowledged) else { return .retry }
            defaults.set(data, forKey: key)
            defaults.removeObject(forKey: key + ".possibly-enabled")
            return .synchronized
        } catch {
            // A timeout may have committed. The next pass must GET a fresh epoch/revision and
            // read the latest local state, never replay this possibly obsolete PUT snapshot.
            if Self.isUnsupportedServer(error) { return .unsupportedServer }
            if let delay = Self.serverRetryDelay(error), delay.isFinite, delay > 0 {
                return .retryAfter(min(3_600, max(30, delay)))
            }
            return .retry
        }
    }

    private static func serverRetryDelay(_ error: Error) -> TimeInterval? {
        if let payload = error as? APIErrorPayload { return payload.retryAfter }
        if let client = error as? APIClientError,
           case .httpResponse(_, let delay) = client { return delay }
        return nil
    }

    private static func isUnsupportedServer(_ error: Error) -> Bool {
        let status: Int?
        if let payload = error as? APIErrorPayload {
            status = payload.httpStatus
        } else if let client = error as? APIClientError {
            switch client {
            case .invalidPayload(let value), .httpStatus(let value), .httpResponse(let value, _):
                status = value
            default: status = nil
            }
        } else { status = nil }
        return status.map { [404, 405, 501].contains($0) } ?? false
    }

    private func storageKey(_ ownerUserID: String) -> String? {
        MessageNotificationContract.accountFingerprint(for: ownerUserID).map {
            "kit.notification-preferences-ack.v1.\($0)"
        }
    }
}

struct NotificationInboxPage: Sendable {
    let items: [NotificationInboxItem]
    let nextCursor: String?
}

struct NotificationInboxItem: Decodable, Sendable {
    struct Payload: Decodable, Sendable {
        let callID: String?
        let recipientUserID: String?
        let state: String?
        let missedCallAlert: Bool?
        enum CodingKeys: String, CodingKey {
            case callID = "call_id", recipientUserID = "recipient_user_id"
            case state, missedCallAlert = "missed_call_alert"
        }
    }
    let id: String
    let type: String
    let data: Payload
    let silent: Bool
    let readAt: String?
    let createdAt: String
    enum CodingKeys: String, CodingKey {
        case id, type, data, silent
        case readAt = "read_at", createdAt = "created_at"
    }
}

struct NotificationInboxAlertRecord: Sendable {
    let requestIdentifier: String
    let notificationID: String
    let callID: String?
    let ownerFingerprint: String?
    let isRecovered: Bool
    let createdAt: Date
    let location: VisibleMessageNotificationRecord.Location
}

struct NotificationInboxTap: Codable, Equatable, Sendable {
    enum Destination: String, Codable, Sendable { case calls, home }
    let notificationID: String
    let recipientUserID: String
    let destination: Destination

    var key: String { "\(recipientUserID):\(notificationID)" }

    init?(_ payload: [AnyHashable: Any]) {
        guard let id = MessageNotificationContract.canonicalUUID(payload["notification_id"] as? String),
              let recipient = MessageNotificationContract.canonicalUUID(payload["recipient_user_id"] as? String),
              let type = payload["type"] as? String
        else { return nil }
        if type == "call.missed" {
            guard payload["missed_call_alert"] as? Bool == true,
                  payload["state"] as? String == "missed",
                  MessageNotificationContract.canonicalUUID(payload["call_id"] as? String) != nil
            else { return nil }
            destination = .calls
        } else if type == NotificationInboxRecoveryPolicy.localType {
            if payload["original_type"] as? String == "call.missed" {
                guard MessageNotificationContract.canonicalUUID(payload["call_id"] as? String) != nil else { return nil }
                destination = .calls
            } else { destination = .home }
        } else { return nil }
        notificationID = id
        recipientUserID = recipient
    }
}

struct NotificationInboxTapStore: @unchecked Sendable {
    private static let lock = NSLock()
    static let storageKey = "kit.notification-inbox-taps.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func append(_ tap: NotificationInboxTap) {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var pending = loadUnlocked()
        pending.removeAll { $0.key == tap.key }
        pending.append(tap)
        if let data = try? JSONEncoder().encode(Array(pending.suffix(16))) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    func remove(key: String) {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let remaining = loadUnlocked().filter { $0.key != key }
        if let data = try? JSONEncoder().encode(remaining) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    func actions() -> [NotificationInboxTap] {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return loadUnlocked()
    }

    private func loadUnlocked() -> [NotificationInboxTap] {
        guard let data = defaults.data(forKey: Self.storageKey), data.count <= 16_384,
              let taps = try? JSONDecoder().decode([NotificationInboxTap].self, from: data),
              taps.count <= 16
        else { return [] }
        return taps.filter {
            MessageNotificationContract.canonicalUUID($0.recipientUserID) != nil
                && MessageNotificationContract.canonicalUUID($0.notificationID) != nil
        }
    }
}

actor NotificationInboxTapDispatcher {
    typealias Handler = @Sendable (NotificationInboxTap) async -> MessageNotificationActionHandlingResult
    static let shared = NotificationInboxTapDispatcher()
    private let store: NotificationInboxTapStore
    private var handler: Handler?
    private var replaying = false

    init(store: NotificationInboxTapStore = .init()) { self.store = store }

    static func persistBeforeCompletingSystemResponse(
        _ tap: NotificationInboxTap, store: NotificationInboxTapStore = .init()
    ) {
        store.append(tap)
    }

    func install(_ handler: @escaping Handler) async {
        self.handler = handler
        await replayPending()
    }

    func replayPending() async {
        guard !replaying, let handler else { return }
        replaying = true
        defer { replaying = false }
        var attempted: Set<String> = []
        while let tap = store.actions().first(where: { !attempted.contains($0.key) }) {
            attempted.insert(tap.key)
            let result = await handler(tap)
            guard result != .retry else { continue }
            // Merge with taps that arrived while restoration/routing suspended.
            store.remove(key: tap.key)
        }
    }
}

enum NotificationInboxRecoveryPolicy {
    static let localType = "notification.recovered"
    static let maximumActiveAlerts = 12
    static let maximumOlderPagesPerPass = 3

    static func identity(for item: NotificationInboxItem, ownerUserID: String) -> String? {
        guard !item.silent, item.readAt == nil,
              let id = MessageNotificationContract.canonicalUUID(item.id),
              !item.type.hasPrefix("messaging."), !item.type.hasPrefix("message.")
        else { return nil }
        if item.type.hasPrefix("call.") {
            guard item.type == "call.missed", item.data.missedCallAlert == true,
                  item.data.state == "missed",
                  MessageNotificationContract.canonicalUUID(item.data.recipientUserID)
                    == MessageNotificationContract.canonicalUUID(ownerUserID),
                  let callID = MessageNotificationContract.canonicalUUID(item.data.callID)
            else { return nil }
            return "call.missed:\(MessageNotificationContract.messageDigest(for: callID)!)"
        }
        return "notification:\(MessageNotificationContract.messageDigest(for: id)!)"
    }

    static func alreadyPresented(
        _ item: NotificationInboxItem, ownerFingerprint: String,
        active: [NotificationInboxAlertRecord]
    ) -> Bool {
        active.contains { record in
            if record.notificationID == MessageNotificationContract.canonicalUUID(item.id) { return true }
            return item.type == "call.missed" && record.ownerFingerprint == ownerFingerprint
                && record.callID != nil
                && record.callID == MessageNotificationContract.canonicalUUID(item.data.callID)
        }
    }
}

/// The unread inbox is the durable recovery source when an OS push was dropped. Receipts are
/// local presentation acknowledgements, never server read receipts. Cursors walk older pages;
/// every pass also revisits the head because an old scheduled row can become visible later.
@MainActor
final class NotificationInboxRecoveryCoordinator {
    static let shared = NotificationInboxRecoveryCoordinator()
    private let center: any VisibleMessageNotificationCenter
    private let defaults: UserDefaults
    private var ownerFingerprint: String?
    private var generation: UInt64 = 0
    private var runningGeneration: UInt64?
    private struct Checkpoint: Codable {
        var receipts: Set<String> = []
        var seenDuringScan: Set<String> = []
        var cursor: String?
    }

    init(center: (any VisibleMessageNotificationCenter)? = nil, defaults: UserDefaults = .standard) {
        self.center = center ?? SystemVisibleMessageNotificationCenter()
        self.defaults = defaults
    }

    func quarantine() {
        generation &+= 1
        ownerFingerprint = nil
        runningGeneration = nil
    }

    func resume(for ownerUserID: String) {
        generation &+= 1
        ownerFingerprint = MessageNotificationContract.accountFingerprint(for: ownerUserID)
    }

    func recover(
        ownerUserID: String,
        isCurrent: @MainActor () async -> Bool,
        fetch: @MainActor (String?) async throws -> NotificationInboxPage
    ) async -> Bool {
        guard let owner = MessageNotificationContract.accountFingerprint(for: ownerUserID),
              ownerFingerprint == owner, runningGeneration == nil,
              await isCurrent()
        else { return false }
        let expectedGeneration = generation
        runningGeneration = expectedGeneration
        defer { if runningGeneration == expectedGeneration { runningGeneration = nil } }
        let key = "kit.notification-inbox.v1.\(owner)"
        var checkpoint = defaults.data(forKey: key).flatMap {
            try? JSONDecoder().decode(Checkpoint.self, from: $0)
        } ?? Checkpoint()
        if checkpoint.cursor == nil { checkpoint.seenDuringScan.removeAll() }
        do {
            let head = try await fetch(nil)
            guard try await process(head, ownerUserID: ownerUserID, owner: owner, key: key,
                                checkpoint: &checkpoint, generation: expectedGeneration,
                                isCurrent: isCurrent) else { return false }
            var cursor = head.nextCursor == nil ? nil : (checkpoint.cursor ?? head.nextCursor)
            checkpoint.cursor = cursor
            guard generation == expectedGeneration, await isCurrent(),
                  save(checkpoint, key: key, generation: expectedGeneration) else { return false }
            var visited: Set<String> = []
            for _ in 0..<NotificationInboxRecoveryPolicy.maximumOlderPagesPerPass {
                guard let next = cursor else { break }
                guard !next.isEmpty, next.utf8.count <= 2_048,
                      visited.insert(next).inserted,
                      generation == expectedGeneration, await isCurrent()
                else { return false }
                let page = try await fetch(next)
                guard try await process(page, ownerUserID: ownerUserID, owner: owner, key: key,
                                    checkpoint: &checkpoint, generation: expectedGeneration,
                                    isCurrent: isCurrent) else { return false }
                cursor = page.nextCursor
                guard cursor != next else { return false }
                checkpoint.cursor = cursor
                guard await isCurrent(), save(checkpoint, key: key, generation: expectedGeneration)
                else { return false }
            }
            checkpoint.cursor = cursor
            if cursor == nil {
                // Prune only after an entire authenticated unread scan. An age/size eviction
                // would repeatedly alert for old unread rows after a long offline interval.
                checkpoint.receipts.formIntersection(checkpoint.seenDuringScan)
                checkpoint.seenDuringScan.removeAll()
            }
            guard generation == expectedGeneration, await isCurrent(),
                  save(checkpoint, key: key, generation: expectedGeneration) else { return false }
            return cursor != nil
        } catch {
            // Leave both unread state and the last completely handled page intact for recovery.
            guard generation == expectedGeneration else { return false }
            return await isCurrent()
        }
    }

    private func process(
        _ page: NotificationInboxPage, ownerUserID: String, owner: String, key: String,
        checkpoint: inout Checkpoint, generation expectedGeneration: UInt64,
        isCurrent: @MainActor () async -> Bool
    ) async throws -> Bool {
        guard page.items.count <= 100, generation == expectedGeneration, await isCurrent()
        else { return false }
        let authorization = await center.authorization()
        var active = await center.activeInboxNotifications()
        guard generation == expectedGeneration, await isCurrent() else { return false }
        for item in page.items {
            guard generation == expectedGeneration, await isCurrent() else { return false }
            guard let identity = NotificationInboxRecoveryPolicy.identity(for: item, ownerUserID: ownerUserID),
                  let createdAt = CallLifecyclePolicy.serverTimestamp(item.createdAt)
            else { continue }
            checkpoint.seenDuringScan.insert(identity)
            if checkpoint.receipts.contains(identity) { continue }
            if NotificationInboxRecoveryPolicy.alreadyPresented(item, ownerFingerprint: owner, active: active) {
                checkpoint.receipts.insert(identity)
                guard save(checkpoint, key: key, generation: expectedGeneration) else { return false }
                continue
            }
            guard authorization.permitsVisibleAlerts else { continue }
            let owned = active.filter { $0.isRecovered && $0.ownerFingerprint == owner }
            var eviction: NotificationInboxAlertRecord?
            if owned.count >= NotificationInboxRecoveryPolicy.maximumActiveAlerts {
                guard let oldest = owned.min(by: { $0.createdAt < $1.createdAt }),
                      createdAt > oldest.createdAt else { continue }
                eviction = oldest
            }
            let content = UNMutableNotificationContent()
            content.title = item.type == "call.missed" ? "Missed call" : "Kit Pay update"
            content.body = item.type == "call.missed"
                ? "Open Kit Pay to view your calls." : "Open Kit Pay to view your updates."
            content.sound = .default
            content.userInfo = ["type": NotificationInboxRecoveryPolicy.localType,
                                "notification_id": item.id, "recipient_user_id": ownerUserID,
                                "original_type": item.type, "created_at": item.createdAt]
            if item.type == "call.missed", let callID = item.data.callID { content.userInfo["call_id"] = callID }
            let request = UNNotificationRequest(
                identifier: "kit.inbox.\(owner).\(identity)", content: content, trigger: nil
            )
            try await center.add(request)
            guard generation == expectedGeneration, await isCurrent() else {
                center.removePendingRequests(withIdentifiers: [request.identifier])
                center.removeDeliveredNotifications(withIdentifiers: [request.identifier])
                return false
            }
            if let eviction {
                center.removePendingRequests(withIdentifiers: [eviction.requestIdentifier])
                center.removeDeliveredNotifications(withIdentifiers: [eviction.requestIdentifier])
                active.removeAll { $0.requestIdentifier == eviction.requestIdentifier }
            }
            checkpoint.receipts.insert(identity)
            guard save(checkpoint, key: key, generation: expectedGeneration) else { return false }
            active.append(NotificationInboxAlertRecord(
                requestIdentifier: request.identifier, notificationID: item.id,
                callID: item.type == "call.missed" ? item.data.callID : nil,
                ownerFingerprint: owner, isRecovered: true, createdAt: createdAt, location: .pending
            ))
        }
        return true
    }

    private func save(_ checkpoint: Checkpoint, key: String, generation expectedGeneration: UInt64) -> Bool {
        guard generation == expectedGeneration,
              let bytes = try? JSONEncoder().encode(checkpoint) else { return false }
        defaults.set(bytes, forKey: key)
        return true
    }
}

enum RecipientBoundRemoteNotificationPolicy {
    static func permits(_ payload: [AnyHashable: Any], ownerFingerprint: String?) -> Bool {
        guard let recipient = payload["recipient_user_id"] as? String,
              let fingerprint = MessageNotificationContract.accountFingerprint(for: recipient),
              let ownerFingerprint
        else { return false }
        return fingerprint == ownerFingerprint
    }
}

enum RemoteMessageNotificationReconciliationPolicy {
    static func identifiersToRemove(
        records: [RemoteMessageNotificationRecord],
        messages: [LocalMessage],
        ownerUserID: String,
        suppressedConversationID: String?,
        mutedConversationIDs: Set<String>
    ) -> [String] {
        guard let owner = MessageNotificationContract.canonicalUUID(ownerUserID) else { return [] }
        let suppressed = MessageNotificationContract.canonicalUUID(suppressedConversationID)
        let muted = Set(mutedConversationIDs.compactMap { MessageNotificationContract.canonicalUUID($0) })
        let clearedMessageIDs = Set(messages.compactMap { message -> String? in
            guard !message.isOutgoing,
                  let conversation = MessageNotificationContract.canonicalUUID(message.conversationId),
                  conversation == suppressed || muted.contains(conversation)
            else { return nil }
            return MessageNotificationContract.canonicalUUID(message.serverMessageId)
        })
        var retainedKeys: Set<String> = []
        return records.sorted { $0.requestIdentifier < $1.requestIdentifier }.compactMap { record in
            guard record.notice.recipientUserID == owner else { return nil }
            if clearedMessageIDs.contains(record.notice.messageID)
                || !retainedKeys.insert(record.notice.deduplicationKey).inserted {
                return record.requestIdentifier
            }
            return nil
        }
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

enum MessageNotificationActionHandlingResult: Equatable, Sendable {
    /// The route or inline reply committed successfully and may be retired permanently.
    case completed
    /// Required authenticated state is not ready yet. Keep the action for a later lifecycle or
    /// connectivity replay rather than losing a cold-launch tap.
    case retry
    /// A fully restored authenticated account proved that this action belongs to another owner.
    /// This is the only failure that may retire an otherwise valid pending action.
    case invalidated
}

/// Persists only privacy-preserving open routes. The notification payload has already replaced
/// account, conversation and message identifiers with validated UUIDs/digests, and no message
/// body or sender name is stored. Inline-reply text is deliberately excluded: its handler keeps
/// the system response alive until the encrypted outbox write finishes.
private struct MessageNotificationOpenActionStore {
    private static let lock = NSLock()

    private struct Record: Codable {
        let requestIdentifier: String
        let conversationID: String
        let accountFingerprint: String
        let messageDigest: String?

        init(_ action: MessageNotificationAction) {
            requestIdentifier = action.requestIdentifier
            conversationID = action.conversationID
            accountFingerprint = action.accountFingerprint
            messageDigest = action.messageDigest
        }

        var action: MessageNotificationAction? {
            guard MessageNotificationContract.isMessageRequestIdentifier(requestIdentifier),
                  MessageNotificationContract.canonicalUUID(conversationID) == conversationID,
                  MessageNotificationContract.isIdentifierDigest(accountFingerprint),
                  messageDigest == nil
                    || MessageNotificationContract.isIdentifierDigest(messageDigest ?? "")
            else { return nil }
            return MessageNotificationAction(
                requestIdentifier: requestIdentifier,
                conversationID: conversationID,
                accountFingerprint: accountFingerprint,
                messageDigest: messageDigest,
                kind: .open
            )
        }
    }

    let defaults: UserDefaults
    let storageKey: String

    func actions() -> [MessageNotificationAction] {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return actionsLocked()
    }

    func store(_ action: MessageNotificationAction) {
        guard case .open = action.kind else { return }
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var actions = actionsLocked()
        if let index = actions.firstIndex(where: {
            $0.deduplicationKey == action.deduplicationKey
        }) {
            actions[index] = action
        } else {
            actions.append(action)
        }
        saveLocked(actions)
    }

    func remove(deduplicationKey: String) {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        saveLocked(actionsLocked().filter { $0.deduplicationKey != deduplicationKey })
    }

    private func actionsLocked() -> [MessageNotificationAction] {
        guard let data = defaults.data(forKey: storageKey),
              let records = try? JSONDecoder().decode([Record].self, from: data)
        else { return [] }
        var seen: Set<String> = []
        let actions = records.compactMap(\.action).filter {
            seen.insert($0.deduplicationKey).inserted
        }
        if actions.count != records.count { saveLocked(actions) }
        return actions
    }

    private func saveLocked(_ actions: [MessageNotificationAction]) {
        let records = actions.compactMap { action -> Record? in
            guard case .open = action.kind else { return nil }
            return Record(action)
        }
        guard !records.isEmpty else {
            defaults.removeObject(forKey: storageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: storageKey)
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

enum NotificationResponseDisposition: Equatable, Sendable {
    case message(MessageNotificationAction)
    case claim(ClaimablePaymentNotificationAction)
    case opaqueWake
    case ignore

    /// Opening a notification launches the app and can finish UIKit's handoff before protected
    /// state, Signal sessions, and the target conversation have finished restoring. Holding the
    /// completion handler across that work lets iOS kill a cold launch as unresponsive. Inline
    /// reply is the exception: it may run without foregrounding Kit Pay, so its brief durable
    /// outbox write keeps the system response lifetime until the write has completed.
    var completesBeforeRouting: Bool {
        switch self {
        case .message(let action):
            if case .reply = action.kind { return false }
            return true
        case .claim, .opaqueWake, .ignore:
            return true
        }
    }
}

enum NotificationResponseDispositionPolicy {
    /// Strictly validated message/payment actions remain admissible during cold-launch privacy
    /// quarantine. Their handlers wait for protected-state restoration and re-prove the account,
    /// conversation, and authoritative payment before navigating. An opaque provider payload has
    /// no such binding and is forwarded only after normal notification ownership is active.
    static func disposition(
        messageAction: MessageNotificationAction?,
        claimAction: ClaimablePaymentNotificationAction?,
        registrationEnabled: Bool,
        privacyQuarantineActive: Bool
    ) -> NotificationResponseDisposition {
        if let messageAction { return .message(messageAction) }
        if let claimAction { return .claim(claimAction) }
        guard registrationEnabled, !privacyQuarantineActive else { return .ignore }
        return .opaqueWake
    }
}

/// UIKit may perform scene restoration inside this callback. Its caller can finish on any
/// executor, so transfer the one system completion to the main queue before invoking it.
final class NotificationSystemResponseCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (() -> Void)?

    init(_ handler: @escaping () -> Void) { self.handler = handler }

    func complete() {
        lock.lock()
        let callback = handler
        handler = nil
        lock.unlock()
        guard let callback else { return }
        if Thread.isMainThread {
            callback()
        } else {
            DispatchQueue.main.async(execute: callback)
        }
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
    typealias Handler = @MainActor @Sendable (
        MessageNotificationAction
    ) async -> MessageNotificationActionHandlingResult

    static let shared = MessageNotificationActionDispatcher()
    static let defaultStorageKey = "kit-pay-pending-message-notification-opens-v1"

    /// UIKit's completion handler must be released promptly on a cold launch, but queuing an
    /// unstructured task after that callback leaves a process-termination gap. Persist the opaque
    /// open route synchronously first; the actor performs all routing and deduplication afterward.
    static func persistBeforeCompletingSystemResponse(
        _ action: MessageNotificationAction,
        defaults: UserDefaults = .standard,
        storageKey: String = MessageNotificationActionDispatcher.defaultStorageKey
    ) {
        MessageNotificationOpenActionStore(
            defaults: defaults,
            storageKey: storageKey
        ).store(action)
    }

    private let durableStore: MessageNotificationOpenActionStore
    private var handler: Handler?
    private var pending: [MessageNotificationAction]
    private var pendingKeys: Set<String>
    private var activeKeys: Set<String> = []
    private var completedKeys: Set<String> = []
    private var completedOrder: [String] = []
    private let maximumCompletedKeys = 128

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = MessageNotificationActionDispatcher.defaultStorageKey
    ) {
        let durableStore = MessageNotificationOpenActionStore(
            defaults: defaults,
            storageKey: storageKey
        )
        self.durableStore = durableStore
        let restored = durableStore.actions()
        pending = restored
        pendingKeys = Set(restored.map(\.deduplicationKey))
    }

    func install(_ handler: @escaping Handler) async {
        // Notification responses can arrive while SwiftUI is still constructing AppModel during
        // a cold launch. Durable open intents also survive termination between UIKit handing the
        // response off and the account-bound model finishing protected-state restoration.
        self.handler = handler
        await replayPending()
    }

    func replayPending() async {
        // The notification delegate writes open routes synchronously before UIKit's completion
        // handler. The shared dispatcher may already exist at that point, so fold any records
        // written after actor initialization into the process-local queue on every lifecycle wake.
        for action in durableStore.actions() {
            let key = action.deduplicationKey
            if completedKeys.contains(key) {
                durableStore.remove(deduplicationKey: key)
            } else if !pendingKeys.contains(key), !activeKeys.contains(key) {
                pending.append(action)
                pendingKeys.insert(key)
            }
        }
        guard let handler else { return }
        let buffered = pending
        pending.removeAll()
        pendingKeys.removeAll()
        for action in buffered {
            guard !completedKeys.contains(action.deduplicationKey),
                  activeKeys.insert(action.deduplicationKey).inserted
            else { continue }
            let result = await handler(action)
            activeKeys.remove(action.deduplicationKey)
            finish(action, result: result)
        }
    }

    func dispatch(_ action: MessageNotificationAction) async {
        let key = action.deduplicationKey
        if completedKeys.contains(key) {
            // A repeated UIKit callback persisted the route before it could consult this actor.
            // Retire that new durable copy instead of replaying a completed tap after relaunch.
            durableStore.remove(deduplicationKey: key)
            return
        }
        guard !activeKeys.contains(key) else { return }
        if pendingKeys.remove(key) != nil {
            // A repeated delivery is an explicit retry opportunity. Remove the parked copy and
            // execute this newest equivalent action through the normal single-flight path.
            pending.removeAll { $0.deduplicationKey == key }
        }
        guard activeKeys.insert(key).inserted else { return }
        durableStore.store(action)
        guard let handler else {
            activeKeys.remove(key)
            pending.append(action)
            pendingKeys.insert(key)
            return
        }
        let result = await handler(action)
        activeKeys.remove(key)
        finish(action, result: result)
    }

    private func finish(
        _ action: MessageNotificationAction,
        result: MessageNotificationActionHandlingResult
    ) {
        switch result {
        case .completed, .invalidated:
            durableStore.remove(deduplicationKey: action.deduplicationKey)
            recordCompletion(action.deduplicationKey)
        case .retry:
            guard pendingKeys.insert(action.deduplicationKey).inserted else { return }
            pending.append(action)
        }
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
    /// A one-way owner binding captured from an already recovered notification session, or set by
    /// the first fully authenticated account that handles an otherwise cold-launch action.
    let accountFingerprint: String?

    init(
        notificationID: String,
        claimID: String,
        conversationID: String?,
        groupPaymentID: String?,
        accountFingerprint: String? = nil
    ) {
        self.notificationID = notificationID
        self.claimID = claimID
        self.conversationID = conversationID
        self.groupPaymentID = groupPaymentID
        self.accountFingerprint = accountFingerprint
    }

    var deduplicationKey: String {
        "\(notificationID):\(claimID)"
    }

    func bound(toAccountFingerprint fingerprint: String) -> Self? {
        guard MessageNotificationContract.isIdentifierDigest(fingerprint),
              accountFingerprint == nil || accountFingerprint == fingerprint
        else { return nil }
        return Self(
            notificationID: notificationID,
            claimID: claimID,
            conversationID: conversationID,
            groupPaymentID: groupPaymentID,
            accountFingerprint: fingerprint
        )
    }
}

enum ClaimablePaymentNotificationActionHandlingResult: Equatable, Sendable {
    /// The account-authorized route committed successfully and may be retired permanently.
    case completed
    /// Protected/authenticated state or the authoritative claim is not ready. Keep the existing
    /// owner binding and retry on a later lifecycle or connectivity wake.
    case retry
    /// Persist the first fully restored account, then immediately invoke the handler again with
    /// that strengthened action. No network or routing work may begin before this transition.
    case bindAndContinue(toAccountFingerprint: String)
    /// A fully restored account or authoritative claim proved that this intent is not admissible.
    case invalidated
}

/// Decides whether an authoritative claim lookup can ever succeed if replayed. A withdrawn
/// feature and a server denial/not-found response are final for this notification route; network,
/// decoding, cancellation, authentication-refresh, and server failures remain retryable.
enum ClaimablePaymentNotificationLookupFailurePolicy {
    static func isTerminal(_ error: Error) -> Bool {
        if let payload = error as? APIErrorPayload,
           let status = payload.httpStatus {
            return [403, 404, 410].contains(status)
        }
        if let clientError = error as? APIClientError {
            switch clientError {
            case .invalidPayload(let status), .httpStatus(let status),
                 .httpResponse(let status, _):
                return [403, 404, 410].contains(status)
            case .signedOut, .invalidResponse, .invalidURL:
                return false
            }
        }
        return false
    }
}

enum ClaimablePaymentNotificationCapabilityReadiness: Equatable {
    case enabled
    case awaitingAuthority
    case withdrawn
}

enum ClaimablePaymentNotificationCapabilityPolicy {
    private static let requiredFeatures = [
        "wallets", "internal_transfers", "claimable_transfers",
    ]

    static func readiness(
        capabilities: CapabilitiesDTO?
    ) -> ClaimablePaymentNotificationCapabilityReadiness {
        guard let capabilities else { return .awaitingAuthority }
        if requiredFeatures.contains(where: capabilities.featureIsWithdrawn) {
            return .withdrawn
        }
        guard requiredFeatures.allSatisfy(capabilities.supportsFeature)
        else { return .awaitingAuthority }
        return .enabled
    }
}

/// Persists only validated identifiers and a one-way account digest. Claim amount, counterparties,
/// notification copy, and credentials never enter preferences. For duplicate callbacks the first
/// owner binding wins: an unbound replay can strengthen an existing record, but it cannot erase or
/// replace a previously proven account.
private struct ClaimablePaymentNotificationActionStore {
    private static let lock = NSLock()

    private struct Record: Codable {
        let notificationID: String
        let claimID: String
        let conversationID: String?
        let groupPaymentID: String?
        let accountFingerprint: String?

        init(_ action: ClaimablePaymentNotificationAction) {
            notificationID = action.notificationID
            claimID = action.claimID
            conversationID = action.conversationID
            groupPaymentID = action.groupPaymentID
            accountFingerprint = action.accountFingerprint
        }

        var action: ClaimablePaymentNotificationAction? {
            guard MessageNotificationContract.canonicalUUID(notificationID) == notificationID,
                  MessageNotificationContract.canonicalUUID(claimID) == claimID,
                  conversationID.map({
                      MessageNotificationContract.canonicalUUID($0) == $0
                  }) ?? true,
                  groupPaymentID.map({
                      MessageNotificationContract.canonicalUUID($0) == $0
                  }) ?? true,
                  accountFingerprint.map({
                      MessageNotificationContract.isIdentifierDigest($0)
                  }) ?? true
            else { return nil }
            return ClaimablePaymentNotificationAction(
                notificationID: notificationID,
                claimID: claimID,
                conversationID: conversationID,
                groupPaymentID: groupPaymentID,
                accountFingerprint: accountFingerprint
            )
        }
    }

    let defaults: UserDefaults
    let storageKey: String

    func actions() -> [ClaimablePaymentNotificationAction] {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return actionsLocked()
    }

    @discardableResult
    func store(
        _ action: ClaimablePaymentNotificationAction
    ) -> ClaimablePaymentNotificationAction {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var actions = actionsLocked()
        let stored: ClaimablePaymentNotificationAction
        if let index = actions.firstIndex(where: {
            $0.deduplicationKey == action.deduplicationKey
        }) {
            let existing = actions[index]
            if existing.accountFingerprint == nil,
               let incomingFingerprint = action.accountFingerprint,
               let bound = existing.bound(toAccountFingerprint: incomingFingerprint) {
                actions[index] = bound
                stored = bound
            } else {
                stored = existing
            }
        } else {
            actions.append(action)
            stored = action
        }
        saveLocked(actions)
        return stored
    }

    func remove(deduplicationKey: String) {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        saveLocked(actionsLocked().filter { $0.deduplicationKey != deduplicationKey })
    }

    func removeAll() {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        defaults.removeObject(forKey: storageKey)
    }

    private func actionsLocked() -> [ClaimablePaymentNotificationAction] {
        guard let data = defaults.data(forKey: storageKey),
              let records = try? JSONDecoder().decode([Record].self, from: data)
        else { return [] }
        var seen: Set<String> = []
        let actions = records.compactMap(\.action).filter {
            seen.insert($0.deduplicationKey).inserted
        }
        if actions.count != records.count { saveLocked(actions) }
        return actions
    }

    private func saveLocked(_ actions: [ClaimablePaymentNotificationAction]) {
        guard !actions.isEmpty else {
            defaults.removeObject(forKey: storageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(actions.map(Record.init)) else { return }
        defaults.set(data, forKey: storageKey)
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

    /// Group shares are deliberately unreadable through `GET transfer-claims/{id}`. The group
    /// payment projection is therefore the authority for a notification carrying group context.
    /// A sender owns the whole payment; a recipient must additionally prove that the caller-scoped
    /// `your_share` is the exact claim named by the notification.
    static func authorizesGroupPayment(
        action: ClaimablePaymentNotificationAction,
        groupPayment: GroupPaymentDTO,
        currentUserID: String?
    ) -> Bool {
        guard let actionGroupPaymentID = canonicalUUID(action.groupPaymentID),
              let actionConversationID = canonicalUUID(action.conversationID),
              canonicalUUID(groupPayment.id) == actionGroupPaymentID,
              canonicalUUID(groupPayment.conversationId) == actionConversationID,
              ["pending", "settled"].contains(groupPayment.status),
              let currentUserID = canonicalUUID(currentUserID),
              let senderID = canonicalUUID(groupPayment.sender?.id)
        else { return false }
        if currentUserID == senderID { return true }
        guard let share = groupPayment.yourShare,
              share.knownStatus != nil,
              canonicalUUID(share.claimId) == action.claimID
        else { return false }
        return true
    }

    static func conversation(
        action: ClaimablePaymentNotificationAction,
        groupPayment: GroupPaymentDTO,
        conversations: [Conversation],
        currentUserID: String?
    ) -> Conversation? {
        guard authorizesGroupPayment(
            action: action,
            groupPayment: groupPayment,
            currentUserID: currentUserID
        ),
            let conversationID = canonicalUUID(action.conversationID),
            let currentUserID = canonicalUUID(currentUserID),
            let senderID = canonicalUUID(groupPayment.sender?.id)
        else { return nil }
        let matches = conversations.filter {
            canonicalUUID($0.id) == conversationID
        }
        guard matches.count == 1,
              let conversation = matches.first,
              conversation.isGroup,
              let participants = canonicalRoster(conversation.participantUserIds),
              participants.contains(currentUserID),
              participants.contains(senderID)
        else { return nil }
        return conversation
    }

    static func targetMessageID(
        action: ClaimablePaymentNotificationAction,
        groupPayment: GroupPaymentDTO,
        conversation: Conversation,
        messages: [LocalMessage]
    ) -> UUID? {
        guard let groupPaymentID = canonicalUUID(action.groupPaymentID),
              canonicalUUID(groupPayment.id) == groupPaymentID,
              canonicalUUID(action.conversationID) == canonicalUUID(conversation.id),
              canonicalUUID(groupPayment.conversationId) == canonicalUUID(conversation.id),
              let senderID = canonicalUUID(groupPayment.sender?.id)
        else { return nil }
        let matches = messages.filter { message in
            guard canonicalUUID(message.conversationId) == canonicalUUID(conversation.id),
                  canonicalUUID(message.senderId) == senderID,
                  let descriptor = KitGroupPaymentMessage.parse(message.body)
            else { return false }
            return descriptor.action == .sent
                && descriptor.groupPaymentId == groupPaymentID
                && descriptor.matchesAuthoritativePayment(groupPayment)
        }
        guard matches.count == 1 else { return nil }
        return matches[0].id
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
    typealias Handler = @MainActor @Sendable (
        ClaimablePaymentNotificationAction
    ) async -> ClaimablePaymentNotificationActionHandlingResult

    static let shared = ClaimablePaymentNotificationActionDispatcher()
    static let defaultStorageKey = "kit-pay-pending-claim-notification-opens-v1"

    /// Claim taps foreground the app, so UIKit's response lifetime must end promptly. The opaque,
    /// validated route is committed synchronously first to close the process-termination gap.
    static func persistBeforeCompletingSystemResponse(
        _ action: ClaimablePaymentNotificationAction,
        defaults: UserDefaults = .standard,
        storageKey: String = ClaimablePaymentNotificationActionDispatcher.defaultStorageKey
    ) {
        ClaimablePaymentNotificationActionStore(
            defaults: defaults,
            storageKey: storageKey
        ).store(action)
    }

    private let durableStore: ClaimablePaymentNotificationActionStore
    private var handler: Handler?
    private var pending: [ClaimablePaymentNotificationAction]
    private var pendingKeys: Set<String>
    private var activeKeys: Set<String> = []
    /// A lifecycle/capability wake that races an already-running handler must not disappear. The
    /// active handler consumes this latch only after it has durably re-queued a retry.
    private var replayAfterActiveKeys: Set<String> = []
    /// Invalidates a replay snapshot even when it contains more keys than the bounded completed
    /// deduplication window can retain.
    private var accountBoundaryGeneration: UInt64 = 0
    /// An account transition can retire an action while its handler is suspended. Keep those keys
    /// fenced until the handler unwinds so a late retry result cannot recreate a deleted record.
    private var retiredActiveKeys: Set<String> = []
    private var completedKeys: Set<String> = []
    private var completedOrder: [String] = []
    private let maximumCompletedKeys = 128

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = ClaimablePaymentNotificationActionDispatcher.defaultStorageKey
    ) {
        let durableStore = ClaimablePaymentNotificationActionStore(
            defaults: defaults,
            storageKey: storageKey
        )
        self.durableStore = durableStore
        let restored = durableStore.actions()
        pending = restored
        pendingKeys = Set(restored.map(\.deduplicationKey))
    }

    func install(_ handler: @escaping Handler) async {
        self.handler = handler
        await replayPending()
    }

    func replayPending() async {
        // The notification delegate writes before releasing UIKit. Reload on every explicit wake
        // because the process-wide actor may have been initialized before that synchronous write.
        for action in durableStore.actions() {
            let key = action.deduplicationKey
            if completedKeys.contains(key) {
                durableStore.remove(deduplicationKey: key)
            } else if activeKeys.contains(key) {
                replayAfterActiveKeys.insert(key)
            } else {
                if let index = pending.firstIndex(where: {
                    $0.deduplicationKey == key
                }) {
                    // A synchronous callback may have strengthened an unbound record after this
                    // actor initialized. Always prefer the store's first-owner-wins snapshot.
                    pending[index] = action
                } else {
                    pending.append(action)
                    pendingKeys.insert(key)
                }
            }
        }
        guard let handler else { return }
        let replayGeneration = accountBoundaryGeneration
        let buffered = pending
        pending.removeAll()
        pendingKeys.removeAll()
        for action in buffered {
            guard accountBoundaryGeneration == replayGeneration else { return }
            guard !completedKeys.contains(action.deduplicationKey),
                  activeKeys.insert(action.deduplicationKey).inserted
            else { continue }
            await handle(action, using: handler)
        }
    }

    func dispatch(_ action: ClaimablePaymentNotificationAction) async {
        let key = action.deduplicationKey
        if completedKeys.contains(key) {
            // A repeated callback may have recreated the durable row before consulting this actor.
            durableStore.remove(deduplicationKey: key)
            return
        }
        guard !activeKeys.contains(key) else {
            // A repeated tap is also an explicit wake. Coalesce it with any lifecycle/capability
            // wake and run once more if the in-flight attempt finishes as retryable.
            replayAfterActiveKeys.insert(key)
            return
        }
        if pendingKeys.remove(key) != nil {
            // A duplicate callback is also an explicit retry opportunity. The store returns the
            // first (and potentially already account-bound) representation of this exact intent.
            pending.removeAll { $0.deduplicationKey == key }
        }
        let stored = durableStore.store(action)
        guard activeKeys.insert(key).inserted else { return }
        guard let handler else {
            activeKeys.remove(key)
            pending.append(stored)
            pendingKeys.insert(key)
            return
        }
        await handle(stored, using: handler)
    }

    /// Clears all claim routes at a real account boundary. Claim APNs do not carry an owner field,
    /// so retaining an unbound row would let a later session adopt it. Active handlers are fenced
    /// until they unwind, preventing a late retry result from recreating the removed record.
    func invalidateAllPendingActions() {
        accountBoundaryGeneration &+= 1
        let keys = Set(durableStore.actions().map(\.deduplicationKey))
            .union(pending.map(\.deduplicationKey))
            .union(activeKeys)
        retiredActiveKeys.formUnion(activeKeys)
        replayAfterActiveKeys.removeAll()
        pending.removeAll()
        pendingKeys.removeAll()
        durableStore.removeAll()
        keys.forEach(recordCompletion)
    }

    private func handle(
        _ initialAction: ClaimablePaymentNotificationAction,
        using handler: Handler
    ) async {
        let key = initialAction.deduplicationKey
        var action = initialAction
        var shouldReplayAfterActiveAttempt = false
        actionLoop: while true {
            let result = await handler(action)
            guard !retiredActiveKeys.contains(key), !completedKeys.contains(key) else {
                durableStore.remove(deduplicationKey: key)
                break actionLoop
            }
            switch result {
            case .bindAndContinue(let accountFingerprint):
                guard action.accountFingerprint == nil,
                      let bound = action.bound(
                          toAccountFingerprint: accountFingerprint
                      )
                else {
                    finish(action, result: .invalidated)
                    break actionLoop
                }
                let stored = durableStore.store(bound)
                guard stored.accountFingerprint == accountFingerprint else {
                    finish(action, result: .invalidated)
                    break actionLoop
                }
                action = stored
            case .completed, .retry, .invalidated:
                finish(action, result: result)
                shouldReplayAfterActiveAttempt = result == .retry
                    && replayAfterActiveKeys.contains(key)
                break actionLoop
            }
        }
        replayAfterActiveKeys.remove(key)
        activeKeys.remove(key)
        retiredActiveKeys.remove(key)
        if shouldReplayAfterActiveAttempt {
            // The wake happened after this attempt began. Active ownership has now been released
            // and `.retry` has restored the durable row, so the coalesced replay cannot be lost.
            await replayPending()
        }
    }

    private func finish(
        _ action: ClaimablePaymentNotificationAction,
        result: ClaimablePaymentNotificationActionHandlingResult
    ) {
        switch result {
        case .completed, .invalidated:
            durableStore.remove(deduplicationKey: action.deduplicationKey)
            recordCompletion(action.deduplicationKey)
        case .retry:
            enqueue(durableStore.store(action))
        case .bindAndContinue:
            // `handle(_:using:)` consumes this transition. Fail closed if a future caller ever
            // forwards it here instead of allowing an unbound route to remain replayable.
            durableStore.remove(deduplicationKey: action.deduplicationKey)
            recordCompletion(action.deduplicationKey)
        }
    }

    private func enqueue(_ action: ClaimablePaymentNotificationAction) {
        guard !completedKeys.contains(action.deduplicationKey),
              pendingKeys.insert(action.deduplicationKey).inserted
        else { return }
        pending.append(action)
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
    func deliveredRemoteMessageNotifications() async -> [RemoteMessageNotificationRecord]
    func activeInboxNotifications() async -> [NotificationInboxAlertRecord]
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

    func deliveredRemoteMessageNotifications() async -> [RemoteMessageNotificationRecord] {
        await center.deliveredNotifications().compactMap { notification in
            guard let notice = RemoteMessageAvailableNotification(
                notification.request.content.userInfo
            ) else { return nil }
            return RemoteMessageNotificationRecord(
                requestIdentifier: notification.request.identifier, notice: notice
            )
        }
    }

    func activeInboxNotifications() async -> [NotificationInboxAlertRecord] {
        async let pending = center.pendingNotificationRequests()
        async let delivered = center.deliveredNotifications()
        let (requests, notifications) = await (pending, delivered)
        return requests.compactMap {
            inboxRecord($0, location: .pending, deliveredAt: nil)
        } + notifications.compactMap {
            inboxRecord($0.request, location: .delivered, deliveredAt: $0.date)
        }
    }

    private func inboxRecord(
        _ request: UNNotificationRequest,
        location: VisibleMessageNotificationRecord.Location, deliveredAt: Date?
    ) -> NotificationInboxAlertRecord? {
        let payload = request.content.userInfo
        guard let type = payload["type"] as? String,
              !type.hasPrefix("messaging."), !type.hasPrefix("message."),
              !type.hasPrefix("call.") || type == "call.missed",
              let id = MessageNotificationContract.canonicalUUID(payload["notification_id"] as? String)
        else { return nil }
        let isRecovered = type == NotificationInboxRecoveryPolicy.localType
        let missed = type == "call.missed" || (isRecovered && payload["original_type"] as? String == "call.missed")
        return NotificationInboxAlertRecord(
            requestIdentifier: request.identifier, notificationID: id,
            callID: missed ? MessageNotificationContract.canonicalUUID(payload["call_id"] as? String) : nil,
            ownerFingerprint: MessageNotificationContract.accountFingerprint(for: payload["recipient_user_id"] as? String),
            isRecovered: isRecovered,
            createdAt: (payload["created_at"] as? String).flatMap { CallLifecyclePolicy.serverTimestamp($0) }
                ?? deliveredAt ?? .distantPast,
            location: location
        )
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
    private var publicationOwnerFingerprint: String?
    // Closes the gap before the OS exposes a just-delivered remote alert in its delivered list.
    // The delivered list is the durable source across process death; this cache is bounded.
    private var systemAlertKeys: [String] = []
    private var foregroundAlertKeys: [String] = []

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
        let descriptors = descriptors.filter {
            publicationOwnerFingerprint == nil || $0.accountFingerprint == publicationOwnerFingerprint
        }
        guard !descriptors.isEmpty else { return 0 }
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
        let remoteNotifications = await center.deliveredRemoteMessageNotifications()
        // The system-center read suspends. Ownership may enter quarantine while it is in flight;
        // a stale plan must not remove notifications that now belong to a recovered account.
        guard publicationIsPermitted(expectedGeneration), !Task.isCancelled else { return 0 }
        let incomingOwners = Set(descriptors.map(\.accountFingerprint))
        let remoteKeys = Set(remoteNotifications.filter {
            incomingOwners.contains($0.notice.accountFingerprint)
        }.map { $0.notice.deduplicationKey }).union(systemAlertKeys)
        let duplicateLocalRecords = activeNotifications.filter { record in
            guard incomingOwners.contains(record.accountFingerprint),
                  let version = record.version else { return false }
            return remoteKeys.contains("\(record.accountFingerprint):\(version.messageDigest)")
        }
        let plan = VisibleMessageNotificationPublicationPolicy.plan(
            active: activeNotifications.filter { !duplicateLocalRecords.contains($0) },
            incoming: descriptors
        )
        let recordsToRemove = plan.recordsToRemove + duplicateLocalRecords
        let pendingIdentifiers = Set(recordsToRemove.compactMap {
            $0.location == .pending ? $0.requestIdentifier : nil
        }).sorted()
        let deliveredIdentifiers = Set(recordsToRemove.compactMap {
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
            let remoteKey = "\(descriptor.accountFingerprint):\(descriptor.version.messageDigest)"
            if systemAlertKeys.contains(remoteKey) || remoteKeys.contains(remoteKey) {
                continue
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
                guard publicationIsPermitted(expectedGeneration), !Task.isCancelled,
                      !systemAlertKeys.contains(remoteKey) else {
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

    func recordSystemAlert(_ notice: RemoteMessageAvailableNotification, ownerUserID: String) async {
        guard publicationEnabled,
              notice.recipientUserID == MessageNotificationContract.canonicalUUID(ownerUserID),
              publicationOwnerFingerprint == nil || notice.accountFingerprint == publicationOwnerFingerprint
        else { return }
        let generation = publicationGeneration
        let key = notice.deduplicationKey
        guard !foregroundAlertKeys.contains(key) else { return }
        systemAlertKeys.removeAll { $0 == key }
        systemAlertKeys.append(key)
        if systemAlertKeys.count > 256 { systemAlertKeys.removeFirst(systemAlertKeys.count - 256) }
        await removeLocalCopies(of: [key], generation: generation)
    }

    func recordForegroundDelivery(_ notice: RemoteMessageAvailableNotification) {
        let key = notice.deduplicationKey
        systemAlertKeys.removeAll { $0 == key }
        foregroundAlertKeys.removeAll { $0 == key }
        foregroundAlertKeys.append(key)
        if foregroundAlertKeys.count > 256 {
            foregroundAlertKeys.removeFirst(foregroundAlertKeys.count - 256)
        }
    }

    private func removeLocalCopies(of keys: Set<String>, generation: UInt64) async {
        let active = await center.activeMessageNotifications()
        guard publicationIsPermitted(generation) else { return }
        let duplicates = active.filter {
            guard let version = $0.version else { return false }
            return keys.contains("\($0.accountFingerprint):\(version.messageDigest)")
        }
        center.removePendingRequests(withIdentifiers: duplicates.filter {
            $0.location == .pending
        }.map(\.requestIdentifier))
        center.removeDeliveredNotifications(withIdentifiers: duplicates.filter {
            $0.location == .delivered
        }.map(\.requestIdentifier))
    }

    func reconcileRemoteNotifications(
        messages: [LocalMessage], ownerUserID: String,
        suppressedConversationID: String?, mutedConversationIDs: Set<String>
    ) async {
        guard publicationEnabled,
              publicationOwnerFingerprint == nil
                || MessageNotificationContract.accountFingerprint(for: ownerUserID) == publicationOwnerFingerprint
        else { return }
        let generation = publicationGeneration
        let records = await center.deliveredRemoteMessageNotifications()
        guard publicationIsPermitted(generation) else { return }
        let identifiers = RemoteMessageNotificationReconciliationPolicy.identifiersToRemove(
            records: records, messages: messages, ownerUserID: ownerUserID,
            suppressedConversationID: suppressedConversationID,
            mutedConversationIDs: mutedConversationIDs
        )
        if !identifiers.isEmpty { center.removeDeliveredNotifications(withIdentifiers: identifiers) }
        let ownedKeys = Set(records.filter {
            $0.notice.recipientUserID == MessageNotificationContract.canonicalUUID(ownerUserID)
        }.map { $0.notice.deduplicationKey })
        if !ownedKeys.isEmpty { await removeLocalCopies(of: ownedKeys, generation: generation) }
    }

    func beginPrivacyQuarantine() {
        publicationGeneration &+= 1
        publicationEnabled = false
        publicationOwnerFingerprint = nil
        systemAlertKeys.removeAll()
        foregroundAlertKeys.removeAll()
        schedulingTail?.cancel()
        schedulingTail = nil
    }

    func resumeAfterOwnershipRecovery(for ownerUserID: String? = nil) {
        publicationGeneration &+= 1
        publicationOwnerFingerprint = MessageNotificationContract.accountFingerprint(for: ownerUserID)
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

struct RemoteNotificationRegistrationRetryState: Equatable, Sendable {
    private(set) var isNeeded = false

    mutating func recordFailure() {
        isNeeded = true
    }

    mutating func recordToken(provider: String) {
        // PushKit credentials are delivered independently and cannot prove that ordinary APNs
        // registration recovered after application(_:didFailToRegisterForRemoteNotificationsWithError:).
        guard provider == "apns" else { return }
        isNeeded = false
    }
}

enum PushRegistrationRetryDecision: Equatable, Sendable {
    case retry(after: TimeInterval)
    case stop
}

enum PushRegistrationRetryPolicy {
    private static let exponentialDelays: [TimeInterval] = [2, 4, 8]
    private static let maximumDelay: TimeInterval = 300
    private static let durableDelays: [TimeInterval] = [
        60, 5 * 60, 15 * 60, 30 * 60, 60 * 60, 2 * 60 * 60, 4 * 60 * 60, 6 * 60 * 60,
    ]
    private static let maximumDurableDelay: TimeInterval = 6 * 60 * 60

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

    /// Once the short foreground burst is exhausted, retain a low-frequency recovery lane. The
    /// first delayed attempt is never earlier than one minute and later failures cap at six hours,
    /// preventing both permanent registration loss and a battery/network hot loop.
    static func durableRetryDelay(
        failureCount: Int,
        minimumDelay: TimeInterval,
        jitterUnitInterval: Double = Double.random(in: 0 ... 1)
    ) -> TimeInterval {
        let index = min(max(0, failureCount - 1), durableDelays.count - 1)
        let floor = max(60, min(maximumDurableDelay, minimumDelay))
        let base = max(durableDelays[index], floor)
        let jitter = min(1, max(0, jitterUnitInterval))
        return min(maximumDurableDelay, base * (1 + (0.1 * jitter)))
    }

    static func isDurablyRetryable(_ error: Error) -> Bool {
        if let urlError = error as? URLError,
           connectivityGatedURLErrorCodes.contains(urlError.code) {
            return true
        }
        return isRetryable(error)
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
        let operation: Operation
    }

    private struct DeferredFlight {
        let id: UUID
        let task: Task<Void, Never>
    }

    private struct RetryRecord: Codable, Equatable, Sendable {
        let tokenFingerprint: String
        let failureCount: Int
        let nextAttemptAt: TimeInterval
    }

    private enum ExecutionResult: Equatable, Sendable {
        case registered
        case failed(retryable: Bool, minimumDelay: TimeInterval)
        case cancelled
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private let retryStorageKey: String
    private let receiptLifetime: TimeInterval
    private let now: @Sendable () -> Date
    private let sleeper: Sleeper
    private let deferredSleeper: Sleeper
    private let jitter: @Sendable () -> Double
    private var inFlight: [RegistrationKey: Flight] = [:]
    private var deferredFlights: [RegistrationKey: DeferredFlight] = [:]

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "kit-pay-push-registration-receipts-v1",
        retryStorageKey: String = "kit-pay-push-registration-retries-v1",
        receiptLifetime: TimeInterval = 7 * 24 * 60 * 60,
        now: @escaping @Sendable () -> Date = { Date() },
        sleeper: @escaping Sleeper = { delay in
            try await Task<Never, Never>.sleep(for: .seconds(delay))
        },
        deferredSleeper: @escaping Sleeper = { delay in
            try await Task<Never, Never>.sleep(for: .seconds(delay))
        },
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0 ... 1) }
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.retryStorageKey = retryStorageKey
        self.receiptLifetime = receiptLifetime
        self.now = now
        self.sleeper = sleeper
        self.deferredSleeper = deferredSleeper
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
            removeRetryRecord(for: key)
            deferredFlights.removeValue(forKey: key)?.task.cancel()
            return .alreadyRegistered
        }
        if receipts.removeValue(forKey: key.receiptKey) != nil {
            saveRegistrationReceipts(receipts)
        }
        if let flight = inFlight[key] {
            return await finish(flight: flight, for: key)
        }

        // A newly issued token supersedes an older token for the same account/provider.
        let staleKeys = Set(inFlight.keys).union(deferredFlights.keys).filter {
            $0.accountFingerprint == key.accountFingerprint
                && $0.provider == key.provider
                && $0.tokenFingerprint != key.tokenFingerprint
        }
        for staleKey in staleKeys {
            inFlight.removeValue(forKey: staleKey)?.task.cancel()
            deferredFlights.removeValue(forKey: staleKey)?.task.cancel()
        }

        var retryRecords = registrationRetryRecords()
        if let retryRecord = retryRecords[key.receiptKey],
           retryRecord.tokenFingerprint != key.tokenFingerprint {
            retryRecords.removeValue(forKey: key.receiptKey)
            saveRegistrationRetryRecords(retryRecords)
        }
        if let retryRecord = retryRecords[key.receiptKey],
           retryRecord.tokenFingerprint == key.tokenFingerprint,
           retryRecord.nextAttemptAt > now().timeIntervalSince1970 {
            ensureDeferredRetry(
                for: key,
                record: retryRecord,
                operation: operation
            )
            return .deferred
        }

        deferredFlights.removeValue(forKey: key)?.task.cancel()
        let flightID = UUID()
        let sleeper = self.sleeper
        let jitter = self.jitter
        let task = Task {
            await Self.execute(operation: operation, sleeper: sleeper, jitter: jitter)
        }
        let flight = Flight(id: flightID, task: task, operation: operation)
        inFlight[key] = flight
        return await finish(flight: flight, for: key)
    }

    /// Connectivity recovery is a trusted wake signal, not permission to spin. It cancels the
    /// sleeping task and makes the durable record due; the caller must still replay Apple's cached
    /// token, which re-enters normal single-flight registration and authentication checks.
    func expediteDeferredRetries(accountID: String) {
        let accountFingerprint = Self.fingerprint(accountID.lowercased())
        let prefix = "\(accountFingerprint)."
        var records = registrationRetryRecords()
        var changed = false
        let matchingReceiptKeys = records.keys.filter { $0.hasPrefix(prefix) }
        for receiptKey in matchingReceiptKeys {
            guard let record = records[receiptKey] else { continue }
            records[receiptKey] = RetryRecord(
                tokenFingerprint: record.tokenFingerprint,
                failureCount: record.failureCount,
                nextAttemptAt: now().timeIntervalSince1970
            )
            changed = true
        }
        if changed { saveRegistrationRetryRecords(records) }
        let matchingKeys = deferredFlights.keys.filter {
            $0.accountFingerprint == accountFingerprint
        }
        for key in matchingKeys {
            deferredFlights.removeValue(forKey: key)?.task.cancel()
        }
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
            deferredFlights.removeValue(forKey: key)?.task.cancel()
        }
        let deferredKeys = deferredFlights.keys.filter {
            $0.accountFingerprint == accountFingerprint
                && (provider == nil || $0.provider == provider)
        }
        for key in deferredKeys {
            deferredFlights.removeValue(forKey: key)?.task.cancel()
        }

        var receipts = registrationReceipts()
        let prefix = "\(accountFingerprint)."
        receipts = receipts.filter { receiptKey, _ in
            guard receiptKey.hasPrefix(prefix) else { return true }
            guard let provider else { return false }
            return receiptKey != "\(prefix)\(provider)"
        }
        saveRegistrationReceipts(receipts)

        var retryRecords = registrationRetryRecords()
        retryRecords = retryRecords.filter { receiptKey, _ in
            guard receiptKey.hasPrefix(prefix) else { return true }
            guard let provider else { return false }
            return receiptKey != "\(prefix)\(provider)"
        }
        saveRegistrationRetryRecords(retryRecords)
    }

    func cancelAll() {
        inFlight.values.forEach { $0.task.cancel() }
        inFlight.removeAll()
        deferredFlights.values.forEach { $0.task.cancel() }
        deferredFlights.removeAll()
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
            removeRetryRecord(for: key)
            deferredFlights.removeValue(forKey: key)?.task.cancel()
            return .registered
        case .failed(let retryable, let minimumDelay):
            guard retryable else {
                removeRetryRecord(for: key)
                deferredFlights.removeValue(forKey: key)?.task.cancel()
                return .failed
            }
            var records = registrationRetryRecords()
            let previousFailureCount = records[key.receiptKey].flatMap { record in
                record.tokenFingerprint == key.tokenFingerprint ? record.failureCount : nil
            } ?? 0
            let failureCount = min(Int.max - 1, max(0, previousFailureCount)) + 1
            let delay = PushRegistrationRetryPolicy.durableRetryDelay(
                failureCount: failureCount,
                minimumDelay: minimumDelay,
                jitterUnitInterval: jitter()
            )
            let record = RetryRecord(
                tokenFingerprint: key.tokenFingerprint,
                failureCount: failureCount,
                nextAttemptAt: now().addingTimeInterval(delay).timeIntervalSince1970
            )
            records[key.receiptKey] = record
            saveRegistrationRetryRecords(records)
            ensureDeferredRetry(for: key, record: record, operation: flight.operation)
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
                guard try await operation() else {
                    return .failed(retryable: true, minimumDelay: 900)
                }
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
                        retryable: PushRegistrationRetryPolicy.isDurablyRetryable(error),
                        minimumDelay: PushRegistrationRetryPolicy.cooldownAfterStopping(for: error)
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

    private func registrationRetryRecords() -> [String: RetryRecord] {
        guard let data = defaults.data(forKey: retryStorageKey),
              let records = try? JSONDecoder().decode([String: RetryRecord].self, from: data)
        else { return [:] }
        let valid = records.filter { receiptKey, record in
            !receiptKey.isEmpty
                && MessageNotificationContract.isIdentifierDigest(record.tokenFingerprint)
                && record.failureCount > 0
                && record.nextAttemptAt.isFinite
        }
        if valid.count != records.count { saveRegistrationRetryRecords(valid) }
        return valid
    }

    private func saveRegistrationRetryRecords(_ records: [String: RetryRecord]) {
        guard !records.isEmpty else {
            defaults.removeObject(forKey: retryStorageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: retryStorageKey)
    }

    private func removeRetryRecord(for key: RegistrationKey) {
        var records = registrationRetryRecords()
        guard records.removeValue(forKey: key.receiptKey) != nil else { return }
        saveRegistrationRetryRecords(records)
    }

    private func ensureDeferredRetry(
        for key: RegistrationKey,
        record: RetryRecord,
        operation: @escaping Operation
    ) {
        guard deferredFlights[key] == nil else { return }
        let delay = max(0, record.nextAttemptAt - now().timeIntervalSince1970)
        let flightID = UUID()
        let deferredSleeper = self.deferredSleeper
        let task = Task { [weak self] in
            do {
                try await deferredSleeper(delay)
                try Task.checkCancellation()
            } catch {
                return
            }
            await self?.runDeferredRetry(
                for: key,
                expectedFlightID: flightID,
                expectedRecord: record,
                operation: operation
            )
        }
        deferredFlights[key] = DeferredFlight(id: flightID, task: task)
    }

    private func runDeferredRetry(
        for key: RegistrationKey,
        expectedFlightID: UUID,
        expectedRecord: RetryRecord,
        operation: @escaping Operation
    ) async {
        guard deferredFlights[key]?.id == expectedFlightID else { return }
        deferredFlights.removeValue(forKey: key)
        guard registrationRetryRecords()[key.receiptKey] == expectedRecord,
              !inFlight.keys.contains(key)
        else { return }

        let flightID = UUID()
        let sleeper = self.sleeper
        let jitter = self.jitter
        let task = Task {
            await Self.execute(operation: operation, sleeper: sleeper, jitter: jitter)
        }
        let flight = Flight(id: flightID, task: task, operation: operation)
        inFlight[key] = flight
        _ = await finish(flight: flight, for: key)
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
    static let kitCallRemoteParticipantConnected = Notification.Name(
        "africa.kit.pay.call-remote-participant-connected"
    )
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

private extension IncomingCallPublicationRetirement {
    init(callKitReason: CXCallEndedReason) {
        switch callKitReason {
        case .unanswered:
            self = .naturallyExpired
        case .remoteEnded:
            self = .terminal(.remoteEnded)
        case .answeredElsewhere:
            self = .terminal(.answeredElsewhere)
        case .declinedElsewhere:
            self = .terminal(.declinedElsewhere)
        case .failed:
            self = .terminal(.failed)
        @unknown default:
            self = .terminal(.failed)
        }
    }

    var callKitReason: CXCallEndedReason {
        switch self {
        case .naturallyExpired:
            return .unanswered
        case .terminal(.remoteEnded):
            return .remoteEnded
        case .terminal(.answeredElsewhere):
            return .answeredElsewhere
        case .terminal(.declinedElsewhere):
            return .declinedElsewhere
        case .terminal(.failed):
            return .failed
        }
    }
}

private extension CallTerminalPushDisposition {
    var callKitReason: CXCallEndedReason {
        publicationRetirement.callKitReason
    }
}

final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate, PKPushRegistryDelegate {
    static let shared = NotificationCoordinator()

    private struct QuarantinedIncomingCall {
        let push: IncomingCallPush
        let deadline: CallRingDeadline
        var verificationEventID: UUID?
        var verificationFailureCount: Int
        var verificationRetryNotBefore: TimeInterval?
    }

    private let callProvider: CXProvider
    private let callController = CXCallController()
    private let callAudioLogger = Logger(
        subsystem: "africa.kit.pay.ios",
        category: "CallKitAudio"
    )
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
    /// Owns the asynchronous gap between PushKit delivery and CallKit's report completion. A
    /// terminal signal revokes that exact publication synchronously, and its bounded tombstone
    /// prevents a duplicate VoIP push from recreating an already-finished ring.
    private var incomingCallPublicationGate = IncomingCallPublicationGate()
    /// Binds CallKit's UUID-less audio callbacks to the exact primary Answer/Start action and
    /// fences callbacks queued before a deactivate, reset, or account transition.
    private var callKitAudioSessionGate = CallKitAudioSessionGate()
    /// Set when Apple reports that APNs registration failed.
    ///
    /// Registration was previously attempted exactly once per sign-in and the failure callback was
    /// empty, so a device that was offline or transiently rejected at that moment never asked
    /// again: alerts, background message wakes and call-state sync stayed dead for the rest of the
    /// session, with no token cached to replay. Connectivity recovery now retries.
    private var remoteRegistrationRetryState = RemoteNotificationRegistrationRetryState()

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
        callKitAudioSessionGate.deactivate()
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
        guard remoteRegistrationRetryState.isNeeded, registrationEnabled else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    @MainActor
    fileprivate func recordRemoteRegistrationFailure() {
        remoteRegistrationRetryState.recordFailure()
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
        NotificationInboxRecoveryCoordinator.shared.quarantine()
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
        VisibleMessageNotificationCoordinator.shared.resumeAfterOwnershipRecovery(for: accountID)
        NotificationInboxRecoveryCoordinator.shared.resume(for: accountID)
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
        NotificationInboxRecoveryCoordinator.shared.quarantine()
        suppressPushTokenInvalidation = true
        UIApplication.shared.unregisterForRemoteNotifications()
        voipRegistry?.desiredPushTypes = []
        pushTokens.remove(provider: "apns")
        pushTokens.remove(provider: "apns_voip")
        discardQuarantinedIncomingCalls()
        for callUUID in incomingCallPublicationGate.pendingCallUUIDs {
            clearCall(callUUID)
            callProvider.reportCall(with: callUUID, endedAt: Date(), reason: .failed)
        }
        callKitAudioSessionGate.reset()
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
        NotificationInboxRecoveryCoordinator.shared.quarantine()
        callRegistryGeneration &+= 1
        invalidateCallKitAudio(resetSounds: true)
        let activeCalls = backendCallIds
        let pendingIncomingCallUUIDs = incomingCallPublicationGate.pendingCallUUIDs
        ringExpiryTasks.values.forEach { $0.cancel() }
        ringExpiryTasks.removeAll()
        discardQuarantinedIncomingCalls()
        for (callUUID, _) in activeCalls {
            clearCall(callUUID)
            callProvider.reportCall(with: callUUID, endedAt: Date(), reason: .failed)
        }
        for callUUID in pendingIncomingCallUUIDs where activeCalls[callUUID] == nil {
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
        callKitAudioSessionGate.reset()
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
        NotificationInboxRecoveryCoordinator.shared.quarantine()
        callRegistryGeneration &+= 1
        verificationRetryTasks.values.forEach { $0.cancel() }
        verificationRetryTasks.removeAll()
        suppressPushTokenInvalidation = false

        let ownerIsUnproven = communicationOwnerFingerprint == nil
        let targetsCurrentOwner = targetFingerprint != nil
            && targetFingerprint == communicationOwnerFingerprint
        if ownerIsUnproven || targetsCurrentOwner {
            let visibleCallUUIDs = Set(backendCallIds.keys)
                .union(quarantinedIncomingCalls.keys)
                .union(incomingCallPublicationGate.pendingCallUUIDs)
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
        remoteRegistrationRetryState.recordToken(provider: registration.provider)
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
        clearCall(
            callUUID,
            publicationRetirement: IncomingCallPublicationRetirement(callKitReason: reason)
        )
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
        callKitAudioSessionGate.claimOwner(callUUID)
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
        guard let callUUID = callKitAudioSessionGate.ownerCallUUID,
              hasCurrentCallRegistryOwnership(callUUID),
              answeredCalls.contains(callUUID) || outgoingCalls.contains(callUUID)
        else { return nil }
        return callUUID
    }

    /// Re-applies CallKit-owned audio when the LiveKit room attaches after `didActivate`, or when
    /// the first activation attempt failed before the room existed. There is deliberately no timer:
    /// the authenticated room boundary is the deterministic second opportunity to reconcile.
    @MainActor
    func reconcileCallKitAudioSessionIfNeeded(callId: String) throws {
        guard registrationEnabled,
              !privacyQuarantineActive,
              let callUUID = UUID(uuidString: callId),
              currentCallKitAudioOwnerUUID() == callUUID,
              let ticket = callKitAudioSessionGate.reconciliationTicket(for: callUUID)
        else { return }
        try configureCallKitAudioSession(
            AVAudioSession.sharedInstance(),
            ticket: ticket,
            source: "room-attachment"
        )
    }

    @MainActor
    private func configureCallKitAudioSession(
        _ audioSession: AVAudioSession,
        ticket: CallKitAudioSessionGate.Ticket,
        source: String
    ) throws {
        guard callKitAudioSessionGate.accepts(ticket),
              currentCallKitAudioOwnerUUID() == ticket.ownerCallUUID
        else { return }
        do {
            try CallMediaCoordinator.shared.activateAudioSession(
                audioSession,
                video: videoCalls[ticket.ownerCallUUID]
            )
            guard callKitAudioSessionGate.markConfigured(ticket) else { return }
            CallMediaCoordinator.shared.callKitAudioSessionConfigurationSucceeded(
                callId: ticket.ownerCallUUID.uuidString.lowercased()
            )
            callSounds.callKitAudioDidActivate()
            callAudioLogger.info("call_audio_configured source=\(source, privacy: .public)")
        } catch {
            if callKitAudioSessionGate.markConfigurationFailed(ticket) {
                callSounds.callKitAudioDidDeactivate()
                callAudioLogger.error(
                    "call_audio_configuration_failed source=\(source, privacy: .public) error=\(error.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
            throw error
        }
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
              !requiresUnexpiredRing || !incoming.ringDeadline.isExpired()
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
                coordinator.clearCall(
                    callUUID,
                    publicationRetirement: .terminal(.declinedElsewhere)
                )
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
        clearCall(callUUID, publicationRetirement: .terminal(.declinedElsewhere))
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
        clearCall(callUUID, publicationRetirement: .terminal(.remoteEnded))
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
        let hasMatchingRevealedCall =
            backendCallIds[callUUID]?.caseInsensitiveCompare(callId) == .orderedSame
        switch CallAnsweredElsewherePolicy.disposition(
            hasPendingPublication: incomingCallPublicationGate.isPending(callUUID),
            hasQuarantinedIncomingCall: quarantinedIncomingCalls[callUUID] != nil,
            hasMatchingRevealedCall: hasMatchingRevealedCall,
            isLocallyAnswered: answeredCalls.contains(callUUID),
            isOutgoing: outgoingCalls.contains(callUUID)
        ) {
        case .ignore:
            return
        case .rememberTerminal:
            incomingCallPublicationGate.retire(
                callUUID: callUUID,
                as: .terminal(.answeredElsewhere)
            )
        case .retireOfferedCall:
            clearCall(callUUID, publicationRetirement: .terminal(.answeredElsewhere))
            callProvider.reportCall(with: callUUID, endedAt: Date(), reason: .answeredElsewhere)
        }
    }

    /// Applies the backend's terminal APNs lifecycle signal directly to CallKit. A remote caller
    /// can cancel before this device answers, so no LiveKit disconnect exists to end that native
    /// ringing surface. Remembering an event that wins the race with its VoIP ring also prevents
    /// the later PushKit publication callback from resurrecting an already-finished call.
    @MainActor
    func reportTerminalCallPush(_ push: CallTerminalPush) {
        guard let callUUID = UUID(uuidString: push.callId) else { return }
        let hasMatchingQuarantinedCall = quarantinedIncomingCalls[callUUID]?.push.callId
            .caseInsensitiveCompare(push.callId) == .orderedSame
        let hasMatchingIncomingCall = incomingCalls[callUUID]?.record.id
            .caseInsensitiveCompare(push.callId) == .orderedSame
        let hasMatchingBackendCall = backendCallIds[callUUID]?
            .caseInsensitiveCompare(push.callId) == .orderedSame
        switch CallTerminalPushPolicy.disposition(
            hasPendingPublication: incomingCallPublicationGate.isPending(callUUID),
            hasMatchingQuarantinedCall: hasMatchingQuarantinedCall,
            hasMatchingAuthenticatedCall: hasMatchingIncomingCall || hasMatchingBackendCall
        ) {
        case .rememberTerminal:
            incomingCallPublicationGate.retire(
                callUUID: callUUID,
                as: push.disposition.publicationRetirement
            )
        case .retireOfferedCall:
            clearCall(callUUID, publicationRetirement: push.disposition.publicationRetirement)
            callProvider.reportCall(
                with: callUUID,
                endedAt: Date(),
                reason: push.disposition.callKitReason
            )
        }
    }

    @MainActor
    private func clearCall(
        _ callUUID: UUID,
        publicationRetirement: IncomingCallPublicationRetirement = .terminal(.failed)
    ) {
        let callID = backendCallIds[callUUID] ?? callUUID.uuidString.lowercased()
        incomingCallPublicationGate.retire(callUUID: callUUID, as: publicationRetirement)
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
        callKitAudioSessionGate.releaseOwner(callUUID)
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
        let monotonicNow = CallMonotonicClock.now()
        let deadline = IncomingCallQuarantinePolicy.deadline(
            for: incoming,
            monotonicNow: monotonicNow
        )
        if let staleEventID = quarantinedIncomingCalls[callUUID]?.verificationEventID {
            pendingCallEvents.acknowledge(staleEventID)
        }
        verificationRetryTasks.removeValue(forKey: callUUID)?.cancel()
        quarantinedIncomingCalls[callUUID] = QuarantinedIncomingCall(
            push: incoming,
            deadline: deadline,
            verificationEventID: nil,
            verificationFailureCount: 0,
            verificationRetryNotBefore: nil
        )
        callAdmissionGenerations[callUUID] = callRegistryGeneration
        quarantineExpiryTasks.removeValue(forKey: callUUID)?.cancel()
        let seconds = deadline.remaining(at: monotonicNow)
        quarantineExpiryTasks[callUUID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(seconds))
            } catch {
                return
            }
            guard let self, self.quarantinedIncomingCalls[callUUID] != nil else { return }
            self.clearCall(callUUID, publicationRetirement: .naturallyExpired)
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
            let monotonicNow = CallMonotonicClock.now()
            guard !pending.deadline.isExpired(at: monotonicNow) else {
                clearCall(callUUID, publicationRetirement: .naturallyExpired)
                callProvider.reportCall(
                    with: callUUID,
                    endedAt: Date(),
                    reason: .unanswered
                )
                continue
            }
            guard pending.verificationEventID == nil else { continue }
            if let retryNotBefore = pending.verificationRetryNotBefore {
                guard retryNotBefore < pending.deadline.monotonicTime else { continue }
                if retryNotBefore > monotonicNow {
                    scheduleIncomingCallVerificationRetry(
                        callUUID: callUUID,
                        after: retryNotBefore - monotonicNow,
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
              !incoming.ringDeadline.isExpired()
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
        guard isAwaitingIncomingCallVerification(request),
              let pending = quarantinedIncomingCalls[request.push.callUUID]
        else { return }
        let retirement: IncomingCallPublicationRetirement = pending.deadline.isExpired()
            ? .naturallyExpired
            : .terminal(.failed)
        clearCall(request.push.callUUID, publicationRetirement: retirement)
        callProvider.reportCall(
            with: request.push.callUUID,
            endedAt: Date(),
            reason: retirement.callKitReason
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

        let monotonicNow = CallMonotonicClock.now()
        let remaining = pending.deadline.remaining(at: monotonicNow)
        guard remaining > 0 else {
            quarantinedIncomingCalls[request.push.callUUID] = pending
            clearCall(
                request.push.callUUID,
                publicationRetirement: .naturallyExpired
            )
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
            pending.verificationRetryNotBefore = pending.deadline.monotonicTime
            quarantinedIncomingCalls[request.push.callUUID] = pending
            return
        }
        pending.verificationRetryNotBefore = monotonicNow + retryDelay
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
        guard !incoming.ringDeadline.isExpired() else {
            clearCall(uuid, publicationRetirement: .naturallyExpired)
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
        let callUUID = incoming.callUUID
        let callID = incoming.record.id
        ringExpiryTasks.removeValue(forKey: callUUID)?.cancel()
        let seconds = incoming.ringDeadline.remaining()
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
            self.clearCall(callUUID, publicationRetirement: .naturallyExpired)
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
        Task { @MainActor in
            let payload = notification.request.content.userInfo
            if SecureMessagingRemoteWake.isMessageAvailable(payload) {
                // Foreground delivery uses the authenticated per-conversation local policy,
                // which can honor an open or muted thread. It does not render the generic alert.
                completionHandler([])
                if let wake = SecureMessagingRemoteWake(payload, requestsForegroundMessageAlert: true) {
                    if let notice = wake.messageAvailable {
                        VisibleMessageNotificationCoordinator.shared.recordForegroundDelivery(notice)
                    }
                    _ = await SecureMessagingWakeDispatcher.shared.dispatch(wake)
                }
                return
            }
            guard registrationEnabled, !privacyQuarantineActive else {
                completionHandler([])
                return
            }
            if payload["recipient_user_id"] != nil,
               !RecipientBoundRemoteNotificationPolicy.permits(
                   payload, ownerFingerprint: communicationOwnerFingerprint
               ) {
                completionHandler([])
                return
            }
            completionHandler([.banner, .badge, .sound, .list])
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let completion = NotificationSystemResponseCompletion(completionHandler)
        Task { @MainActor in
            handleNotificationResponse(response, completion: completion)
        }
    }

    @MainActor
    private func handleNotificationResponse(
        _ response: UNNotificationResponse,
        completion: NotificationSystemResponseCompletion
    ) {
        let content = response.notification.request.content
        if SecureMessagingRemoteWake.isMessageAvailable(content.userInfo) {
            completion.complete()
            if let wake = SecureMessagingRemoteWake(
                content.userInfo, isSystemAlertDelivery: true, isUserTap: true
            ) {
                Task { _ = await SecureMessagingWakeDispatcher.shared.dispatch(wake) }
            }
            return
        }
        if content.userInfo["recipient_user_id"] != nil,
           let communicationOwnerFingerprint,
           !RecipientBoundRemoteNotificationPolicy.permits(
               content.userInfo, ownerFingerprint: communicationOwnerFingerprint
           ) {
            completion.complete()
            return
        }
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let tap = NotificationInboxTap(content.userInfo) {
            NotificationInboxTapDispatcher.persistBeforeCompletingSystemResponse(tap)
            completion.complete()
            Task { await NotificationInboxTapDispatcher.shared.replayPending() }
            return
        }
        let userText = (response as? UNTextInputNotificationResponse)?.userText
        let messageAction = MessageNotificationResponsePolicy.action(
            actionIdentifier: response.actionIdentifier,
            requestIdentifier: response.notification.request.identifier,
            categoryIdentifier: content.categoryIdentifier,
            threadIdentifier: content.threadIdentifier,
            userInfo: content.userInfo,
            userText: userText
        )
        let claimAction = ClaimablePaymentNotificationResponsePolicy.action(
            actionIdentifier: response.actionIdentifier,
            categoryIdentifier: content.categoryIdentifier,
            threadIdentifier: content.threadIdentifier,
            userInfo: content.userInfo
        ).flatMap { action in
            // A warm process has already proved the account owning its APNs registration. A cold
            // launch remains deliberately unbound until AppModel restores one exact session.
            guard registrationEnabled,
                  !privacyQuarantineActive,
                  let communicationOwnerFingerprint
            else { return action }
            return action.bound(toAccountFingerprint: communicationOwnerFingerprint)
        }
        let disposition = NotificationResponseDispositionPolicy.disposition(
            messageAction: messageAction,
            claimAction: claimAction,
            registrationEnabled: registrationEnabled,
            privacyQuarantineActive: privacyQuarantineActive
        )

        switch disposition {
        case .message(let action):
            if disposition.completesBeforeRouting {
                // A default tap foregrounds the app. Release UIKit immediately, then let the
                // actor retain the route while AppModel restores protected/account-bound state.
                // The synchronous opaque write closes the termination gap before this callback.
                MessageNotificationActionDispatcher.persistBeforeCompletingSystemResponse(action)
                completion.complete()
                Task { await MessageNotificationActionDispatcher.shared.dispatch(action) }
                return
            }
            Task {
                await MessageNotificationActionDispatcher.shared.dispatch(action)
                completion.complete()
            }
        case .claim(let action):
            ClaimablePaymentNotificationActionDispatcher
                .persistBeforeCompletingSystemResponse(action)
            completion.complete()
            Task { await ClaimablePaymentNotificationActionDispatcher.shared.dispatch(action) }
        case .opaqueWake:
            NotificationCenter.default.post(
                name: .kitRemoteWakeReceived,
                object: content.userInfo
            )
            completion.complete()
        case .ignore:
            completion.complete()
        }
    }

    @MainActor
    func clearMessageNotifications(
        accountFingerprint: String? = nil,
        conversationID: String? = nil,
        messageIDs: [String] = []
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
                conversationID: canonicalConversationID,
                messageIDs: messageIDs
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
                conversationID: canonicalConversationID,
                messageIDs: messageIDs
            ) ? request.identifier : nil
        }
        if !deliveredIdentifiers.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: deliveredIdentifiers)
        }
    }

    /// Claim APNs do not include an account fingerprint, so they cannot be filtered safely after
    /// ownership changes. Retire the entire category at a privacy/account boundary rather than
    /// allowing an old delivered notification to be rebound to a replacement session.
    @MainActor
    func clearClaimablePaymentNotifications() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let pendingIdentifiers = pending.compactMap { request in
            request.content.categoryIdentifier
                == ClaimablePaymentNotificationContract.categoryIdentifier
                ? request.identifier
                : nil
        }
        if !pendingIdentifiers.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: pendingIdentifiers)
        }

        let delivered = await center.deliveredNotifications()
        let deliveredIdentifiers = delivered.compactMap { notification in
            notification.request.content.categoryIdentifier
                == ClaimablePaymentNotificationContract.categoryIdentifier
                ? notification.request.identifier
                : nil
        }
        if !deliveredIdentifiers.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: deliveredIdentifiers)
        }
    }

    private func shouldClearMessageNotification(
        requestIdentifier: String,
        content: UNNotificationContent,
        accountFingerprint: String?,
        conversationID: String?,
        messageIDs: [String]
    ) -> Bool {
        if SecureMessagingRemoteWake.isMessageAvailable(content.userInfo) {
            guard let notice = RemoteMessageAvailableNotification(content.userInfo) else {
                return conversationID == nil
            }
            if let accountFingerprint, notice.accountFingerprint != accountFingerprint {
                return false
            }
            // The remote envelope intentionally has no conversation ID. Only the caller's
            // authenticated local projection can prove that this message belongs to a thread.
            return conversationID == nil || messageIDs.contains(where: {
                MessageNotificationContract.canonicalUUID($0) == notice.messageID
            })
        }
        if ["call.missed", NotificationInboxRecoveryPolicy.localType].contains(content.userInfo["type"] as? String ?? ""),
           content.userInfo["recipient_user_id"] != nil,
           conversationID == nil {
            return accountFingerprint == nil || RecipientBoundRemoteNotificationPolicy.permits(
                content.userInfo, ownerFingerprint: accountFingerprint
            )
        }
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
        let alreadyTracked = callAdmissionGenerations[uuid] != nil
            || backendCallIds[uuid] != nil
            || quarantinedIncomingCalls[uuid] != nil
            || incomingCalls[uuid] != nil
        let publicationDisposition = incomingCallPublicationGate.begin(
            callUUID: uuid,
            generation: receivedGeneration,
            alreadyTracked: alreadyTracked,
            leaseExpired: incoming.callKitDisposition() == .reportAsUnanswered
        )
        if publicationDisposition == .authorized {
            // Claim this CallKit report before its asynchronous completion. End/answer-elsewhere
            // can now revoke the same generation even while the system call is being published.
            callAdmissionGenerations[uuid] = receivedGeneration
        }
        // PushKit identifies only an app-level token, not the currently recovered account. Report
        // promptly with generic metadata, then reveal/admit only after an authenticated lookup.
        let update = genericIncomingCallUpdate()
        callProvider.reportNewIncomingCall(with: uuid, update: update) { error in
            Task { @MainActor in
                let coordinator = NotificationCoordinator.shared
                let duplicateStillOwnsCallState = publicationDisposition == .duplicate
                    && !coordinator.incomingCallPublicationGate.isRetired(uuid)
                    && (coordinator.callAdmissionGenerations[uuid] != nil
                        || coordinator.backendCallIds[uuid] != nil
                        || coordinator.quarantinedIncomingCalls[uuid] != nil
                        || coordinator.incomingCalls[uuid] != nil)
                if error == nil,
                   publicationDisposition == .authorized,
                   coordinator.callRegistryGeneration == receivedGeneration,
                   coordinator.callAdmissionGenerations[uuid] == receivedGeneration,
                   coordinator.incomingCallPublicationGate.complete(
                       callUUID: uuid,
                       generation: receivedGeneration
                   ) {
                    // The phone is now ringing. Resolving the media host during the ring removes
                    // that handshake from the gap between answering and hearing the caller.
                    CallMediaPrewarmer.shared.prewarm()
                    coordinator.quarantine(incoming)
                    if coordinator.registrationEnabled, !coordinator.privacyQuarantineActive {
                        coordinator.requestVerificationForQuarantinedIncomingCalls()
                    }
                } else if error == nil,
                          !duplicateStillOwnsCallState {
                    // Still report every VoIP push to satisfy PushKit, but retire a stale/duplicate
                    // system surface immediately and never recreate app-owned ringing state.
                    let retirement = coordinator.incomingCallPublicationGate.retirement(for: uuid)
                        ?? .terminal(.failed)
                    coordinator.clearCall(uuid, publicationRetirement: retirement)
                    coordinator.callProvider.reportCall(
                        with: uuid,
                        endedAt: Date(),
                        reason: retirement.callKitReason
                    )
                } else if error != nil, publicationDisposition == .authorized {
                    coordinator.incomingCallPublicationGate.abandon(
                        callUUID: uuid,
                        generation: receivedGeneration
                    )
                    coordinator.failDeferredPrimaryAnswer(for: uuid)
                    if coordinator.callAdmissionGenerations[uuid] == receivedGeneration,
                       coordinator.backendCallIds[uuid] == nil,
                       coordinator.quarantinedIncomingCalls[uuid] == nil,
                       coordinator.incomingCalls[uuid] == nil {
                        coordinator.callAdmissionGenerations.removeValue(forKey: uuid)
                    }
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
        let callUUIDsToRetire = Set(calls.keys)
            .union(quarantinedIncomingCalls.keys)
            .union(incomingCallPublicationGate.pendingCallUUIDs)
        for callUUID in callUUIDsToRetire {
            incomingCallPublicationGate.retire(callUUID: callUUID)
        }
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
        callKitAudioSessionGate.reset()
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
        if (quarantinedIncomingCalls[action.callUUID] != nil
                || incomingCallPublicationGate.isPending(action.callUUID)),
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
        callKitAudioSessionGate.claimOwner(action.callUUID)
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
        let registryGeneration = callRegistryGeneration
        guard let ticket = callKitAudioSessionGate.beginSystemActivation() else {
            callSounds.callKitAudioDidDeactivate()
            callAudioLogger.error("call_audio_activation_waiting_for_exact_owner")
            return
        }
        guard currentCallKitAudioOwnerUUID() == ticket.ownerCallUUID else {
            callKitAudioSessionGate.releaseOwner(ticket.ownerCallUUID)
            callSounds.callKitAudioDidDeactivate()
            callAudioLogger.error("call_audio_activation_rejected_stale_owner")
            return
        }
        Task { @MainActor [weak self] in
            guard let self,
                  self.callKitAudioSessionGate.accepts(ticket),
                  self.callRegistryGeneration == registryGeneration,
                  self.currentCallKitAudioOwnerUUID() == ticket.ownerCallUUID
            else { return }
            do {
                try self.configureCallKitAudioSession(
                    audioSession,
                    ticket: ticket,
                    source: "callkit-activation"
                )
            } catch {
                guard self.callKitAudioSessionGate.accepts(ticket) else { return }
                await CallMediaCoordinator.shared.callKitAudioSessionConfigurationFailed(
                    callId: ticket.ownerCallUUID.uuidString.lowercased(),
                    error: error
                )
            }
        }
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        callKitAudioSessionGate.deactivate()
        let transitionGeneration = callKitAudioSessionGate.generation
        callSounds.callKitAudioDidDeactivate()
        callAudioLogger.info("call_audio_deactivated")
        Task { @MainActor [weak self] in
            guard let self,
                  self.callKitAudioSessionGate.generation == transitionGeneration,
                  self.callKitAudioSessionGate.phase == .inactive
            else { return }
            do {
                try CallMediaCoordinator.shared.deactivateAudioSession()
            } catch {
                guard self.callKitAudioSessionGate.generation == transitionGeneration else { return }
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
        MessagingBackgroundAttachmentUploader.shared.prepareForApplicationLaunch()
        NotificationCoordinator.shared.prepareForProtectedStateRestore()
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard MessagingBackgroundAttachmentUploader.handlesSession(identifier: identifier) else {
            completionHandler()
            return
        }
        MessagingBackgroundAttachmentUploader.shared.setBackgroundEventsCompletionHandler(
            completionHandler
        )
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
        if let wake = SecureMessagingRemoteWake(
            userInfo, isSystemAlertDelivery: application.applicationState != .active
        ) {
            Task {
                completionHandler(
                    await SecureMessagingWakeDispatcher.shared.dispatch(wake)
                )
            }
            return
        }
        if SecureMessagingRemoteWake.isMessageAvailable(userInfo) {
            completionHandler(.noData)
            return
        }
        if let terminalCall = CallTerminalPush(payload: userInfo) {
            NotificationCoordinator.shared.reportTerminalCallPush(terminalCall)
        }
        NotificationCenter.default.post(name: .kitRemoteWakeReceived, object: userInfo)
        completionHandler(.newData)
    }
}
