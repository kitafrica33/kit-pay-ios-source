import Foundation

struct ProviderProductListDTO: Decodable {
    let items: [ProviderProductDTO]?
}

struct ProviderProductDTO: Codable, Hashable, Identifiable {
    let id: String
    let code: String
    let name: String
    let serviceType: String
    let provider: ProviderSummaryDTO
    let category: ProviderCategoryDTO
    let currency: CurrencyDTO
    let minimumAmount: String?
    let maximumAmount: String?

    enum CodingKeys: String, CodingKey {
        case id, code, name, provider, category, currency
        case serviceType = "service_type"
        case minimumAmount = "minimum_amount"
        case maximumAmount = "maximum_amount"
    }
}

enum AirtimeProductPresentationPolicy {
    static func ordered(_ products: [ProviderProductDTO]) -> [ProviderProductDTO] {
        products.enumerated().sorted { lhs, rhs in
            let lhsPriority = networkPriority(for: lhs.element)
            let rhsPriority = networkPriority(for: rhs.element)
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            return lhs.offset < rhs.offset
        }.map { $0.element }
    }

    static func preferredProductID(in products: [ProviderProductDTO]) -> String? {
        ordered(products).first?.id
    }

    static func customerFacingName(for product: ProviderProductDTO) -> String {
        guard product.serviceType.caseInsensitiveCompare(ProviderService.airtime.rawValue)
            == .orderedSame
        else { return product.name }

        return switch network(for: product) {
        case .airtel: "Airtel airtime"
        case .mtn: "MTN airtime"
        case nil: product.name
        }
    }

    private enum Network {
        case airtel
        case mtn
    }

    private static func networkPriority(for product: ProviderProductDTO) -> Int {
        switch network(for: product) {
        case .airtel: 0
        case .mtn: 1
        case nil: 2
        }
    }

    private static func network(for product: ProviderProductDTO) -> Network? {
        let words = [
            product.code,
            product.name,
            product.category.code,
            product.category.name,
        ]
        .joined(separator: " ")
        .lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }

        if words.contains("airtel") { return .airtel }
        if words.contains("mtn") { return .mtn }
        return nil
    }
}

extension ProviderProductDTO {
    var customerFacingName: String {
        AirtimeProductPresentationPolicy.customerFacingName(for: self)
    }
}

struct ProviderSummaryDTO: Codable, Hashable {
    let id: String
    let code: String
    let name: String
    let countryCode: String

    enum CodingKeys: String, CodingKey {
        case id, code, name
        case countryCode = "country_code"
    }
}

struct ProviderCategoryDTO: Codable, Hashable {
    let id: String
    let serviceType: String
    let code: String
    let name: String
    let displayOrder: Int?

    enum CodingKeys: String, CodingKey {
        case id, code, name
        case serviceType = "service_type"
        case displayOrder = "display_order"
    }
}

struct ProviderQuoteDTO: Decodable, Hashable, Identifiable {
    let id: String
    let productId: String
    let providerCode: String
    let serviceType: String
    let accountDisplay: String?
    let amount: String
    let fee: String
    let total: String
    let currency: CurrencyDTO
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case id, amount, fee, total, currency
        case productId = "product_id"
        case providerCode = "provider_code"
        case serviceType = "service_type"
        case accountDisplay = "account_display"
        case expiresAt = "expires_at"
    }

    var isExpired: Bool {
        guard let date = ISO8601DateFormatter().date(from: expiresAt) else { return true }
        return date <= Date()
    }
}

struct ProviderOperationDTO: Decodable, Hashable, Identifiable {
    let id: String
    let type: String
    let status: String
    let walletId: String
    let providerCode: String
    let productId: String
    let productName: String
    let accountDisplay: String?
    let amount: String
    let fee: String
    let total: String
    let currency: CurrencyDTO
    let clientReference: String?
    let providerStatus: String?
    let providerReference: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, type, status, amount, fee, total, currency
        case walletId = "wallet_id"
        case providerCode = "provider_code"
        case productId = "product_id"
        case productName = "product_name"
        case accountDisplay = "account_display"
        case clientReference = "client_reference"
        case providerStatus = "provider_status"
        case providerReference = "provider_reference"
        case createdAt = "created_at"
    }

    var isTerminal: Bool {
        ["succeeded", "failed", "reversed"].contains(status.lowercased())
    }

    var isSuccessful: Bool {
        status.caseInsensitiveCompare("succeeded") == .orderedSame
    }

    func hasSamePaymentBinding(as other: ProviderOperationDTO) -> Bool {
        id == other.id
            && type == other.type
            && walletId == other.walletId
            && providerCode.caseInsensitiveCompare(other.providerCode) == .orderedSame
            && productId == other.productId
            && clientReference == other.clientReference
            && ProviderMoney.amountsMatch(amount, other.amount)
            && ProviderMoney.amountsMatch(fee, other.fee)
            && ProviderMoney.amountsMatch(total, other.total)
            && currency == other.currency
    }
}

struct CreateProviderQuoteRequest: Encodable {
    let account: String
    let amount: String
}

struct CreateProviderOperationRequest: Encodable {
    let quoteId: String
    let walletId: String
    let clientReference: String

    enum CodingKeys: String, CodingKey {
        case quoteId = "quote_id"
        case walletId = "wallet_id"
        case clientReference = "client_reference"
    }
}

struct ProviderOperationBinding {
    let quoteId: String
    let walletId: String
    let clientReference: String

    var stepUpIntent: [String: String?] {
        [
            "quote_id": quoteId,
            "wallet_id": walletId,
            "client_reference": clientReference,
        ]
    }

    var request: CreateProviderOperationRequest {
        CreateProviderOperationRequest(
            quoteId: quoteId,
            walletId: walletId,
            clientReference: clientReference
        )
    }

    var idempotencyKey: String { clientReference }
}

enum ProviderService: String {
    case bill
    case airtime

    var operationType: String {
        switch self {
        case .bill: "bill_payment"
        case .airtime: "airtime_purchase"
        }
    }
}

enum ProviderMoney {
    static func apiAmount(_ raw: String, product: ProviderProductDTO) -> String? {
        if product.requiresWholeUGXRukaPayAmount {
            return wholeUGXAPIAmount(raw)
        }
        return apiAmount(raw, scale: Int(product.currency.scale) ?? 2)
    }

    static func apiAmount(_ raw: String, scale: Int) -> String? {
        let scale = min(max(scale, 0), 9)
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
        let pieces = cleaned.split(separator: ".", omittingEmptySubsequences: false)
        guard !cleaned.isEmpty, pieces.count <= 2 else { return nil }

        let wholeRaw = String(pieces.first ?? "")
        let fractionRaw = pieces.count == 2 ? String(pieces[1]) : ""
        guard !wholeRaw.isEmpty,
              wholeRaw.allSatisfy(\.isNumber),
              fractionRaw.allSatisfy(\.isNumber),
              fractionRaw.count <= scale
        else { return nil }

        let trimmedWhole = wholeRaw.drop(while: { $0 == "0" })
        let whole = trimmedWhole.isEmpty ? "0" : String(trimmedWhole)
        let fraction = fractionRaw + String(repeating: "0", count: scale - fractionRaw.count)
        let amount = scale == 0 ? whole : "\(whole).\(fraction)"
        guard let decimal = decimal(amount), decimal > 0 else { return nil }
        return amount
    }

    /// RukaPay's Uganda provider rails accept integer shillings, even though the Kit
    /// catalog represents UGX with a two-place ledger scale. Commas are presentation
    /// only and no decimal input is rounded or silently reinterpreted.
    static func wholeUGXAPIAmount(_ raw: String) -> String? {
        guard let digits = normalizedWholeUGXInput(raw), !digits.isEmpty else { return nil }
        let canonical = String(digits.drop(while: { $0 == "0" }))
        guard !canonical.isEmpty else { return nil }
        return canonical
    }

    /// Strict edit-time normalization for the whole-UGX field. Unlike a digit-only
    /// filter, this rejects decimal points instead of turning `1.5` into `15`.
    static func normalizedWholeUGXInput(_ raw: String) -> String? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return "" }

        var digits = ""
        for character in cleaned {
            if let value = character.wholeNumberValue, (0 ... 9).contains(value) {
                guard digits.count < 30 else { return nil }
                digits.append(Character(String(value)))
            } else if character == "," || character == "٬" || character.isWhitespace {
                continue
            } else {
                return nil
            }
        }
        return digits
    }

    static func amountsMatch(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = decimal(lhs), let right = decimal(rhs) else { return false }
        return left == right
    }

    static func quoteReconciles(_ quote: ProviderQuoteDTO) -> Bool {
        guard let amount = decimal(quote.amount), amount > 0,
              let fee = decimal(quote.fee), fee >= 0,
              let total = decimal(quote.total), total > 0
        else { return false }
        return amount + fee == total
    }

    static func isWithinProductRange(_ amount: String, product: ProviderProductDTO) -> Bool {
        guard let value = decimal(amount) else { return false }
        if let minimum = product.minimumAmount.flatMap(decimal), value < minimum { return false }
        if let maximum = product.maximumAmount.flatMap(decimal), value > maximum { return false }
        return true
    }

    private static func decimal(_ value: String) -> Decimal? {
        Decimal(string: value, locale: Locale(identifier: "en_US_POSIX"))
    }
}

enum CustomerFacingPaymentCopy {
    static let transactionFeeTitle = "Transaction fee"

    private static let protectedFeeMessage =
        "We couldn't complete this request. Review the transaction fee and total before continuing."

    private static let protectedAmountMessage =
        "We couldn't process this amount. Review it and try again."

    private static let protectedAccountingMessage =
        "We couldn't complete this request. Please try again or contact support with the reference."

    static let confirmedMobileMoneyCollectionFailure =
        "The mobile-money network could not complete this collection. No money was added to your wallet. Check your balance and approval prompt before trying again. If your balance changed, do not retry—contact support with the reference."

    static func neutralizedServiceMessage(_ message: String) -> String {
        let providerNeutralMessage = message.replacingOccurrences(
            of: #"\bruka(?:[\s_-]*pay(?:ments?)?)?(?:[\s,]+uganda)?(?:[\s,]+(?:limited|ltd)\.?)?(?![\p{L}\p{N}_])"#,
            with: "Kit Pay's payment service",
            options: [.regularExpression, .caseInsensitive]
        )

        // Server diagnostics may contain the internal components used to reconcile a
        // single customer-facing transaction fee. Never expose that split in an alert,
        // operation failure, or receipt even if a backend message contains it.
        let internalFeeBreakdown = #"(?:(?:provider(?:['’]s)?|platform|service|kit(?:[\s_-]*pay)?(?:['’]s)?)[\s\S]{0,120}(?:fees?|charges?|surcharges?|commissions?|markups?|settlement|fee[\s_-]*(?:cap|allowance))|(?:fees?|charges?|surcharges?|commissions?|markups?)[\s\S]{0,120}(?:provider(?:['’]s)?|platform|service|kit(?:[\s_-]*pay)?(?:['’]s)?)|(?:fee|charge)[\s_-]*(?:split|breakdown))"#
        guard providerNeutralMessage.range(
            of: internalFeeBreakdown,
            options: [.regularExpression, .caseInsensitive]
        ) == nil else {
            return protectedFeeMessage
        }

        // Internal diagnostics do not always include the word "fee". Treat institutional
        // accounting vocabulary as confidential even when it appears as a standalone ledger,
        // settlement-wallet, margin, revenue, reconciliation, rounding, or float detail.
        let accountingScanMessage = providerNeutralMessage.replacingOccurrences(
            of: #"[_-]+"#,
            with: " ",
            options: .regularExpression
        )
        let internalAccountingDetail = #"\b(?:institutional|commission|revenue|ledger|margin|reconciliation|accounting|journal|allocation|posting|processing\s*costs?|settlement\s*(?:wallet|account|ledger|posting|entry|batch|fee|cost)|rounding\s*(?:adjustment|delta)|float\s*(?:wallet|account|funding|balance)|provider\s*(?:fee|cost|float))\b"#
        guard accountingScanMessage.range(
            of: internalAccountingDetail,
            options: [.regularExpression, .caseInsensitive]
        ) == nil else {
            return protectedAccountingMessage
        }

        // Whole-unit settlement is an internal rail constraint. Inputs are normalized before a
        // request is created, and neither live nor historical backend diagnostics should expose
        // that implementation detail to a customer.
        let internalAmountConstraint = #"(?:\bwhole[\s_-]*(?:shillings?|ugx|numbers?|units?|currency[\s_-]*units?|amounts?)\b|\b(?:amounts?|values?|ugx|currency|shillings?)\b[\s\S]{0,80}\b(?:integers?(?:[\s_-]*only)?|only[\s_-]*integers?|no[\s_-]*decimals?|without[\s_-]*(?:decimals?|fractions?|cents?)|decimals?(?:[\s_-]*places?)?[\s\S]{0,24}(?:not[\s_-]*(?:allowed|accepted|supported)|unsupported|invalid)|fractional(?:[\s_-]*(?:amounts?|values?))?[\s\S]{0,24}(?:not[\s_-]*(?:allowed|accepted|supported)|unsupported|invalid)|cents?[\s\S]{0,24}(?:not[\s_-]*(?:allowed|accepted|supported)|unsupported|invalid))|\b(?:integers?(?:[\s_-]*only)?|only[\s_-]*integers?|no[\s_-]*decimals?|without[\s_-]*(?:decimals?|fractions?|cents?)|decimals?(?:[\s_-]*places?)?[\s\S]{0,24}(?:not[\s_-]*(?:allowed|accepted|supported)|unsupported|invalid)|fractional(?:[\s_-]*(?:amounts?|values?))?|cents?[\s\S]{0,24}(?:not[\s_-]*(?:allowed|accepted|supported)|unsupported|invalid))\b[\s\S]{0,80}\b(?:amounts?|values?|ugx|currency|shillings?)\b)"#
        guard providerNeutralMessage.range(
            of: internalAmountConstraint,
            options: [.regularExpression, .caseInsensitive]
        ) == nil else {
            return protectedAmountMessage
        }

        return providerNeutralMessage
    }

    /// These codes represent a conclusive network rejection, not an unknown or pending outcome.
    /// Keep this allowlist narrow so the app never encourages a retry while settlement is unclear.
    static func confirmedMobileMoneyCollectionFailureMessage(for code: String) -> String? {
        let normalizedCode = code
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(
                of: #"[\s-]+"#,
                with: "_",
                options: .regularExpression
            )
        guard [
            "BANK_PROVIDER_FAILED",
            "MOBILE_MONEY_PROVIDER_FAILED",
            "MOBILE_MONEY_NETWORK_FAILED",
            "MOBILE_MONEY_COLLECTION_PROVIDER_FAILED",
            "MOBILE_MONEY_COLLECTION_NETWORK_FAILED",
        ].contains(normalizedCode) else { return nil }
        return confirmedMobileMoneyCollectionFailure
    }
}

extension ProviderProductDTO {
    var requiresWholeUGXRukaPayAmount: Bool {
        provider.code.caseInsensitiveCompare("rukapay") == .orderedSame
            && currency.code.caseInsensitiveCompare("UGX") == .orderedSame
            && [ProviderService.bill.rawValue, ProviderService.airtime.rawValue]
                .contains(serviceType.lowercased())
    }

    var accountHint: String {
        guard serviceType == ProviderService.bill.rawValue else { return "Phone number" }
        switch category.code.lowercased() {
        case "electricity", "power", "utilities": return "Meter or account number"
        case "television", "tv": return "Decoder or smartcard number"
        case "water": return "Customer account number"
        default: return "Account number"
        }
    }
}

extension CapabilitiesDTO {
    func enablesProviderService(_ service: ProviderService) -> Bool {
        let enabled = features?.compactMapValues { $0 }
        guard enabled?["wallets"] == true else { return false }
        switch service {
        case .bill: return enabled?["bills"] == true
        case .airtime: return enabled?["airtime"] == true
        }
    }
}
