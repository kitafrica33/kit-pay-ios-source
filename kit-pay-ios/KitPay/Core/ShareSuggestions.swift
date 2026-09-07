import CryptoKit
import Foundation
import Intents

/// The app projects only delivery metadata into the suggestion worker. Plaintext bodies,
/// attachments, phone numbers and remote avatar URLs never cross this interface.
struct ShareSuggestionMessage: Equatable, Sendable {
    let id: UUID
    let conversationID: String
    let sentAt: Date?
    let state: String
    let isOutgoing: Bool
}

struct ShareSuggestionRecord: Equatable, Sendable {
    let interactionIdentifier: String
    let groupIdentifier: String
    let conversationIdentifier: String
    let recipientIdentifier: String
    let displayName: String
    let isGroup: Bool
    let sentAt: Date
}

enum ShareSuggestionPolicy {
    static let maximumSuggestions = 12
    static let retention: TimeInterval = 30 * 24 * 60 * 60
    static let groupPrefix = "kitpay-share-account-"

    static func isKnownGroupIdentifier(_ value: String) -> Bool {
        guard value.hasPrefix(groupPrefix) else { return false }
        let suffix = value.dropFirst(groupPrefix.count)
        return suffix.utf8.count == 64 && suffix.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    static func accountGroup(_ accountID: String) -> String {
        groupPrefix + digest("account\u{0}" + accountID)
    }

    static func conversationIdentifier(accountID: String, conversationID: String) -> String {
        "kitpay-share-conversation-" + digest(accountID + "\u{0}" + conversationID)
    }

    static func destination(
        conversationIdentifier: String?,
        accountID: String,
        destinations: [SharedInboxDestination]
    ) -> SharedInboxDestination? {
        guard let conversationIdentifier,
              validDirectory(accountID: accountID, destinations: destinations)
        else { return nil }
        return destinations.first { destination in
            guard let conversationID = destination.conversationID else { return false }
            return self.conversationIdentifier(accountID: accountID, conversationID: conversationID)
                == conversationIdentifier
        }
    }

    static func records(
        accountID: String,
        destinations: [SharedInboxDestination],
        messages: [ShareSuggestionMessage],
        now: Date
    ) -> [ShareSuggestionRecord]? {
        guard validDirectory(accountID: accountID, destinations: destinations) else { return nil }
        let rows = Dictionary(uniqueKeysWithValues: destinations.compactMap { destination in
            destination.conversationID.map { ($0, destination) }
        })
        var latest: [String: ShareSuggestionMessage] = [:]
        for message in messages {
            guard message.isOutgoing,
                  ["sent", "delivered", "read"].contains(message.state),
                  let sentAt = message.sentAt,
                  sentAt.timeIntervalSinceReferenceDate.isFinite, sentAt <= now,
                  now.timeIntervalSince(sentAt) < retention,
                  rows[message.conversationID] != nil
            else { continue }
            if let old = latest[message.conversationID], let oldDate = old.sentAt,
               oldDate > sentAt || (oldDate == sentAt && old.id.uuidString > message.id.uuidString) {
                continue
            }
            latest[message.conversationID] = message
        }
        let groupIdentifier = accountGroup(accountID)
        return latest.values.sorted {
            if $0.sentAt != $1.sentAt { return $0.sentAt! > $1.sentAt! }
            return $0.id.uuidString < $1.id.uuidString
        }.prefix(maximumSuggestions).compactMap { message in
            guard let row = rows[message.conversationID], let sentAt = message.sentAt else { return nil }
            return ShareSuggestionRecord(
                interactionIdentifier: "kitpay-share-send-" + digest(accountID + "\u{0}" + message.conversationID + "\u{0}" + message.id.uuidString.lowercased()),
                groupIdentifier: groupIdentifier,
                conversationIdentifier: conversationIdentifier(accountID: accountID, conversationID: message.conversationID),
                recipientIdentifier: "kitpay-share-recipient-" + digest(accountID + "\u{0}" + (row.recipientUserID ?? message.conversationID)),
                displayName: row.displayName,
                isGroup: row.kind == .group,
                sentAt: sentAt
            )
        }
    }

    private static func validDirectory(accountID: String, destinations: [SharedInboxDestination]) -> Bool {
        SharedInboxPolicy.canonicalAccountID(accountID) == accountID
            && destinations.count <= SharedInboxPolicy.maximumDestinations
            && Set(destinations.map(\.id)).count == destinations.count
            && destinations.allSatisfy(SharedInboxPolicy.isValidDestination)
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

protocol ShareSuggestionDonating: Sendable {
    func donate(_ record: ShareSuggestionRecord) async throws
    func delete(groupIdentifier: String) async throws
    func delete(identifiers: [String]) async throws
}

protocol ShareSuggestionGroupStoring: Sendable {
    func load() -> Set<String>
    func save(_ groups: Set<String>)
}

private struct SystemShareSuggestionDonor: ShareSuggestionDonating {
    func donate(_ record: ShareSuggestionRecord) async throws {
        let person = INPerson(
            personHandle: INPersonHandle(value: record.recipientIdentifier, type: .unknown),
            nameComponents: nil, displayName: record.displayName, image: nil,
            contactIdentifier: nil, customIdentifier: record.recipientIdentifier
        )
        let intent = INSendMessageIntent(
            recipients: [person], outgoingMessageType: .outgoingMessageText, content: nil,
            speakableGroupName: record.isGroup ? INSpeakableString(spokenPhrase: record.displayName) : nil,
            conversationIdentifier: record.conversationIdentifier, serviceName: "Kit Pay",
            sender: nil, attachments: nil
        )
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .outgoing
        interaction.identifier = record.interactionIdentifier
        interaction.groupIdentifier = record.groupIdentifier
        interaction.dateInterval = DateInterval(start: record.sentAt, duration: 0)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            interaction.donate { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    func delete(groupIdentifier: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            INInteraction.delete(with: groupIdentifier) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    func delete(identifiers: [String]) async throws {
        guard !identifiers.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            INInteraction.delete(with: identifiers) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}

private final class DefaultsShareSuggestionGroups: ShareSuggestionGroupStoring, @unchecked Sendable {
    private let key = "KitPay.ShareSuggestionGroups.v1"
    func load() -> Set<String> {
        Set((UserDefaults.standard.stringArray(forKey: key) ?? [])
            .filter(ShareSuggestionPolicy.isKnownGroupIdentifier))
    }
    func save(_ groups: Set<String>) { UserDefaults.standard.set(groups.sorted(), forKey: key) }
}

/// Synchronous revocation is separate from actor scheduling: a Task created before screen lock
/// or sign-out cannot reactivate suggestions merely by entering the actor after invalidation.
private final class ShareSuggestionRequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var accountID: String?

    func begin(accountID: String) -> ShareSuggestions.RequestToken {
        lock.withLock {
            generation &+= 1
            self.accountID = accountID
            return ShareSuggestions.RequestToken(generation: generation, accountID: accountID)
        }
    }
    func invalidate() -> UInt64 {
        lock.withLock { generation &+= 1; accountID = nil; return generation }
    }
    func suspend() {
        lock.withLock {
            // A UI transition must never supersede an already-requested hard privacy revoke.
            // Nil already blocks every refresh token; preserve its pending cleanup revision.
            guard accountID != nil else { return }
            generation &+= 1
            accountID = nil
        }
    }
    func allows(_ token: ShareSuggestions.RequestToken) -> Bool {
        lock.withLock { generation == token.generation && accountID == token.accountID }
    }
    func isRevoked(at revision: UInt64) -> Bool {
        lock.withLock { generation == revision && accountID == nil }
    }
}

actor ShareSuggestions {
    struct RequestToken: Sendable {
        fileprivate let generation: UInt64
        fileprivate let accountID: String
    }
    static let shared = ShareSuggestions()
    private nonisolated let gate = ShareSuggestionRequestGate()
    private let donor: any ShareSuggestionDonating
    private let store: any ShareSuggestionGroupStoring
    private let now: @Sendable () -> Date
    private var knownGroups: Set<String>
    private var needsStartupCleanup = true
    private var activeGroup: String?
    private var appliedRecords: [String: ShareSuggestionRecord] = [:]
    private var previousOperation: Task<Bool, Never>?
    private struct Snapshot: Equatable {
        let accountID: String
        let destinations: [SharedInboxDestination]
        let messages: [ShareSuggestionMessage]
    }
    private var cachedSnapshot: Snapshot?
    private var cachedRecords: [ShareSuggestionRecord] = []
    private var cacheCreatedAt = Date.distantPast
    private var cacheExpiresAt = Date.distantPast

    init(
        donor: any ShareSuggestionDonating = SystemShareSuggestionDonor(),
        store: any ShareSuggestionGroupStoring = DefaultsShareSuggestionGroups(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.donor = donor
        self.store = store
        self.now = now
        knownGroups = store.load()
    }

    /// Call synchronously only after validating the current account/privacy/destination snapshot,
    /// then capture the token in the Task that calls refresh. Never mint it inside a stale Task.
    nonisolated func beginRefresh(accountID: String) -> RequestToken? {
        guard SharedInboxPolicy.canonicalAccountID(accountID) == accountID else { return nil }
        return gate.begin(accountID: accountID)
    }

    nonisolated func invalidate() {
        let revision = gate.invalidate()
        Task { _ = await self.enqueue(records: [], token: nil, revokedRevision: revision) }
    }

    /// Leaving the app must not erase the recent recipients needed in another app's share
    /// sheet. Pause stale snapshot work while keeping previously authorized OS suggestions;
    /// account/privacy revocation still uses invalidate/revoke and removes those names.
    nonisolated func suspendRefresh() {
        gate.suspend()
    }

    @discardableResult
    func refresh(
        accountID: String?, destinations: [SharedInboxDestination],
        messages: [ShareSuggestionMessage], requestToken: RequestToken
    ) async -> Bool {
        guard accountID == requestToken.accountID, gate.allows(requestToken) else { return false }
        let snapshot = Snapshot(accountID: requestToken.accountID,
                                destinations: destinations, messages: messages)
        let currentDate = now()
        let records: [ShareSuggestionRecord]
        if snapshot == cachedSnapshot, currentDate >= cacheCreatedAt, currentDate < cacheExpiresAt {
            records = cachedRecords
        } else {
            guard let computed = ShareSuggestionPolicy.records(
                accountID: requestToken.accountID, destinations: destinations,
                messages: messages, now: currentDate
            ) else {
                guard gate.allows(requestToken) else { return false }
                let revision = gate.invalidate()
                return await enqueue(records: [], token: nil, revokedRevision: revision)
            }
            records = computed
            cachedSnapshot = snapshot
            cachedRecords = computed
            cacheCreatedAt = currentDate
            // Repeated state publication does not rehash the same history. Recompute exactly
            // when a future timestamp becomes eligible or a sent interaction ages out.
            cacheExpiresAt = messages.reduce(Date.distantFuture) { expiry, message in
                guard let sentAt = message.sentAt,
                      sentAt.timeIntervalSinceReferenceDate.isFinite else { return expiry }
                let boundary = sentAt > currentDate
                    ? sentAt : sentAt.addingTimeInterval(ShareSuggestionPolicy.retention)
                return boundary > currentDate ? min(expiry, boundary) : expiry
            }
        }
        return await enqueue(records: records, token: requestToken, revokedRevision: nil)
    }

    @discardableResult
    func revoke() async -> Bool {
        let revision = gate.invalidate()
        return await enqueue(records: [], token: nil, revokedRevision: revision)
    }

    nonisolated static func destination(
        conversationIdentifier: String?, accountID: String, destinations: [SharedInboxDestination]
    ) -> SharedInboxDestination? {
        ShareSuggestionPolicy.destination(conversationIdentifier: conversationIdentifier,
                                          accountID: accountID, destinations: destinations)
    }

    private func enqueue(
        records: [ShareSuggestionRecord], token: RequestToken?, revokedRevision: UInt64?
    ) async -> Bool {
        let previous = previousOperation
        let operation = Task { [weak self] in
            if let previous { _ = await previous.value }
            guard let self else { return false }
            return await self.apply(records: records, token: token, revokedRevision: revokedRevision)
        }
        previousOperation = operation
        return await operation.value
    }

    private func isCurrent(_ token: RequestToken?, _ revokedRevision: UInt64?) -> Bool {
        if let token { return gate.allows(token) }
        return revokedRevision.map { gate.isRevoked(at: $0) } ?? false
    }

    private func apply(
        records: [ShareSuggestionRecord], token: RequestToken?, revokedRevision: UInt64?
    ) async -> Bool {
        guard isCurrent(token, revokedRevision) else { return false }
        let requestedGroup = records.first?.groupIdentifier
        if token == nil {
            cachedSnapshot = nil
            cachedRecords.removeAll()
        }
        do {
            if needsStartupCleanup || requestedGroup != activeGroup || requestedGroup == nil {
                for group in knownGroups.sorted() {
                    try await donor.delete(groupIdentifier: group)
                    knownGroups.remove(group)
                    store.save(knownGroups)
                    if activeGroup == group { appliedRecords.removeAll(); activeGroup = nil }
                    guard isCurrent(token, revokedRevision) else { return false }
                }
                needsStartupCleanup = false
                activeGroup = requestedGroup
                appliedRecords.removeAll()
            }
            guard let requestedGroup else { return true }
            let requestedIDs = Set(records.map(\.interactionIdentifier))
            let removedIDs = Set(appliedRecords.keys).subtracting(requestedIDs)
            if !removedIDs.isEmpty {
                try await donor.delete(identifiers: removedIDs.sorted())
                for id in removedIDs { appliedRecords.removeValue(forKey: id) }
                guard isCurrent(token, revokedRevision) else { return false }
            }
            for record in records where appliedRecords[record.interactionIdentifier] != record {
                guard isCurrent(token, revokedRevision) else { return false }
                // Persist only an opaque cleanup group before the OS mutation. A crash after a
                // donation must leave enough identity for the next process to remove its names.
                knownGroups.insert(requestedGroup)
                store.save(knownGroups)
                try await donor.donate(record)
                appliedRecords[record.interactionIdentifier] = record
                guard isCurrent(token, revokedRevision) else { return false }
            }
            return true
        } catch {
            // Retain cleanup groups on failure. A future refresh/revoke retries removal; never
            // claim that Siri's names were removed when the platform completion reported error.
            return false
        }
    }
}
