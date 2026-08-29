import Foundation

/// Customer support happens only inside the authenticated app, gated on the server-advertised
/// typed `protocols.support` contract (see `SupportGate`). There is no web, email, or phone
/// support channel, and every support surface fails closed when the exact contract is missing,
/// malformed, or incompatible.
enum SupportContract {
    static let capabilityKey = "support"
    /// The AI feature flag must be explicitly present AND agree exactly with
    /// `protocols.support.ai.enabled`; a missing or null flag or any inconsistency makes the
    /// whole support gate fail closed (see `SupportGate`).
    static let aiFeatureKey = "support_ai"
    static let statusOpen = "open"
    static let statusClosed = "closed"
    static let subjectMaximumLength = 140
    static let messageMaximumLength = 4000
    static let contentVisibilityServerReadable = "server_readable"
    static let transportPoll = "poll"
    static let officialSupportDesignation = "official_support"

    /// Server page size for the messages endpoint; a shorter page means the thread is drained.
    static let messagesPageLimit = 100

    /// First-page size requested from the ticket snapshot endpoint.
    static let snapshotMessagesLimit = 200

    /// At most this many message pages are fetched per refresh/poll/load-more cycle so a huge
    /// thread can never trigger an unbounded network/render loop. Remaining history is surfaced
    /// with an explicit continuation control — never silently omitted.
    static let maxAutoPagesPerCycle = 3

    /// Base seconds between automatic thread polls (`transport == "poll"`). Polling is
    /// foreground-only, ticks are skipped while any other thread request is in flight (never
    /// overlapping), and consecutive failures stretch the interval via `pollDelaySeconds`.
    static let pollIntervalSeconds: UInt64 = 20

    /// Upper bound for the backoff interval, so repeated failures slow polling down to a quiet
    /// heartbeat instead of a fixed-cadence retry storm.
    static let maxPollIntervalSeconds: UInt64 = 320

    /// After this many consecutive failed polls the UI tells the user automatic updates are
    /// delayed (a manual refresh or a remote wake resets the counter and the backoff).
    static let maxConsecutivePollFailures = 3

    /// Bounded exponential backoff: 20s, 40s, 80s, 160s, then capped at
    /// `maxPollIntervalSeconds`. Pure so the policy is testable.
    static func pollDelaySeconds(consecutiveFailures: Int) -> UInt64 {
        let shift = UInt64(min(max(consecutiveFailures, 0), 4))
        return min(pollIntervalSeconds << shift, maxPollIntervalSeconds)
    }

    /// The only statuses on which the deployed support backend hands down a DEFINITIVE
    /// non-commit verdict through its own parsed error envelope: 403 (gate/ownership refusal
    /// before any write), 404 (unknown or foreign ticket), 409 (authoritative conflict —
    /// `CLIENT_MESSAGE_ID_REUSED`: the key is bound to DIFFERENT, already-recorded content;
    /// `SUPPORT_TICKET_CLOSED`: the mutation was refused), and 422 (validation refusal before
    /// any write). Deliberately an allowlist, NOT a status class: 408/425/429 and other
    /// proxy-capable 4xx say nothing authoritative about whether the origin processed the
    /// request, and an ambiguous outcome must keep the frozen envelope for verbatim replay.
    static let definitiveRejectionStatuses: Set<Int> = [403, 404, 409, 422]

    /// Whether a thrown POST error is a DEFINITIVE server verdict on the attempted submission —
    /// only then may a frozen idempotency envelope be demoted to an editable draft under a
    /// fresh key. Requires the backend's own parsed error envelope (non-empty stable `code`)
    /// on an allowlisted status. Everything else — timeouts, 408/425/429, every 5xx (the server
    /// may have committed before failing), transport failures, undecodable bodies, and
    /// cancellations — is ambiguous and keeps the envelope frozen for idempotent replay.
    static func isDefinitiveRejection(_ error: Error) -> Bool {
        guard let payload = error as? APIErrorPayload,
              let status = payload.httpStatus,
              !payload.code.isEmpty,
              definitiveRejectionStatuses.contains(status)
        else { return false }
        return true
    }

    /// Page size requested from the cursor-paginated tickets index (also the server's maximum).
    /// Continuation is authoritative, never inferred from page fullness: the response meta must
    /// carry a coherent `has_more`/`next_cursor` pair
    /// (`SupportThreadPageValidator.validateTicketPageContinuation`) or the page is rejected.
    static let ticketsPageLimit = 50

    /// Server-enforced maximum length of a tickets-index continuation cursor. An oversized or
    /// empty cursor is incoherent and rejects the page instead of being echoed back.
    static let ticketsCursorMaximumLength = 400

    /// Hard ceiling for message positions/cursors. Together with `addingReportingOverflow` in
    /// the validator this makes position arithmetic total: a hostile `Int.max` position or
    /// cursor is rejected as inconsistent instead of trapping.
    static let maxMessagePosition = 100_000_000

    /// Bounds applied to server-provided text and identifiers before anything reaches the UI.
    /// Payloads exceeding them are rejected as inconsistent rather than rendered.
    static let displayNameMaximumLength = 80
    static let agentAliasMaximumLength = 80
    static let senderTypeMaximumLength = 40
    static let referenceMaximumLength = 48
    static let categoryTextMaximumLength = 80
    static let categoryDescriptionMaximumLength = 500
    static let categoryIdentifierMaximumLength = 80
    static let timestampMaximumLength = 64
    static let designationMaximumLength = 64
    static let reasonCodeMaximumLength = 64

    /// This app version can neither upload nor display support attachments, so it fails closed:
    /// outgoing request DTOs cannot carry `media_asset_id` at all, incoming attachments are
    /// labeled as not viewable rather than implying access, and `SupportGate` additionally
    /// requires the server to advertise `attachments: false`. Flip only together with a real,
    /// authenticated attachment pipeline AND a matching server advertisement.
    static let attachmentsSupported = false

    /// The customer sender type and the closed allowlist of official sender types. Matching is
    /// exact — a padded or unknown type never renders as support and can never earn a seal.
    static let senderTypeCustomer = "customer"
    static let senderTypeAgent = "agent"
    static let senderTypeAssistant = "assistant"
    static let senderTypeSystem = "system"
    static let officialSenderTypes: Set<String> = [
        senderTypeAgent, senderTypeAssistant, senderTypeSystem,
    ]

    /// Server-defined category keys that most closely match an account-deletion question. Used
    /// only to preselect a category the server actually returned; never sent unvalidated.
    static let accountDeletionCategoryHints = ["account_deletion", "account", "deletion"]

    /// The bare feature flag. Necessary but NOT sufficient: every support surface must gate on
    /// `SupportGate.state`, which also requires the exact typed `protocols.support` contract.
    static func available(features: [String: Bool?]?) -> Bool {
        features?[capabilityKey] == true
    }

    /// The only predicate that may put verified wording or a seal on screen. It requires the
    /// explicit `official` flag AND the `official_support` verification designation together, so
    /// partial, malformed, or inconsistent identity metadata renders without any verified claim.
    static func isVerifiedOfficialSupport(
        official: Bool,
        verification: SupportVerificationDTO?
    ) -> Bool {
        official && verification?.designation == officialSupportDesignation
    }

    /// An agent alias is coherent when absent, or present as a bounded string with no leading or
    /// trailing whitespace. Anything else marks the sender metadata inconsistent.
    static func isCoherentAgentAlias(_ alias: String?) -> Bool {
        guard let alias else { return true }
        return isBoundedServerText(alias, maximum: agentAliasMaximumLength)
            && alias == alias.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Initials for a human agent's TICKET-SCOPED alias — the only identity artwork a support
    /// thread may derive for a person. Uppercased first characters of the first two
    /// whitespace-separated alias words; nil when no letterable word exists, so the caller falls
    /// back to the official mark rather than an empty disc.
    static func avatarInitials(fromAlias alias: String?) -> String? {
        guard let alias else { return nil }
        let words = alias.split(whereSeparator: \.isWhitespace)
        let letters = words.prefix(2).compactMap { $0.first.map(String.init) }
        guard !letters.isEmpty else { return nil }
        return letters.joined().uppercased()
    }

    /// Non-empty and within the given length bound. Server text failing this is rejected before
    /// it can reach the UI.
    static func isBoundedServerText(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.count <= maximum
    }

    static func canonicalUUID(_ value: String) -> String? {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              let identifier = UUID(uuidString: value)
        else { return nil }
        return identifier.uuidString.lowercased()
    }

    static func canonicalTicketID(_ value: String) -> String? {
        canonicalUUID(value)
    }

    /// Canonical account identifier for flow binding and draft storage. The backend account
    /// identifier is `users.public_id`, a UUID column, so this requires a real UUID (the same
    /// validation the session contract applies to `session_id`) — arbitrary or malformed token
    /// text can never mint a flow binding or a protected-draft namespace, and a support flow
    /// never falls back to a session-scoped stand-in (which would break account isolation and
    /// durable draft recovery across a fresh session).
    static func canonicalAccountID(_ value: String?) -> String? {
        guard let value else { return nil }
        return canonicalUUID(value)
    }

    static func normalizedSubject(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3, trimmed.count <= subjectMaximumLength else { return nil }
        return trimmed
    }

    static func normalizedMessageBody(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= messageMaximumLength else { return nil }
        return trimmed
    }

    static func preferredCategory(
        in categories: [SupportCategoryDTO],
        hints: [String] = accountDeletionCategoryHints
    ) -> SupportCategoryDTO? {
        for hint in hints {
            if let match = categories.first(where: {
                $0.key.caseInsensitiveCompare(hint) == .orderedSame
            }) {
                return match
            }
        }
        return nil
    }
}

/// The strictly validated `payments` block of the support advertisement. Decoded strictly so a
/// malformed advertisement fails the whole support gate closed; the customer-initiated payments
/// surface additionally requires `SupportGate.paymentsState` (SupportPaymentModels.swift), which
/// binds these values to the collapsed `support_payments` feature flag and the company-only
/// beneficiary kind.
struct SupportPaymentsProtocolDTO: Equatable, Sendable {
    let ready: Bool
    let beneficiaryKind: String
    let beneficiaryDisplayName: String
}

/// Typed model of the server's `protocols.support` advertisement. Decoding is deliberately
/// strict — the canonical contract (docs/support-platform.md) is:
///
///     { "ready": Bool, "end_to_end_encrypted": Bool, "content": String, "transport": String,
///       "attachments": Bool,
///       "payments": { "ready": Bool, "beneficiary": { "kind": String, "display_name": String } },
///       "ai": { "enabled": Bool } }
///
/// Unknown or extra keys, a missing required key, or a wrong type anywhere throws, which the
/// lenient `CapabilityProtocolsDTO` layer turns into `support == nil`, which `SupportGate` turns
/// into "support unavailable". The deployed backend now emits exactly this canonical shape
/// (`attachments` is a plain boolean in CapabilitiesController, and
/// `SupportPaymentService::beneficiary` documents that the block is exactly `kind` +
/// `display_name` because clients bind strictly). Any future divergence fails closed here rather
/// than being papered over — never loosen this decoder to accommodate an unannounced schema
/// change; the canonical shape above is pinned by tests.
struct SupportProtocolDTO: Equatable, Sendable {
    let ready: Bool
    let endToEndEncrypted: Bool
    let content: String
    let transport: String
    /// Canonical wire shape is a plain boolean (`"attachments": false`).
    let attachmentsEnabled: Bool
    /// From the required `ai: { enabled: Bool }` block; must match the `support_ai` feature flag.
    let aiEnabled: Bool
    let payments: SupportPaymentsProtocolDTO
}

extension SupportProtocolDTO: Decodable {
    private struct WireKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private static let allowedKeys: Set<String> = [
        "ready", "end_to_end_encrypted", "content", "transport",
        "attachments", "payments", "ai",
    ]
    private static let allowedAIKeys: Set<String> = ["enabled"]
    private static let allowedPaymentsKeys: Set<String> = ["ready", "beneficiary"]
    private static let allowedBeneficiaryKeys: Set<String> = ["kind", "display_name"]

    private static func reject(
        _ codingPath: [CodingKey],
        _ reason: String
    ) -> DecodingError {
        DecodingError.dataCorrupted(DecodingError.Context(
            codingPath: codingPath,
            debugDescription: reason
        ))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: WireKey.self)
        for key in container.allKeys where !Self.allowedKeys.contains(key.stringValue) {
            throw Self.reject(
                container.codingPath,
                "Unknown protocols.support key: \(key.stringValue)"
            )
        }
        ready = try container.decode(Bool.self, forKey: WireKey("ready"))
        endToEndEncrypted = try container.decode(
            Bool.self,
            forKey: WireKey("end_to_end_encrypted")
        )
        content = try container.decode(String.self, forKey: WireKey("content"))
        transport = try container.decode(String.self, forKey: WireKey("transport"))
        attachmentsEnabled = try container.decode(Bool.self, forKey: WireKey("attachments"))

        // `ai` is required and must be exactly { "enabled": Bool }.
        let ai = try container.nestedContainer(keyedBy: WireKey.self, forKey: WireKey("ai"))
        for key in ai.allKeys where !Self.allowedAIKeys.contains(key.stringValue) {
            throw Self.reject(ai.codingPath, "Unknown protocols.support.ai key: \(key.stringValue)")
        }
        aiEnabled = try ai.decode(Bool.self, forKey: WireKey("enabled"))

        // `payments` is required and fully shape-validated. The beneficiary block is pinned to
        // exactly `kind` + `display_name` — the backend documents that support clients bind
        // strictly to it, so any extra key is a contract break that must fail the gate closed.
        let paymentsContainer = try container.nestedContainer(
            keyedBy: WireKey.self,
            forKey: WireKey("payments")
        )
        for key in paymentsContainer.allKeys
        where !Self.allowedPaymentsKeys.contains(key.stringValue) {
            throw Self.reject(
                paymentsContainer.codingPath,
                "Unknown protocols.support.payments key: \(key.stringValue)"
            )
        }
        let paymentsReady = try paymentsContainer.decode(Bool.self, forKey: WireKey("ready"))
        let beneficiary = try paymentsContainer.nestedContainer(
            keyedBy: WireKey.self,
            forKey: WireKey("beneficiary")
        )
        for key in beneficiary.allKeys
        where !Self.allowedBeneficiaryKeys.contains(key.stringValue) {
            throw Self.reject(
                beneficiary.codingPath,
                "Unknown protocols.support.payments.beneficiary key: \(key.stringValue)"
            )
        }
        let beneficiaryKind = try beneficiary.decode(String.self, forKey: WireKey("kind"))
        let beneficiaryDisplayName = try beneficiary.decode(
            String.self,
            forKey: WireKey("display_name")
        )
        guard SupportContract.isBoundedServerText(
                beneficiaryKind,
                maximum: SupportContract.categoryTextMaximumLength
            ),
            SupportContract.isBoundedServerText(
                beneficiaryDisplayName,
                maximum: SupportContract.displayNameMaximumLength
            )
        else {
            throw Self.reject(beneficiary.codingPath, "Unbounded beneficiary text")
        }
        payments = SupportPaymentsProtocolDTO(
            ready: paymentsReady,
            beneficiaryKind: beneficiaryKind,
            beneficiaryDisplayName: beneficiaryDisplayName
        )
    }
}

enum SupportGateState: Equatable, Sendable {
    case unavailable
    case available(aiProcessingEnabled: Bool)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    var aiProcessingEnabled: Bool {
        if case .available(let ai) = self { return ai }
        return false
    }
}

/// The single gate for every support surface and action. The feature flag alone is NOT enough:
/// the server must also advertise the exact typed contract this client implements —
/// `ready == true`, `transport == "poll"`, `content == "server_readable"`,
/// `end_to_end_encrypted == false`, `attachments == false` — and the `support_ai` feature flag
/// must be explicitly present (a missing or null flag fails closed, never "assume off") and
/// agree exactly with `protocols.support.ai.enabled`. Missing, malformed, unknown, extra,
/// incompatible, or mutually inconsistent values all yield `.unavailable`.
enum SupportGate {
    static func state(for capabilities: CapabilitiesDTO?) -> SupportGateState {
        state(features: capabilities?.features, support: capabilities?.protocols?.support)
    }

    static func state(
        features: [String: Bool?]?,
        support: SupportProtocolDTO?
    ) -> SupportGateState {
        guard let features,
              SupportContract.available(features: features),
              let aiFeatureEntry = features[SupportContract.aiFeatureKey],
              let aiFeatureFlag = aiFeatureEntry,
              let support,
              support.ready,
              !support.endToEndEncrypted,
              support.content == SupportContract.contentVisibilityServerReadable,
              support.transport == SupportContract.transportPoll,
              support.attachmentsEnabled == SupportContract.attachmentsSupported,
              support.aiEnabled == aiFeatureFlag
        else { return .unavailable }
        return .available(aiProcessingEnabled: support.aiEnabled)
    }
}

/// Where the account-deletion flow may send a customer for help. In-app support is offered only
/// behind the full typed gate — the same `SupportGate.state` that gates every other support
/// surface — so a bare `features.support` flag (or a malformed `protocols.support` block) fails
/// closed to the official legal deletion page instead of opening a support UI the server did not
/// fully advertise.
enum SupportAssistancePath: Equatable, Sendable {
    case inAppSupport
    case legalDeletionPage
}

extension SupportContract {
    static func deletionAssistancePath(capabilities: CapabilitiesDTO?) -> SupportAssistancePath {
        deletionAssistancePath(
            features: capabilities?.features,
            support: capabilities?.protocols?.support
        )
    }

    static func deletionAssistancePath(
        features: [String: Bool?]?,
        support: SupportProtocolDTO?
    ) -> SupportAssistancePath {
        SupportGate.state(features: features, support: support).isAvailable
            ? .inAppSupport
            : .legalDeletionPage
    }
}

/// Why a close request cannot proceed as a plain close right now. Exactly one obstacle is
/// surfaced at a time, most severe first; resolving it re-evaluates the rest. The ordering is
/// part of the safety contract:
///  1. `cleanupBlocked` — an ACCEPTED envelope's verified clear failed. Nothing may proceed
///     around the composer until cleanup verifiably succeeds, or the delivered message's local
///     copy could resurrect later.
///  2. `pendingReplay` — a frozen envelope may already be committed server-side. It resolves
///     only by verbatim replay: the backend resolves idempotent replays BEFORE its closed-ticket
///     check, so a 200 replay proves the message committed while the ticket was open and a
///     409 SUPPORT_TICKET_CLOSED proves it never committed. It is never discarded.
///  3. `storageError` — draft storage is in a failed state, so whether composer content is
///     durably stored is unknown; a discard must verifiably clear storage before any close.
///  4. `unsentDraft` — unsent composer text a plain close would silently orphan; the customer
///     explicitly chooses send-then-close or a verified-clear discard.
///  5. `pendingPayment` — a frozen payment attempt (or an unreadable payment record) exists.
///     Lowest severity because closing is genuinely SAFE: the backend resolves payment
///     idempotent replays before its closed-ticket check, and the pending notice stays
///     accessible on the closed ticket, so the attempt remains resolvable and can never
///     double-charge. The prompt informs; it does not have to block.
enum SupportCloseObstacle: Equatable, Sendable {
    case cleanupBlocked
    case pendingReplay
    case storageError
    case unsentDraft
    case pendingPayment
}

enum SupportClosePolicy {
    static func obstacle(
        cleanupBlocked: Bool,
        pendingReplay: Bool,
        storageError: Bool,
        composerText: String,
        pendingPayment: Bool
    ) -> SupportCloseObstacle? {
        if cleanupBlocked { return .cleanupBlocked }
        if pendingReplay { return .pendingReplay }
        if storageError { return .storageError }
        // ANY non-whitespace text counts — including text the send normalizer would reject —
        // because a plain close would silently lose it either way.
        if !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .unsentDraft
        }
        if pendingPayment { return .pendingPayment }
        return nil
    }
}

/// Explicit load state so "not loaded yet" can never be confused with an authoritative empty
/// result, and a failure is a distinct, retryable state instead of an indefinite spinner.
enum SupportLoadState<Value: Equatable>: Equatable {
    case idle
    case loading
    case loaded(Value)
    case failed(String)

    var loadedValue: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

struct SupportCategoryDTO: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: String
    let key: String
    let name: String
    let description: String?
}

struct SupportVerificationDTO: Codable, Equatable, Hashable, Sendable {
    let designation: String
}

struct SupportTicketCategoryRefDTO: Codable, Equatable, Hashable, Sendable {
    let key: String
    let name: String
}

struct SupportIdentityDTO: Codable, Equatable, Hashable, Sendable {
    let displayName: String
    let official: Bool
    let verification: SupportVerificationDTO?

    var isVerifiedOfficialSupport: Bool {
        SupportContract.isVerifiedOfficialSupport(official: official, verification: verification)
    }

    private enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case official
        case verification
    }
}

struct SupportTicketClosureDTO: Codable, Equatable, Hashable, Sendable {
    let at: String
    let reasonCode: String?

    private enum CodingKeys: String, CodingKey {
        case at
        case reasonCode = "reason_code"
    }
}

struct SupportTicketDTO: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: String
    let reference: String
    let subject: String
    let status: String
    let category: SupportTicketCategoryRefDTO
    let supportIdentity: SupportIdentityDTO
    let assistantActive: Bool
    let messageCount: Int
    let createdAt: String
    let lastMessageAt: String?
    let closed: SupportTicketClosureDTO?
    let endToEndEncrypted: Bool
    let contentVisibility: String

    var isOpen: Bool { status == SupportContract.statusOpen }

    /// Support conversations are staff-readable by design; a payload claiming end-to-end
    /// encryption for a support thread is contradictory and therefore NOT treated as
    /// server-readable — `SupportThreadPageValidator.validateTicket` additionally REJECTS such a
    /// ticket before it can reach the UI.
    var isServerReadable: Bool {
        contentVisibility == SupportContract.contentVisibilityServerReadable
            && !endToEndEncrypted
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case reference
        case subject
        case status
        case category
        case supportIdentity = "support_identity"
        case assistantActive = "assistant_active"
        case messageCount = "message_count"
        case createdAt = "created_at"
        case lastMessageAt = "last_message_at"
        case closed
        case endToEndEncrypted = "end_to_end_encrypted"
        case contentVisibility = "content_visibility"
    }
}

struct SupportSenderDTO: Codable, Equatable, Hashable, Sendable {
    let type: String
    let displayName: String
    let official: Bool
    let automated: Bool
    let verification: SupportVerificationDTO?
    let agentAlias: String?

    /// Exact match only; a padded or mixed-case variant is an unknown type.
    var isCustomer: Bool { type == SupportContract.senderTypeCustomer }

    /// Sender-type/metadata coherence, per the server's presenter contract:
    /// - `assistant` is automated and never carries an alias,
    /// - `agent` is human (not automated) and may carry a coherent alias,
    /// - `system` is not automated and never carries an alias.
    /// Anything else — including an unknown or whitespace-padded type — is incoherent.
    var hasCoherentOfficialMetadata: Bool {
        switch type {
        case SupportContract.senderTypeAssistant:
            automated && agentAlias == nil
        case SupportContract.senderTypeAgent:
            !automated && SupportContract.isCoherentAgentAlias(agentAlias)
        case SupportContract.senderTypeSystem:
            !automated && agentAlias == nil
        default:
            false
        }
    }

    /// A coherent customer sender: exact type, no official/automation claims, no verification,
    /// no alias. Anything else claiming to be a customer is incoherent.
    var isCoherentCustomer: Bool {
        isCustomer && !official && !automated && verification == nil && agentAlias == nil
    }

    /// The only sender predicate that may render on the support side or earn a seal. A customer
    /// or unknown type can never be verified support; an allowlisted type must additionally
    /// carry the explicit official flag, the `official_support` designation, AND type-consistent
    /// metadata. The backend's official senders always satisfy all three, so anything less is
    /// rejected outright by `SupportThreadPageValidator.validateSender` — it never renders as
    /// support, sealed or otherwise.
    var isVerifiedOfficialSupport: Bool {
        !isCustomer
            && SupportContract.officialSenderTypes.contains(type)
            && hasCoherentOfficialMetadata
            && SupportContract.isVerifiedOfficialSupport(
                official: official,
                verification: verification
            )
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case displayName = "display_name"
        case official
        case automated
        case verification
        case agentAlias = "agent_alias"
    }
}

/// The privacy-preserving, ticket-scoped avatar of a message sender. Derived EXCLUSIVELY from
/// the sender payload the server already scoped to this ticket — never from profile photos,
/// contact records, remote image URLs, or any global identity — so a support thread can never
/// surface either side's real-world identity beyond what the ticket itself carries.
enum SupportSenderAvatar: Equatable, Sendable {
    /// The official Kit Pay mark: verified assistant and system senders, and verified agents
    /// whose alias yields no usable initials.
    case officialMark
    /// Initials from the ticket-scoped alias of a verified human agent.
    case initials(String)
    /// No identity artwork at all: customers, and any sender that fails the verified-official
    /// predicate — an unverified sender must never borrow official-looking artwork.
    case none
}

extension SupportSenderDTO {
    var ticketScopedAvatar: SupportSenderAvatar {
        guard isVerifiedOfficialSupport else { return .none }
        if type == SupportContract.senderTypeAgent,
           let initials = SupportContract.avatarInitials(fromAlias: agentAlias) {
            return .initials(initials)
        }
        return .officialMark
    }
}

struct SupportAttachmentDTO: Codable, Equatable, Hashable, Sendable {
    let mediaAssetID: String

    private enum CodingKeys: String, CodingKey {
        case mediaAssetID = "media_asset_id"
    }
}

struct SupportMessageDTO: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: String
    let position: Int
    let sender: SupportSenderDTO
    let body: String
    let attachment: SupportAttachmentDTO?
    let createdAt: String

    private enum CodingKeys: String, CodingKey {
        case id
        case position
        case sender
        case body
        case attachment
        case createdAt = "created_at"
    }
}

struct SupportCategoryListDTO: Codable, Equatable, Sendable {
    let items: [SupportCategoryDTO]
}

struct SupportTicketListDTO: Codable, Equatable, Sendable {
    let items: [SupportTicketDTO]
}

/// One validated page of the cursor-paginated tickets index: the rows plus the AUTHORITATIVE
/// continuation from the response meta. `hasMore == true` always comes with the non-empty bounded
/// cursor for the next page; `false` always comes with no cursor — any other combination (or a
/// response missing the meta pair entirely) is rejected before construction
/// (`SupportThreadPageValidator.validateTicketPageContinuation`), so completeness is never
/// guessed from page fullness.
struct SupportTicketPage: Equatable, Sendable {
    let items: [SupportTicketDTO]
    let nextCursor: String?
    let hasMore: Bool
}

/// Bounded first page of a ticket thread; when longer, the client keeps reading from the
/// messages endpoint. Continuation cursors are always derived from validated delivered items;
/// the server's `messages_has_more`/`messages_next_after_position` pair must be internally
/// coherent AND agree with the derived value (see
/// `SupportThreadPageValidator.validateSnapshotContinuation`) — a cursor beyond the max
/// validated delivered position would silently skip a range and is rejected instead of trusted.
struct SupportTicketSnapshotDTO: Codable, Equatable, Sendable {
    let ticket: SupportTicketDTO
    let messages: [SupportMessageDTO]
    let messagesHasMore: Bool
    let messagesNextAfterPosition: Int?

    private enum CodingKeys: String, CodingKey {
        case ticket
        case messages
        case messagesHasMore = "messages_has_more"
        case messagesNextAfterPosition = "messages_next_after_position"
    }
}

struct SupportMessageListDTO: Codable, Equatable, Sendable {
    let items: [SupportMessageDTO]
    let ticket: SupportTicketDTO
}

/// Pure integrity validation applied to every server page before it can touch UI state. On any
/// violation the page is rejected as a whole (`SupportContractError.inconsistentThread` /
/// `.inconsistentList`), the last known-good state is preserved, and a safe error is surfaced.
enum SupportThreadPageValidator {
    /// Validates one messages page against the bound ticket and the already-applied window.
    ///
    /// Positions must be EXACTLY contiguous: the first item at `afterPosition + 1` and each
    /// subsequent item advancing by exactly one. That single rule rejects nonpositive positions,
    /// cursor jumps/omissions, duplicate or conflicting positions, non-monotonic items, and
    /// overlap with the applied window. All position arithmetic is bounded
    /// (`SupportContract.maxMessagePosition`) and overflow-checked, so an `Int.max` cursor or
    /// position fails closed instead of trapping. Also rejects: a page ticket that is not
    /// exactly the bound ticket; more items than requested; non-canonical message or attachment
    /// identifiers; duplicate IDs within the page or against applied messages (compared
    /// canonically); non-verified or incoherent senders; unbounded or unparseable server text.
    static func validateMessagePage(
        _ items: [SupportMessageDTO],
        boundTicketID: String,
        pageTicket: SupportTicketDTO?,
        afterPosition: Int,
        requestedLimit: Int,
        existingIDs: Set<String>,
        existingMaxPosition: Int
    ) throws {
        guard requestedLimit >= 1,
              afterPosition >= 0,
              afterPosition <= SupportContract.maxMessagePosition,
              existingMaxPosition >= 0,
              existingMaxPosition <= SupportContract.maxMessagePosition,
              afterPosition == existingMaxPosition
        else { throw SupportContractError.inconsistentThread }
        if let pageTicket {
            try validateTicket(pageTicket, expectedID: boundTicketID)
        }
        guard items.count <= requestedLimit else {
            throw SupportContractError.inconsistentThread
        }

        let canonicalExisting = Set(existingIDs.map { SupportContract.canonicalUUID($0) ?? $0 })
        var seenIDs = Set<String>()
        let start = afterPosition.addingReportingOverflow(1)
        guard !start.overflow else { throw SupportContractError.inconsistentThread }
        var expectedPosition = start.partialValue
        for item in items {
            guard let canonicalID = SupportContract.canonicalUUID(item.id),
                  item.position == expectedPosition,
                  item.position <= SupportContract.maxMessagePosition,
                  !canonicalExisting.contains(canonicalID),
                  !seenIDs.contains(canonicalID)
            else { throw SupportContractError.inconsistentThread }
            try validateMessageContent(item)
            seenIDs.insert(canonicalID)
            let next = expectedPosition.addingReportingOverflow(1)
            guard !next.overflow else { throw SupportContractError.inconsistentThread }
            expectedPosition = next.partialValue
        }
    }

    /// Bounds every piece of server text and every identifier in a message, requires a parseable
    /// timestamp, and requires the sender to pass `validateSender` — so an unknown, incoherent,
    /// or non-verified non-customer sender can never render at all, let alone as support.
    static func validateMessageContent(_ message: SupportMessageDTO) throws {
        guard SupportContract.isBoundedServerText(
                message.body,
                maximum: SupportContract.messageMaximumLength
            ),
            SupportContract.normalizedMessageBody(message.body) != nil,
            SupportContract.isBoundedServerText(
                message.createdAt,
                maximum: SupportContract.timestampMaximumLength
            ),
            SupportDates.parse(message.createdAt) != nil
        else { throw SupportContractError.inconsistentThread }
        try validateSender(message.sender)
        if let attachment = message.attachment {
            guard SupportContract.canonicalUUID(attachment.mediaAssetID) != nil else {
                throw SupportContractError.inconsistentThread
            }
        }
    }

    /// A sender must be a coherent customer or a fully VERIFIED official sender
    /// (`isVerifiedOfficialSupport`: allowlisted type + type/automation coherence + explicit
    /// `official` flag + `official_support` designation — the backend's official senders always
    /// provide all of these). An allowlisted type with `official == false`, a missing or wrong
    /// verification, or inconsistent automation therefore rejects the whole page: it must never
    /// render on the support side, with or without a seal.
    static func validateSender(_ sender: SupportSenderDTO) throws {
        guard SupportContract.isBoundedServerText(
                sender.displayName,
                maximum: SupportContract.displayNameMaximumLength
            ),
            SupportContract.isBoundedServerText(
                sender.type,
                maximum: SupportContract.senderTypeMaximumLength
            ),
            sender.isCoherentCustomer || sender.isVerifiedOfficialSupport
        else { throw SupportContractError.inconsistentThread }
        if let designation = sender.verification?.designation {
            guard SupportContract.isBoundedServerText(
                designation,
                maximum: SupportContract.designationMaximumLength
            ) else { throw SupportContractError.inconsistentThread }
        }
    }

    /// Validates one ticket row (list page, snapshot, or mutation result), optionally pinning it
    /// to an expected identifier. Rejects contradictory visibility claims (end-to-end-encrypted
    /// or non-server-readable support content), unknown statuses, status/closure incoherence,
    /// unparseable dates, and unbounded text or identifiers. The ticket-level support identity
    /// must be FULLY verified official support (explicit `official` flag + `official_support`
    /// designation — the backend presenter always emits exactly that), so a ticket carrying a
    /// partial, missing, or inconsistent identity is rejected outright rather than headed
    /// "Kit Pay support" without a verified basis.
    static func validateTicket(_ ticket: SupportTicketDTO, expectedID: String? = nil) throws {
        guard let canonicalID = SupportContract.canonicalTicketID(ticket.id) else {
            throw SupportContractError.inconsistentThread
        }
        if let expectedID {
            guard canonicalID == SupportContract.canonicalTicketID(expectedID) else {
                throw SupportContractError.inconsistentThread
            }
        }
        guard ticket.status == SupportContract.statusOpen
                || ticket.status == SupportContract.statusClosed,
            (ticket.status == SupportContract.statusClosed) == (ticket.closed != nil),
            !ticket.endToEndEncrypted,
            ticket.contentVisibility == SupportContract.contentVisibilityServerReadable,
            SupportContract.isBoundedServerText(
                ticket.reference,
                maximum: SupportContract.referenceMaximumLength
            ),
            SupportContract.isBoundedServerText(
                ticket.subject,
                maximum: SupportContract.subjectMaximumLength
            ),
            SupportContract.isBoundedServerText(
                ticket.category.key,
                maximum: SupportContract.categoryTextMaximumLength
            ),
            SupportContract.isBoundedServerText(
                ticket.category.name,
                maximum: SupportContract.categoryTextMaximumLength
            ),
            SupportContract.isBoundedServerText(
                ticket.supportIdentity.displayName,
                maximum: SupportContract.displayNameMaximumLength
            ),
            ticket.supportIdentity.isVerifiedOfficialSupport,
            ticket.messageCount >= 0,
            SupportContract.isBoundedServerText(
                ticket.createdAt,
                maximum: SupportContract.timestampMaximumLength
            ),
            SupportDates.parse(ticket.createdAt) != nil
        else { throw SupportContractError.inconsistentThread }
        if let lastMessageAt = ticket.lastMessageAt {
            guard SupportContract.isBoundedServerText(
                    lastMessageAt,
                    maximum: SupportContract.timestampMaximumLength
                ),
                SupportDates.parse(lastMessageAt) != nil
            else { throw SupportContractError.inconsistentThread }
        }
        if let closed = ticket.closed {
            guard SupportContract.isBoundedServerText(
                    closed.at,
                    maximum: SupportContract.timestampMaximumLength
                ),
                SupportDates.parse(closed.at) != nil
            else { throw SupportContractError.inconsistentThread }
            if let reasonCode = closed.reasonCode {
                guard SupportContract.isBoundedServerText(
                    reasonCode,
                    maximum: SupportContract.reasonCodeMaximumLength
                ) else { throw SupportContractError.inconsistentThread }
            }
        }
    }

    /// Validates one tickets-index page: every row individually, no duplicate identifiers within
    /// the page, and no overlap with rows already applied (compared canonically).
    static func validateTicketPage(
        _ items: [SupportTicketDTO],
        requestedLimit: Int,
        existingIDs: Set<String>
    ) throws {
        guard requestedLimit >= 1, items.count <= requestedLimit else {
            throw SupportContractError.inconsistentList
        }
        let canonicalExisting = Set(existingIDs.map { SupportContract.canonicalUUID($0) ?? $0 })
        var seenIDs = Set<String>()
        for ticket in items {
            do {
                try validateTicket(ticket)
            } catch {
                throw SupportContractError.inconsistentList
            }
            let canonicalID = SupportContract.canonicalTicketID(ticket.id) ?? ticket.id
            guard !seenIDs.contains(canonicalID), !canonicalExisting.contains(canonicalID) else {
                throw SupportContractError.inconsistentList
            }
            seenIDs.insert(canonicalID)
        }
    }

    /// Validates the server's category list before it can seed a picker.
    static func validateCategories(_ items: [SupportCategoryDTO]) throws {
        var seenKeys = Set<String>()
        for category in items {
            guard SupportContract.isBoundedServerText(
                    category.id,
                    maximum: SupportContract.categoryIdentifierMaximumLength
                ),
                SupportContract.isBoundedServerText(
                    category.key,
                    maximum: SupportContract.categoryTextMaximumLength
                ),
                SupportContract.isBoundedServerText(
                    category.name,
                    maximum: SupportContract.categoryTextMaximumLength
                ),
                !seenKeys.contains(category.key)
            else { throw SupportContractError.inconsistentList }
            if let description = category.description {
                guard SupportContract.isBoundedServerText(
                    description,
                    maximum: SupportContract.categoryDescriptionMaximumLength
                ) else { throw SupportContractError.inconsistentList }
            }
            seenKeys.insert(category.key)
        }
    }

    /// The only way a thread continuation cursor may be produced: from the validated delivered
    /// items themselves (call this only AFTER `validateMessagePage` accepted the snapshot page).
    /// The server pair must be coherent — `messages_has_more == true` requires a delivered page
    /// and a non-nil `messages_next_after_position` EQUAL to the max validated delivered
    /// position; `false` requires the cursor to be absent. A cursor beyond the delivered range
    /// would silently skip messages, and any other combination is a contradiction — either
    /// rejects the snapshot.
    static func validateSnapshotContinuation(
        messagesHasMore: Bool,
        messagesNextAfterPosition: Int?,
        validatedItems: [SupportMessageDTO]
    ) throws -> Int {
        let derived = validatedItems.map(\.position).max() ?? 0
        if messagesHasMore {
            guard !validatedItems.isEmpty,
                  let cursor = messagesNextAfterPosition,
                  cursor == derived
            else { throw SupportContractError.inconsistentThread }
        } else {
            guard messagesNextAfterPosition == nil else {
                throw SupportContractError.inconsistentThread
            }
        }
        return derived
    }

    /// AUTHORITATIVE forward-window remainder for a ticket thread. Message positions are 1-based
    /// and exactly contiguous (`validateMessagePage`), so the max loaded position equals the
    /// number of loaded messages, and the refreshed ticket's `message_count` is the server's
    /// authoritative total:
    /// - `message_count > lastLoadedPosition` — more history remains (also covers a message that
    ///   landed between the page query and the ticket refresh: the next page picks it up);
    /// - equal — the window is drained;
    /// - LESS than the validated delivered window — the payload contradicts itself and the page
    ///   is rejected as a whole, preserving prior state.
    /// Call this BEFORE applying the page, so a contradictory ticket never touches UI state.
    static func forwardWindowRemaining(
        lastLoadedPosition: Int,
        ticket: SupportTicketDTO
    ) throws -> Bool {
        guard lastLoadedPosition >= 0,
              lastLoadedPosition <= SupportContract.maxMessagePosition,
              ticket.messageCount >= lastLoadedPosition
        else { throw SupportContractError.inconsistentThread }
        return ticket.messageCount > lastLoadedPosition
    }

    /// Coherence rule for the tickets-index continuation, the ONLY way a list page's
    /// completeness may be decided. The response meta must carry the pair explicitly:
    /// `has_more == true` requires a non-empty cursor within the server's own length bound
    /// (anything longer could never be a cursor the server issued); `false` requires the cursor
    /// to be absent; a missing `has_more` (no meta at all) means the endpoint contract is not
    /// being spoken and the page is rejected — completeness is never inferred from page
    /// fullness.
    static func validateTicketPageContinuation(
        hasMore: Bool?,
        nextCursor: String?
    ) throws -> (hasMore: Bool, nextCursor: String?) {
        guard let hasMore else { throw SupportContractError.inconsistentList }
        if hasMore {
            guard let nextCursor,
                  SupportContract.isBoundedServerText(
                      nextCursor,
                      maximum: SupportContract.ticketsCursorMaximumLength
                  )
            else { throw SupportContractError.inconsistentList }
            return (true, nextCursor)
        }
        guard nextCursor == nil else { throw SupportContractError.inconsistentList }
        return (false, nil)
    }

    /// Authoritative-success validation for a sent message. The persisted idempotency envelope
    /// may be cleared ONLY after the response provably describes the attempted send: full
    /// content validation, a canonical identifier, a bounded position, the customer as sender
    /// (with exact coherence), no attachment (this client cannot send one), and the body
    /// byte-equal to the attempted normalized body. Anything less keeps the envelope frozen for
    /// idempotent replay.
    static func validateSentMessageAuthoritative(
        _ message: SupportMessageDTO,
        attemptedBody: String
    ) throws {
        try validateMessageContent(message)
        guard SupportContract.canonicalUUID(message.id) != nil,
              message.position >= 1,
              message.position <= SupportContract.maxMessagePosition,
              message.sender.isCoherentCustomer,
              message.attachment == nil,
              message.body == attemptedBody
        else { throw SupportContractError.inconsistentThread }
    }

    /// Authoritative-success validation for a created ticket, by the same rule: the response
    /// must provably describe the attempted submission before the persisted envelope may be
    /// cleared — a validated ticket containing at least the submitted message, with the EXACT
    /// attempted normalized subject and the exact selected category key. The server additionally
    /// enforces replay identity on its side (an idempotent replay of `client_message_id` 409s
    /// unless body, subject, and category all match), and it may legitimately return an
    /// already-CLOSED ticket for a replay of a since-closed creation, so open status is
    /// deliberately not required here. The wire response also carries an `idempotent_replay`
    /// meta flag, but the transport envelope does not surface response metadata, so subject,
    /// category, and message count are the client-checkable identity; a malformed or unrelated
    /// response fails this check and MUST leave the frozen envelope untouched.
    static func validateCreatedTicketAuthoritative(
        _ ticket: SupportTicketDTO,
        attemptedSubject: String,
        attemptedCategoryKey: String
    ) throws {
        try validateTicket(ticket)
        guard ticket.messageCount >= 1,
              ticket.subject == attemptedSubject,
              ticket.category.key == attemptedCategoryKey
        else { throw SupportContractError.inconsistentThread }
    }

    /// Authoritative postcondition for the customer close action. Any merely valid same-ID
    /// ticket is NOT enough: the response must actually be closed with coherent closure
    /// metadata (`validateTicket` ties `status == "closed"` to a parseable `closed.at` and a
    /// bounded optional reason code; the reason value itself is not pinned because an
    /// idempotent re-close returns whatever party closed the ticket first). A wrong or stale
    /// 2xx — still-open status, different ticket — is rejected so the prior state is preserved.
    static func validateClosedTicketAuthoritative(
        _ ticket: SupportTicketDTO,
        expectedID: String
    ) throws {
        try validateTicket(ticket, expectedID: expectedID)
        guard !ticket.isOpen, ticket.closed != nil else {
            throw SupportContractError.inconsistentThread
        }
    }

    /// Authoritative postcondition for the customer "talk to a person" escalation. The backend
    /// contract: escalation on a closed ticket is a definitive 409, and a 2xx hands the AI off,
    /// so the response must be the same ticket, still open, with `assistant_active == false`.
    /// Known fail-closed edge (documented for backend reconciliation, not loosened here): when
    /// an admin manually assigned an agent while `ai_state` was still pending/answered, the
    /// backend skips the hand-off and returns `assistant_active == true` even though a human is
    /// attached — the customer payload cannot distinguish that from a failed hand-off, so this
    /// validator rejects it and the UI preserves prior state with a safe error.
    static func validateEscalatedTicketAuthoritative(
        _ ticket: SupportTicketDTO,
        expectedID: String
    ) throws {
        try validateTicket(ticket, expectedID: expectedID)
        guard ticket.isOpen, !ticket.assistantActive else {
            throw SupportContractError.inconsistentThread
        }
    }
}

/// Pure policies for the ticket list.
enum SupportTicketListPolicy {
    /// Deterministic upsert: an existing row (matched by canonical ID) is replaced in place, so
    /// an idempotent replay racing a list refresh can never duplicate a ticket; a genuinely new
    /// ticket is inserted at the top.
    static func upsert(
        _ ticket: SupportTicketDTO,
        into tickets: [SupportTicketDTO]
    ) -> [SupportTicketDTO] {
        let newID = SupportContract.canonicalTicketID(ticket.id) ?? ticket.id
        var tickets = tickets
        if let index = tickets.firstIndex(where: {
            (SupportContract.canonicalTicketID($0.id) ?? $0.id) == newID
        }) {
            tickets[index] = ticket
        } else {
            tickets.insert(ticket, at: 0)
        }
        return tickets
    }
}

/// A support composer draft/idempotency envelope: exactly what the user is composing (or last
/// attempted to send) plus the idempotency UUID minted for it, persisted atomically as one
/// protected-storage item per account+thread. The record is versioned and self-describing
/// (account, thread, phase) so a stored blob is only ever honored after strict validation
/// against the requesting account and thread — a corrupted, foreign, or mis-keyed record fails
/// closed instead of silently rotating or reusing idempotency authority.
struct SupportComposerDraft: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    enum Phase: String, Codable, Sendable {
        /// Normal composing: autosaved on edits, cleared when emptied.
        case draft
        /// A POST was attempted and its outcome is unknown (or not yet authoritative). The
        /// record is FROZEN: edits and empty autosaves must not overwrite or delete it, and the
        /// next send must replay exactly this content with exactly this UUID, until an
        /// authoritative success clears it or a definitive server rejection demotes it back to
        /// `.draft`.
        case pendingReplay = "pending_replay"
    }

    let schemaVersion: Int
    /// Canonical account UUID (`SupportContract.canonicalAccountID`).
    let accountID: String
    /// Draft namespace within the account: a canonical ticket ID or
    /// `SupportDraftStore.newTicketThreadKey`.
    let thread: String
    var phase: Phase
    var categoryKey: String?
    var subject: String?
    var message: String
    /// Canonical lowercase UUID string; survives with the text so an ambiguous POST outcome can
    /// be replayed idempotently instead of duplicated.
    let clientMessageID: String
    var updatedAt: Date

    init(
        accountID: String,
        thread: String,
        phase: Phase = .draft,
        categoryKey: String? = nil,
        subject: String? = nil,
        message: String,
        clientMessageID: String,
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.accountID = accountID
        self.thread = thread
        self.phase = phase
        self.categoryKey = categoryKey
        self.subject = subject
        self.message = message
        self.clientMessageID = clientMessageID
        self.updatedAt = updatedAt
    }

    /// Strict record validation, applied on every load AND before every save. Structure: exact
    /// current schema version; canonical account UUID equal to the requesting account; the
    /// exact requested thread key, which must itself be a valid namespace (exactly the
    /// new-ticket key or a canonical ticket UUID — arbitrary strings can never name a record);
    /// canonical idempotency UUID; contract bounds on subject, body, and category. The rules
    /// are additionally phase- and flow-specific:
    /// - a ticket-thread record never carries the new-ticket-only fields (subject/category);
    /// - a `.draft` may hold partial mid-typing content within bounds;
    /// - a `.pendingReplay` is a frozen POST attempt, so its message must be EXACTLY a
    ///   normalized non-empty body, and a new-ticket attempt must also carry an exactly
    ///   normalized subject and a selected category key.
    /// Content beyond these rules is never persisted, so a stored record violating them is
    /// corruption and fails closed.
    func isValid(accountID requestedAccountID: String, thread requestedThread: String) -> Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              SupportContract.canonicalAccountID(accountID) == accountID,
              accountID == requestedAccountID,
              thread == requestedThread,
              SupportDraftStore.isValidThreadKey(thread),
              SupportContract.canonicalUUID(clientMessageID) == clientMessageID,
              message.count <= SupportContract.messageMaximumLength
        else { return false }

        let isNewTicketThread = thread == SupportDraftStore.newTicketThreadKey
        if isNewTicketThread {
            guard subject.map({ $0.count <= SupportContract.subjectMaximumLength }) ?? true,
                  categoryKey.map({
                      SupportContract.isBoundedServerText(
                          $0,
                          maximum: SupportContract.categoryTextMaximumLength
                      )
                  }) ?? true
            else { return false }
        } else {
            guard subject == nil, categoryKey == nil else { return false }
        }

        switch phase {
        case .draft:
            return true
        case .pendingReplay:
            guard SupportContract.normalizedMessageBody(message) == message else { return false }
            if isNewTicketThread {
                guard let subject,
                      SupportContract.normalizedSubject(subject) == subject,
                      categoryKey != nil
                else { return false }
            }
            return true
        }
    }
}

enum SupportDraftStoreError: LocalizedError, Equatable {
    case unreadable
    case unverifiedWrite
    case unverifiedRemoval

    var errorDescription: String? {
        switch self {
        case .unreadable:
            "Your saved draft can't be read from protected storage right now."
        case .unverifiedWrite:
            "Your draft can't be saved to protected storage, so sending is paused to protect it."
        case .unverifiedRemoval:
            "Your draft couldn't be fully cleared from protected storage."
        }
    }
}

/// Backing storage seam for drafts so the policy is testable without a live Keychain.
/// `Sendable` so the store's existential is safe under strict concurrency.
protocol SupportDraftPersistence: Sendable {
    func data(for account: String) throws -> Data?
    func set(_ data: Data, for account: String) throws
    func remove(_ account: String) throws
}

/// Production persistence: the app Keychain (generic password items, accessible after first
/// unlock, this device only, never synchronized). Draft plaintext and idempotency UUIDs must
/// never sit in UserDefaults or any plist-backed store. Stateless, hence trivially Sendable;
/// the Keychain itself serializes concurrent SecItem calls.
struct SupportKeychainDraftPersistence: SupportDraftPersistence {
    func data(for account: String) throws -> Data? {
        try KeychainStore.data(for: account)
    }

    func set(_ data: Data, for account: String) throws {
        try KeychainStore.set(data, for: account)
    }

    func remove(_ account: String) throws {
        try KeychainStore.remove(account)
    }
}

/// One protected-storage record per account naming every thread key that currently holds a
/// draft/idempotency record. Maintained index-FIRST on save, so a draft record can never exist
/// outside the enumerable index (an over-counting index after a failed trim merely makes a purge
/// clear an already-absent key; an under-counting one could leak plaintext past account
/// deletion). This is what makes a verified account-wide purge possible at all: the app's
/// Keychain seam cannot enumerate items by prefix.
struct SupportDraftIndexRecord: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let accountID: String
    var threads: [String]

    init(accountID: String, threads: [String]) {
        self.schemaVersion = Self.currentSchemaVersion
        self.accountID = accountID
        self.threads = threads
    }

    func isValid(accountID requestedAccountID: String) -> Bool {
        schemaVersion == Self.currentSchemaVersion
            && SupportContract.canonicalAccountID(accountID) == accountID
            && accountID == requestedAccountID
            && threads.count <= SupportDraftStore.maxIndexedThreads
            && Set(threads).count == threads.count
            && threads.allSatisfy(SupportDraftStore.isValidThreadKey)
    }
}

/// Verified, error-reporting protected storage for composer drafts. Every operation either
/// provably succeeds or throws; callers must treat a save failure as "durability unproven" and
/// keep the composer blocked from submitting until a later save verifies.
///
/// Main-actor isolated: every call site is UI code, and isolating the store gives all
/// read-modify-write sequences (save → read-back, remove → read-back, index maintenance) a
/// total order without a non-Sendable shared existential escaping across threads.
@MainActor
final class SupportDraftStore {
    nonisolated static let accountPrefix = "support.draft.v2"
    /// Thread key for the new-ticket composer (no ticket ID exists yet).
    nonisolated static let newTicketThreadKey = "new-ticket"
    /// Reserved suffix of the per-account index record; `isValidThreadKey` rejects it, so no
    /// draft record can ever collide with the index.
    nonisolated static let indexThreadKey = "index"
    nonisolated static let maxIndexedThreads = 200

    static let shared = SupportDraftStore(persistence: SupportKeychainDraftPersistence())

    private let persistence: SupportDraftPersistence

    init(persistence: SupportDraftPersistence) {
        self.persistence = persistence
    }

    /// A draft namespace is exactly the new-ticket key or a canonical ticket UUID. Arbitrary
    /// strings — including the reserved index suffix — can never name a record.
    nonisolated static func isValidThreadKey(_ thread: String) -> Bool {
        thread == newTicketThreadKey || SupportContract.canonicalTicketID(thread) == thread
    }

    nonisolated static func storageAccount(accountID: String, thread: String) -> String {
        "\(accountPrefix).\(accountID).\(thread)"
    }

    nonisolated static func indexStorageAccount(accountID: String) -> String {
        "\(accountPrefix).\(accountID).\(indexThreadKey)"
    }

    /// Every raw-argument entry point constructs its storage key ONLY through this guard: a
    /// non-canonical account or an invalid thread namespace — including the reserved index
    /// suffix — throws before any key is formed, so no `load`/`clear` argument can ever address
    /// (let alone delete) the account index record or alias another account's key space.
    private nonisolated static func guardedStorageAccount(
        accountID: String,
        thread: String,
        failure: SupportDraftStoreError
    ) throws -> String {
        guard SupportContract.canonicalAccountID(accountID) == accountID,
              isValidThreadKey(thread)
        else { throw failure }
        return storageAccount(accountID: accountID, thread: thread)
    }

    /// Returns nil only for "no draft stored". A storage failure, an undecodable blob, or a
    /// record failing strict validation against the requesting account+thread throws, so callers
    /// fail closed — they must NOT mint or reuse idempotency authority over an unknown or
    /// corrupted prior record.
    func load(accountID: String, thread: String) throws -> SupportComposerDraft? {
        let account = try Self.guardedStorageAccount(
            accountID: accountID,
            thread: thread,
            failure: .unreadable
        )
        let stored: Data?
        do {
            stored = try persistence.data(for: account)
        } catch {
            throw SupportDraftStoreError.unreadable
        }
        guard let stored else { return nil }
        guard let draft = try? JSONDecoder().decode(SupportComposerDraft.self, from: stored),
              draft.isValid(accountID: accountID, thread: thread)
        else { throw SupportDraftStoreError.unreadable }
        return draft
    }

    /// Durable, verified write of a strictly valid record: validates the envelope, commits the
    /// thread to the account index FIRST (so the record is enumerable before it exists), encodes
    /// once, writes the blob, reads it back, and requires byte-for-byte equality. Anything less
    /// throws, and the caller must treat durability as unproven.
    func save(_ draft: SupportComposerDraft) throws {
        guard draft.isValid(accountID: draft.accountID, thread: draft.thread) else {
            throw SupportDraftStoreError.unverifiedWrite
        }
        do {
            try indexThread(draft.thread, accountID: draft.accountID)
        } catch {
            throw SupportDraftStoreError.unverifiedWrite
        }
        let account = Self.storageAccount(accountID: draft.accountID, thread: draft.thread)
        guard let encoded = try? JSONEncoder().encode(draft) else {
            throw SupportDraftStoreError.unverifiedWrite
        }
        do {
            try persistence.set(encoded, for: account)
            guard try persistence.data(for: account) == encoded else {
                throw SupportDraftStoreError.unverifiedWrite
            }
        } catch {
            throw SupportDraftStoreError.unverifiedWrite
        }
    }

    /// Verified removal of one record: deletes it, reads back, and requires that nothing
    /// remains. Arguments are canonically gated BEFORE any key is formed — `thread: "index"`
    /// (or any other invalid namespace) throws instead of resolving to the account index
    /// record. The index entry is then trimmed best-effort ONLY — a failed or skipped trim
    /// leaves a harmless over-count, and never blocks the verified removal itself.
    func clear(accountID: String, thread: String) throws {
        let account = try Self.guardedStorageAccount(
            accountID: accountID,
            thread: thread,
            failure: .unverifiedRemoval
        )
        try removeVerified(account)
        if let index = try? loadIndexRecord(accountID: accountID),
           index.threads.contains(thread) {
            var trimmed = index
            trimmed.threads.removeAll { $0 == thread }
            try? writeIndexRecord(trimmed, accountID: accountID)
        }
    }

    /// Verified account-wide purge for accepted account deletion: enumerates the account's
    /// records via the index (an unreadable index throws, keeping the deletion cleanup blocked
    /// and retried rather than silently leaving unenumerable plaintext behind), removes every
    /// record with read-back proof — the fixed new-ticket key unconditionally, so a missing
    /// index still cannot strand it — and finally removes the index itself, again verified.
    func purgeAccount(accountID rawAccountID: String) throws {
        guard let accountID = SupportContract.canonicalAccountID(rawAccountID) else {
            // Records can only ever be saved under a canonical account UUID, so a malformed
            // target cannot name any record — but a purge must never silently no-op.
            throw SupportDraftStoreError.unreadable
        }
        let index = try loadIndexRecord(accountID: accountID)
        var threads = Set(index?.threads ?? [])
        threads.insert(Self.newTicketThreadKey)
        for thread in threads.sorted() {
            try removeVerified(Self.storageAccount(accountID: accountID, thread: thread))
        }
        try removeVerified(Self.indexStorageAccount(accountID: accountID))
    }

    private func removeVerified(_ account: String) throws {
        let residual: Data?
        do {
            try persistence.remove(account)
            residual = try persistence.data(for: account)
        } catch {
            throw SupportDraftStoreError.unverifiedRemoval
        }
        guard residual == nil else { throw SupportDraftStoreError.unverifiedRemoval }
    }

    private func loadIndexRecord(accountID: String) throws -> SupportDraftIndexRecord? {
        let account = Self.indexStorageAccount(accountID: accountID)
        let stored: Data?
        do {
            stored = try persistence.data(for: account)
        } catch {
            throw SupportDraftStoreError.unreadable
        }
        guard let stored else { return nil }
        guard let record = try? JSONDecoder().decode(SupportDraftIndexRecord.self, from: stored),
              record.isValid(accountID: accountID)
        else { throw SupportDraftStoreError.unreadable }
        return record
    }

    private func indexThread(_ thread: String, accountID: String) throws {
        let existing = try loadIndexRecord(accountID: accountID)
        if let existing, existing.threads.contains(thread) { return }
        var record = existing ?? SupportDraftIndexRecord(accountID: accountID, threads: [])
        guard record.threads.count < Self.maxIndexedThreads else {
            throw SupportDraftStoreError.unverifiedWrite
        }
        record.threads.append(thread)
        try writeIndexRecord(record, accountID: accountID)
    }

    private func writeIndexRecord(
        _ record: SupportDraftIndexRecord,
        accountID: String
    ) throws {
        guard record.isValid(accountID: accountID) else {
            throw SupportDraftStoreError.unverifiedWrite
        }
        let account = Self.indexStorageAccount(accountID: accountID)
        guard let encoded = try? JSONEncoder().encode(record) else {
            throw SupportDraftStoreError.unverifiedWrite
        }
        do {
            try persistence.set(encoded, for: account)
            guard try persistence.data(for: account) == encoded else {
                throw SupportDraftStoreError.unverifiedWrite
            }
        } catch {
            throw SupportDraftStoreError.unverifiedWrite
        }
    }
}

/// Deliberately has no `media_asset_id` field (see `SupportContract.attachmentsSupported`): this
/// version cannot produce authenticated attachments, so the wire contract fails closed and the
/// encode tests pin the exact key set.
struct OpenSupportTicketRequestDTO: Encodable, Equatable, Sendable {
    let categoryKey: String
    let subject: String
    let message: String
    let clientMessageID: String

    private enum CodingKeys: String, CodingKey {
        case categoryKey = "category_key"
        case subject
        case message
        case clientMessageID = "client_message_id"
    }
}

/// Deliberately has no `media_asset_id` field (see `SupportContract.attachmentsSupported`).
struct SendSupportMessageRequestDTO: Encodable, Equatable, Sendable {
    let body: String
    let clientMessageID: String

    private enum CodingKeys: String, CodingKey {
        case body
        case clientMessageID = "client_message_id"
    }
}

enum SupportContractError: LocalizedError, Equatable {
    case invalidTicketID
    case invalidSubject
    case invalidMessageBody
    case invalidCategory
    case inconsistentThread
    case inconsistentList
    case deliveryUnconfirmed
    case supportUnavailable
    case paymentUnconfirmed

    var errorDescription: String? {
        switch self {
        case .invalidTicketID: "This support request could not be opened safely."
        case .invalidSubject: "Enter a short subject between 3 and 140 characters."
        case .invalidMessageBody: "Enter a message of up to 4000 characters."
        case .invalidCategory: "Choose a support category."
        case .inconsistentThread:
            "Some messages could not be loaded safely. Pull down to try again."
        case .inconsistentList:
            "Some support requests could not be loaded safely. Pull down to try again."
        case .deliveryUnconfirmed:
            "We couldn't confirm this was delivered. It's kept safely on this screen — "
                + "sending again will not create a duplicate."
        case .supportUnavailable:
            "Kit Pay support is not available right now. Your draft is kept on this screen."
        case .paymentUnconfirmed:
            "We couldn't confirm this payment. It's kept safely here — confirming it again "
                + "will not charge you twice."
        }
    }
}

enum SupportDates {
    private static let iso8601 = ISO8601DateFormatter()

    /// The backend emits `toIso8601ZuluString()` (no fractional seconds); the fractional variant
    /// is also accepted so a benign format upgrade cannot invalidate otherwise-consistent pages.
    private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        return iso8601.date(from: value) ?? iso8601Fractional.date(from: value)
    }
}
