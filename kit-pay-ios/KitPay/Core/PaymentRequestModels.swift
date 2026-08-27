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

enum PaymentRequestSubmissionError: LocalizedError, Equatable {
    case invalidRecipient
    case accountChanged
    case unconfirmedRequest

    var errorDescription: String? {
        switch self {
        case .invalidRecipient:
            "Choose a valid Kit Pay contact."
        case .accountChanged:
            "Your account changed before the request was completed. Please try again."
        case .unconfirmedRequest:
            "The request could not be confirmed. Check your payment requests before trying again."
        }
    }
}

/// Process-local authority to finish sharing one just-created request. It is intentionally not
/// persisted: after a relaunch, only a future backend conversation/message binding can safely
/// prove where an older financial request belongs.
struct PaymentRequestChatShareLease: Equatable, Sendable {
    let accountEpoch: UUID
    let userID: String
    let sessionID: String
    let recipientUserID: String
    let descriptor: KitPaymentMessage

    func authorizes(_ share: KitPaymentRequestChatShare) -> Bool {
        recipientUserID.caseInsensitiveCompare(share.recipientUserID) == .orderedSame
            && descriptor == share.descriptor
    }

    func matches(
        accountEpoch: UUID,
        userID: String,
        sessionID: String,
        recipientUserID: String
    ) -> Bool {
        self.accountEpoch == accountEpoch
            && self.userID.caseInsensitiveCompare(userID) == .orderedSame
            && self.sessionID == sessionID
            && self.recipientUserID.caseInsensitiveCompare(recipientUserID) == .orderedSame
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
