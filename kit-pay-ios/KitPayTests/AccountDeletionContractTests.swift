import Foundation
import XCTest
@testable import KitPay

final class AccountDeletionContractTests: XCTestCase {
    private let accountID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    private let receiptID = "22222222-2222-4222-8222-222222222222"

    func testProtectedPreflightDecodesOnlyTheExactAndroidParityContract() throws {
        let preflight = try decode(
            AccountDeletionPreflightDTO.self,
            from: preflightObject()
        )

        XCTAssertEqual(preflight.state, "available")
        XCTAssertTrue(preflight.canRequest)
        XCTAssertEqual(preflight.purpose, "account_deletion")
        XCTAssertEqual(preflight.accountID, accountID)
        XCTAssertEqual(preflight.intent["action"]!, "delete_account")
        XCTAssertEqual(preflight.confirmationText, "DELETE")
        XCTAssertEqual(preflight.notice.deletedCategories, ["Profile data"])
        XCTAssertEqual(preflight.notice.retainedCategories, ["Ledger records"])

        let roundTrip = try JSONDecoder().decode(
            AccountDeletionPreflightDTO.self,
            from: JSONEncoder().encode(preflight)
        )
        XCTAssertEqual(roundTrip, preflight)
    }

    func testPreflightFailsClosedForUnavailableOrUnboundDeletion() throws {
        var unavailable = preflightObject()
        unavailable["state"] = "unavailable"

        var cannotRequest = preflightObject()
        cannotRequest["can_request"] = false

        var wrongConfirmation = preflightObject()
        wrongConfirmation["confirmation_text"] = "delete"

        var wrongPurpose = preflightObject()
        var wrongPurposeStepUp = try XCTUnwrap(wrongPurpose["step_up"] as? [String: Any])
        wrongPurposeStepUp["purpose"] = "wallet_transfer"
        wrongPurpose["step_up"] = wrongPurposeStepUp

        var extraIntent = preflightObject()
        var extraStepUp = try XCTUnwrap(extraIntent["step_up"] as? [String: Any])
        var extraFields = try XCTUnwrap(extraStepUp["intent"] as? [String: Any])
        extraFields["amount"] = "1"
        extraStepUp["intent"] = extraFields
        extraIntent["step_up"] = extraStepUp

        var nonCanonicalAccount = preflightObject()
        var nonCanonicalStepUp = try XCTUnwrap(
            nonCanonicalAccount["step_up"] as? [String: Any]
        )
        var nonCanonicalIntent = try XCTUnwrap(
            nonCanonicalStepUp["intent"] as? [String: Any]
        )
        nonCanonicalIntent["account_id"] = accountID.uppercased()
        nonCanonicalStepUp["intent"] = nonCanonicalIntent
        nonCanonicalAccount["step_up"] = nonCanonicalStepUp

        var unknownField = preflightObject()
        unknownField["server_hint"] = "ignore-the-contract"

        for object in [
            unavailable,
            cannotRequest,
            wrongConfirmation,
            wrongPurpose,
            extraIntent,
            nonCanonicalAccount,
            unknownField,
        ] {
            XCTAssertThrowsError(
                try decode(AccountDeletionPreflightDTO.self, from: object)
            )
        }
    }

    func testPreflightRejectsUntrustedNoticeAndMalformedRequirements() throws {
        var evilURL = preflightObject()
        var evilNotice = try XCTUnwrap(evilURL["notice"] as? [String: Any])
        evilNotice["public_url"] = "https://pay.kit.africa.evil.test/account-deletion"
        evilURL["notice"] = evilNotice

        var duplicateRequirement = preflightObject()
        duplicateRequirement["closure_requirements"] = [
            ["code": "open_balance", "message": "Close the balance"],
            ["code": "open_balance", "message": "Close the balance again"],
        ]

        var unknownNoticeField = preflightObject()
        var unknownNotice = try XCTUnwrap(unknownNoticeField["notice"] as? [String: Any])
        unknownNotice["redirect_url"] = "https://example.test"
        unknownNoticeField["notice"] = unknownNotice

        XCTAssertThrowsError(try decode(AccountDeletionPreflightDTO.self, from: evilURL))
        XCTAssertThrowsError(
            try decode(AccountDeletionPreflightDTO.self, from: duplicateRequirement)
        )
        XCTAssertThrowsError(
            try decode(AccountDeletionPreflightDTO.self, from: unknownNoticeField)
        )
    }

    func testReceiptMustProveAcceptedDeletionPendingState() throws {
        let receipt = try decode(AccountDeletionReceiptDTO.self, from: receiptObject())

        XCTAssertEqual(receipt.receiptID, receiptID)
        XCTAssertEqual(receipt.state, "accepted")
        XCTAssertEqual(receipt.accountStatus, "deletion_pending")
        XCTAssertEqual(receipt.requestedAt, "2026-07-18T13:00:00Z")

        let roundTrip = try JSONDecoder().decode(
            AccountDeletionReceiptDTO.self,
            from: JSONEncoder().encode(receipt)
        )
        XCTAssertEqual(roundTrip, receipt)
    }

    func testReceiptFailsClosedBeforeLocalSignOutForAnyAmbiguousSuccess() throws {
        var queued = receiptObject()
        queued["state"] = "queued"

        var stillActive = receiptObject()
        stillActive["account_status"] = "active"

        var malformedID = receiptObject()
        malformedID["receipt_id"] = "receipt-1"

        var malformedTime = receiptObject()
        malformedTime["requested_at"] = "18 July 2026"

        var unknownField = receiptObject()
        unknownField["accepted"] = true

        for object in [queued, stillActive, malformedID, malformedTime, unknownField] {
            XCTAssertThrowsError(
                try decode(AccountDeletionReceiptDTO.self, from: object)
            )
        }
    }

    func testRequestRequiresExactDeleteAndEncodesNoExtraFields() throws {
        let request = try RequestAccountDeletionDTO(confirmation: "DELETE")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )

        XCTAssertEqual(object["confirmation"] as? String, "DELETE")
        XCTAssertEqual(Set(object.keys), ["confirmation"])
        XCTAssertThrowsError(try RequestAccountDeletionDTO(confirmation: "delete")) { error in
            XCTAssertEqual(
                error as? AccountDeletionContractError,
                .invalidConfirmation
            )
        }
    }

    func testEndpointsMatchTheCompatibilityAPIAndStepUpHeader() {
        XCTAssertEqual(AccountDeletionAPIEndpoint.preflight.path, "account/deletion")
        XCTAssertEqual(AccountDeletionAPIEndpoint.preflight.method, "GET")
        XCTAssertEqual(AccountDeletionAPIEndpoint.request.path, "account/deletion-requests")
        XCTAssertEqual(AccountDeletionAPIEndpoint.request.method, "POST")
        XCTAssertEqual(
            AccountDeletionAPIEndpoint.stepUpHeader,
            "X-Kit-Wallet-Step-Up"
        )
    }

    func testCapabilityAndPublicFallbackFailClosed() throws {
        XCTAssertTrue(
            AccountDeletionContract.protectedFlowAvailable(
                features: ["account_deletion": true]
            )
        )
        XCTAssertFalse(
            AccountDeletionContract.protectedFlowAvailable(
                features: ["account_deletion": false]
            )
        )
        XCTAssertFalse(AccountDeletionContract.protectedFlowAvailable(features: nil))
        XCTAssertEqual(
            AccountDeletionContract.trustedFallbackURL?.absoluteString,
            "https://pay.kit.africa/account-deletion"
        )

        let rejected = [
            "http://pay.kit.africa/account-deletion",
            "https://pay.kit.africa.evil.test/account-deletion",
            "https://user@pay.kit.africa/account-deletion",
            "https://pay.kit.africa:443/account-deletion",
            "https://pay.kit.africa/account-deletion?next=evil",
            "https://pay.kit.africa/account-deletion#other",
            " https://pay.kit.africa/account-deletion",
        ]
        for value in rejected {
            XCTAssertNil(AccountDeletionContract.trustedDeletionURL(value))
        }
    }

    func testPINAndStepUpValuesAreBoundedAndHeaderSafe() {
        XCTAssertTrue(AccountDeletionContract.validPIN("2580"))
        XCTAssertFalse(AccountDeletionContract.validPIN("258"))
        XCTAssertFalse(AccountDeletionContract.validPIN("٢٥٨٠"))
        XCTAssertFalse(AccountDeletionContract.validPIN("2580\n"))

        XCTAssertTrue(
            AccountDeletionContract.validStepUpToken(String(repeating: "a", count: 64))
        )
        XCTAssertFalse(AccountDeletionContract.validStepUpToken(""))
        XCTAssertFalse(
            AccountDeletionContract.validStepUpToken(String(repeating: "a", count: 63))
        )
        XCTAssertFalse(
            AccountDeletionContract.validStepUpToken(String(repeating: "a", count: 257))
        )
        XCTAssertFalse(
            AccountDeletionContract.validStepUpToken(
                String(repeating: "a", count: 63) + "\n"
            )
        )
    }

    func testAcceptedDeletionMarkerIsStrictIdempotentAndGenerationScoped() async throws {
        let marker = try PendingAcceptedAccountDeletion(
            accountID: accountID,
            sessionID: "33333333-3333-4333-8333-333333333333",
            receiptID: receiptID
        )
        let roundTrip = try JSONDecoder().decode(
            PendingAcceptedAccountDeletion.self,
            from: JSONEncoder().encode(marker)
        )
        XCTAssertEqual(roundTrip, marker)

        let memory = AccountDeletionMarkerMemory()
        let store = AcceptedAccountDeletionPurgeStore(
            load: { memory.load() },
            save: { try memory.save($0) },
            remove: { memory.remove() }
        )
        try await store.schedule(marker)
        try await store.schedule(marker)
        let scheduled = try await store.pending()
        XCTAssertEqual(scheduled, marker)

        let newer = try PendingAcceptedAccountDeletion(
            accountID: accountID,
            sessionID: "44444444-4444-4444-8444-444444444444",
            receiptID: "55555555-5555-4555-8555-555555555555"
        )
        do {
            try await store.schedule(newer)
            XCTFail("A newer marker must not orphan an unfinished accepted deletion")
        } catch {
            XCTAssertEqual(error as? AccountDeletionPurgeMarkerError, .conflictingMarker)
        }
        let stillScheduled = try await store.pending()
        XCTAssertEqual(stillScheduled, marker)
        let rejectedCompletion = try await store.completeIfCurrent(newer)
        XCTAssertFalse(rejectedCompletion)
        let acceptedCompletion = try await store.completeIfCurrent(marker)
        XCTAssertTrue(acceptedCompletion)
        let completed = try await store.pending()
        XCTAssertNil(completed)
    }

    func testAcceptedDeletionMarkerRejectsMalformedOrExtendedRecords() throws {
        XCTAssertThrowsError(
            try PendingAcceptedAccountDeletion(
                accountID: "not-an-account",
                sessionID: "33333333-3333-4333-8333-333333333333",
                receiptID: receiptID
            )
        )

        let extended = try JSONSerialization.data(withJSONObject: [
            "account_id": accountID,
            "session_id": "33333333-3333-4333-8333-333333333333",
            "receipt_id": receiptID,
            "access_token": "must-not-be-stored",
        ])
        XCTAssertThrowsError(
            try JSONDecoder().decode(PendingAcceptedAccountDeletion.self, from: extended)
        )
    }

    func testPreSubmissionAttemptFenceIsStrictDurableAndMatchesAcceptedReceipt() async throws {
        let attempt = try PendingAccountDeletionAttempt(
            accountID: accountID,
            sessionID: "33333333-3333-4333-8333-333333333333",
            attemptID: "66666666-6666-4666-8666-666666666666"
        )
        let accepted = try PendingAcceptedAccountDeletion(
            accountID: accountID,
            sessionID: attempt.sessionID,
            receiptID: receiptID
        )
        XCTAssertTrue(attempt.matches(accepted))

        let differentSession = try PendingAcceptedAccountDeletion(
            accountID: accountID,
            sessionID: "77777777-7777-4777-8777-777777777777",
            receiptID: receiptID
        )
        XCTAssertFalse(attempt.matches(differentSession))

        let memory = AccountDeletionMarkerMemory()
        let store = AccountDeletionAttemptStore(
            load: { memory.load() },
            save: { try memory.save($0) },
            remove: { memory.remove() }
        )
        try await store.schedule(attempt)
        let scheduledAttempt = try await store.pending()
        XCTAssertEqual(scheduledAttempt, attempt)

        let conflicting = try PendingAccountDeletionAttempt(
            accountID: accountID,
            sessionID: attempt.sessionID,
            attemptID: "88888888-8888-4888-8888-888888888888"
        )
        do {
            try await store.schedule(conflicting)
            XCTFail("A second irreversible attempt must not replace unresolved authority")
        } catch {
            XCTAssertEqual(error as? AccountDeletionPurgeMarkerError, .conflictingMarker)
        }
        let completedAttempt = try await store.completeIfCurrent(attempt)
        XCTAssertTrue(completedAttempt)
        let clearedAttempt = try await store.pending()
        XCTAssertNil(clearedAttempt)
    }

    func testAcceptedDeletionMarkerKeepsRetryAuthorityOnPersistenceFailures() async throws {
        let marker = try PendingAcceptedAccountDeletion(
            accountID: accountID,
            sessionID: "33333333-3333-4333-8333-333333333333",
            receiptID: receiptID
        )
        let memory = AccountDeletionMarkerMemory()
        let store = AcceptedAccountDeletionPurgeStore(
            load: { memory.load() },
            save: { try memory.save($0) },
            remove: { memory.remove() }
        )

        memory.setDiscardWrites(true)
        do {
            try await store.schedule(marker)
            XCTFail("A marker write must be verified before cleanup can continue")
        } catch {
            XCTAssertEqual(
                error as? AccountDeletionPurgeMarkerError,
                .persistenceVerificationFailed
            )
        }

        memory.setDiscardWrites(false)
        try await store.schedule(marker)
        memory.setRetainOnRemove(true)
        do {
            _ = try await store.completeIfCurrent(marker)
            XCTFail("A marker must remain active when durable removal cannot be verified")
        } catch {
            XCTAssertEqual(
                error as? AccountDeletionPurgeMarkerError,
                .persistenceVerificationFailed
            )
        }
        let retained = try await store.pending()
        XCTAssertEqual(retained, marker)

        memory.seed(Data("not-json".utf8))
        do {
            _ = try await store.pending()
            XCTFail("Malformed durable cleanup authority must fail closed")
        } catch {
            XCTAssertEqual(error as? AccountDeletionPurgeMarkerError, .invalidMarker)
        }
    }

    func testAccountAndCleanupPoliciesKeepDeletionBoundToItsAuthenticatedReceipt() {
        XCTAssertEqual(
            AccountDeletionContract.canonicalAccountID(accountID.uppercased()),
            accountID
        )
        XCTAssertNil(AccountDeletionContract.canonicalAccountID(" \(accountID)"))
        XCTAssertNil(AccountDeletionContract.canonicalAccountID("not-an-account"))

        XCTAssertTrue(AccountSignOutDataPolicy.ordinaryLogout.preserveCommunicationHistory)
        XCTAssertFalse(
            AccountSignOutDataPolicy.acceptedAccountDeletion.preserveCommunicationHistory
        )
        XCTAssertTrue(
            AccountDeletionSubmissionError.completionUncertain.requiresSupportResolution
        )
        XCTAssertFalse(
            AccountDeletionSubmissionError.accountChanged.requiresSupportResolution
        )
        XCTAssertTrue(
            AccountDeletionSubmissionError.acceptedButLocalCleanupFailed.deletionWasAccepted
        )
        XCTAssertFalse(AccountDeletionSubmissionError.unavailable.deletionWasAccepted)
    }

    @MainActor
    func testSubmissionGateRejectsDuplicateUntilTheAttemptFinishes() {
        let gate = AccountDeletionSubmissionGate()

        XCTAssertTrue(gate.begin())
        XCTAssertTrue(gate.isSubmitting)
        XCTAssertFalse(gate.begin())
        gate.finish()
        XCTAssertFalse(gate.isSubmitting)
        XCTAssertTrue(gate.begin())
    }

    private func preflightObject() -> [String: Any] {
        [
            "state": "available",
            "can_request": true,
            "requires_support": false,
            "closure_requirements": [],
            "step_up": [
                "purpose": "account_deletion",
                "intent": [
                    "account_id": accountID,
                    "action": "delete_account",
                ],
            ],
            "confirmation_text": "DELETE",
            "notice": noticeObject(),
        ]
    }

    private func receiptObject() -> [String: Any] {
        [
            "receipt_id": receiptID,
            "state": "accepted",
            "account_status": "deletion_pending",
            "requested_at": "2026-07-18T13:00:00Z",
            "requires_support": false,
            "closure_requirements": [],
            "notice": noticeObject(),
        ]
    }

    private func noticeObject() -> [String: Any] {
        [
            "version": "kit-account-deletion-2026-07",
            "public_url": "https://pay.kit.africa/account-deletion",
            "deleted_categories": ["Profile data"],
            "retained_categories": ["Ledger records"],
        ]
    }

    private func decode<Value: Decodable>(
        _ type: Value.Type,
        from object: [String: Any]
    ) throws -> Value {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try JSONDecoder().decode(type, from: data)
    }
}

private final class AccountDeletionMarkerMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var discardWrites = false
    private var retainOnRemove = false

    func load() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    func save(_ value: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !discardWrites else { return }
        data = value
    }

    func remove() {
        lock.lock()
        defer { lock.unlock() }
        guard !retainOnRemove else { return }
        data = nil
    }

    func setDiscardWrites(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        discardWrites = value
    }

    func setRetainOnRemove(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        retainOnRemove = value
    }

    func seed(_ value: Data?) {
        lock.lock()
        defer { lock.unlock() }
        data = value
    }
}
