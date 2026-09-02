import CryptoKit
import Foundation

// MARK: - Authoritative transfer-acceptance state

/// Server-side lifecycle of a claimable Kit Pay → Kit Pay transfer.
enum TransferAcceptanceStatus: String, Codable, CaseIterable {
    case pending
    case accepted
    case rejected
    case reversed
    case expired
}

/// One transfer as the backend sees it. The chat descriptor is only a hint; every button the
/// user can tap resolves against this authoritative object first.
struct TransferAcceptanceDTO: Codable, Hashable, Identifiable {
    let id: String
    let transactionId: String
    let reference: String?
    let status: String
    let amount: String
    let currency: CurrencyDTO
    let note: String?
    let sender: TransferAcceptancePartyDTO?
    let recipient: TransferAcceptancePartyDTO?
    let reason: String?
    let resolvedBy: String?
    let reversalTransactionId: String?
    let expiresAt: String?
    let acceptedAt: String?
    let returnedAt: String?
    let createdAt: String?
    let canAccept: Bool
    let canReject: Bool
    let canReverse: Bool

    enum CodingKeys: String, CodingKey {
        case id, reference, status, amount, currency, note, sender, recipient, reason
        case transactionId = "transaction_id"
        case resolvedBy = "resolved_by"
        case reversalTransactionId = "reversal_transaction_id"
        case expiresAt = "expires_at"
        case acceptedAt = "accepted_at"
        case returnedAt = "returned_at"
        case createdAt = "created_at"
        case canAccept = "can_accept"
        case canReject = "can_reject"
        case canReverse = "can_reverse"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        transactionId = try values.decode(String.self, forKey: .transactionId)
        reference = try values.decodeIfPresent(String.self, forKey: .reference)
        status = try values.decode(String.self, forKey: .status)
        amount = try values.decode(String.self, forKey: .amount)
        currency = try values.decode(CurrencyDTO.self, forKey: .currency)
        note = try values.decodeIfPresent(String.self, forKey: .note)
        sender = try values.decodeIfPresent(TransferAcceptancePartyDTO.self, forKey: .sender)
        recipient = try values.decodeIfPresent(TransferAcceptancePartyDTO.self, forKey: .recipient)
        reason = try values.decodeIfPresent(String.self, forKey: .reason)
        resolvedBy = try values.decodeIfPresent(String.self, forKey: .resolvedBy)
        reversalTransactionId = try values.decodeIfPresent(
            String.self,
            forKey: .reversalTransactionId
        )
        expiresAt = try values.decodeIfPresent(String.self, forKey: .expiresAt)
        acceptedAt = try values.decodeIfPresent(String.self, forKey: .acceptedAt)
        returnedAt = try values.decodeIfPresent(String.self, forKey: .returnedAt)
        createdAt = try values.decodeIfPresent(String.self, forKey: .createdAt)
        canAccept = try values.decodeIfPresent(Bool.self, forKey: .canAccept) ?? false
        canReject = try values.decodeIfPresent(Bool.self, forKey: .canReject) ?? false
        canReverse = try values.decodeIfPresent(Bool.self, forKey: .canReverse) ?? false
    }

    var knownStatus: TransferAcceptanceStatus? {
        TransferAcceptanceStatus(rawValue: status)
    }

    var senderUserId: String? { sender?.id }
    var recipientUserId: String? { recipient?.id }
}

struct TransferAcceptancePartyDTO: Codable, Hashable {
    let id: String?
    let name: String?
    let phone: String?
}

// MARK: - Acceptance window

/// The escrow window and the canonical wording used everywhere the auto-reversal is explained.
enum TransferAcceptanceWindowPolicy {
    static let acceptanceWindowDays = 7

    /// The reason carried inside the auto-reversal chat receipt and shown under the bubble.
    /// Must stay within `KitPaymentMessage.maximumReasonLength`.
    static let autoReversalReason =
        "Reversed automatically: not accepted within 7 days, so the money returned to the sender."

    /// Whole days left before an unaccepted transfer auto-reverses, from the server's
    /// `expires_at`; nil when the timestamp is absent or unparseable.
    static func daysRemaining(untilExpiry expiresAt: String?, now: Date = Date()) -> Int? {
        guard let expiresAt, let expiry = parseTimestamp(expiresAt) else { return nil }
        let seconds = expiry.timeIntervalSince(now)
        guard seconds > 0 else { return 0 }
        return max(1, Int((seconds / 86_400).rounded(.up)))
    }

    static func pendingRecipientCopy(expiresAt: String?, now: Date = Date()) -> String {
        guard let days = daysRemaining(untilExpiry: expiresAt, now: now) else {
            return "Accept to add it to your wallet — unaccepted payments return to the sender after \(acceptanceWindowDays) days."
        }
        if days <= 0 {
            return "Accept to add it to your wallet — it is about to return to the sender."
        }
        let unit = days == 1 ? "day" : "days"
        return "Accept to add it to your wallet — it returns to the sender in \(days) \(unit)."
    }

    static func pendingSenderCopy(expiresAt: String?, now: Date = Date()) -> String {
        guard let days = daysRemaining(untilExpiry: expiresAt, now: now) else {
            return "Waiting for them to accept. Unaccepted payments come back to you after \(acceptanceWindowDays) days."
        }
        if days <= 0 {
            return "Waiting for them to accept. It is about to come back to you."
        }
        let unit = days == 1 ? "day" : "days"
        return "Waiting for them to accept. It comes back to you in \(days) \(unit)."
    }

    /// A deterministic message id for the auto-reversal receipt, derived from the transfer id,
    /// so the receipt is idempotent no matter how many times either device observes the expiry.
    static func autoReversalReceiptMessageID(forTransferID transferID: String) -> UUID {
        deterministicMessageID(
            namespace: "kit-transfer-auto-reversal:\(transferID.lowercased())"
        )
    }

    /// A stable, action-scoped id for a user-driven terminal receipt. The action is part of the
    /// namespace so it cannot collide with the original transfer card or the automatic-expiry
    /// receipt, while retries and multiple installations converge on one chat event.
    static func resolutionReceiptMessageID(
        forTransferID transferID: String,
        action: KitPaymentMessageAction
    ) -> UUID? {
        switch action {
        case .accepted, .rejected, .reversed:
            return deterministicMessageID(
                namespace: "kit-transfer-resolution:\(transferID.lowercased()):\(action.rawValue)"
            )
        case .request, .paid, .declined, .cancelled, .transfer, .sent, .expired:
            return nil
        }
    }

    private static func deterministicMessageID(namespace: String) -> UUID {
        let digest = SHA256.hash(data: Data(namespace.utf8))
        let bytes = Array(digest.prefix(16))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}

struct TransferAcceptanceListDTO: Decodable {
    let items: [TransferAcceptanceDTO]
    let page: CursorPage?
}

// MARK: - Durable transfer chat-receipt recovery

enum FinancialChatReceiptRecoveryPhase: String, Codable, Hashable, Sendable {
    /// The intent is durable, but no financial request has been allowed to start yet.
    case prepared
    /// The intent was made durable immediately before the financial request began. Its outcome
    /// is unknown until an exact recovery endpoint proves otherwise.
    case submitted
    /// The exact server result and deterministic encrypted descriptor are durable locally.
    case confirmed
}

enum FinancialChatReceiptRecoveryDecision: Equatable {
    case notCommitted
    case retain
}

/// Shared fail-closed error and retry rules for every financial-to-chat hand-off.
enum FinancialChatReceiptRecoveryPolicy {
    static let maximumPendingRecords = 16
    static let maximumRecordsPerRecoveryPass = 4
    static let preparedRetentionLifetime: TimeInterval = 7 * 24 * 60 * 60
    static let clockSkewAllowance: TimeInterval = 10 * 60

    /// Recovery errors are authoritative only when both the status and operation-specific code
    /// match. In-progress, reused-key, replay-unavailable, opaque, transport, cancellation, and
    /// every 5xx response retain the journal.
    static func recoveryDecision(
        for error: Error,
        notFoundCode: String
    ) -> FinancialChatReceiptRecoveryDecision {
        guard let payload = error as? APIErrorPayload,
              payload.httpStatus == 404,
              payload.code == notFoundCode
        else { return .retain }
        return .notCommitted
    }

    /// These codes are explicit pre-commit refusals from mutation endpoints. Everything else is
    /// ambiguous and keeps its idempotency authority until exact recovery resolves it.
    static func mutationWasDefinitivelyRejected(_ error: Error) -> Bool {
        guard let payload = error as? APIErrorPayload,
              let status = payload.httpStatus
        else { return false }
        switch (status, payload.code) {
        case (400, "VALIDATION_ERROR"),
             (409, "INSUFFICIENT_FUNDS"),
             (422, "VALIDATION_ERROR"),
             (422, "VALIDATION_FAILED"):
            return true
        default:
            return false
        }
    }

    static func nextRecoveryDate(afterAttempt attempt: Int, now: Date) -> Date {
        let exponent = min(max(attempt - 1, 0), 10)
        let delay = min(TimeInterval(5 * (1 << exponent)), 60 * 60)
        return now.addingTimeInterval(delay)
    }
}

/// The account-bound hand-off between one approved wallet transfer and its encrypted chat card.
///
/// This record is committed to `SecureLocalStore` *before* the financial POST. It contains no
/// step-up bearer token and cannot itself move money. Its stable UUID is also the backend
/// idempotency key, so an explicit retry of the exact intent can only recover the first result.
/// A server-confirmed descriptor is persisted here before the normal Signal outbox is touched;
/// the record is removed only after that deterministic message is durable in the encrypted
/// messaging store.
struct TransferChatReceiptRecoveryRecord: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let ownerUserID: String
    let sourceWalletID: String
    let destinationWalletID: String
    let recipientUserID: String
    let recipientName: String
    let conversationID: String?
    let amount: String
    let currencyCode: String
    let currencyScale: Int
    let note: String?
    let createdAt: Date
    var phase: FinancialChatReceiptRecoveryPhase
    var nextRecoveryAt: Date
    var recoveryAttemptCount: Int
    var confirmation: TransferChatReceiptConfirmation?

    var idempotencyKey: String {
        "ios-transfer-\(id.uuidString.lowercased())"
    }

    init?(
        id: UUID = UUID(),
        ownerUserID: String,
        sourceWalletID: String,
        destinationWalletID: String,
        recipientUserID: String,
        recipientName: String,
        conversationID: String?,
        amount: String,
        currency: CurrencyDTO,
        note: String?,
        createdAt: Date = Date()
    ) {
        let canonicalConversationID: String?
        if let conversationID {
            guard let value = Self.canonicalUUID(conversationID) else { return nil }
            canonicalConversationID = value
        } else {
            canonicalConversationID = nil
        }
        let canonicalNote: String?
        if let note {
            guard let value = Self.canonicalNote(note) else { return nil }
            canonicalNote = value
        } else {
            canonicalNote = nil
        }
        guard let ownerUserID = Self.canonicalUUID(ownerUserID),
              let sourceWalletID = Self.canonicalUUID(sourceWalletID),
              let destinationWalletID = Self.canonicalUUID(destinationWalletID),
              let recipientUserID = Self.canonicalUUID(recipientUserID),
              ownerUserID != recipientUserID,
              let currencyScale = Int(currency.scale),
              let amountMinor = KitPaymentMessage.minorUnits(
                  for: amount,
                  scale: currencyScale
              ),
              amountMinor > 0,
              let recipientName = Self.safeRecipientName(recipientName),
              Self.isCurrencyCode(currency.code),
              createdAt.timeIntervalSinceReferenceDate.isFinite
        else { return nil }

        self.id = id
        self.ownerUserID = ownerUserID
        self.sourceWalletID = sourceWalletID
        self.destinationWalletID = destinationWalletID
        self.recipientUserID = recipientUserID
        self.recipientName = recipientName
        self.conversationID = canonicalConversationID
        self.amount = amount
        self.currencyCode = currency.code
        self.currencyScale = currencyScale
        self.note = canonicalNote
        self.createdAt = createdAt
        phase = .prepared
        nextRecoveryAt = createdAt
        recoveryAttemptCount = 0
        confirmation = nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, ownerUserID, sourceWalletID, destinationWalletID, recipientUserID
        case recipientName, conversationID, amount, currencyCode, currencyScale, note, createdAt
        case phase, nextRecoveryAt, recoveryAttemptCount, confirmation
        // Development builds briefly wrote these names before exact recovery replaced history
        // matching. Decode them fail-closed so no ambiguous transfer loses its authority.
        case nextLookupAt, lookupAttemptCount
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        ownerUserID = try values.decode(String.self, forKey: .ownerUserID)
        sourceWalletID = try values.decode(String.self, forKey: .sourceWalletID)
        destinationWalletID = try values.decode(String.self, forKey: .destinationWalletID)
        recipientUserID = try values.decode(String.self, forKey: .recipientUserID)
        recipientName = try values.decode(String.self, forKey: .recipientName)
        conversationID = try values.decodeIfPresent(String.self, forKey: .conversationID)
        amount = try values.decode(String.self, forKey: .amount)
        currencyCode = try values.decode(String.self, forKey: .currencyCode)
        currencyScale = try values.decode(Int.self, forKey: .currencyScale)
        note = try values.decodeIfPresent(String.self, forKey: .note)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        confirmation = try values.decodeIfPresent(
            TransferChatReceiptConfirmation.self,
            forKey: .confirmation
        )
        phase = try values.decodeIfPresent(
            FinancialChatReceiptRecoveryPhase.self,
            forKey: .phase
        ) ?? (confirmation == nil ? .submitted : .confirmed)
        nextRecoveryAt = try values.decodeIfPresent(Date.self, forKey: .nextRecoveryAt)
            ?? values.decodeIfPresent(Date.self, forKey: .nextLookupAt)
            ?? createdAt
        recoveryAttemptCount = try values.decodeIfPresent(Int.self, forKey: .recoveryAttemptCount)
            ?? values.decodeIfPresent(Int.self, forKey: .lookupAttemptCount)
            ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(ownerUserID, forKey: .ownerUserID)
        try values.encode(sourceWalletID, forKey: .sourceWalletID)
        try values.encode(destinationWalletID, forKey: .destinationWalletID)
        try values.encode(recipientUserID, forKey: .recipientUserID)
        try values.encode(recipientName, forKey: .recipientName)
        try values.encodeIfPresent(conversationID, forKey: .conversationID)
        try values.encode(amount, forKey: .amount)
        try values.encode(currencyCode, forKey: .currencyCode)
        try values.encode(currencyScale, forKey: .currencyScale)
        try values.encodeIfPresent(note, forKey: .note)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(phase, forKey: .phase)
        try values.encode(nextRecoveryAt, forKey: .nextRecoveryAt)
        try values.encode(recoveryAttemptCount, forKey: .recoveryAttemptCount)
        try values.encodeIfPresent(confirmation, forKey: .confirmation)
    }

    var isStructurallyValid: Bool {
        baseIsStructurallyValid
            && (phase == .confirmed) == (confirmation != nil)
            && (confirmation.map { $0.isValid(for: self) } ?? true)
    }

    fileprivate var baseIsStructurallyValid: Bool {
        Self.canonicalUUID(ownerUserID) == ownerUserID
            && Self.canonicalUUID(sourceWalletID) == sourceWalletID
            && Self.canonicalUUID(destinationWalletID) == destinationWalletID
            && Self.canonicalUUID(recipientUserID) == recipientUserID
            && ownerUserID != recipientUserID
            && (conversationID == nil || Self.canonicalUUID(conversationID) == conversationID)
            && Self.safeRecipientName(recipientName) == recipientName
            && Self.canonicalNote(note) == note
            && Self.isCurrencyCode(currencyCode)
            && (0 ... 6).contains(currencyScale)
            && KitPaymentMessage.minorUnits(for: amount, scale: currencyScale).map { $0 > 0 }
                == true
            && createdAt.timeIntervalSinceReferenceDate.isFinite
            && nextRecoveryAt.timeIntervalSinceReferenceDate.isFinite
            && recoveryAttemptCount >= 0
            && idempotencyKey.utf8.count <= 128
    }

    fileprivate func hasSameFinancialAndChatIntent(
        as other: TransferChatReceiptRecoveryRecord
    ) -> Bool {
        ownerUserID == other.ownerUserID
            && sourceWalletID == other.sourceWalletID
            && destinationWalletID == other.destinationWalletID
            && recipientUserID == other.recipientUserID
            && conversationID == other.conversationID
            && amount == other.amount
            && currencyCode == other.currencyCode
            && currencyScale == other.currencyScale
            && note == other.note
    }

    fileprivate static func canonicalUUID(_ value: String?) -> String? {
        guard let value,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              let identifier = UUID(uuidString: value)
        else { return nil }
        return identifier.uuidString.lowercased()
    }

    private static func safeRecipientName(_ value: String) -> String? {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty,
              clean.count <= 100,
              clean.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              })
        else { return nil }
        return clean
    }

    private static func canonicalNote(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        guard clean == value,
              clean.utf16.count <= KitPaymentMessage.maximumNoteLength,
              clean.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              })
        else { return nil }
        return clean
    }

    private static func isCurrencyCode(_ value: String) -> Bool {
        value.range(of: #"^[A-Z]{3}$"#, options: .regularExpression) != nil
    }
}

/// The minimum server fact needed to reconstruct the same immutable `KITPAY1` card. The full
/// wallet transaction is deliberately not retained or copied into messaging state.
struct TransferChatReceiptConfirmation: Codable, Hashable, Sendable {
    enum Evidence {
        /// The exact response to the idempotent POST; a missing counterparty field is acceptable
        /// because the request itself was bound to the persisted destination wallet.
        case directResponse
        /// The exact idempotency-bound recovery response. It has the same authority as the
        /// original response and never relies on amount/time matching against wallet history.
        case exactRecovery
    }

    let transactionID: String
    let messageID: String
    let encodedDescriptor: String

    var clientMessageID: UUID? { UUID(uuidString: messageID) }

    init?(
        transaction: WalletTransaction,
        recovery: TransferChatReceiptRecoveryRecord,
        evidence: Evidence
    ) {
        guard recovery.baseIsStructurallyValid,
              CustomerTransactionPresentationPolicy.isCustomerVisible(transaction),
              let transactionID = Self.canonicalUUID(transaction.id),
              Self.canonicalUUID(transaction.walletId) == recovery.sourceWalletID,
              transaction.type.caseInsensitiveCompare("internal_transfer") == .orderedSame,
              transaction.direction.caseInsensitiveCompare("debit") == .orderedSame,
              transaction.currency.code == recovery.currencyCode,
              Int(transaction.currency.scale) == recovery.currencyScale,
              KitPaymentMessage.minorUnits(
                  for: transaction.amount,
                  scale: recovery.currencyScale
              ) == KitPaymentMessage.minorUnits(
                  for: recovery.amount,
                  scale: recovery.currencyScale
              ),
              transaction.note == recovery.note
        else { return nil }

        let action: KitPaymentMessageAction
        let messageID: String
        let authoritativeAmount: String
        let authoritativeCurrency: CurrencyDTO
        let authoritativeNote: String?
        if let claim = transaction.claim {
            guard let claimID = Self.canonicalUUID(claim.id),
                  claimID != transactionID,
                  Self.canonicalUUID(claim.transactionId) == transactionID,
                  Self.canonicalUUID(claim.senderUserId) == recovery.ownerUserID,
                  Self.canonicalUUID(claim.recipientUserId) == recovery.recipientUserID,
                  claim.knownStatus != nil
            else { return nil }
            action = .transfer
            messageID = claimID
            authoritativeAmount = claim.amount
            authoritativeCurrency = claim.currency
            authoritativeNote = claim.note
        } else {
            let counterpartyID = Self.canonicalUUID(transaction.counterparty?.id)
            switch evidence {
            case .directResponse, .exactRecovery:
                guard transaction.counterparty?.id == nil
                    || counterpartyID == recovery.recipientUserID
                else { return nil }
            }
            guard transaction.status.caseInsensitiveCompare("completed") == .orderedSame
                || transaction.status.caseInsensitiveCompare("succeeded") == .orderedSame
            else { return nil }
            action = .sent
            messageID = transactionID
            authoritativeAmount = transaction.amount
            authoritativeCurrency = transaction.currency
            authoritativeNote = transaction.note
        }

        guard authoritativeCurrency.code == recovery.currencyCode,
              Int(authoritativeCurrency.scale) == recovery.currencyScale,
              KitPaymentMessage.minorUnits(
                  for: authoritativeAmount,
                  scale: recovery.currencyScale
              ) == KitPaymentMessage.minorUnits(
                  for: recovery.amount,
                  scale: recovery.currencyScale
              ),
              authoritativeNote == recovery.note,
              let amountMinor = KitPaymentMessage.minorUnits(
                  for: authoritativeAmount,
                  scale: recovery.currencyScale
              ),
              let descriptor = KitPaymentMessage(
                  action: action,
                  paymentRequestId: messageID,
                  amountMinor: amountMinor,
                  currencyCode: recovery.currencyCode,
                  currencyScale: recovery.currencyScale,
                  note: recovery.note
              )
        else { return nil }

        self.transactionID = transactionID
        self.messageID = messageID
        encodedDescriptor = descriptor.encoded
    }

    func isValid(for recovery: TransferChatReceiptRecoveryRecord) -> Bool {
        guard let transactionID = Self.canonicalUUID(transactionID),
              transactionID == self.transactionID,
              let messageID = Self.canonicalUUID(messageID),
              messageID == self.messageID,
              let descriptor = KitPaymentMessage.parse(encodedDescriptor),
              descriptor.paymentRequestId == messageID,
              [.transfer, .sent].contains(descriptor.action),
              descriptor.currencyCode == recovery.currencyCode,
              descriptor.currencyScale == recovery.currencyScale,
              descriptor.amountMinor == KitPaymentMessage.minorUnits(
                  for: recovery.amount,
                  scale: recovery.currencyScale
              ),
              descriptor.note == recovery.note,
              descriptor.action == (messageID == transactionID ? .sent : .transfer)
        else { return false }
        return true
    }

    private static func canonicalUUID(_ value: String?) -> String? {
        TransferChatReceiptRecoveryRecord.canonicalUUID(value)
    }
}

/// Pure bounds and state transitions for the protected transfer recovery journal.
enum TransferChatReceiptRecoveryPolicy {
    static let maximumPendingRecords = FinancialChatReceiptRecoveryPolicy.maximumPendingRecords
    static let maximumRecordsPerRecoveryPass =
        FinancialChatReceiptRecoveryPolicy.maximumRecordsPerRecoveryPass

    @discardableResult
    static func sanitize(
        _ records: inout [TransferChatReceiptRecoveryRecord],
        ownerUserID: String? = nil,
        now: Date = Date()
    ) -> Int {
        let originalCount = records.count
        let canonicalOwner = ownerUserID.flatMap(
            TransferChatReceiptRecoveryRecord.canonicalUUID
        )
        records = records
            .sorted { left, right in
                FinancialRecoveryValidation.recoveryComesFirst(
                    leftPhase: left.phase,
                    leftDate: left.createdAt,
                    leftID: left.id,
                    rightPhase: right.phase,
                    rightDate: right.createdAt,
                    rightID: right.id
                )
            }
        var seen: Set<UUID> = []
        records = records
            .filter { record in
                let age = now.timeIntervalSince(record.createdAt)
                return record.isStructurallyValid
                    && (ownerUserID == nil || record.ownerUserID == canonicalOwner)
                    && age >= -FinancialChatReceiptRecoveryPolicy.clockSkewAllowance
                    && (record.phase != .prepared
                        || age <= FinancialChatReceiptRecoveryPolicy.preparedRetentionLifetime)
                    && seen.insert(record.id).inserted
            }
        return originalCount - records.count
    }

    /// Reuses every exact submitted/confirmed intent, and a still-live prepared intent. This is
    /// the explicit retry path that prevents a newly minted key from moving the same money twice.
    static func insertOrReuse(
        _ candidate: TransferChatReceiptRecoveryRecord,
        in records: inout [TransferChatReceiptRecoveryRecord],
        now: Date = Date()
    ) -> TransferChatReceiptRecoveryRecord? {
        guard candidate.isStructurallyValid else { return nil }
        sanitize(&records, ownerUserID: candidate.ownerUserID, now: now)
        if let existing = records.first(where: { record in
            record.hasSameFinancialAndChatIntent(as: candidate)
                && (record.phase != .prepared
                    || now.timeIntervalSince(record.createdAt)
                        <= FinancialChatReceiptRecoveryPolicy.preparedRetentionLifetime)
        }) {
            return existing
        }
        guard records.count < maximumPendingRecords else { return nil }
        records.append(candidate)
        return candidate
    }

    @discardableResult
    static func markSubmitted(
        recordID: UUID,
        in records: inout [TransferChatReceiptRecoveryRecord],
        now: Date = Date()
    ) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == recordID }),
              records[index].phase == .prepared,
              records[index].confirmation == nil
        else { return false }
        records[index].phase = .submitted
        records[index].nextRecoveryAt = now
        return true
    }

    @discardableResult
    static func storeConfirmation(
        _ confirmation: TransferChatReceiptConfirmation,
        for recordID: UUID,
        in records: inout [TransferChatReceiptRecoveryRecord]
    ) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == recordID }),
              records[index].phase != .prepared,
              confirmation.isValid(for: records[index]),
              records[index].confirmation.map({ $0 == confirmation }) ?? true
        else { return false }
        records[index].confirmation = confirmation
        records[index].phase = .confirmed
        return true
    }

    @discardableResult
    static func recordRecoveryFailure(
        for recordID: UUID,
        in records: inout [TransferChatReceiptRecoveryRecord],
        now: Date = Date()
    ) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == recordID }),
              records[index].phase == .submitted
        else { return false }
        if records[index].recoveryAttemptCount < Int.max {
            records[index].recoveryAttemptCount += 1
        }
        records[index].nextRecoveryAt = FinancialChatReceiptRecoveryPolicy.nextRecoveryDate(
            afterAttempt: records[index].recoveryAttemptCount,
            now: now
        )
        return true
    }

    static func isDefinitiveRejection(_ error: Error) -> Bool {
        FinancialChatReceiptRecoveryPolicy.mutationWasDefinitivelyRejected(error)
    }

    static func recoveryDecision(for error: Error) -> FinancialChatReceiptRecoveryDecision {
        FinancialChatReceiptRecoveryPolicy.recoveryDecision(
            for: error,
            notFoundCode: "TRANSFER_RECOVERY_NOT_FOUND"
        )
    }

    @discardableResult
    static func retireNotCommitted(
        recordID: UUID,
        in records: inout [TransferChatReceiptRecoveryRecord]
    ) -> Bool {
        guard let index = records.firstIndex(where: {
            $0.id == recordID && $0.phase == .submitted && $0.confirmation == nil
        }) else { return false }
        records.remove(at: index)
        return true
    }

    @discardableResult
    static func acknowledgeDurableMessage(
        recordID: UUID,
        messageID: UUID,
        in records: inout [TransferChatReceiptRecoveryRecord]
    ) -> Bool {
        guard let index = records.firstIndex(where: {
            $0.id == recordID
                && $0.phase == .confirmed
                && $0.confirmation?.clientMessageID == messageID
                && $0.confirmation?.isValid(for: $0) == true
        }) else { return false }
        records.remove(at: index)
        return true
    }
}

enum TransferChatReceiptRecoveryError: LocalizedError, Equatable {
    case invalidIntent
    case recoveryCapacityReached
    case accountChanged
    case unconfirmedTransfer

    var errorDescription: String? {
        switch self {
        case .invalidIntent:
            "Choose a valid Kit Pay recipient before sending money."
        case .recoveryCapacityReached:
            "Kit is still confirming earlier payment receipts. Check Wallet activity before trying again."
        case .accountChanged:
            "Your account changed before the payment was completed. Please try again."
        case .unconfirmedTransfer:
            "Kit Pay did not confirm the exact transfer total. Check your activity before trying again."
        }
    }
}

enum FinancialChatReceiptRecoveryError: LocalizedError, Equatable {
    case invalidIntent
    case recoveryCapacityReached
    case accountChanged
    case unconfirmedResult

    var errorDescription: String? {
        switch self {
        case .invalidIntent:
            "Kit Pay could not validate this financial chat action."
        case .recoveryCapacityReached:
            "Kit is still confirming earlier financial chat receipts. Please try again later."
        case .accountChanged:
            "Your account changed before the action completed. Please try again."
        case .unconfirmedResult:
            "Kit Pay could not confirm the exact result. Check activity before trying again."
        }
    }
}

// MARK: - Capability gate

/// Accept/Reject/Reverse exists only when the backend advertises it; without the capability,
/// transfers are what they always were — instant and final — and the chat event is a receipt.
struct TransferAcceptancePolicy: Equatable {
    let transfersEnabled: Bool
    let acceptanceEnabled: Bool

    init(features: [String: Bool?]?) {
        let enabled = features?.compactMapValues { $0 } ?? [:]
        transfersEnabled = enabled["wallets"] == true && enabled["internal_transfers"] == true
        acceptanceEnabled = transfersEnabled && enabled["claimable_transfers"] == true
    }
}

// MARK: - Descriptor ↔ authority resolution

/// The two accounts a chat transfer event may bind to: the signed-in user and the single
/// conversation peer. A transfer whose parties are anyone else — however real — must stay
/// inert in this conversation (a relayed descriptor must never gain live buttons).
struct KitTransferPartyBinding: Equatable {
    let currentUserID: String
    let peerUserID: String

    init?(currentUserID: String?, peerUserID: String?) {
        guard let current = currentUserID?.lowercased(), !current.isEmpty,
              let peer = peerUserID?.lowercased(), !peer.isEmpty,
              current != peer
        else { return nil }
        self.currentUserID = current
        self.peerUserID = peer
    }
}

enum KitTransferResolution: Equatable {
    case match(TransferAcceptanceDTO)
    case missing
    case mismatch
}

enum KitTransferResolutionPolicy {
    /// A chat transfer event may only act on a backend transfer whose id, amount, currency, AND
    /// parties all match: the transfer must be exactly between the signed-in user and this
    /// conversation's peer. Fails closed when the backend omits either party.
    static func resolve(
        _ descriptor: KitPaymentMessage,
        in transfers: [TransferAcceptanceDTO],
        binding: KitTransferPartyBinding
    ) -> KitTransferResolution {
        guard descriptor.action == .transfer else { return .mismatch }
        let candidates = transfers.filter {
            $0.id.lowercased() == descriptor.paymentRequestId
        }
        guard !candidates.isEmpty else { return .missing }
        guard candidates.count == 1,
              let transfer = candidates.first,
              transfer.knownStatus != nil,
              descriptor.matchesAuthoritativeTransfer(transfer),
              let sender = transfer.senderUserId?.lowercased(),
              let recipient = transfer.recipientUserId?.lowercased(),
              sender != recipient,
              Set([sender, recipient]) == Set([binding.currentUserID, binding.peerUserID])
        else { return .mismatch }
        return .match(transfer)
    }
}

extension KitPaymentMessage {
    /// Field-exact check against the backend's transfer object.
    func matchesAuthoritativeTransfer(_ transfer: TransferAcceptanceDTO) -> Bool {
        guard let scale = Int(transfer.currency.scale),
              let transferMinor = Self.minorUnits(for: transfer.amount, scale: scale)
        else { return false }
        return transfer.id.lowercased() == paymentRequestId
            && transfer.currency.code == currencyCode
            && scale == currencyScale
            && transferMinor == amountMinor
    }
}

// MARK: - Offline thread fallback

/// The latest transfer outcome visible INSIDE the conversation itself, derived from the
/// encrypted response events (`accepted`/`rejected`/`reversed`) that reference a transfer id.
/// Used only as an offline hint — buttons always require the authoritative object — and only
/// when the event's author could truthfully produce that outcome: the transfer's recipient
/// authors accept/reject, its sender authors a reversal. A counterpart cannot forge the
/// outcome that is not theirs to declare (e.g. a payer forging "Accepted · Final" to make a
/// merchant hand over goods against a still-reversible payment).
enum KitTransferThreadStatePolicy {
    static func latestLocalOutcome(
        forTransferID transferID: String,
        transferIsOutgoing: Bool,
        messages: [LocalMessage]
    ) -> KitPaymentMessageAction? {
        var outcome: KitPaymentMessageAction?
        for message in messages {
            guard let descriptor = KitPaymentMessage.parse(message.body),
                  descriptor.paymentRequestId.caseInsensitiveCompare(transferID) == .orderedSame
            else { continue }
            switch descriptor.action {
            case .accepted, .rejected:
                // The recipient authors these: the opposite direction of the transfer event.
                if message.isOutgoing != transferIsOutgoing {
                    outcome = descriptor.action
                }
            case .reversed, .expired:
                // The sender authors this: the same direction as the transfer event.
                if message.isOutgoing == transferIsOutgoing {
                    outcome = descriptor.action
                }
            case .request, .paid, .declined, .cancelled, .transfer, .sent:
                continue
            }
        }
        return outcome
    }
}

// MARK: - Presentation

struct KitTransferMessagePresentation: Equatable {
    let title: String
    let statusText: String
    let showsAccept: Bool
    let showsReject: Bool
    let showsReverse: Bool

    var showsAnyAction: Bool { showsAccept || showsReject || showsReverse }
}

enum KitTransferMessagePresentationPolicy {
    /// Presentation ladder for a `.transfer` chat event and its response events.
    ///
    /// - The response events (`accepted`/`rejected`/`reversed`) are immutable receipts.
    /// - A `.transfer` event under the acceptance capability offers Accept/Reject to the
    ///   recipient and Reverse to the sender only while the AUTHORITATIVE status is still
    ///   `pending` — never from the descriptor or the thread hint alone.
    /// - Without the capability, a `transfer` event stays inert; immediate transfers use `sent`.
    static func presentation(
        for descriptor: KitPaymentMessage,
        isOutgoing: Bool,
        authoritativeTransfer: TransferAcceptanceDTO?,
        localOutcome: KitPaymentMessageAction?,
        binding: KitTransferPartyBinding?,
        acceptanceEnabled: Bool,
        isOnline: Bool
    ) -> KitTransferMessagePresentation {
        switch descriptor.action {
        case .accepted:
            return receipt(
                title: "Payment accepted",
                statusText: "The payment is now final."
            )
        case .rejected:
            return receipt(
                title: "Payment declined",
                statusText: isOutgoing
                    ? "You declined it. The money went back to the sender."
                    : "The money was returned to you."
            )
        case .reversed:
            return receipt(
                title: "Payment reversed",
                statusText: isOutgoing
                    ? "You reversed it before it was accepted."
                    : "The sender reversed it before it was accepted."
            )
        case .expired:
            return receipt(
                title: "Payment returned",
                statusText: "Not accepted within \(TransferAcceptanceWindowPolicy.acceptanceWindowDays) days"
            )
        case .sent:
            return receipt(
                title: isOutgoing ? "Payment sent" : "Payment received",
                statusText: "Completed"
            )
        case .request, .paid, .declined, .cancelled:
            // Requests/paid events belong to KitPaymentMessagePresentationPolicy.
            return receipt(title: "Payment", statusText: "")
        case .transfer:
            break
        }

        guard acceptanceEnabled else {
            return receipt(
                title: "Payment awaiting acceptance",
                statusText: isOnline ? "This payment cannot be updated yet" : "Connect to see the latest status"
            )
        }

        if let authoritativeTransfer,
           descriptor.matchesAuthoritativeTransfer(authoritativeTransfer) {
            // Buttons additionally bind to the transfer's OWN parties, never chat direction
            // alone: Accept/Reject belong to the transfer's recipient, Reverse to its sender.
            let currentUserID = binding?.currentUserID
            let currentUserIsRecipient = currentUserID != nil
                && authoritativeTransfer.recipientUserId?.lowercased() == currentUserID
            let currentUserIsSender = currentUserID != nil
                && authoritativeTransfer.senderUserId?.lowercased() == currentUserID
            switch authoritativeTransfer.knownStatus {
            case .pending:
                if isOutgoing {
                    return KitTransferMessagePresentation(
                        title: "Payment sent",
                        statusText: TransferAcceptanceWindowPolicy.pendingSenderCopy(
                            expiresAt: authoritativeTransfer.expiresAt
                        ) + (isOnline && authoritativeTransfer.canReverse
                            ? " You can still reverse it."
                            : ""),
                        showsAccept: false,
                        showsReject: false,
                        showsReverse: isOnline
                            && currentUserIsSender
                            && authoritativeTransfer.canReverse
                    )
                }
                return KitTransferMessagePresentation(
                    title: "Payment received",
                    statusText: isOnline
                        ? TransferAcceptanceWindowPolicy.pendingRecipientCopy(
                            expiresAt: authoritativeTransfer.expiresAt
                        )
                        : "Connect to accept or decline.",
                    showsAccept: isOnline
                        && currentUserIsRecipient
                        && authoritativeTransfer.canAccept,
                    showsReject: isOnline
                        && currentUserIsRecipient
                        && authoritativeTransfer.canReject,
                    showsReverse: false
                )
            case .accepted:
                return receipt(
                    title: isOutgoing ? "Payment sent" : "Payment received",
                    statusText: "Accepted · Final"
                )
            case .rejected:
                return receipt(
                    title: isOutgoing ? "Payment sent" : "Payment received",
                    statusText: "Declined · Money returned to the sender"
                )
            case .reversed:
                return receipt(
                    title: isOutgoing ? "Payment sent" : "Payment received",
                    statusText: "Reversed by the sender"
                )
            case .expired:
                return receipt(
                    title: isOutgoing ? "Payment sent" : "Payment received",
                    statusText: "Returned automatically · Not accepted within \(TransferAcceptanceWindowPolicy.acceptanceWindowDays) days"
                )
            case nil:
                return receipt(
                    title: isOutgoing ? "Payment sent" : "Payment received",
                    statusText: authoritativeTransfer.status
                        .replacingOccurrences(of: "_", with: " ")
                        .capitalized
                )
            }
        }

        // No authoritative object yet: response events already exchanged in this thread are a
        // truthful hint, and never enable a button.
        if let localOutcome {
            switch localOutcome {
            case .accepted:
                return receipt(
                    title: isOutgoing ? "Payment sent" : "Payment received",
                    statusText: "Accepted · Final"
                )
            case .rejected:
                return receipt(
                    title: isOutgoing ? "Payment sent" : "Payment received",
                    statusText: "Declined · Money returned to the sender"
                )
            case .reversed:
                return receipt(
                    title: isOutgoing ? "Payment sent" : "Payment received",
                    statusText: "Reversed by the sender"
                )
            case .expired:
                return receipt(
                    title: isOutgoing ? "Payment sent" : "Payment received",
                    statusText: "Returned automatically · Not accepted within \(TransferAcceptanceWindowPolicy.acceptanceWindowDays) days"
                )
            case .request, .paid, .declined, .cancelled, .transfer, .sent:
                break
            }
        }
        return receipt(
            title: isOutgoing ? "Payment sent" : "Payment received",
            statusText: isOnline ? "Verifying payment status" : "Connect to see the latest status"
        )
    }

    private static func receipt(
        title: String,
        statusText: String
    ) -> KitTransferMessagePresentation {
        KitTransferMessagePresentation(
            title: title,
            statusText: statusText,
            showsAccept: false,
            showsReject: false,
            showsReverse: false
        )
    }
}
