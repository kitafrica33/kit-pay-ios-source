import Foundation
import SwiftUI
import UIKit

enum PaymentAmountInputMode: Equatable, Sendable {
    case whole
    case decimal(maximumFractionDigits: Int)
}

struct PaymentAmountEdit: Equatable, Sendable {
    /// Preserves transient intent such as `1.` and `1.0` so the next keystroke can produce `1.05`.
    let editingCanonicalValue: String
    /// Stable value for business logic and API parsing; redundant fractional zeroes are removed.
    let committedCanonicalValue: String
    let displayedValue: String
    /// UIKit selections are UTF-16 offsets, so keep the policy in the same coordinate space.
    let caretUTF16Offset: Int
}

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

    static func editingDisplayedInput(
        _ canonical: String,
        mode: PaymentAmountInputMode
    ) -> String {
        switch mode {
        case .whole:
            return groupedWholeInput(canonical, locale: fixedDisplayLocale)
        case .decimal(let maximumFractionDigits):
            return groupedDecimalInput(
                canonical,
                maximumFractionDigits: maximumFractionDigits,
                locale: fixedDisplayLocale
            )
        }
    }

    static func committedCanonicalInput(
        _ canonical: String,
        mode: PaymentAmountInputMode
    ) -> String {
        switch mode {
        case .whole:
            return normalizedWholeInput(canonical)
        case .decimal(let maximumFractionDigits):
            let normalized = canonicalDecimal(
                canonical,
                maximumFractionDigits: maximumFractionDigits
            )
            guard let separatorIndex = normalized.firstIndex(of: ".") else {
                return normalized
            }
            let whole = String(normalized[..<separatorIndex])
            let fraction = String(normalized[normalized.index(after: separatorIndex)...])
                .reversed()
                .drop(while: { $0 == "0" })
                .reversed()
            return fraction.isEmpty ? whole : whole + "." + String(fraction)
        }
    }

    static func committedDisplayedInput(
        _ canonical: String,
        mode: PaymentAmountInputMode
    ) -> String {
        editingDisplayedInput(committedCanonicalInput(canonical, mode: mode), mode: mode)
    }

    /// Applies one native text-field edit while keeping the stored value canonical and the
    /// selection attached to the same logical digit. Reformatting through a computed SwiftUI
    /// binding moves the insertion point to the end after every comma insertion; keeping the
    /// operation here makes insertion, replacement, paste and separator deletion deterministic.
    static func applyingEdit(
        to displayedValue: String,
        range: NSRange,
        replacement: String,
        currentSelection: NSRange? = nil,
        mode: PaymentAmountInputMode,
        locale: Locale = .current
    ) -> PaymentAmountEdit? {
        let source = displayedValue as NSString
        guard range.location <= source.length,
              range.length <= source.length - range.location
        else { return nil }

        let inputSeparators = Separators(locale: locale)
        let displaySeparators = Separators(locale: fixedDisplayLocale)
        let editRange = adjustedGroupingDeletionRange(
            in: source,
            requestedRange: range,
            replacement: replacement,
            currentSelection: currentSelection,
            separators: displaySeparators
        )
        // Multi-character replacements are paste/IME commits, not an in-progress keystroke.
        // Normalize those immediately so a pasted `1,768.80` never sits in the field with a
        // redundant zero. A single typed zero remains transient (`1.0`) so the next keystroke
        // can still form `1.05`.
        let commitsReplacement = replacement.utf16.count > 1
        guard let replacement = editingReplacement(
            replacement,
            mode: mode,
            inputSeparators: inputSeparators,
            locale: locale
        ) else { return nil }
        let candidate = source.replacingCharacters(in: editRange, with: replacement)
        guard let canonical = canonicalEditingInput(
            candidate,
            mode: mode,
            separators: displaySeparators,
            locale: fixedDisplayLocale
        ) else { return nil }

        let rawCaret = min(
            editRange.location + replacement.utf16.count,
            (candidate as NSString).length
        )
        let prefix = (candidate as NSString).substring(to: rawCaret)
        guard let canonicalPrefix = canonicalEditingInput(
            prefix,
            mode: mode,
            separators: displaySeparators,
            locale: fixedDisplayLocale
        ) else { return nil }

        let committed = committedCanonicalInput(canonical, mode: mode)
        let editingCanonical = commitsReplacement ? committed : canonical
        let displayed = editingDisplayedInput(editingCanonical, mode: mode)
        let caretCanonicalPrefix = commitsReplacement
            ? committedCanonicalInput(canonicalPrefix, mode: mode)
            : canonicalPrefix
        return PaymentAmountEdit(
            editingCanonicalValue: editingCanonical,
            committedCanonicalValue: committed,
            displayedValue: displayed,
            caretUTF16Offset: displayedCaretOffset(
                semanticOffset: caretCanonicalPrefix.utf16.count,
                in: displayed,
                mode: mode,
                separators: displaySeparators
            )
        )
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

    /// Drops every redundant fractional zero from an already-grouped committed value. Editing
    /// uses `editingDisplayedInput` instead so a transient `1.0` can still become `1.05`.
    static func trimmingZeroFraction(
        _ grouped: String,
        maximumFractionDigits: Int,
        locale: Locale = .current
    ) -> String {
        let scale = min(max(maximumFractionDigits, 0), 9)
        guard scale > 0 else { return grouped }
        let separator = Separators(locale: locale).decimal
        guard let separatorIndex = grouped.lastIndex(of: separator) else { return grouped }
        let whole = grouped[..<separatorIndex]
        let fraction = grouped[grouped.index(after: separatorIndex)...]
        let trimmed = fraction.reversed().drop(while: { $0 == "0" }).reversed()
        return trimmed.isEmpty
            ? String(whole)
            : String(whole) + String(separator) + String(trimmed)
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

    private static let fixedDisplayLocale = Locale(identifier: "en_US_POSIX")

    private static func editingReplacement(
        _ replacement: String,
        mode: PaymentAmountInputMode,
        inputSeparators: Separators,
        locale: Locale
    ) -> String? {
        guard replacement.utf16.count > 1 else {
            if case .decimal = mode,
               replacement.first == inputSeparators.decimal,
               inputSeparators.decimal != "." {
                return "."
            }
            return replacement
        }

        switch mode {
        case .whole:
            return canonicalPastedWholeInput(
                replacement,
                separators: inputSeparators
            )
        case .decimal(let maximumFractionDigits):
            return canonicalPastedDecimalInput(
                replacement,
                maximumFractionDigits: maximumFractionDigits,
                locale: locale
            )
        }
    }

    private static func canonicalPastedWholeInput(
        _ raw: String,
        separators: Separators
    ) -> String? {
        var digits = ""
        for character in raw {
            if let digit = asciiDigit(from: character) {
                if digits.count < 30 { digits.append(digit) }
            } else if character == separators.grouping
                || character == ","
                || character == "\u{066C}"
                || character.isWhitespace {
                continue
            } else {
                // Never reinterpret a pasted decimal as a larger whole-unit amount.
                return nil
            }
        }
        return digits
    }

    private static func canonicalPastedDecimalInput(
        _ raw: String,
        maximumFractionDigits: Int,
        locale: Locale
    ) -> String {
        let separators = Separators(locale: locale)
        let dotIndex = raw.lastIndex(of: ".")
        let commaIndex = raw.lastIndex(of: ",")
        let decimalCharacter: Character?
        if let dotIndex, let commaIndex {
            decimalCharacter = dotIndex > commaIndex ? "." : ","
        } else if raw.filter({ $0 == separators.decimal }).count == 1 {
            decimalCharacter = separators.decimal
        } else if let dotIndex, separators.grouping != "." {
            decimalCharacter = dotIndex < raw.endIndex ? "." : nil
        } else if let commaIndex,
                  separators.grouping != ",",
                  raw.distance(from: raw.index(after: commaIndex), to: raw.endIndex)
                    <= max(maximumFractionDigits, 0) {
            decimalCharacter = ","
        } else {
            decimalCharacter = nil
        }

        let scale = min(max(maximumFractionDigits, 0), 9)
        var whole = ""
        var fraction = ""
        var sawDecimal = false
        for character in raw {
            if character == decimalCharacter, !sawDecimal {
                sawDecimal = true
            } else if let digit = asciiDigit(from: character) {
                if sawDecimal {
                    if fraction.count < scale { fraction.append(digit) }
                } else if whole.count < 30 {
                    whole.append(digit)
                }
            }
        }
        if whole.isEmpty, sawDecimal { whole = "0" }
        return whole + (sawDecimal && scale > 0 ? "." + fraction : "")
    }

    private static func canonicalEditingInput(
        _ raw: String,
        mode: PaymentAmountInputMode,
        separators: Separators,
        locale: Locale
    ) -> String? {
        switch mode {
        case .whole:
            var digits = ""
            for character in raw {
                if let digit = asciiDigit(from: character) {
                    if digits.count < 30 { digits.append(digit) }
                    continue
                }
                if character == separators.grouping
                    || character == "\u{066C}"
                    || character.isWhitespace {
                    continue
                }
                // A whole-unit rail must reject a decimal edit instead of silently turning
                // `1.5` into `15`. Reject other pasted content for the same fail-closed reason.
                return nil
            }
            return digits
        case .decimal(let maximumFractionDigits):
            return normalizedDecimalInput(
                raw,
                maximumFractionDigits: maximumFractionDigits,
                locale: locale
            )
        }
    }

    private static func adjustedGroupingDeletionRange(
        in source: NSString,
        requestedRange: NSRange,
        replacement: String,
        currentSelection: NSRange?,
        separators: Separators
    ) -> NSRange {
        guard replacement.isEmpty,
              requestedRange.length > 0,
              let currentSelection,
              currentSelection.length == 0,
              let deleted = source.substring(with: requestedRange).first,
              source.substring(with: requestedRange).count == 1,
              deleted == separators.grouping
        else { return requestedRange }

        if currentSelection.location == NSMaxRange(requestedRange),
           requestedRange.location > 0 {
            let previous = source.rangeOfComposedCharacterSequence(
                at: requestedRange.location - 1
            )
            if source.substring(with: previous).first.flatMap(asciiDigit(from:)) != nil {
                return NSRange(
                    location: previous.location,
                    length: NSMaxRange(requestedRange) - previous.location
                )
            }
        }

        if currentSelection.location == requestedRange.location,
           NSMaxRange(requestedRange) < source.length {
            let next = source.rangeOfComposedCharacterSequence(at: NSMaxRange(requestedRange))
            if source.substring(with: next).first.flatMap(asciiDigit(from:)) != nil {
                return NSRange(
                    location: requestedRange.location,
                    length: NSMaxRange(next) - requestedRange.location
                )
            }
        }
        return requestedRange
    }

    private static func displayedCaretOffset(
        semanticOffset: Int,
        in displayed: String,
        mode: PaymentAmountInputMode,
        separators: Separators
    ) -> Int {
        guard semanticOffset > 0 else { return 0 }
        var consumed = 0
        var utf16Offset = 0
        for character in displayed {
            utf16Offset += String(character).utf16.count
            let isDecimal: Bool
            switch mode {
            case .whole: isDecimal = false
            case .decimal: isDecimal = character == separators.decimal
            }
            if asciiDigit(from: character) != nil || isDecimal {
                consumed += 1
                if consumed >= semanticOffset { return utf16Offset }
            }
        }
        return displayed.utf16.count
    }
}

enum KitAmountFieldTextStyle {
    case hero
    case large
    case title
    case monospacedTitle
    case body
    case monospacedBody

    fileprivate var font: UIFont {
        switch self {
        case .hero:
            return Self.scaledSystemFont(size: 44, weight: .bold, design: .rounded, style: .largeTitle)
        case .large:
            return Self.scaledSystemFont(size: 32, weight: .bold, design: .rounded, style: .title1)
        case .title:
            return Self.scaledSystemFont(size: 28, weight: .bold, design: .rounded, style: .title1)
        case .monospacedTitle:
            return UIFontMetrics(forTextStyle: .title1).scaledFont(
                for: .monospacedDigitSystemFont(ofSize: 28, weight: .bold)
            )
        case .body:
            return UIFont.preferredFont(forTextStyle: .body)
        case .monospacedBody:
            return UIFontMetrics(forTextStyle: .body).scaledFont(
                for: .monospacedDigitSystemFont(ofSize: 17, weight: .regular)
            )
        }
    }

    private static func scaledSystemFont(
        size: CGFloat,
        weight: UIFont.Weight,
        design: UIFontDescriptor.SystemDesign,
        style: UIFont.TextStyle
    ) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        let descriptor = base.fontDescriptor.withDesign(design) ?? base.fontDescriptor
        return UIFontMetrics(forTextStyle: style).scaledFont(
            for: UIFont(descriptor: descriptor, size: size)
        )
    }
}

/// A native one-line field is used deliberately: UIKit exposes the UTF-16 replacement range and
/// current selection, which lets the formatter keep the caret next to the edited digit while
/// grouping separators appear. The bound value never contains grouping or localized decimals.
@MainActor
struct KitAmountTextField: UIViewRepresentable {
    @Binding private var value: String
    private let placeholder: String
    private let mode: PaymentAmountInputMode
    private let textStyle: KitAmountFieldTextStyle
    private let textAlignment: NSTextAlignment

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.locale) private var locale

    init(
        _ placeholder: String,
        value: Binding<String>,
        mode: PaymentAmountInputMode,
        textStyle: KitAmountFieldTextStyle = .body,
        textAlignment: NSTextAlignment = .natural
    ) {
        self.placeholder = placeholder
        _value = value
        self.mode = mode
        self.textStyle = textStyle
        self.textAlignment = textAlignment
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField(frame: .zero)
        field.delegate = context.coordinator
        field.borderStyle = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartDashesType = .no
        field.smartQuotesType = .no
        field.smartInsertDeleteType = .no
        field.adjustsFontForContentSizeCategory = true
        field.adjustsFontSizeToFitWidth = true
        field.minimumFontSize = 13
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        configure(field)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        configure(field)
        if field.isFirstResponder,
           context.coordinator.lastPublishedCanonical == value,
           context.coordinator.editingCanonicalValue != nil {
            return
        }
        context.coordinator.editingCanonicalValue = nil
        context.coordinator.lastPublishedCanonical = value
        let displayed = PaymentInputFormatting.committedDisplayedInput(value, mode: mode)
        guard field.text != displayed else { return }
        field.text = displayed
        if field.isFirstResponder {
            context.coordinator.setCaret(displayed.utf16.count, in: field)
        }
    }

    private func configure(_ field: UITextField) {
        let keyboardType: UIKeyboardType = switch mode {
        case .whole: .numberPad
        case .decimal: .decimalPad
        }
        if field.keyboardType != keyboardType {
            field.keyboardType = keyboardType
            if field.isFirstResponder { field.reloadInputViews() }
        }
        field.placeholder = placeholder
        field.font = textStyle.font
        field.textAlignment = textAlignment
        field.isEnabled = isEnabled
        field.accessibilityLabel = placeholder
    }

    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: KitAmountTextField
        fileprivate var editingCanonicalValue: String?
        fileprivate var lastPublishedCanonical: String?

        init(parent: KitAmountTextField) {
            self.parent = parent
        }

        func textField(
            _ textField: UITextField,
            shouldChangeCharactersIn range: NSRange,
            replacementString string: String
        ) -> Bool {
            let displayed = textField.text ?? ""
            guard let edit = PaymentInputFormatting.applyingEdit(
                to: displayed,
                range: range,
                replacement: string,
                currentSelection: selection(in: textField),
                mode: parent.mode,
                locale: parent.locale
            ) else { return false }

            textField.text = edit.displayedValue
            editingCanonicalValue = edit.editingCanonicalValue
            lastPublishedCanonical = edit.committedCanonicalValue
            if parent.value != edit.committedCanonicalValue {
                parent.value = edit.committedCanonicalValue
            }
            setCaret(edit.caretUTF16Offset, in: textField)
            return false
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            let committed = PaymentInputFormatting.committedCanonicalInput(
                parent.value,
                mode: parent.mode
            )
            editingCanonicalValue = committed
            lastPublishedCanonical = committed
            if parent.value != committed { parent.value = committed }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            let committed = PaymentInputFormatting.committedCanonicalInput(
                editingCanonicalValue ?? parent.value,
                mode: parent.mode
            )
            editingCanonicalValue = nil
            lastPublishedCanonical = committed
            if parent.value != committed { parent.value = committed }
            textField.text = PaymentInputFormatting.committedDisplayedInput(
                committed,
                mode: parent.mode
            )
        }

        fileprivate func setCaret(_ utf16Offset: Int, in textField: UITextField) {
            let bounded = min(max(utf16Offset, 0), (textField.text ?? "").utf16.count)
            guard let position = textField.position(
                from: textField.beginningOfDocument,
                offset: bounded
            ) else { return }
            textField.selectedTextRange = textField.textRange(from: position, to: position)
        }

        private func selection(in textField: UITextField) -> NSRange? {
            guard let selection = textField.selectedTextRange else { return nil }
            let start = textField.offset(
                from: textField.beginningOfDocument,
                to: selection.start
            )
            let end = textField.offset(
                from: textField.beginningOfDocument,
                to: selection.end
            )
            return NSRange(location: start, length: end - start)
        }
    }
}

extension CurrencyDTO {
    var decimalScale: Int { Int(scale) ?? 2 }
}

/// The one place the app turns an amount into something a customer reads.
///
/// Amounts arrive as canonical `.`-separated strings (or minor units) and were previously
/// interpolated straight into text, so a balance of `1250000` rendered as `UGX 1250000` — a
/// seven-digit run nobody can read at a glance, and one that is easy to misread by a factor of
/// ten. Every display surface now goes through here, so the ledger row, the review sheet, the
/// approval prompt and the receipt cannot disagree about what an amount looks like.
///
/// Customer-facing money uses the product contract's unambiguous comma grouping and `.` decimal
/// mark. Input still accepts the keyboard locale's decimal separator before canonicalizing it.
enum KitMoney {
    /// The digits alone, grouped: `1,250,000` / `1,250,000.75`.
    ///
    /// Settled values never force `.00`, and `1,250.80` is rendered as `1,250.8`. The opt-out is
    /// retained only for transient editing; customer-facing call sites use the default.
    static func amount(
        _ raw: String,
        scale: Int = 2,
        trimZeroFraction: Bool = true,
        locale: Locale = .current
    ) -> String {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = cleaned.isEmpty ? "0" : cleaned
        let mode = PaymentAmountInputMode.decimal(maximumFractionDigits: scale)
        if trimZeroFraction {
            return PaymentInputFormatting.committedDisplayedInput(source, mode: mode)
        }
        return PaymentInputFormatting.editingDisplayedInput(source, mode: mode)
    }

    /// `UGX 1,250,000` — the code and the grouped amount, separated by a space.
    static func formatted(
        _ raw: String,
        code: String,
        scale: Int = 2,
        trimZeroFraction: Bool = true,
        locale: Locale = .current
    ) -> String {
        let value = amount(raw, scale: scale, trimZeroFraction: trimZeroFraction, locale: locale)
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        return code.isEmpty ? value : "\(code) \(value)"
    }

    static func formatted(
        _ raw: String,
        currency: CurrencyDTO,
        trimZeroFraction: Bool = true,
        locale: Locale = .current
    ) -> String {
        formatted(
            raw,
            code: currency.code,
            scale: currency.decimalScale,
            trimZeroFraction: trimZeroFraction,
            locale: locale
        )
    }

    /// A ledger row's amount, with the direction carried by the sign rather than by colour alone.
    ///
    /// The minus is U+2212, not a hyphen, so it matches the digit width in a monospaced column.
    static func signed(
        _ raw: String,
        currency: CurrencyDTO,
        direction: String,
        locale: Locale = .current
    ) -> String {
        let sign = switch direction.lowercased() {
        case "credit": "+"
        case "debit": "\u{2212}"
        default: ""
        }
        return sign + formatted(raw, currency: currency, locale: locale)
    }

    /// Renders minor units (what the wire and QR payloads carry) without going through `Double`.
    static func formatted(
        minorUnits: some BinaryInteger,
        code: String,
        scale: Int,
        locale: Locale = .current
    ) -> String {
        formatted(
            decimal(minorUnits: minorUnits, scale: scale),
            code: code,
            scale: scale,
            locale: locale
        )
    }

    /// Minor units as a canonical `.`-separated decimal string.
    ///
    /// Kept in integer arithmetic — routing money through `Double` is where rounding errors of a
    /// whole minor unit come from.
    static func decimal(minorUnits: some BinaryInteger, scale: Int) -> String {
        let scale = min(max(scale, 0), 9)
        let sign = minorUnits < 0 ? "-" : ""
        var digits = String(minorUnits.magnitude)
        guard scale > 0 else { return sign + digits }
        if digits.count <= scale {
            digits = String(repeating: "0", count: scale - digits.count + 1) + digits
        }
        let separator = digits.index(digits.endIndex, offsetBy: -scale)
        let whole = String(digits[..<separator])
        let fraction = String(digits[separator...])
        return sign + whole + "." + fraction
    }
}

private func asciiDigits(from raw: String) -> String {
    String(raw.compactMap { asciiDigit(from: $0) })
}

private func asciiDigit(from character: Character) -> Character? {
    guard let value = character.wholeNumberValue, (0 ... 9).contains(value) else { return nil }
    return Character(String(value))
}
