import Foundation

struct BankListDTO: Decodable {
    let items: [BankDTO]?

    private enum CodingKeys: String, CodingKey {
        case items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.items), !(try container.decodeNil(forKey: .items)) else {
            items = nil
            return
        }
        if let array = try? container.decode([BankDTO].self, forKey: .items) {
            items = array
            return
        }

        // A filtered Laravel collection was briefly serialized with its retained numeric
        // indexes, turning `items` into a JSON object instead of an array. Accept only that
        // narrowly defined legacy shape so an otherwise successful catalog remains usable.
        let indexed = try container.decode([String: BankDTO].self, forKey: .items)
        let ordered = try indexed.map { key, bank -> (index: Int, bank: BankDTO) in
            guard let index = Int(key), index >= 0, String(index) == key else {
                throw DecodingError.dataCorruptedError(
                    forKey: .items,
                    in: container,
                    debugDescription: "Bank catalog item keys must be non-negative numeric indexes."
                )
            }
            return (index, bank)
        }
        items = ordered.sorted { $0.index < $1.index }.map { $0.bank }
    }
}

struct BankAccountVerificationListDTO: Decodable {
    let items: [BankAccountVerificationDTO]?
}

struct BankBeneficiaryListDTO: Decodable {
    let items: [BankBeneficiaryDTO]?
}

struct BankingOperationListDTO: Decodable {
    let items: [BankingOperationDTO]?
}

enum BankTransferFeeMode: String, Codable, CaseIterable, Identifiable {
    case senderAbsorbs = "sender_absorbs"
    case beneficiaryAbsorbs = "recipient_absorbs"
    case kitCovers = "kit_covers"

    var id: String { rawValue }
}

struct BankTransferQuoteBankDTO: Decodable, Hashable {
    let id: String
    let code: String
    let name: String
}

struct BankTransferQuoteStepUpDTO: Decodable {
    let purpose: String
    let intent: [String: String]

    var authorizationIntent: [String: String?] {
        intent.mapValues(Optional.some)
    }
}

struct BankTransferQuoteDTO: Decodable, Identifiable {
    let id: String
    let action: String
    let operationType: String
    let feeMode: BankTransferFeeMode
    let walletId: String
    let beneficiaryId: String
    let bank: BankTransferQuoteBankDTO
    let recipientAmount: String
    let processingFee: String
    let providerFee: String?
    let kitFee: String?
    let providerFeeCap: String
    let maximumProviderTotal: String
    let customerDebit: String
    let kitDebit: String
    let scheduleVersion: String
    let scheduleVerified: Bool
    let currency: CurrencyDTO
    let expiresAt: String
    let stepUp: BankTransferQuoteStepUpDTO

    enum CodingKeys: String, CodingKey {
        case id, action, bank, currency
        case operationType = "operation_type"
        case feeMode = "fee_mode"
        case walletId = "wallet_id"
        case beneficiaryId = "beneficiary_id"
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
    var enteredAmount: String {
        feeMode == .beneficiaryAbsorbs ? customerDebit : recipientAmount
    }

    var hasConsistentAmounts: Bool {
        BankTransferMoney.outboundAmountsReconcile(
            feeMode: feeMode,
            recipientAmount: recipientAmount,
            processingFee: processingFee,
            providerFee: providerFee,
            kitFee: kitFee,
            providerFeeCap: providerFeeCap,
            maximumProviderTotal: maximumProviderTotal,
            customerDebit: customerDebit,
            kitDebit: kitDebit
        )
    }

    var hasValidStepUpBinding: Bool {
        guard stepUp.purpose == BankTransferContract.purpose,
              (providerFee == nil) == (kitFee == nil)
        else { return false }

        var expected = [
            "action": action,
            "operation_type": operationType,
            "quote_id": id,
            "wallet_id": walletId,
            "beneficiary_id": beneficiaryId,
            "bank_id": bank.id,
            "bank_code": bank.code,
            "fee_mode": feeMode.rawValue,
            "recipient_amount": recipientAmount,
            "processing_fee": processingFee,
            "provider_fee_cap": providerFeeCap,
            "maximum_provider_total": maximumProviderTotal,
            "customer_debit": customerDebit,
            "kit_debit": kitDebit,
            "schedule_version": scheduleVersion,
            "currency": currency.code,
        ]
        if let providerFee, let kitFee {
            expected["provider_fee"] = providerFee
            expected["kit_fee"] = kitFee
        }
        return stepUp.intent == expected
    }
}

struct BankDTO: Codable, Hashable, Identifiable {
    let id: String
    let code: String
    let name: String
    let countryCode: String
    let currency: String
    let capabilities: [String: Bool?]?

    enum CodingKeys: String, CodingKey {
        case id, code, name, currency, capabilities
        case countryCode = "country_code"
    }

    var canVerifyAccount: Bool { capabilities?["account_verification"] == true }
    var canTransfer: Bool { capabilities?["transfers"] == true }
}

struct BankOperationFailureDTO: Codable, Hashable {
    let code: String
    let message: String?
}

struct BankAccountVerificationDTO: Decodable, Hashable, Identifiable {
    let id: String
    let bankId: String
    let status: String
    let accountNumberMasked: String
    let verifiedAccountName: String?
    let failure: BankOperationFailureDTO?
    let verifiedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, status, failure
        case bankId = "bank_id"
        case accountNumberMasked = "account_number_masked"
        case verifiedAccountName = "verified_account_name"
        case verifiedAt = "verified_at"
    }

    var isVerified: Bool {
        status.caseInsensitiveCompare("verified") == .orderedSame
            && verifiedAccountName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var isPending: Bool {
        ["pending", "queued", "processing", "submitted"].contains(status.lowercased())
    }
}

struct BankBeneficiaryDTO: Decodable, Hashable, Identifiable {
    let id: String
    let kind: String
    let label: String
    let bank: BankDTO
    let accountName: String
    let accountNumberMasked: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case id, kind, label, bank, status
        case accountName = "account_name"
        case accountNumberMasked = "account_number_masked"
    }

    var isActive: Bool { status.caseInsensitiveCompare("active") == .orderedSame }
}

struct BankingOperationDTO: Decodable, Hashable, Identifiable {
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
    let outboundQuoteId: String?
    let outboundPricing: BankTransferOutboundPricingDTO?
    let feeQuoteId: String?
    let feeMode: String?
    let requestedAmount: String?
    let providerFee: String?
    let platformFee: String?
    let roundingAdjustment: String?
    let totalFees: String?
    let netAmount: String?
    let providerReference: String?
    let walletTransactionId: String?
    let reversalTransactionId: String?
    let failure: BankOperationFailureDTO?
    let createdAt: String?
    let completedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, reference, type, direction, status, amount, currency, failure
        case submissionStage = "submission_stage"
        case bankId = "bank_id"
        case beneficiaryId = "beneficiary_id"
        case walletId = "wallet_id"
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
        case providerReference = "provider_reference"
        case walletTransactionId = "wallet_transaction_id"
        case reversalTransactionId = "reversal_transaction_id"
        case createdAt = "created_at"
        case completedAt = "completed_at"
    }

    var isTerminal: Bool {
        ["completed", "succeeded", "failed", "reversed", "cancelled", "canceled"]
            .contains(status.lowercased())
    }

    var isSuccessful: Bool {
        ["completed", "succeeded"].contains(status.lowercased())
    }

    func hasSameOutboundBinding(as quote: BankTransferQuoteDTO) -> Bool {
        type.caseInsensitiveCompare(BankTransferContract.operationType) == .orderedSame
            && direction.caseInsensitiveCompare("outbound") == .orderedSame
            && outboundQuoteId == quote.id
            && walletId == quote.walletId
            && beneficiaryId == quote.beneficiaryId
            && bankId == quote.bank.id
            && currency == quote.currency
            && BankTransferMoney.amountsMatch(amount, quote.recipientAmount)
            && outboundPricing?.matches(quote) == true
    }
}

struct BankTransferOutboundPricingDTO: Decodable, Hashable {
    let feeMode: BankTransferFeeMode
    let recipientAmount: String
    let processingFee: String
    let providerFee: String?
    let kitFee: String?
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
        BankTransferMoney.outboundAmountsReconcile(
            feeMode: feeMode,
            recipientAmount: recipientAmount,
            processingFee: processingFee,
            providerFee: providerFee,
            kitFee: kitFee,
            providerFeeCap: providerFeeCap,
            maximumProviderTotal: maximumProviderTotal,
            customerDebit: customerDebit,
            kitDebit: kitDebit
        )
    }

    func matches(_ quote: BankTransferQuoteDTO) -> Bool {
        feeMode == quote.feeMode
            && scheduleVersion == quote.scheduleVersion
            && BankTransferMoney.amountsMatch(recipientAmount, quote.recipientAmount)
            && BankTransferMoney.amountsMatch(processingFee, quote.processingFee)
            && optionalAmountMatches(providerFee, quote.providerFee)
            && optionalAmountMatches(kitFee, quote.kitFee)
            && BankTransferMoney.amountsMatch(providerFeeCap, quote.providerFeeCap)
            && BankTransferMoney.amountsMatch(maximumProviderTotal, quote.maximumProviderTotal)
            && BankTransferMoney.amountsMatch(customerDebit, quote.customerDebit)
            && BankTransferMoney.amountsMatch(kitDebit, quote.kitDebit)
            && hasConsistentAmounts
    }

    private func optionalAmountMatches(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case let (left?, right?):
            BankTransferMoney.amountsMatch(left, right)
        case (nil, nil):
            true
        default:
            false
        }
    }
}

struct CreateBankAccountVerificationRequest: Encodable {
    let bankId: String
    let accountNumber: String

    enum CodingKeys: String, CodingKey {
        case bankId = "bank_id"
        case accountNumber = "account_number"
    }
}

struct CreateBankBeneficiaryRequest: Encodable {
    let verificationId: String
    let kind: String
    let label: String

    enum CodingKeys: String, CodingKey {
        case verificationId = "verification_id"
        case kind, label
    }
}

struct CreateBankTransferQuoteRequest: Encodable {
    let walletId: String
    let beneficiaryId: String
    let amount: String
    let feeMode: BankTransferFeeMode

    enum CodingKeys: String, CodingKey {
        case walletId = "wallet_id"
        case beneficiaryId = "beneficiary_id"
        case amount
        case feeMode = "fee_mode"
    }
}

struct CreateQuotedBankTransferRequest: Encodable {
    let quoteId: String

    enum CodingKeys: String, CodingKey {
        case quoteId = "quote_id"
    }
}

enum BankTransferContract {
    static let purpose = "bank_transfer"
    static let operationType = "bank_transfer"
}

enum BankAccountNumber {
    static func apiValue(from raw: String) -> String? {
        let normalized = normalizedInput(raw)
        guard (4 ... 40).contains(normalized.count) else { return nil }
        return normalized
    }

    static func normalizedInput(_ raw: String) -> String {
        String(raw.uppercased().filter { character in
            character.isASCII && (character.isLetter || character.isNumber)
        }.prefix(40))
    }
}

enum BankTransferMoney {
    static let minimumUGXTransfer = Decimal(20_000)

    static func editableWholeUGXInput(_ raw: String) -> String? {
        let compact = raw.filter { !$0.isWhitespace && $0 != "," }
        guard compact.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return PaymentInputFormatting.normalizedWholeInput(compact)
    }

    /// RukaPay bank payouts settle in whole UGX. Keep the wire amount integer-valued and never
    /// silently round or truncate a decimal entered by the customer.
    static func wholeUGXAmount(_ raw: String) -> String? {
        guard let normalized = editableWholeUGXInput(raw), !normalized.isEmpty else { return nil }
        let significant = String(normalized.drop(while: { $0 == "0" }))
        guard !significant.isEmpty,
              Decimal(string: significant, locale: Locale(identifier: "en_US_POSIX")) != nil
        else { return nil }
        return significant
    }

    static func transferableWholeUGXAmount(_ raw: String) -> String? {
        guard let amount = wholeUGXAmount(raw),
              let value = Decimal(
                  string: amount,
                  locale: Locale(identifier: "en_US_POSIX")
              ),
              value >= minimumUGXTransfer
        else { return nil }
        return amount
    }

    static func operationAmount(_ value: String, matchesWholeUGX amount: String) -> Bool {
        guard let returned = Decimal(
            string: value,
            locale: Locale(identifier: "en_US_POSIX")
        ), let submitted = Decimal(
            string: amount,
            locale: Locale(identifier: "en_US_POSIX")
        ) else { return false }
        return returned == submitted && returned.rounded(scale: 0) == returned
    }

    static func amountsMatch(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = Decimal(string: lhs, locale: Locale(identifier: "en_US_POSIX")),
              let right = Decimal(string: rhs, locale: Locale(identifier: "en_US_POSIX"))
        else { return false }
        return left == right
    }

    static func outboundAmountsReconcile(
        feeMode: BankTransferFeeMode,
        recipientAmount: String,
        processingFee: String,
        providerFee: String? = nil,
        kitFee: String? = nil,
        providerFeeCap: String,
        maximumProviderTotal: String,
        customerDebit: String,
        kitDebit: String
    ) -> Bool {
        let locale = Locale(identifier: "en_US_POSIX")
        guard let recipient = Decimal(string: recipientAmount, locale: locale), recipient > 0,
              let fee = Decimal(string: processingFee, locale: locale), fee >= 0,
              let providerCap = Decimal(string: providerFeeCap, locale: locale), providerCap >= 0,
              let maximumTotal = Decimal(string: maximumProviderTotal, locale: locale),
              let customer = Decimal(string: customerDebit, locale: locale), customer > 0,
              let kit = Decimal(string: kitDebit, locale: locale), kit >= 0,
              (providerFee == nil) == (kitFee == nil)
        else { return false }

        let provider: Decimal
        let platform: Decimal
        if let providerFee, let kitFee {
            guard let parsedProvider = Decimal(string: providerFee, locale: locale),
                  let parsedPlatform = Decimal(string: kitFee, locale: locale)
            else { return false }
            provider = parsedProvider
            platform = parsedPlatform
        } else {
            provider = providerCap
            platform = 0
        }
        guard provider >= 0,
              platform >= 0,
              providerCap == provider,
              fee == provider + platform,
              maximumTotal == recipient + provider
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

enum BankTransferIdempotency {
    static func key(prefix: String, id: UUID = UUID()) -> String {
        "\(prefix)-\(id.uuidString.lowercased())"
    }
}

extension CapabilitiesDTO {
    var enablesBankTransfers: Bool {
        let enabled = features?.compactMapValues { $0 }
        return enabled?["wallets"] == true && enabled?["bank_transfers"] == true
    }
}

private extension Decimal {
    func rounded(scale: Int) -> Decimal {
        var source = self
        var result = Decimal()
        NSDecimalRound(&result, &source, scale, .plain)
        return result
    }
}
