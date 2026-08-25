import Foundation

/// Puts a face on a saved beneficiary when that beneficiary is someone the sender already knows
/// on Kit Pay.
///
/// A beneficiary is a bank or mobile-money destination, so the server never sends a Kit Pay user
/// id with it — only a bank-verified account name and a masked account number. Matching therefore
/// happens entirely on this device, against the contact directory this iPhone already synced, and
/// it fails closed: an ambiguous match shows the ordinary bank or handset glyph rather than
/// guessing a face. Showing the wrong person's photo above an account number would be worse than
/// showing no photo at all.
struct BeneficiaryContactIndex: Equatable, Sendable {
    /// Registered Kit Pay contacts keyed by their full normalized name.
    private var byFullName: [String: [WalletContactDTO]] = [:]
    /// The same contacts keyed by first and last name only, so a bank's "JOHN K MUKASA" can still
    /// find "John Mukasa" in the address book.
    private var byOuterName: [String: [WalletContactDTO]] = [:]
    /// Keyed by the trailing digits a mask leaves visible.
    private var byPhoneSuffix: [String: [WalletContactDTO]] = [:]

    /// How many trailing digits of a phone number the buckets are keyed on. The narrowest mask the
    /// backend produces leaves the last three visible.
    private static let suffixLength = 3

    init(contacts: [WalletContactDTO] = [], context: PhoneIdentityContext = .uganda) {
        for contact in contacts {
            // Only an addressable Kit Pay account has a photo to show. An address-book row that is
            // not on Kit Pay must keep looking like what it is.
            guard ContactRecipientDirectory.recipientUserId(for: contact) != nil else { continue }

            let tokens = BeneficiaryNameMatching.tokens(contact.name)
            if let key = BeneficiaryNameMatching.fullKey(tokens) {
                byFullName[key, default: []].append(contact)
            }
            if let key = BeneficiaryNameMatching.outerKey(tokens) {
                byOuterName[key, default: []].append(contact)
            }

            if let phone = PhoneIdentityNormalizer.normalizedE164(contact.phone, context: context) {
                let digits = phone.filter(\.isNumber)
                if digits.count >= Self.suffixLength {
                    byPhoneSuffix[String(digits.suffix(Self.suffixLength)), default: []]
                        .append(contact)
                }
            }
        }
    }

    var isEmpty: Bool {
        byFullName.isEmpty && byOuterName.isEmpty && byPhoneSuffix.isEmpty
    }

    /// A bank beneficiary carries no phone number at all, so the bank-verified account name is the
    /// only signal. It has to be a complete name — a single word like "Mum" is not evidence — and
    /// it has to point at exactly one Kit Pay contact.
    func contact(forAccountName accountName: String) -> WalletContactDTO? {
        let tokens = BeneficiaryNameMatching.tokens(accountName)
        guard tokens.count >= 2 else { return nil }

        if let key = BeneficiaryNameMatching.fullKey(tokens),
           let match = unique(byFullName[key]) {
            return match
        }
        guard let key = BeneficiaryNameMatching.outerKey(tokens) else { return nil }
        return unique(byOuterName[key])
    }

    /// A mobile-money beneficiary is a phone number, which is what a contact is, so the masked
    /// number is the anchor. Everything but the last few digits is hidden, so a suffix alone can
    /// easily collide in a large address book: the account name breaks the tie, and no tie-break
    /// means no photo.
    func contact(forMaskedPhone maskedPhone: String, accountName: String?) -> WalletContactDTO? {
        let visible = BeneficiaryNameMatching.visibleSuffix(
            of: maskedPhone,
            length: Self.suffixLength
        )
        guard let visible else { return nil }
        let candidates = byPhoneSuffix[visible] ?? []
        if let match = unique(candidates) { return match }
        guard !candidates.isEmpty, let accountName else { return nil }

        let tokens = BeneficiaryNameMatching.tokens(accountName)
        guard !tokens.isEmpty else { return nil }
        let named = candidates.filter {
            BeneficiaryNameMatching.namesAgree(tokens, BeneficiaryNameMatching.tokens($0.name))
        }
        return unique(named)
    }

    /// Distinct people only. The directory can legitimately hold the same Kit Pay account twice
    /// (one address-book card per SIM), and that is still one face.
    private func unique(_ candidates: [WalletContactDTO]?) -> WalletContactDTO? {
        guard let candidates, !candidates.isEmpty else { return nil }
        var seen: Set<String> = []
        for candidate in candidates {
            guard let id = ContactRecipientDirectory.recipientUserId(for: candidate) else { continue }
            seen.insert(id)
            if seen.count > 1 { return nil }
        }
        guard seen.count == 1 else { return nil }
        return candidates.first { ContactRecipientDirectory.recipientUserId(for: $0) != nil }
    }
}

/// The name and mask arithmetic behind `BeneficiaryContactIndex`, kept separate so it can be
/// reasoned about — and tested — without building a directory.
enum BeneficiaryNameMatching {
    /// Titles a bank prints but nobody saves in their phone.
    private static let honorifics: Set<String> = ["mr", "mrs", "ms", "miss", "dr", "prof", "rev"]

    /// Lowercased, unaccented words of at least two letters. Initials are dropped rather than
    /// matched: "J" agreeing with "James" would let two different people share a face.
    static func tokens(_ value: String) -> [String] {
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        return folded
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 2 && !honorifics.contains($0) }
    }

    /// Order-insensitive: banks print "MUKASA JOHN" where the address book says "John Mukasa".
    static func fullKey(_ tokens: [String]) -> String? {
        guard tokens.count >= 2 else { return nil }
        return tokens.sorted().joined(separator: " ")
    }

    /// First and last name only, so an extra middle name on one side is not a mismatch.
    static func outerKey(_ tokens: [String]) -> String? {
        guard let first = tokens.first, let last = tokens.last, tokens.count >= 2 else { return nil }
        return [first, last].sorted().joined(separator: " ")
    }

    /// Used only to break a tie between numbers that already share their visible digits, so one
    /// shared name is enough — the phone did the identifying.
    static func namesAgree(_ lhs: [String], _ rhs: [String]) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        return !Set(lhs).isDisjoint(with: Set(rhs))
    }

    /// The trailing digits a mask such as `••••••8200` leaves in the clear. Returns nil when the
    /// mask shows fewer digits than asked for, because a shorter suffix would match too many
    /// people to be evidence of anything.
    static func visibleSuffix(of maskedPhone: String, length: Int) -> String? {
        var suffix = ""
        for character in maskedPhone.reversed() {
            guard character.isNumber else { break }
            suffix.append(character)
            if suffix.count == length { break }
        }
        guard suffix.count == length else { return nil }
        return String(suffix.reversed())
    }
}
