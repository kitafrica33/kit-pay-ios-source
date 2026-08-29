import Foundation

/// Client-side pins of the referral program wire contract (backend `openapi.yaml`,
/// `ReferralController`). Everything that decides or moves money is SERVER-owned: this client
/// renders the server's program terms, statuses, and amounts verbatim and never computes
/// qualification, deadlines, or payouts itself. Anything the payload gets wrong fails the decode
/// closed instead of being guessed at.
enum ReferralContract {
    /// The exact capability key. The entire surface — entry row included — is dark unless
    /// `features["referrals"] == true`; the server advertises it only while the feature flag is
    /// on AND a policy version is currently active.
    static let capabilityKey = "referrals"

    /// The CLOSED set of coarse public statuses. The backend deliberately collapses every
    /// internal state (manual review, payout mechanics, future additions) into these six, so a
    /// value outside this set is a contract break, not a new feature — the decode fails closed.
    static let statusPending = "pending"
    static let statusQualified = "qualified"
    static let statusPaid = "paid"
    static let statusExpired = "expired"
    static let statusNotEligible = "not_eligible"
    static let statusReversed = "reversed"
    static let knownStatuses: Set<String> = [
        statusPending, statusQualified, statusPaid,
        statusExpired, statusNotEligible, statusReversed,
    ]

    static let codeMaximumLength = 64
    static let shareURLMaximumLength = 512
    static let referredNameMaximumLength = 80
    static let identifierMaximumLength = 64
    static let timestampMaximumLength = 64
    static let amountMaximumLength = 40
    static let currencyScaleRange = 0...9
    /// The server caps the list itself; a longer one is incoherent.
    static let maximumListItems = 100
    /// Sanity ceiling for the policy's day counts — generous for any plausible program,
    /// tight enough that a corrupt payload can't render absurd terms as policy copy.
    static let policyDaysRange = 1...3650

    /// The bare capability check. Exact `true` only — absent, `null`, or `false` all read as
    /// unavailable.
    static func available(features: [String: Bool?]?) -> Bool {
        features?[capabilityKey] == true
    }

    /// Server-formatted decimal money strings ("25000.00", "0.50", "123"): bounded, ASCII
    /// digits, at most one dot, no empty whole or fraction part. Never negative — a negative
    /// reward or threshold is incoherent on this surface.
    static func isCoherentDisplayAmount(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= amountMaximumLength else { return false }
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count <= 2 else { return false }
        return pieces.allSatisfy { piece in
            !piece.isEmpty && piece.allSatisfy { $0.isASCII && $0.isNumber }
        }
    }

    /// Exactly three ASCII uppercase letters, per the contract's `^[A-Z]{3}$`.
    static func isCoherentCurrencyCode(_ code: String) -> Bool {
        code.count == 3 && code.allSatisfy { $0.isASCII && $0.isLetter && $0.isUppercase }
    }

    static func isBoundedServerText(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.count <= maximum
    }
}

/// Typed gate for every referral surface. Referrals carry no `protocols` block (the server
/// collapses "flag on AND active policy" into the single advertised capability), so the gate is
/// exactly that flag — routed through one predicate so the rule lives in one place and unknown
/// or absent capabilities fail closed.
enum ReferralGateState: Equatable, Sendable {
    case unavailable
    case available

    var isAvailable: Bool { self == .available }
}

enum ReferralGate {
    static func state(for capabilities: CapabilitiesDTO?) -> ReferralGateState {
        state(features: capabilities?.features)
    }

    static func state(features: [String: Bool?]?) -> ReferralGateState {
        ReferralContract.available(features: features) ? .available : .unavailable
    }
}

enum ReferralContractError: LocalizedError, Equatable {
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Inviting friends isn't available right now. Please try again later."
        }
    }
}

/// Server-formatted money: a display-ready decimal string plus the currency it was expanded
/// with. Decode-only on purpose — the client never sends referral money anywhere.
struct ReferralMoneyDTO: Decodable, Equatable, Hashable, Sendable {
    let amount: String
    let currencyCode: String
    let currencyScale: Int

    private enum CodingKeys: String, CodingKey {
        case amount
        case currency
    }

    private enum CurrencyKeys: String, CodingKey {
        case code
        case scale
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let amount = try container.decode(String.self, forKey: .amount)
        let currency = try container.nestedContainer(
            keyedBy: CurrencyKeys.self,
            forKey: .currency
        )
        let code = try currency.decode(String.self, forKey: .code)
        let scaleText = try currency.decode(String.self, forKey: .scale)
        guard ReferralContract.isCoherentDisplayAmount(amount),
              ReferralContract.isCoherentCurrencyCode(code),
              let scale = Int(scaleText),
              ReferralContract.currencyScaleRange.contains(scale)
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .amount,
                in: container,
                debugDescription: "Incoherent referral money payload."
            )
        }
        self.amount = amount
        self.currencyCode = code
        self.currencyScale = scale
    }
}

/// Terms of the currently active policy version — the ONLY source of the program copy the
/// screen renders (reward, threshold, business days, window). Nothing here is ever hardcoded
/// client-side.
struct ReferralProgramTermsDTO: Decodable, Equatable, Hashable, Sendable {
    let reward: ReferralMoneyDTO
    let qualifyingBalance: ReferralMoneyDTO
    let qualifyingBusinessDays: Int
    let windowDays: Int

    private enum CodingKeys: String, CodingKey {
        case reward
        case qualifyingBalance = "qualifying_balance"
        case qualifyingBusinessDays = "qualifying_business_days"
        case windowDays = "window_days"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reward = try container.decode(ReferralMoneyDTO.self, forKey: .reward)
        qualifyingBalance = try container.decode(
            ReferralMoneyDTO.self,
            forKey: .qualifyingBalance
        )
        qualifyingBusinessDays = try container.decode(Int.self, forKey: .qualifyingBusinessDays)
        windowDays = try container.decode(Int.self, forKey: .windowDays)
        guard ReferralContract.policyDaysRange.contains(qualifyingBusinessDays),
              ReferralContract.policyDaysRange.contains(windowDays)
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .windowDays,
                in: container,
                debugDescription: "Incoherent referral program terms."
            )
        }
    }
}

/// The caller's shareable code and its canonical link. The link is what leaves the app, so it
/// must parse as a real HTTPS URL with a host — anything else fails closed before it can be
/// copied or shared.
struct ReferralShareCodeDTO: Decodable, Equatable, Hashable, Sendable {
    let code: String
    let shareURL: URL

    private enum CodingKeys: String, CodingKey {
        case code
        case shareURL = "share_url"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let code = try container.decode(String.self, forKey: .code)
        let rawURL = try container.decode(String.self, forKey: .shareURL)
        guard ReferralContract.isBoundedServerText(
                  code,
                  maximum: ReferralContract.codeMaximumLength
              ),
              ReferralContract.isBoundedServerText(
                  rawURL,
                  maximum: ReferralContract.shareURLMaximumLength
              ),
              let url = URL(string: rawURL),
              url.scheme == "https",
              let host = url.host(percentEncoded: false),
              !host.isEmpty
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .shareURL,
                in: container,
                debugDescription: "Incoherent referral share code payload."
            )
        }
        self.code = code
        shareURL = url
    }
}

/// One referred person, exactly as coarse as the server presents it: display name (the only
/// detail exposed about them), a status from the closed public set, the pinned reward, and the
/// two timestamps. No balances, no review detail, no payout mechanics.
struct ReferralListItemDTO: Decodable, Equatable, Hashable, Identifiable, Sendable {
    let id: String
    let referredName: String?
    let status: String
    let reward: ReferralMoneyDTO
    let attributedAt: String
    let paidAt: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case referredName = "referred_name"
        case status
        case reward
        case attributedAt = "attributed_at"
        case paidAt = "paid_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        referredName = try container.decodeIfPresent(String.self, forKey: .referredName)
        status = try container.decode(String.self, forKey: .status)
        reward = try container.decode(ReferralMoneyDTO.self, forKey: .reward)
        attributedAt = try container.decode(String.self, forKey: .attributedAt)
        paidAt = try container.decodeIfPresent(String.self, forKey: .paidAt)
        guard ReferralContract.isBoundedServerText(
                  id,
                  maximum: ReferralContract.identifierMaximumLength
              ),
              UUID(uuidString: id) != nil,
              ReferralContract.knownStatuses.contains(status),
              referredName.map({
                  ReferralContract.isBoundedServerText(
                      $0,
                      maximum: ReferralContract.referredNameMaximumLength
                  )
              }) ?? true,
              ReferralContract.isBoundedServerText(
                  attributedAt,
                  maximum: ReferralContract.timestampMaximumLength
              ),
              paidAt.map({
                  ReferralContract.isBoundedServerText(
                      $0,
                      maximum: ReferralContract.timestampMaximumLength
                  )
              }) ?? true
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .status,
                in: container,
                debugDescription: "Incoherent referral list item."
            )
        }
    }
}

/// The six public buckets plus the grand total. The server computes the total over the same
/// rows it buckets, so `total` must equal the bucket sum — a payload where it doesn't is
/// contradictory and is rejected rather than displayed.
struct ReferralTotalsDTO: Decodable, Equatable, Hashable, Sendable {
    let total: Int
    let pending: Int
    let qualified: Int
    let paid: Int
    let expired: Int
    let notEligible: Int
    let reversed: Int

    private enum CodingKeys: String, CodingKey {
        case total
        case pending
        case qualified
        case paid
        case expired
        case notEligible = "not_eligible"
        case reversed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        total = try container.decode(Int.self, forKey: .total)
        pending = try container.decode(Int.self, forKey: .pending)
        qualified = try container.decode(Int.self, forKey: .qualified)
        paid = try container.decode(Int.self, forKey: .paid)
        expired = try container.decode(Int.self, forKey: .expired)
        notEligible = try container.decode(Int.self, forKey: .notEligible)
        reversed = try container.decode(Int.self, forKey: .reversed)
        let buckets = [pending, qualified, paid, expired, notEligible, reversed]
        guard buckets.allSatisfy({ $0 >= 0 }),
              total == buckets.reduce(0, +)
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .total,
                in: container,
                debugDescription: "Incoherent referral totals."
            )
        }
    }
}

/// The whole `GET /referrals` payload. `program` is null whenever no policy version is active;
/// `code` is null until the caller first requests one. The row list is bounded and its ids are
/// unique — duplicates would silently corrupt list identity.
struct ReferralOverviewDTO: Decodable, Equatable, Sendable {
    let program: ReferralProgramTermsDTO?
    let code: ReferralShareCodeDTO?
    let referrals: [ReferralListItemDTO]
    let totals: ReferralTotalsDTO

    private enum CodingKeys: String, CodingKey {
        case program
        case code
        case referrals
        case totals
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        program = try container.decodeIfPresent(ReferralProgramTermsDTO.self, forKey: .program)
        code = try container.decodeIfPresent(ReferralShareCodeDTO.self, forKey: .code)
        referrals = try container.decode([ReferralListItemDTO].self, forKey: .referrals)
        totals = try container.decode(ReferralTotalsDTO.self, forKey: .totals)
        guard referrals.count <= ReferralContract.maximumListItems,
              Set(referrals.map(\.id)).count == referrals.count
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .referrals,
                in: container,
                debugDescription: "Incoherent referral list."
            )
        }
    }
}

/// `POST /referrals/code` response: always the caller's single active code.
struct ReferralCodeResponseDTO: Decodable, Equatable, Sendable {
    let code: ReferralShareCodeDTO
}
