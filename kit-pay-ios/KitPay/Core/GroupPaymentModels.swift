import Foundation

// MARK: - Authoritative group-payment state

/// Where one member's share of a group payment has got to. Deliberately the same vocabulary as a
/// one-to-one held transfer, because underneath it is one.
enum GroupPaymentShareStatus: String, Codable, CaseIterable {
    case pending
    case accepted
    case rejected
    case reversed
    case expired

    var isSettled: Bool { self != .pending }

    /// Whether the money went back to the sender rather than staying with the member.
    var returnedFunds: Bool { [.rejected, .reversed, .expired].contains(self) }
}

enum GroupPaymentSplitMode: String, Codable, CaseIterable {
    /// One pot divided across the recipients.
    case even
    /// The sender wrote an amount for each member.
    case custom
}

enum GroupPaymentAudience: String, Codable, CaseIterable {
    /// Everybody in the group at the time of sending.
    case all
    /// A chosen few.
    case selected
}

/// One group payment as the backend renders it *for the caller*.
///
/// The scoping is the server's, not the app's: a recipient of an unevenly-split payment is sent
/// `total_amount: null` and `amount: null` for everybody but themselves. The app never has the
/// other members' amounts to leak in the first place.
struct GroupPaymentDTO: Decodable, Hashable, Identifiable {
    let id: String
    let conversationId: String?
    let splitMode: String
    let audience: String
    let currency: CurrencyDTO
    let recipientCount: Int
    /// Absent for a recipient of a custom split: the size of everybody else's share is not theirs.
    let totalAmount: String?
    let note: String?
    let sender: GroupPaymentPartyDTO?
    let status: String
    let pendingCount: Int
    let acceptedCount: Int
    let returnedCount: Int
    let yourShare: GroupPaymentShareDTO?
    let canReverseUnclaimed: Bool
    let recipients: [GroupPaymentRecipientDTO]
    let expiresAt: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, audience, currency, note, sender, status, recipients
        case conversationId = "conversation_id"
        case splitMode = "split_mode"
        case recipientCount = "recipient_count"
        case totalAmount = "total_amount"
        case pendingCount = "pending_count"
        case acceptedCount = "accepted_count"
        case returnedCount = "returned_count"
        case yourShare = "your_share"
        case canReverseUnclaimed = "can_reverse_unclaimed"
        case expiresAt = "expires_at"
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        conversationId = try values.decodeIfPresent(String.self, forKey: .conversationId)
        splitMode = try values.decode(String.self, forKey: .splitMode)
        audience = try values.decode(String.self, forKey: .audience)
        currency = try values.decode(CurrencyDTO.self, forKey: .currency)
        recipientCount = try values.decodeIfPresent(Int.self, forKey: .recipientCount) ?? 0
        totalAmount = try values.decodeIfPresent(String.self, forKey: .totalAmount)
        note = try values.decodeIfPresent(String.self, forKey: .note)
        sender = try values.decodeIfPresent(GroupPaymentPartyDTO.self, forKey: .sender)
        status = try values.decode(String.self, forKey: .status)
        pendingCount = try values.decodeIfPresent(Int.self, forKey: .pendingCount) ?? 0
        acceptedCount = try values.decodeIfPresent(Int.self, forKey: .acceptedCount) ?? 0
        returnedCount = try values.decodeIfPresent(Int.self, forKey: .returnedCount) ?? 0
        yourShare = try values.decodeIfPresent(GroupPaymentShareDTO.self, forKey: .yourShare)
        canReverseUnclaimed = try values.decodeIfPresent(
            Bool.self,
            forKey: .canReverseUnclaimed
        ) ?? false
        recipients = try values.decodeIfPresent(
            [GroupPaymentRecipientDTO].self,
            forKey: .recipients
        ) ?? []
        expiresAt = try values.decodeIfPresent(String.self, forKey: .expiresAt)
        createdAt = try values.decodeIfPresent(String.self, forKey: .createdAt)
    }

    var knownSplitMode: GroupPaymentSplitMode? { GroupPaymentSplitMode(rawValue: splitMode) }
    var knownAudience: GroupPaymentAudience? { GroupPaymentAudience(rawValue: audience) }
    var isSettled: Bool { status == "settled" }
    var currencyScale: Int { currency.decimalScale }

    /// Every recipient's share as a fraction of what has been decided, for the sender's progress
    /// line. Counts, not amounts, so it means the same thing to a member who cannot see the pot.
    var resolvedCount: Int { acceptedCount + returnedCount }
}

struct GroupPaymentPartyDTO: Decodable, Hashable {
    let id: String?
    let name: String?
}

struct GroupPaymentShareDTO: Decodable, Hashable {
    let amount: String
    let status: String
    let claimId: String?
    let canAccept: Bool
    let canReject: Bool

    enum CodingKeys: String, CodingKey {
        case amount, status
        case claimId = "claim_id"
        case canAccept = "can_accept"
        case canReject = "can_reject"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        amount = try values.decode(String.self, forKey: .amount)
        status = try values.decode(String.self, forKey: .status)
        claimId = try values.decodeIfPresent(String.self, forKey: .claimId)
        canAccept = try values.decodeIfPresent(Bool.self, forKey: .canAccept) ?? false
        canReject = try values.decodeIfPresent(Bool.self, forKey: .canReject) ?? false
    }

    var knownStatus: GroupPaymentShareStatus? { GroupPaymentShareStatus(rawValue: status) }
}

struct GroupPaymentRecipientDTO: Decodable, Hashable, Identifiable {
    let userId: String?
    let name: String?
    let status: String
    /// Withheld unless the viewer is the sender, the split was even, or this is the viewer's own.
    let amount: String?
    let resolvedAt: String?

    enum CodingKeys: String, CodingKey {
        case name, status, amount
        case userId = "user_id"
        case resolvedAt = "resolved_at"
    }

    var id: String { userId ?? name ?? status }
    var knownStatus: GroupPaymentShareStatus? { GroupPaymentShareStatus(rawValue: status) }
}

/// Binds a chat announcement to the server object it claims to represent. A valid payment copied
/// into another group — or reposted by somebody other than its sender — stays inert even though
/// its identifier and amounts are otherwise genuine.
enum GroupPaymentAuthorityPolicy {
    static func matchesContext(
        _ payment: GroupPaymentDTO,
        conversationID: String,
        announcementSenderID: String
    ) -> Bool {
        guard let paymentConversationID = canonicalUUID(payment.conversationId),
              let expectedConversationID = canonicalUUID(conversationID),
              let paymentSenderID = canonicalUUID(payment.sender?.id),
              let expectedSenderID = canonicalUUID(announcementSenderID)
        else { return false }
        return paymentConversationID == expectedConversationID
            && paymentSenderID == expectedSenderID
    }

    private static func canonicalUUID(_ raw: String?) -> String? {
        guard let raw, let value = UUID(uuidString: raw) else { return nil }
        return value.uuidString.lowercased()
    }
}

// MARK: - Capability gate

/// Group payments exist only where held transfers and group chat already do — the server refuses
/// otherwise, and the composer must not offer what the server will decline.
struct GroupPaymentPolicy: Equatable {
    let acceptanceEnabled: Bool
    let groupPaymentsEnabled: Bool

    init(features: [String: Bool?]?) {
        let enabled = features?.compactMapValues { $0 } ?? [:]
        acceptanceEnabled = enabled["wallets"] == true
            && enabled["internal_transfers"] == true
            && enabled["claimable_transfers"] == true
        groupPaymentsEnabled = acceptanceEnabled && enabled["group_payments"] == true
    }
}

// MARK: - Wire descriptor

enum KitGroupPaymentMessageAction: String, Equatable, Sendable, CaseIterable {
    /// The announcement the sender posts: who was paid, and how much when that is not private.
    case sent
    /// A member took their own share.
    case accepted
    /// A member turned their own share down.
    case rejected
    /// The sender pulled back whatever nobody had claimed.
    case returned
}

/// Canonical group-payment descriptor carried inside the end-to-end encrypted message body.
///
/// One ciphertext reaches every member, so this can only ever carry what the whole group is
/// allowed to see. That is the reason the total is present for an even split and absent for a
/// custom one: with an even split the pot is share × members and hiding it would be theatre,
/// while with a custom split the amounts are between the sender and each recipient. Each member
/// reads their own share from `GET /group-payments/{id}`, never from here.
///
/// Its fixed field order and strict re-encoding match Android's `KITGRP1` wire contract.
struct KitGroupPaymentMessage: Equatable, Sendable {
    static let prefix = "KITGRP1:"
    /// Larger than `KITPAY1` because the announcement may name who was paid. A send to more
    /// recipients than fit simply omits the roster and the app resolves names from the API.
    static let maximumDescriptorLength = 4_096
    static let maximumNoteLength = 280
    static let maximumRecipientCount = 50
    /// Beyond this the roster is dropped from the descriptor rather than truncated: a partial
    /// list would read as the whole list, and "sent to Ama and Ben" when six were paid is a lie.
    static let maximumInlineRecipients = 24
    static let maximumAmountMinor: Int64 = 1_000_000_000_000

    let action: KitGroupPaymentMessageAction
    let groupPaymentId: String
    let splitMode: GroupPaymentSplitMode?
    let audience: GroupPaymentAudience?
    let recipientCount: Int?
    let currencyCode: String?
    let currencyScale: Int?
    /// Present only on a `sent` announcement of an even split.
    let totalAmountMinor: Int64?
    let note: String?
    /// Public ids of the members who were paid, lowercased, in the server's order. Empty when the
    /// roster did not fit or the payment went to everybody.
    let recipientUserIds: [String]

    init?(
        action: KitGroupPaymentMessageAction,
        groupPaymentId: String,
        splitMode: GroupPaymentSplitMode? = nil,
        audience: GroupPaymentAudience? = nil,
        recipientCount: Int? = nil,
        currencyCode: String? = nil,
        currencyScale: Int? = nil,
        totalAmountMinor: Int64? = nil,
        note: String? = nil,
        recipientUserIds: [String] = []
    ) {
        guard Self.isCanonicalUUID(groupPaymentId) else { return nil }

        let normalizedNote: String?
        if let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalizedNote = note
        } else {
            normalizedNote = nil
        }
        let normalizedRecipients = recipientUserIds.map { $0.lowercased() }

        switch action {
        case .sent:
            guard let splitMode,
                  let audience,
                  let recipientCount,
                  (1 ... Self.maximumRecipientCount).contains(recipientCount),
                  let currencyCode,
                  Self.isCurrencyCode(currencyCode),
                  let currencyScale,
                  (0 ... 6).contains(currencyScale),
                  (normalizedNote?.utf16.count ?? 0) <= Self.maximumNoteLength,
                  normalizedRecipients.count <= Self.maximumInlineRecipients,
                  normalizedRecipients.allSatisfy(Self.isCanonicalUUID),
                  Set(normalizedRecipients).count == normalizedRecipients.count,
                  normalizedRecipients.isEmpty || normalizedRecipients.count == recipientCount
            else { return nil }
            // The total travels with an even split and only with an even split. A custom split
            // that carried its total would hand every member the sum of amounts they were never
            // shown, one subtraction away from someone else's share.
            switch splitMode {
            case .even:
                guard let totalAmountMinor,
                      (1 ... Self.maximumAmountMinor).contains(totalAmountMinor)
                else { return nil }
            case .custom:
                guard totalAmountMinor == nil, audience == .selected else { return nil }
            }
        case .accepted, .rejected, .returned:
            // An outcome is who did what, and nothing else: an amount here would republish a
            // share the group was never told.
            guard splitMode == nil,
                  audience == nil,
                  recipientCount == nil,
                  currencyCode == nil,
                  currencyScale == nil,
                  totalAmountMinor == nil,
                  normalizedNote == nil,
                  normalizedRecipients.isEmpty
            else { return nil }
        }

        self.action = action
        self.groupPaymentId = groupPaymentId
        self.splitMode = splitMode
        self.audience = audience
        self.recipientCount = recipientCount
        self.currencyCode = currencyCode
        self.currencyScale = currencyScale
        self.totalAmountMinor = totalAmountMinor
        self.note = normalizedNote
        self.recipientUserIds = normalizedRecipients
        guard encoded.utf16.count <= Self.maximumDescriptorLength else { return nil }
    }

    /// The announcement for a payment the server has just confirmed.
    init?(announcing payment: GroupPaymentDTO, recipientUserIds: [String]) {
        guard let splitMode = payment.knownSplitMode,
              let audience = payment.knownAudience
        else { return nil }
        let scale = payment.currencyScale
        let totalMinor: Int64?
        switch splitMode {
        case .even:
            guard let totalAmount = payment.totalAmount,
                  let minor = KitPaymentMessage.minorUnits(for: totalAmount, scale: scale)
            else { return nil }
            totalMinor = minor
        case .custom:
            totalMinor = nil
        }
        let roster = recipientUserIds.count <= Self.maximumInlineRecipients
            && recipientUserIds.count == payment.recipientCount
            ? recipientUserIds
            : []
        self.init(
            action: .sent,
            groupPaymentId: payment.id.lowercased(),
            splitMode: splitMode,
            audience: audience,
            recipientCount: payment.recipientCount,
            currencyCode: payment.currency.code,
            currencyScale: scale,
            totalAmountMinor: totalMinor,
            note: payment.note,
            recipientUserIds: roster
        )
    }

    /// An outcome event authored by whoever produced it.
    init?(outcome: KitGroupPaymentMessageAction, groupPaymentId: String) {
        guard outcome != .sent else { return nil }
        self.init(action: outcome, groupPaymentId: groupPaymentId.lowercased())
    }

    /// The local message id for an outcome chip this member posts.
    ///
    /// Derived from the payment, the outcome and the author, so a retry — or the same action taken
    /// twice on two devices — converges on one chip instead of announcing "Ama took their share"
    /// again. The timeline drops repeats anyway; this stops them being sent at all.
    static func outcomeMessageID(
        groupPaymentId: String,
        action: KitGroupPaymentMessageAction,
        actorUserId: String
    ) -> UUID {
        KitSystemMessage.deterministicMessageID(
            namespace: [
                "group-payment-outcome",
                groupPaymentId.lowercased(),
                action.rawValue,
                actorUserId.lowercased(),
            ].joined(separator: "|")
        )
    }

    var encoded: String {
        var value = Self.prefix
        value += "v=1"
        value += "&a=\(action.rawValue)"
        value += "&id=\(Self.percentEncode(groupPaymentId))"
        if let splitMode { value += "&sp=\(splitMode.rawValue)" }
        if let audience { value += "&au=\(audience.rawValue)" }
        if let recipientCount { value += "&n=\(recipientCount)" }
        if let currencyCode { value += "&cur=\(Self.percentEncode(currencyCode))" }
        if let currencyScale { value += "&sc=\(currencyScale)" }
        if let totalAmountMinor { value += "&amt=\(totalAmountMinor)" }
        if let note { value += "&note=\(Self.percentEncode(note))" }
        if !recipientUserIds.isEmpty {
            value += "&rid=\(Self.percentEncode(recipientUserIds.joined(separator: ",")))"
        }
        return value
    }

    /// The canonical `.`-separated total, when the group is allowed to know it.
    var decimalTotalAmount: String? {
        guard let totalAmountMinor, let currencyScale else { return nil }
        return KitMoney.decimal(minorUnits: totalAmountMinor, scale: currencyScale)
    }

    /// What one member gets from an evenly-split pot, before the remainder is dealt. Shown only
    /// as "about", because the odd minor unit goes to one member and not the others.
    var evenShareMinor: Int64? {
        guard splitMode == .even,
              let totalAmountMinor,
              let recipientCount,
              recipientCount > 0
        else { return nil }
        return totalAmountMinor / Int64(recipientCount)
    }

    var dividesEvenly: Bool {
        guard let totalAmountMinor, let recipientCount, recipientCount > 0 else { return false }
        return totalAmountMinor % Int64(recipientCount) == 0
    }

    static func isGroupPaymentText(_ text: String) -> Bool {
        text.hasPrefix(prefix)
    }

    static func parse(_ text: String) -> KitGroupPaymentMessage? {
        guard text.hasPrefix(prefix), text.utf16.count <= maximumDescriptorLength else {
            return nil
        }

        var fields: [String: String] = [:]
        for pair in text.dropFirst(prefix.count).split(
            separator: "&",
            omittingEmptySubsequences: false
        ) {
            guard let separator = pair.firstIndex(of: "="), separator != pair.startIndex else {
                return nil
            }
            let key = String(pair[..<separator])
            let encodedValue = String(pair[pair.index(after: separator)...])
            guard fields[key] == nil, let value = percentDecode(encodedValue) else { return nil }
            fields[key] = value
        }

        let roster = fields["rid"].map { value in
            value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        } ?? []

        guard fields["v"] == "1",
              let action = fields["a"].flatMap(KitGroupPaymentMessageAction.init(rawValue:)),
              let groupPaymentId = fields["id"]?.lowercased(),
              let descriptor = KitGroupPaymentMessage(
                  action: action,
                  groupPaymentId: groupPaymentId,
                  splitMode: fields["sp"].flatMap(GroupPaymentSplitMode.init(rawValue:)),
                  audience: fields["au"].flatMap(GroupPaymentAudience.init(rawValue:)),
                  recipientCount: fields["n"].flatMap(Int.init),
                  currencyCode: fields["cur"],
                  currencyScale: fields["sc"].flatMap(Int.init),
                  totalAmountMinor: fields["amt"].flatMap(Int64.init),
                  note: fields["note"],
                  recipientUserIds: roster
              ),
              descriptor.encoded == text
        else { return nil }
        return descriptor
    }

    /// Field-exact check against the backend's object, so an announcement can never put words in
    /// the payment's mouth.
    func matchesAuthoritativePayment(_ payment: GroupPaymentDTO) -> Bool {
        guard payment.id.lowercased() == groupPaymentId,
              payment.splitMode == splitMode?.rawValue,
              payment.audience == audience?.rawValue,
              payment.recipientCount == recipientCount
        else { return false }
        guard let currencyCode, let currencyScale else { return false }
        guard payment.currency.code == currencyCode, payment.currencyScale == currencyScale else {
            return false
        }
        switch splitMode {
        case .even:
            guard let totalAmount = payment.totalAmount,
                  KitPaymentMessage.minorUnits(for: totalAmount, scale: currencyScale)
                  == totalAmountMinor
            else { return false }
        case .custom, nil:
            break
        }
        return true
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        value.range(
            of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,
            options: .regularExpression
        ) != nil
    }

    private static func isCurrencyCode(_ value: String) -> Bool {
        value.range(of: #"^[A-Z]{3}$"#, options: .regularExpression) != nil
    }

    /// Java `URLEncoder`'s safe byte set, with its `+` spaces canonicalized to `%20`.
    private static func percentEncode(_ value: String) -> String {
        let hex = Array("0123456789ABCDEF".utf8)
        var encoded = ""
        encoded.reserveCapacity(value.utf8.count * 3)
        for byte in value.utf8 {
            switch byte {
            case 48 ... 57, 65 ... 90, 97 ... 122, 45, 46, 95, 42:
                encoded.unicodeScalars.append(UnicodeScalar(byte))
            default:
                encoded.unicodeScalars.append("%")
                encoded.unicodeScalars.append(UnicodeScalar(hex[Int(byte >> 4)]))
                encoded.unicodeScalars.append(UnicodeScalar(hex[Int(byte & 0x0F)]))
            }
        }
        return encoded
    }

    private static func percentDecode(_ value: String) -> String? {
        value.replacingOccurrences(of: "+", with: "%20").removingPercentEncoding
    }
}

// MARK: - Request bodies

struct CreateGroupPaymentBody: Encodable, Sendable {
    let sourceWalletId: String
    let splitMode: String
    let audience: String
    let totalAmount: String?
    let note: String?
    let recipients: [Recipient]?

    struct Recipient: Encodable, Equatable, Sendable {
        let userId: String
        let amount: String?

        enum CodingKeys: String, CodingKey {
            case userId = "user_id"
            case amount
        }
    }

    enum CodingKeys: String, CodingKey {
        case audience, note, recipients
        case sourceWalletId = "source_wallet_id"
        case splitMode = "split_mode"
        case totalAmount = "total_amount"
    }
}

struct GroupPaymentResolutionBody: Encodable {
    let reason: String?
}

struct GroupPaymentEmptyBody: Encodable {}

// MARK: - Composing a send

/// Everything the composer needs to decide before it asks anyone to approve a payment.
///
/// The server checks all of this again and is the authority; the point of doing it here is that a
/// sender should never be asked for their PIN or their fingerprint to approve a send that was
/// always going to be refused.
enum GroupPaymentDraftPolicy {
    /// Matches the server's own ceiling on how many members one payment may reach.
    static let maximumRecipients = 50

    struct Member: Identifiable, Hashable {
        let userId: String
        let name: String

        var id: String { userId }
    }

    enum Outcome {
        case ready(CreateGroupPaymentBody)
        /// Copy to show under the composer. Never phrased as an error the sender caused when it
        /// is really a limit of the currency or their balance.
        case problem(String)
    }

    static func draft(
        sourceWalletId: String,
        splitMode: GroupPaymentSplitMode,
        audience: GroupPaymentAudience,
        selected: [Member],
        totalInput: String,
        customAmounts: [String: String],
        note: String?,
        scale: Int,
        availableBalance: String
    ) -> Outcome {
        guard !selected.isEmpty else {
            return .problem("Choose at least one member to pay.")
        }
        guard selected.count <= maximumRecipients else {
            return .problem("A group payment can go to at most \(maximumRecipients) members at a time.")
        }
        let canonicalRecipients = selected.compactMap { member in
            UUID(uuidString: member.userId)?.uuidString.lowercased()
        }
        guard canonicalRecipients.count == selected.count,
              Set(canonicalRecipients).count == selected.count
        else {
            return .problem("Refresh this group before sending. Its member list is not valid.")
        }
        guard splitMode == .even || audience == .selected else {
            // Writing an amount for each member is itself the act of choosing them.
            return .problem("To give each member a different amount, choose the members you are paying.")
        }
        let available = KitPaymentMessage.minorUnits(for: availableBalance, scale: scale) ?? 0

        switch splitMode {
        case .even:
            guard let total = minorUnits(forDisplayedInput: totalInput, scale: scale),
                  (1 ... KitGroupPaymentMessage.maximumAmountMinor).contains(total)
            else { return .problem("Enter the amount you are sending.") }
            guard total >= Int64(selected.count) else {
                return .problem(
                    "That amount is too small to divide between \(selected.count) members. Each one has to receive at least the smallest unit of the currency."
                )
            }
            guard total <= available else {
                return .problem("Your wallet does not have that much available.")
            }
            return .ready(
                CreateGroupPaymentBody(
                    sourceWalletId: sourceWalletId,
                    splitMode: splitMode.rawValue,
                    audience: audience.rawValue,
                    totalAmount: KitMoney.decimal(minorUnits: total, scale: scale),
                    note: trimmedNote(note),
                    // "Everyone" is left for the server to resolve: the roster it holds at the
                    // moment of sending is the true one, not whatever this device last synced.
                    recipients: audience == .all ? nil : selected.map {
                        CreateGroupPaymentBody.Recipient(userId: $0.userId, amount: nil)
                    }
                )
            )
        case .custom:
            var entries: [CreateGroupPaymentBody.Recipient] = []
            var total: Int64 = 0
            for member in selected {
                guard let raw = customAmounts[member.userId],
                      let minor = minorUnits(forDisplayedInput: raw, scale: scale),
                      (1 ... KitGroupPaymentMessage.maximumAmountMinor).contains(minor)
                else { return .problem("Enter an amount for every member you are paying.") }
                let (nextTotal, overflow) = total.addingReportingOverflow(minor)
                guard !overflow, nextTotal <= KitGroupPaymentMessage.maximumAmountMinor else {
                    return .problem("That group payment is above the supported amount.")
                }
                total = nextTotal
                entries.append(
                    CreateGroupPaymentBody.Recipient(
                        userId: member.userId,
                        amount: KitMoney.decimal(minorUnits: minor, scale: scale)
                    )
                )
            }
            guard total <= available else {
                return .problem("Your wallet does not have that much available.")
            }
            return .ready(
                CreateGroupPaymentBody(
                    sourceWalletId: sourceWalletId,
                    splitMode: splitMode.rawValue,
                    audience: audience.rawValue,
                    totalAmount: nil,
                    note: trimmedNote(note),
                    recipients: entries
                )
            )
        }
    }

    /// What the sender is about to spend, for the review line above the approval control.
    static func totalMinor(
        splitMode: GroupPaymentSplitMode,
        selected: [Member],
        totalInput: String,
        customAmounts: [String: String],
        scale: Int
    ) -> Int64? {
        switch splitMode {
        case .even:
            return minorUnits(forDisplayedInput: totalInput, scale: scale)
        case .custom:
            var total: Int64 = 0
            for member in selected {
                guard let raw = customAmounts[member.userId],
                      let minor = minorUnits(forDisplayedInput: raw, scale: scale),
                      (1 ... KitGroupPaymentMessage.maximumAmountMinor).contains(minor)
                else { return nil }
                let (nextTotal, overflow) = total.addingReportingOverflow(minor)
                guard !overflow, nextTotal <= KitGroupPaymentMessage.maximumAmountMinor else {
                    return nil
                }
                total = nextTotal
            }
            return total
        }
    }

    /// Keeps the UI and the encrypted descriptor on the same UTF-16 boundary. Counting Swift
    /// characters would let 280 emoji through as a 560-unit note, after the money had moved but
    /// before its chat announcement could be created.
    static func boundedNoteInput(_ raw: String) -> String {
        var result = ""
        result.reserveCapacity(min(raw.count, KitGroupPaymentMessage.maximumNoteLength))
        for character in raw {
            let next = String(character)
            guard result.utf16.count + next.utf16.count
                    <= KitGroupPaymentMessage.maximumNoteLength
            else { break }
            result.append(character)
        }
        return result
    }

    private static func trimmedNote(_ note: String?) -> String? {
        guard let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty else {
            return nil
        }
        return boundedNoteInput(note)
    }

    private static func minorUnits(forDisplayedInput raw: String, scale: Int) -> Int64? {
        KitPaymentMessage.minorUnits(
            for: raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: ",", with: ""),
            scale: scale
        )
    }
}

// MARK: - Step-up intent

enum GroupPaymentStepUpPolicy {
    static let sendPurpose = "group_payment"
    static let reversePurpose = "group_payment_reverse"

    /// The intent the server hashes for a send. The whole recipient list is flattened into one
    /// `id:amount,id:amount` string, so approving "5,000 split between three people" cannot be
    /// replayed as "5,000 each", and so the hash does not depend on how either platform's JSON
    /// encoder orders keys or renders arrays. The server validates both fields to exclude the
    /// separators before it hashes anything.
    static func sendIntent(
        for body: CreateGroupPaymentBody,
        conversationId: String
    ) -> [String: String?] {
        let recipientIntent = (body.recipients ?? [])
            .map { "\($0.userId):\($0.amount ?? "")" }
            .joined(separator: ",")
        return [
            "conversation_id": conversationId,
            "source_wallet_id": body.sourceWalletId,
            "split_mode": body.splitMode,
            "audience": body.audience,
            "total_amount": body.totalAmount,
            "note": body.note,
            // Laravel's request middleware normalizes an empty string to null before the
            // challenge is hashed. Emit null here too, otherwise an even split to everyone
            // rejects the genuine challenge as if its approval intent had been changed.
            "recipients": recipientIntent.isEmpty ? nil : recipientIntent,
        ]
    }

    static func reverseIntent(groupPaymentId: String, reason: String?) -> [String: String?] {
        [
            "group_payment_id": groupPaymentId,
            "reason": reason,
        ]
    }
}

// MARK: - Collaborative group payment requests

/// Strict, additive capability blocks for the group-request and scheduled-payment rollout. The
/// outer capabilities decoder treats this section leniently so one malformed future payment
/// protocol cannot make the whole app unusable; each feature still fails closed here.
struct PaymentProtocolsCapabilityDTO: Decodable {
    let groupPaymentRequests: GroupPaymentRequestsProtocolCapabilityDTO?
    let scheduledChatPayments: ScheduledChatPaymentsProtocolCapabilityDTO?
    let scheduledGroupPayments: ScheduledGroupPaymentsProtocolCapabilityDTO?

    enum CodingKeys: String, CodingKey {
        case groupPaymentRequests = "group_payment_requests"
        case scheduledChatPayments = "scheduled_chat_payments"
        case scheduledGroupPayments = "scheduled_group_payments"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        groupPaymentRequests = try? values.decodeIfPresent(
            GroupPaymentRequestsProtocolCapabilityDTO.self,
            forKey: .groupPaymentRequests
        )
        scheduledChatPayments = try? values.decodeIfPresent(
            ScheduledChatPaymentsProtocolCapabilityDTO.self,
            forKey: .scheduledChatPayments
        )
        scheduledGroupPayments = try? values.decodeIfPresent(
            ScheduledGroupPaymentsProtocolCapabilityDTO.self,
            forKey: .scheduledGroupPayments
        )
    }
}

struct ScheduledChatPaymentsProtocolCapabilityDTO: Decodable, Equatable, Sendable {
    static let version = "v1"
    static let minimumIOSRelease = "1.0.16-r39"

    let version: String?
    let ready: Bool?
    let minimumIOSVersion: String?

    enum CodingKeys: String, CodingKey {
        case version, ready
        case minimumIOSVersion = "minimum_ios_version"
    }

    var supportsIOSV1: Bool {
        ready == true
            && version == Self.version
            && minimumIOSVersion == Self.minimumIOSRelease
    }
}

struct GroupPaymentRequestsProtocolCapabilityDTO: Decodable, Equatable, Sendable {
    static let version = "v1"
    static let minimumIOSRelease = "1.0.16-r39"

    let version: String?
    let ready: Bool?
    let partialContributions: Bool?
    let progressBasisPointsMax: Int?
    let minimumIOSVersion: String?

    enum CodingKeys: String, CodingKey {
        case version, ready
        case partialContributions = "partial_contributions"
        case progressBasisPointsMax = "progress_basis_points_max"
        case minimumIOSVersion = "minimum_ios_version"
    }

    var supportsIOSV1: Bool {
        ready == true
            && version == Self.version
            && partialContributions == true
            && progressBasisPointsMax == 10_000
            && minimumIOSVersion == Self.minimumIOSRelease
    }
}

struct ScheduledGroupPaymentsProtocolCapabilityDTO: Decodable, Equatable, Sendable {
    let version: String?
    let ready: Bool?
    let minimumIOSVersion: String?
    let minimumLeadSeconds: Int?
    let maximumHorizonSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case version, ready
        case minimumIOSVersion = "minimum_ios_version"
        case minimumLeadSeconds = "minimum_lead_seconds"
        case maximumHorizonSeconds = "maximum_horizon_seconds"
    }

    var supportsIOSV1: Bool {
        ready == true
            && version == "v1"
            && minimumIOSVersion == GroupPaymentRequestsProtocolCapabilityDTO.minimumIOSRelease
            && minimumLeadSeconds == 60
            && maximumHorizonSeconds == 31_536_000
    }
}

struct ScheduledGroupPaymentPolicy: Equatable {
    let enabled: Bool

    init(capabilities: CapabilitiesDTO?) {
        enabled = GroupPaymentPolicy(features: capabilities?.features).groupPaymentsEnabled
            && capabilities?.supportsFeature("scheduled_payments") == true
            && capabilities?.supportsFeature("scheduled_group_payments_v1") == true
            && capabilities?.protocols?.payments?.scheduledGroupPayments?.supportsIOSV1 == true
    }
}

enum ScheduledGroupPaymentStatus: String, Codable, CaseIterable, Sendable {
    case scheduled
    case queued
    case processing
    case completed
    case failed
    case cancelled

    var isTerminal: Bool { [.completed, .failed, .cancelled].contains(self) }
}

struct PreviewScheduledGroupPaymentBody: Encodable, Sendable {
    let sourceWalletId: String
    let splitMode: String
    let audience: String
    let totalAmount: String?
    let note: String?
    let recipients: [CreateGroupPaymentBody.Recipient]?
    let scheduledFor: String

    enum CodingKeys: String, CodingKey {
        case audience, note, recipients
        case sourceWalletId = "source_wallet_id"
        case splitMode = "split_mode"
        case totalAmount = "total_amount"
        case scheduledFor = "scheduled_for"
    }

    init(draft: CreateGroupPaymentBody, scheduledFor: Date) {
        sourceWalletId = draft.sourceWalletId
        splitMode = draft.splitMode
        audience = draft.audience
        totalAmount = draft.totalAmount
        note = draft.note
        recipients = draft.recipients
        self.scheduledFor = ScheduledPaymentDates.apiString(scheduledFor)
    }
}

struct CreateScheduledGroupPaymentBody: Encodable, Sendable {
    let planId: String

    enum CodingKeys: String, CodingKey { case planId = "plan_id" }
}

struct ScheduledGroupPaymentPlanRecipientDTO: Decodable, Equatable, Sendable {
    let userId: String
    let destinationWalletId: String
    let amount: String

    enum CodingKeys: String, CodingKey {
        case amount
        case userId = "user_id"
        case destinationWalletId = "destination_wallet_id"
    }
}

struct ScheduledGroupPaymentStepUpIntentDTO: Decodable, Equatable, Sendable {
    let action: String
    let planId: String
    let planHash: String
    let conversationId: String
    let sourceWalletId: String
    let splitMode: String
    let audience: String
    let totalAmount: String
    let currency: String
    let note: String?
    let scheduledFor: String
    let rosterFingerprint: String
    let frozenRecipients: String

    enum CodingKeys: String, CodingKey, CaseIterable {
        case action, currency, note, audience
        case planId = "plan_id"
        case planHash = "plan_hash"
        case conversationId = "conversation_id"
        case sourceWalletId = "source_wallet_id"
        case splitMode = "split_mode"
        case totalAmount = "total_amount"
        case scheduledFor = "scheduled_for"
        case rosterFingerprint = "roster_fingerprint"
        case frozenRecipients = "frozen_recipients"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard CodingKeys.allCases.allSatisfy(values.contains) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Scheduled group step-up intent is incomplete."
            ))
        }
        action = try values.decode(String.self, forKey: .action)
        planId = try values.decode(String.self, forKey: .planId)
        planHash = try values.decode(String.self, forKey: .planHash)
        conversationId = try values.decode(String.self, forKey: .conversationId)
        sourceWalletId = try values.decode(String.self, forKey: .sourceWalletId)
        splitMode = try values.decode(String.self, forKey: .splitMode)
        audience = try values.decode(String.self, forKey: .audience)
        totalAmount = try values.decode(String.self, forKey: .totalAmount)
        currency = try values.decode(String.self, forKey: .currency)
        note = try values.decodeIfPresent(String.self, forKey: .note)
        scheduledFor = try values.decode(String.self, forKey: .scheduledFor)
        rosterFingerprint = try values.decode(String.self, forKey: .rosterFingerprint)
        frozenRecipients = try values.decode(String.self, forKey: .frozenRecipients)
    }

    var fields: [String: String?] {
        [
            "action": action,
            "plan_id": planId,
            "plan_hash": planHash,
            "conversation_id": conversationId,
            "source_wallet_id": sourceWalletId,
            "split_mode": splitMode,
            "audience": audience,
            "total_amount": totalAmount,
            "currency": currency,
            "note": note,
            "scheduled_for": scheduledFor,
            "roster_fingerprint": rosterFingerprint,
            "frozen_recipients": frozenRecipients,
        ]
    }
}

struct ScheduledGroupPaymentStepUpDTO: Decodable, Equatable, Sendable {
    let purpose: String
    let intent: ScheduledGroupPaymentStepUpIntentDTO
}

struct ScheduledGroupPaymentPlanDTO: Decodable, Equatable, Sendable {
    let planId: String
    let conversationId: String
    let sourceWalletId: String
    let splitMode: String
    let audience: String
    let totalAmount: String
    let currency: CurrencyDTO
    let note: String?
    let recipientCount: Int
    let recipients: [ScheduledGroupPaymentPlanRecipientDTO]
    let rosterFingerprint: String
    let frozenRecipients: String
    let planHash: String
    let scheduledFor: String
    let expiresAt: String
    let stepUp: ScheduledGroupPaymentStepUpDTO

    enum CodingKeys: String, CodingKey {
        case audience, currency, note, recipients
        case planId = "plan_id"
        case conversationId = "conversation_id"
        case sourceWalletId = "source_wallet_id"
        case splitMode = "split_mode"
        case totalAmount = "total_amount"
        case recipientCount = "recipient_count"
        case rosterFingerprint = "roster_fingerprint"
        case frozenRecipients = "frozen_recipients"
        case planHash = "plan_hash"
        case scheduledFor = "scheduled_for"
        case expiresAt = "expires_at"
        case stepUp = "step_up"
    }

    var scheduledDate: Date? { ScheduledPaymentDates.parse(scheduledFor) }
    var expiryDate: Date? { ScheduledPaymentDates.parse(expiresAt) }
    var totalAmountMinor: Int64? {
        KitPaymentMessage.minorUnits(for: totalAmount, scale: currency.decimalScale)
    }

    func isStructurallyValid(now: Date = Date()) -> Bool {
        guard ScheduledPaymentValidation.canonicalUUID(planId) == planId,
              ScheduledPaymentValidation.canonicalUUID(conversationId) == conversationId,
              ScheduledPaymentValidation.canonicalUUID(sourceWalletId) == sourceWalletId,
              GroupPaymentSplitMode(rawValue: splitMode) != nil,
              GroupPaymentAudience(rawValue: audience) != nil,
              ScheduledPaymentValidation.isCurrencyCode(currency.code),
              (0 ... 6).contains(currency.decimalScale),
              let total = totalAmountMinor,
              (1 ... KitGroupPaymentMessage.maximumAmountMinor).contains(total),
              (1 ... GroupPaymentDraftPolicy.maximumRecipients).contains(recipientCount),
              recipients.count == recipientCount,
              (note?.utf16.count ?? 0) <= KitGroupPaymentMessage.maximumNoteLength,
              SecureMessagingWirePolicy.isLowercaseSHA256(rosterFingerprint),
              SecureMessagingWirePolicy.isLowercaseSHA256(planHash),
              let scheduledDate,
              let expiryDate,
              scheduledDate > now,
              expiryDate > now,
              expiryDate < scheduledDate,
              stepUp.purpose == "scheduled_group_payment"
        else { return false }

        var recipientIDs: [String] = []
        var walletIDs: Set<String> = []
        var frozen: [String] = []
        var sum: Int64 = 0
        for recipient in recipients {
            guard ScheduledPaymentValidation.canonicalUUID(recipient.userId) == recipient.userId,
                  ScheduledPaymentValidation.canonicalUUID(recipient.destinationWalletId)
                    == recipient.destinationWalletId,
                  walletIDs.insert(recipient.destinationWalletId).inserted,
                  let amount = KitPaymentMessage.minorUnits(
                      for: recipient.amount,
                      scale: currency.decimalScale
                  ),
                  amount > 0
            else { return false }
            let (next, overflow) = sum.addingReportingOverflow(amount)
            guard !overflow, next <= KitGroupPaymentMessage.maximumAmountMinor else { return false }
            sum = next
            recipientIDs.append(recipient.userId)
            frozen.append("\(recipient.userId):\(recipient.destinationWalletId):\(amount)")
        }
        guard recipientIDs == recipientIDs.sorted(),
              Set(recipientIDs).count == recipientIDs.count,
              sum == total,
              frozen.joined(separator: ",") == frozenRecipients
        else { return false }

        let intent = stepUp.intent
        return intent.action == "create"
            && intent.planId == planId
            && intent.planHash == planHash
            && intent.conversationId == conversationId
            && intent.sourceWalletId == sourceWalletId
            && intent.splitMode == splitMode
            && intent.audience == audience
            && intent.totalAmount == totalAmount
            && intent.currency == currency.code
            && intent.note == note
            && intent.scheduledFor == scheduledFor
            && intent.rosterFingerprint == rosterFingerprint
            && intent.frozenRecipients == frozenRecipients
    }

    func matches(
        draft: CreateGroupPaymentBody,
        conversationID: String,
        wallet: Wallet,
        scheduledFor expectedDate: Date,
        allowedRecipientIDs: Set<String>,
        now: Date = Date()
    ) -> Bool {
        guard isStructurallyValid(now: now),
              conversationId == conversationID,
              sourceWalletId == wallet.id.lowercased(),
              currency == wallet.currency,
              splitMode == draft.splitMode,
              audience == draft.audience,
              note == draft.note,
              scheduledDate == expectedDate,
              recipients.allSatisfy({ allowedRecipientIDs.contains($0.userId) })
        else { return false }
        let previewIDs = recipients.map(\.userId)
        if draft.audience == GroupPaymentAudience.all.rawValue {
            guard Set(previewIDs) == allowedRecipientIDs else { return false }
        } else {
            guard let requested = draft.recipients,
                  Set(previewIDs) == Set(requested.map { $0.userId.lowercased() })
            else { return false }
            if draft.splitMode == GroupPaymentSplitMode.custom.rawValue {
                let amounts = Dictionary(uniqueKeysWithValues: recipients.map {
                    ($0.userId, $0.amount)
                })
                guard requested.allSatisfy({ recipient in
                    amounts[recipient.userId.lowercased()] == recipient.amount
                }) else { return false }
            }
        }
        return draft.totalAmount == nil || draft.totalAmount == totalAmount
    }
}

struct ScheduledGroupPaymentRecipientDTO: Decodable, Hashable, Identifiable, Sendable {
    let userId: String
    let name: String?
    let amount: String?

    enum CodingKeys: String, CodingKey {
        case name, amount
        case userId = "user_id"
    }

    var id: String { userId }
}

struct ScheduledGroupPaymentDTO: Decodable, Hashable, Identifiable, Sendable {
    let id: String
    let type: String
    let conversationId: String
    let status: String
    let sourceWalletId: String?
    let splitMode: String
    let audience: String
    let totalAmount: String?
    let currency: CurrencyDTO
    let note: String?
    let recipientCount: Int
    let recipients: [ScheduledGroupPaymentRecipientDTO]
    let groupPaymentId: String?
    let failure: ScheduledPaymentFailureDTO?
    let scheduledFor: String
    let queuedAt: String?
    let startedAt: String?
    let completedAt: String?
    let cancelledAt: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, type, status, audience, currency, note, recipients, failure
        case conversationId = "conversation_id"
        case sourceWalletId = "source_wallet_id"
        case splitMode = "split_mode"
        case totalAmount = "total_amount"
        case recipientCount = "recipient_count"
        case groupPaymentId = "group_payment_id"
        case scheduledFor = "scheduled_for"
        case queuedAt = "queued_at"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case cancelledAt = "cancelled_at"
        case createdAt = "created_at"
    }

    var knownStatus: ScheduledGroupPaymentStatus? { .init(rawValue: status) }
    var scheduledDate: Date? { ScheduledPaymentDates.parse(scheduledFor) }

    var isStructurallyValid: Bool {
        guard type == "scheduled_group_payment",
              ScheduledPaymentValidation.canonicalUUID(id) == id,
              ScheduledPaymentValidation.canonicalUUID(conversationId) == conversationId,
              sourceWalletId.map({ ScheduledPaymentValidation.canonicalUUID($0) == $0 }) ?? true,
              GroupPaymentSplitMode(rawValue: splitMode) != nil,
              GroupPaymentAudience(rawValue: audience) != nil,
              ScheduledPaymentValidation.isCurrencyCode(currency.code),
              (0 ... 6).contains(currency.decimalScale),
              let status = knownStatus,
              scheduledDate != nil,
              createdAt.flatMap(ScheduledPaymentDates.parse) != nil,
              (note?.utf16.count ?? 0) <= KitGroupPaymentMessage.maximumNoteLength,
              (1 ... GroupPaymentDraftPolicy.maximumRecipients).contains(recipientCount),
              recipients.count == recipientCount,
              Set(recipients.map(\.userId)).count == recipients.count,
              recipients.allSatisfy({ recipient in
                  guard ScheduledPaymentValidation.canonicalUUID(recipient.userId)
                    == recipient.userId else { return false }
                  // A recipient-scoped custom split legitimately redacts another member's
                  // amount with null. A present amount is never a redaction: malformed text
                  // must fail closed instead of falling through to a positive sentinel.
                  guard let amount = recipient.amount else { return true }
                  return KitPaymentMessage.minorUnits(
                      for: amount,
                      scale: currency.decimalScale
                  ).map({ $0 > 0 }) == true
              }),
              totalAmount.flatMap({
                  KitPaymentMessage.minorUnits(for: $0, scale: currency.decimalScale)
              }).map({ $0 > 0 }) ?? true,
              groupPaymentId.map({ ScheduledPaymentValidation.canonicalUUID($0) == $0 }) ?? true,
              failure.map(\.isStructurallyValid) ?? true,
              queuedAt.map({ ScheduledPaymentDates.parse($0) != nil }) ?? true,
              startedAt.map({ ScheduledPaymentDates.parse($0) != nil }) ?? true,
              completedAt.map({ ScheduledPaymentDates.parse($0) != nil }) ?? true,
              cancelledAt.map({ ScheduledPaymentDates.parse($0) != nil }) ?? true
        else { return false }
        if splitMode == GroupPaymentSplitMode.even.rawValue || sourceWalletId != nil {
            guard let totalText = totalAmount,
                  let total = KitPaymentMessage.minorUnits(
                      for: totalText,
                      scale: currency.decimalScale
                  )
            else { return false }
            var recipientTotal: Int64 = 0
            for recipient in recipients {
                guard let amountText = recipient.amount,
                      let amount = KitPaymentMessage.minorUnits(
                          for: amountText,
                          scale: currency.decimalScale
                      )
                else { return false }
                let (next, overflow) = recipientTotal.addingReportingOverflow(amount)
                guard !overflow else { return false }
                recipientTotal = next
            }
            guard recipientTotal == total else { return false }
        }
        switch status {
        case .scheduled:
            return sourceWalletId != nil && groupPaymentId == nil && failure == nil
                && queuedAt == nil && startedAt == nil && completedAt == nil && cancelledAt == nil
        case .queued:
            return sourceWalletId != nil && groupPaymentId == nil && failure == nil
                && queuedAt != nil && startedAt == nil && completedAt == nil && cancelledAt == nil
        case .processing:
            return sourceWalletId != nil && groupPaymentId == nil && failure == nil
                && queuedAt != nil && startedAt != nil && completedAt == nil && cancelledAt == nil
        case .completed:
            return groupPaymentId != nil && failure == nil && completedAt != nil
                && cancelledAt == nil
        case .failed:
            return sourceWalletId != nil && groupPaymentId == nil && failure != nil
                && completedAt != nil && cancelledAt == nil
        case .cancelled:
            return sourceWalletId != nil && groupPaymentId == nil && failure == nil
                && queuedAt == nil && startedAt == nil && completedAt == nil && cancelledAt != nil
        }
    }

    func matches(plan: ScheduledGroupPaymentPlanDTO) -> Bool {
        isStructurallyValid
            && knownStatus == .scheduled
            && conversationId == plan.conversationId
            && sourceWalletId == plan.sourceWalletId
            && splitMode == plan.splitMode
            && audience == plan.audience
            && totalAmount == plan.totalAmount
            && currency == plan.currency
            && note == plan.note
            && recipientCount == plan.recipientCount
            && scheduledDate == plan.scheduledDate
            && recipients.map(\.userId) == plan.recipients.map(\.userId)
            && recipients.map(\.amount) == plan.recipients.map { Optional($0.amount) }
    }
}

struct ScheduledGroupPaymentListDTO: Decodable, Sendable {
    let items: [ScheduledGroupPaymentDTO]
    let hasMore: Bool
    let nextBefore: String?

    enum CodingKeys: String, CodingKey {
        case items
        case hasMore = "has_more"
        case nextBefore = "next_before"
    }

    var isStructurallyValid: Bool {
        items.count <= 100
            && items.allSatisfy(\.isStructurallyValid)
            && (hasMore
                ? ScheduledPaymentValidation.canonicalUUID(nextBefore) != nil
                : nextBefore == nil)
    }
}

enum ScheduledGroupPaymentSyncAction: String, Equatable, Sendable {
    case completed
    case failed
    case cancelled

    init?(eventType: String) {
        guard eventType.hasPrefix("scheduled_group_payment.") else { return nil }
        self.init(rawValue: String(eventType.dropFirst("scheduled_group_payment.".count)))
    }
}

/// A content-minimal durable sync hint. It never creates a financial card by itself: callers
/// must exact-read the scheduled object and, for completion, the resulting group payment.
struct ScheduledGroupPaymentSyncEnvelope: Equatable, Sendable {
    let action: ScheduledGroupPaymentSyncAction
    let scheduledGroupPaymentID: String
    let conversationID: String
    let groupPaymentID: String?
    let scheduledAt: Date
    let occurredAt: Date

    init?(event: MessagingSyncEventDTO) {
        guard let eventType = event.type,
              let action = ScheduledGroupPaymentSyncAction(eventType: eventType),
              event.resourceType == "scheduled_group_payment",
              let data = event.data,
              data.schema == "kit.scheduled-group-payment.v1",
              let rawID = data.scheduledGroupPaymentId,
              let id = ScheduledPaymentValidation.canonicalUUID(rawID),
              rawID == id,
              event.resourceId == id,
              let rawConversationID = data.conversationId,
              let conversationID = ScheduledPaymentValidation.canonicalUUID(rawConversationID),
              rawConversationID == conversationID,
              event.conversationId == conversationID,
              data.status == action.rawValue,
              let scheduledAt = data.scheduledFor.flatMap(ScheduledPaymentDates.parse),
              let occurredAt = event.occurredAt.flatMap(ScheduledPaymentDates.parse)
        else { return nil }

        let groupPaymentID = data.groupPaymentId.flatMap(
            ScheduledPaymentValidation.canonicalUUID
        )
        switch action {
        case .completed:
            guard groupPaymentID != nil,
                  groupPaymentID == data.groupPaymentId,
                  data.completedAt.flatMap(ScheduledPaymentDates.parse) != nil,
                  data.cancelledAt == nil
            else { return nil }
        case .failed:
            guard data.groupPaymentId == nil,
                  data.completedAt.flatMap(ScheduledPaymentDates.parse) != nil,
                  data.cancelledAt == nil
            else { return nil }
        case .cancelled:
            guard data.groupPaymentId == nil,
                  data.completedAt == nil,
                  data.cancelledAt.flatMap(ScheduledPaymentDates.parse) != nil
            else { return nil }
        }
        self.action = action
        scheduledGroupPaymentID = id
        self.conversationID = conversationID
        self.groupPaymentID = groupPaymentID
        self.scheduledAt = scheduledAt
        self.occurredAt = occurredAt
    }

    func matchesAuthoritative(_ schedule: ScheduledGroupPaymentDTO) -> Bool {
        guard schedule.isStructurallyValid,
              schedule.id == scheduledGroupPaymentID,
              schedule.conversationId == conversationID,
              schedule.knownStatus?.rawValue == action.rawValue,
              schedule.groupPaymentId == groupPaymentID,
              schedule.scheduledDate == scheduledAt
        else { return false }
        switch action {
        case .completed:
            return schedule.completedAt.flatMap(ScheduledPaymentDates.parse) != nil
                && schedule.failure == nil
                && schedule.cancelledAt == nil
        case .failed:
            return schedule.completedAt.flatMap(ScheduledPaymentDates.parse) != nil
                && schedule.failure?.isStructurallyValid == true
                && schedule.cancelledAt == nil
        case .cancelled:
            return schedule.completedAt == nil
                && schedule.failure == nil
                && schedule.cancelledAt.flatMap(ScheduledPaymentDates.parse) != nil
        }
    }
}

enum ScheduledGroupPaymentProjectionPolicy {
    struct Completion: Equatable {
        let senderUserID: String
        let descriptor: KitGroupPaymentMessage
    }

    static func completion(
        envelope: ScheduledGroupPaymentSyncEnvelope,
        schedule: ScheduledGroupPaymentDTO,
        payment: GroupPaymentDTO,
        memberUserIDs: Set<String>
    ) -> Completion? {
        guard envelope.action == .completed,
              envelope.matchesAuthoritative(schedule),
              let groupPaymentID = envelope.groupPaymentID,
              payment.id.lowercased() == groupPaymentID,
              let senderUserID = GroupPaymentRequestValidation.canonicalUUID(payment.sender?.id),
              memberUserIDs.contains(senderUserID),
              GroupPaymentAuthorityPolicy.matchesContext(
                  payment,
                  conversationID: envelope.conversationID,
                  announcementSenderID: senderUserID
              ),
              payment.splitMode == schedule.splitMode,
              payment.audience == schedule.audience,
              payment.currency == schedule.currency,
              payment.recipientCount == schedule.recipientCount,
              payment.note == schedule.note,
              ["pending", "settled"].contains(payment.status),
              payment.pendingCount >= 0,
              payment.acceptedCount >= 0,
              payment.returnedCount >= 0,
              payment.pendingCount + payment.acceptedCount + payment.returnedCount
                == payment.recipientCount
        else { return nil }

        let scheduledRecipientIDs = schedule.recipients.map(\.userId)
        let paymentRecipientIDs = payment.recipients.compactMap {
            GroupPaymentRequestValidation.canonicalUUID($0.userId)
        }
        guard paymentRecipientIDs.count == payment.recipientCount,
              Set(paymentRecipientIDs) == Set(scheduledRecipientIDs),
              Set(scheduledRecipientIDs).isSubset(of: memberUserIDs),
              let descriptor = KitGroupPaymentMessage(
                  announcing: payment,
                  recipientUserIds: scheduledRecipientIDs
              ),
              descriptor.matchesAuthoritativePayment(payment)
        else { return nil }
        if schedule.splitMode == GroupPaymentSplitMode.even.rawValue {
            guard schedule.totalAmount == payment.totalAmount else { return nil }
        } else {
            guard schedule.totalAmount == nil || schedule.totalAmount == payment.totalAmount
            else { return nil }
        }
        return Completion(senderUserID: senderUserID, descriptor: descriptor)
    }

    static func deterministicMessageID(
        scheduledGroupPaymentID: String,
        groupPaymentID: String
    ) -> UUID {
        KitSystemMessage.deterministicMessageID(
            namespace: "scheduled-group-payment|\(scheduledGroupPaymentID)|\(groupPaymentID)"
        )
    }
}

enum KitScheduledGroupPaymentOutcomeAction: String, Equatable, Sendable {
    case failed
    case cancelled
}

/// Creator-only, server-authenticated terminal notice for a schedule that did not produce a
/// group payment. It carries no amount, wallet or server failure text, so it cannot expose money
/// data or turn an untrusted message into an action surface.
struct KitScheduledGroupPaymentOutcomeMessage: Equatable, Sendable {
    static let prefix = "KITSGRP1:"
    static let maximumDescriptorLength = 180

    let action: KitScheduledGroupPaymentOutcomeAction
    let scheduledGroupPaymentID: String
    let scheduledAt: Date

    init?(
        action: KitScheduledGroupPaymentOutcomeAction,
        scheduledGroupPaymentID: String,
        scheduledAt: Date
    ) {
        guard ScheduledPaymentValidation.canonicalUUID(scheduledGroupPaymentID)
                == scheduledGroupPaymentID,
              scheduledAt.timeIntervalSince1970.isFinite,
              scheduledAt.timeIntervalSince1970 >= 0
        else { return nil }
        self.action = action
        self.scheduledGroupPaymentID = scheduledGroupPaymentID
        self.scheduledAt = scheduledAt
        guard encoded.utf8.count <= Self.maximumDescriptorLength else { return nil }
    }

    var encoded: String {
        "\(Self.prefix)v=1&a=\(action.rawValue)&id=\(scheduledGroupPaymentID)&at=\(Int64(scheduledAt.timeIntervalSince1970))"
    }

    static func parse(_ text: String) -> Self? {
        guard text.hasPrefix(prefix), text.utf8.count <= maximumDescriptorLength else { return nil }
        var fields: [String: String] = [:]
        for pair in text.dropFirst(prefix.count).split(
            separator: "&",
            omittingEmptySubsequences: false
        ) {
            guard let separator = pair.firstIndex(of: "="), separator != pair.startIndex else {
                return nil
            }
            let key = String(pair[..<separator])
            let value = String(pair[pair.index(after: separator)...])
            guard fields[key] == nil else { return nil }
            fields[key] = value
        }
        guard fields["v"] == "1",
              let action = fields["a"].flatMap(
                  KitScheduledGroupPaymentOutcomeAction.init(rawValue:)
              ),
              let id = fields["id"],
              let seconds = fields["at"].flatMap(Int64.init),
              let value = Self(
                  action: action,
                  scheduledGroupPaymentID: id,
                  scheduledAt: Date(timeIntervalSince1970: TimeInterval(seconds))
              ),
              value.encoded == text
        else { return nil }
        return value
    }

    var deterministicMessageID: UUID {
        KitSystemMessage.deterministicMessageID(
            namespace: "scheduled-group-payment-outcome|\(scheduledGroupPaymentID)|\(action.rawValue)"
        )
    }

    func isTrustedProjection(_ message: LocalMessage) -> Bool {
        message.id == deterministicMessageID
            && message.serverMessageId == nil
            && message.secureMessagingHistory == nil
            && message.pendingAttachment == nil
            && message.pendingMediaBatch == nil
            && message.attachmentData == nil
            && message.failureReason == nil
            && message.scheduledAt == nil
            && message.isOutgoing
    }
}

struct GroupPaymentRequestPolicy: Equatable {
    let enabled: Bool

    init(capabilities: CapabilitiesDTO?) {
        enabled = capabilities?.supportsFeature("wallets") == true
            && capabilities?.supportsFeature("internal_transfers") == true
            && capabilities?.supportsFeature("group_payment_requests_v1") == true
            && capabilities?.protocols?.payments?.groupPaymentRequests?.supportsIOSV1 == true
    }
}

enum GroupPaymentRequestStatus: String, Codable, CaseIterable {
    case open
    case completed
    case cancelled
    case expired

    var isTerminal: Bool { self != .open }
}

struct GroupPaymentRequestContributionDTO: Decodable, Hashable, Identifiable {
    let id: String
    let contributorUserId: String
    let amount: String
    let amountMinor: String
    let walletTransactionId: String?
    let createdAt: String?
    let isYours: Bool

    enum CodingKeys: String, CodingKey {
        case id, amount
        case contributorUserId = "contributor_user_id"
        case amountMinor = "amount_minor"
        case walletTransactionId = "wallet_transaction_id"
        case createdAt = "created_at"
        case isYours = "is_yours"
    }

    var minorUnits: Int64? {
        GroupPaymentRequestValidation.canonicalMinorUnits(amountMinor)
    }

    func isStructurallyValid(currencyScale: Int) -> Bool {
        guard GroupPaymentRequestValidation.canonicalUUID(id) != nil,
              GroupPaymentRequestValidation.canonicalUUID(contributorUserId) != nil,
              let minorUnits,
              minorUnits > 0,
              minorUnits <= KitGroupPaymentMessage.maximumAmountMinor,
              amount == KitMoney.decimal(minorUnits: minorUnits, scale: currencyScale),
              walletTransactionId.map({ GroupPaymentRequestValidation.canonicalUUID($0) != nil })
                ?? true
        else { return false }
        return true
    }
}

struct GroupPaymentRequestDTO: Decodable, Hashable, Identifiable {
    let id: String
    let type: String
    let conversationId: String
    let requesterUserId: String
    let status: String
    let destinationWalletId: String?
    let targetAmount: String
    let targetAmountMinor: String
    let contributedAmount: String
    let contributedAmountMinor: String
    let remainingAmount: String
    let remainingAmountMinor: String
    let progressBasisPoints: Int
    /// Number of successful contribution rows. One member may contribute more than once.
    let contributionCount: Int
    /// Number of distinct members who have contributed at least once.
    let contributorCount: Int
    let yourContributedAmount: String
    let yourContributedAmountMinor: String
    let currency: CurrencyDTO
    let note: String?
    let expiresAt: String?
    let completedAt: String?
    let cancelledAt: String?
    let expiredAt: String?
    let createdAt: String?
    let updatedAt: String?
    let canContribute: Bool
    let canCancel: Bool
    /// The resource embeds only its newest bounded contribution window.
    let contributionsHasMore: Bool
    let contributionsNextBefore: String?
    let contributions: [GroupPaymentRequestContributionDTO]

    enum CodingKeys: String, CodingKey {
        case id, type, status, currency, note, contributions
        case conversationId = "conversation_id"
        case requesterUserId = "requester_user_id"
        case destinationWalletId = "destination_wallet_id"
        case targetAmount = "target_amount"
        case targetAmountMinor = "target_amount_minor"
        case contributedAmount = "contributed_amount"
        case contributedAmountMinor = "contributed_amount_minor"
        case remainingAmount = "remaining_amount"
        case remainingAmountMinor = "remaining_amount_minor"
        case progressBasisPoints = "progress_basis_points"
        case contributionCount = "contribution_count"
        case contributorCount = "contributor_count"
        case yourContributedAmount = "your_contributed_amount"
        case yourContributedAmountMinor = "your_contributed_amount_minor"
        case expiresAt = "expires_at"
        case completedAt = "completed_at"
        case cancelledAt = "cancelled_at"
        case expiredAt = "expired_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case canContribute = "can_contribute"
        case canCancel = "can_cancel"
        case contributionsHasMore = "contributions_has_more"
        case contributionsNextBefore = "contributions_next_before"
    }

    var knownStatus: GroupPaymentRequestStatus? { GroupPaymentRequestStatus(rawValue: status) }
    var currencyScale: Int { currency.decimalScale }
    var targetMinorUnits: Int64? {
        GroupPaymentRequestValidation.canonicalMinorUnits(targetAmountMinor)
    }
    var contributedMinorUnits: Int64? {
        GroupPaymentRequestValidation.canonicalMinorUnits(contributedAmountMinor)
    }
    var remainingMinorUnits: Int64? {
        GroupPaymentRequestValidation.canonicalMinorUnits(remainingAmountMinor)
    }

    var isStructurallyValid: Bool {
        let scale = currencyScale
        let contributionTotal = contributions.reduce(into: Int64(0)) { total, item in
            guard let amount = item.minorUnits,
                  !total.addingReportingOverflow(amount).overflow
            else {
                total = -1
                return
            }
            total += amount
        }
        guard type == "group_payment_request",
              GroupPaymentRequestValidation.canonicalUUID(id) != nil,
              GroupPaymentRequestValidation.canonicalUUID(conversationId) != nil,
              GroupPaymentRequestValidation.canonicalUUID(requesterUserId) != nil,
              destinationWalletId.map({ GroupPaymentRequestValidation.canonicalUUID($0) != nil })
                ?? true,
              let status = knownStatus,
              (0 ... 6).contains(scale),
              GroupPaymentRequestValidation.isCurrencyCode(currency.code),
              let target = targetMinorUnits,
              let contributed = contributedMinorUnits,
              let remaining = remainingMinorUnits,
              let yours = GroupPaymentRequestValidation.canonicalMinorUnits(
                  yourContributedAmountMinor
              ),
              target > 0,
              target <= KitGroupPaymentMessage.maximumAmountMinor,
              contributed >= 0,
              contributed <= target,
              remaining == target - contributed,
              yours >= 0,
              yours <= contributed,
              targetAmount == KitMoney.decimal(minorUnits: target, scale: scale),
              contributedAmount == KitMoney.decimal(minorUnits: contributed, scale: scale),
              remainingAmount == KitMoney.decimal(minorUnits: remaining, scale: scale),
              yourContributedAmount == KitMoney.decimal(minorUnits: yours, scale: scale),
              (0 ... 10_000).contains(progressBasisPoints),
              progressBasisPoints == GroupPaymentRequestValidation.progressBasisPoints(
                  contributed: contributed,
                  target: target
              ),
              contributionCount >= 0,
              contributorCount >= 0,
              contributorCount <= contributionCount,
              (note?.utf16.count ?? 0) <= KitGroupPaymentRequestMessage.maximumNoteLength,
              contributions.count == min(
                  contributionCount,
                  GroupPaymentRequestValidation.embeddedContributionLimit
              ),
              contributions.allSatisfy({ $0.isStructurallyValid(currencyScale: scale) }),
              contributionTotal >= 0,
              contributionTotal <= contributed,
              contributionsHasMore == (contributionCount > contributions.count),
              contributionsHasMore
                ? GroupPaymentRequestValidation.canonicalUUID(contributionsNextBefore)
                    == contributionsNextBefore
                : contributionsNextBefore == nil,
              contributionsHasMore
                ? contributions.first?.id == contributionsNextBefore
                : contributionTotal == contributed,
              Set(contributions.map { $0.id.lowercased() }).count == contributions.count,
              Set(contributions.map { $0.contributorUserId.lowercased() }).count
                <= contributorCount,
              contributionsHasMore
                || Set(contributions.map { $0.contributorUserId.lowercased() }).count
                    == contributorCount,
              status != .completed || remaining == 0,
              status != .completed || contributionCount > 0,
              status != .open || remaining > 0,
              canContribute == false || (status == .open && remaining > 0),
              canCancel == false || status == .open
        else { return false }
        return true
    }
}

struct GroupPaymentRequestListDTO: Decodable {
    let items: [GroupPaymentRequestDTO]
}

struct GroupPaymentRequestContributionListDTO: Decodable, Equatable {
    let items: [GroupPaymentRequestContributionDTO]
    let hasMore: Bool
    let nextBefore: String?

    enum CodingKeys: String, CodingKey {
        case items
        case hasMore = "has_more"
        case nextBefore = "next_before"
    }

    func isStructurallyValid(currencyScale: Int, limit: Int) -> Bool {
        (1 ... 100).contains(limit)
            && items.count <= limit
            && items.allSatisfy({ $0.isStructurallyValid(currencyScale: currencyScale) })
            && Set(items.map { $0.id.lowercased() }).count == items.count
            && (hasMore
                ? GroupPaymentRequestValidation.canonicalUUID(nextBefore) == nextBefore
                : nextBefore == nil)
    }
}

struct GroupPaymentRequestContributionReference: Hashable, Sendable {
    let requestID: String
    let contributionID: String
    /// Completion attribution must come from the request-scoped exact endpoint, even when the
    /// bounded request response happens to embed a row with the same identifier.
    let requiresExactRead: Bool
}

struct GroupPaymentRequestContributionResultDTO: Decodable {
    let request: GroupPaymentRequestDTO
    let contribution: GroupPaymentRequestContributionDTO

    var isStructurallyValid: Bool {
        request.isStructurallyValid
            && contribution.isStructurallyValid(currencyScale: request.currencyScale)
            && request.contributions.contains(contribution)
    }
}

struct CreateGroupPaymentRequestBody: Encodable, Equatable {
    let destinationWalletId: String
    let totalAmount: String
    let note: String?
    let expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case destinationWalletId = "destination_wallet_id"
        case totalAmount = "total_amount"
        case note
        case expiresAt = "expires_at"
    }
}

struct ContributeGroupPaymentRequestBody: Encodable, Equatable {
    let sourceWalletId: String
    let amount: String

    enum CodingKeys: String, CodingKey {
        case sourceWalletId = "source_wallet_id"
        case amount
    }
}

enum GroupPaymentRequestValidation {
    static let embeddedContributionLimit = 50

    static func canonicalUUID(_ raw: String?) -> String? {
        guard let raw,
              raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
              let uuid = UUID(uuidString: raw)
        else { return nil }
        return uuid.uuidString.lowercased()
    }

    static func canonicalMinorUnits(_ raw: String) -> Int64? {
        guard !raw.isEmpty,
              raw.utf8.allSatisfy({ (48 ... 57).contains($0) }),
              raw == "0" || raw.first != "0",
              let value = Int64(raw),
              value >= 0
        else { return nil }
        return value
    }

    static func isCurrencyCode(_ raw: String) -> Bool {
        raw.range(of: #"^[A-Z]{3}$"#, options: .regularExpression) != nil
    }

    static func progressBasisPoints(contributed: Int64, target: Int64) -> Int {
        guard target > 0, contributed > 0 else { return 0 }
        guard contributed < target else { return 10_000 }
        return Int((contributed * 10_000) / target)
    }
}

enum GroupPaymentRequestAuthorityPolicy {
    static func matchesContext(
        _ request: GroupPaymentRequestDTO,
        conversationID: String,
        announcementSenderID: String
    ) -> Bool {
        guard request.isStructurallyValid,
              let actualConversation = GroupPaymentRequestValidation.canonicalUUID(
                  request.conversationId
              ),
              let expectedConversation = GroupPaymentRequestValidation.canonicalUUID(
                  conversationID
              ),
              let requester = GroupPaymentRequestValidation.canonicalUUID(request.requesterUserId),
              let author = GroupPaymentRequestValidation.canonicalUUID(announcementSenderID)
        else { return false }
        return actualConversation == expectedConversation && requester == author
    }

    static func matchingContribution(
        for descriptor: KitGroupPaymentRequestMessage,
        in request: GroupPaymentRequestDTO,
        messageAuthorID: String,
        exactContribution: GroupPaymentRequestContributionDTO? = nil
    ) -> GroupPaymentRequestContributionDTO? {
        let embeddedContribution = descriptor.contributionID.flatMap { contributionID in
            request.contributions.first {
                $0.id.caseInsensitiveCompare(contributionID) == .orderedSame
            }
        }
        let candidate = descriptor.action == .completed
            ? exactContribution
            : embeddedContribution ?? exactContribution
        guard descriptor.action == .contributed || descriptor.action == .completed,
              descriptor.matchesAuthoritativeRequest(request),
              let contributionID = descriptor.contributionID,
              let author = GroupPaymentRequestValidation.canonicalUUID(messageAuthorID),
              let contribution = candidate,
              contribution.id.caseInsensitiveCompare(contributionID) == .orderedSame,
              contribution.isStructurallyValid(currencyScale: request.currencyScale),
              GroupPaymentRequestValidation.canonicalUUID(contribution.contributorUserId) == author,
              contribution.minorUnits == descriptor.amountMinor
        else { return nil }
        return contribution
    }

    static func terminalEventMatches(
        _ descriptor: KitGroupPaymentRequestMessage,
        request: GroupPaymentRequestDTO,
        messageAuthorID: String,
        exactContribution: GroupPaymentRequestContributionDTO? = nil
    ) -> Bool {
        guard descriptor.matchesAuthoritativeRequest(request),
              let author = GroupPaymentRequestValidation.canonicalUUID(messageAuthorID),
              let requester = GroupPaymentRequestValidation.canonicalUUID(request.requesterUserId)
        else { return false }
        switch descriptor.action {
        case .cancelled, .expired:
            return author == requester
        case .completed:
            // The embedded list is a bounded presentation window, not completion authority.
            // Require the exact request-scoped contribution read named by the signed server event.
            return matchingContribution(
                for: descriptor,
                in: request,
                messageAuthorID: author,
                exactContribution: exactContribution
            ) != nil
        case .requested, .contributed:
            return false
        }
    }
}

enum KitGroupPaymentRequestMessageAction: String, Equatable, Sendable, CaseIterable {
    case requested
    case contributed
    case completed
    case cancelled
    case expired
}

/// Canonical optional E2EE rendering hint for the authoritative group-payment-request resource.
/// It intentionally carries no wallet or transaction identifiers. Every live action re-reads the
/// API object; this descriptor can make a card discoverable, never make money move by itself.
struct KitGroupPaymentRequestMessage: Equatable, Sendable {
    static let prefix = "KITGREQ1:"
    static let maximumDescriptorLength = 2_048
    static let maximumNoteLength = 280

    let action: KitGroupPaymentRequestMessageAction
    let requestID: String
    let contributionID: String?
    let amountMinor: Int64?
    let currencyCode: String?
    let currencyScale: Int?
    let note: String?

    init?(
        action: KitGroupPaymentRequestMessageAction,
        requestID: String,
        contributionID: String? = nil,
        amountMinor: Int64? = nil,
        currencyCode: String? = nil,
        currencyScale: Int? = nil,
        note: String? = nil
    ) {
        guard let requestID = GroupPaymentRequestValidation.canonicalUUID(requestID) else {
            return nil
        }
        let contributionID = contributionID.flatMap {
            GroupPaymentRequestValidation.canonicalUUID($0)
        }
        let normalizedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalNote = normalizedNote?.isEmpty == false ? normalizedNote : nil

        switch action {
        case .requested:
            guard contributionID == nil,
                  let amountMinor,
                  (1 ... KitGroupPaymentMessage.maximumAmountMinor).contains(amountMinor),
                  let currencyCode,
                  GroupPaymentRequestValidation.isCurrencyCode(currencyCode),
                  let currencyScale,
                  (0 ... 6).contains(currencyScale),
                  (finalNote?.utf16.count ?? 0) <= Self.maximumNoteLength
            else { return nil }
        case .contributed, .completed:
            guard contributionID != nil,
                  let amountMinor,
                  (1 ... KitGroupPaymentMessage.maximumAmountMinor).contains(amountMinor),
                  currencyCode == nil,
                  currencyScale == nil,
                  finalNote == nil
            else { return nil }
        case .cancelled, .expired:
            guard contributionID == nil,
                  amountMinor == nil,
                  currencyCode == nil,
                  currencyScale == nil,
                  finalNote == nil
            else { return nil }
        }

        self.action = action
        self.requestID = requestID
        self.contributionID = contributionID
        self.amountMinor = amountMinor
        self.currencyCode = currencyCode
        self.currencyScale = currencyScale
        self.note = finalNote
        guard encoded.utf8.count <= Self.maximumDescriptorLength else { return nil }
    }

    init?(requesting request: GroupPaymentRequestDTO) {
        guard request.isStructurallyValid,
              let amount = request.targetMinorUnits
        else { return nil }
        self.init(
            action: .requested,
            requestID: request.id,
            amountMinor: amount,
            currencyCode: request.currency.code,
            currencyScale: request.currencyScale,
            note: request.note
        )
    }

    init?(
        contributing contribution: GroupPaymentRequestContributionDTO,
        requestID: String
    ) {
        guard let amount = contribution.minorUnits else { return nil }
        self.init(
            action: .contributed,
            requestID: requestID,
            contributionID: contribution.id,
            amountMinor: amount
        )
    }

    init?(
        completing contribution: GroupPaymentRequestContributionDTO,
        requestID: String
    ) {
        guard let amount = contribution.minorUnits else { return nil }
        self.init(
            action: .completed,
            requestID: requestID,
            contributionID: contribution.id,
            amountMinor: amount
        )
    }

    init?(terminal action: KitGroupPaymentRequestMessageAction, requestID: String) {
        guard [.cancelled, .expired].contains(action) else { return nil }
        self.init(action: action, requestID: requestID)
    }

    var encoded: String {
        var value = Self.prefix + "v=1&a=\(action.rawValue)&id=\(requestID)"
        if let contributionID { value += "&cid=\(contributionID)" }
        if let amountMinor { value += "&amt=\(amountMinor)" }
        if let currencyCode { value += "&cur=\(currencyCode)" }
        if let currencyScale { value += "&sc=\(currencyScale)" }
        if let note { value += "&note=\(Self.percentEncode(note))" }
        return value
    }

    static func isGroupPaymentRequestText(_ text: String) -> Bool { text.hasPrefix(prefix) }

    static func parse(_ text: String) -> KitGroupPaymentRequestMessage? {
        guard text.hasPrefix(prefix), text.utf8.count <= maximumDescriptorLength else { return nil }
        var fields: [String: String] = [:]
        for pair in text.dropFirst(prefix.count).split(
            separator: "&",
            omittingEmptySubsequences: false
        ) {
            guard let separator = pair.firstIndex(of: "="), separator != pair.startIndex else {
                return nil
            }
            let key = String(pair[..<separator])
            let raw = String(pair[pair.index(after: separator)...])
            guard fields[key] == nil, let value = Self.percentDecode(raw) else { return nil }
            fields[key] = value
        }
        guard fields["v"] == "1",
              let action = fields["a"].flatMap(KitGroupPaymentRequestMessageAction.init(rawValue:)),
              let requestID = fields["id"],
              let descriptor = KitGroupPaymentRequestMessage(
                  action: action,
                  requestID: requestID,
                  contributionID: fields["cid"],
                  amountMinor: fields["amt"].flatMap(Int64.init),
                  currencyCode: fields["cur"],
                  currencyScale: fields["sc"].flatMap(Int.init),
                  note: fields["note"]
              ),
              descriptor.encoded == text
        else { return nil }
        return descriptor
    }

    func matchesAuthoritativeRequest(_ request: GroupPaymentRequestDTO) -> Bool {
        guard request.isStructurallyValid,
              request.id.caseInsensitiveCompare(requestID) == .orderedSame
        else { return false }
        switch action {
        case .requested:
            return request.targetMinorUnits == amountMinor
                && request.currency.code == currencyCode
                && request.currencyScale == currencyScale
                && request.note == note
        case .contributed:
            guard let contributionID, let amountMinor else { return false }
            return request.contributions.contains {
                $0.id.caseInsensitiveCompare(contributionID) == .orderedSame
                    && $0.minorUnits == amountMinor
            }
        case .completed:
            return request.knownStatus == .completed
                && request.remainingMinorUnits == 0
        case .cancelled:
            return request.knownStatus == .cancelled
        case .expired:
            return request.knownStatus == .expired
        }
    }

    static func deterministicMessageID(
        requestID: String,
        action: KitGroupPaymentRequestMessageAction,
        contributionID: String? = nil,
        actorUserID: String
    ) -> UUID {
        KitSystemMessage.deterministicMessageID(
            namespace: [
                "group-payment-request",
                requestID.lowercased(),
                action.rawValue,
                contributionID?.lowercased() ?? "none",
                actorUserID.lowercased(),
            ].joined(separator: "|")
        )
    }

    private static func percentEncode(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private static func percentDecode(_ value: String) -> String? {
        guard !value.contains("+") else { return nil }
        return value.removingPercentEncoding
    }
}

enum GroupPaymentRequestProjectionSource: Sendable {
    case encryptedDescriptor
    case authoritativeFinancialEvent
}

enum GroupPaymentRequestProjectionDisposition: Equatable, Sendable {
    case notAGroupPaymentRequest
    case inserted
    case coalesced
}

/// Gives the optional encrypted `KITGREQ1` hint and the authoritative financial sync row one
/// durable identity. A financial projection always wins when the bodies disagree; this prevents
/// arrival order, history restoration, or a peer-authored contradictory hint from changing the
/// payment card that survives locally.
enum GroupPaymentRequestProjectionCoalescingPolicy {
    private struct Identity: Hashable {
        let conversationID: String
        let actorUserID: String
        let requestID: String
        let action: String
        let contributionID: String?
    }

    static func sameEvent(_ lhs: LocalMessage, _ rhs: LocalMessage) -> Bool {
        guard let left = identity(for: lhs), let right = identity(for: rhs) else { return false }
        return left == right
    }

    static func isAuthoritativeFinancialProjection(_ message: LocalMessage) -> Bool {
        guard let descriptor = KitGroupPaymentRequestMessage.parse(message.body),
              let actorUserID = GroupPaymentRequestValidation.canonicalUUID(message.senderId),
              message.id == KitGroupPaymentRequestMessage.deterministicMessageID(
                  requestID: descriptor.requestID,
                  action: descriptor.action,
                  contributionID: descriptor.contributionID,
                  actorUserID: actorUserID
              ),
              message.serverMessageId == nil,
              message.secureMessagingHistory == nil,
              message.failureReason == nil,
              message.pendingAttachment == nil,
              message.pendingMediaBatch == nil,
              message.attachmentData == nil,
              message.replyToServerMessageID == nil,
              message.scheduledAt == nil
        else { return false }
        return message.state == .sent || message.state == .received
    }

    @discardableResult
    static func reconcile(
        _ candidate: LocalMessage,
        source: GroupPaymentRequestProjectionSource,
        into messages: inout [LocalMessage]
    ) -> GroupPaymentRequestProjectionDisposition {
        guard let candidateIdentity = identity(for: candidate) else {
            return .notAGroupPaymentRequest
        }
        let matchingIndices = messages.indices.filter {
            identity(for: messages[$0]) == candidateIdentity
        }
        guard let insertionIndex = matchingIndices.first else {
            messages.append(candidate)
            return .inserted
        }

        let winner: LocalMessage
        switch source {
        case .authoritativeFinancialEvent:
            winner = candidate
        case .encryptedDescriptor:
            if let authoritative = matchingIndices
                .map({ messages[$0] })
                .first(where: isAuthoritativeFinancialProjection) {
                winner = authoritative
            } else {
                winner = (matchingIndices.map({ messages[$0] }) + [candidate])
                    .sorted(by: descriptorComesBefore)
                    .first ?? candidate
            }
        }

        messages[insertionIndex] = winner
        for index in matchingIndices.dropFirst().reversed() {
            messages.remove(at: index)
        }
        return .coalesced
    }

    static func coalescedForTimeline(_ messages: [LocalMessage]) -> [LocalMessage] {
        var result: [LocalMessage] = []
        result.reserveCapacity(messages.count)
        for message in messages {
            guard identity(for: message) != nil else {
                result.append(message)
                continue
            }
            let source: GroupPaymentRequestProjectionSource =
                isAuthoritativeFinancialProjection(message)
                    ? .authoritativeFinancialEvent
                    : .encryptedDescriptor
            _ = reconcile(message, source: source, into: &result)
        }
        return result
    }

    private static func identity(for message: LocalMessage) -> Identity? {
        guard let conversationID = GroupPaymentRequestValidation.canonicalUUID(
            message.conversationId
        ),
              let actorUserID = GroupPaymentRequestValidation.canonicalUUID(message.senderId),
              let descriptor = KitGroupPaymentRequestMessage.parse(message.body)
        else { return nil }
        return Identity(
            conversationID: conversationID,
            actorUserID: actorUserID,
            requestID: descriptor.requestID,
            action: descriptor.action.rawValue,
            contributionID: descriptor.contributionID
        )
    }

    private static func descriptorComesBefore(_ lhs: LocalMessage, _ rhs: LocalMessage) -> Bool {
        let left = descriptorOrderKey(lhs)
        let right = descriptorOrderKey(rhs)
        if left.authenticated != right.authenticated {
            return left.authenticated && !right.authenticated
        }
        if left.serverID != right.serverID { return left.serverID < right.serverID }
        if left.body != right.body { return left.body < right.body }
        return left.localID < right.localID
    }

    private static func descriptorOrderKey(
        _ message: LocalMessage
    ) -> (authenticated: Bool, serverID: String, body: String, localID: String) {
        (
            authenticated: message.serverMessageId != nil
                && message.secureMessagingHistory != nil,
            serverID: message.serverMessageId ?? "~",
            body: message.body,
            localID: message.id.uuidString.lowercased()
        )
    }
}

enum GroupPaymentRequestDraftPolicy {
    enum Outcome: Equatable {
        case ready(CreateGroupPaymentRequestBody)
        case problem(String)
    }

    static func draft(
        destinationWalletID: String,
        amountInput: String,
        note: String?,
        expiresAt: Date?,
        currencyScale: Int,
        now: Date = Date()
    ) -> Outcome {
        guard GroupPaymentRequestValidation.canonicalUUID(destinationWalletID) != nil else {
            return .problem("Choose an active wallet for this request.")
        }
        guard let amount = KitPaymentMessage.minorUnits(
            for: amountInput.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: ",", with: ""),
            scale: currencyScale
        ), amount <= KitGroupPaymentMessage.maximumAmountMinor else {
            return .problem("Enter the total amount you want the group to contribute.")
        }
        let cleanNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (cleanNote?.utf16.count ?? 0) <= KitGroupPaymentRequestMessage.maximumNoteLength else {
            return .problem("Keep the note within 280 characters.")
        }
        if let expiresAt {
            guard expiresAt > now,
                  expiresAt <= now.addingTimeInterval(90 * 24 * 60 * 60)
            else { return .problem("Choose an expiry within the next 90 days.") }
        }
        return .ready(
            CreateGroupPaymentRequestBody(
                destinationWalletId: destinationWalletID.lowercased(),
                totalAmount: KitMoney.decimal(minorUnits: amount, scale: currencyScale),
                note: cleanNote?.isEmpty == false ? cleanNote : nil,
                expiresAt: expiresAt.map(GroupPaymentRequestDates.apiString)
            )
        )
    }

    static func boundedNoteInput(_ raw: String) -> String {
        var result = ""
        for character in raw {
            let next = String(character)
            guard result.utf16.count + next.utf16.count
                    <= KitGroupPaymentRequestMessage.maximumNoteLength
            else { break }
            result.append(character)
        }
        return result
    }
}

enum GroupPaymentRequestContributionPolicy {
    static let purpose = "group_payment_request_contribution"

    static func canonicalAmount(
        _ input: String,
        request: GroupPaymentRequestDTO,
        wallet: Wallet
    ) -> String? {
        guard request.isStructurallyValid,
              request.knownStatus == .open,
              request.canContribute,
              wallet.status == "active",
              wallet.currency == request.currency,
              let remaining = request.remainingMinorUnits,
              let available = KitPaymentMessage.minorUnits(
                  for: wallet.balances.available,
                  scale: request.currencyScale
              ),
              let amount = KitPaymentMessage.minorUnits(
                  for: input,
                  scale: request.currencyScale
              ),
              amount <= remaining,
              amount <= available
        else { return nil }
        return KitMoney.decimal(minorUnits: amount, scale: request.currencyScale)
    }

    static func intent(
        requestID: String,
        sourceWalletID: String,
        amount: String,
        currencyCode: String
    ) -> [String: String?] {
        [
            "action": "contribute",
            "group_payment_request_id": requestID,
            "source_wallet_id": sourceWalletID,
            "amount": amount,
            "currency": currencyCode,
        ]
    }
}

enum GroupPaymentRequestDates {
    private static let formatter: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter()
        value.formatOptions = [.withInternetDateTime]
        return value
    }()

    static func apiString(_ date: Date) -> String { formatter.string(from: date) }
}
