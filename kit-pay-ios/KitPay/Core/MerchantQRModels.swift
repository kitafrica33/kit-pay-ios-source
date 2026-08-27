import Foundation

enum MerchantAccountOnboardingPolicy {
    static func businessWallets(in wallets: [Wallet]) -> [Wallet] {
        wallets.filter { isEligibleBusinessWallet($0) }
    }

    static func selectedBusinessWallet(id: String, from wallets: [Wallet]) -> Wallet? {
        guard !id.isEmpty else { return nil }
        return businessWallets(in: wallets).first { $0.id == id }
    }

    static func initialBusinessWalletID(
        in wallets: [Wallet],
        preferredWalletID: String?
    ) -> String {
        let eligible = businessWallets(in: wallets)
        if let preferredWalletID,
           eligible.contains(where: { $0.id == preferredWalletID }) {
            return preferredWalletID
        }
        return eligible.count == 1 ? eligible[0].id : ""
    }

    static func merchantAccounts(
        _ accounts: [MerchantAccountDTO],
        linkedTo wallet: Wallet?
    ) -> [MerchantAccountDTO] {
        guard let wallet else { return [] }
        return accounts.filter { $0.settlementWalletId == wallet.id }
    }

    static func isEligibleBusinessWallet(_ wallet: Wallet) -> Bool {
        wallet.accountType?.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("business") == .orderedSame
            && wallet.status.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("active") == .orderedSame
    }
}

struct MerchantAccountListDTO: Decodable {
    let items: [MerchantAccountDTO]?
}

struct MerchantAccountDTO: Decodable, Hashable, Identifiable {
    let id: String
    let publicId: String
    let displayName: String
    let legalName: String?
    let countryCode: String
    let settlementWalletId: String
    let status: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, status
        case publicId = "public_id"
        case displayName = "display_name"
        case legalName = "legal_name"
        case countryCode = "country_code"
        case settlementWalletId = "settlement_wallet_id"
        case createdAt = "created_at"
    }
}

struct MerchantSummaryDTO: Decodable, Hashable {
    let id: String
    let publicId: String
    let displayName: String

    enum CodingKeys: String, CodingKey {
        case id
        case publicId = "public_id"
        case displayName = "display_name"
    }
}

struct MerchantQRCodeDTO: Decodable, Hashable, Identifiable {
    let id: String
    let type: String
    let kind: String
    let status: String
    let payload: String?
    let merchant: MerchantSummaryDTO
    let merchantPaymentIntentId: String?
    let amount: String?
    let currency: CurrencyDTO?
    let expiresAt: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, type, kind, status, payload, merchant, amount, currency
        case merchantPaymentIntentId = "merchant_payment_intent_id"
        case expiresAt = "expires_at"
        case createdAt = "created_at"
    }

    var isDynamic: Bool { kind.caseInsensitiveCompare("dynamic") == .orderedSame }
    var isPayable: Bool { status.caseInsensitiveCompare("active") == .orderedSame }
}

struct MerchantPaymentIntentDTO: Decodable, Hashable, Identifiable {
    let id: String
    let type: String
    let merchant: MerchantSummaryDTO
    let status: String
    let settlementMode: String
    let settlementWalletId: String
    let sourceWalletId: String?
    let amount: String
    let currency: CurrencyDTO
    let walletTransactionId: String?
    let expiresAt: String
    let capturedAt: String?
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, type, merchant, status, amount, currency
        case settlementMode = "settlement_mode"
        case settlementWalletId = "settlement_wallet_id"
        case sourceWalletId = "source_wallet_id"
        case walletTransactionId = "wallet_transaction_id"
        case expiresAt = "expires_at"
        case capturedAt = "captured_at"
        case createdAt = "created_at"
    }
}

struct CreateMerchantAccountRequest: Encodable {
    let settlementWalletId: String
    let displayName: String
    let legalName: String?
    let countryCode: String

    enum CodingKeys: String, CodingKey {
        case settlementWalletId = "settlement_wallet_id"
        case displayName = "display_name"
        case legalName = "legal_name"
        case countryCode = "country_code"
    }
}

struct CreateMerchantPaymentIntentRequest: Encodable {
    let amount: String
    let settlementMode: String
    let note: String?

    enum CodingKeys: String, CodingKey {
        case amount, note
        case settlementMode = "settlement_mode"
    }
}

struct CreateMerchantQRRequest: Encodable {
    let kind: String
    let merchantPaymentIntentId: String?
    let expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case merchantPaymentIntentId = "merchant_payment_intent_id"
        case expiresAt = "expires_at"
    }
}

struct ResolveMerchantQRRequest: Encodable {
    let payload: String
}

struct PayMerchantQRRequest: Encodable {
    let payload: String
    let sourceWalletId: String
    let amount: String?

    enum CodingKeys: String, CodingKey {
        case payload, amount
        case sourceWalletId = "source_wallet_id"
    }
}

enum MerchantQRMoney {
    static func apiAmount(_ raw: String, scale: Int) -> String? {
        let safeScale = min(max(scale, 0), 9)
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
        let pieces = cleaned.split(separator: ".", omittingEmptySubsequences: false)
        guard !cleaned.isEmpty, pieces.count <= 2 else { return nil }
        let wholeRaw = String(pieces.first ?? "")
        let fractionRaw = pieces.count == 2 ? String(pieces[1]) : ""
        guard !wholeRaw.isEmpty,
              wholeRaw.allSatisfy(\.isNumber),
              fractionRaw.allSatisfy(\.isNumber),
              fractionRaw.count <= safeScale
        else { return nil }

        let whole = String(wholeRaw.drop(while: { $0 == "0" })).isEmpty
            ? "0"
            : String(wholeRaw.drop(while: { $0 == "0" }))
        let fraction = fractionRaw + String(repeating: "0", count: safeScale - fractionRaw.count)
        let amount = safeScale == 0 ? whole : "\(whole).\(fraction)"
        guard let value = Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX")),
              value > 0
        else { return nil }
        return amount
    }
}

extension CapabilitiesDTO {
    var enablesMerchantQRPayments: Bool {
        let enabled = features?.compactMapValues { $0 }
        return enabled?["wallets"] == true
            && enabled?["merchant_payments"] == true
            && enabled?["qr_payments"] == true
    }
}
