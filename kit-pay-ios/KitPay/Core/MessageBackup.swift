import CryptoKit
import Foundation

/// How often Kit Pay automatically backs up encrypted chats to the user's iCloud.
enum MessageBackupFrequency: String, Codable, CaseIterable, Sendable {
    case off
    case daily
    case weekly
    case monthly

    var displayName: String {
        switch self {
        case .off: "Off"
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        }
    }

    var interval: TimeInterval? {
        switch self {
        case .off: nil
        case .daily: 24 * 60 * 60
        case .weekly: 7 * 24 * 60 * 60
        case .monthly: 30 * 24 * 60 * 60
        }
    }
}

/// Per-account backup settings persisted inside the encrypted local state.
/// Optional fields keep older encrypted state decodable.
struct MessageBackupPreferences: Codable, Hashable, Sendable {
    var frequency: MessageBackupFrequency = .off
    var includesMedia: Bool = false
    var lastBackupAt: Date?
    var lastBackupByteSize: Int?
    var lastBackupMessageCount: Int?
    var lastBackupGeneration: Int64?
    var lastBackupContentDigest: String?

    static let `default` = MessageBackupPreferences()

    // Synthesized Codable would throw on blobs written before a field existed;
    // decodeIfPresent keeps every historical shape readable.
    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        frequency = try container.decodeIfPresent(
            MessageBackupFrequency.self,
            forKey: .frequency
        ) ?? .off
        includesMedia = try container.decodeIfPresent(Bool.self, forKey: .includesMedia) ?? false
        lastBackupAt = try container.decodeIfPresent(Date.self, forKey: .lastBackupAt)
        lastBackupByteSize = try container.decodeIfPresent(Int.self, forKey: .lastBackupByteSize)
        lastBackupMessageCount = try container.decodeIfPresent(
            Int.self,
            forKey: .lastBackupMessageCount
        )
        lastBackupGeneration = try container.decodeIfPresent(
            Int64.self,
            forKey: .lastBackupGeneration
        )
        lastBackupContentDigest = try container.decodeIfPresent(
            String.self,
            forKey: .lastBackupContentDigest
        )
    }
}

enum MessageBackupSchedulePolicy {
    static func isBackupDue(
        frequency: MessageBackupFrequency,
        lastBackupAt: Date?,
        now: Date = Date()
    ) -> Bool {
        guard let interval = frequency.interval else { return false }
        guard let lastBackupAt else { return true }
        return now.timeIntervalSince(lastBackupAt) >= interval
    }
}

enum MessageBackupAutomaticRunResult: Equatable, Sendable {
    /// The schedule, connectivity, account state, or local-history policy did not request work.
    case notDue
    case succeeded
    case failed

    var backgroundTaskSucceeded: Bool { self != .failed }
}

/// Everything a restored device needs to rebuild chat history. Attachment plaintext is included
/// only for small inline blobs; large media stays re-downloadable via each message's descriptor.
struct MessageBackupPayload: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = MessageBackupPayload.currentSchemaVersion
    let userID: String
    let createdAt: Date
    let deviceName: String
    var conversations: [Conversation]
    var messages: [LocalMessage]
    var pinnedConversationIds: [String]?
    var mutedConversationIds: [String]?

    init(
        schemaVersion: Int = MessageBackupPayload.currentSchemaVersion,
        userID: String,
        createdAt: Date,
        deviceName: String,
        conversations: [Conversation],
        messages: [LocalMessage],
        pinnedConversationIds: [String]? = nil,
        mutedConversationIds: [String]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.userID = userID
        self.createdAt = createdAt
        self.deviceName = deviceName
        self.conversations = conversations
        self.messages = messages
        self.pinnedConversationIds = pinnedConversationIds
        self.mutedConversationIds = mutedConversationIds
    }

    static func snapshot(
        of state: PersistedState,
        userID: String,
        deviceName: String,
        includesMedia: Bool,
        createdAt: Date = Date()
    ) -> MessageBackupPayload {
        let conversationsByID = Dictionary(
            state.conversations.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let ownerUserID = userID.lowercased()
        // An outbox is intentionally never part of a backup. Match that boundary by retaining
        // only messages whose server submission or receipt is already committed; restoring a
        // queued/encrypting/sending/failed local item without its command could silently strand it.
        var messages = state.messages.filter { message in
            switch message.state {
            case .sent, .delivered, .read, .received:
                guard message.pendingAttachment == nil,
                    // Membership notices are projections of authenticated sync events, but the
                    // local message shape does not retain that server-event provenance. Exclude
                    // them instead of backing up a trusted namespace that restore cannot prove.
                    !SecureMessageReservedPrefixPolicy.beginsWithReservedPrefix(
                        message.body,
                        prefix: KitSystemMessage.prefix
                    )
                else { return false }
                // A message written before sender-bound history metadata existed remains useful
                // while its author is in the roster. Once that member departs, however, the
                // archive cannot prove the sender and validation would reject the whole backup.
                // Omit only that un-restorable legacy row; current-member and owner history stays.
                if let conversation = conversationsByID[message.conversationId] {
                    return MessageBackupValidationPolicy.isRestorableMessageSender(
                        message,
                        in: conversation,
                        ownerUserID: ownerUserID
                    )
                }
                return true
            case .queued, .encrypting, .sending, .failed:
                return false
            }
        }
        if !includesMedia {
            for index in messages.indices {
                messages[index].attachmentData = nil
            }
        }
        return MessageBackupPayload(
            userID: userID.lowercased(),
            createdAt: createdAt,
            deviceName: deviceName,
            conversations: state.conversations,
            messages: messages,
            pinnedConversationIds: state.pinnedConversationIds,
            mutedConversationIds: state.mutedConversationIds
        )
    }
}

enum MessageBackupError: LocalizedError, Equatable {
    case iCloudUnavailable
    case keyUnavailable
    case authenticationFailed
    case incompatibleBackup
    case invalidBackup
    case backupNotFound
    case accountMismatch
    case conflictRetryLimitExceeded

    var errorDescription: String? {
        switch self {
        case .iCloudUnavailable:
            "Sign in to iCloud in iPhone Settings to back up your encrypted chats."
        case .keyUnavailable:
            "The backup key could not be read from your iCloud Keychain."
        case .authenticationFailed:
            "This backup could not be authenticated with the key currently in iCloud Keychain. "
                + "Keep it and try again after iCloud Keychain finishes syncing."
        case .incompatibleBackup:
            "This backup cannot be safely restored by this version of Kit Pay."
        case .invalidBackup:
            "This backup file is damaged or incomplete."
        case .backupNotFound:
            "No Kit Pay chat backup was found in this iCloud account."
        case .accountMismatch:
            "This backup belongs to a different Kit Pay account."
        case .conflictRetryLimitExceeded:
            "Your chat backup changed on another device. Please try again."
        }
    }
}

/// Hard limits and ownership checks applied before an archive can be uploaded or merged into the
/// protected local store. A valid AEAD tag proves who encrypted bytes, not that decoded fields are
/// safe to trust after a buggy or compromised older client wrote them.
enum MessageBackupValidationPolicy {
    static let maximumEncryptedBytes = 32 * 1_024 * 1_024
    static let maximumConversations = 5_000
    static let maximumMessages = 20_000
    static let maximumInlineMediaBytes = KitChatMediaLimits.maximumInlineCacheBytes
    static let maximumAggregateInlineMediaBytes = 12 * 1_024 * 1_024
    static let maximumAggregateTextAndMetadataBytes = 12 * 1_024 * 1_024
    static let maximumTitleUTF8Bytes = 4_096
    static let maximumBodyUTF8Bytes = 64 * 1_024
    static let maximumDeviceNameUTF8Bytes = 512
    private static let earliestValidDate = Date(timeIntervalSince1970: 1_577_836_800) // 2020-01-01
    private static let maximumFutureSkew: TimeInterval = 7 * 24 * 60 * 60

    static func validate(
        _ payload: MessageBackupPayload,
        expectedUserID: String? = nil,
        now: Date = Date()
    ) throws {
        guard payload.schemaVersion == MessageBackupPayload.currentSchemaVersion,
              SecureMessagingWirePolicy.isCanonicalUUID(payload.userID),
              expectedUserID.map({
                  payload.userID.caseInsensitiveCompare($0) == .orderedSame
              }) ?? true,
              isValidDate(payload.createdAt, now: now),
              !payload.deviceName.isEmpty,
              payload.deviceName.utf8.count <= maximumDeviceNameUTF8Bytes,
              payload.conversations.count <= maximumConversations,
              payload.messages.count <= maximumMessages
        else {
            if let expectedUserID,
               payload.userID.caseInsensitiveCompare(expectedUserID) != .orderedSame {
                throw MessageBackupError.accountMismatch
            }
            throw MessageBackupError.invalidBackup
        }

        let conversationIDs = payload.conversations.map(\.id)
        guard Set(conversationIDs).count == conversationIDs.count else {
            throw MessageBackupError.invalidBackup
        }
        var aggregateTextAndMetadataBytes = payload.deviceName.utf8.count
        var participantsByConversation: [String: Set<String>] = [:]
        var groupConversationIDs: Set<String> = []
        for conversation in payload.conversations {
            guard SecureMessagingWirePolicy.isCanonicalUUID(conversation.id),
                  conversation.conversationType == nil
                    || conversation.conversationType == SecureMessagingWire.directConversationType
                    || conversation.conversationType == SecureMessagingWire.groupConversationType,
                  (conversation.isGroup
                    ? MessagingGroupTitlePolicy.isValid(conversation.title)
                    : (!conversation.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && conversation.title.utf8.count <= maximumTitleUTF8Bytes)),
                  conversation.unreadCount >= 0,
                  isValidDate(conversation.updatedAt, now: now),
                  // Direct threads keep the strict exactly-two rule. A retained GROUP may no
                  // longer contain the archive owner after a leave/removal. The final member may
                  // leave too, so a retained history-only group can have an empty active roster.
                  conversation.isGroup
                    ? (0 ... SecureMessagingWire.maximumGroupMembers)
                        .contains(conversation.participantUserIds.count)
                    : conversation.participantUserIds.count == 2,
                  Set(conversation.participantUserIds).count
                    == conversation.participantUserIds.count,
                  conversation.participantUserIds.allSatisfy(
                      SecureMessagingWirePolicy.isCanonicalUUID
                  ),
                  conversation.groupMemberRoles.map({ roles in
                      conversation.isGroup
                          && Set(roles.keys) == Set(conversation.participantUserIds)
                          && roles.keys.allSatisfy(SecureMessagingWirePolicy.isCanonicalUUID)
                  }) ?? true,
                  // The owner may have left/been removed from a group whose history they keep.
                  conversation.isGroup
                    || conversation.participantUserIds.contains(payload.userID)
            else { throw MessageBackupError.invalidBackup }
            guard addBounded(
                conversation.title.utf8.count
                    + conversation.id.utf8.count
                    + conversation.participantUserIds.reduce(0) { $0 + $1.utf8.count }
                    + 256,
                to: &aggregateTextAndMetadataBytes,
                limit: maximumAggregateTextAndMetadataBytes
            ) else { throw MessageBackupError.invalidBackup }
            participantsByConversation[conversation.id] = Set(conversation.participantUserIds)
            if conversation.isGroup {
                groupConversationIDs.insert(conversation.id)
            }
        }

        let messageIDs = payload.messages.map(\.id)
        guard Set(messageIDs).count == messageIDs.count else {
            throw MessageBackupError.invalidBackup
        }
        let serverIDs = payload.messages.compactMap(\.serverMessageId)
        guard Set(serverIDs).count == serverIDs.count else {
            throw MessageBackupError.invalidBackup
        }
        var aggregateInlineBytes = 0
        for message in payload.messages {
            let isGroup = groupConversationIDs.contains(message.conversationId)
            // Current rosters intentionally omit people who left. Preserve their already
            // authenticated history only when the projection carries every piece of provenance
            // produced by secure-message decryption. Merely choosing another canonical UUID as
            // a group sender is never enough. The archive owner is handled separately because
            // their own pre-removal outgoing messages may predate retained history metadata.
            let hasAuthenticatedDepartedGroupSender = isGroup
                && isAuthenticatedDepartedGroupSender(
                    message,
                    ownerUserID: payload.userID
                )
            guard let participants = participantsByConversation[message.conversationId],
                  SecureMessagingWirePolicy.isCanonicalUUID(message.conversationId),
                  SecureMessagingWirePolicy.isCanonicalUUID(message.senderId),
                  participants.contains(message.senderId)
                    || (isGroup && message.senderId == payload.userID)
                    || hasAuthenticatedDepartedGroupSender,
                  message.isOutgoing == (message.senderId == payload.userID),
                  message.body.utf8.count <= maximumBodyUTF8Bytes,
                  !message.body.unicodeScalars.contains(where: { $0.value == 0 }),
                  // KITSYS1 is server-event-authored. Backups do not carry enough event metadata
                  // to reconstruct and verify that provenance, so restore must fail closed.
                  !SecureMessageReservedPrefixPolicy.beginsWithReservedPrefix(
                      message.body,
                      prefix: KitSystemMessage.prefix
                  ),
                  isValidDate(message.createdAt, now: now),
                  message.sentAt.map({ isValidDate($0, now: now) }) ?? true,
                  (message.failureReason?.utf8.count ?? 0) <= 4_096,
                  [.sent, .delivered, .read, .received].contains(message.state),
                  message.pendingAttachment == nil,
                  message.serverMessageId.map(SecureMessagingWirePolicy.isCanonicalUUID) ?? true,
                  message.replyToServerMessageID
                    .map(SecureMessagingWirePolicy.isCanonicalUUID) ?? true,
                  // A message never answers itself, and a reaction is never an answer.
                  message.replyToServerMessageID == nil
                    || message.replyToServerMessageID
                        != message.serverMessageId?.lowercased(),
                  message.replyToServerMessageID == nil
                    || !KitMessageReaction.isReactionText(message.body)
            else { throw MessageBackupError.invalidBackup }
            // Accumulated stepwise rather than as one expression: the summed optionals are cheap
            // at runtime but expensive to type-check as a single term.
            var historyBytes = 0
            if let history = message.secureMessagingHistory {
                historyBytes += history.clientMessageID.utf8.count
                historyBytes += history.senderUserID?.utf8.count ?? 0
                historyBytes += history.senderDeviceID.utf8.count
                historyBytes += history.rosterRevision.utf8.count
                historyBytes += history.replyToMessageID?.utf8.count ?? 0
            }
            var messageBytes = 512
            messageBytes += message.body.utf8.count
            messageBytes += message.conversationId.utf8.count
            messageBytes += message.senderId.utf8.count
            messageBytes += message.serverMessageId?.utf8.count ?? 0
            messageBytes += message.failureReason?.utf8.count ?? 0
            messageBytes += message.replyToServerMessageID?.utf8.count ?? 0
            messageBytes += historyBytes
            guard addBounded(
                messageBytes,
                to: &aggregateTextAndMetadataBytes,
                limit: maximumAggregateTextAndMetadataBytes
            ) else { throw MessageBackupError.invalidBackup }

            if let attachment = message.attachmentData {
                guard !attachment.isEmpty,
                      attachment.count <= maximumInlineMediaBytes,
                      aggregateInlineBytes <= maximumAggregateInlineMediaBytes - attachment.count
                else { throw MessageBackupError.invalidBackup }
                aggregateInlineBytes += attachment.count
            }
            if let descriptor = KitMediaMessageDescriptor.parse(message.body) {
                guard message.attachmentData.map({ $0.count == descriptor.plaintextByteSize })
                    ?? true
                else { throw MessageBackupError.invalidBackup }
            } else {
                guard message.attachmentData == nil,
                      !SecureMessageReservedPrefixPolicy.beginsWithReservedPrefix(
                          message.body,
                          prefix: KitMediaMessageDescriptor.prefix
                      )
                else { throw MessageBackupError.invalidBackup }
            }
            if let history = message.secureMessagingHistory {
                guard SecureMessagingWirePolicy.isCanonicalUUID(history.clientMessageID),
                      history.senderUserID.map(SecureMessagingWirePolicy.isCanonicalUUID) ?? true,
                      history.senderUserID.map({ $0 == message.senderId }) ?? true,
                      SecureMessagingWirePolicy.isCanonicalUUID(history.senderDeviceID),
                      history.senderEnrollmentEpoch > 0,
                      (1 ... 127).contains(history.senderSignalDeviceID),
                      SecureMessagingWirePolicy.isRosterRevision(history.rosterRevision),
                      history.replyToMessageID.map(SecureMessagingWirePolicy.isCanonicalUUID)
                        ?? true,
                      // The visible pointer must be the authenticated one, not a second claim
                      // about who this message answers.
                      message.replyToServerMessageID == nil
                        || message.replyToServerMessageID
                            == history.replyToMessageID?.lowercased(),
                      SecureMessagingContentBindingPolicy.kind(
                          for: message.body,
                          replyToMessageID: history.replyToMessageID,
                          attachments: KitMediaMessageDescriptor.attachments(for: message.body)
                      ) == history.kind,
                      history.kind != .encryptedReaction
                        || (message.serverMessageId != nil
                            && history.senderUserID == message.senderId
                            && MessageReactionAggregationPolicy.hasValidTarget(
                                for: message,
                                among: payload.messages
                            )),
                      history.kind != .encryptedEdit
                        || (message.serverMessageId != nil
                            && history.senderUserID == message.senderId
                            && MessageEditAggregationPolicy.hasValidTarget(
                                for: message,
                                among: payload.messages
                            ))
                else { throw MessageBackupError.invalidBackup }
            } else if KitMessageReaction.isReactionText(message.body) {
                // Backups contain committed messages only; a reaction without authenticated
                // outer kind/target metadata could be ordinary legacy text impersonating one.
                throw MessageBackupError.invalidBackup
            }
        }

        try validateConversationReferences(
            payload.pinnedConversationIds,
            allowedIDs: Set(conversationIDs)
        )
        try validateConversationReferences(
            payload.mutedConversationIds,
            allowedIDs: Set(conversationIDs)
        )
    }

    static func isAuthenticatedDepartedGroupSender(
        _ message: LocalMessage,
        ownerUserID: String
    ) -> Bool {
        message.senderId != ownerUserID
            && !message.isOutgoing
            && [.received, .read].contains(message.state)
            && message.serverMessageId != nil
            && message.sentAt != nil
            && message.secureMessagingHistory?.senderUserID == message.senderId
    }

    /// Group roster changes can make a message's sender absent from a newer conversation
    /// projection. Only authenticated retained-history provenance can carry a non-owner sender
    /// across that boundary. Direct-conversation integrity remains the validator's strict concern.
    static func isRestorableMessageSender(
        _ message: LocalMessage,
        in conversation: Conversation,
        ownerUserID: String
    ) -> Bool {
        guard conversation.isGroup else { return true }
        return conversation.participantUserIds.contains(message.senderId)
            || message.senderId == ownerUserID
            || isAuthenticatedDepartedGroupSender(message, ownerUserID: ownerUserID)
    }

    private static func validateConversationReferences(
        _ ids: [String]?,
        allowedIDs: Set<String>
    ) throws {
        guard let ids else { return }
        guard ids.count <= maximumConversations,
              Set(ids).count == ids.count,
              ids.allSatisfy({
                  SecureMessagingWirePolicy.isCanonicalUUID($0) && allowedIDs.contains($0)
              })
        else { throw MessageBackupError.invalidBackup }
    }

    private static func isValidDate(_ date: Date, now: Date) -> Bool {
        let value = date.timeIntervalSince1970
        return value.isFinite
            && date >= earliestValidDate
            && date <= now.addingTimeInterval(maximumFutureSkew)
    }

    private static func addBounded(_ amount: Int, to total: inout Int, limit: Int) -> Bool {
        guard amount >= 0, amount <= limit, total <= limit - amount else { return false }
        total += amount
        return true
    }
}

/// Versioned end-to-end encryption around the backup payload. The 32-byte key lives only in the
/// user's iCloud Keychain (Apple end-to-end encrypted); iCloud stores ciphertext it cannot read.
enum MessageBackupCrypto {
    static let envelopePrefix = Data("KITBKP1:".utf8)
    static let keyBytes = 32

    static func encrypt(_ payload: MessageBackupPayload, key: Data) throws -> Data {
        guard key.count == keyBytes else { throw MessageBackupError.keyUnavailable }
        try MessageBackupValidationPolicy.validate(payload)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let clear = try encoder.encode(payload)
        let sealed = try ChaChaPoly.seal(clear, using: SymmetricKey(data: key))
        let encrypted = envelopePrefix + sealed.combined
        guard encrypted.count <= MessageBackupValidationPolicy.maximumEncryptedBytes else {
            throw MessageBackupError.invalidBackup
        }
        return encrypted
    }

    static func decrypt(_ data: Data, key: Data) throws -> MessageBackupPayload {
        guard key.count == keyBytes else { throw MessageBackupError.keyUnavailable }
        guard data.count > envelopePrefix.count,
              data.count <= MessageBackupValidationPolicy.maximumEncryptedBytes,
              data.prefix(envelopePrefix.count) == envelopePrefix
        else { throw MessageBackupError.invalidBackup }

        let sealed: ChaChaPoly.SealedBox
        do {
            sealed = try ChaChaPoly.SealedBox(
                combined: data.dropFirst(envelopePrefix.count)
            )
        } catch {
            throw MessageBackupError.invalidBackup
        }

        let clear: Data
        do {
            clear = try ChaChaPoly.open(sealed, using: SymmetricKey(data: key))
        } catch {
            // ChaChaPoly deliberately does not distinguish a wrong key from authenticated
            // ciphertext corruption. Keep this separate from decoding and policy validation so
            // we never tell a customer that a compatible, intact backup is merely "invalid".
            throw MessageBackupError.authenticationFailed
        }

        let payload: MessageBackupPayload
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            payload = try decoder.decode(MessageBackupPayload.self, from: clear)
        } catch {
            throw MessageBackupError.incompatibleBackup
        }

        do {
            try MessageBackupValidationPolicy.validate(payload)
        } catch MessageBackupError.accountMismatch {
            throw MessageBackupError.accountMismatch
        } catch {
            // Schema version 1 has accumulated stricter safety checks over time. A payload that
            // authenticates and decodes but fails today's policy is materially different from a
            // wrong key; preserve it and describe the compatibility failure accurately.
            throw MessageBackupError.incompatibleBackup
        }
        return payload
    }
}

/// Per-account backup key in iCloud Keychain, minted on first backup.
enum MessageBackupKeyStore {
    static func account(forUserID userID: String) -> String {
        "kit-pay-message-backup-key-v1-\(userID.lowercased())"
    }

    static func existingKey(forUserID userID: String) throws -> Data? {
        guard let data = try KeychainStore.synchronizableData(
            for: account(forUserID: userID)
        ), data.count == MessageBackupCrypto.keyBytes else { return nil }
        return data
    }

    static func key(forUserID userID: String) throws -> Data {
        if let existing = try existingKey(forUserID: userID) { return existing }
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        try KeychainStore.setSynchronizable(key, for: account(forUserID: userID))
        return key
    }

    static func removeKey(forUserID userID: String) throws {
        try KeychainStore.removeSynchronizable(account(forUserID: userID))
    }
}

/// What the restore prompt shows before the user decides.
struct MessageBackupSummary: Equatable, Sendable {
    let createdAt: Date
    let byteSize: Int
    let messageCount: Int
    let deviceName: String
    let generation: Int64
    let contentDigest: String?

    init(
        createdAt: Date,
        byteSize: Int,
        messageCount: Int,
        deviceName: String,
        generation: Int64 = 0,
        contentDigest: String? = nil
    ) {
        self.createdAt = createdAt
        self.byteSize = byteSize
        self.messageCount = messageCount
        self.deviceName = deviceName
        self.generation = generation
        self.contentDigest = contentDigest
    }
}

struct MessageBackupContentMetadata: Equatable, Sendable {
    let messageCount: Int
    let newestMessageAt: Date?
    let digest: String

    static func make(for payload: MessageBackupPayload) throws -> Self {
        struct CanonicalContent: Encodable {
            let conversations: [Conversation]
            let messages: [LocalMessage]
            let pinnedConversationIds: [String]
            let mutedConversationIds: [String]
        }
        let content = CanonicalContent(
            conversations: payload.conversations.sorted { $0.id < $1.id },
            messages: payload.messages.sorted {
                $0.id.uuidString.lowercased() < $1.id.uuidString.lowercased()
            },
            pinnedConversationIds: (payload.pinnedConversationIds ?? []).sorted(),
            mutedConversationIds: (payload.mutedConversationIds ?? []).sorted()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(content)
        return Self(
            messageCount: payload.messages.count,
            newestMessageAt: payload.messages
                .map { max($0.createdAt, $0.sentAt ?? $0.createdAt) }
                .max(),
            digest: SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        )
    }
}

/// A sent message can have two local identifiers across the user's iPhones: the originating
/// device retains its client-generated UUID, while a device that receives the synced copy uses
/// the server message UUID. Treat the authenticated server UUID as the primary backup identity
/// whenever it exists, while retaining the local UUID as an alias for older projections.
private enum MessageBackupMessageIdentityPolicy {
    static func primaryKey(for message: LocalMessage) -> String {
        message.serverMessageId ?? message.id.uuidString.lowercased()
    }

    static func keys(for message: LocalMessage) -> Set<String> {
        var keys = [message.id.uuidString.lowercased()]
        if let serverMessageId = message.serverMessageId {
            keys.append(serverMessageId)
        }
        return Set(keys)
    }
}

/// Concurrent devices always converge on the union of their valid archives. Selection for an ID
/// collision is deterministic, making a CloudKit conflict retry independent of save order.
enum MessageBackupConflictPolicy {
    static func merge(
        _ first: MessageBackupPayload,
        _ second: MessageBackupPayload
    ) throws -> MessageBackupPayload {
        try MessageBackupValidationPolicy.validate(first)
        try MessageBackupValidationPolicy.validate(second, expectedUserID: first.userID)

        var conversations = Dictionary(uniqueKeysWithValues: first.conversations.map { ($0.id, $0) })
        for candidate in second.conversations {
            if let existing = conversations[candidate.id] {
                conversations[candidate.id] = try preferredConversation(existing, candidate)
            } else {
                conversations[candidate.id] = candidate
            }
        }
        // A newer group projection may omit a member who was still present in an older valid
        // archive. Filter against the selected roster before either identity-deduplication pass:
        // an unbound legacy row must not displace a sender-bound copy with a different delivery
        // state and then poison (or disappear from) the merged backup.
        let restorableFirstMessages = first.messages.filter { message in
            guard let conversation = conversations[message.conversationId] else { return true }
            return MessageBackupValidationPolicy.isRestorableMessageSender(
                message,
                in: conversation,
                ownerUserID: first.userID
            )
        }
        let restorableSecondMessages = second.messages.filter { message in
            guard let conversation = conversations[message.conversationId] else { return true }
            return MessageBackupValidationPolicy.isRestorableMessageSender(
                message,
                in: conversation,
                ownerUserID: first.userID
            )
        }
        var messagesByLocalID = Dictionary(
            uniqueKeysWithValues: restorableFirstMessages.map { ($0.id, $0) }
        )
        for candidate in restorableSecondMessages {
            if let existing = messagesByLocalID[candidate.id] {
                messagesByLocalID[candidate.id] = try preferredMessage(existing, candidate)
            } else {
                messagesByLocalID[candidate.id] = candidate
            }
        }
        var messagesByBackupIdentity: [String: LocalMessage] = [:]
        for candidate in messagesByLocalID.values {
            let identity = MessageBackupMessageIdentityPolicy.primaryKey(for: candidate)
            if let existing = messagesByBackupIdentity[identity] {
                messagesByBackupIdentity[identity] = try preferredMessage(existing, candidate)
            } else {
                messagesByBackupIdentity[identity] = candidate
            }
        }
        let newest: MessageBackupPayload
        if first.createdAt != second.createdAt {
            newest = first.createdAt > second.createdAt ? first : second
        } else {
            newest = first.deviceName >= second.deviceName ? first : second
        }
        let merged = MessageBackupPayload(
            userID: first.userID,
            createdAt: max(first.createdAt, second.createdAt),
            deviceName: newest.deviceName,
            conversations: conversations.values.sorted { $0.id < $1.id },
            messages: messagesByBackupIdentity.values.sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString.lowercased() < $1.id.uuidString.lowercased()
            },
            pinnedConversationIds: mergedReferences(
                first.pinnedConversationIds,
                second.pinnedConversationIds
            ),
            mutedConversationIds: mergedReferences(
                first.mutedConversationIds,
                second.mutedConversationIds
            )
        )
        try MessageBackupValidationPolicy.validate(merged)
        return merged
    }

    private static func mergedReferences(_ first: [String]?, _ second: [String]?) -> [String]? {
        let values = Set(first ?? []).union(second ?? []).sorted()
        return values.isEmpty && first == nil && second == nil ? nil : values
    }

    private static func preferredConversation(
        _ first: Conversation,
        _ second: Conversation
    ) throws -> Conversation {
        if first.updatedAt != second.updatedAt {
            return first.updatedAt > second.updatedAt ? first : second
        }
        return try canonicalDigest(first) >= canonicalDigest(second) ? first : second
    }

    private static func preferredMessage(
        _ first: LocalMessage,
        _ second: LocalMessage
    ) throws -> LocalMessage {
        let firstRank = messageRank(first)
        let secondRank = messageRank(second)
        if firstRank != secondRank { return firstRank > secondRank ? first : second }
        let firstSentAt = first.sentAt ?? first.createdAt
        let secondSentAt = second.sentAt ?? second.createdAt
        if firstSentAt != secondSentAt { return firstSentAt > secondSentAt ? first : second }
        return try canonicalDigest(first) >= canonicalDigest(second) ? first : second
    }

    private static func messageRank(_ message: LocalMessage) -> Int {
        let deliveryRank: Int
        switch message.state {
        case .failed: deliveryRank = 0
        case .queued: deliveryRank = 1
        case .encrypting: deliveryRank = 2
        case .sending: deliveryRank = 3
        case .received: deliveryRank = 4
        case .sent: deliveryRank = 5
        case .delivered: deliveryRank = 6
        case .read: deliveryRank = 7
        }
        return deliveryRank * 16
            + (message.serverMessageId == nil ? 0 : 8)
            + (message.secureMessagingHistory == nil ? 0 : 4)
            // A sender-bound history record is strictly more useful than its otherwise identical
            // legacy form: it remains restorable after that sender leaves a group.
            + (message.secureMessagingHistory?.senderUserID == nil ? 0 : 2)
            + (message.pendingAttachment == nil ? 1 : 0)
    }

    private static func canonicalDigest<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try SHA256.hash(data: encoder.encode(value))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// Restoring must never destroy newer local history: local copies win by message/conversation ID,
/// the backup only fills gaps.
enum MessageBackupRestorePolicy {
    static func merge(
        _ payload: MessageBackupPayload,
        into state: inout PersistedState,
        currentUserID: String
    ) throws {
        try MessageBackupValidationPolicy.validate(payload, expectedUserID: currentUserID)

        var conversationsByID = Dictionary(
            state.conversations.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for conversation in payload.conversations {
            if let local = conversationsByID[conversation.id] {
                if conversation.updatedAt > local.updatedAt {
                    var merged = conversation
                    merged.unreadCount = local.unreadCount
                    conversationsByID[conversation.id] = merged
                }
            } else {
                var restored = conversation
                restored.unreadCount = 0
                conversationsByID[conversation.id] = restored
            }
        }
        state.conversations = conversationsByID.values.sorted { $0.updatedAt > $1.updatedAt }

        var retainedMessageIdentityKeys = Set(
            state.messages.flatMap { MessageBackupMessageIdentityPolicy.keys(for: $0) }
        )
        let restoredMessages = payload.messages.filter { message in
            let candidateKeys = MessageBackupMessageIdentityPolicy.keys(for: message)
            guard retainedMessageIdentityKeys.isDisjoint(with: candidateKeys) else { return false }
            retainedMessageIdentityKeys.formUnion(candidateKeys)
            return true
        }
        state.messages.append(contentsOf: restoredMessages)

        if state.pinnedConversationIds == nil {
            state.pinnedConversationIds = payload.pinnedConversationIds
        }
        if state.mutedConversationIds == nil {
            state.mutedConversationIds = payload.mutedConversationIds
        }
    }
}
