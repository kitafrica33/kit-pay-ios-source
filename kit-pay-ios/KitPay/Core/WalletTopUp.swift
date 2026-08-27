import Foundation

/// What a payment is short by, and what it would take to cover it.
///
/// The wallet balance is already on the device, so a payment that cannot succeed is knowable
/// before anything is sent. Saying "you are short UGX 4,200, top up UGX 5,000" is the whole point:
/// a bare "insufficient funds" leaves the customer to do that subtraction themselves, usually
/// twice, because the first guess is rarely enough once the transaction fee is counted.
struct WalletTopUpRequirement: Equatable, Identifiable, Sendable {
    let walletID: String
    let currencyCode: String
    let scale: Int
    /// Everything that has to leave the wallet, transaction fee included.
    let required: Decimal
    let available: Decimal
    /// What is missing, to the currency's own precision.
    let shortfall: Decimal
    /// The shortfall rounded up to the next whole unit — nobody tops up UGX 4,213.
    let suggestedTopUp: Decimal

    var id: String { "\(walletID)-\(requiredAPIAmount)" }

    var requiredAPIAmount: String {
        WalletTopUpPolicy.apiAmount(required, scale: scale)
    }

    var shortfallAPIAmount: String {
        WalletTopUpPolicy.apiAmount(shortfall, scale: scale)
    }

    var suggestedTopUpAPIAmount: String {
        WalletTopUpPolicy.apiAmount(suggestedTopUp, scale: scale)
    }

    var displayShortfall: String {
        KitMoney.formatted(shortfallAPIAmount, code: currencyCode, scale: scale, trimZeroFraction: true)
    }

    var displaySuggestedTopUp: String {
        KitMoney.formatted(
            suggestedTopUpAPIAmount,
            code: currencyCode,
            scale: scale,
            trimZeroFraction: true
        )
    }

    var displayRequired: String {
        KitMoney.formatted(requiredAPIAmount, code: currencyCode, scale: scale, trimZeroFraction: true)
    }

    var displayAvailable: String {
        KitMoney.formatted(
            WalletTopUpPolicy.apiAmount(available, scale: scale),
            code: currencyCode,
            scale: scale,
            trimZeroFraction: true
        )
    }

    /// The sentence shown where the payment was blocked.
    var summary: String {
        "Your balance is \(displayShortfall) less than this payment needs."
    }

    /// True once a top-up has landed and the original payment can be approved.
    func isCovered(by wallet: Wallet?) -> Bool {
        guard let wallet, wallet.id == walletID else { return false }
        guard let available = WalletTopUpPolicy.decimal(wallet.balances.available) else {
            return false
        }
        return available >= required
    }
}

enum WalletTopUpPolicy {
    /// The requirement for a payment, or nil when the wallet already covers it.
    ///
    /// `debitAPIAmount` is the full wallet debit — for the rails that charge one, that is the
    /// quote's customer debit rather than the amount typed, because a payment that clears the
    /// amount but not the fee fails just the same.
    static func requirement(
        wallet: Wallet?,
        debitAPIAmount: String?
    ) -> WalletTopUpRequirement? {
        guard let wallet,
              let debitAPIAmount,
              let required = decimal(debitAPIAmount),
              required > 0
        else { return nil }
        let available = decimal(wallet.balances.available) ?? 0
        guard required > available else { return nil }

        let shortfall = required - available
        return WalletTopUpRequirement(
            walletID: wallet.id,
            currencyCode: wallet.currency.code,
            scale: wallet.currency.decimalScale,
            required: required,
            available: available,
            shortfall: shortfall,
            suggestedTopUp: roundedUpWholeUnit(shortfall)
        )
    }

    /// At least one whole unit, and never less than the shortfall itself.
    static func roundedUpWholeUnit(_ value: Decimal) -> Decimal {
        guard value > 0 else { return 0 }
        var input = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, 0, .up)
        return max(rounded, 1)
    }

    static func decimal(_ raw: String?) -> Decimal? {
        guard let raw else { return nil }
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
        guard !cleaned.isEmpty else { return nil }
        return Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// A canonical amount string at the currency's scale, which is what every money endpoint and
    /// every amount field in the app expects.
    static func apiAmount(_ value: Decimal, scale: Int) -> String {
        let scale = min(max(scale, 0), 9)
        var input = max(value, 0)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, scale, .plain)
        var formatted = NSDecimalNumber(decimal: rounded).stringValue
        guard scale > 0 else {
            return formatted.split(separator: ".").first.map(String.init) ?? formatted
        }
        if !formatted.contains(".") { formatted += "." }
        let pieces = formatted.split(separator: ".", omittingEmptySubsequences: false)
        let whole = String(pieces.first ?? "0")
        let fraction = pieces.count > 1 ? String(pieces[1]) : ""
        let padded = fraction.count >= scale
            ? String(fraction.prefix(scale))
            : fraction + String(repeating: "0", count: scale - fraction.count)
        return "\(whole).\(padded)"
    }

    /// The server's own verdict, for the case where the balance on the device was stale — a
    /// payment authorized a second before an unrelated debit posted, say. The customer is told the
    /// same thing either way.
    static func isInsufficientFunds(_ error: Error) -> Bool {
        guard let payload = error as? APIErrorPayload else { return false }
        return payload.code == "INSUFFICIENT_FUNDS"
    }
}
