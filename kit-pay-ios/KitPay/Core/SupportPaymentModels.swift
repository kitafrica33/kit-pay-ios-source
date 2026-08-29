import Foundation

/// Customer-initiated payments inside a support ticket. The contract is deliberately one-way:
/// support can NEVER request money, no request field can express a destination (the server
/// routes every support payment to its configured company commission wallet and rejects
/// `destination`/`destination_wallet_id` outright), and the only payee identity this client may
/// ever render is the server-authored company beneficiary block. Everything here fails closed:
/// the surface is dark unless the server advertises the exact payments contract
/// (`SupportGate.paymentsState`), a payment attempt is frozen in protected storage BEFORE its
/// POST so an ambiguous outcome is always resolvable by verbatim idempotent replay, and a
/// malformed response or record never mints fresh idempotency authority.
enum SupportPaymentContract {
    /// Step-up purpose; the server hashes it with the exact intent fields below.
    static let stepUpPurpose = "support_payment"
    /// The collapsed server flag: true only when support, wallets, internal transfers, AND a
    /// validated commission wallet are all live. Re-checked client-side with the underlying
    /// flags anyway — defense in depth, never a substitute for the server's own gate.
    static let featureKey = "support_payments"
    static let walletsFeatureKey = "wallets"
    static let internalTransfersFeatureKey = "internal_transfers"
    /// The only beneficiary kind this client will ever display or pay.
    static let beneficiaryKindCompany = "company"

    /// Server validation bounds (`support/tickets/{ticket}/payments`).
    static let amountMaximumLength = 40
    static let noteMaximumLength = 280

    /// Server regex for the `Idempotency-Key` header: `^[A-Za-z0-9._:-]{16,128}$`.
    static let idempotencyKeyMinimumLength = 16
    static let idempotencyKeyMaximumLength = 128
    static let mintedIdempotencyKeyPrefix = "ios-support-payment-"

    /// Bounds applied to server-provided receipt text before anything reaches the UI.
    static let transactionIDMaximumLength = 64
    static let statusMaximumLength = 40
    static let currencyCodeMaximumLength = 8
    static let currencyScaleRange = 0...9

    private static let idempotencyKeyAlphabet = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:-"
    )

    /// One key per REVIEWED confirmation: minted when the review screen is entered and reused
    /// verbatim for every retry of that same confirmation. It may rotate only when the reviewed
    /// intent changes (before any freeze) — never while a frozen attempt exists.
    static func mintIdempotencyKey() -> String {
        mintedIdempotencyKeyPrefix + UUID().uuidString.lowercased()
    }

    static func isValidIdempotencyKey(_ value: String) -> Bool {
        value.count >= idempotencyKeyMinimumLength
            && value.count <= idempotencyKeyMaximumLength
            && value.allSatisfy { idempotencyKeyAlphabet.contains($0) }
    }

    /// Normalizes customer-typed amount text into the exact API decimal string, mirroring the
    /// wallet-transfer normalizer: strips grouping commas, requires ASCII digits only, pads the
    /// fraction to the wallet's scale, and rejects zero, negatives, and excess precision. Any
    /// deviation returns nil — the client never "fixes up" money text beyond these rules.
    static func apiAmount(_ raw: String, scale: Int) -> String? {
        let scale = min(max(scale, 0), 9)
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
        let pieces = cleaned.split(separator: ".", omittingEmptySubsequences: false)
        guard !cleaned.isEmpty, pieces.count <= 2 else { return nil }
        let wholeRaw = String(pieces.first ?? "")
        let fractionRaw = pieces.count == 2 ? String(pieces[1]) : ""
        guard !wholeRaw.isEmpty,
              wholeRaw.allSatisfy({ $0.isASCII && $0.isNumber }),
              fractionRaw.allSatisfy({ $0.isASCII && $0.isNumber }),
              fractionRaw.count <= scale
        else { return nil }

        let whole = String(wholeRaw.drop(while: { $0 == "0" })).nilIfEmpty ?? "0"
        let fraction = fractionRaw + String(repeating: "0", count: scale - fractionRaw.count)
        let result = scale == 0 ? whole : "\(whole).\(fraction)"
        guard let decimal = Decimal(string: result, locale: Locale(identifier: "en_US_POSIX")),
              decimal > 0
        else { return nil }
        return result
    }

    /// Whether a stored or server-provided amount string is exactly the canonical shape
    /// `apiAmount` produces (and the server's money formatter emits): bounded, ASCII digits with
    /// at most one point, no redundant leading zero, non-empty fraction when present, strictly
    /// positive. Frozen envelopes and receipt amounts failing this are rejected, never rendered
    /// or replayed.
    static func isCanonicalAPIAmount(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= amountMaximumLength else { return false }
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count <= 2,
              let whole = pieces.first,
              !whole.isEmpty,
              whole.allSatisfy({ $0.isASCII && $0.isNumber }),
              whole == "0" || !whole.hasPrefix("0")
        else { return false }
        if pieces.count == 2 {
            let fraction = pieces[1]
            guard !fraction.isEmpty, fraction.allSatisfy({ $0.isASCII && $0.isNumber }) else {
                return false
            }
        }
        guard let decimal = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")),
              decimal > 0
        else { return false }
        return true
    }

    /// A note is coherent when absent, or exactly its own trimmed non-empty bounded text — a
    /// frozen note is part of the step-up intent hash, so it must be byte-stable across replays.
    static func isCoherentNote(_ note: String?) -> Bool {
        guard let note else { return true }
        return !note.isEmpty
            && note.count <= noteMaximumLength
            && note == note.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Advertisement state for the support-payments surface. Dark unless every server signal agrees;
/// `beneficiaryDisplayName` is the pre-flight payee shown BEFORE a payment (the authoritative
/// name on a receipt comes from the payment response itself).
enum SupportPaymentsGateState: Equatable, Sendable {
    case unavailable
    case available(beneficiaryDisplayName: String)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    var beneficiaryDisplayName: String? {
        if case .available(let name) = self { return name }
        return nil
    }
}

extension SupportGate {
    /// The payments surface requires the FULL support gate plus the exact payments
    /// advertisement: `features.support_payments`, `features.wallets`, and
    /// `features.internal_transfers` all explicitly true, `protocols.support.payments.ready`
    /// true, and the company beneficiary kind. The server already collapses the underlying
    /// requirements into `support_payments`; the client re-checks the parts anyway so a
    /// contradictory advertisement fails closed instead of trusting either side alone.
    static func paymentsState(for capabilities: CapabilitiesDTO?) -> SupportPaymentsGateState {
        paymentsState(
            features: capabilities?.features,
            support: capabilities?.protocols?.support
        )
    }

    static func paymentsState(
        features: [String: Bool?]?,
        support: SupportProtocolDTO?
    ) -> SupportPaymentsGateState {
        guard state(features: features, support: support).isAvailable,
              let features,
              features[SupportPaymentContract.featureKey] == true,
              features[SupportPaymentContract.walletsFeatureKey] == true,
              features[SupportPaymentContract.internalTransfersFeatureKey] == true,
              let support,
              support.payments.ready,
              support.payments.beneficiaryKind == SupportPaymentContract.beneficiaryKindCompany
        else { return .unavailable }
        return .available(beneficiaryDisplayName: support.payments.beneficiaryDisplayName)
    }
}

/// One frozen payment attempt, persisted in protected storage BEFORE its POST. Its existence IS
/// the pending state: an authoritative receipt or a definitive server rejection clears it
/// (verified), anything ambiguous keeps it for verbatim replay under the same idempotency key —
/// the server resolves replays before its closed-ticket check, so resolution stays possible even
/// after the ticket closes, and a replay can never charge twice.
struct SupportPaymentEnvelope: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    /// Canonical account UUID (`SupportContract.canonicalAccountID`).
    let accountID: String
    /// Canonical ticket UUID; payments exist only inside an existing ticket.
    let ticketID: String
    /// Canonical wallet UUID the customer chose to pay from.
    let sourceWalletID: String
    /// Exact API decimal string (`SupportPaymentContract.apiAmount` output), replayed verbatim.
    let amount: String
    /// Exact normalized note or nil; part of the step-up intent hash, so byte-stable.
    let note: String?
    /// Display-only currency identity captured from the chosen wallet at review time, so the
    /// pending notice can show honest money text even if the wallet list later changes.
    let currencyCode: String
    let currencyScale: Int
    /// Frozen `Idempotency-Key`; the server scopes it to the ticket, so it can never replay
    /// another ticket's transfer.
    let idempotencyKey: String
    let createdAt: Date

    init(
        accountID: String,
        ticketID: String,
        sourceWalletID: String,
        amount: String,
        note: String?,
        currencyCode: String,
        currencyScale: Int,
        idempotencyKey: String,
        createdAt: Date = Date()
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.accountID = accountID
        self.ticketID = ticketID
        self.sourceWalletID = sourceWalletID
        self.amount = amount
        self.note = note
        self.currencyCode = currencyCode
        self.currencyScale = currencyScale
        self.idempotencyKey = idempotencyKey
        self.createdAt = createdAt
    }

    /// The exact step-up intent the server hashes (`['ticket_id', 'source_wallet_id', 'amount',
    /// 'note' ?? null]`). A nil note MUST be sent as an explicit null, so the dictionary always
    /// carries all four keys.
    var stepUpIntent: [String: String?] {
        [
            "ticket_id": ticketID,
            "source_wallet_id": sourceWalletID,
            "amount": amount,
            "note": note,
        ]
    }

    /// Strict record validation, applied on every load AND before every save. A stored record
    /// violating any rule is corruption and fails closed (`.unreadable`) — the client never
    /// replays, renders, or silently replaces a record it cannot fully vouch for, because a
    /// discarded idempotency key plus a fresh attempt is exactly how a double charge happens.
    func isValid(accountID requestedAccountID: String, ticketID requestedTicketID: String) -> Bool {
        schemaVersion == Self.currentSchemaVersion
            && SupportContract.canonicalAccountID(accountID) == accountID
            && accountID == requestedAccountID
            && SupportContract.canonicalTicketID(ticketID) == ticketID
            && ticketID == requestedTicketID
            && SupportContract.canonicalUUID(sourceWalletID) == sourceWalletID
            && SupportPaymentContract.isCanonicalAPIAmount(amount)
            && SupportPaymentContract.isCoherentNote(note)
            && SupportContract.isBoundedServerText(
                currencyCode,
                maximum: SupportPaymentContract.currencyCodeMaximumLength
            )
            && SupportPaymentContract.currencyScaleRange.contains(currencyScale)
            && SupportPaymentContract.isValidIdempotencyKey(idempotencyKey)
    }
}

enum SupportPaymentStoreError: LocalizedError, Equatable {
    case unreadable
    case unverifiedWrite
    case unverifiedRemoval

    var errorDescription: String? {
        switch self {
        case .unreadable:
            "A saved payment attempt can't be read from protected storage on this device."
        case .unverifiedWrite:
            "This payment can't be saved to protected storage, so it wasn't started."
        case .unverifiedRemoval:
            "The saved payment attempt couldn't be fully cleared from protected storage."
        }
    }
}

/// Per-account index of ticket IDs that currently hold a frozen payment envelope, maintained
/// index-FIRST on save so every envelope is enumerable — the account-deletion purge depends on
/// it (the Keychain seam cannot enumerate by prefix).
struct SupportPaymentIndexRecord: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let accountID: String
    var tickets: [String]

    init(accountID: String, tickets: [String]) {
        self.schemaVersion = Self.currentSchemaVersion
        self.accountID = accountID
        self.tickets = tickets
    }

    func isValid(accountID requestedAccountID: String) -> Bool {
        schemaVersion == Self.currentSchemaVersion
            && SupportContract.canonicalAccountID(accountID) == accountID
            && accountID == requestedAccountID
            && tickets.count <= SupportPaymentStore.maxIndexedTickets
            && Set(tickets).count == tickets.count
            && tickets.allSatisfy(SupportPaymentStore.isValidTicketKey)
    }
}

/// Verified, error-reporting protected storage for frozen payment attempts — a deliberate
/// parallel of `SupportDraftStore` (same persistence seam, same verified-write / verified-removal
/// / index-first / verified-purge discipline) over a stricter namespace: payment records exist
/// ONLY under a canonical ticket UUID, in a separate `support.payment.v1` key space with its own
/// index, so a payment envelope and a message draft can never alias each other. Every operation
/// either provably succeeds or throws; a failed save means the POST it was guarding must not run.
@MainActor
final class SupportPaymentStore {
    nonisolated static let accountPrefix = "support.payment.v1"
    /// Reserved suffix of the per-account index record; `isValidTicketKey` rejects it, so no
    /// envelope can ever collide with the index.
    nonisolated static let indexTicketKey = "index"
    nonisolated static let maxIndexedTickets = 200

    static let shared = SupportPaymentStore(persistence: SupportKeychainDraftPersistence())

    private let persistence: SupportDraftPersistence

    init(persistence: SupportDraftPersistence) {
        self.persistence = persistence
    }

    /// A payment namespace is exactly a canonical ticket UUID — there is no new-ticket variant,
    /// and arbitrary strings (including the reserved index suffix) can never name a record.
    nonisolated static func isValidTicketKey(_ ticketID: String) -> Bool {
        SupportContract.canonicalTicketID(ticketID) == ticketID
    }

    nonisolated static func storageAccount(accountID: String, ticketID: String) -> String {
        "\(accountPrefix).\(accountID).\(ticketID)"
    }

    nonisolated static func indexStorageAccount(accountID: String) -> String {
        "\(accountPrefix).\(accountID).\(indexTicketKey)"
    }

    private nonisolated static func guardedStorageAccount(
        accountID: String,
        ticketID: String,
        failure: SupportPaymentStoreError
    ) throws -> String {
        guard SupportContract.canonicalAccountID(accountID) == accountID,
              isValidTicketKey(ticketID)
        else { throw failure }
        return storageAccount(accountID: accountID, ticketID: ticketID)
    }

    /// Returns nil only for "no frozen attempt". A storage failure, an undecodable blob, or a
    /// record failing strict validation throws — the caller must NOT start a fresh payment over
    /// an unknown prior attempt.
    func load(accountID: String, ticketID: String) throws -> SupportPaymentEnvelope? {
        let account = try Self.guardedStorageAccount(
            accountID: accountID,
            ticketID: ticketID,
            failure: .unreadable
        )
        let stored: Data?
        do {
            stored = try persistence.data(for: account)
        } catch {
            throw SupportPaymentStoreError.unreadable
        }
        guard let stored else { return nil }
        guard let envelope = try? JSONDecoder().decode(
                SupportPaymentEnvelope.self,
                from: stored
              ),
              envelope.isValid(accountID: accountID, ticketID: ticketID)
        else { throw SupportPaymentStoreError.unreadable }
        return envelope
    }

    /// Durable, verified write of a strictly valid envelope: index-FIRST, encode once, write,
    /// read back byte-for-byte. Anything less throws and the guarded POST must not run.
    func save(_ envelope: SupportPaymentEnvelope) throws {
        guard envelope.isValid(accountID: envelope.accountID, ticketID: envelope.ticketID) else {
            throw SupportPaymentStoreError.unverifiedWrite
        }
        do {
            try indexTicket(envelope.ticketID, accountID: envelope.accountID)
        } catch {
            throw SupportPaymentStoreError.unverifiedWrite
        }
        let account = Self.storageAccount(
            accountID: envelope.accountID,
            ticketID: envelope.ticketID
        )
        guard let encoded = try? JSONEncoder().encode(envelope) else {
            throw SupportPaymentStoreError.unverifiedWrite
        }
        do {
            try persistence.set(encoded, for: account)
            guard try persistence.data(for: account) == encoded else {
                throw SupportPaymentStoreError.unverifiedWrite
            }
        } catch {
            throw SupportPaymentStoreError.unverifiedWrite
        }
    }

    /// Verified removal of one envelope (read-back must find nothing); the index entry is then
    /// trimmed best-effort only — an over-counting index is harmless, an unverified removal
    /// is not.
    func clear(accountID: String, ticketID: String) throws {
        let account = try Self.guardedStorageAccount(
            accountID: accountID,
            ticketID: ticketID,
            failure: .unverifiedRemoval
        )
        try removeVerified(account)
        if let index = try? loadIndexRecord(accountID: accountID),
           index.tickets.contains(ticketID) {
            var trimmed = index
            trimmed.tickets.removeAll { $0 == ticketID }
            try? writeIndexRecord(trimmed, accountID: accountID)
        }
    }

    /// Verified account-wide purge for accepted account deletion (same contract as the draft
    /// store): an unreadable index throws — keeping the deletion cleanup blocked and retried —
    /// every indexed envelope is removed with read-back proof, then the index itself.
    func purgeAccount(accountID rawAccountID: String) throws {
        guard let accountID = SupportContract.canonicalAccountID(rawAccountID) else {
            throw SupportPaymentStoreError.unreadable
        }
        let index = try loadIndexRecord(accountID: accountID)
        for ticketID in (index?.tickets ?? []).sorted() {
            try removeVerified(Self.storageAccount(accountID: accountID, ticketID: ticketID))
        }
        try removeVerified(Self.indexStorageAccount(accountID: accountID))
    }

    private func removeVerified(_ account: String) throws {
        let residual: Data?
        do {
            try persistence.remove(account)
            residual = try persistence.data(for: account)
        } catch {
            throw SupportPaymentStoreError.unverifiedRemoval
        }
        guard residual == nil else { throw SupportPaymentStoreError.unverifiedRemoval }
    }

    private func loadIndexRecord(accountID: String) throws -> SupportPaymentIndexRecord? {
        let account = Self.indexStorageAccount(accountID: accountID)
        let stored: Data?
        do {
            stored = try persistence.data(for: account)
        } catch {
            throw SupportPaymentStoreError.unreadable
        }
        guard let stored else { return nil }
        guard let record = try? JSONDecoder().decode(
                SupportPaymentIndexRecord.self,
                from: stored
              ),
              record.isValid(accountID: accountID)
        else { throw SupportPaymentStoreError.unreadable }
        return record
    }

    private func indexTicket(_ ticketID: String, accountID: String) throws {
        let existing = try loadIndexRecord(accountID: accountID)
        if let existing, existing.tickets.contains(ticketID) { return }
        var record = existing ?? SupportPaymentIndexRecord(accountID: accountID, tickets: [])
        guard record.tickets.count < Self.maxIndexedTickets else {
            throw SupportPaymentStoreError.unverifiedWrite
        }
        record.tickets.append(ticketID)
        try writeIndexRecord(record, accountID: accountID)
    }

    private func writeIndexRecord(
        _ record: SupportPaymentIndexRecord,
        accountID: String
    ) throws {
        guard record.isValid(accountID: accountID) else {
            throw SupportPaymentStoreError.unverifiedWrite
        }
        let account = Self.indexStorageAccount(accountID: accountID)
        guard let encoded = try? JSONEncoder().encode(record) else {
            throw SupportPaymentStoreError.unverifiedWrite
        }
        do {
            try persistence.set(encoded, for: account)
            guard try persistence.data(for: account) == encoded else {
                throw SupportPaymentStoreError.unverifiedWrite
            }
        } catch {
            throw SupportPaymentStoreError.unverifiedWrite
        }
    }
}

/// Wire body for `POST support/tickets/{ticket}/payments`. Deliberately has NO destination field
/// of any kind — the server rejects `destination_wallet_id`/`destination` as prohibited and
/// resolves the company commission wallet itself. A nil note is OMITTED from the body (the
/// intent hash treats absent and null alike server-side). The encode tests pin the exact key
/// set; never add a key here without a coordinated contract change.
struct SupportPaymentRequestDTO: Encodable, Equatable, Sendable {
    let sourceWalletID: String
    let amount: String
    let note: String?

    private enum CodingKeys: String, CodingKey {
        case sourceWalletID = "source_wallet_id"
        case amount
        case note
    }
}

struct SupportPaymentCurrencyDTO: Equatable, Sendable {
    let code: String
    /// Wire value is a string (`"0"`, `"2"`); validated to a small integer at decode.
    let scale: String

    var decimalScale: Int { Int(scale) ?? 2 }
}

/// The whitelisted ledger transaction the server presents for a support payment — exactly
/// `{id, reference, amount, currency: {code, scale}, status, occurred_at}`. Field VALUES are
/// validated at decode (bounded text, canonical money string, sane scale) so nothing unbounded
/// or incoherent can reach the receipt UI; unknown sibling keys are tolerated so an additive
/// server field cannot strand a committed payment.
struct SupportPaymentTransactionDTO: Equatable, Sendable {
    let id: String
    let reference: String
    let amount: String
    let currency: SupportPaymentCurrencyDTO
    let status: String
    let occurredAt: String
}

extension SupportPaymentTransactionDTO: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id
        case reference
        case amount
        case currency
        case status
        case occurredAt = "occurred_at"
    }

    private enum CurrencyKeys: String, CodingKey {
        case code
        case scale
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        reference = try container.decode(String.self, forKey: .reference)
        amount = try container.decode(String.self, forKey: .amount)
        status = try container.decode(String.self, forKey: .status)
        occurredAt = try container.decode(String.self, forKey: .occurredAt)
        let currencyContainer = try container.nestedContainer(
            keyedBy: CurrencyKeys.self,
            forKey: .currency
        )
        let code = try currencyContainer.decode(String.self, forKey: .code)
        let scale = try currencyContainer.decode(String.self, forKey: .scale)
        currency = SupportPaymentCurrencyDTO(code: code, scale: scale)

        guard SupportContract.isBoundedServerText(
                id,
                maximum: SupportPaymentContract.transactionIDMaximumLength
            ),
            SupportContract.isBoundedServerText(
                reference,
                maximum: SupportContract.referenceMaximumLength
            ),
            SupportPaymentContract.isCanonicalAPIAmount(amount),
            SupportContract.isBoundedServerText(
                status,
                maximum: SupportPaymentContract.statusMaximumLength
            ),
            SupportContract.isBoundedServerText(
                occurredAt,
                maximum: SupportContract.timestampMaximumLength
            ),
            SupportContract.isBoundedServerText(
                code,
                maximum: SupportPaymentContract.currencyCodeMaximumLength
            ),
            let scaleValue = Int(scale),
            SupportPaymentContract.currencyScaleRange.contains(scaleValue)
        else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "Incoherent support payment transaction"
            ))
        }
    }
}

/// The server-authored payee identity — the ONLY counterparty a support payment may ever show.
/// The backend documents this block as exactly `{kind, display_name}` with clients binding
/// strictly: an extra key, a non-company kind, or unbounded text is a broken contract and fails
/// the decode closed (the frozen envelope stays replayable; no receipt is rendered from it).
struct SupportPaymentBeneficiaryDTO: Equatable, Sendable {
    let kind: String
    let displayName: String
}

extension SupportPaymentBeneficiaryDTO: Decodable {
    private struct WireKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private static let allowedKeys: Set<String> = ["kind", "display_name"]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: WireKey.self)
        for key in container.allKeys where !Self.allowedKeys.contains(key.stringValue) {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "Unknown beneficiary key: \(key.stringValue)"
            ))
        }
        kind = try container.decode(String.self, forKey: WireKey("kind"))
        displayName = try container.decode(String.self, forKey: WireKey("display_name"))
        guard kind == SupportPaymentContract.beneficiaryKindCompany,
              SupportContract.isBoundedServerText(
                  displayName,
                  maximum: SupportContract.displayNameMaximumLength
              )
        else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "Incoherent support payment beneficiary"
            ))
        }
    }
}

/// Authoritative payment outcome: `{transaction, beneficiary, ticket_payment_id}`. Only a fully
/// validated receipt may clear a frozen envelope or reach the UI.
struct SupportPaymentReceiptDTO: Equatable, Sendable {
    let transaction: SupportPaymentTransactionDTO
    let beneficiary: SupportPaymentBeneficiaryDTO
    let ticketPaymentID: String
}

extension SupportPaymentReceiptDTO: Decodable {
    private enum CodingKeys: String, CodingKey {
        case transaction
        case beneficiary
        case ticketPaymentID = "ticket_payment_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transaction = try container.decode(
            SupportPaymentTransactionDTO.self,
            forKey: .transaction
        )
        beneficiary = try container.decode(
            SupportPaymentBeneficiaryDTO.self,
            forKey: .beneficiary
        )
        ticketPaymentID = try container.decode(String.self, forKey: .ticketPaymentID)
        guard SupportContract.isBoundedServerText(
            ticketPaymentID,
            maximum: SupportPaymentContract.transactionIDMaximumLength
        ) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "Incoherent support payment identifier"
            ))
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
