import CryptoKit
import Foundation

/// The only address-book fields sent to Kit. Device identifiers, labels, email
/// addresses, postal addresses, notes, and images never enter the sync payload.
struct ContactSyncEntry: Encodable, Equatable, Sendable {
    let name: String
    let phone: String
    let favorite: Bool
}

struct SyncContactsRequest: Encodable, Equatable, Sendable {
    let contacts: [ContactSyncEntry]
}

struct DeviceContactPhone: Equatable, Sendable {
    let name: String
    let phone: String

    init(name: String, phone: String) {
        self.name = name
        self.phone = phone
    }
}

struct ContactSyncSnapshot: Equatable, Sendable {
    /// The chunked backend protocol accepts a device snapshot of up to 50,000
    /// normalized phone identities without truncating large address books.
    static let serverLimit = 50_000

    let contacts: [ContactSyncEntry]
    let omittedCount: Int

    /// A deterministic, non-reversible marker stored inside the encrypted app
    /// state. It lets foreground/background checks avoid re-uploading an
    /// unchanged 10,000+ entry address book.
    var fingerprint: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = (try? encoder.encode(contacts)) ?? Data()
        return SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }
}

/// The regional context used when a contact stores a national number without
/// an international prefix. Kit's server currently defaults to Uganda; when a
/// signed-in profile has an E.164 number, the app can infer its calling code.
struct PhoneIdentityContext: Equatable, Sendable {
    static let uganda = PhoneIdentityContext(countryCallingCode: "256")

    let countryCallingCode: String
    let nationalTrunkPrefix: String?

    init(countryCallingCode: String, nationalTrunkPrefix: String? = "0") {
        let digits = countryCallingCode.filter(\.isNumber)
        self.countryCallingCode = (1 ... 3).contains(digits.count) ? digits : "256"
        self.nationalTrunkPrefix = nationalTrunkPrefix?.filter(\.isNumber).nilIfEmpty
    }

    /// Uses a trusted profile number only to select a calling code. Contact
    /// data is never read or uploaded while constructing this context.
    init(
        referencePhone: String?,
        countryISOCode: String? = nil,
        fallback: PhoneIdentityContext = .uganda
    ) {
        if let referencePhone,
           let internationalDigits = PhoneIdentityNormalizer.explicitInternationalDigits(referencePhone),
           let callingCode = PhoneIdentityNormalizer.callingCode(in: internationalDigits) {
            self.init(
                countryCallingCode: callingCode,
                nationalTrunkPrefix: Self.trunkPrefix(for: callingCode)
            )
            return
        }

        if let countryISOCode,
           let callingCode = Self.callingCodesByISO[
               countryISOCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
           ] {
            self.init(
                countryCallingCode: callingCode,
                nationalTrunkPrefix: Self.trunkPrefix(for: callingCode)
            )
            return
        }

        self = fallback
    }

    fileprivate static func trunkPrefix(for callingCode: String) -> String? {
        switch callingCode {
        case "1", "39": nil
        case "7": "8"
        default: "0"
        }
    }

    /// Profile-country fallback for accounts whose phone projection is absent.
    /// The E.164 profile phone remains preferred because shared calling codes
    /// (for example +1) cannot identify a single ISO region.
    private static let callingCodesByISO: [String: String] = [
        "AE": "971", "AF": "93", "AR": "54", "AT": "43", "AU": "61",
        "BE": "32", "BG": "359", "BH": "973", "BI": "257", "BR": "55",
        "BW": "267", "CA": "1", "CD": "243", "CH": "41", "CL": "56",
        "CM": "237", "CN": "86", "CO": "57", "CY": "357", "CZ": "420",
        "DE": "49", "DJ": "253", "DK": "45", "DZ": "213", "EC": "593",
        "EE": "372", "EG": "20", "ER": "291", "ES": "34", "ET": "251",
        "FI": "358", "FR": "33", "GB": "44", "GH": "233", "GR": "30",
        "HK": "852", "HR": "385", "HU": "36", "ID": "62", "IE": "353",
        "IL": "972", "IN": "91", "IQ": "964", "IS": "354", "IT": "39",
        "JP": "81", "KE": "254", "KR": "82", "KW": "965", "KZ": "7",
        "LB": "961", "LK": "94", "LT": "370", "LU": "352", "LV": "371",
        "MA": "212", "MT": "356", "MU": "230", "MX": "52", "MY": "60",
        "MZ": "258", "NA": "264", "NG": "234", "NL": "31", "NO": "47",
        "NP": "977", "NZ": "64", "OM": "968", "PE": "51", "PH": "63",
        "PK": "92", "PL": "48", "PT": "351", "QA": "974", "RO": "40",
        "RS": "381", "RU": "7", "RW": "250", "SA": "966", "SD": "249",
        "SE": "46", "SG": "65", "SI": "386", "SK": "421", "SN": "221",
        "SO": "252", "SS": "211", "TH": "66", "TN": "216", "TR": "90",
        "TW": "886", "TZ": "255", "UA": "380", "UG": "256", "US": "1",
        "UY": "598", "VE": "58", "VN": "84", "ZA": "27", "ZM": "260",
        "ZW": "263",
    ]
}

/// A deterministic, dependency-free phone identity parser. It is deliberately
/// conservative: explicit `+`/`00` numbers are international; otherwise the
/// selected region supplies the calling code. The backend remains authoritative
/// and validates normalized values with libphonenumber.
enum PhoneIdentityNormalizer {
    static func normalizedE164(
        _ input: String,
        context: PhoneIdentityContext = .uganda
    ) -> String? {
        guard let parsed = parsedDigits(input) else { return nil }

        var body = parsed.digits
        if parsed.hasPlus {
            // Already an international number.
        } else if body.hasPrefix("00") {
            body.removeFirst(2)
        } else if body.hasPrefix("011") {
            // Common international access prefix used by NANP countries. Do
            // not reinterpret a malformed international number as a local one.
            let internationalBody = String(body.dropFirst(3))
            guard callingCode(in: internationalBody) != nil else { return nil }
            body = internationalBody
        } else {
            if body.hasPrefix(context.countryCallingCode) {
                // The country code is present but the leading plus was omitted.
            } else {
                if let trunk = context.nationalTrunkPrefix,
                   body.hasPrefix(trunk) {
                    body.removeFirst(trunk.count)
                }
                // Tolerate a trunk prefix before an explicitly written local
                // country code (for example 0 256 772 ...).
                if !body.hasPrefix(context.countryCallingCode) {
                    body = context.countryCallingCode + body
                }
            }
        }

        // People commonly store a national trunk prefix after their own
        // country code (for example +256 0772...). It is not part of E.164.
        // Limit this correction to the selected region so a foreign number's
        // national-significant prefix is never guessed.
        if let trunk = context.nationalTrunkPrefix,
           trunk == "0",
           body.hasPrefix(context.countryCallingCode + trunk) {
            body = context.countryCallingCode
                + String(body.dropFirst(context.countryCallingCode.count + trunk.count))
        }

        guard (8 ... 15).contains(body.count),
              body.first != "0",
              callingCode(in: body) != nil
        else { return nil }
        return "+" + body
    }

    fileprivate static func explicitInternationalDigits(_ input: String) -> String? {
        guard let parsed = parsedDigits(input) else { return nil }
        if parsed.hasPlus { return parsed.digits }
        if parsed.digits.hasPrefix("00") { return String(parsed.digits.dropFirst(2)) }
        if parsed.digits.hasPrefix("011") {
            return String(parsed.digits.dropFirst(3))
        }
        return nil
    }

    fileprivate static func callingCode(in digits: String) -> String? {
        for length in stride(from: min(3, digits.count), through: 1, by: -1) {
            let candidate = String(digits.prefix(length))
            if countryCallingCodes.contains(candidate) { return candidate }
        }
        return nil
    }

    private static func parsedDigits(_ input: String) -> (digits: String, hasPlus: Bool)? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.unicodeScalars.count <= 64 else { return nil }

        var digits = ""
        var hasPlus = false
        for scalar in trimmed.unicodeScalars {
            let character = Character(String(scalar))
            if CharacterSet.decimalDigits.contains(scalar),
               let value = character.wholeNumberValue,
               (0 ... 9).contains(value) {
                digits.append(String(value))
                continue
            }
            if scalar == "+", digits.isEmpty, !hasPlus {
                hasPlus = true
                continue
            }
            if CharacterSet.whitespacesAndNewlines.contains(scalar)
                || "().-/".unicodeScalars.contains(scalar) {
                continue
            }
            // Reject service codes, extensions, letters, and ambiguous syntax
            // rather than accidentally treating their digits as phone identity.
            return nil
        }
        guard !digits.isEmpty else { return nil }
        return (digits, hasPlus)
    }

    /// ITU country calling codes used only to recognize an international
    /// prefix; national numbering-plan validity is intentionally server-owned.
    private static let countryCallingCodes = Set("""
    1 7 20 27 30 31 32 33 34 36 39 40 41 43 44 45 46 47 48 49
    51 52 53 54 55 56 57 58 60 61 62 63 64 65 66 81 82 84 86
    90 91 92 93 94 95 98 211 212 213 216 218 220 221 222 223
    224 225 226 227 228 229 230 231 232 233 234 235 236 237
    238 239 240 241 242 243 244 245 246 247 248 249 250 251
    252 253 254 255 256 257 258 260 261 262 263 264 265 266
    267 268 269 290 291 297 298 299 350 351 352 353 354 355
    356 357 358 359 370 371 372 373 374 375 376 377 378 379
    380 381 382 383 385 386 387 389 420 421 423 500 501 502
    503 504 505 506 507 508 509 590 591 592 593 594 595 596
    597 598 599 670 672 673 674 675 676 677 678 679 680 681
    682 683 685 686 687 688 689 690 691 692 850 852 853 855
    856 880 886 960 961 962 963 964 965 966 967 968 970 971
    972 973 974 975 976 977 992 993 994 995 996 998
    """.split(whereSeparator: \.isWhitespace).map(String.init))
}

struct ContactRecipientSections: Equatable, Sendable {
    let kitPay: [WalletContactDTO]
    let invitations: [WalletContactDTO]
}

/// Exact `GET /search?types[]=users` payload used for member discovery. The
/// backend can return other search result types on broader requests, so the
/// recipient mapper still rejects everything except an addressable user UUID.
struct KitUserSearchResultListDTO: Decodable, Sendable {
    let items: [KitUserSearchResultDTO]?
}

struct KitUserSearchResultDTO: Decodable, Equatable, Sendable, Identifiable {
    let type: String
    let id: String
    let title: String?
    let subtitle: String?
    let metadata: KitUserSearchMetadataDTO?
}

struct KitUserSearchMetadataDTO: Decodable, Equatable, Sendable {
    let avatarURL: String?

    enum CodingKeys: String, CodingKey {
        case avatarURL = "avatar_url"
    }
}

struct KitUserRecipientSections: Equatable, Sendable {
    /// Saved/synced Kit Pay contacts always remain ahead of directory-only users.
    let savedKitPay: [WalletContactDTO]
    let directoryKitPay: [WalletContactDTO]
    /// Invitations can only originate from the user's local contact directory.
    let invitations: [WalletContactDTO]

    var kitPay: [WalletContactDTO] { savedKitPay + directoryKitPay }
}

/// Maps authenticated member-search results into ephemeral recipients without
/// mixing server-wide discovery with the user's private, invite-only contacts.
enum KitUserDirectorySearch {
    static let resultLimit = 25

    /// Android's established contract uses `@tag`; `:tag` is accepted as an
    /// equivalent shorthand because it is already used by Kit Pay customers.
    static func remoteQuery(from rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let marker = trimmed.first, marker == "@" || marker == ":" else { return nil }
        let query = String(trimmed.dropFirst())
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2 ... 100).contains(query.count) else { return nil }
        return query
    }

    static func queryItems(query: String, limit: Int = resultLimit) -> [URLQueryItem]? {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2 ... 100).contains(value.count), (1 ... 50).contains(limit) else { return nil }
        return [
            URLQueryItem(name: "q", value: value),
            URLQueryItem(name: "types[]", value: "users"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
    }

    static func sections(
        localContacts: [WalletContactDTO],
        remoteResults: [KitUserSearchResultDTO],
        query: String,
        context: PhoneIdentityContext = .uganda,
        excludingUserID: String?
    ) -> KitUserRecipientSections {
        let local = ContactRecipientDirectory.sectionsFromOrdered(
            localContacts,
            query: query,
            context: context
        )
        guard remoteQuery(from: query) != nil else {
            return KitUserRecipientSections(
                savedKitPay: local.kitPay,
                directoryKitPay: [],
                invitations: local.invitations
            )
        }
        let savedIDs = Set(local.kitPay.compactMap {
            ContactRecipientDirectory.recipientUserId(for: $0)
        })
        return KitUserRecipientSections(
            savedKitPay: local.kitPay,
            directoryKitPay: addressableContacts(
                from: remoteResults,
                excludingUserID: excludingUserID,
                excludingRecipientIDs: savedIDs
            ),
            invitations: local.invitations
        )
    }

    static func addressableContacts(
        from results: [KitUserSearchResultDTO],
        excludingUserID: String?,
        excludingRecipientIDs: Set<String> = []
    ) -> [WalletContactDTO] {
        let ownID = canonicalUserID(excludingUserID)
        let excluded = Set(excludingRecipientIDs.compactMap { canonicalUserID($0) })
        var seen = excluded
        var contacts: [WalletContactDTO] = []
        contacts.reserveCapacity(results.count)

        for result in results {
            guard result.type.caseInsensitiveCompare("users") == .orderedSame,
                  let userID = canonicalUserID(result.id),
                  ownID.map({ userID != $0 }) ?? true,
                  seen.insert(userID).inserted
            else { continue }

            let tag = normalizedTag(result.subtitle)
            contacts.append(
                WalletContactDTO(
                    id: userID,
                    contactId: nil,
                    name: safeName(result.title, tag: tag),
                    phone: "",
                    isKitUser: true,
                    favorite: false,
                    status: nil,
                    tag: tag,
                    avatarURL: result.metadata?.avatarURL,
                    receivingWalletId: nil
                )
            )
        }
        return contacts
    }

    private static func canonicalUserID(_ rawValue: String?) -> String? {
        guard let rawValue,
              let id = UUID(
                  uuidString: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
              )
        else { return nil }
        return id.uuidString.lowercased()
    }

    private static func normalizedTag(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingTagMarkers()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return String(value.prefix(100))
    }

    private static func safeName(_ rawValue: String?, tag: String?) -> String {
        let scalars = (rawValue ?? "").unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .prefix(100)
        let name = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        return tag.map { "@\($0)" } ?? "Kit Pay member"
    }
}

/// Shared ordering and matching for message, call, and wallet recipient
/// pickers. Canonical phones are deduplicated before Kit users are placed ahead
/// of contacts who need an invitation.
enum ContactRecipientDirectory {
    /// Returns the canonical public user identifier only for an addressable
    /// Kit Pay account. Address-book row identifiers are deliberately never
    /// accepted as messaging or calling recipients.
    static func recipientUserId(for contact: WalletContactDTO) -> String? {
        guard contact.isKitUser == true,
              let id = UUID(uuidString: contact.id.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return id.uuidString.lowercased()
    }

    static func ordered(
        _ contacts: [WalletContactDTO],
        context: PhoneIdentityContext = .uganda
    ) -> [WalletContactDTO] {
        var byIdentity: [String: WalletContactDTO] = [:]

        for contact in contacts {
            let identity = identityKey(for: contact, context: context)
            if let current = byIdentity[identity] {
                byIdentity[identity] = merged(current, contact, context: context)
            } else {
                byIdentity[identity] = contact
            }
        }

        return byIdentity.values.sorted { lhs, rhs in
            let lhsKit = recipientUserId(for: lhs) != nil
            let rhsKit = recipientUserId(for: rhs) != nil
            if lhsKit != rhsKit { return lhsKit && !rhsKit }

            let lhsFavorite = lhs.favorite == true
            let rhsFavorite = rhs.favorite == true
            if lhsFavorite != rhsFavorite { return lhsFavorite && !rhsFavorite }

            let lhsName = searchKey(lhs.name)
            let rhsName = searchKey(rhs.name)
            if lhsName != rhsName { return lhsName < rhsName }

            let lhsPhone = PhoneIdentityNormalizer.normalizedE164(lhs.phone, context: context) ?? lhs.phone
            let rhsPhone = PhoneIdentityNormalizer.normalizedE164(rhs.phone, context: context) ?? rhs.phone
            if lhsPhone != rhsPhone { return lhsPhone < rhsPhone }
            return lhs.id < rhs.id
        }
    }

    /// The server may retain a union learned from several devices when using
    /// non-destructive partial sync. Each iPhone should display only contacts
    /// visible in its own currently authorized address-book snapshot.
    static func restrictedToSnapshot(
        _ contacts: [WalletContactDTO],
        entries: [ContactSyncEntry],
        context: PhoneIdentityContext = .uganda
    ) -> [WalletContactDTO] {
        let visiblePhones = Set(entries.map(\.phone))
        var visible: [WalletContactDTO] = []
        visible.reserveCapacity(min(contacts.count, entries.count))
        for contact in contacts {
            if Task.isCancelled { break }
            guard let phone = PhoneIdentityNormalizer.normalizedE164(
                contact.phone,
                context: context
            ) else { continue }
            if visiblePhones.contains(phone) { visible.append(contact) }
        }
        return visible
    }

    static func sections(
        _ contacts: [WalletContactDTO],
        query: String = "",
        context: PhoneIdentityContext = .uganda
    ) -> ContactRecipientSections {
        let visible = ordered(contacts, context: context).filter {
            matches($0, query: query, context: context)
        }
        return ContactRecipientSections(
            kitPay: visible.filter { recipientUserId(for: $0) != nil },
            invitations: visible.filter { recipientUserId(for: $0) == nil }
        )
    }

    /// Fast path for the encrypted directory, which is already normalized and
    /// sorted when sync completes. This avoids re-sorting 10,000+ contacts on
    /// every search keystroke.
    static func sectionsFromOrdered(
        _ contacts: [WalletContactDTO],
        query: String = "",
        context: PhoneIdentityContext = .uganda
    ) -> ContactRecipientSections {
        let visible = contacts.filter { matches($0, query: query, context: context) }
        return ContactRecipientSections(
            kitPay: visible.filter { recipientUserId(for: $0) != nil },
            invitations: visible.filter { recipientUserId(for: $0) == nil }
        )
    }

    static func matches(
        _ contact: WalletContactDTO,
        query: String,
        context: PhoneIdentityContext = .uganda
    ) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        let key = searchKey(trimmed)
        let tagQuery = key.trimmingTagMarkers()
        let tagMatches = !tagQuery.isEmpty && contact.tag.map {
            searchKey($0).trimmingTagMarkers().contains(tagQuery)
        } == true
        if searchKey(contact.name).contains(key)
            || tagMatches
            || searchKey(contact.phone).contains(key) {
            return true
        }

        let queryDigits = trimmed.compactMap(\.wholeNumberValue).map(String.init).joined()
        if !queryDigits.isEmpty,
           phoneSearchAliases(for: contact.phone, context: context).contains(where: {
               $0.contains(queryDigits)
           }) {
            return true
        }

        guard let queryPhone = PhoneIdentityNormalizer.normalizedE164(trimmed, context: context),
              let contactPhone = PhoneIdentityNormalizer.normalizedE164(contact.phone, context: context)
        else { return false }
        return queryPhone == contactPhone
    }

    private static func phoneSearchAliases(
        for phone: String,
        context: PhoneIdentityContext
    ) -> [String] {
        let rawDigits = phone.compactMap(\.wholeNumberValue).map(String.init).joined()
        guard let canonical = PhoneIdentityNormalizer.normalizedE164(phone, context: context) else {
            return rawDigits.isEmpty ? [] : [rawDigits]
        }

        let internationalDigits = String(canonical.dropFirst())
        var aliases = [rawDigits, internationalDigits]
        if internationalDigits.hasPrefix(context.countryCallingCode) {
            let national = String(internationalDigits.dropFirst(context.countryCallingCode.count))
            aliases.append(national)
            if let trunk = context.nationalTrunkPrefix {
                aliases.append(trunk + national)
            }
        }
        return aliases.filter { !$0.isEmpty }
    }

    private static func identityKey(
        for contact: WalletContactDTO,
        context: PhoneIdentityContext
    ) -> String {
        if let phone = PhoneIdentityNormalizer.normalizedE164(contact.phone, context: context) {
            return "phone:\(phone)"
        }
        return "id:\(contact.id.lowercased())"
    }

    private static func merged(
        _ lhs: WalletContactDTO,
        _ rhs: WalletContactDTO,
        context: PhoneIdentityContext
    ) -> WalletContactDTO {
        let base: WalletContactDTO
        let supplement: WalletContactDTO
        let lhsRecipientId = recipientUserId(for: lhs)
        let rhsRecipientId = recipientUserId(for: rhs)
        if rhsRecipientId != nil, lhsRecipientId == nil {
            (base, supplement) = (rhs, lhs)
        } else {
            (base, supplement) = (lhs, rhs)
        }

        return WalletContactDTO(
            id: recipientUserId(for: base) ?? base.id,
            contactId: base.contactId ?? supplement.contactId,
            name: base.name,
            phone: PhoneIdentityNormalizer.normalizedE164(base.phone, context: context) ?? base.phone,
            isKitUser: base.isKitUser == true || supplement.isKitUser == true,
            favorite: base.favorite == true || supplement.favorite == true,
            status: base.status ?? supplement.status,
            tag: base.tag ?? supplement.tag,
            avatarURL: base.avatarURL ?? supplement.avatarURL,
            receivingWalletId: base.receivingWalletId ?? supplement.receivingWalletId,
            verification: base.verification?.designation != nil
                ? base.verification
                : supplement.verification
        )
    }

    private static func searchKey(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}

struct ConversationContactPresentation: Equatable, Sendable {
    let recipientUserID: String?
    let displayName: String
    let avatarURL: String?
    let verification: AccountVerificationDesignation?
    let contact: WalletContactDTO?
}

/// One directory scan per chat-list/search render. Preserve duplicate order so the existing
/// saved-contact name and avatar precedence remain identical to a direct directory lookup.
struct ConversationContactDirectoryIndex {
    private var contactsByRecipient: [String: [WalletContactDTO]] = [:]

    init(_ contacts: [WalletContactDTO]) {
        for contact in contacts {
            guard let recipientID = ContactRecipientDirectory.recipientUserId(for: contact)
            else { continue }
            contactsByRecipient[recipientID, default: []].append(contact)
        }
    }

    func contacts(for recipientID: String) -> [WalletContactDTO] {
        contactsByRecipient[recipientID] ?? []
    }
}

/// Gives every chat surface one stable identity presentation. A name saved in this iPhone's
/// Contacts app wins over the mutable server conversation title, while the member avatar still
/// comes from the synchronized Kit Pay directory. Ambiguous/group rosters deliberately fall back
/// to the authenticated conversation title and never guess a recipient.
enum ConversationContactPresentationPolicy {
    static func presentation(
        for conversation: Conversation,
        currentUserID: String?,
        contacts: [WalletContactDTO]
    ) -> ConversationContactPresentation {
        presentation(for: conversation, currentUserID: currentUserID) { recipientID in
            contacts.filter { ContactRecipientDirectory.recipientUserId(for: $0) == recipientID }
        }
    }

    static func presentation(
        for conversation: Conversation,
        currentUserID: String?,
        directory: ConversationContactDirectoryIndex
    ) -> ConversationContactPresentation {
        presentation(for: conversation, currentUserID: currentUserID,
                     matchingContacts: directory.contacts(for:))
    }

    private static func presentation(
        for conversation: Conversation,
        currentUserID: String?,
        matchingContacts: (String) -> [WalletContactDTO]
    ) -> ConversationContactPresentation {
        let fallbackName = cleanName(conversation.title) ?? "Kit Pay user"
        guard let currentUserID = canonicalUserID(currentUserID) else {
            return fallback(
                name: fallbackName
            )
        }

        var participantIDs: Set<String> = []
        for rawParticipantID in conversation.participantUserIds {
            guard let participantID = canonicalUserID(rawParticipantID),
                  participantIDs.insert(participantID).inserted
            else { return fallback(name: fallbackName) }
        }
        guard !conversation.isGroup,
              participantIDs.count == 2,
              participantIDs.remove(currentUserID) != nil,
              let recipientUserID = participantIDs.first
        else {
            // A group presents its own identity: the authenticated title and, when one is
            // set, the group's own photo — never a member's face borrowed onto a shared room.
            return ConversationContactPresentation(
                recipientUserID: nil,
                displayName: fallbackName,
                avatarURL: conversation.isGroup
                    ? cleanHTTPSURL(conversation.groupPhotoURL)
                    : nil,
                verification: nil,
                contact: nil
            )
        }

        let matches = matchingContacts(recipientUserID)
        let savedContact = matches.first {
            $0.contactId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        let contact = savedContact ?? matches.first
        let displayName = savedContact.flatMap { cleanName($0.name) }
            ?? contact.flatMap { cleanName($0.name) }
            ?? conversation.memberIdentity(for: recipientUserID)?.displayName
            ?? fallbackName
        let memberIdentity = conversation.memberIdentity(for: recipientUserID)
        let avatarURL = cleanHTTPSURL(memberIdentity?.avatarURL)
            ?? matches.lazy.compactMap { cleanHTTPSURL($0.avatarURL) }.first
        let verification = memberIdentity?.verification?.designation
            ?? contact?.verification?.designation

        return ConversationContactPresentation(
            recipientUserID: recipientUserID,
            displayName: displayName,
            avatarURL: avatarURL,
            verification: verification,
            contact: contact
        )
    }

    private static func fallback(name: String) -> ConversationContactPresentation {
        ConversationContactPresentation(
            recipientUserID: nil,
            displayName: name,
            avatarURL: nil,
            verification: nil,
            contact: nil
        )
    }

    private static func canonicalUserID(_ rawValue: String?) -> String? {
        guard let rawValue,
              rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
              let identifier = UUID(uuidString: rawValue)
        else { return nil }
        return identifier.uuidString.lowercased()
    }

    private static func cleanName(_ rawValue: String?) -> String? {
        let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private static func cleanHTTPSURL(_ rawValue: String?) -> String? {
        guard let value = cleanName(rawValue),
              let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.host != nil
        else { return nil }
        return value
    }
}

enum ContactSyncNormalizer {
    /// Mirrors the API's UG-default phone handling before upload. The backend
    /// remains authoritative and validates every number with libphonenumber.
    static func normalizedPhone(
        _ input: String,
        context: PhoneIdentityContext = .uganda
    ) -> String? {
        PhoneIdentityNormalizer.normalizedE164(input, context: context)
    }

    /// Produces the device snapshot used by the chunked contacts sync protocol.
    /// Duplicate normalized numbers keep their original position while the
    /// last phone-book row wins, matching the backend's fingerprint map.
    static func snapshot(
        from phones: [DeviceContactPhone],
        limit: Int = ContactSyncSnapshot.serverLimit,
        context: PhoneIdentityContext = .uganda
    ) -> ContactSyncSnapshot {
        let safeLimit = max(0, min(limit, ContactSyncSnapshot.serverLimit))
        var order: [String] = []
        var entriesByPhone: [String: ContactSyncEntry] = [:]

        for candidate in phones {
            if Task.isCancelled { break }
            guard let phone = normalizedPhone(candidate.phone, context: context) else { continue }
            let name = normalizedName(candidate.name, fallback: phone)
            if entriesByPhone[phone] == nil { order.append(phone) }
            entriesByPhone[phone] = ContactSyncEntry(
                name: name,
                phone: phone,
                favorite: false
            )
        }

        let entries = order.compactMap { entriesByPhone[$0] }
        return ContactSyncSnapshot(
            contacts: Array(entries.prefix(safeLimit)),
            omittedCount: max(0, entries.count - safeLimit)
        )
    }

    private static func normalizedName(_ input: String, fallback: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        let scalars = trimmed.unicodeScalars.prefix(160)
        return String(String.UnicodeScalarView(scalars))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }

    func trimmingTagMarkers() -> String {
        String(drop(while: { $0 == "@" || $0 == ":" }))
    }
}
