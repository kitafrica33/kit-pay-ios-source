import Foundation
import XCTest

@testable import KitPay

/// In-memory persistence seam with fault injection for the payment store (mirrors the draft
/// store's mock; kept file-private here because each suite owns its own seam).
private final class MockPaymentPersistence: SupportDraftPersistence, @unchecked Sendable {
    struct Failure: Error {}

    var storage: [String: Data] = [:]
    var failData = false
    var failSet = false
    var failRemove = false
    /// `remove` reports success but the record survives — the dangerous silent case.
    var removeSilentlyKeepsData = false
    /// `set` reports success but persists corrupted bytes, so read-back must catch it.
    var corruptOnSet = false

    func data(for account: String) throws -> Data? {
        if failData { throw Failure() }
        return storage[account]
    }

    func set(_ data: Data, for account: String) throws {
        if failSet { throw Failure() }
        storage[account] = corruptOnSet ? data + Data([0x21]) : data
    }

    func remove(_ account: String) throws {
        if failRemove { throw Failure() }
        if !removeSilentlyKeepsData { storage[account] = nil }
    }
}

@MainActor
final class SupportPaymentTests: XCTestCase {
    private let accountID = "11111111-1111-1111-1111-111111111111"
    private let ticketID = "22222222-2222-2222-2222-222222222222"
    private let otherTicketID = "44444444-4444-4444-4444-444444444444"
    private let walletID = "33333333-3333-3333-3333-333333333333"

    private func makeStore() -> (SupportPaymentStore, MockPaymentPersistence) {
        let persistence = MockPaymentPersistence()
        return (SupportPaymentStore(persistence: persistence), persistence)
    }

    private func makeEnvelope(
        accountID: String? = nil,
        ticketID: String? = nil,
        sourceWalletID: String? = nil,
        amount: String = "1250000.00",
        note: String? = "Loan repayment",
        currencyCode: String = "UGX",
        currencyScale: Int = 2,
        idempotencyKey: String = SupportPaymentContract.mintIdempotencyKey()
    ) -> SupportPaymentEnvelope {
        SupportPaymentEnvelope(
            accountID: accountID ?? self.accountID,
            ticketID: ticketID ?? self.ticketID,
            sourceWalletID: sourceWalletID ?? walletID,
            amount: amount,
            note: note,
            currencyCode: currencyCode,
            currencyScale: currencyScale,
            idempotencyKey: idempotencyKey
        )
    }

    // MARK: - Idempotency key (server regex ^[A-Za-z0-9._:-]{16,128}$)

    func testMintedIdempotencyKeyIsPrefixedBoundedAndValid() {
        let key = SupportPaymentContract.mintIdempotencyKey()
        XCTAssertTrue(key.hasPrefix("ios-support-payment-"))
        XCTAssertEqual(key.count, 56) // 20-char prefix + 36-char lowercased UUID
        XCTAssertTrue(SupportPaymentContract.isValidIdempotencyKey(key))
        // Every mint is unique — reuse across DIFFERENT intents is what the mint prevents.
        XCTAssertNotEqual(key, SupportPaymentContract.mintIdempotencyKey())
    }

    func testIdempotencyKeyLengthBoundaries() {
        XCTAssertFalse(
            SupportPaymentContract.isValidIdempotencyKey(String(repeating: "a", count: 15))
        )
        XCTAssertTrue(
            SupportPaymentContract.isValidIdempotencyKey(String(repeating: "a", count: 16))
        )
        XCTAssertTrue(
            SupportPaymentContract.isValidIdempotencyKey(String(repeating: "a", count: 128))
        )
        XCTAssertFalse(
            SupportPaymentContract.isValidIdempotencyKey(String(repeating: "a", count: 129))
        )
    }

    func testIdempotencyKeyCharsetMatchesServerRegex() {
        XCTAssertTrue(
            SupportPaymentContract.isValidIdempotencyKey("AZaz09._:-AZaz09._:-")
        )
        XCTAssertFalse(
            SupportPaymentContract.isValidIdempotencyKey("has spaces not allowed")
        )
        XCTAssertFalse(
            SupportPaymentContract.isValidIdempotencyKey("euro-sign-€-not-allowed")
        )
        XCTAssertFalse(
            SupportPaymentContract.isValidIdempotencyKey("slash/not/allowed-000")
        )
    }

    // MARK: - Amount normalization (mirror of the wallet-transfer normalizer)

    func testAPIAmountNormalizesGroupedAndPaddedInput() {
        XCTAssertEqual(SupportPaymentContract.apiAmount("1,250,000", scale: 2), "1250000.00")
        XCTAssertEqual(SupportPaymentContract.apiAmount("000123", scale: 0), "123")
        XCTAssertEqual(SupportPaymentContract.apiAmount("  25 ", scale: 0), "25")
        XCTAssertEqual(SupportPaymentContract.apiAmount("1.", scale: 2), "1.00")
        XCTAssertEqual(SupportPaymentContract.apiAmount("7.5", scale: 2), "7.50")
    }

    func testAPIAmountRejectsIncoherentInput() {
        XCTAssertNil(SupportPaymentContract.apiAmount("0", scale: 2))
        XCTAssertNil(SupportPaymentContract.apiAmount("0.00", scale: 2))
        XCTAssertNil(SupportPaymentContract.apiAmount("", scale: 2))
        XCTAssertNil(SupportPaymentContract.apiAmount("1.234", scale: 2)) // excess precision
        XCTAssertNil(SupportPaymentContract.apiAmount("1.2.3", scale: 2))
        XCTAssertNil(SupportPaymentContract.apiAmount(".5", scale: 2)) // empty whole part
        XCTAssertNil(SupportPaymentContract.apiAmount("abc", scale: 2))
        XCTAssertNil(SupportPaymentContract.apiAmount("-5", scale: 2))
        // Non-ASCII digits satisfy `\.isNumber` but must never reach a money string.
        XCTAssertNil(SupportPaymentContract.apiAmount("١٢٣", scale: 2))
    }

    func testIsCanonicalAPIAmountMatrix() {
        XCTAssertTrue(SupportPaymentContract.isCanonicalAPIAmount("1250000.00"))
        XCTAssertTrue(SupportPaymentContract.isCanonicalAPIAmount("123"))
        XCTAssertTrue(SupportPaymentContract.isCanonicalAPIAmount("0.50"))

        XCTAssertFalse(SupportPaymentContract.isCanonicalAPIAmount("0.00")) // not positive
        XCTAssertFalse(SupportPaymentContract.isCanonicalAPIAmount("01.00")) // leading zero
        XCTAssertFalse(SupportPaymentContract.isCanonicalAPIAmount("1.")) // empty fraction
        XCTAssertFalse(SupportPaymentContract.isCanonicalAPIAmount(".5")) // empty whole
        XCTAssertFalse(SupportPaymentContract.isCanonicalAPIAmount("1,000")) // grouping
        XCTAssertFalse(SupportPaymentContract.isCanonicalAPIAmount(""))
        XCTAssertFalse(SupportPaymentContract.isCanonicalAPIAmount("1.2.3"))
        XCTAssertFalse(SupportPaymentContract.isCanonicalAPIAmount("١٢٣"))
        XCTAssertFalse(
            SupportPaymentContract.isCanonicalAPIAmount(
                String(repeating: "9", count: SupportPaymentContract.amountMaximumLength + 1)
            )
        )
    }

    // MARK: - Envelope validation and step-up intent

    func testEnvelopeIsValidForCanonicalRecord() {
        let envelope = makeEnvelope()
        XCTAssertTrue(envelope.isValid(accountID: accountID, ticketID: ticketID))
        // Bound to ITS OWN account and ticket only.
        XCTAssertFalse(envelope.isValid(accountID: accountID, ticketID: otherTicketID))
        XCTAssertFalse(
            envelope.isValid(
                accountID: "55555555-5555-5555-5555-555555555555",
                ticketID: ticketID
            )
        )
    }

    func testEnvelopeRejectsIncoherentFields() {
        XCTAssertFalse(
            makeEnvelope(sourceWalletID: "not-a-uuid")
                .isValid(accountID: accountID, ticketID: ticketID)
        )
        XCTAssertFalse(
            makeEnvelope(amount: "01.00").isValid(accountID: accountID, ticketID: ticketID)
        )
        XCTAssertFalse(
            makeEnvelope(amount: "0.00").isValid(accountID: accountID, ticketID: ticketID)
        )
        // A note must be exactly its trimmed non-empty self — it feeds the step-up intent hash.
        XCTAssertFalse(
            makeEnvelope(note: "padded ").isValid(accountID: accountID, ticketID: ticketID)
        )
        XCTAssertFalse(
            makeEnvelope(note: "").isValid(accountID: accountID, ticketID: ticketID)
        )
        XCTAssertFalse(
            makeEnvelope(note: String(repeating: "n", count: 281))
                .isValid(accountID: accountID, ticketID: ticketID)
        )
        XCTAssertTrue(
            makeEnvelope(note: nil).isValid(accountID: accountID, ticketID: ticketID)
        )
        XCTAssertFalse(
            makeEnvelope(currencyCode: "TOOLONGCODE")
                .isValid(accountID: accountID, ticketID: ticketID)
        )
        XCTAssertFalse(
            makeEnvelope(currencyScale: 10).isValid(accountID: accountID, ticketID: ticketID)
        )
        XCTAssertFalse(
            makeEnvelope(idempotencyKey: "short").isValid(accountID: accountID, ticketID: ticketID)
        )
    }

    func testStepUpIntentCarriesExactlyTheServerHashedFields() {
        let intent = makeEnvelope(note: "For my loan").stepUpIntent
        XCTAssertEqual(
            Set(intent.keys),
            ["ticket_id", "source_wallet_id", "amount", "note"]
        )
        XCTAssertEqual(intent["ticket_id"], ticketID)
        XCTAssertEqual(intent["source_wallet_id"], walletID)
        XCTAssertEqual(intent["amount"], "1250000.00")
        XCTAssertEqual(intent["note"], "For my loan")

        // A nil note stays an EXPLICIT null entry (the server hashes `note ?? null`).
        let nilNoteIntent = makeEnvelope(note: nil).stepUpIntent
        XCTAssertEqual(Set(nilNoteIntent.keys), ["ticket_id", "source_wallet_id", "amount", "note"])
        XCTAssertTrue(nilNoteIntent.contains { $0.key == "note" && $0.value == nil })
    }

    // MARK: - Request wire shape (no destination can ever be expressed)

    func testRequestEncodesExactKeySetWithNote() throws {
        let data = try JSONEncoder().encode(
            SupportPaymentRequestDTO(sourceWalletID: walletID, amount: "10.00", note: "hello")
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["source_wallet_id", "amount", "note"])
        XCTAssertEqual(object["source_wallet_id"] as? String, walletID)
        XCTAssertEqual(object["amount"] as? String, "10.00")
        XCTAssertEqual(object["note"] as? String, "hello")
    }

    func testRequestOmitsNilNoteAndCarriesNoDestinationField() throws {
        let data = try JSONEncoder().encode(
            SupportPaymentRequestDTO(sourceWalletID: walletID, amount: "10.00", note: nil)
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // The server prohibits destination fields outright; the exact key set proves the
        // client cannot even express one.
        XCTAssertEqual(Set(object.keys), ["source_wallet_id", "amount"])
    }

    // MARK: - Receipt decoding (strict company-only beneficiary)

    private func receiptJSON(
        beneficiary: String = #"{"kind": "company", "display_name": "Kit Africa"}"#,
        transactionExtra: String = ""
    ) -> Data {
        Data("""
        {
            "transaction": {
                "id": "aaaabbbb-cccc-dddd-eeee-ffff00001111",
                "reference": "KP-2026-000123",
                "amount": "1250000.00",
                "currency": {"code": "UGX", "scale": "2"},
                "status": "completed",
                "occurred_at": "2026-08-28T10:15:00Z"\(transactionExtra)
            },
            "beneficiary": \(beneficiary),
            "ticket_payment_id": "99998888-7777-6666-5555-444433332222"
        }
        """.utf8)
    }

    func testReceiptDecodesCanonicalServerShape() throws {
        let receipt = try JSONDecoder().decode(SupportPaymentReceiptDTO.self, from: receiptJSON())
        XCTAssertEqual(receipt.transaction.reference, "KP-2026-000123")
        XCTAssertEqual(receipt.transaction.amount, "1250000.00")
        XCTAssertEqual(receipt.transaction.currency.code, "UGX")
        XCTAssertEqual(receipt.transaction.currency.decimalScale, 2)
        XCTAssertEqual(receipt.transaction.status, "completed")
        XCTAssertEqual(receipt.beneficiary.kind, "company")
        XCTAssertEqual(receipt.beneficiary.displayName, "Kit Africa")
        XCTAssertEqual(receipt.ticketPaymentID, "99998888-7777-6666-5555-444433332222")
    }

    func testTransactionToleratesAdditiveUnknownKeys() throws {
        // An additive server field must never strand a COMMITTED payment behind a decode error.
        let receipt = try JSONDecoder().decode(
            SupportPaymentReceiptDTO.self,
            from: receiptJSON(transactionExtra: #", "settlement_batch": "b-1""#)
        )
        XCTAssertEqual(receipt.transaction.status, "completed")
    }

    func testBeneficiaryFailsClosedOnAnyContractDeviation() {
        // Extra key: the backend documents the block as exactly kind + display_name.
        XCTAssertThrowsError(try JSONDecoder().decode(
            SupportPaymentReceiptDTO.self,
            from: receiptJSON(
                beneficiary: #"{"kind": "company", "display_name": "Kit Africa", "phone": "x"}"#
            )
        ))
        // Non-company kind: this client pays the company beneficiary and nothing else.
        XCTAssertThrowsError(try JSONDecoder().decode(
            SupportPaymentReceiptDTO.self,
            from: receiptJSON(beneficiary: #"{"kind": "partner", "display_name": "Kit Africa"}"#)
        ))
        XCTAssertThrowsError(try JSONDecoder().decode(
            SupportPaymentReceiptDTO.self,
            from: receiptJSON(beneficiary: #"{"display_name": "Kit Africa"}"#)
        ))
        XCTAssertThrowsError(try JSONDecoder().decode(
            SupportPaymentReceiptDTO.self,
            from: receiptJSON(beneficiary: #"{"kind": "company"}"#)
        ))
        XCTAssertThrowsError(try JSONDecoder().decode(
            SupportPaymentReceiptDTO.self,
            from: receiptJSON(
                beneficiary: #"{"kind": "company", "display_name": "\#(String(repeating: "n", count: 81))"}"#
            )
        ))
    }

    func testTransactionRejectsIncoherentValues() {
        func fixture(
            amount: String = #""10.00""#,
            currency: String = #"{"code": "UGX", "scale": "2"}"#,
            status: String = #""completed""#
        ) -> Data {
            Data("""
            {
                "transaction": {
                    "id": "t-1", "reference": "KP-1",
                    "amount": \(amount),
                    "currency": \(currency),
                    "status": \(status),
                    "occurred_at": "2026-08-28T10:15:00Z"
                },
                "beneficiary": {"kind": "company", "display_name": "Kit Africa"},
                "ticket_payment_id": "p-1"
            }
            """.utf8)
        }
        // Sanity: the base fixture decodes.
        XCTAssertNoThrow(try JSONDecoder().decode(SupportPaymentReceiptDTO.self, from: fixture()))

        XCTAssertThrowsError(try JSONDecoder().decode(
            SupportPaymentReceiptDTO.self, from: fixture(amount: #""01.00""#)
        ))
        XCTAssertThrowsError(try JSONDecoder().decode(
            SupportPaymentReceiptDTO.self, from: fixture(amount: #""0.00""#)
        ))
        XCTAssertThrowsError(try JSONDecoder().decode(
            SupportPaymentReceiptDTO.self,
            from: fixture(currency: #"{"code": "UGX", "scale": "99"}"#)
        ))
        XCTAssertThrowsError(try JSONDecoder().decode(
            SupportPaymentReceiptDTO.self,
            from: fixture(currency: #"{"code": "UGX", "scale": "x"}"#)
        ))
        XCTAssertThrowsError(try JSONDecoder().decode(
            SupportPaymentReceiptDTO.self, from: fixture(status: #""""#)
        ))
    }

    // MARK: - Store: verified writes, removals, purge

    func testStoreRoundTripAndAbsence() throws {
        let (store, _) = makeStore()
        XCTAssertNil(try store.load(accountID: accountID, ticketID: ticketID))
        let envelope = makeEnvelope()
        try store.save(envelope)
        XCTAssertEqual(try store.load(accountID: accountID, ticketID: ticketID), envelope)
        // Other tickets are unaffected.
        XCTAssertNil(try store.load(accountID: accountID, ticketID: otherTicketID))
    }

    func testSaveSurfacesWriteFailure() {
        let (store, persistence) = makeStore()
        persistence.failSet = true
        XCTAssertThrowsError(try store.save(makeEnvelope())) {
            XCTAssertEqual($0 as? SupportPaymentStoreError, .unverifiedWrite)
        }
    }

    func testSaveSurfacesCorruptedReadBack() {
        // `set` succeeds but the persisted bytes differ: the byte-equal read-back must fail the
        // save, because an unprovable freeze must not authorize a POST.
        let (store, persistence) = makeStore()
        persistence.corruptOnSet = true
        XCTAssertThrowsError(try store.save(makeEnvelope())) {
            XCTAssertEqual($0 as? SupportPaymentStoreError, .unverifiedWrite)
        }
    }

    func testSaveRejectsInvalidEnvelope() {
        let (store, persistence) = makeStore()
        XCTAssertThrowsError(try store.save(makeEnvelope(amount: "01.00"))) {
            XCTAssertEqual($0 as? SupportPaymentStoreError, .unverifiedWrite)
        }
        XCTAssertTrue(persistence.storage.isEmpty)
    }

    func testClearIsVerifiedAndSurfacesSilentSurvivor() throws {
        let (store, persistence) = makeStore()
        try store.save(makeEnvelope())
        persistence.removeSilentlyKeepsData = true
        XCTAssertThrowsError(try store.clear(accountID: accountID, ticketID: ticketID)) {
            XCTAssertEqual($0 as? SupportPaymentStoreError, .unverifiedRemoval)
        }
        persistence.removeSilentlyKeepsData = false
        XCTAssertNoThrow(try store.clear(accountID: accountID, ticketID: ticketID))
        XCTAssertNil(try store.load(accountID: accountID, ticketID: ticketID))
        // Clearing an absent record stays a success.
        XCTAssertNoThrow(try store.clear(accountID: accountID, ticketID: ticketID))
    }

    func testStoreRejectsNonTicketNamespaces() {
        let (store, _) = makeStore()
        // Payments are ticket-scoped ONLY: no new-ticket namespace, no reserved index key,
        // no arbitrary strings.
        XCTAssertFalse(SupportPaymentStore.isValidTicketKey("new-ticket"))
        XCTAssertFalse(SupportPaymentStore.isValidTicketKey(SupportPaymentStore.indexTicketKey))
        XCTAssertFalse(SupportPaymentStore.isValidTicketKey("../escape"))
        XCTAssertThrowsError(try store.load(accountID: accountID, ticketID: "new-ticket"))
        XCTAssertThrowsError(try store.clear(accountID: accountID, ticketID: "index"))
        XCTAssertThrowsError(try store.load(accountID: "not-a-uuid", ticketID: ticketID))
    }

    func testLoadFailsClosedOnTamperedRecord() throws {
        let (store, persistence) = makeStore()
        try store.save(makeEnvelope())
        // Overwrite with a record claiming a different ticket: strict validation rejects it.
        let alien = makeEnvelope(ticketID: otherTicketID)
        persistence.storage[
            SupportPaymentStore.storageAccount(accountID: accountID, ticketID: ticketID)
        ] = try JSONEncoder().encode(alien)
        XCTAssertThrowsError(try store.load(accountID: accountID, ticketID: ticketID)) {
            XCTAssertEqual($0 as? SupportPaymentStoreError, .unreadable)
        }
    }

    func testPurgeRemovesEveryIndexedEnvelopeAndTheIndex() throws {
        let (store, persistence) = makeStore()
        try store.save(makeEnvelope())
        try store.save(makeEnvelope(ticketID: otherTicketID))
        XCTAssertFalse(persistence.storage.isEmpty)
        try store.purgeAccount(accountID: accountID)
        XCTAssertTrue(persistence.storage.isEmpty)
    }

    func testPurgeThrowsWhenIndexUnreadable() throws {
        let (store, persistence) = makeStore()
        try store.save(makeEnvelope())
        persistence.failData = true
        XCTAssertThrowsError(try store.purgeAccount(accountID: accountID))
    }

    // MARK: - Close policy with a pending payment (lowest severity, informational)

    func testClosePolicyRanksPendingPaymentLowest() {
        XCTAssertEqual(
            SupportClosePolicy.obstacle(
                cleanupBlocked: false,
                pendingReplay: false,
                storageError: false,
                composerText: "",
                pendingPayment: true
            ),
            .pendingPayment
        )
        // Every other obstacle outranks it.
        XCTAssertEqual(
            SupportClosePolicy.obstacle(
                cleanupBlocked: false,
                pendingReplay: false,
                storageError: false,
                composerText: "unsent",
                pendingPayment: true
            ),
            .unsentDraft
        )
        XCTAssertEqual(
            SupportClosePolicy.obstacle(
                cleanupBlocked: false,
                pendingReplay: false,
                storageError: true,
                composerText: "unsent",
                pendingPayment: true
            ),
            .storageError
        )
        XCTAssertEqual(
            SupportClosePolicy.obstacle(
                cleanupBlocked: false,
                pendingReplay: true,
                storageError: true,
                composerText: "unsent",
                pendingPayment: true
            ),
            .pendingReplay
        )
        XCTAssertEqual(
            SupportClosePolicy.obstacle(
                cleanupBlocked: true,
                pendingReplay: true,
                storageError: true,
                composerText: "unsent",
                pendingPayment: true
            ),
            .cleanupBlocked
        )
        XCTAssertNil(
            SupportClosePolicy.obstacle(
                cleanupBlocked: false,
                pendingReplay: false,
                storageError: false,
                composerText: "",
                pendingPayment: false
            )
        )
    }

    // MARK: - Definitive rejection vs ambiguous outcomes

    func testPaymentErrorClassificationMatchesEnvelopeSafetyRules() {
        // Definitive: the server parsed and refused THIS request — safe to clear the envelope.
        XCTAssertTrue(SupportContract.isDefinitiveRejection(
            APIErrorPayload(code: "INSUFFICIENT_FUNDS", message: "x", httpStatus: 409)
        ))
        XCTAssertTrue(SupportContract.isDefinitiveRejection(
            APIErrorPayload(code: "SUPPORT_TICKET_CLOSED", message: "x", httpStatus: 409)
        ))
        XCTAssertTrue(SupportContract.isDefinitiveRejection(
            APIErrorPayload(code: "WALLET_NOT_FOUND", message: "x", httpStatus: 404)
        ))
        XCTAssertTrue(SupportContract.isDefinitiveRejection(
            APIErrorPayload(code: "IDEMPOTENCY_KEY_REQUIRED", message: "x", httpStatus: 422)
        ))

        // Ambiguous: the frozen envelope must survive for verbatim replay.
        XCTAssertFalse(SupportContract.isDefinitiveRejection(
            APIErrorPayload(code: "SUPPORT_PAYMENTS_UNAVAILABLE", message: "x", httpStatus: 503)
        ))
        XCTAssertFalse(SupportContract.isDefinitiveRejection(
            APIErrorPayload(code: "FEATURE_UNAVAILABLE", message: "x", httpStatus: 503)
        ))
        XCTAssertFalse(SupportContract.isDefinitiveRejection(
            APIErrorPayload(code: "STEP_UP_REQUIRED", message: "x", httpStatus: 428)
        ))
        XCTAssertFalse(SupportContract.isDefinitiveRejection(
            APIErrorPayload(code: "", message: "x", httpStatus: 409)
        ))
        XCTAssertFalse(SupportContract.isDefinitiveRejection(
            APIErrorPayload(code: "ANYTHING", message: "x", httpStatus: nil)
        ))
        XCTAssertFalse(SupportContract.isDefinitiveRejection(URLError(.timedOut)))
    }

    // MARK: - Payments gate

    private func makeSupportProtocol(
        paymentsReady: Bool = true,
        beneficiaryKind: String = "company",
        beneficiaryDisplayName: String = "Kit Africa"
    ) -> SupportProtocolDTO {
        SupportProtocolDTO(
            ready: true,
            endToEndEncrypted: false,
            content: "server_readable",
            transport: "poll",
            attachmentsEnabled: false,
            aiEnabled: false,
            payments: SupportPaymentsProtocolDTO(
                ready: paymentsReady,
                beneficiaryKind: beneficiaryKind,
                beneficiaryDisplayName: beneficiaryDisplayName
            )
        )
    }

    private var fullPaymentFeatures: [String: Bool?] {
        [
            "support": true,
            "support_ai": false,
            "support_payments": true,
            "wallets": true,
            "internal_transfers": true,
        ]
    }

    func testPaymentsGateAvailableOnlyUnderTheFullAdvertisement() {
        XCTAssertEqual(
            SupportGate.paymentsState(
                features: fullPaymentFeatures,
                support: makeSupportProtocol()
            ),
            .available(beneficiaryDisplayName: "Kit Africa")
        )
    }

    func testPaymentsGateFailsClosedOnAnyMissingSignal() {
        let support = makeSupportProtocol()

        var features = fullPaymentFeatures
        features["support_payments"] = nil
        XCTAssertEqual(SupportGate.paymentsState(features: features, support: support), .unavailable)

        features = fullPaymentFeatures
        features["support_payments"] = false
        XCTAssertEqual(SupportGate.paymentsState(features: features, support: support), .unavailable)

        features = fullPaymentFeatures
        features["wallets"] = false
        XCTAssertEqual(SupportGate.paymentsState(features: features, support: support), .unavailable)

        features = fullPaymentFeatures
        features.removeValue(forKey: "internal_transfers")
        XCTAssertEqual(SupportGate.paymentsState(features: features, support: support), .unavailable)

        // The BASE support gate failing takes the payments surface down with it.
        features = fullPaymentFeatures
        features["support"] = false
        XCTAssertEqual(SupportGate.paymentsState(features: features, support: support), .unavailable)

        XCTAssertEqual(
            SupportGate.paymentsState(features: fullPaymentFeatures, support: nil),
            .unavailable
        )
        XCTAssertEqual(
            SupportGate.paymentsState(
                features: fullPaymentFeatures,
                support: makeSupportProtocol(paymentsReady: false)
            ),
            .unavailable
        )
        // Non-company beneficiary kinds never open the surface.
        XCTAssertEqual(
            SupportGate.paymentsState(
                features: fullPaymentFeatures,
                support: makeSupportProtocol(beneficiaryKind: "partner")
            ),
            .unavailable
        )
    }

    // MARK: - Endpoint routing

    func testPaymentsEndpointRouting() {
        let endpoint = SupportAPIEndpoint.payments(id: ticketID)
        XCTAssertEqual(endpoint.path, "support/tickets/\(ticketID)/payments")
        XCTAssertEqual(endpoint.method, "POST")
    }
}
