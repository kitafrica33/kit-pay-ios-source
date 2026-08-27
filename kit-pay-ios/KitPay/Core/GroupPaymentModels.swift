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

struct CreateGroupPaymentBody: Encodable {
    let sourceWalletId: String
    let splitMode: String
    let audience: String
    let totalAmount: String?
    let note: String?
    let recipients: [Recipient]?

    struct Recipient: Encodable, Equatable {
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
            guard let total = KitPaymentMessage.minorUnits(for: totalInput, scale: scale),
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
                      let minor = KitPaymentMessage.minorUnits(for: raw, scale: scale),
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
            return KitPaymentMessage.minorUnits(for: totalInput, scale: scale)
        case .custom:
            var total: Int64 = 0
            for member in selected {
                guard let raw = customAmounts[member.userId],
                      let minor = KitPaymentMessage.minorUnits(for: raw, scale: scale),
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
