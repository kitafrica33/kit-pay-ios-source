import Foundation

enum PaymentRequestStatus: String, Codable, CaseIterable {
    case pending
    case paid
    case cancelled
    case expired
}

struct PaymentRequestDTO: Decodable, Hashable, Identifiable {
    let id: String
    let type: String
    let status: String
    let destinationWalletId: String
    let requestedFromUserId: String?
    let amount: String
    let currency: CurrencyDTO
    let note: String?
    let expiresAt: String?
    let walletTransactionId: String?
    let paidAt: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, type, status, amount, currency, note
        case destinationWalletId = "destination_wallet_id"
        case requestedFromUserId = "requested_from_user_id"
        case expiresAt = "expires_at"
        case walletTransactionId = "wallet_transaction_id"
        case paidAt = "paid_at"
        case createdAt = "created_at"
    }

    var knownStatus: PaymentRequestStatus? { PaymentRequestStatus(rawValue: status) }
}

struct PaymentRequestListDTO: Decodable {
    let items: [PaymentRequestDTO]
}

// MARK: - Server-side scheduled payments

enum ScheduledPaymentStatus: String, Codable, CaseIterable, Sendable {
    case scheduled
    case queued
    case processing
    case completed
    case failed
    case cancelled

    var isTerminal: Bool { [.completed, .failed, .cancelled].contains(self) }
}

enum PaymentExecutionStatus: String, Codable, CaseIterable, Sendable {
    case queued
    case processing
    case completed
    case failed
}

struct ScheduledPaymentFailureDTO: Decodable, Hashable, Sendable {
    let code: String
    let message: String

    var isStructurallyValid: Bool {
        !code.isEmpty
            && code.utf8.count <= 120
            && !message.isEmpty
            && message.utf16.count <= 500
            && !message.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
    }
}

/// One immutable payment instruction held by the backend until `scheduledFor`.
///
/// Unlike a delayed encrypted message, this is intentionally server-side: money can therefore
/// move at the agreed time while the phone is locked, offline, or terminated by iOS. Every DTO is
/// checked as a coherent state machine before it is shown or used for a follow-up action.
struct ScheduledPaymentDTO: Decodable, Hashable, Identifiable, Sendable {
    let id: String
    let type: String
    let status: String
    let conversationId: String?
    /// Redacted from a completed recipient's exact-read projection.
    let sourceWalletId: String?
    let destinationWalletId: String
    let amount: String
    let currency: CurrencyDTO
    let note: String?
    let scheduledFor: String
    let paymentExecutionId: String?
    let walletTransactionId: String?
    let failure: ScheduledPaymentFailureDTO?
    let completedAt: String?
    let cancelledAt: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, type, status, amount, currency, note, failure
        case conversationId = "conversation_id"
        case sourceWalletId = "source_wallet_id"
        case destinationWalletId = "destination_wallet_id"
        case scheduledFor = "scheduled_for"
        case paymentExecutionId = "payment_execution_id"
        case walletTransactionId = "wallet_transaction_id"
        case completedAt = "completed_at"
        case cancelledAt = "cancelled_at"
        case createdAt = "created_at"
    }

    var knownStatus: ScheduledPaymentStatus? { ScheduledPaymentStatus(rawValue: status) }
    var currencyScale: Int { currency.decimalScale }
    var amountMinor: Int64? {
        KitPaymentMessage.minorUnits(for: amount, scale: currencyScale)
    }
    var scheduledDate: Date? { ScheduledPaymentDates.parse(scheduledFor) }

    var isStructurallyValid: Bool {
        guard type == "scheduled_payment",
              ScheduledPaymentValidation.canonicalUUID(id) != nil,
              sourceWalletId.map({ ScheduledPaymentValidation.canonicalUUID($0) != nil }) ?? true,
              sourceWalletId != nil || knownStatus == .completed,
              ScheduledPaymentValidation.canonicalUUID(destinationWalletId) != nil,
              sourceWalletId.map({
                  $0.caseInsensitiveCompare(destinationWalletId) != .orderedSame
              }) ?? true,
              conversationId.map({ ScheduledPaymentValidation.canonicalUUID($0) != nil }) ?? true,
              let status = knownStatus,
              (0 ... 6).contains(currencyScale),
              ScheduledPaymentValidation.isCurrencyCode(currency.code),
              amountMinor != nil,
              scheduledDate != nil,
              createdAt.map({ ScheduledPaymentDates.parse($0) != nil }) ?? true,
              (note?.utf16.count ?? 0) <= 280,
              paymentExecutionId.map({ ScheduledPaymentValidation.canonicalUUID($0) != nil })
                ?? true,
              walletTransactionId.map({ ScheduledPaymentValidation.canonicalUUID($0) != nil })
                ?? true,
              completedAt.map({ ScheduledPaymentDates.parse($0) != nil }) ?? true,
              cancelledAt.map({ ScheduledPaymentDates.parse($0) != nil }) ?? true,
              failure.map(\.isStructurallyValid) ?? true
        else { return false }

        switch status {
        case .scheduled:
            return paymentExecutionId == nil
                && walletTransactionId == nil
                && failure == nil
                && completedAt == nil
                && cancelledAt == nil
        case .queued, .processing:
            return paymentExecutionId != nil
                && walletTransactionId == nil
                && failure == nil
                && completedAt == nil
                && cancelledAt == nil
        case .completed:
            return (paymentExecutionId != nil || sourceWalletId == nil)
                && walletTransactionId != nil
                && failure == nil
                && completedAt != nil
                && cancelledAt == nil
        case .failed:
            return paymentExecutionId != nil
                && walletTransactionId == nil
                && failure != nil
                && completedAt != nil
                && cancelledAt == nil
        case .cancelled:
            return paymentExecutionId == nil
                && walletTransactionId == nil
                && failure == nil
                && completedAt == nil
                && cancelledAt != nil
        }
    }
}

struct ScheduledPaymentListDTO: Decodable, Sendable {
    let items: [ScheduledPaymentDTO]
    let hasMore: Bool
    let nextBefore: String?

    enum CodingKeys: String, CodingKey {
        case items
        case hasMore = "has_more"
        case nextBefore = "next_before"
    }

    var isStructurallyValid: Bool {
        items.count <= 100
            && items.allSatisfy(\.isStructurallyValid)
            && (hasMore
                ? ScheduledPaymentValidation.canonicalUUID(nextBefore) != nil
                : nextBefore == nil)
    }
}

struct CreateScheduledPaymentBody: Encodable, Equatable, Sendable {
    let sourceWalletId: String
    let destinationWalletId: String
    let conversationId: String?
    let amount: String
    let note: String?
    let scheduledFor: String

    enum CodingKeys: String, CodingKey {
        case amount, note
        case sourceWalletId = "source_wallet_id"
        case destinationWalletId = "destination_wallet_id"
        case conversationId = "conversation_id"
        case scheduledFor = "scheduled_for"
    }
}

struct PaymentExecutionDTO: Decodable, Hashable, Identifiable, Sendable {
    let id: String
    let type: String
    let status: String
    let instructionType: String
    let instructionId: String
    let occurrenceNumber: Int
    let walletTransactionId: String?
    let scheduledFor: String
    let failure: ScheduledPaymentFailureDTO?

    enum CodingKeys: String, CodingKey {
        case id, type, status, failure
        case instructionType = "instruction_type"
        case instructionId = "instruction_id"
        case occurrenceNumber = "occurrence_number"
        case walletTransactionId = "wallet_transaction_id"
        case scheduledFor = "scheduled_for"
    }

    var knownStatus: PaymentExecutionStatus? { PaymentExecutionStatus(rawValue: status) }

    var isStructurallyValid: Bool {
        guard type == "payment_execution",
              ScheduledPaymentValidation.canonicalUUID(id) != nil,
              ScheduledPaymentValidation.canonicalUUID(instructionId) != nil,
              instructionType == "scheduled",
              occurrenceNumber == 1,
              let status = knownStatus,
              ScheduledPaymentDates.parse(scheduledFor) != nil,
              walletTransactionId.map({ ScheduledPaymentValidation.canonicalUUID($0) != nil })
                ?? true,
              failure.map(\.isStructurallyValid) ?? true
        else { return false }
        switch status {
        case .queued, .processing:
            return walletTransactionId == nil && failure == nil
        case .completed:
            return walletTransactionId != nil && failure == nil
        case .failed:
            return walletTransactionId == nil && failure != nil
        }
    }
}

enum ScheduledPaymentDates {
    static func apiString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func parse(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = fractional.date(from: raw) { return value }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

enum ScheduledPaymentValidation {
    static func canonicalUUID(_ raw: String?) -> String? {
        guard let raw,
              raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
              let value = UUID(uuidString: raw)
        else { return nil }
        return value.uuidString.lowercased()
    }

    static func isCurrencyCode(_ raw: String) -> Bool {
        raw.range(of: #"^[A-Z]{3}$"#, options: .regularExpression) != nil
    }
}

struct ScheduledPaymentPolicy: Equatable, Sendable {
    let enabled: Bool
    let chatEnabled: Bool

    init(capabilities: CapabilitiesDTO?) {
        enabled = capabilities?.supportsFeature("wallets") == true
            && capabilities?.supportsFeature("internal_transfers") == true
            && capabilities?.supportsFeature("scheduled_payments") == true
        chatEnabled = enabled
            && capabilities?.supportsFeature("scheduled_chat_payments_v1") == true
            && capabilities?.protocols?.payments?.scheduledChatPayments?.supportsIOSV1 == true
    }

    static func intent(
        sourceWalletID: String,
        destinationWalletID: String,
        amount: String,
        currencyCode: String,
        note: String?,
        scheduledFor: Date,
        conversationID: String?
    ) -> [String: String?] {
        var value: [String: String?] = [
            "action": "create",
            "source_wallet_id": sourceWalletID,
            "destination_wallet_id": destinationWalletID,
            "amount": amount,
            "currency": currencyCode,
            "note": note,
            "scheduled_for": ScheduledPaymentDates.apiString(scheduledFor),
        ]
        if let conversationID { value["conversation_id"] = conversationID }
        return value
    }

    static func confirms(
        _ payment: ScheduledPaymentDTO,
        sourceWalletID: String,
        destinationWalletID: String,
        amount: String,
        currency: CurrencyDTO,
        note: String?,
        scheduledFor: Date,
        conversationID: String?
    ) -> Bool {
        payment.isStructurallyValid
            && payment.knownStatus == .scheduled
            && payment.sourceWalletId?.caseInsensitiveCompare(sourceWalletID) == .orderedSame
            && payment.destinationWalletId.caseInsensitiveCompare(destinationWalletID)
                == .orderedSame
            && payment.amount == amount
            && payment.currency == currency
            && payment.note == note
            && payment.conversationId?.lowercased() == conversationID?.lowercased()
            && payment.scheduledDate == scheduledFor
    }
}

enum KitScheduledPaymentMessageAction: String, Equatable, Sendable, CaseIterable {
    case completed
    case failed
    case cancelled
}

/// A local projection of an authenticated server sync event. It is never accepted from an E2EE
/// message: `isTrustedProjection` binds the descriptor to its deterministic local id and requires
/// the absence of a server message id/history record, so a peer cannot forge a payment receipt.
struct KitScheduledPaymentMessage: Equatable, Sendable {
    static let prefix = "KITSCHPAY1:"
    static let maximumDescriptorLength = 2_048

    let action: KitScheduledPaymentMessageAction
    let scheduledPaymentID: String
    let amountMinor: Int64
    let currencyCode: String
    let currencyScale: Int
    let scheduledAtUnixSeconds: Int64
    let walletTransactionID: String?
    let note: String?
    let reason: String?

    init?(
        action: KitScheduledPaymentMessageAction,
        scheduledPaymentID: String,
        amountMinor: Int64,
        currencyCode: String,
        currencyScale: Int,
        scheduledAt: Date,
        walletTransactionID: String?,
        note: String?,
        reason: String?
    ) {
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedNote = trimmedNote?.isEmpty == false ? trimmedNote : nil
        let trimmedReason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedReason = trimmedReason?.isEmpty == false ? trimmedReason : nil
        guard let id = ScheduledPaymentValidation.canonicalUUID(scheduledPaymentID),
              id == scheduledPaymentID,
              (1 ... KitPaymentMessage.maximumAmountMinor).contains(amountMinor),
              ScheduledPaymentValidation.isCurrencyCode(currencyCode),
              (0 ... 6).contains(currencyScale),
              scheduledAt.timeIntervalSince1970.isFinite,
              scheduledAt.timeIntervalSince1970 > 0,
              (normalizedNote?.utf16.count ?? 0) <= 280,
              (normalizedReason?.utf16.count ?? 0) <= 280,
              normalizedNote.map(Self.hasNoControlCharacters) ?? true,
              normalizedReason.map(Self.hasNoControlCharacters) ?? true,
              walletTransactionID.map({ ScheduledPaymentValidation.canonicalUUID($0) != nil })
                ?? true,
              action == .completed ? walletTransactionID != nil : walletTransactionID == nil,
              action != .failed || normalizedReason != nil
        else { return nil }
        self.action = action
        self.scheduledPaymentID = id
        self.amountMinor = amountMinor
        self.currencyCode = currencyCode
        self.currencyScale = currencyScale
        self.scheduledAtUnixSeconds = Int64(scheduledAt.timeIntervalSince1970.rounded(.down))
        self.walletTransactionID = walletTransactionID?.lowercased()
        self.note = normalizedNote
        self.reason = normalizedReason
        guard encoded.utf16.count <= Self.maximumDescriptorLength else { return nil }
    }

    var scheduledAt: Date { Date(timeIntervalSince1970: TimeInterval(scheduledAtUnixSeconds)) }
    var decimalAmount: String { KitMoney.decimal(minorUnits: amountMinor, scale: currencyScale) }

    var encoded: String {
        var value = Self.prefix
        value += "v=1&a=\(action.rawValue)&id=\(scheduledPaymentID)"
        value += "&amt=\(amountMinor)&cur=\(currencyCode)&sc=\(currencyScale)"
        value += "&at=\(scheduledAtUnixSeconds)"
        if let walletTransactionID { value += "&tx=\(walletTransactionID)" }
        if let note { value += "&note=\(Self.percentEncode(note))" }
        if let reason { value += "&rsn=\(Self.percentEncode(reason))" }
        return value
    }

    static func parse(_ text: String) -> KitScheduledPaymentMessage? {
        guard text.hasPrefix(prefix), text.utf16.count <= maximumDescriptorLength else { return nil }
        var fields: [String: String] = [:]
        for pair in text.dropFirst(prefix.count).split(separator: "&", omittingEmptySubsequences: false) {
            guard let separator = pair.firstIndex(of: "="), separator != pair.startIndex else {
                return nil
            }
            let key = String(pair[..<separator])
            let encoded = String(pair[pair.index(after: separator)...])
            guard fields[key] == nil,
                  let value = encoded.replacingOccurrences(of: "+", with: "%20")
                    .removingPercentEncoding
            else { return nil }
            fields[key] = value
        }
        guard fields["v"] == "1",
              let action = fields["a"].flatMap(KitScheduledPaymentMessageAction.init(rawValue:)),
              let id = fields["id"],
              let amount = fields["amt"].flatMap(Int64.init),
              let currency = fields["cur"],
              let scale = fields["sc"].flatMap(Int.init),
              let seconds = fields["at"].flatMap(Int64.init),
              let descriptor = KitScheduledPaymentMessage(
                  action: action,
                  scheduledPaymentID: id,
                  amountMinor: amount,
                  currencyCode: currency,
                  currencyScale: scale,
                  scheduledAt: Date(timeIntervalSince1970: TimeInterval(seconds)),
                  walletTransactionID: fields["tx"],
                  note: fields["note"],
                  reason: fields["rsn"]
              ),
              descriptor.encoded == text
        else { return nil }
        return descriptor
    }

    var deterministicMessageID: UUID {
        KitSystemMessage.deterministicMessageID(
            namespace: "kit-scheduled-payment-event:\(scheduledPaymentID):\(action.rawValue)"
        )
    }

    func isTrustedProjection(_ message: LocalMessage) -> Bool {
        message.id == deterministicMessageID
            && message.serverMessageId == nil
            && message.secureMessagingHistory == nil
            && message.pendingAttachment == nil
            && message.pendingMediaBatch == nil
            && message.attachmentData == nil
            && message.failureReason == nil
            && message.scheduledAt == nil
    }

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

    private static func hasNoControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}

struct ScheduledPaymentSyncEnvelope: Equatable, Sendable {
    let action: KitScheduledPaymentMessageAction
    let scheduledPaymentID: String
    let conversationID: String
    let senderUserID: String
    let recipientUserID: String
    let descriptor: KitScheduledPaymentMessage
    let occurredAt: Date

    init?(event: MessagingSyncEventDTO, currentUserID: String) {
        guard let eventType = event.type,
              let action = Self.action(for: eventType),
              event.resourceType == "scheduled_payment",
              let data = event.data,
              data.schema == "kit.scheduled-payment.v1",
              let rawID = data.scheduledPaymentId,
              let id = ScheduledPaymentValidation.canonicalUUID(rawID),
              rawID == id,
              event.resourceId == id,
              let rawConversationID = data.conversationId,
              let conversationID = ScheduledPaymentValidation.canonicalUUID(rawConversationID),
              rawConversationID == conversationID,
              event.conversationId == conversationID,
              let rawSenderID = data.senderUserId,
              let senderID = ScheduledPaymentValidation.canonicalUUID(rawSenderID),
              rawSenderID == senderID,
              let rawRecipientID = data.recipientUserId,
              let recipientID = ScheduledPaymentValidation.canonicalUUID(rawRecipientID),
              rawRecipientID == recipientID,
              senderID != recipientID,
              let current = ScheduledPaymentValidation.canonicalUUID(currentUserID),
              current == senderID || (action == .completed && current == recipientID),
              data.status == action.rawValue,
              let rawAmountMinor = data.amountMinor,
              let amountMinor = GroupPaymentRequestValidation.canonicalMinorUnits(rawAmountMinor),
              let currency = data.currency,
              let scale = data.currencyScale,
              let scheduledAtText = data.scheduledFor,
              let scheduledAt = ScheduledPaymentDates.parse(scheduledAtText),
              let occurredAtText = event.occurredAt,
              let occurredAt = ScheduledPaymentDates.parse(occurredAtText),
              let descriptor = KitScheduledPaymentMessage(
                  action: action,
                  scheduledPaymentID: id,
                  amountMinor: amountMinor,
                  currencyCode: currency,
                  currencyScale: scale,
                  scheduledAt: scheduledAt,
                  walletTransactionID: data.walletTransactionId,
                  note: data.note,
                  reason: Self.reason(action: action, data: data)
              )
        else { return nil }
        switch action {
        case .completed:
            guard data.failureCode == nil,
                  data.failureMessage == nil,
                  data.cancelledAt == nil,
                  data.completedAt.flatMap(ScheduledPaymentDates.parse) != nil
            else { return nil }
        case .failed:
            guard data.failureCode?.isEmpty == false,
                  data.completedAt.flatMap(ScheduledPaymentDates.parse) != nil,
                  data.cancelledAt == nil,
                  data.walletTransactionId == nil
            else { return nil }
        case .cancelled:
            guard data.cancelledAt.flatMap(ScheduledPaymentDates.parse) != nil,
                  data.walletTransactionId == nil
            else { return nil }
        }
        self.action = action
        self.scheduledPaymentID = id
        self.conversationID = conversationID
        self.senderUserID = senderID
        self.recipientUserID = recipientID
        self.descriptor = descriptor
        self.occurredAt = occurredAt
    }

    func matchesDirectConversation(memberUserIDs: Set<String>) -> Bool {
        memberUserIDs == Set([senderUserID, recipientUserID])
    }

    func matchesAuthoritative(_ payment: ScheduledPaymentDTO) -> Bool {
        guard payment.isStructurallyValid,
              payment.id == scheduledPaymentID,
              payment.conversationId == conversationID,
              payment.knownStatus?.rawValue == action.rawValue,
              payment.amountMinor == descriptor.amountMinor,
              payment.currency.code == descriptor.currencyCode,
              payment.currencyScale == descriptor.currencyScale,
              payment.scheduledDate == descriptor.scheduledAt,
              payment.walletTransactionId == descriptor.walletTransactionID,
              payment.note == descriptor.note
        else { return false }
        switch action {
        case .completed:
            return payment.failure == nil && payment.completedAt != nil
        case .failed:
            return payment.failure?.isStructurallyValid == true
                && (Self.safeFailureMessage(payment.failure?.message)
                    ?? "The scheduled payment could not be sent.") == descriptor.reason
        case .cancelled:
            return payment.failure == nil && payment.cancelledAt != nil
        }
    }

    private static func action(for eventType: String) -> KitScheduledPaymentMessageAction? {
        switch eventType {
        case "scheduled_payment.completed": .completed
        case "scheduled_payment.failed": .failed
        case "scheduled_payment.cancelled": .cancelled
        default: nil
        }
    }

    private static func reason(
        action: KitScheduledPaymentMessageAction,
        data: MessagingSyncEventDataDTO
    ) -> String? {
        switch action {
        case .completed: nil
        case .failed:
            Self.safeFailureMessage(data.failureMessage)
                ?? "The scheduled payment could not be sent."
        case .cancelled:
            "The scheduled payment was cancelled."
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func safeFailureMessage(_ value: String?) -> String? {
        guard let value = nonEmpty(value),
              value.utf16.count <= 280,
              value.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              })
        else { return nil }
        return value
    }
}

enum KitPaymentMessageAction: String, Equatable, Sendable, CaseIterable {
    case request
    case paid
    /// The peer declined a payment request. No money moved.
    case declined
    /// The requester withdrew their own payment request. No money moved.
    case cancelled
    /// A held Kit Pay → Kit Pay transfer event; `id` carries the transfer claim id.
    case transfer
    /// A Kit Pay → Kit Pay transfer that settled immediately on a backend without acceptance.
    case sent
    /// Recipient accepted a pending transfer — the payment is final.
    case accepted
    /// Recipient rejected a pending transfer — the money returned to the sender.
    case rejected
    /// Sender reversed a pending transfer before it was accepted.
    case reversed
    /// Nobody acted before the acceptance window closed, so the server returned the money.
    case expired

    var isTransferEvent: Bool {
        ![.request, .paid, .declined, .cancelled].contains(self)
    }

    var returnedFunds: Bool {
        [.rejected, .reversed, .expired].contains(self)
    }

    var movesMoney: Bool {
        ![.request, .declined, .cancelled].contains(self)
    }
}

/// Canonical payment descriptor carried inside the end-to-end encrypted message body.
/// Its fixed order and strict re-encoding match Android's `KITPAY1` wire contract.
struct KitPaymentMessage: Equatable, Sendable {
    static let prefix = "KITPAY1:"
    static let maximumDescriptorLength = 1_024
    static let maximumNoteLength = 140
    static let maximumReasonLength = 140
    static let maximumAmountMinor: Int64 = 1_000_000_000_000

    let action: KitPaymentMessageAction
    let paymentRequestId: String
    let amountMinor: Int64
    let currencyCode: String
    let currencyScale: Int
    let note: String?
    let reason: String?

    init?(
        action: KitPaymentMessageAction,
        paymentRequestId: String,
        amountMinor: Int64,
        currencyCode: String,
        currencyScale: Int,
        note: String?,
        reason: String? = nil
    ) {
        let normalizedNote: String?
        if let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalizedNote = note
        } else {
            normalizedNote = nil
        }
        let normalizedReason: String?
        if let reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalizedReason = reason
        } else {
            normalizedReason = nil
        }
        guard Self.isCanonicalUUID(paymentRequestId),
              (1 ... Self.maximumAmountMinor).contains(amountMinor),
              Self.isCurrencyCode(currencyCode),
              (0 ... 6).contains(currencyScale),
              (normalizedNote?.utf16.count ?? 0) <= Self.maximumNoteLength,
              (normalizedReason?.utf16.count ?? 0) <= Self.maximumReasonLength
        else { return nil }

        self.action = action
        self.paymentRequestId = paymentRequestId
        self.amountMinor = amountMinor
        self.currencyCode = currencyCode
        self.currencyScale = currencyScale
        self.note = normalizedNote
        self.reason = normalizedReason
        guard encoded.utf16.count <= Self.maximumDescriptorLength else { return nil }
    }

    init?(action: KitPaymentMessageAction, paymentRequest: PaymentRequestDTO) {
        guard let scale = Int(paymentRequest.currency.scale),
              let amountMinor = Self.minorUnits(
                  for: paymentRequest.amount,
                  scale: scale
              )
        else { return nil }
        self.init(
            action: action,
            paymentRequestId: paymentRequest.id,
            amountMinor: amountMinor,
            currencyCode: paymentRequest.currency.code,
            currencyScale: scale,
            note: paymentRequest.note,
            reason: nil
        )
    }

    var isRequest: Bool { action == .request }

    var encoded: String {
        var value = Self.prefix
        value += "v=1"
        value += "&a=\(action.rawValue)"
        value += "&id=\(Self.percentEncode(paymentRequestId))"
        value += "&amt=\(amountMinor)"
        value += "&cur=\(Self.percentEncode(currencyCode))"
        value += "&sc=\(currencyScale)"
        if let note { value += "&note=\(Self.percentEncode(note))" }
        if let reason { value += "&rsn=\(Self.percentEncode(reason))" }
        return value
    }

    /// The canonical `.`-separated amount. Display goes through `KitMoney`, which groups it.
    var decimalAmount: String {
        KitMoney.decimal(minorUnits: amountMinor, scale: currencyScale)
    }

    func changingAction(to action: KitPaymentMessageAction) -> KitPaymentMessage? {
        KitPaymentMessage(
            action: action,
            paymentRequestId: paymentRequestId,
            amountMinor: amountMinor,
            currencyCode: currencyCode,
            currencyScale: currencyScale,
            note: note,
            reason: reason
        )
    }

    static func outcomeMessageID(
        paymentRequestID: String,
        action: KitPaymentMessageAction,
        actorUserID: String
    ) -> UUID {
        KitSystemMessage.deterministicMessageID(
            namespace: [
                "payment-request-outcome",
                paymentRequestID.lowercased(),
                action.rawValue,
                actorUserID.lowercased(),
            ].joined(separator: "|")
        )
    }

    func matchesAuthoritativeRequest(_ request: PaymentRequestDTO) -> Bool {
        request.type == "payment_request"
            && request.id == paymentRequestId
            && request.currency.code == currencyCode
            && Int(request.currency.scale) == currencyScale
            && Self.minorUnits(for: request.amount, scale: currencyScale) == amountMinor
    }

    static func isPaymentText(_ text: String) -> Bool {
        text.hasPrefix(prefix)
    }

    static func parse(_ text: String) -> KitPaymentMessage? {
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

        guard fields["v"] == "1",
              let action = fields["a"].flatMap(KitPaymentMessageAction.init(rawValue:)),
              let paymentRequestId = fields["id"]?.lowercased(),
              let amountMinor = fields["amt"].flatMap(Int64.init),
              let currencyCode = fields["cur"],
              let currencyScale = fields["sc"].flatMap(Int.init),
              let descriptor = KitPaymentMessage(
                  action: action,
                  paymentRequestId: paymentRequestId,
                  amountMinor: amountMinor,
                  currencyCode: currencyCode,
                  currencyScale: currencyScale,
                  note: fields["note"],
                  reason: fields["rsn"]
              ),
              descriptor.encoded == text
        else { return nil }
        return descriptor
    }

    /// Converts a backend decimal amount without rounding or binary floating-point arithmetic.
    static func minorUnits(for amount: String, scale: Int) -> Int64? {
        guard (0 ... 6).contains(scale) else { return nil }
        let parts = amount.split(separator: ".", omittingEmptySubsequences: false)
        guard (1 ... 2).contains(parts.count),
              let wholePart = parts.first,
              !wholePart.isEmpty,
              Self.containsOnlyASCIIDigits(wholePart)
        else { return nil }

        var fraction = parts.count == 2 ? String(parts[1]) : ""
        guard parts.count != 2 || (!fraction.isEmpty && Self.containsOnlyASCIIDigits(fraction)) else {
            return nil
        }
        if fraction.count > scale {
            let exactEnd = fraction.index(fraction.startIndex, offsetBy: scale)
            guard fraction[exactEnd...].allSatisfy({ $0 == "0" }) else { return nil }
            fraction = String(fraction[..<exactEnd])
        }
        if fraction.count < scale {
            fraction += String(repeating: "0", count: scale - fraction.count)
        }

        guard let result = Int64(String(wholePart) + fraction),
              (1 ... maximumAmountMinor).contains(result)
        else { return nil }
        return result
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        value.range(
            of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,
            options: .regularExpression
        ) != nil
    }

    private static func isCurrencyCode(_ value: String) -> Bool {
        value.range(of: #"^[A-Z]{3}$"#, options: .regularExpression) != nil
    }

    private static func containsOnlyASCIIDigits<S: StringProtocol>(_ value: S) -> Bool {
        value.utf8.allSatisfy { (48 ... 57).contains($0) }
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

/// Binds one server-confirmed payment request to the exact public Kit Pay recipient selected by
/// the sender. The backend does not currently expose a durable conversation/message binding, so
/// this value is deliberately created only from the response to the current user-initiated flow.
/// Older requests must not be projected into an arbitrary conversation by inference.
struct KitPaymentRequestChatShare: Equatable, Sendable {
    let recipientUserID: String
    let recipientName: String
    let descriptor: KitPaymentMessage
    /// Reusing the financial request UUID as the sender's messaging idempotency UUID makes a
    /// delivery retry resolve to the same protected local/server message instead of a second card.
    let clientMessageID: UUID

    init?(
        paymentRequest: PaymentRequestDTO,
        recipientUserID: String,
        recipientName: String
    ) {
        guard paymentRequest.type == "payment_request",
              paymentRequest.knownStatus == .pending,
              let requestedFrom = Self.canonicalUUID(paymentRequest.requestedFromUserId),
              let recipient = Self.canonicalUUID(recipientUserID),
              let clientMessageID = UUID(uuidString: paymentRequest.id),
              requestedFrom == recipient,
              let descriptor = KitPaymentMessage(
                  action: .request,
                  paymentRequest: paymentRequest
              )
        else { return nil }

        let cleanName = recipientName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return nil }
        self.recipientUserID = recipient
        self.recipientName = cleanName
        self.descriptor = descriptor
        self.clientMessageID = clientMessageID
    }

    private static func canonicalUUID(_ value: String?) -> String? {
        guard let value,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              let uuid = UUID(uuidString: value)
        else { return nil }
        return uuid.uuidString.lowercased()
    }
}

// MARK: - Durable payment-request chat recovery

/// A create intent is written before the POST and remains account/chat bound until its exact
/// `KITPAY1` request card has crossed into the encrypted outbox.
struct PaymentRequestChatReceiptRecoveryRecord: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let ownerUserID: String
    let destinationWalletID: String
    let recipientUserID: String
    let recipientName: String
    let conversationID: String?
    let amount: String
    let currencyCode: String
    let currencyScale: Int
    let note: String?
    let expiresAt: String?
    let idempotencyKey: String
    let createdAt: Date
    var phase: FinancialChatReceiptRecoveryPhase
    var nextRecoveryAt: Date
    var recoveryAttemptCount: Int
    var confirmation: PaymentRequestChatReceiptConfirmation?

    init?(
        id: UUID = UUID(),
        ownerUserID: String,
        destinationWalletID: String,
        recipientUserID: String,
        recipientName: String,
        conversationID: String?,
        amount: String,
        currency: CurrencyDTO,
        note: String?,
        expiresAt: String? = nil,
        idempotencyKey: String,
        createdAt: Date = Date()
    ) {
        let cleanNote = FinancialRecoveryValidation.canonicalOptionalNote(note)
        guard (note == nil || cleanNote != nil),
              let owner = FinancialRecoveryValidation.canonicalUUID(ownerUserID),
              let destination = FinancialRecoveryValidation.canonicalUUID(destinationWalletID),
              let recipient = FinancialRecoveryValidation.canonicalUUID(recipientUserID),
              owner != recipient,
              let name = FinancialRecoveryValidation.safeName(recipientName),
              let scale = Int(currency.scale),
              FinancialRecoveryValidation.isCurrencyCode(currency.code),
              KitPaymentMessage.minorUnits(for: amount, scale: scale).map({ $0 > 0 }) == true,
              let key = FinancialRecoveryValidation.idempotencyKey(idempotencyKey),
              createdAt.timeIntervalSinceReferenceDate.isFinite
        else { return nil }
        let conversation: String?
        if let conversationID {
            guard let value = FinancialRecoveryValidation.canonicalUUID(conversationID) else {
                return nil
            }
            conversation = value
        } else {
            conversation = nil
        }
        guard expiresAt.map({ !$0.isEmpty && $0.utf8.count <= 100 }) ?? true else { return nil }
        self.id = id
        self.ownerUserID = owner
        self.destinationWalletID = destination
        self.recipientUserID = recipient
        self.recipientName = name
        self.conversationID = conversation
        self.amount = amount
        currencyCode = currency.code
        currencyScale = scale
        self.note = cleanNote
        self.expiresAt = expiresAt
        self.idempotencyKey = key
        self.createdAt = createdAt
        phase = .prepared
        nextRecoveryAt = createdAt
        recoveryAttemptCount = 0
        confirmation = nil
    }

    var isStructurallyValid: Bool {
        FinancialRecoveryValidation.canonicalUUID(ownerUserID) == ownerUserID
            && FinancialRecoveryValidation.canonicalUUID(destinationWalletID)
                == destinationWalletID
            && FinancialRecoveryValidation.canonicalUUID(recipientUserID) == recipientUserID
            && ownerUserID != recipientUserID
            && (conversationID == nil
                || FinancialRecoveryValidation.canonicalUUID(conversationID) == conversationID)
            && FinancialRecoveryValidation.safeName(recipientName) == recipientName
            && FinancialRecoveryValidation.isCurrencyCode(currencyCode)
            && (0 ... 6).contains(currencyScale)
            && KitPaymentMessage.minorUnits(for: amount, scale: currencyScale).map({ $0 > 0 })
                == true
            && FinancialRecoveryValidation.canonicalOptionalNote(note) == note
            && (expiresAt.map({ !$0.isEmpty && $0.utf8.count <= 100 }) ?? true)
            && FinancialRecoveryValidation.idempotencyKey(idempotencyKey) == idempotencyKey
            && createdAt.timeIntervalSinceReferenceDate.isFinite
            && nextRecoveryAt.timeIntervalSinceReferenceDate.isFinite
            && recoveryAttemptCount >= 0
            && (phase == .confirmed) == (confirmation != nil)
            && (confirmation?.isValid(for: self) ?? true)
    }

    func hasSameIntent(as other: Self) -> Bool {
        ownerUserID == other.ownerUserID
            && destinationWalletID == other.destinationWalletID
            && recipientUserID == other.recipientUserID
            && conversationID == other.conversationID
            && amount == other.amount
            && currencyCode == other.currencyCode
            && currencyScale == other.currencyScale
            && note == other.note
            && expiresAt == other.expiresAt
    }
}

struct PaymentRequestChatReceiptConfirmation: Codable, Hashable, Sendable {
    let requestID: String
    let messageID: String
    let encodedDescriptor: String

    var clientMessageID: UUID? { UUID(uuidString: messageID) }

    init?(request: PaymentRequestDTO, recovery: PaymentRequestChatReceiptRecoveryRecord) {
        guard recovery.isValidWithoutConfirmation,
              request.type == "payment_request",
              request.knownStatus == .pending,
              let requestID = FinancialRecoveryValidation.canonicalUUID(request.id),
              FinancialRecoveryValidation.canonicalUUID(request.destinationWalletId)
                == recovery.destinationWalletID,
              FinancialRecoveryValidation.canonicalUUID(request.requestedFromUserId)
                == recovery.recipientUserID,
              request.amount == recovery.amount,
              request.currency.code == recovery.currencyCode,
              Int(request.currency.scale) == recovery.currencyScale,
              request.note == recovery.note,
              (recovery.expiresAt == nil || request.expiresAt == recovery.expiresAt),
              let descriptor = KitPaymentMessage(action: .request, paymentRequest: request)
        else { return nil }
        self.requestID = requestID
        messageID = requestID
        encodedDescriptor = descriptor.encoded
    }

    func isValid(for recovery: PaymentRequestChatReceiptRecoveryRecord) -> Bool {
        guard FinancialRecoveryValidation.canonicalUUID(requestID) == requestID,
              messageID == requestID,
              let descriptor = KitPaymentMessage.parse(encodedDescriptor),
              descriptor.action == .request,
              descriptor.paymentRequestId == requestID,
              descriptor.amountMinor == KitPaymentMessage.minorUnits(
                  for: recovery.amount,
                  scale: recovery.currencyScale
              ),
              descriptor.currencyCode == recovery.currencyCode,
              descriptor.currencyScale == recovery.currencyScale,
              descriptor.note == recovery.note
        else { return false }
        return true
    }
}

private extension PaymentRequestChatReceiptRecoveryRecord {
    var isValidWithoutConfirmation: Bool {
        var copy = self
        copy.phase = .submitted
        copy.confirmation = nil
        return copy.isStructurallyValid
    }
}

enum PaymentRequestChatReceiptRecoveryPolicy {
    static let maximumRecordsPerRecoveryPass =
        FinancialChatReceiptRecoveryPolicy.maximumRecordsPerRecoveryPass

    @discardableResult
    static func sanitize(
        _ records: inout [PaymentRequestChatReceiptRecoveryRecord],
        ownerUserID: String? = nil,
        now: Date = Date()
    ) -> Int {
        let originalCount = records.count
        let owner = ownerUserID.flatMap { FinancialRecoveryValidation.canonicalUUID($0) }
        var seen: Set<UUID> = []
        records = records.sorted { left, right in
            FinancialRecoveryValidation.recoveryComesFirst(
                leftPhase: left.phase,
                leftDate: left.createdAt,
                leftID: left.id,
                rightPhase: right.phase,
                rightDate: right.createdAt,
                rightID: right.id
            )
        }.filter { record in
            let age = now.timeIntervalSince(record.createdAt)
            return record.isStructurallyValid
                && (ownerUserID == nil || record.ownerUserID == owner)
                && age >= -FinancialChatReceiptRecoveryPolicy.clockSkewAllowance
                && (record.phase != .prepared
                    || age <= FinancialChatReceiptRecoveryPolicy.preparedRetentionLifetime)
                && seen.insert(record.id).inserted
        }
        return originalCount - records.count
    }

    static func insertOrReuse(
        _ candidate: PaymentRequestChatReceiptRecoveryRecord,
        in records: inout [PaymentRequestChatReceiptRecoveryRecord],
        now: Date = Date()
    ) -> PaymentRequestChatReceiptRecoveryRecord? {
        guard candidate.isStructurallyValid else { return nil }
        sanitize(&records, ownerUserID: candidate.ownerUserID, now: now)
        if let existing = records.first(where: { $0.hasSameIntent(as: candidate) }) {
            return existing
        }
        guard records.count < FinancialChatReceiptRecoveryPolicy.maximumPendingRecords else {
            return nil
        }
        records.append(candidate)
        return candidate
    }

    @discardableResult
    static func markSubmitted(
        recordID: UUID,
        in records: inout [PaymentRequestChatReceiptRecoveryRecord],
        now: Date = Date()
    ) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == recordID }),
              records[index].phase == .prepared
        else { return false }
        records[index].phase = .submitted
        records[index].nextRecoveryAt = now
        return true
    }

    @discardableResult
    static func storeConfirmation(
        _ confirmation: PaymentRequestChatReceiptConfirmation,
        for recordID: UUID,
        in records: inout [PaymentRequestChatReceiptRecoveryRecord]
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
        recordID: UUID,
        in records: inout [PaymentRequestChatReceiptRecoveryRecord],
        now: Date = Date()
    ) -> Bool {
        guard let index = records.firstIndex(where: {
            $0.id == recordID && $0.phase == .submitted
        }) else { return false }
        if records[index].recoveryAttemptCount < Int.max {
            records[index].recoveryAttemptCount += 1
        }
        records[index].nextRecoveryAt = FinancialChatReceiptRecoveryPolicy.nextRecoveryDate(
            afterAttempt: records[index].recoveryAttemptCount,
            now: now
        )
        return true
    }

    @discardableResult
    static func retireNotCommitted(
        recordID: UUID,
        in records: inout [PaymentRequestChatReceiptRecoveryRecord]
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
        in records: inout [PaymentRequestChatReceiptRecoveryRecord]
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

    static func recoveryDecision(for error: Error) -> FinancialChatReceiptRecoveryDecision {
        FinancialChatReceiptRecoveryPolicy.recoveryDecision(
            for: error,
            notFoundCode: "PAYMENT_REQUEST_RECOVERY_NOT_FOUND"
        )
    }
}

enum PaymentRequestResolutionRecoveryOperation: String, Codable, Hashable, Sendable {
    case paid
    case cancelled
}

enum PaymentRequestResolutionRecoveryReadDecision: Equatable {
    case confirm
    case retain
    case retireUncommitted
}

/// Durable authority for the chat outcome of a pay/cancel action. The known request ID is read
/// exactly after restart; recovery never repeats either mutation.
struct PaymentRequestResolutionChatReceiptRecoveryRecord:
    Codable, Hashable, Identifiable, Sendable
{
    let id: UUID
    let ownerUserID: String
    let conversationID: String
    let recipientUserID: String
    let recipientName: String
    let requestID: String
    let destinationWalletID: String
    let sourceWalletID: String?
    let originalDescriptor: String
    let operation: PaymentRequestResolutionRecoveryOperation
    let idempotencyKey: String
    let createdAt: Date
    var phase: FinancialChatReceiptRecoveryPhase
    var nextRecoveryAt: Date
    var recoveryAttemptCount: Int
    var confirmation: PaymentRequestResolutionChatReceiptConfirmation?

    init?(
        id: UUID = UUID(),
        ownerUserID: String,
        conversationID: String,
        recipientUserID: String,
        recipientName: String,
        request: PaymentRequestDTO,
        descriptor: KitPaymentMessage,
        sourceWalletID: String?,
        operation: PaymentRequestResolutionRecoveryOperation,
        idempotencyKey: String,
        createdAt: Date = Date()
    ) {
        guard descriptor.action == .request,
              descriptor.matchesAuthoritativeRequest(request),
              request.knownStatus == .pending,
              let owner = FinancialRecoveryValidation.canonicalUUID(ownerUserID),
              let conversation = FinancialRecoveryValidation.canonicalUUID(conversationID),
              let recipient = FinancialRecoveryValidation.canonicalUUID(recipientUserID),
              let requestID = FinancialRecoveryValidation.canonicalUUID(request.id),
              let destination = FinancialRecoveryValidation.canonicalUUID(
                  request.destinationWalletId
              ),
              let name = FinancialRecoveryValidation.safeName(recipientName),
              let key = FinancialRecoveryValidation.idempotencyKey(idempotencyKey),
              owner != recipient,
              createdAt.timeIntervalSinceReferenceDate.isFinite
        else { return nil }
        let source = sourceWalletID.flatMap { FinancialRecoveryValidation.canonicalUUID($0) }
        guard (operation == .paid) == (source != nil) else { return nil }
        self.id = id
        self.ownerUserID = owner
        self.conversationID = conversation
        self.recipientUserID = recipient
        self.recipientName = name
        self.requestID = requestID
        self.destinationWalletID = destination
        self.sourceWalletID = source
        originalDescriptor = descriptor.encoded
        self.operation = operation
        self.idempotencyKey = key
        self.createdAt = createdAt
        phase = .prepared
        nextRecoveryAt = createdAt
        recoveryAttemptCount = 0
        confirmation = nil
    }

    var isStructurallyValid: Bool {
        guard FinancialRecoveryValidation.canonicalUUID(ownerUserID) == ownerUserID,
              FinancialRecoveryValidation.canonicalUUID(conversationID) == conversationID,
              FinancialRecoveryValidation.canonicalUUID(recipientUserID) == recipientUserID,
              FinancialRecoveryValidation.canonicalUUID(requestID) == requestID,
              FinancialRecoveryValidation.canonicalUUID(destinationWalletID)
                == destinationWalletID,
              ownerUserID != recipientUserID,
              (sourceWalletID == nil
                  || FinancialRecoveryValidation.canonicalUUID(sourceWalletID) == sourceWalletID),
              (operation == .paid) == (sourceWalletID != nil),
              FinancialRecoveryValidation.safeName(recipientName) == recipientName,
              FinancialRecoveryValidation.idempotencyKey(idempotencyKey) == idempotencyKey,
              let descriptor = KitPaymentMessage.parse(originalDescriptor),
              descriptor.action == .request,
              descriptor.paymentRequestId == requestID,
              createdAt.timeIntervalSinceReferenceDate.isFinite,
              nextRecoveryAt.timeIntervalSinceReferenceDate.isFinite,
              recoveryAttemptCount >= 0,
              (phase == .confirmed) == (confirmation != nil)
        else { return false }
        return confirmation?.isValid(for: self) ?? true
    }

    func hasSameIntent(as other: Self) -> Bool {
        ownerUserID == other.ownerUserID
            && conversationID == other.conversationID
            && recipientUserID == other.recipientUserID
            && requestID == other.requestID
            && destinationWalletID == other.destinationWalletID
            && sourceWalletID == other.sourceWalletID
            && originalDescriptor == other.originalDescriptor
            && operation == other.operation
    }

    func matchesExactRead(_ request: PaymentRequestDTO) -> Bool {
        guard request.type == "payment_request",
              FinancialRecoveryValidation.canonicalUUID(request.id) == requestID,
              FinancialRecoveryValidation.canonicalUUID(request.destinationWalletId)
                == destinationWalletID,
              let descriptor = KitPaymentMessage.parse(originalDescriptor),
              descriptor.matchesAuthoritativeRequest(request),
              descriptor.note == request.note
        else { return false }
        switch operation {
        case .paid:
            return FinancialRecoveryValidation.canonicalUUID(request.requestedFromUserId)
                == ownerUserID
        case .cancelled:
            return FinancialRecoveryValidation.canonicalUUID(request.requestedFromUserId)
                == recipientUserID
        }
    }
}

struct PaymentRequestResolutionChatReceiptConfirmation: Codable, Hashable, Sendable {
    let messageID: String
    let encodedDescriptor: String

    var clientMessageID: UUID? { UUID(uuidString: messageID) }

    init?(
        request: PaymentRequestDTO,
        recovery: PaymentRequestResolutionChatReceiptRecoveryRecord
    ) {
        guard let original = KitPaymentMessage.parse(recovery.originalDescriptor),
              recovery.matchesExactRead(request)
        else { return nil }
        switch recovery.operation {
        case .paid:
            guard request.knownStatus == .paid,
                  FinancialRecoveryValidation.canonicalUUID(request.requestedFromUserId)
                    == recovery.ownerUserID,
                  FinancialRecoveryValidation.canonicalUUID(request.walletTransactionId) != nil
            else { return nil }
        case .cancelled:
            guard request.knownStatus == .cancelled,
                  FinancialRecoveryValidation.canonicalUUID(request.requestedFromUserId)
                    == recovery.recipientUserID
            else { return nil }
        }
        let action: KitPaymentMessageAction = recovery.operation == .paid ? .paid : .cancelled
        guard let descriptor = original.changingAction(to: action) else { return nil }
        let identifier = KitPaymentMessage.outcomeMessageID(
            paymentRequestID: recovery.requestID,
            action: action,
            actorUserID: recovery.ownerUserID
        )
        messageID = identifier.uuidString.lowercased()
        encodedDescriptor = descriptor.encoded
    }

    func isValid(for recovery: PaymentRequestResolutionChatReceiptRecoveryRecord) -> Bool {
        let action: KitPaymentMessageAction = recovery.operation == .paid ? .paid : .cancelled
        guard clientMessageID == KitPaymentMessage.outcomeMessageID(
            paymentRequestID: recovery.requestID,
            action: action,
            actorUserID: recovery.ownerUserID
        ), let original = KitPaymentMessage.parse(recovery.originalDescriptor),
           let descriptor = KitPaymentMessage.parse(encodedDescriptor),
           descriptor == original.changingAction(to: action)
        else { return false }
        return true
    }
}

enum PaymentRequestResolutionChatReceiptRecoveryPolicy {
    static let maximumRecordsPerRecoveryPass =
        FinancialChatReceiptRecoveryPolicy.maximumRecordsPerRecoveryPass

    /// A still-pending exact read can race an in-flight pay/cancel commit, so it is never proof
    /// that the mutation failed. Only a different terminal state makes the intended transition
    /// impossible and permits the submitted journal to be retired.
    static func exactReadDecision(
        for request: PaymentRequestDTO,
        recovery: PaymentRequestResolutionChatReceiptRecoveryRecord
    ) -> PaymentRequestResolutionRecoveryReadDecision {
        guard recovery.matchesExactRead(request), let status = request.knownStatus else {
            return .retain
        }
        let expected: PaymentRequestStatus = recovery.operation == .paid ? .paid : .cancelled
        if status == expected { return .confirm }
        return status == .pending ? .retain : .retireUncommitted
    }

    @discardableResult
    static func sanitize(
        _ records: inout [PaymentRequestResolutionChatReceiptRecoveryRecord],
        ownerUserID: String? = nil,
        now: Date = Date()
    ) -> Int {
        let originalCount = records.count
        let owner = ownerUserID.flatMap { FinancialRecoveryValidation.canonicalUUID($0) }
        var seen: Set<UUID> = []
        records = records.sorted { left, right in
            FinancialRecoveryValidation.recoveryComesFirst(
                leftPhase: left.phase,
                leftDate: left.createdAt,
                leftID: left.id,
                rightPhase: right.phase,
                rightDate: right.createdAt,
                rightID: right.id
            )
        }.filter { record in
            let age = now.timeIntervalSince(record.createdAt)
            return record.isStructurallyValid
                && (ownerUserID == nil || record.ownerUserID == owner)
                && age >= -FinancialChatReceiptRecoveryPolicy.clockSkewAllowance
                && (record.phase != .prepared
                    || age <= FinancialChatReceiptRecoveryPolicy.preparedRetentionLifetime)
                && seen.insert(record.id).inserted
        }
        return originalCount - records.count
    }

    static func insertOrReuse(
        _ candidate: PaymentRequestResolutionChatReceiptRecoveryRecord,
        in records: inout [PaymentRequestResolutionChatReceiptRecoveryRecord],
        now: Date = Date()
    ) -> PaymentRequestResolutionChatReceiptRecoveryRecord? {
        guard candidate.isStructurallyValid else { return nil }
        sanitize(&records, ownerUserID: candidate.ownerUserID, now: now)
        if let existing = records.first(where: { $0.hasSameIntent(as: candidate) }) {
            return existing
        }
        guard records.count < FinancialChatReceiptRecoveryPolicy.maximumPendingRecords else {
            return nil
        }
        records.append(candidate)
        return candidate
    }

    @discardableResult
    static func markSubmitted(
        recordID: UUID,
        in records: inout [PaymentRequestResolutionChatReceiptRecoveryRecord],
        now: Date = Date()
    ) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == recordID }),
              records[index].phase == .prepared
        else { return false }
        records[index].phase = .submitted
        records[index].nextRecoveryAt = now
        return true
    }

    @discardableResult
    static func storeConfirmation(
        _ confirmation: PaymentRequestResolutionChatReceiptConfirmation,
        for recordID: UUID,
        in records: inout [PaymentRequestResolutionChatReceiptRecoveryRecord]
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
        recordID: UUID,
        in records: inout [PaymentRequestResolutionChatReceiptRecoveryRecord],
        now: Date = Date()
    ) -> Bool {
        guard let index = records.firstIndex(where: {
            $0.id == recordID && $0.phase == .submitted
        }) else { return false }
        if records[index].recoveryAttemptCount < Int.max {
            records[index].recoveryAttemptCount += 1
        }
        records[index].nextRecoveryAt = FinancialChatReceiptRecoveryPolicy.nextRecoveryDate(
            afterAttempt: records[index].recoveryAttemptCount,
            now: now
        )
        return true
    }

    @discardableResult
    static func retireUncommitted(
        recordID: UUID,
        in records: inout [PaymentRequestResolutionChatReceiptRecoveryRecord]
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
        in records: inout [PaymentRequestResolutionChatReceiptRecoveryRecord]
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

enum FinancialRecoveryValidation {
    static func canonicalUUID(_ value: String?) -> String? {
        guard let value,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              let identifier = UUID(uuidString: value)
        else { return nil }
        return identifier.uuidString.lowercased()
    }

    static func idempotencyKey(_ value: String) -> String? {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.utf8.count <= 128,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return value
    }

    static func safeName(_ value: String) -> String? {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty,
              clean.count <= 100,
              clean.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return clean
    }

    /// Returns nil for both an absent note and an invalid note, so callers must additionally
    /// compare a non-nil input with the result when constructing a record.
    static func canonicalOptionalNote(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty,
              clean == value,
              clean.utf16.count <= KitPaymentMessage.maximumNoteLength,
              clean.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return clean
    }

    static func isCurrencyCode(_ value: String) -> Bool {
        value.range(of: #"^[A-Z]{3}$"#, options: .regularExpression) != nil
    }

    static func recoveryComesFirst(
        leftPhase: FinancialChatReceiptRecoveryPhase,
        leftDate: Date,
        leftID: UUID,
        rightPhase: FinancialChatReceiptRecoveryPhase,
        rightDate: Date,
        rightID: UUID
    ) -> Bool {
        let rank: (FinancialChatReceiptRecoveryPhase) -> Int = {
            switch $0 {
            case .confirmed: 0
            case .submitted: 1
            case .prepared: 2
            }
        }
        if rank(leftPhase) != rank(rightPhase) { return rank(leftPhase) < rank(rightPhase) }
        if leftDate != rightDate { return leftDate < rightDate }
        return leftID.uuidString < rightID.uuidString
    }
}

enum PaymentRequestSubmissionError: LocalizedError, Equatable {
    case invalidRecipient
    case recoveryCapacityReached
    case accountChanged
    case unconfirmedRequest

    var errorDescription: String? {
        switch self {
        case .invalidRecipient:
            "Choose a valid Kit Pay contact."
        case .recoveryCapacityReached:
            "Kit is still confirming earlier payment requests. Please try again later."
        case .accountChanged:
            "Your account changed before the request was completed. Please try again."
        case .unconfirmedRequest:
            "The request could not be confirmed. Check your payment requests before trying again."
        }
    }
}

enum KitPaymentRequestResolution: Equatable {
    case match(PaymentRequestDTO)
    case missing
    case mismatch
}

enum KitPaymentRequestResolutionPolicy {
    static func resolve(
        _ descriptor: KitPaymentMessage,
        in requests: [PaymentRequestDTO]
    ) -> KitPaymentRequestResolution {
        guard descriptor.isRequest else { return .mismatch }
        let candidates = requests.filter { $0.id == descriptor.paymentRequestId }
        guard !candidates.isEmpty else { return .missing }
        guard candidates.count == 1,
              let request = candidates.first,
              descriptor.matchesAuthoritativeRequest(request)
        else { return .mismatch }
        return .match(request)
    }
}

struct KitPaymentThreadOutcome: Equatable {
    let action: KitPaymentMessageAction
    let reason: String?
}

/// Folds authenticated terminal payment-request events in conversation order. Direction checks
/// prevent either party from claiming an outcome that only the other side can produce.
enum KitPaymentRequestThreadStatePolicy {
    static func latestLocalOutcome(
        forRequestID requestID: String,
        requestIsOutgoing: Bool,
        messages: [LocalMessage]
    ) -> KitPaymentThreadOutcome? {
        var outcome: KitPaymentThreadOutcome?
        for message in messages {
            guard let descriptor = KitPaymentMessage.parse(message.body),
                  descriptor.paymentRequestId.caseInsensitiveCompare(requestID) == .orderedSame
            else { continue }
            switch descriptor.action {
            case .paid, .declined:
                guard message.isOutgoing != requestIsOutgoing else { continue }
            case .cancelled:
                guard message.isOutgoing == requestIsOutgoing else { continue }
            case .request, .transfer, .sent, .accepted, .rejected, .reversed, .expired:
                continue
            }
            outcome = KitPaymentThreadOutcome(
                action: descriptor.action,
                reason: descriptor.reason
            )
        }
        return outcome
    }
}

struct KitPaymentMessagePresentation: Equatable {
    let title: String
    let statusText: String
    let showsPayAction: Bool
}

enum KitPaymentMessagePresentationPolicy {
    static func presentation(
        for descriptor: KitPaymentMessage,
        isOutgoing: Bool,
        authoritativeRequest: PaymentRequestDTO?,
        sourceWallet: Wallet?,
        policy: PaymentRequestPolicy,
        isOnline: Bool
    ) -> KitPaymentMessagePresentation {
        switch descriptor.action {
        case .paid:
            return KitPaymentMessagePresentation(
                title: isOutgoing ? "Payment sent" : "Payment received",
                statusText: "Completed",
                showsPayAction: false
            )
        case .declined:
            return KitPaymentMessagePresentation(
                title: "Payment request declined",
                statusText: "No money moved",
                showsPayAction: false
            )
        case .cancelled:
            return KitPaymentMessagePresentation(
                title: "Payment request cancelled",
                statusText: "No money moved",
                showsPayAction: false
            )
        case .sent:
            return KitPaymentMessagePresentation(
                title: isOutgoing ? "Payment sent" : "Payment received",
                statusText: "Completed",
                showsPayAction: false
            )
        case .transfer, .accepted, .rejected, .reversed, .expired:
            // Transfer-family actions are rendered by KitTransferMessagePresentationPolicy.
            return KitPaymentMessagePresentation(
                title: "Payment",
                statusText: "",
                showsPayAction: false
            )
        case .request:
            break
        }
        guard !isOutgoing else {
            return KitPaymentMessagePresentation(
                title: "Payment request sent",
                statusText: "Sent securely",
                showsPayAction: false
            )
        }
        guard let authoritativeRequest,
              descriptor.matchesAuthoritativeRequest(authoritativeRequest)
        else {
            return KitPaymentMessagePresentation(
                title: "Payment request",
                statusText: isOnline ? "Verifying request details" : "Connect to verify and pay",
                showsPayAction: false
            )
        }
        guard authoritativeRequest.knownStatus == .pending else {
            return KitPaymentMessagePresentation(
                title: "Payment request",
                statusText: authoritativeRequest.status.capitalized,
                showsPayAction: false
            )
        }
        guard let sourceWallet, policy.canPay(authoritativeRequest, from: sourceWallet) else {
            return KitPaymentMessagePresentation(
                title: "Payment request",
                statusText: "Not eligible for payment",
                showsPayAction: false
            )
        }
        guard isOnline else {
            return KitPaymentMessagePresentation(
                title: "Payment request",
                statusText: "Connect to pay",
                showsPayAction: false
            )
        }
        return KitPaymentMessagePresentation(
            title: "Payment request",
            statusText: "Wallet PIN required",
            showsPayAction: true
        )
    }
}

/// Retains a successfully-created backend request until its encrypted chat descriptor is queued.
/// Retrying therefore never creates a second financial request.
@MainActor
final class KitPaymentRequestSecureShareSession {
    private(set) var pendingRequest: PaymentRequestDTO?

    var hasPendingRequest: Bool { pendingRequest != nil }

    func submit(
        create: () async -> PaymentRequestDTO?,
        share: (PaymentRequestDTO) async -> Bool
    ) async -> Bool {
        let request: PaymentRequestDTO
        if let pendingRequest {
            request = pendingRequest
        } else {
            guard let created = await create() else { return false }
            pendingRequest = created
            request = created
        }

        guard await share(request) else { return false }
        pendingRequest = nil
        return true
    }
}

struct CreatePaymentRequestBody: Encodable {
    let destinationWalletId: String
    let requestedFromUserId: String?
    let amount: String
    let note: String?
    let expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case destinationWalletId = "destination_wallet_id"
        case requestedFromUserId = "requested_from_user_id"
        case amount, note
        case expiresAt = "expires_at"
    }
}

struct PayPaymentRequestBody: Encodable {
    let sourceWalletId: String

    enum CodingKeys: String, CodingKey {
        case sourceWalletId = "source_wallet_id"
    }
}

struct PaymentRequestEmptyBody: Encodable {}

enum PaymentRequestDirection: Equatable {
    case incoming
    case outgoing
    case unknown
}

struct PaymentRequestPolicy {
    let paymentRequestsEnabled: Bool
    let internalTransfersEnabled: Bool
    let currentUserId: String?
    let ownedWalletIds: Set<String>

    init(
        features: [String: Bool?]?,
        currentUserId: String?,
        ownedWalletIds: Set<String>
    ) {
        let enabled = features?.compactMapValues { $0 } ?? [:]
        paymentRequestsEnabled = enabled["wallets"] == true
            && enabled["payment_requests"] == true
        internalTransfersEnabled = enabled["internal_transfers"] == true
        self.currentUserId = currentUserId
        self.ownedWalletIds = ownedWalletIds
    }

    func direction(of request: PaymentRequestDTO) -> PaymentRequestDirection {
        if ownedWalletIds.contains(request.destinationWalletId) { return .outgoing }
        if let currentUserId, request.requestedFromUserId == currentUserId { return .incoming }
        return .unknown
    }

    func canCancel(_ request: PaymentRequestDTO) -> Bool {
        request.knownStatus == .pending
            && direction(of: request) == .outgoing
    }

    func canPay(_ request: PaymentRequestDTO, now: Date = Date()) -> Bool {
        guard paymentRequestsEnabled,
              internalTransfersEnabled,
              request.knownStatus == .pending,
              direction(of: request) == .incoming
        else { return false }

        guard let expiresAt = request.expiresAt else { return true }
        guard let expiry = ISO8601DateFormatter().date(from: expiresAt) else { return false }
        return expiry > now
    }

    func canPay(_ request: PaymentRequestDTO, from wallet: Wallet, now: Date = Date()) -> Bool {
        canPay(request, now: now)
            && ownedWalletIds.contains(wallet.id)
            && wallet.status == "active"
            && wallet.currency == request.currency
            && wallet.id != request.destinationWalletId
    }

    static func payIntent(for request: PaymentRequestDTO, sourceWalletId: String) -> [String: String?] {
        [
            "action": "pay",
            "payment_request_id": request.id,
            "source_wallet_id": sourceWalletId,
            "amount": request.amount,
            "currency": request.currency.code,
        ]
    }

    static func isValidPIN(_ pin: String) -> Bool {
        pin.range(of: #"^[0-9]{4}$"#, options: .regularExpression) != nil
    }
}
