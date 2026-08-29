import CryptoKit
import Foundation

enum AbuseReportContract {
    static let capabilityKey = "abuse_reporting"
    static let maximumSelectedMessages = 5
    static let maximumPresentedMessages = 50
    static let maximumMessageCharacters = 4_000
    static let maximumSelectedMessageBytes = 12_000
    static let maximumNoteCharacters = 1_000

    static func isAvailable(features: [String: Bool?]?) -> Bool {
        features?[capabilityKey] == true
    }

    static func validIdempotencyKey(_ value: String) -> Bool {
        value.range(
            of: #"\A[A-Za-z0-9][A-Za-z0-9._:-]{15,127}\z"#,
            options: .regularExpression
        ) != nil
    }

    static func validRequestFingerprint(_ value: String) -> Bool {
        value.range(of: #"\A[0-9a-f]{64}\z"#, options: .regularExpression) != nil
    }

    static func makeIdempotencyKey() -> String {
        "ios-abuse-report-\(UUID().uuidString.lowercased())"
    }

    static func limitedNote(_ value: String) -> String {
        let scalars = value.unicodeScalars.prefix(maximumNoteCharacters)
        return String(String.UnicodeScalarView(scalars))
    }
}

struct AbuseReportContext: Equatable, Sendable {
    let currentUserID: String
    let reportedUserID: String
    let conversationID: String

    init?(
        currentUserID rawCurrentUserID: String?,
        reportedUserID rawReportedUserID: String?,
        conversation: Conversation
    ) {
        guard let currentUserID = CommunicationPrivacyIdentifier.canonicalUUID(rawCurrentUserID),
              let reportedUserID = CommunicationPrivacyIdentifier.canonicalUUID(rawReportedUserID),
              let conversationID = CommunicationPrivacyIdentifier.canonicalUUID(conversation.id),
              currentUserID != reportedUserID
        else { return nil }

        let members = conversation.participantUserIds.compactMap {
            CommunicationPrivacyIdentifier.canonicalUUID($0)
        }
        let uniqueMembers = Set(members)
        guard members.count == conversation.participantUserIds.count,
              uniqueMembers.count == members.count,
              uniqueMembers.contains(currentUserID),
              uniqueMembers.contains(reportedUserID)
        else { return nil }

        // A direct thread must remain exactly two-party. A group report instead binds the report
        // to the authenticated sender selected from the group transcript; the backend performs
        // the same membership check against its authoritative roster at submission time.
        if conversation.isGroup {
            guard members.count >= 2 else { return nil }
        } else {
            guard uniqueMembers == Set([currentUserID, reportedUserID]),
                  members.count == 2
            else { return nil }
        }

        self.currentUserID = currentUserID
        self.reportedUserID = reportedUserID
        self.conversationID = conversationID
    }
}

enum AbuseReportTarget: Equatable, Identifiable, Sendable {
    case account
    case conversation
    case message(String)

    var id: String {
        switch self {
        case .account: "account"
        case .conversation: "conversation"
        case .message(let messageID): "message:\(messageID)"
        }
    }

    var type: AbuseReportTargetType {
        switch self {
        case .account: .account
        case .conversation: .conversation
        case .message: .message
        }
    }

    var messageID: String? {
        guard case .message(let messageID) = self else { return nil }
        return CommunicationPrivacyIdentifier.canonicalUUID(messageID)
    }

    static func message(
        _ message: LocalMessage,
        context: AbuseReportContext
    ) -> AbuseReportTarget? {
        guard !message.isOutgoing,
              CommunicationPrivacyIdentifier.canonicalUUID(message.senderId)
                == context.reportedUserID,
              CommunicationPrivacyIdentifier.canonicalUUID(message.conversationId)
                == context.conversationID,
              let messageID = CommunicationPrivacyIdentifier.canonicalUUID(message.serverMessageId)
        else { return nil }
        return .message(messageID)
    }
}

enum AbuseReportTargetType: String, Codable, Equatable, Sendable {
    case account
    case conversation
    case message
}

enum AbuseReportReason: String, CaseIterable, Codable, Identifiable, Sendable {
    case spam
    case scamOrFraud = "scam_or_fraud"
    case harassmentOrBullying = "harassment_or_bullying"
    case hateSpeech = "hate_speech"
    case credibleThreat = "credible_threat"
    case sexualContent = "sexual_content"
    case childSafety = "child_safety"
    case selfHarm = "self_harm"
    case impersonation
    case illegalActivity = "illegal_activity"
    case privacyViolation = "privacy_violation"
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .spam: "Spam"
        case .scamOrFraud: "Scam or fraud"
        case .harassmentOrBullying: "Harassment or bullying"
        case .hateSpeech: "Hate speech"
        case .credibleThreat: "Threats or violence"
        case .sexualContent: "Sexual content"
        case .childSafety: "Child safety"
        case .selfHarm: "Self-harm"
        case .impersonation: "Impersonation"
        case .illegalActivity: "Illegal activity"
        case .privacyViolation: "Privacy violation"
        case .other: "Something else"
        }
    }
}

struct AbuseReportSelectedMessage: Encodable, Equatable, Sendable {
    let messageID: String
    let plaintext: String

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case plaintext
    }

    /// Only prose a person typed may be attached to a report. The entire `KITMEDIA` family is
    /// rejected here — every version, parseable or not — because a descriptor carries the
    /// decryption keys for its attachments, and submitting one would hand moderators (and any
    /// transport log) the keys to media the reporter never consented to share. Captions are not
    /// extracted from descriptors either: sharing part of a media message it has no dedicated
    /// consent language for is worse than omitting it from the picker.
    init(messageID rawMessageID: String, plaintext: String) throws {
        guard let messageID = CommunicationPrivacyIdentifier.canonicalUUID(rawMessageID),
              !plaintext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              plaintext.unicodeScalars.count <= AbuseReportContract.maximumMessageCharacters,
              plaintext.utf8.count <= AbuseReportContract.maximumSelectedMessageBytes,
              SecureMessageReservedPrefixPolicy.allowsUserAuthoredText(plaintext)
        else { throw AbuseReportContractError.invalidSelectedMessage }
        self.messageID = messageID
        self.plaintext = plaintext
    }
}

struct AbuseReportMessageCandidate: Identifiable, Equatable, Sendable {
    let payload: AbuseReportSelectedMessage
    let isOutgoing: Bool
    let createdAt: Date
    let isReportTarget: Bool

    var id: String { payload.messageID }
    var plaintext: String { payload.plaintext }

    init(
        payload: AbuseReportSelectedMessage,
        isOutgoing: Bool,
        createdAt: Date,
        isReportTarget: Bool = false
    ) {
        self.payload = payload
        self.isOutgoing = isOutgoing
        self.createdAt = createdAt
        self.isReportTarget = isReportTarget
    }
}

enum AbuseReportMessageSelectionPolicy {
    static func candidates(
        from messages: [LocalMessage],
        context: AbuseReportContext,
        targetMessageID rawTargetMessageID: String? = nil
    ) -> [AbuseReportMessageCandidate] {
        let targetMessageID = CommunicationPrivacyIdentifier.canonicalUUID(rawTargetMessageID)
        var seen: Set<String> = []
        var candidates = messages
            .compactMap { message -> AbuseReportMessageCandidate? in
                guard CommunicationPrivacyIdentifier.canonicalUUID(message.conversationId)
                        == context.conversationID,
                      CommunicationPrivacyIdentifier.canonicalUUID(message.senderId)
                        == (message.isOutgoing
                            ? context.currentUserID
                            : context.reportedUserID),
                      message.pendingAttachment == nil,
                      message.pendingMediaBatch == nil,
                      message.attachmentData == nil,
                      [.sent, .delivered, .read, .received].contains(message.state),
                      let messageID = CommunicationPrivacyIdentifier.canonicalUUID(
                          message.serverMessageId
                      ),
                      let payload = try? AbuseReportSelectedMessage(
                          messageID: messageID,
                          plaintext: message.body
                      ),
                      seen.insert(messageID).inserted
                else { return nil }
                return AbuseReportMessageCandidate(
                    payload: payload,
                    isOutgoing: message.isOutgoing,
                    createdAt: message.createdAt,
                    isReportTarget: messageID == targetMessageID
                )
            }
            .sorted {
                if $0.createdAt == $1.createdAt { return $0.id > $1.id }
                return $0.createdAt > $1.createdAt
            }

        // A report opened from an old message must not hide that exact eligible message merely
        // because it falls outside the newest-message window. Keep the list bounded by moving the
        // target to the first row and using the remaining slots for the newest context.
        if let targetIndex = candidates.firstIndex(where: { $0.isReportTarget }) {
            let target = candidates.remove(at: targetIndex)
            return [target] + Array(candidates.prefix(
                AbuseReportContract.maximumPresentedMessages - 1
            ))
        }
        return Array(candidates.prefix(AbuseReportContract.maximumPresentedMessages))
    }

    static func canSelect(
        _ candidate: AbuseReportMessageCandidate,
        selectedIDs: Set<String>,
        candidates: [AbuseReportMessageCandidate]
    ) -> Bool {
        if selectedIDs.contains(candidate.id) { return true }
        guard selectedIDs.count < AbuseReportContract.maximumSelectedMessages else { return false }
        let selectedBytes = candidates.lazy
            .filter { selectedIDs.contains($0.id) }
            .reduce(0) { $0 + $1.plaintext.utf8.count }
        return selectedBytes + candidate.plaintext.utf8.count
            <= AbuseReportContract.maximumSelectedMessageBytes
    }

    static func payloads(
        selectedIDs: Set<String>,
        candidates: [AbuseReportMessageCandidate]
    ) throws -> [AbuseReportSelectedMessage] {
        let selected = candidates.filter { selectedIDs.contains($0.id) }
        guard selected.count == selectedIDs.count,
              selected.count <= AbuseReportContract.maximumSelectedMessages,
              selected.reduce(0, { $0 + $1.plaintext.utf8.count })
                <= AbuseReportContract.maximumSelectedMessageBytes
        else { throw AbuseReportContractError.invalidSelectedMessages }
        return selected
            .sorted {
                if $0.createdAt == $1.createdAt { return $0.id < $1.id }
                return $0.createdAt < $1.createdAt
            }
            .map(\.payload)
    }
}

struct CreateAbuseReportRequest: Encodable, Equatable, Sendable {
    let targetType: AbuseReportTargetType
    let reportedUserID: String
    let conversationID: String
    let messageID: String?
    let reasonCode: AbuseReportReason
    let reporterNote: String?
    let selectedMessages: [AbuseReportSelectedMessage]?
    let consent: AbuseReportConsent

    enum CodingKeys: String, CodingKey {
        case targetType = "target_type"
        case reportedUserID = "reported_user_id"
        case conversationID = "conversation_id"
        case messageID = "message_id"
        case reasonCode = "reason_code"
        case reporterNote = "reporter_note"
        case selectedMessages = "selected_messages"
        case consent
    }

    init(
        context: AbuseReportContext,
        target: AbuseReportTarget,
        reason: AbuseReportReason,
        reporterNote rawReporterNote: String?,
        selectedMessages: [AbuseReportSelectedMessage],
        shareSelectedMessagePlaintext: Bool
    ) throws {
        let note = rawReporterNote?.trimmingCharacters(in: .whitespacesAndNewlines)
        let messageID: String?
        switch target {
        case .account, .conversation:
            messageID = nil
        case .message(let rawMessageID):
            guard let canonicalMessageID = CommunicationPrivacyIdentifier.canonicalUUID(
                rawMessageID
            ) else { throw AbuseReportContractError.invalidRequest }
            messageID = canonicalMessageID
        }
        guard (note?.unicodeScalars.count ?? 0) <= AbuseReportContract.maximumNoteCharacters,
              selectedMessages.count <= AbuseReportContract.maximumSelectedMessages,
              Set(selectedMessages.map(\.messageID)).count == selectedMessages.count,
              selectedMessages.reduce(0, { $0 + $1.plaintext.utf8.count })
                <= AbuseReportContract.maximumSelectedMessageBytes,
              shareSelectedMessagePlaintext == !selectedMessages.isEmpty
        else { throw AbuseReportContractError.invalidRequest }

        targetType = target.type
        reportedUserID = context.reportedUserID
        conversationID = context.conversationID
        self.messageID = messageID
        reasonCode = reason
        reporterNote = note?.isEmpty == false ? note : nil
        self.selectedMessages = selectedMessages.isEmpty ? nil : selectedMessages
        consent = AbuseReportConsent(
            shareReportWithModerators: true,
            shareSelectedMessagePlaintext: shareSelectedMessagePlaintext
        )
    }

    /// A deterministic, one-way identity for retrying this exact request. The digest may be
    /// persisted, but the encoded request used to produce it must remain in memory only.
    func retryFingerprint() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var material = Data("kit-pay-abuse-report-request-v1\u{0}".utf8)
        material.append(try encoder.encode(self))
        return SHA256.hash(data: material)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct AbuseReportConsent: Encodable, Equatable, Sendable {
    let shareReportWithModerators: Bool
    let shareSelectedMessagePlaintext: Bool

    enum CodingKeys: String, CodingKey {
        case shareReportWithModerators = "share_report_with_moderators"
        case shareSelectedMessagePlaintext = "share_selected_message_plaintext"
    }
}

struct PendingAbuseReportAttempt: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let accountID: String
    let requestFingerprint: String
    let idempotencyKey: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version
        case accountID = "account_id"
        case requestFingerprint = "request_fingerprint"
        case idempotencyKey = "idempotency_key"
    }

    init(
        accountID rawAccountID: String,
        requestFingerprint: String,
        idempotencyKey: String
    ) throws {
        guard let accountID = CommunicationPrivacyIdentifier.canonicalUUID(rawAccountID),
              AbuseReportContract.validRequestFingerprint(requestFingerprint),
              AbuseReportContract.validIdempotencyKey(idempotencyKey)
        else { throw AbuseReportAttemptStoreError.invalidAttempt }

        version = Self.currentVersion
        self.accountID = accountID
        self.requestFingerprint = requestFingerprint
        self.idempotencyKey = idempotencyKey
    }

    init(from decoder: Decoder) throws {
        try AbuseReportDecoding.rejectUnknownKeys(
            from: decoder,
            allowed: CodingKeys.allCases.map(\.rawValue)
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.count == CodingKeys.allCases.count,
              try container.decode(Int.self, forKey: .version) == Self.currentVersion
        else { throw AbuseReportAttemptStoreError.invalidAttempt }
        try self.init(
            accountID: container.decode(String.self, forKey: .accountID),
            requestFingerprint: container.decode(String.self, forKey: .requestFingerprint),
            idempotencyKey: container.decode(String.self, forKey: .idempotencyKey)
        )
    }
}

enum AbuseReportAttemptStoreError: Error, Equatable {
    case invalidAttempt
    case persistenceVerificationFailed
}

/// Persists only an account ID, a one-way request fingerprint, and the retry key. The request and
/// any selected plaintext never enter Keychain. A distinct item per account/fingerprint preserves
/// ambiguous attempts without letting one report replace another report's retry authority.
actor AbuseReportAttemptStore {
    static let shared = AbuseReportAttemptStore()

    typealias Load = @Sendable (_ account: String) throws -> Data?
    typealias Save = @Sendable (_ data: Data, _ account: String) throws -> Void
    typealias Remove = @Sendable (_ account: String) throws -> Void

    private let load: Load
    private let save: Save
    private let remove: Remove

    init(
        load: @escaping Load = { try KeychainStore.data(for: $0) },
        save: @escaping Save = { try KeychainStore.set($0, for: $1) },
        remove: @escaping Remove = { try KeychainStore.remove($0) }
    ) {
        self.load = load
        self.save = save
        self.remove = remove
    }

    func attempt(
        for request: CreateAbuseReportRequest,
        accountID rawAccountID: String
    ) throws -> PendingAbuseReportAttempt {
        guard let accountID = CommunicationPrivacyIdentifier.canonicalUUID(rawAccountID) else {
            throw AbuseReportAttemptStoreError.invalidAttempt
        }
        let fingerprint = try request.retryFingerprint()
        guard AbuseReportContract.validRequestFingerprint(fingerprint) else {
            throw AbuseReportAttemptStoreError.invalidAttempt
        }
        let storageAccount = Self.storageAccount(
            accountID: accountID,
            requestFingerprint: fingerprint
        )

        if let data = try load(storageAccount) {
            let existing = try decode(data)
            guard existing.accountID == accountID,
                  existing.requestFingerprint == fingerprint
            else { throw AbuseReportAttemptStoreError.invalidAttempt }
            return existing
        }

        let attempt = try PendingAbuseReportAttempt(
            accountID: accountID,
            requestFingerprint: fingerprint,
            idempotencyKey: AbuseReportContract.makeIdempotencyKey()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try save(try encoder.encode(attempt), storageAccount)
        guard let persisted = try load(storageAccount),
              try decode(persisted) == attempt
        else { throw AbuseReportAttemptStoreError.persistenceVerificationFailed }
        return attempt
    }

    /// Called only after a strictly validated server receipt. Failure leaves the attempt active or
    /// surfaces an error rather than silently losing retry authority.
    func completeIfCurrent(_ attempt: PendingAbuseReportAttempt) throws -> Bool {
        let storageAccount = Self.storageAccount(
            accountID: attempt.accountID,
            requestFingerprint: attempt.requestFingerprint
        )
        guard let data = try load(storageAccount) else { return false }
        guard try decode(data) == attempt else {
            throw AbuseReportAttemptStoreError.invalidAttempt
        }
        try remove(storageAccount)
        guard try load(storageAccount) == nil else {
            throw AbuseReportAttemptStoreError.persistenceVerificationFailed
        }
        return true
    }

    static func storageAccount(accountID: String, requestFingerprint: String) -> String {
        "kit-pay-abuse-report-attempt-v1:\(accountID):\(requestFingerprint)"
    }

    private func decode(_ data: Data) throws -> PendingAbuseReportAttempt {
        do {
            return try JSONDecoder().decode(PendingAbuseReportAttempt.self, from: data)
        } catch let error as AbuseReportAttemptStoreError {
            throw error
        } catch {
            throw AbuseReportAttemptStoreError.invalidAttempt
        }
    }
}

struct AbuseReportReceipt: Decodable, Equatable, Sendable {
    let id: String
    let status: String
    let targetType: AbuseReportTargetType
    let reasonCode: AbuseReportReason
    let conversationID: String
    let messageID: String?
    let selectedMessageCount: Int
    let submittedAt: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, status
        case targetType = "target_type"
        case reasonCode = "reason_code"
        case conversationID = "conversation_id"
        case messageID = "message_id"
        case selectedMessageCount = "selected_message_count"
        case submittedAt = "submitted_at"
    }

    init(from decoder: Decoder) throws {
        try AbuseReportDecoding.rejectUnknownKeys(
            from: decoder,
            allowed: CodingKeys.allCases.map(\.rawValue)
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.count == CodingKeys.allCases.count else {
            throw AbuseReportContractError.invalidReceipt
        }

        let rawID = try container.decode(String.self, forKey: .id)
        let status = try container.decode(String.self, forKey: .status)
        let targetType = try container.decode(AbuseReportTargetType.self, forKey: .targetType)
        let reasonCode = try container.decode(AbuseReportReason.self, forKey: .reasonCode)
        let rawConversationID = try container.decode(String.self, forKey: .conversationID)
        let rawMessageID = try container.decodeIfPresent(String.self, forKey: .messageID)
        let selectedMessageCount = try container.decode(Int.self, forKey: .selectedMessageCount)
        let submittedAt = try container.decode(String.self, forKey: .submittedAt)

        guard let id = CommunicationPrivacyIdentifier.canonicalUUID(rawID),
              let conversationID = CommunicationPrivacyIdentifier.canonicalUUID(rawConversationID),
              status == "received",
              (0 ... AbuseReportContract.maximumSelectedMessages).contains(selectedMessageCount),
              AbuseReportDecoding.date(from: submittedAt) != nil
        else { throw AbuseReportContractError.invalidReceipt }

        let messageID = rawMessageID.flatMap {
            CommunicationPrivacyIdentifier.canonicalUUID($0)
        }
        guard (rawMessageID == nil || messageID != nil),
              (targetType == .message) == (messageID != nil)
        else { throw AbuseReportContractError.invalidReceipt }

        self.id = id
        self.status = status
        self.targetType = targetType
        self.reasonCode = reasonCode
        self.conversationID = conversationID
        self.messageID = messageID
        self.selectedMessageCount = selectedMessageCount
        self.submittedAt = submittedAt
    }

    func confirms(_ request: CreateAbuseReportRequest) -> Bool {
        targetType == request.targetType
            && reasonCode == request.reasonCode
            && conversationID == request.conversationID
            && messageID == request.messageID
            && selectedMessageCount == (request.selectedMessages?.count ?? 0)
    }
}

enum AbuseReportErrorCopy {
    static func message(for error: Error) -> String {
        if let apiClientError = error as? APIClientError,
           case .signedOut = apiClientError {
            return "Sign in again before submitting this report."
        }
        if let apiError = error as? APIErrorPayload {
            if apiError.httpStatus == 429 || apiError.code.uppercased().contains("RATE_LIMIT") {
                return "Too many reports were submitted. Please wait a moment and try again."
            }
            switch apiError.code.uppercased() {
            case "REPORT_TARGET_UNAVAILABLE":
                return "This account or conversation is no longer available to report."
            case "VALIDATION_FAILED":
                return "Review the report details and try again."
            default:
                break
            }
        }
        return "Kit Pay could not submit this report. Please try again."
    }
}

enum AbuseReportContractError: Error, Equatable {
    case invalidSelectedMessage
    case invalidSelectedMessages
    case invalidRequest
    case invalidIdempotencyKey
    case invalidReceipt
}

private enum AbuseReportDecoding {
    private struct AnyCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    static func rejectUnknownKeys(from decoder: Decoder, allowed: [String]) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        guard Set(container.allKeys.map(\.stringValue)).isSubset(of: Set(allowed)) else {
            throw AbuseReportContractError.invalidReceipt
        }
    }

    static func date(from value: String) -> Date? {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.range(
                  of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$"#,
                  options: .regularExpression
              ) != nil
        else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = value.contains(".")
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
