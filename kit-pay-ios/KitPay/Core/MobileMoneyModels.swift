import Foundation

struct MobileMoneyNetworkListDTO: Decodable {
    let items: [MobileMoneyNetworkDTO]?
}

struct MobileMoneyAccountListDTO: Decodable {
    let items: [MobileMoneyAccountDTO]?
}

struct MobileMoneyOperationListDTO: Decodable {
    let items: [MobileMoneyOperationDTO]?
}

enum MobileMoneyFeeMode: String, Codable, CaseIterable, Identifiable {
    case inclusive
    case grossUp = "gross_up"

    var id: String { rawValue }
}

enum MobileMoneyPayoutFeeMode: String, Codable, CaseIterable, Identifiable {
    case senderAbsorbs = "sender_absorbs"
    case beneficiaryAbsorbs = "recipient_absorbs"
    case kitCovers = "kit_covers"

    var id: String { rawValue }
}

struct MobileMoneyCollectionQuoteDTO: Decodable, Identifiable {
    let id: String
    let action: String
    let feeMode: MobileMoneyFeeMode
    let walletId: String
    let accountId: String
    let network: String
    let requestedAmount: String
    let providerAmount: String
    let providerFee: String
    let platformFee: String
    let roundingAdjustment: String
    let totalFees: String
    let walletCredit: String
    let currency: CurrencyDTO
    let providerFeeEstimated: Bool
    let expiresAt: String
    let stepUp: MobileMoneyQuoteStepUpDTO

    enum CodingKeys: String, CodingKey {
        case id, action, network, currency
        case feeMode = "fee_mode"
        case walletId = "wallet_id"
        case accountId = "account_id"
        case requestedAmount = "requested_amount"
        case providerAmount = "provider_amount"
        case providerFee = "provider_fee"
        case platformFee = "platform_fee"
        case roundingAdjustment = "rounding_adjustment"
        case totalFees = "total_fees"
        case walletCredit = "wallet_credit"
        case providerFeeEstimated = "provider_fee_estimated"
        case expiresAt = "expires_at"
        case stepUp = "step_up"
    }

    var isExpired: Bool {
        guard let date = ISO8601DateFormatter().date(from: expiresAt) else { return true }
        return date <= Date()
    }
}

struct MobileMoneyPayoutQuoteDTO: Decodable, Identifiable {
    let id: String
    let action: String
    let feeMode: MobileMoneyPayoutFeeMode
    let walletId: String
    let accountId: String
    let network: String
    let recipientAmount: String
    let processingFee: String
    let providerFee: String
    let kitFee: String
    let providerFeeCap: String
    let maximumProviderTotal: String
    let customerDebit: String
    let kitDebit: String
    let scheduleVersion: String
    let scheduleVerified: Bool
    let currency: CurrencyDTO
    let expiresAt: String
    let stepUp: MobileMoneyQuoteStepUpDTO

    enum CodingKeys: String, CodingKey {
        case id, action, network, currency
        case feeMode = "fee_mode"
        case walletId = "wallet_id"
        case accountId = "account_id"
        case recipientAmount = "recipient_amount"
        case processingFee = "processing_fee"
        case providerFee = "provider_fee"
        case kitFee = "kit_fee"
        case providerFeeCap = "provider_fee_cap"
        case maximumProviderTotal = "maximum_provider_total"
        case customerDebit = "customer_debit"
        case kitDebit = "kit_debit"
        case scheduleVersion = "schedule_version"
        case scheduleVerified = "schedule_verified"
        case expiresAt = "expires_at"
        case stepUp = "step_up"
    }

    var isExpired: Bool {
        guard let date = ISO8601DateFormatter().date(from: expiresAt) else { return true }
        return date <= Date()
    }

    /// The amount entered before the quote applies its selected fee treatment.
    /// When the beneficiary covers the fee, that entered amount is the exact
    /// customer debit and the beneficiary receives the net amount.
    var enteredAmount: String {
        feeMode == .beneficiaryAbsorbs ? customerDebit : recipientAmount
    }

    var hasConsistentAmounts: Bool {
        let locale = Locale(identifier: "en_US_POSIX")
        guard let recipient = Decimal(string: recipientAmount, locale: locale), recipient > 0,
              let fee = Decimal(string: processingFee, locale: locale), fee >= 0,
              let provider = Decimal(string: providerFee, locale: locale), provider >= 0,
              let kitFeeComponent = Decimal(string: kitFee, locale: locale), kitFeeComponent >= 0,
              let providerCap = Decimal(string: providerFeeCap, locale: locale), providerCap >= 0,
              let maximumTotal = Decimal(string: maximumProviderTotal, locale: locale),
              let customer = Decimal(string: customerDebit, locale: locale), customer > 0,
              let kit = Decimal(string: kitDebit, locale: locale), kit >= 0,
              fee == provider + kitFeeComponent,
              providerCap == provider,
              maximumTotal == recipient + providerCap
        else { return false }

        switch feeMode {
        case .senderAbsorbs:
            return customer == recipient + fee && kit == 0
        case .beneficiaryAbsorbs:
            return customer == recipient + fee && kit == 0
        case .kitCovers:
            return customer == recipient && kit == providerCap
        }
    }
}

struct MobileMoneyQuoteStepUpDTO: Decodable {
    let purpose: String
    let intent: [String: String]

    var authorizationIntent: [String: String?] {
        intent.mapValues(Optional.some)
    }
}

struct MobileMoneyNetworkDTO: Codable, Hashable, Identifiable {
    let id: String
    let code: String
    let name: String
    let currency: CurrencyDTO
    let capabilities: [String: Bool?]?

    var canCollect: Bool { capabilities?["collections"] == true }
    var canPayout: Bool { capabilities?["payouts"] == true }
    var canVerifyAccount: Bool { capabilities?["account_verification"] == true }
}

extension Collection where Element == MobileMoneyNetworkDTO {
    /// Payout entry points fail closed until at least one returned network explicitly
    /// advertises the capability. An empty or collection-only catalog must not expose cash out.
    var supportsMobileMoneyPayouts: Bool {
        contains {
            MobileMoneySavedAccountRailPolicy.isMobileMoneyRailDestination($0)
                && $0.canPayout
        }
    }
}

struct MobileMoneyFailureDTO: Codable, Hashable {
    let code: String
    let message: String?
}

struct MobileMoneyOutboundPricingDTO: Decodable, Hashable {
    let feeMode: MobileMoneyPayoutFeeMode
    let recipientAmount: String
    let processingFee: String
    let providerFee: String
    let kitFee: String
    let providerFeeCap: String
    let maximumProviderTotal: String
    let customerDebit: String
    let kitDebit: String
    let scheduleVersion: String
    let actualProviderFee: String?
    let actualProviderTotal: String?

    enum CodingKeys: String, CodingKey {
        case feeMode = "fee_mode"
        case recipientAmount = "recipient_amount"
        case processingFee = "processing_fee"
        case providerFee = "provider_fee"
        case kitFee = "kit_fee"
        case providerFeeCap = "provider_fee_cap"
        case maximumProviderTotal = "maximum_provider_total"
        case customerDebit = "customer_debit"
        case kitDebit = "kit_debit"
        case scheduleVersion = "schedule_version"
        case actualProviderFee = "actual_provider_fee"
        case actualProviderTotal = "actual_provider_total"
    }

    var hasConsistentAmounts: Bool {
        let locale = Locale(identifier: "en_US_POSIX")
        guard let recipient = Decimal(string: recipientAmount, locale: locale), recipient > 0,
              let fee = Decimal(string: processingFee, locale: locale), fee >= 0,
              let provider = Decimal(string: providerFee, locale: locale), provider >= 0,
              let kitFeeComponent = Decimal(string: kitFee, locale: locale), kitFeeComponent >= 0,
              let providerCap = Decimal(string: providerFeeCap, locale: locale), providerCap >= 0,
              let maximumTotal = Decimal(string: maximumProviderTotal, locale: locale),
              let customer = Decimal(string: customerDebit, locale: locale), customer > 0,
              let kit = Decimal(string: kitDebit, locale: locale), kit >= 0,
              fee == provider + kitFeeComponent,
              providerCap == provider,
              maximumTotal == recipient + providerCap
        else { return false }

        switch feeMode {
        case .senderAbsorbs, .beneficiaryAbsorbs:
            return customer == recipient + fee && kit == 0
        case .kitCovers:
            return customer == recipient && kit == providerCap
        }
    }

    func matches(_ quote: MobileMoneyPayoutQuoteDTO) -> Bool {
        feeMode == quote.feeMode
            && scheduleVersion == quote.scheduleVersion
            && MobileMoneyAmount.amountsMatch(recipientAmount, quote.recipientAmount)
            && MobileMoneyAmount.amountsMatch(processingFee, quote.processingFee)
            && MobileMoneyAmount.amountsMatch(providerFee, quote.providerFee)
            && MobileMoneyAmount.amountsMatch(kitFee, quote.kitFee)
            && MobileMoneyAmount.amountsMatch(providerFeeCap, quote.providerFeeCap)
            && MobileMoneyAmount.amountsMatch(maximumProviderTotal, quote.maximumProviderTotal)
            && MobileMoneyAmount.amountsMatch(customerDebit, quote.customerDebit)
            && MobileMoneyAmount.amountsMatch(kitDebit, quote.kitDebit)
            && hasConsistentAmounts
    }
}

struct MobileMoneyVerificationDTO: Decodable, Hashable, Identifiable {
    let id: String
    let bankId: String
    let status: String
    let accountNumberMasked: String
    let verifiedAccountName: String?
    let failure: MobileMoneyFailureDTO?
    let verifiedAt: String?
    let network: MobileMoneyNetworkDTO

    enum CodingKeys: String, CodingKey {
        case id, status, failure, network
        case bankId = "bank_id"
        case accountNumberMasked = "account_number_masked"
        case verifiedAccountName = "verified_account_name"
        case verifiedAt = "verified_at"
    }

    var isVerified: Bool { status.caseInsensitiveCompare("verified") == .orderedSame }
    var isPending: Bool {
        ["pending", "queued", "processing", "submitted"].contains(status.lowercased())
    }
}

struct MobileMoneyAccountDTO: Decodable, Hashable, Identifiable {
    let id: String
    let kind: String
    let label: String
    let network: MobileMoneyNetworkDTO
    let accountName: String?
    let phoneNumberMasked: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case id, kind, label, network, status
        case accountName = "account_name"
        case phoneNumberMasked = "phone_number_masked"
    }

    var ownership: MobileMoneySavedAccountOwnership? {
        MobileMoneySavedAccountOwnership(kind: kind)
    }
    var isOwnAccount: Bool { ownership == .mine }
    var isThirdPartyAccount: Bool { ownership == .beneficiary }
    var isActive: Bool { status.caseInsensitiveCompare("active") == .orderedSame }
}

struct MobileMoneyAccountDetailDTO: Decodable {
    let account: MobileMoneyAccountDTO
    let recentOperations: [MobileMoneyOperationDTO]

    enum CodingKeys: String, CodingKey {
        case account
        case recentOperations = "recent_operations"
    }
}

struct MobileMoneyAccountDeletionDTO: Decodable {
    let id: String
    let deleted: Bool
}

/// The two ownership values in the mobile-money account contract. Unknown values stay nil so
/// account eligibility and future account-management mutations fail closed.
enum MobileMoneySavedAccountOwnership: String, CaseIterable, Identifiable, Hashable {
    case mine = "own"
    case beneficiary = "third_party"

    init?(kind: String) {
        switch kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case Self.mine.rawValue:
            self = .mine
        case Self.beneficiary.rawValue:
            self = .beneficiary
        default:
            return nil
        }
    }

    var id: String { rawValue }
    var title: String { self == .mine ? "Mine" : "Beneficiary" }
}

struct MobileMoneyOperationDTO: Decodable, Hashable, Identifiable {
    let id: String
    let reference: String
    let type: String
    let direction: String
    let status: String
    let submissionStage: String?
    let bankId: String
    let beneficiaryId: String?
    let walletId: String
    let amount: String
    let currency: CurrencyDTO
    let providerReference: String?
    let walletTransactionId: String?
    let failure: MobileMoneyFailureDTO?
    let createdAt: String?
    let completedAt: String?
    let mobileMoneyType: String
    let network: MobileMoneyNetworkDTO
    let outboundQuoteId: String?
    let outboundPricing: MobileMoneyOutboundPricingDTO?
    let feeQuoteId: String?
    let feeMode: MobileMoneyFeeMode?
    let requestedAmount: String?
    let providerFee: String?
    let platformFee: String?
    let roundingAdjustment: String?
    let totalFees: String?
    let netAmount: String?

    enum CodingKeys: String, CodingKey {
        case id, reference, type, direction, status, amount, currency, failure, network
        case submissionStage = "submission_stage"
        case bankId = "bank_id"
        case beneficiaryId = "beneficiary_id"
        case walletId = "wallet_id"
        case providerReference = "provider_reference"
        case walletTransactionId = "wallet_transaction_id"
        case createdAt = "created_at"
        case completedAt = "completed_at"
        case mobileMoneyType = "mobile_money_type"
        case outboundQuoteId = "outbound_quote_id"
        case outboundPricing = "outbound_pricing"
        case feeQuoteId = "fee_quote_id"
        case feeMode = "fee_mode"
        case requestedAmount = "requested_amount"
        case providerFee = "provider_fee"
        case platformFee = "platform_fee"
        case roundingAdjustment = "rounding_adjustment"
        case totalFees = "total_fees"
        case netAmount = "net_amount"
    }

    var isTerminal: Bool {
        ["completed", "succeeded", "failed", "reversed", "cancelled", "canceled"]
            .contains(status.lowercased())
    }

    var isSuccessful: Bool {
        ["completed", "succeeded"].contains(status.lowercased())
    }

    var isFailed: Bool {
        status.caseInsensitiveCompare("failed") == .orderedSame
    }

    /// The single combined fee disclosed to the customer. Provider, platform, cap, and
    /// settlement components remain available only for internal response-binding validation.
    var customerTransactionFee: String? {
        if mobileMoneyType.caseInsensitiveCompare(MobileMoneyAction.collection.rawValue)
            == .orderedSame {
            return totalFees
        }
        if mobileMoneyType.caseInsensitiveCompare(MobileMoneyAction.payout.rawValue)
            == .orderedSame {
            return outboundPricing?.processingFee
        }
        return nil
    }

    /// A retry is suggested only when the backend has conclusively recorded a failed collection.
    /// Pending, reversed, cancelled, payout, and outcome-unknown operations retain their own copy.
    var confirmedCollectionFailureMessage: String? {
        guard isFailed,
              mobileMoneyType.caseInsensitiveCompare(MobileMoneyAction.collection.rawValue)
                == .orderedSame,
              let failure
        else { return nil }
        return CustomerFacingPaymentCopy.confirmedMobileMoneyCollectionFailureMessage(
            for: failure.code
        )
    }
}

/// How a mobile-money operation is refreshed while its screen is visible.
///
/// Provider settlement is asynchronous and can take longer than any fixed client-side window.
/// Polling therefore continues until the server returns a terminal operation, while the bounded
/// interval keeps a long-running provider request from becoming a tight network loop.
enum MobileMoneyOperationRefreshPolicy {
    static let firstInterval: TimeInterval = 1.5
    static let maximumInterval: TimeInterval = 10
    static let maximumBackoffAttempt = 5

    static func interval(attempt: Int) -> TimeInterval {
        let boundedAttempt = min(max(attempt, 0), maximumBackoffAttempt)
        guard boundedAttempt > 0 else { return firstInterval }
        let grown = firstInterval * pow(1.5, Double(boundedAttempt))
        return min(maximumInterval, grown)
    }

    static func nextAttempt(after attempt: Int) -> Int {
        guard attempt < maximumBackoffAttempt else { return maximumBackoffAttempt }
        return max(attempt, 0) + 1
    }

    static func shouldPoll(
        _ operation: MobileMoneyOperationDTO,
        isActive: Bool,
        isOnline: Bool
    ) -> Bool {
        isActive && isOnline && !operation.isTerminal
    }

    /// A detail response may advance settlement fields, but it must not replace the operation
    /// with a different payment. These fields are fixed when the operation is created.
    static func hasSameImmutableIdentity(
        _ candidate: MobileMoneyOperationDTO,
        as expected: MobileMoneyOperationDTO
    ) -> Bool {
        guard sameCanonicalID(candidate.id, expected.id),
              sameCanonicalID(candidate.bankId, expected.bankId),
              sameCanonicalID(candidate.walletId, expected.walletId),
              sameCanonicalID(candidate.network.id, expected.network.id),
              sameOptionalCanonicalID(candidate.beneficiaryId, expected.beneficiaryId),
              sameOptionalCanonicalID(candidate.outboundQuoteId, expected.outboundQuoteId),
              sameOptionalCanonicalID(candidate.feeQuoteId, expected.feeQuoteId)
        else { return false }
        return candidate.reference == expected.reference
            && candidate.type.caseInsensitiveCompare(expected.type) == .orderedSame
            && candidate.direction.caseInsensitiveCompare(expected.direction) == .orderedSame
            && candidate.mobileMoneyType.caseInsensitiveCompare(expected.mobileMoneyType)
                == .orderedSame
            && candidate.network.code.caseInsensitiveCompare(expected.network.code) == .orderedSame
            && candidate.currency == expected.currency
            && MobileMoneyAmount.amountsMatch(candidate.amount, expected.amount)
            && candidate.feeMode == expected.feeMode
            && sameOptionalAmount(candidate.requestedAmount, expected.requestedAmount)
    }

    private static func sameCanonicalID(_ candidate: String, _ expected: String) -> Bool {
        guard let candidateID = UUID(uuidString: candidate),
              let expectedID = UUID(uuidString: expected)
        else { return false }
        return candidateID == expectedID
    }

    private static func sameOptionalCanonicalID(
        _ candidate: String?,
        _ expected: String?
    ) -> Bool {
        switch (candidate, expected) {
        case (nil, nil):
            return true
        case (.some(let candidate), .some(let expected)):
            return sameCanonicalID(candidate, expected)
        default:
            return false
        }
    }

    private static func sameOptionalAmount(_ candidate: String?, _ expected: String?) -> Bool {
        switch (candidate, expected) {
        case (nil, nil):
            return true
        case (.some(let candidate), .some(let expected)):
            return MobileMoneyAmount.amountsMatch(candidate, expected)
        default:
            return false
        }
    }
}

/// Customer-facing operation state shared by every mobile-money activity surface.
enum MobileMoneyOperationStatusPresentation {
    static func customerText(for operation: MobileMoneyOperationDTO) -> String {
        if operation.isSuccessful {
            return operation.mobileMoneyType.caseInsensitiveCompare(
                MobileMoneyAction.payout.rawValue
            ) == .orderedSame ? "Paid" : "Completed"
        }
        switch operation.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "failed":
            return "Failed"
        case "reversed":
            return "Reversed"
        case "cancelled", "canceled":
            return "Cancelled"
        default:
            return "Processing"
        }
    }
}

/// Only terminal mobile-money push events are settlement refresh hints. The shared remote-wake
/// notification also carries messaging, support, and call payloads, which must not trigger a
/// financial-history request merely because the mobile-money screen is open.
enum MobileMoneyRemoteWakePolicy {
    private static let terminalEventTypes: Set<String> = [
        "mobile_money.collection.succeeded",
        "mobile_money.collection.failed",
        "mobile_money.collection.reversed",
        "mobile_money.payout.succeeded",
        "mobile_money.payout.failed",
        "mobile_money.payout.reversed",
    ]

    static func shouldRefreshOperations(for object: Any?) -> Bool {
        guard let payload = object as? [AnyHashable: Any],
              let eventType = payload["type"] as? String
        else { return false }
        return terminalEventTypes.contains(eventType)
    }
}

enum MobileMoneySavedAccountActivity {
    /// The server binds both collections and payouts to the saved account through
    /// `beneficiary_id`. Do not infer ownership from a network, name, or masked phone number:
    /// those fields are not unique and could expose another account's activity.
    static func recentOperations(
        for accountID: String,
        from operations: [MobileMoneyOperationDTO],
        limit: Int = 20
    ) -> [MobileMoneyOperationDTO] {
        guard let accountUUID = UUID(uuidString: accountID), limit > 0 else { return [] }
        return Array(operations.lazy.filter { operation in
            guard let beneficiaryID = operation.beneficiaryId,
                  let beneficiaryUUID = UUID(uuidString: beneficiaryID)
            else { return false }
            return beneficiaryUUID == accountUUID
        }.prefix(limit))
    }
}

enum MobileMoneySavedAccountContract {
    static func canonicalID(_ value: String) -> UUID? {
        UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func hasSameImmutableDestination(
        _ candidate: MobileMoneyAccountDTO,
        as expected: MobileMoneyAccountDTO
    ) -> Bool {
        guard let candidateID = canonicalID(candidate.id),
              let expectedID = canonicalID(expected.id),
              let candidateNetworkID = canonicalID(candidate.network.id),
              let expectedNetworkID = canonicalID(expected.network.id)
        else { return false }
        return candidateID == expectedID
            && candidateNetworkID == expectedNetworkID
            && candidate.network.code.caseInsensitiveCompare(expected.network.code) == .orderedSame
            && candidate.phoneNumberMasked == expected.phoneNumberMasked
    }

    static func isValidDetail(
        _ detail: MobileMoneyAccountDetailDTO,
        expectedAccount: MobileMoneyAccountDTO
    ) -> Bool {
        guard detail.account.isActive,
              detail.account.ownership != nil,
              detail.recentOperations.count <= 20,
              hasSameImmutableDestination(detail.account, as: expectedAccount),
              let accountID = canonicalID(expectedAccount.id)
        else { return false }
        return detail.recentOperations.allSatisfy { operation in
            guard let beneficiaryID = operation.beneficiaryId.flatMap({ canonicalID($0) }) else {
                return false
            }
            return beneficiaryID == accountID
        }
    }

    static func isValidOwnershipUpdate(
        _ updated: MobileMoneyAccountDTO,
        expectedAccount: MobileMoneyAccountDTO,
        ownership: MobileMoneySavedAccountOwnership
    ) -> Bool {
        updated.isActive
            && updated.ownership == ownership
            && hasSameImmutableDestination(updated, as: expectedAccount)
    }

    static func isValidDeletion(
        _ deletion: MobileMoneyAccountDeletionDTO,
        expectedAccountID: String
    ) -> Bool {
        guard deletion.deleted,
              let deletedID = canonicalID(deletion.id),
              let expectedID = canonicalID(expectedAccountID)
        else { return false }
        return deletedID == expectedID
    }
}

struct CreateMobileMoneyVerificationRequest: Encodable {
    let network: String
    let phoneNumber: String

    enum CodingKeys: String, CodingKey {
        case network
        case phoneNumber = "phone_number"
    }
}

struct CreateMobileMoneyAccountRequest: Encodable {
    let verificationId: String
    let kind: String
    let label: String

    enum CodingKeys: String, CodingKey {
        case verificationId = "verification_id"
        case kind, label
    }
}

struct UpdateMobileMoneyAccountRequest: Encodable {
    let kind: String
}

struct CreateLegacyMobileMoneyCollectionRequest: Encodable {
    let walletId: String
    let accountId: String
    let amount: String

    enum CodingKeys: String, CodingKey {
        case walletId = "wallet_id"
        case accountId = "account_id"
        case amount
    }
}

struct CreateMobileMoneyCollectionQuoteRequest: Encodable {
    let walletId: String
    let accountId: String
    let amount: String
    let feeMode: MobileMoneyFeeMode

    enum CodingKeys: String, CodingKey {
        case walletId = "wallet_id"
        case accountId = "account_id"
        case amount
        case feeMode = "fee_mode"
    }
}

struct CreateMobileMoneyPayoutQuoteRequest: Encodable {
    let walletId: String
    let accountId: String
    let amount: String
    let feeMode: MobileMoneyPayoutFeeMode

    enum CodingKeys: String, CodingKey {
        case walletId = "wallet_id"
        case accountId = "account_id"
        case amount
        case feeMode = "fee_mode"
    }
}

struct CreateQuotedMobileMoneyCollectionRequest: Encodable {
    let quoteId: String

    enum CodingKeys: String, CodingKey {
        case quoteId = "quote_id"
    }
}

struct CreateQuotedMobileMoneyPayoutRequest: Encodable {
    let quoteId: String

    enum CodingKeys: String, CodingKey {
        case quoteId = "quote_id"
    }
}

enum MobileMoneyAction: String, Identifiable {
    case collection
    case payout

    var id: String { rawValue }
    var purpose: String { "mobile_money_\(rawValue)" }
    var endpointComponent: String { self == .collection ? "collections" : "payouts" }
    var title: String { self == .collection ? "Cash in" : "Cash out" }
}

/// User-facing mobile-money journeys. The payment contract exposes one payout operation
/// for both sending to another person and withdrawing to the customer's own number, while
/// the app keeps those destinations distinct so the wrong saved account cannot be chosen.
enum MobileMoneyFlow: String, Identifiable, CaseIterable {
    case addMoney = "add_money"
    case send
    case withdraw

    var id: String { rawValue }

    var action: MobileMoneyAction {
        self == .addMoney ? .collection : .payout
    }

    var title: String {
        switch self {
        case .addMoney: "Add money"
        case .send: "Send"
        case .withdraw: "Withdraw"
        }
    }

    var subtitle: String {
        switch self {
        case .addMoney: "Mobile to Kit"
        case .send: "To another number"
        case .withdraw: "To my number"
        }
    }

    var systemImage: String {
        switch self {
        case .addMoney: "arrow.down.left"
        case .send: "paperplane.fill"
        case .withdraw: "arrow.up.right"
        }
    }

    var defaultPayoutOwnership: MobileMoneyRecipientOwnership {
        self == .withdraw ? .myself : .someoneElse
    }
}

enum MobileMoneyRecipientOwnership: String, CaseIterable, Identifiable, Hashable {
    case myself = "own"
    case someoneElse = "third_party"

    var id: String { rawValue }
    var accountKind: String { rawValue }

    var title: String {
        switch self {
        case .myself: "Send to myself"
        case .someoneElse: "Send to someone else"
        }
    }
}

enum MobileMoneyPayoutRecipientSource: String, CaseIterable, Identifiable, Hashable {
    case savedAccount = "saved_account"
    case newNumber = "new_number"

    var id: String { rawValue }
    var title: String { self == .savedAccount ? "Saved" : "New number" }
}

struct MobileMoneyPayoutLookupRequest: Hashable {
    let networkCode: String
    let phoneNumber: String
    let ownership: MobileMoneyRecipientOwnership

    init?(
        networkCode: String,
        rawPhoneNumber: String,
        ownership: MobileMoneyRecipientOwnership
    ) {
        let network = networkCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard ["MTN", "AIRTEL"].contains(network),
              let phone = UgandaMobileMoneyPhone.apiValue(from: rawPhoneNumber)
        else { return nil }
        self.networkCode = network
        phoneNumber = phone
        self.ownership = ownership
    }
}

struct MobileMoneyLookupGeneration {
    private(set) var id: UUID?
    private(set) var request: MobileMoneyPayoutLookupRequest?

    mutating func begin(
        _ request: MobileMoneyPayoutLookupRequest,
        id: UUID = UUID()
    ) -> UUID {
        self.id = id
        self.request = request
        return id
    }

    mutating func invalidate() {
        id = nil
        request = nil
    }

    func accepts(_ id: UUID, request: MobileMoneyPayoutLookupRequest) -> Bool {
        self.id == id && self.request == request
    }
}

enum MobileMoneyPayoutLookupState: Equatable {
    case idle
    case saved(MobileMoneyRecipientOwnership, MobileMoneyAccountDTO)
    case verifying(MobileMoneyPayoutLookupRequest)
    case verified(MobileMoneyPayoutLookupRequest, MobileMoneyAccountDTO)
    case failed(MobileMoneyPayoutLookupRequest, String)

    func account(for ownership: MobileMoneyRecipientOwnership) -> MobileMoneyAccountDTO? {
        switch self {
        case .saved(let savedOwnership, let account):
            return savedOwnership == ownership ? account : nil
        case .verified(let request, let account):
            return request.ownership == ownership ? account : nil
        case .idle, .verifying, .failed:
            return nil
        }
    }
}

enum MobileMoneyPayoutSavedAccountPolicy {
    static func eligibleAccounts(
        from accounts: [MobileMoneyAccountDTO],
        ownership: MobileMoneyRecipientOwnership
    ) -> [MobileMoneyAccountDTO] {
        accounts.filter {
            MobileMoneySavedAccountRailPolicy.isMobileMoneyRailDestination($0.network)
                && $0.isPayoutCapable
                && $0.hasConfirmedPayoutIdentity
                && $0.hasPreferredPayoutOwnership(ownership)
        }
    }

    static func account(
        id accountID: String,
        ownership: MobileMoneyRecipientOwnership,
        in accounts: [MobileMoneyAccountDTO]
    ) -> MobileMoneyAccountDTO? {
        eligibleAccounts(from: accounts, ownership: ownership).first {
            $0.id.caseInsensitiveCompare(accountID) == .orderedSame
        }
    }
}

/// The counterpart of `BankBeneficiaryRailPolicy` for the shared backend beneficiary store:
/// mobile-money rows carry no explicit rail field either, so bank-rail rows are kept off the
/// mobile-money surface using the strongest signals available. Only banks advertise a
/// `transfers` capability and only banks use numeric institution codes; a row showing either
/// bank signal — or an empty code — is excluded here, and rows mixing both rails' signals are
/// also excluded from the bank surface, so ambiguous records fail closed on both rails.
enum MobileMoneySavedAccountRailPolicy {
    static func isMobileMoneyRailDestination(_ network: MobileMoneyNetworkDTO) -> Bool {
        guard network.capabilities?["transfers"] != true else { return false }
        let code = network.code.trimmingCharacters(in: .whitespacesAndNewlines)
        return !code.isEmpty && !code.allSatisfy(\.isNumber)
    }

    static func mobileMoneyAccounts(
        _ accounts: [MobileMoneyAccountDTO]
    ) -> [MobileMoneyAccountDTO] {
        accounts.filter { isMobileMoneyRailDestination($0.network) }
    }
}

enum MobileMoneySavedAccountActionPolicy {
    static func canCollect(from account: MobileMoneyAccountDTO) -> Bool {
        MobileMoneySavedAccountRailPolicy.isMobileMoneyRailDestination(account.network)
            && account.isActive
            && account.isOwnAccount
            && account.network.canCollect
    }

    static func payoutFlow(for account: MobileMoneyAccountDTO) -> MobileMoneyFlow? {
        guard MobileMoneySavedAccountRailPolicy.isMobileMoneyRailDestination(account.network),
              account.isPayoutCapable,
              account.hasConfirmedPayoutIdentity
        else { return nil }
        if account.isOwnAccount { return .withdraw }
        if account.isThirdPartyAccount { return .send }
        return nil
    }
}

extension MobileMoneyAccountDTO {
    func isEligible(for flow: MobileMoneyFlow) -> Bool {
        guard MobileMoneySavedAccountRailPolicy.isMobileMoneyRailDestination(network),
              isActive
        else { return false }
        switch flow {
        case .addMoney:
            return MobileMoneySavedAccountActionPolicy.canCollect(from: self)
        case .send:
            return isThirdPartyAccount && network.canPayout
        case .withdraw:
            return isOwnAccount && network.canPayout
        }
    }

    var isPayoutCapable: Bool {
        isActive
            && MobileMoneySavedAccountRailPolicy.isMobileMoneyRailDestination(network)
            && network.canPayout
            && ["MTN", "AIRTEL"].contains(network.code.uppercased())
    }

    var hasConfirmedPayoutIdentity: Bool {
        guard let name = accountName?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !name.isEmpty
    }

    func hasPreferredPayoutOwnership(_ ownership: MobileMoneyRecipientOwnership) -> Bool {
        switch ownership {
        case .myself: return isOwnAccount
        case .someoneElse: return isThirdPartyAccount
        }
    }

    func hasSamePayoutIdentity(as other: MobileMoneyAccountDTO) -> Bool {
        guard let ownName = accountName?.trimmingCharacters(in: .whitespacesAndNewlines),
              let otherName = other.accountName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ownName.isEmpty,
              !otherName.isEmpty
        else { return false }
        return id.caseInsensitiveCompare(other.id) == .orderedSame
            && kind.caseInsensitiveCompare(other.kind) == .orderedSame
            && network.id.caseInsensitiveCompare(other.network.id) == .orderedSame
            && network.code.caseInsensitiveCompare(other.network.code) == .orderedSame
            && phoneNumberMasked == other.phoneNumberMasked
            && ownName.caseInsensitiveCompare(otherName) == .orderedSame
    }
}

enum MobileMoneyTransactionPresentation {
    static func transaction(
        for operation: MobileMoneyOperationDTO,
        accounts: [MobileMoneyAccountDTO],
        walletTransactions: [WalletTransaction]
    ) -> WalletTransaction {
        if let walletTransactionID = operation.walletTransactionId?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ),
            !walletTransactionID.isEmpty,
            let exact = walletTransactions.first(where: {
                $0.id.caseInsensitiveCompare(walletTransactionID) == .orderedSame
                    && $0.walletId.caseInsensitiveCompare(operation.walletId) == .orderedSame
            }) {
            return exact
        }

        let account = operation.beneficiaryId.flatMap { beneficiaryID in
            accounts.first {
                $0.id.caseInsensitiveCompare(beneficiaryID) == .orderedSame
            }
        }
        let isCollection = operation.mobileMoneyType.caseInsensitiveCompare(
            MobileMoneyAction.collection.rawValue
        ) == .orderedSame
        let transactionID = nonBlank(operation.walletTransactionId)
            ?? "mobile-money-operation:\(operation.id)"
        let amount = isCollection
            ? operation.netAmount ?? operation.amount
            : operation.outboundPricing?.customerDebit ?? operation.amount
        let counterpartyName = nonBlank(account?.accountName)
            ?? account?.label
            ?? operation.network.name
        let note = operation.failure?.message.map {
            CustomerFacingPaymentCopy.neutralizedServiceMessage($0)
        } ?? account.map { "\($0.network.name) • \($0.phoneNumberMasked)" }

        return WalletTransaction(
            id: transactionID,
            walletId: operation.walletId,
            reference: operation.reference,
            amount: amount,
            currency: operation.currency,
            type: operation.type.isEmpty
                ? "mobile_money_\(operation.mobileMoneyType.lowercased())"
                : operation.type,
            direction: isCollection ? "credit" : "debit",
            status: operation.isSuccessful ? "completed" : operation.status,
            counterparty: Counterparty(
                id: account?.id,
                name: counterpartyName,
                phone: account?.phoneNumberMasked,
                accountNumber: nil
            ),
            note: note,
            occurredAt: operation.completedAt ?? operation.createdAt ?? ""
        )
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}

enum MobileMoneyAmount {
    private static let locale = Locale(identifier: "en_US_POSIX")

    /// Mobile-money collections settle in whole currency units. Accept a decimal amount from
    /// the customer and round it to the nearest unit (`.5` rounds up) before constructing the
    /// scaled API value. This keeps the provider constraint out of the customer experience.
    static func roundedCollectionAPIAmount(_ raw: String, scale: Int) -> String? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
        guard !cleaned.isEmpty,
              let value = Decimal(string: cleaned, locale: locale),
              value > 0
        else { return nil }

        var source = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &source, 0, .plain)
        guard rounded > 0 else { return nil }

        let canonicalWhole = NSDecimalNumber(decimal: rounded).stringValue
        let safeScale = min(max(scale, 0), 9)
        return safeScale == 0
            ? canonicalWhole
            : canonicalWhole + "." + String(repeating: "0", count: safeScale)
    }

    static func wholeUnitAPIAmount(_ raw: String, scale: Int) -> String? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
        guard !cleaned.isEmpty, cleaned.allSatisfy(\.isNumber),
              let value = Decimal(string: cleaned, locale: locale),
              value > 0
        else { return nil }
        let safeScale = min(max(scale, 0), 9)
        let canonicalWhole = String(cleaned.drop(while: { $0 == "0" }))
        guard !canonicalWhole.isEmpty else { return nil }
        return safeScale == 0
            ? canonicalWhole
            : canonicalWhole + "." + String(repeating: "0", count: safeScale)
    }

    static func amountsMatch(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = Decimal(string: lhs, locale: locale),
              let right = Decimal(string: rhs, locale: locale)
        else { return false }
        return left == right
    }
}

extension CapabilitiesDTO {
    var enablesMobileMoney: Bool {
        let enabled = features?.compactMapValues { $0 }
        return enabled?["wallets"] == true && enabled?["mobile_money"] == true
    }
}
