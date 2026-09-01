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

struct BankFundingAccountListDTO: Decodable {
    let items: [BankFundingAccountDTO]?
}

struct BankFundingAccountBankDTO: Decodable, Hashable, Identifiable {
    let id: String
    let name: String
    let code: String
    let countryCode: String

    enum CodingKeys: String, CodingKey {
        case id, name, code
        case countryCode = "country_code"
    }
}

/// A Kit Pay receiving account, not one of the customer's saved beneficiaries.
///
/// Keeping this model separate is deliberate: deposits credit the selected Kit Pay wallet and
/// therefore never ask for, infer, or persist a beneficiary.
struct BankFundingAccountDTO: Decodable, Hashable, Identifiable {
    let id: String
    let label: String
    let bank: BankFundingAccountBankDTO
    let accountName: String
    let accountNumber: String
    let accountNumberMasked: String
    let branchName: String?
    let branchCode: String?
    let swiftCode: String?
    let instructions: String?
    let currency: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case id, label, bank, currency, status, instructions
        case accountName = "account_name"
        case accountNumber = "account_number"
        case accountNumberMasked = "account_number_masked"
        case branchName = "branch_name"
        case branchCode = "branch_code"
        case swiftCode = "swift_code"
    }

    var isActive: Bool {
        status.caseInsensitiveCompare("active") == .orderedSame
            && !accountNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct BankDepositRequestListDTO: Decodable {
    let items: [BankDepositRequestDTO]?
}

struct BankDepositProofDTO: Decodable, Hashable {
    let assetId: String
    let filename: String
    let status: String
    let scanStatus: String
    let mimeType: String?
    let byteSize: Int?

    enum CodingKeys: String, CodingKey {
        case filename, status
        case assetId = "asset_id"
        case scanStatus = "scan_status"
        case mimeType = "mime_type"
        case byteSize = "byte_size"
    }
}

struct BankDepositRejectionDTO: Decodable, Hashable {
    let code: String
    let reason: String?
}

struct BankDepositRequestDTO: Decodable, Hashable, Identifiable {
    let id: String
    let reference: String
    let walletId: String
    let amount: String
    let currency: CurrencyDTO
    let status: String
    let source: String
    let fundingAccount: BankFundingAccountDTO
    let proof: BankDepositProofDTO?
    let bankTransactionReference: String?
    let customerNote: String?
    let rejection: BankDepositRejectionDTO?
    let expiresAt: String
    let createdAt: String?
    let proofSubmittedAt: String?
    let completedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, reference, amount, currency, status, source, proof, rejection
        case walletId = "wallet_id"
        case fundingAccount = "funding_account"
        case bankTransactionReference = "bank_transaction_reference"
        case customerNote = "customer_note"
        case expiresAt = "expires_at"
        case createdAt = "created_at"
        case proofSubmittedAt = "proof_submitted_at"
        case completedAt = "completed_at"
    }

    var acceptsProof: Bool {
        ["awaiting_proof", "proof_submitted"].contains(status.lowercased())
            && ISO8601DateFormatter().date(from: expiresAt).map { $0 > Date() } == true
    }

    var isTerminal: Bool {
        ["approved", "completed", "rejected", "expired", "cancelled", "canceled"]
            .contains(status.lowercased())
    }

    var isSuccessful: Bool {
        ["approved", "completed"].contains(status.lowercased())
    }

    func hasSameBinding(
        wallet: Wallet,
        fundingAccount: BankFundingAccountDTO,
        submittedAmount: String
    ) -> Bool {
        walletId == wallet.id
            && fundingAccount.id == self.fundingAccount.id
            && currency.code.caseInsensitiveCompare(wallet.currency.code) == .orderedSame
            && currency.scale == wallet.currency.scale
            && BankTransferMoney.amountsMatch(amount, submittedAmount)
            && BankDepositReferencePolicy.isValid(reference)
    }
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
    var totalFees: String? = nil
    var pricingScope: String? = nil
    let customerDebit: String
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
        case totalFees = "total_fees"
        case pricingScope = "pricing_scope"
        case customerDebit = "customer_debit"
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
        CustomerPricingContract.accepts(scope: pricingScope, authoritativeTotal: totalFees)
            && CustomerPricingContract.totalsMatch(totalFees, legacy: processingFee)
            && BankTransferMoney.customerOutboundAmountsReconcile(
            feeMode: feeMode,
            recipientAmount: recipientAmount,
            totalFees: totalFees ?? processingFee,
            customerDebit: customerDebit
        )
    }

    var hasValidStepUpBinding: Bool {
        guard stepUp.purpose == BankTransferContract.purpose else { return false }

        let expected = [
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
            "customer_debit": customerDebit,
            "currency": currency.code,
        ]
        let legacyCompatibilityKeys: Set<String> = [
            "provider_fee", "kit_fee", "provider_fee_cap", "maximum_provider_total",
            "kit_debit", "schedule_version",
        ]
        let allowedKeys = Set(expected.keys).union(legacyCompatibilityKeys)
        return Set(stepUp.intent.keys).isSubset(of: allowedKeys)
            && expected.allSatisfy { stepUp.intent[$0.key] == $0.value }
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

/// `banking/beneficiaries` is served from the shared banking beneficiary store, which also
/// holds mobile-money destinations: the backend models each mobile-money network as a bank
/// record (mobile-money verifications and operations both carry a `bank_id`). Beneficiary
/// rows carry no explicit rail field, so the bank surface keys off the strongest signals it
/// has: only mobile-money networks advertise `collections`/`payouts` capabilities or use an
/// MTN/AIRTEL code, and only transfer banks advertise `transfers`. Rows mixing both rails'
/// signals are ambiguous and are excluded here (fail closed).
enum BankBeneficiaryRailPolicy {
    private static let mobileMoneyNetworkCodes: Set<String> = ["MTN", "AIRTEL"]

    static func isBankRailDestination(_ bank: BankDTO) -> Bool {
        guard bank.canTransfer,
              bank.capabilities?["collections"] != true,
              bank.capabilities?["payouts"] != true
        else { return false }
        return !mobileMoneyNetworkCodes.contains(
            bank.code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        )
    }

    static func bankRailBanks(_ banks: [BankDTO]) -> [BankDTO] {
        banks.filter(isBankRailDestination)
    }

    static func bankRailBeneficiaries(
        _ beneficiaries: [BankBeneficiaryDTO]
    ) -> [BankBeneficiaryDTO] {
        beneficiaries.filter { isBankRailDestination($0.bank) }
    }
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

    /// The only outbound pricing shape that is safe to present to a customer.
    ///
    /// The operation must advertise the public `customer_totals` contract and reconcile its
    /// principal with that aggregate. Legacy, institutional, and malformed shapes fail closed
    /// instead of reaching a customer history row or receipt.
    var customerOutboundPricing: BankTransferOutboundPricingDTO? {
        guard let outboundPricing,
              outboundPricing.pricingScope == CustomerPricingContract.scope,
              outboundPricing.totalFees != nil,
              outboundPricing.hasConsistentAmounts,
              BankTransferMoney.amountsMatch(amount, outboundPricing.recipientAmount)
        else { return nil }
        return outboundPricing
    }

    /// Complete amount removed from the customer's wallet for this operation.
    ///
    /// Returning nil prevents the UI from substituting the recipient principal for an unverified
    /// total wallet debit.
    var customerAmountDeducted: String? {
        customerOutboundPricing?.customerDebit
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

/// Fail-closed boundary for the bank-transfer-specific activity surface.
///
/// A principal-only legacy operation cannot prove the complete wallet debit and is therefore not
/// a customer transaction until the authoritative aggregate pricing contract is available.
enum BankTransferOperationPresentationPolicy {
    static func isCustomerVisible(_ operation: BankingOperationDTO) -> Bool {
        operation.type.caseInsensitiveCompare(BankTransferContract.operationType) == .orderedSame
            && operation.direction.caseInsensitiveCompare("outbound") == .orderedSame
            && operation.customerAmountDeducted != nil
    }

    static func customerVisibleOperations(
        _ operations: [BankingOperationDTO]
    ) -> [BankingOperationDTO] {
        operations.filter(isCustomerVisible)
    }
}

struct BankTransferOutboundPricingDTO: Decodable, Hashable {
    let feeMode: BankTransferFeeMode
    let recipientAmount: String
    let processingFee: String
    var totalFees: String? = nil
    var pricingScope: String? = nil
    let customerDebit: String

    enum CodingKeys: String, CodingKey {
        case feeMode = "fee_mode"
        case recipientAmount = "recipient_amount"
        case processingFee = "processing_fee"
        case totalFees = "total_fees"
        case pricingScope = "pricing_scope"
        case customerDebit = "customer_debit"
    }

    var hasConsistentAmounts: Bool {
        CustomerPricingContract.accepts(scope: pricingScope, authoritativeTotal: totalFees)
            && CustomerPricingContract.totalsMatch(totalFees, legacy: processingFee)
            && BankTransferMoney.customerOutboundAmountsReconcile(
            feeMode: feeMode,
            recipientAmount: recipientAmount,
            totalFees: totalFees ?? processingFee,
            customerDebit: customerDebit
        )
    }

    func matches(_ quote: BankTransferQuoteDTO) -> Bool {
        feeMode == quote.feeMode
            && BankTransferMoney.amountsMatch(recipientAmount, quote.recipientAmount)
            && BankTransferMoney.amountsMatch(processingFee, quote.processingFee)
            && BankTransferMoney.amountsMatch(
                totalFees ?? processingFee,
                quote.totalFees ?? quote.processingFee
            )
            && BankTransferMoney.amountsMatch(customerDebit, quote.customerDebit)
            && hasConsistentAmounts
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

struct CreateBankDepositRequest: Encodable {
    let walletId: String
    let fundingAccountId: String
    let amount: String
    let note: String?

    enum CodingKeys: String, CodingKey {
        case amount, note
        case walletId = "wallet_id"
        case fundingAccountId = "funding_account_id"
    }
}

struct AttachBankDepositProofRequest: Encodable {
    let mediaAssetId: String

    enum CodingKeys: String, CodingKey {
        case mediaAssetId = "media_asset_id"
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

    /// Reconciles only amounts that belong in a customer's payment approval contract.
    /// Provider cost, Kit margin, settlement caps, and institutional contributions are not
    /// required by the mobile client and remain private to the server-side ledger.
    static func customerOutboundAmountsReconcile(
        feeMode: BankTransferFeeMode,
        recipientAmount: String,
        totalFees: String,
        customerDebit: String
    ) -> Bool {
        let locale = Locale(identifier: "en_US_POSIX")
        guard let recipient = Decimal(string: recipientAmount, locale: locale), recipient > 0,
              let fee = Decimal(string: totalFees, locale: locale), fee >= 0,
              let customer = Decimal(string: customerDebit, locale: locale), customer > 0
        else { return false }

        switch feeMode {
        case .senderAbsorbs, .beneficiaryAbsorbs:
            return customer == recipient + fee
        case .kitCovers:
            return customer == recipient
        }
    }

}

enum BankDepositMoney {
    static func apiAmount(_ raw: String, scale: Int) -> String? {
        guard (0 ... 9).contains(scale) else { return nil }
        let compact = raw.filter { !$0.isWhitespace && $0 != "," }
        let pieces = compact.split(separator: ".", omittingEmptySubsequences: false)
        guard !compact.isEmpty,
              pieces.count <= 2,
              pieces.allSatisfy({ part in
                  part.allSatisfy { $0.isASCII && $0.isNumber }
              }),
              let integerPart = pieces.first,
              !integerPart.isEmpty
        else { return nil }

        let fraction = pieces.count == 2 ? String(pieces[1]) : ""
        guard fraction.count <= scale else { return nil }
        let integer = String(integerPart.drop(while: { $0 == "0" }))
        let canonicalInteger = integer.isEmpty ? "0" : integer
        let canonicalFraction = String(fraction.reversed().drop(while: { $0 == "0" }).reversed())
        let canonical = canonicalFraction.isEmpty
            ? canonicalInteger
            : "\(canonicalInteger).\(canonicalFraction)"
        guard Decimal(string: canonical, locale: Locale(identifier: "en_US_POSIX")).map({ $0 > 0 }) == true
        else { return nil }
        return canonical
    }
}

enum BankDepositReferencePolicy {
    static func isValid(_ value: String) -> Bool {
        let groups = value.split(separator: "-", omittingEmptySubsequences: false)
        guard value == value.uppercased(),
              groups.count == 4,
              groups.allSatisfy({ $0.count == 4 }),
              groups.joined().allSatisfy({ character in
                  character.isASCII && (character.isLetter || character.isNumber)
              })
        else { return false }
        let characters = groups.joined()
        return characters.contains(where: \.isLetter)
            && characters.contains(where: \.isNumber)
    }
}

struct BankDepositInstructionField: Equatable, Identifiable {
    let label: String
    let value: String
    let monospaced: Bool

    var id: String { label }
}

/// One canonical representation of the bank coordinates shown on screen, copied to another app,
/// and exported to PDF. Keeping these surfaces together prevents a stale or masked account number
/// from reaching one of them while the others display the authoritative value.
enum BankDepositInstructions {
    static let exportActionTitle = "Export PDF"

    static func accountFields(for deposit: BankDepositRequestDTO) -> [BankDepositInstructionField] {
        let account = deposit.fundingAccount
        var fields = [
            BankDepositInstructionField(label: "Bank", value: account.bank.name, monospaced: false),
            BankDepositInstructionField(label: "Account name", value: account.accountName, monospaced: false),
            BankDepositInstructionField(label: "Account number", value: account.accountNumber, monospaced: true),
        ]
        append("Branch", account.branchName, monospaced: false, to: &fields)
        append("Branch code", account.branchCode, monospaced: true, to: &fields)
        append("SWIFT", account.swiftCode, monospaced: true, to: &fields)
        return fields
    }

    static func receivingFields(for deposit: BankDepositRequestDTO) -> [BankDepositInstructionField] {
        var fields = accountFields(for: deposit)
        fields.append(
            BankDepositInstructionField(
                label: "Payment reference",
                value: deposit.reference,
                monospaced: true
            )
        )
        fields.append(
            BankDepositInstructionField(
                label: "Exact amount",
                value: KitMoney.formatted(
                    deposit.amount,
                    currency: deposit.currency,
                    trimZeroFraction: true
                ),
                monospaced: false
            )
        )
        return fields
    }

    static func clipboardText(for deposit: BankDepositRequestDTO) -> String {
        receivingFields(for: deposit)
            .map { "\($0.label): \($0.value)" }
            .joined(separator: "\n")
    }

    private static func append(
        _ label: String,
        _ rawValue: String?,
        monospaced: Bool,
        to fields: inout [BankDepositInstructionField]
    ) {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return }
        fields.append(
            BankDepositInstructionField(label: label, value: value, monospaced: monospaced)
        )
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

    var enablesBankDeposits: Bool {
        let enabled = features?.compactMapValues { $0 }
        return enabled?["wallets"] == true && enabled?["bank_deposits"] == true
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
