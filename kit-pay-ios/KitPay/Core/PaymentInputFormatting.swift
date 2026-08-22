import Foundation

enum UgandaMobileMoneyPhone {
    static let countryCode = "256"
    static let nationalDigitCount = 9

    static func nationalDigits(from raw: String) -> String {
        String(unboundedNationalDigits(from: raw).prefix(nationalDigitCount))
    }

    static func spacedNationalDigits(from raw: String) -> String {
        let digits = nationalDigits(from: raw)
        return stride(from: 0, to: digits.count, by: 3).map { start in
            let lower = digits.index(digits.startIndex, offsetBy: start)
            let upper = digits.index(lower, offsetBy: min(3, digits.count - start))
            return String(digits[lower..<upper])
        }.joined(separator: " ")
    }

    static func apiValue(from raw: String) -> String? {
        let national = unboundedNationalDigits(from: raw)
        guard national.count == nationalDigitCount, national.first == "7" else { return nil }
        return countryCode + national
    }

    static func e164Value(from raw: String) -> String? {
        apiValue(from: raw).map { "+" + $0 }
    }

    static func internationalDisplayValue(from raw: String) -> String {
        let national = spacedNationalDigits(from: raw)
        return national.isEmpty ? "+\(countryCode)" : "+\(countryCode) \(national)"
    }

    private static func unboundedNationalDigits(from raw: String) -> String {
        var digits = asciiDigits(from: raw)
        if digits.hasPrefix("00") {
            digits.removeFirst(2)
        }
        if digits.hasPrefix(countryCode) {
            digits.removeFirst(countryCode.count)
        }
        if digits.hasPrefix("0") {
            digits.removeFirst()
        }
        return digits
    }
}

enum PaymentInputFormatting {
    /// The characters a customer's keyboard and locale actually put in an amount field.
    ///
    /// `UIKeyboardType.decimalPad` draws the *locale's* decimal separator, so a customer whose
    /// region uses a comma types `1,50`. Parsing used to recognise only `.` and silently discard
    /// everything else, which turned `1,50` into `150` — a hundredfold overpayment entered
    /// without a single warning. Display and parsing now share one definition of the separators
    /// so a value always round-trips through the field it was typed into.
    struct Separators: Equatable {
        let decimal: Character
        let grouping: Character
        /// Everything accepted as a decimal point on input. The locale's own separator always
        /// counts; `.` also counts unless this locale spends it on grouping, where accepting it
        /// would misread `1.234` as one-point-two-three-four.
        let acceptedDecimals: Set<Character>

        init(locale: Locale = .current) {
            let localeDecimal = Self.singleCharacter(locale.decimalSeparator) ?? "."
            let localeGrouping = Self.singleCharacter(locale.groupingSeparator) ?? ","
            // A locale that reports the same character for both is unusable; fall back to the
            // arithmetic convention rather than producing values that cannot be parsed back.
            if localeDecimal == localeGrouping {
                decimal = "."
                grouping = ","
                acceptedDecimals = ["."]
                return
            }
            decimal = localeDecimal
            grouping = localeGrouping
            var accepted: Set<Character> = [localeDecimal]
            if localeGrouping != "." { accepted.insert(".") }
            acceptedDecimals = accepted
        }

        private static func singleCharacter(_ value: String?) -> Character? {
            guard let value, value.count == 1 else { return nil }
            return Character(value)
        }
    }

    static func normalizedWholeInput(_ raw: String, maximumDigits: Int = 30) -> String {
        String(asciiDigits(from: raw).prefix(maximumDigits))
    }

    static func groupedWholeInput(_ raw: String, locale: Locale = .current) -> String {
        groupedInteger(normalizedWholeInput(raw), separators: Separators(locale: locale))
    }

    /// Turns what the customer typed into the canonical `.`-separated amount the API expects.
    static func normalizedDecimalInput(
        _ raw: String,
        maximumFractionDigits: Int,
        maximumWholeDigits: Int = 30,
        locale: Locale = .current
    ) -> String {
        let separators = Separators(locale: locale)
        let scale = min(max(maximumFractionDigits, 0), 9)
        var whole = ""
        var fraction = ""
        var sawSeparator = false
        for character in raw {
            if separators.acceptedDecimals.contains(character) {
                sawSeparator = true
            } else if let digit = asciiDigit(from: character) {
                if sawSeparator {
                    if fraction.count < scale { fraction.append(digit) }
                } else if whole.count < maximumWholeDigits {
                    whole.append(digit)
                }
            }
        }
        if whole.isEmpty, sawSeparator { whole = "0" }
        return whole + (sawSeparator && scale > 0 ? "." + fraction : "")
    }

    /// Renders a canonical `.`-separated amount for display, in this locale's separators.
    ///
    /// The input is always canonical — state the app itself holds, or a value the backend sent —
    /// so it is read with `.` regardless of locale. Only the output is localized.
    static func groupedDecimalInput(
        _ canonical: String,
        maximumFractionDigits: Int,
        locale: Locale = .current
    ) -> String {
        let separators = Separators(locale: locale)
        let normalized = canonicalDecimal(
            canonical,
            maximumFractionDigits: maximumFractionDigits
        )
        guard let separatorIndex = normalized.firstIndex(of: ".") else {
            return groupedInteger(normalized, separators: separators)
        }
        let whole = String(normalized[..<separatorIndex])
        let fraction = String(normalized[normalized.index(after: separatorIndex)...])
        return groupedInteger(whole, separators: separators)
            + String(separators.decimal)
            + fraction
    }

    /// Drops an all-zero fraction from an already-grouped display value, using this locale's
    /// separator rather than assuming `.00`.
    static func trimmingZeroFraction(
        _ grouped: String,
        maximumFractionDigits: Int,
        locale: Locale = .current
    ) -> String {
        let scale = min(max(maximumFractionDigits, 0), 9)
        guard scale > 0 else { return grouped }
        let zeroFraction = String(Separators(locale: locale).decimal)
            + String(repeating: "0", count: scale)
        guard grouped.hasSuffix(zeroFraction) else { return grouped }
        return String(grouped.dropLast(zeroFraction.count))
    }

    /// Reads a canonical amount: ASCII (or ASCII-equivalent) digits with `.` as the only
    /// separator.
    private static func canonicalDecimal(
        _ raw: String,
        maximumFractionDigits: Int,
        maximumWholeDigits: Int = 30
    ) -> String {
        let scale = min(max(maximumFractionDigits, 0), 9)
        var whole = ""
        var fraction = ""
        var sawSeparator = false
        for character in raw {
            if character == "." {
                sawSeparator = true
            } else if let digit = asciiDigit(from: character) {
                if sawSeparator {
                    if fraction.count < scale { fraction.append(digit) }
                } else if whole.count < maximumWholeDigits {
                    whole.append(digit)
                }
            }
        }
        if whole.isEmpty, sawSeparator { whole = "0" }
        return whole + (sawSeparator && scale > 0 ? "." + fraction : "")
    }

    private static func groupedInteger(_ digits: String, separators: Separators) -> String {
        guard digits.count > 3 else { return digits }
        var result = ""
        for (offset, character) in digits.reversed().enumerated() {
            if offset > 0, offset.isMultiple(of: 3) { result.append(separators.grouping) }
            result.append(character)
        }
        return String(result.reversed())
    }
}

private func asciiDigits(from raw: String) -> String {
    String(raw.compactMap { asciiDigit(from: $0) })
}

private func asciiDigit(from character: Character) -> Character? {
    guard let value = character.wholeNumberValue, (0 ... 9).contains(value) else { return nil }
    return Character(String(value))
}
