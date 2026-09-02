import Foundation
import XCTest
@testable import KitPay

final class PaymentRequestTests: XCTestCase {
    private let recoveryRequesterID = "10000000-0000-4000-8000-000000000001"
    private let recoveryPayerID = "10000000-0000-4000-8000-000000000002"
    private let recoveryWalletID = "20000000-0000-4000-8000-000000000001"
    private let recoverySourceWalletID = "20000000-0000-4000-8000-000000000002"
    private let recoveryConversationID = "30000000-0000-4000-8000-000000000001"
    private let recoveryRequestID = "40000000-0000-4000-8000-000000000001"

    func testCreateBodyUsesBackendFieldNamesAndOmitsAbsentOptionals() throws {
        let body = CreatePaymentRequestBody(
            destinationWalletId: "destination-wallet",
            requestedFromUserId: "payer-user",
            amount: "25.50",
            note: nil,
            expiresAt: nil
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any]
        )

        XCTAssertEqual(object["destination_wallet_id"] as? String, "destination-wallet")
        XCTAssertEqual(object["requested_from_user_id"] as? String, "payer-user")
        XCTAssertEqual(object["amount"] as? String, "25.50")
        XCTAssertNil(object["note"])
        XCTAssertNil(object["expires_at"])
        XCTAssertEqual(Set(object.keys), ["destination_wallet_id", "requested_from_user_id", "amount"])
    }

    func testPayBodyAndStepUpIntentMatchBackendContractExactly() throws {
        let request = paymentRequest(
            id: "request-id",
            destinationWalletId: "requester-wallet",
            requestedFromUserId: "payer-user",
            amount: "25.50"
        )
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(PayPaymentRequestBody(sourceWalletId: "payer-wallet"))
            ) as? [String: Any]
        )
        XCTAssertEqual(body as NSDictionary, ["source_wallet_id": "payer-wallet"] as NSDictionary)

        let intent = PaymentRequestPolicy.payIntent(for: request, sourceWalletId: "payer-wallet")
        XCTAssertEqual(Set(intent.keys), [
            "action", "payment_request_id", "source_wallet_id", "amount", "currency",
        ])
        XCTAssertEqual(try XCTUnwrap(intent["action"] ?? nil), "pay")
        XCTAssertEqual(try XCTUnwrap(intent["payment_request_id"] ?? nil), "request-id")
        XCTAssertEqual(try XCTUnwrap(intent["source_wallet_id"] ?? nil), "payer-wallet")
        XCTAssertEqual(try XCTUnwrap(intent["amount"] ?? nil), "25.50")
        XCTAssertEqual(try XCTUnwrap(intent["currency"] ?? nil), "UGX")
    }

    func testCancelBodyIsAnEmptyJSONOperation() throws {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(PaymentRequestEmptyBody())
            ) as? [String: Any]
        )
        XCTAssertTrue(object.isEmpty)
    }

    // MARK: - Durable financial chat recovery

    func testPaymentRequestCreationJournalRoundTripsAndAcknowledgesOnlyExactMessage() throws {
        let record = try XCTUnwrap(PaymentRequestChatReceiptRecoveryRecord(
            id: UUID(uuidString: "50000000-0000-4000-8000-000000000001")!,
            ownerUserID: recoveryRequesterID,
            destinationWalletID: recoveryWalletID,
            recipientUserID: recoveryPayerID,
            recipientName: "Payer",
            conversationID: recoveryConversationID,
            amount: "10.00",
            currency: CurrencyDTO(code: "UGX", scale: "2"),
            note: "Lunch",
            idempotencyKey: "ios-request-create-1",
            createdAt: Date(timeIntervalSince1970: 1_780_000_000)
        ))
        let request = paymentRequest(
            id: recoveryRequestID,
            destinationWalletId: recoveryWalletID,
            requestedFromUserId: recoveryPayerID
        )
        let confirmation = try XCTUnwrap(PaymentRequestChatReceiptConfirmation(
            request: request,
            recovery: record
        ))
        var records = [record]

        XCTAssertTrue(PaymentRequestChatReceiptRecoveryPolicy.markSubmitted(
            recordID: record.id,
            in: &records
        ))
        XCTAssertTrue(PaymentRequestChatReceiptRecoveryPolicy.storeConfirmation(
            confirmation,
            for: record.id,
            in: &records
        ))
        XCTAssertEqual(records[0].phase, .confirmed)
        XCTAssertEqual(confirmation.clientMessageID, UUID(uuidString: recoveryRequestID))
        XCTAssertEqual(
            try JSONDecoder().decode(
                PaymentRequestChatReceiptRecoveryRecord.self,
                from: JSONEncoder().encode(records[0])
            ),
            records[0]
        )
        XCTAssertFalse(PaymentRequestChatReceiptRecoveryPolicy.acknowledgeDurableMessage(
            recordID: record.id,
            messageID: UUID(),
            in: &records
        ))
        XCTAssertTrue(PaymentRequestChatReceiptRecoveryPolicy.acknowledgeDurableMessage(
            recordID: record.id,
            messageID: try XCTUnwrap(confirmation.clientMessageID),
            in: &records
        ))
        XCTAssertTrue(records.isEmpty)
    }

    func testPaymentRequestCreationRetryReusesKeyAndOnlyPreparedRecordsExpire() throws {
        let createdAt = Date(timeIntervalSince1970: 1_780_000_000)
        let original = try XCTUnwrap(paymentRequestCreationRecovery(
            id: UUID(uuidString: "50000000-0000-4000-8000-000000000001")!,
            idempotencyKey: "ios-request-original",
            createdAt: createdAt
        ))
        let retry = try XCTUnwrap(paymentRequestCreationRecovery(
            id: UUID(uuidString: "50000000-0000-4000-8000-000000000002")!,
            idempotencyKey: "ios-request-new-key",
            createdAt: createdAt.addingTimeInterval(30)
        ))
        var records: [PaymentRequestChatReceiptRecoveryRecord] = []
        XCTAssertEqual(
            PaymentRequestChatReceiptRecoveryPolicy.insertOrReuse(
                original,
                in: &records,
                now: createdAt
            )?.idempotencyKey,
            original.idempotencyKey
        )
        XCTAssertEqual(
            PaymentRequestChatReceiptRecoveryPolicy.insertOrReuse(
                retry,
                in: &records,
                now: createdAt.addingTimeInterval(30)
            )?.idempotencyKey,
            original.idempotencyKey
        )
        XCTAssertEqual(records.count, 1)

        XCTAssertTrue(PaymentRequestChatReceiptRecoveryPolicy.markSubmitted(
            recordID: original.id,
            in: &records,
            now: createdAt
        ))
        let stalePrepared = try XCTUnwrap(paymentRequestCreationRecovery(
            id: UUID(uuidString: "50000000-0000-4000-8000-000000000003")!,
            idempotencyKey: "ios-request-stale",
            createdAt: createdAt
        ))
        records.append(stalePrepared)
        PaymentRequestChatReceiptRecoveryPolicy.sanitize(
            &records,
            ownerUserID: recoveryRequesterID,
            now: createdAt.addingTimeInterval(
                FinancialChatReceiptRecoveryPolicy.preparedRetentionLifetime + 1
            )
        )
        XCTAssertEqual(records.map(\.phase), [.submitted])

        PaymentRequestChatReceiptRecoveryPolicy.sanitize(
            &records,
            ownerUserID: recoveryPayerID,
            now: createdAt.addingTimeInterval(
                FinancialChatReceiptRecoveryPolicy.preparedRetentionLifetime + 1
            )
        )
        XCTAssertTrue(records.isEmpty, "another account must never inherit the journal")
    }

    func testPaymentRequestRecoveryRetiresOnlyItsStructuredNotFoundCode() {
        XCTAssertEqual(
            PaymentRequestChatReceiptRecoveryPolicy.recoveryDecision(
                for: APIErrorPayload(
                    code: "PAYMENT_REQUEST_RECOVERY_NOT_FOUND",
                    message: "not committed",
                    httpStatus: 404
                )
            ),
            .notCommitted
        )
        let ambiguous: [Error] = [
            APIErrorPayload(
                code: "PAYMENT_REQUEST_NOT_FOUND",
                message: "opaque",
                httpStatus: 404
            ),
            APIErrorPayload(
                code: "PAYMENT_REQUEST_RECOVERY_NOT_FOUND",
                message: "wrong status",
                httpStatus: 409
            ),
            APIErrorPayload(
                code: "IDEMPOTENCY_REQUEST_IN_PROGRESS",
                message: "in progress",
                httpStatus: 409
            ),
            APIErrorPayload(
                code: "IDEMPOTENCY_KEY_REUSED",
                message: "mismatch",
                httpStatus: 409
            ),
            APIErrorPayload(
                code: "IDEMPOTENCY_REPLAY_UNAVAILABLE",
                message: "unavailable",
                httpStatus: 409
            ),
            APIErrorPayload(code: "SERVER_ERROR", message: "retry", httpStatus: 503),
            APIClientError.invalidResponse,
            CancellationError(),
        ]
        for error in ambiguous {
            XCTAssertEqual(
                PaymentRequestChatReceiptRecoveryPolicy.recoveryDecision(for: error),
                .retain
            )
        }
    }

    func testPayAndCancelRecoveryUseExactReadAndDeterministicOutcomeIDs() throws {
        let pending = paymentRequest(
            id: recoveryRequestID,
            destinationWalletId: recoveryWalletID,
            requestedFromUserId: recoveryPayerID
        )
        let descriptor = try XCTUnwrap(
            KitPaymentMessage(action: .request, paymentRequest: pending)
        )
        let pay = try XCTUnwrap(PaymentRequestResolutionChatReceiptRecoveryRecord(
            ownerUserID: recoveryPayerID,
            conversationID: recoveryConversationID,
            recipientUserID: recoveryRequesterID,
            recipientName: "Requester",
            request: pending,
            descriptor: descriptor,
            sourceWalletID: recoverySourceWalletID,
            operation: .paid,
            idempotencyKey: "ios-request-pay-1"
        ))
        let cancel = try XCTUnwrap(PaymentRequestResolutionChatReceiptRecoveryRecord(
            ownerUserID: recoveryRequesterID,
            conversationID: recoveryConversationID,
            recipientUserID: recoveryPayerID,
            recipientName: "Payer",
            request: pending,
            descriptor: descriptor,
            sourceWalletID: nil,
            operation: .cancelled,
            idempotencyKey: "ios-request-cancel-1"
        ))
        let paid = paymentRequest(
            id: recoveryRequestID,
            status: "paid",
            destinationWalletId: recoveryWalletID,
            requestedFromUserId: recoveryPayerID,
            walletTransactionId: "60000000-0000-4000-8000-000000000001"
        )
        let cancelled = paymentRequest(
            id: recoveryRequestID,
            status: "cancelled",
            destinationWalletId: recoveryWalletID,
            requestedFromUserId: recoveryPayerID
        )
        let paidConfirmation = try XCTUnwrap(
            PaymentRequestResolutionChatReceiptConfirmation(request: paid, recovery: pay)
        )
        let cancelledConfirmation = try XCTUnwrap(
            PaymentRequestResolutionChatReceiptConfirmation(request: cancelled, recovery: cancel)
        )

        XCTAssertEqual(
            paidConfirmation.clientMessageID,
            KitPaymentMessage.outcomeMessageID(
                paymentRequestID: recoveryRequestID,
                action: .paid,
                actorUserID: recoveryPayerID
            )
        )
        XCTAssertEqual(
            cancelledConfirmation.clientMessageID,
            KitPaymentMessage.outcomeMessageID(
                paymentRequestID: recoveryRequestID,
                action: .cancelled,
                actorUserID: recoveryRequesterID
            )
        )
        XCTAssertNotEqual(paidConfirmation.clientMessageID, cancelledConfirmation.clientMessageID)
        XCTAssertTrue(pay.matchesExactRead(paid))
        XCTAssertTrue(cancel.matchesExactRead(cancelled))
        XCTAssertEqual(
            PaymentRequestResolutionChatReceiptRecoveryPolicy.exactReadDecision(
                for: pending,
                recovery: pay
            ),
            .retain,
            "a pending read may still be racing the submitted mutation"
        )
        XCTAssertEqual(
            PaymentRequestResolutionChatReceiptRecoveryPolicy.exactReadDecision(
                for: paid,
                recovery: pay
            ),
            .confirm
        )
        XCTAssertEqual(
            PaymentRequestResolutionChatReceiptRecoveryPolicy.exactReadDecision(
                for: cancelled,
                recovery: pay
            ),
            .retireUncommitted
        )
        XCTAssertNil(PaymentRequestResolutionChatReceiptConfirmation(
            request: paymentRequest(
                id: recoveryRequestID,
                status: "paid",
                destinationWalletId: recoveryWalletID,
                requestedFromUserId: recoveryRequesterID,
                walletTransactionId: "60000000-0000-4000-8000-000000000001"
            ),
            recovery: pay
        ))

        var records = [pay]
        XCTAssertTrue(PaymentRequestResolutionChatReceiptRecoveryPolicy.markSubmitted(
            recordID: pay.id,
            in: &records
        ))
        XCTAssertTrue(PaymentRequestResolutionChatReceiptRecoveryPolicy.storeConfirmation(
            paidConfirmation,
            for: pay.id,
            in: &records
        ))
        XCTAssertEqual(
            try JSONDecoder().decode(
                PaymentRequestResolutionChatReceiptRecoveryRecord.self,
                from: JSONEncoder().encode(records[0])
            ),
            records[0]
        )
        XCTAssertTrue(PaymentRequestResolutionChatReceiptRecoveryPolicy.acknowledgeDurableMessage(
            recordID: pay.id,
            messageID: try XCTUnwrap(paidConfirmation.clientMessageID),
            in: &records
        ))
        XCTAssertTrue(records.isEmpty)
    }

    func testPolicySeparatesIncomingAndOutgoingAndAppliesExactActionGates() {
        let policy = PaymentRequestPolicy(
            features: [
                "wallets": true,
                "payment_requests": true,
                "internal_transfers": true,
            ],
            currentUserId: "payer-user",
            ownedWalletIds: ["payer-wallet"]
        )
        let incoming = paymentRequest(
            destinationWalletId: "requester-wallet",
            requestedFromUserId: "payer-user"
        )
        let outgoing = paymentRequest(
            destinationWalletId: "payer-wallet",
            requestedFromUserId: "other-user"
        )

        XCTAssertEqual(policy.direction(of: incoming), .incoming)
        XCTAssertTrue(policy.canPay(incoming))
        XCTAssertFalse(policy.canCancel(incoming))
        XCTAssertEqual(policy.direction(of: outgoing), .outgoing)
        XCTAssertFalse(policy.canPay(outgoing))
        XCTAssertTrue(policy.canCancel(outgoing))
    }

    func testPolicyFailsClosedForDisabledTransferExpiredAndUnknownStates() {
        let noTransfer = PaymentRequestPolicy(
            features: ["wallets": true, "payment_requests": true, "internal_transfers": false],
            currentUserId: "payer-user",
            ownedWalletIds: ["payer-wallet"]
        )
        let expired = paymentRequest(
            status: "pending",
            destinationWalletId: "requester-wallet",
            requestedFromUserId: "payer-user",
            expiresAt: "2025-01-01T00:00:00Z"
        )
        let unknown = paymentRequest(
            status: "processing",
            destinationWalletId: "requester-wallet",
            requestedFromUserId: "payer-user"
        )

        XCTAssertFalse(noTransfer.canPay(expired, now: Date(timeIntervalSince1970: 0)))

        let enabled = PaymentRequestPolicy(
            features: ["wallets": true, "payment_requests": true, "internal_transfers": true],
            currentUserId: "payer-user",
            ownedWalletIds: ["payer-wallet"]
        )
        XCTAssertFalse(enabled.canPay(expired, now: Date(timeIntervalSince1970: 1_800_000_000)))
        XCTAssertFalse(enabled.canPay(unknown))
        XCTAssertFalse(enabled.canCancel(unknown))
    }

    func testPolicyRejectsInactiveOrCurrencyMismatchedSourceWallet() {
        let policy = PaymentRequestPolicy(
            features: ["wallets": true, "payment_requests": true, "internal_transfers": true],
            currentUserId: "payer-user",
            ownedWalletIds: ["payer-wallet"]
        )
        let request = paymentRequest(
            destinationWalletId: "requester-wallet",
            requestedFromUserId: "payer-user"
        )
        let inactive = wallet(status: "restricted", currency: CurrencyDTO(code: "UGX", scale: "2"))
        let wrongCurrency = wallet(status: "active", currency: CurrencyDTO(code: "USD", scale: "2"))

        XCTAssertFalse(policy.canPay(request, from: inactive))
        XCTAssertFalse(policy.canPay(request, from: wrongCurrency))
        XCTAssertTrue(policy.canPay(request, from: wallet(
            status: "active",
            currency: CurrencyDTO(code: "UGX", scale: "2")
        )))
    }

    func testPINPolicyRequiresExactlyFourASCIIDigits() {
        XCTAssertTrue(PaymentRequestPolicy.isValidPIN("0123"))
        XCTAssertFalse(PaymentRequestPolicy.isValidPIN("123"))
        XCTAssertFalse(PaymentRequestPolicy.isValidPIN("12345"))
        XCTAssertFalse(PaymentRequestPolicy.isValidPIN("12a3"))
        XCTAssertFalse(PaymentRequestPolicy.isValidPIN("١٢٣٤"))
    }

    func testCreatorCanStillCancelPendingRequestWhenCreationFeatureIsDisabled() {
        let policy = PaymentRequestPolicy(
            features: ["wallets": true, "payment_requests": false, "internal_transfers": false],
            currentUserId: "payer-user",
            ownedWalletIds: ["payer-wallet"]
        )
        let outgoing = paymentRequest(
            destinationWalletId: "payer-wallet",
            requestedFromUserId: "other-user"
        )

        XCTAssertFalse(policy.paymentRequestsEnabled)
        XCTAssertTrue(policy.canCancel(outgoing))
        XCTAssertFalse(policy.canPay(outgoing))
    }

    func testKitPaymentMessageMatchesAndroidCanonicalFixture() throws {
        let descriptor = try XCTUnwrap(KitPaymentMessage(
            action: .request,
            paymentRequestId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            amountMinor: 2_500_000,
            currencyCode: "UGX",
            currencyScale: 2,
            note: "Lunch split 50/50 & drinks"
        ))
        let encoded = "KITPAY1:v=1&a=request&id=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
            + "&amt=2500000&cur=UGX&sc=2&note=Lunch%20split%2050%2F50%20%26%20drinks"

        XCTAssertEqual(descriptor.encoded, encoded)
        XCTAssertTrue(KitPaymentMessage.isPaymentText(encoded))
        XCTAssertEqual(KitPaymentMessage.parse(encoded), descriptor)
        XCTAssertEqual(KitPaymentMessage.parse(encoded)?.encoded, encoded)
        XCTAssertEqual(descriptor.decimalAmount, "25000.00")
    }

    func testUserAuthoredTextCannotEnterThePaymentEventNamespace() {
        XCTAssertFalse(SecureMessageReservedPrefixPolicy.allowsUserAuthoredText(
            "KITPAY1:v=1&a=sent&id=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa&amt=1&cur=UGX&sc=0"
        ))
        XCTAssertFalse(SecureMessageReservedPrefixPolicy.allowsUserAuthoredText(
            "  \nKITPAY1:not-even-a-valid-descriptor"
        ))
        XCTAssertTrue(SecureMessageReservedPrefixPolicy.allowsUserAuthoredText(
            "Please review KITPAY1: after lunch"
        ))
    }

    func testKitPaymentMessageUsesAndroidUTF8FormEncodingWithoutPlusSpaces() throws {
        let descriptor = try XCTUnwrap(KitPaymentMessage(
            action: .request,
            paymentRequestId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            amountMinor: 1,
            currencyCode: "UGX",
            currencyScale: 2,
            note: "Café 🍜 ~*"
        ))

        XCTAssertTrue(descriptor.encoded.hasSuffix("&note=Caf%C3%A9%20%F0%9F%8D%9C%20%7E*"))
        XCTAssertFalse(descriptor.encoded.contains("+"))
        XCTAssertEqual(KitPaymentMessage.parse(descriptor.encoded), descriptor)

        let blank = try XCTUnwrap(KitPaymentMessage(
            action: .request,
            paymentRequestId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            amountMinor: 1,
            currencyCode: "UGX",
            currencyScale: 2,
            note: "   "
        ))
        XCTAssertNil(blank.note)
        XCTAssertFalse(blank.encoded.contains("&note="))
    }

    func testKitPaymentMessageRejectsNoncanonicalMalformedAndOversizedText() throws {
        let canonical = try XCTUnwrap(KitPaymentMessage(
            action: .request,
            paymentRequestId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            amountMinor: 2_500_000,
            currencyCode: "UGX",
            currencyScale: 2,
            note: "Lunch"
        )).encoded
        let malformed = [
            canonical.replacingOccurrences(
                of: "v=1&a=request&id=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                with: "v=1&id=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa&a=request"
            ),
            canonical + "&amt=2500000",
            canonical + "&x=1",
            canonical.replacingOccurrences(of: "a=request", with: "a=steal"),
            canonical.replacingOccurrences(of: "amt=2500000", with: "amt=0"),
            canonical.replacingOccurrences(of: "amt=2500000", with: "amt=01"),
            canonical.replacingOccurrences(of: "amt=2500000", with: "amt=1000000000001"),
            canonical.replacingOccurrences(of: "cur=UGX", with: "cur=ugx"),
            canonical.replacingOccurrences(of: "cur=UGX", with: "cur=UGX1"),
            canonical.replacingOccurrences(of: "sc=2", with: "sc=7"),
            canonical.replacingOccurrences(of: "sc=2", with: "sc=02"),
            canonical.replacingOccurrences(
                of: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                with: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
            ),
            canonical.replacingOccurrences(
                of: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                with: "not-a-uuid"
            ),
            canonical.replacingOccurrences(of: "note=Lunch", with: "note=%4Cunch"),
            canonical.replacingOccurrences(of: "note=Lunch", with: "note=%ZZ"),
            canonical.replacingOccurrences(of: "note=Lunch", with: "note=%20"),
            canonical.replacingOccurrences(of: "note=Lunch", with: "note=Lunch+split"),
            "plain text mentioning KITPAY1: later",
            "KITPAY1:v=2&a=request",
        ]

        for value in malformed {
            XCTAssertNil(KitPaymentMessage.parse(value), value)
        }

        let oversizedNote = String(repeating: "x", count: 141)
        XCTAssertNil(KitPaymentMessage.parse(
            canonical.replacingOccurrences(of: "note=Lunch", with: "note=\(oversizedNote)")
        ))
        let oversizedDescriptor = "KITPAY1:v=1&a=request&id=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
            + "&amt=1&cur=UGX&sc=2&note="
            + String(repeating: "%E6%B2%99", count: 140)
        XCTAssertGreaterThan(oversizedDescriptor.utf16.count, KitPaymentMessage.maximumDescriptorLength)
        XCTAssertNil(KitPaymentMessage.parse(oversizedDescriptor))
    }

    func testKitPaymentMessageConvertsBackendDecimalsToMinorUnitsExactly() {
        XCTAssertEqual(KitPaymentMessage.minorUnits(for: "25.50", scale: 2), 2_550)
        XCTAssertEqual(KitPaymentMessage.minorUnits(for: "25.5", scale: 2), 2_550)
        XCTAssertEqual(KitPaymentMessage.minorUnits(for: "25.5000", scale: 2), 2_550)
        XCTAssertEqual(KitPaymentMessage.minorUnits(for: "25.0", scale: 0), 25)
        XCTAssertEqual(KitPaymentMessage.minorUnits(for: "0.01", scale: 2), 1)
        XCTAssertEqual(
            KitPaymentMessage.minorUnits(for: "10000000000.00", scale: 2),
            KitPaymentMessage.maximumAmountMinor
        )

        XCTAssertNil(KitPaymentMessage.minorUnits(for: "0", scale: 2))
        XCTAssertNil(KitPaymentMessage.minorUnits(for: "-1.00", scale: 2))
        XCTAssertNil(KitPaymentMessage.minorUnits(for: "1.001", scale: 2))
        XCTAssertNil(KitPaymentMessage.minorUnits(for: "1e2", scale: 2))
        XCTAssertNil(KitPaymentMessage.minorUnits(for: "1,00", scale: 2))
        XCTAssertNil(KitPaymentMessage.minorUnits(for: "10000000000.01", scale: 2))
        XCTAssertNil(KitPaymentMessage.minorUnits(for: "1.00", scale: 7))
    }

    func testChatPaymentPresentationSeparatesDirectionActionAndPayEligibility() throws {
        let request = paymentRequest(
            id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            destinationWalletId: "requester-wallet",
            requestedFromUserId: "payer-user",
            amount: "25.50"
        )
        let descriptor = try XCTUnwrap(KitPaymentMessage(action: .request, paymentRequest: request))
        let paid = try XCTUnwrap(descriptor.changingAction(to: .paid))
        XCTAssertEqual(KitPaymentMessage.parse(paid.encoded), paid)
        XCTAssertTrue(paid.encoded.contains("&a=paid&"))
        let policy = PaymentRequestPolicy(
            features: [
                "wallets": true,
                "payment_requests": true,
                "internal_transfers": true,
            ],
            currentUserId: "payer-user",
            ownedWalletIds: ["payer-wallet"]
        )
        let source = wallet(status: "active", currency: request.currency)

        let outgoingRequest = KitPaymentMessagePresentationPolicy.presentation(
            for: descriptor,
            isOutgoing: true,
            authoritativeRequest: request,
            sourceWallet: source,
            policy: policy,
            isOnline: true
        )
        XCTAssertEqual(outgoingRequest.title, "Payment request sent")
        XCTAssertFalse(outgoingRequest.showsPayAction)

        let incomingRequest = KitPaymentMessagePresentationPolicy.presentation(
            for: descriptor,
            isOutgoing: false,
            authoritativeRequest: request,
            sourceWallet: source,
            policy: policy,
            isOnline: true
        )
        XCTAssertEqual(incomingRequest.title, "Payment request")
        XCTAssertTrue(incomingRequest.showsPayAction)

        XCTAssertFalse(KitPaymentMessagePresentationPolicy.presentation(
            for: descriptor,
            isOutgoing: false,
            authoritativeRequest: request,
            sourceWallet: source,
            policy: policy,
            isOnline: false
        ).showsPayAction)
        XCTAssertFalse(KitPaymentMessagePresentationPolicy.presentation(
            for: descriptor,
            isOutgoing: false,
            authoritativeRequest: request,
            sourceWallet: wallet(status: "restricted", currency: request.currency),
            policy: policy,
            isOnline: true
        ).showsPayAction)
        XCTAssertEqual(KitPaymentMessagePresentationPolicy.presentation(
            for: paid,
            isOutgoing: true,
            authoritativeRequest: nil,
            sourceWallet: source,
            policy: policy,
            isOnline: true
        ).title, "Payment sent")
        XCTAssertEqual(KitPaymentMessagePresentationPolicy.presentation(
            for: paid,
            isOutgoing: false,
            authoritativeRequest: nil,
            sourceWallet: source,
            policy: policy,
            isOnline: true
        ).title, "Payment received")
    }

    func testPaymentRequestThreadOutcomeIsLastWinsAndDirectionBound() throws {
        let id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let request = try XCTUnwrap(KitPaymentMessage(
            action: .request,
            paymentRequestId: id,
            amountMinor: 500,
            currencyCode: "UGX",
            currencyScale: 0,
            note: nil
        ))
        let declined = try XCTUnwrap(request.changingAction(to: .declined))
        let paid = try XCTUnwrap(request.changingAction(to: .paid))
        let forgedCancel = try XCTUnwrap(request.changingAction(to: .cancelled))
        let messages = [
            localMessage(request.encoded, isOutgoing: true),
            localMessage(declined.encoded, isOutgoing: false),
            localMessage(forgedCancel.encoded, isOutgoing: false),
            localMessage(paid.encoded, isOutgoing: false),
        ]

        XCTAssertEqual(
            KitPaymentRequestThreadStatePolicy.latestLocalOutcome(
                forRequestID: id.uppercased(),
                requestIsOutgoing: true,
                messages: messages
            ),
            KitPaymentThreadOutcome(action: .paid, reason: nil)
        )
    }

    func testAuthoritativeChatRequestMismatchPreventsResolution() throws {
        let request = paymentRequest(
            id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            destinationWalletId: "requester-wallet",
            requestedFromUserId: "payer-user",
            amount: "25.50"
        )
        let descriptor = try XCTUnwrap(KitPaymentMessage(action: .request, paymentRequest: request))
        XCTAssertEqual(
            KitPaymentRequestResolutionPolicy.resolve(descriptor, in: [request]),
            .match(request)
        )
        XCTAssertEqual(KitPaymentRequestResolutionPolicy.resolve(descriptor, in: []), .missing)

        let wrongAmount = paymentRequest(
            id: request.id,
            destinationWalletId: request.destinationWalletId,
            requestedFromUserId: request.requestedFromUserId,
            amount: "25.51"
        )
        let wrongCurrency = paymentRequest(
            id: request.id,
            destinationWalletId: request.destinationWalletId,
            requestedFromUserId: request.requestedFromUserId,
            amount: request.amount,
            currency: CurrencyDTO(code: "USD", scale: "2")
        )
        XCTAssertEqual(
            KitPaymentRequestResolutionPolicy.resolve(descriptor, in: [wrongAmount]),
            .mismatch
        )
        XCTAssertEqual(
            KitPaymentRequestResolutionPolicy.resolve(descriptor, in: [wrongCurrency]),
            .mismatch
        )
    }

    func testChatShareBindsTheConfirmedRecipientAndStableMessageIdentity() throws {
        let recipient = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let request = paymentRequest(
            id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            destinationWalletId: "requester-wallet",
            requestedFromUserId: recipient,
            amount: "25.50"
        )

        let share = try XCTUnwrap(
            KitPaymentRequestChatShare(
                paymentRequest: request,
                recipientUserID: recipient.uppercased(),
                recipientName: "  ExampleContact  "
            )
        )

        XCTAssertEqual(share.recipientUserID, recipient)
        XCTAssertEqual(share.recipientName, "ExampleContact")
        XCTAssertEqual(share.descriptor.paymentRequestId, request.id)
        XCTAssertEqual(share.clientMessageID, UUID(uuidString: request.id))
    }

    func testChatShareRejectsRecipientMismatchAndNonPendingRequests() {
        let recipient = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let other = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        let request = paymentRequest(
            id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            destinationWalletId: "requester-wallet",
            requestedFromUserId: recipient
        )
        let paid = paymentRequest(
            id: request.id,
            status: "paid",
            destinationWalletId: request.destinationWalletId,
            requestedFromUserId: recipient
        )

        XCTAssertNil(KitPaymentRequestChatShare(
            paymentRequest: request,
            recipientUserID: other,
            recipientName: "Other"
        ))
        XCTAssertNil(KitPaymentRequestChatShare(
            paymentRequest: paid,
            recipientUserID: recipient,
            recipientName: "ExampleContact"
        ))
        XCTAssertNil(KitPaymentRequestChatShare(
            paymentRequest: request,
            recipientUserID: recipient,
            recipientName: "   "
        ))
    }

    @MainActor
    func testSecureShareRetryDoesNotRecreateBackendRequest() async throws {
        let request = paymentRequest(
            id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            destinationWalletId: "requester-wallet",
            requestedFromUserId: "payer-user"
        )
        let session = KitPaymentRequestSecureShareSession()
        var createCount = 0
        var shareCount = 0
        let create: () async -> PaymentRequestDTO? = {
            createCount += 1
            return request
        }
        let share: (PaymentRequestDTO) async -> Bool = { sharedRequest in
            XCTAssertEqual(sharedRequest.id, request.id)
            shareCount += 1
            return shareCount == 2
        }

        let firstAttempt = await session.submit(create: create, share: share)
        XCTAssertFalse(firstAttempt)
        XCTAssertTrue(session.hasPendingRequest)

        let secondAttempt = await session.submit(create: create, share: share)
        XCTAssertTrue(secondAttempt)
        XCTAssertFalse(session.hasPendingRequest)
        XCTAssertEqual(createCount, 1)
        XCTAssertEqual(shareCount, 2)
    }

    func testScheduledPaymentBodyAndStepUpIntentMatchBackendExactly() throws {
        let date = try XCTUnwrap(ScheduledPaymentDates.parse("2026-08-30T09:15:00Z"))
        let body = CreateScheduledPaymentBody(
            sourceWalletId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            destinationWalletId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            conversationId: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
            amount: "500000",
            note: "School fees",
            scheduledFor: ScheduledPaymentDates.apiString(date)
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), [
            "source_wallet_id", "destination_wallet_id", "conversation_id", "amount", "note",
            "scheduled_for",
        ])
        XCTAssertEqual(object["scheduled_for"] as? String, "2026-08-30T09:15:00Z")

        let intent = ScheduledPaymentPolicy.intent(
            sourceWalletID: body.sourceWalletId,
            destinationWalletID: body.destinationWalletId,
            amount: body.amount,
            currencyCode: "UGX",
            note: body.note,
            scheduledFor: date,
            conversationID: body.conversationId
        )
        XCTAssertEqual(Set(intent.keys), [
            "action", "source_wallet_id", "destination_wallet_id", "amount", "currency", "note",
            "scheduled_for", "conversation_id",
        ])
        XCTAssertEqual(try XCTUnwrap(intent["action"] ?? nil), "create")
        XCTAssertEqual(try XCTUnwrap(intent["conversation_id"] ?? nil), body.conversationId)
    }

    func testScheduledPaymentDTORejectsContradictoryTerminalState() throws {
        let valid = try decodeScheduledPayment(
            status: "completed",
            paymentExecutionID: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
            walletTransactionID: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
            failure: "null",
            completedAt: "\"2026-08-30T09:15:03Z\"",
            cancelledAt: "null"
        )
        XCTAssertTrue(valid.isStructurallyValid)

        let contradictory = try decodeScheduledPayment(
            status: "completed",
            paymentExecutionID: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
            walletTransactionID: nil,
            failure: "null",
            completedAt: "\"2026-08-30T09:15:03Z\"",
            cancelledAt: "null"
        )
        XCTAssertFalse(contradictory.isStructurallyValid)
    }

    func testScheduledPaymentReceiptIsCanonicalAndOnlyTrustedAsServerProjection() throws {
        let scheduledAt = try XCTUnwrap(ScheduledPaymentDates.parse("2026-08-30T09:15:00Z"))
        let descriptor = try XCTUnwrap(KitScheduledPaymentMessage(
            action: .completed,
            scheduledPaymentID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            amountMinor: 500_000,
            currencyCode: "UGX",
            currencyScale: 0,
            scheduledAt: scheduledAt,
            walletTransactionID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            note: "School fees",
            reason: nil
        ))
        XCTAssertEqual(KitScheduledPaymentMessage.parse(descriptor.encoded), descriptor)
        XCTAssertFalse(SecureMessageReservedPrefixPolicy.allowsUserAuthoredText(descriptor.encoded))

        var projected = LocalMessage(
            id: descriptor.deterministicMessageID,
            conversationId: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
            senderId: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
            body: descriptor.encoded,
            createdAt: scheduledAt,
            sentAt: scheduledAt,
            state: .sent,
            failureReason: nil,
            isOutgoing: true
        )
        XCTAssertTrue(descriptor.isTrustedProjection(projected))
        projected.serverMessageId = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
        XCTAssertFalse(descriptor.isTrustedProjection(projected))
    }

    func testScheduledPaymentSyncAllowsRecipientOnlyForCompletedOutcome() throws {
        let completed = try decodeScheduledPaymentSyncEvent(
            type: "scheduled_payment.completed",
            status: "completed",
            walletTransactionID: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
            failureCode: nil,
            failureMessage: nil,
            completedAt: "2026-08-30T09:15:03Z",
            cancelledAt: nil
        )
        let recipientEnvelope = ScheduledPaymentSyncEnvelope(
            event: completed,
            currentUserID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        )
        XCTAssertNotNil(recipientEnvelope)
        let redactedAuthority = try decodeScheduledPayment(
            conversationID: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
            sourceWalletID: nil,
            status: "completed",
            paymentExecutionID: nil,
            walletTransactionID: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
            failure: "null",
            completedAt: "\"2026-08-30T09:15:03Z\"",
            cancelledAt: "null"
        )
        XCTAssertTrue(redactedAuthority.isStructurallyValid)
        XCTAssertTrue(try XCTUnwrap(recipientEnvelope).matchesAuthoritative(redactedAuthority))
        let wrongConversationAuthority = try decodeScheduledPayment(
            sourceWalletID: nil,
            status: "completed",
            paymentExecutionID: nil,
            walletTransactionID: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
            failure: "null",
            completedAt: "\"2026-08-30T09:15:03Z\"",
            cancelledAt: "null"
        )
        XCTAssertFalse(
            try XCTUnwrap(recipientEnvelope).matchesAuthoritative(wrongConversationAuthority)
        )

        let failed = try decodeScheduledPaymentSyncEvent(
            type: "scheduled_payment.failed",
            status: "failed",
            walletTransactionID: nil,
            failureCode: "INSUFFICIENT_FUNDS",
            failureMessage: "The wallet balance was insufficient.",
            completedAt: "2026-08-30T09:15:03Z",
            cancelledAt: nil
        )
        XCTAssertNil(ScheduledPaymentSyncEnvelope(
            event: failed,
            currentUserID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        ))
        XCTAssertNotNil(ScheduledPaymentSyncEnvelope(
            event: failed,
            currentUserID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        ))
    }

    func testScheduledPaymentGateSeparatesStandaloneFromChatRollout() throws {
        func capabilities(chatFeature: Bool, ready: Bool, minimumIOS: String) throws
            -> CapabilitiesDTO {
            let json = """
            {
              "api_version":"v1",
              "currency":{"code":"UGX","scale":"0"},
              "features":{
                "wallets":true,
                "internal_transfers":true,
                "scheduled_payments":true,
                "scheduled_chat_payments_v1":\(chatFeature)
              },
              "authentication":{},
              "protocols":{"payments":{"scheduled_chat_payments":{
                "version":"v1",
                "ready":\(ready),
                "minimum_android_version":"0.2.35",
                "minimum_android_version_code":46,
                "minimum_ios_version":"\(minimumIOS)"
              }}}
            }
            """
            return try JSONDecoder().decode(CapabilitiesDTO.self, from: Data(json.utf8))
        }

        let enabled = ScheduledPaymentPolicy(capabilities: try capabilities(
            chatFeature: true,
            ready: true,
            minimumIOS: "1.0.16-r39"
        ))
        XCTAssertTrue(enabled.enabled)
        XCTAssertTrue(enabled.chatEnabled)

        let withheld = ScheduledPaymentPolicy(capabilities: try capabilities(
            chatFeature: false,
            ready: true,
            minimumIOS: "1.0.16-r39"
        ))
        XCTAssertTrue(withheld.enabled, "standalone scheduling has its own gate")
        XCTAssertFalse(withheld.chatEnabled)

        XCTAssertFalse(ScheduledPaymentPolicy(capabilities: try capabilities(
            chatFeature: true,
            ready: true,
            minimumIOS: "1.0.16-r38"
        )).chatEnabled)
    }

    func testPendingServerScheduleSurvivesTruncatedRefreshUntilExactTerminalRead() throws {
        let retained = try decodeScheduledPayment(
            id: "11111111-1111-4111-8111-111111111111",
            status: "scheduled",
            paymentExecutionID: nil,
            walletTransactionID: nil,
            failure: "null",
            completedAt: "null",
            cancelledAt: "null"
        )
        let newlyFetched = try decodeScheduledPayment(
            id: "22222222-2222-4222-8222-222222222222",
            status: "scheduled",
            paymentExecutionID: nil,
            walletTransactionID: nil,
            failure: "null",
            completedAt: "null",
            cancelledAt: "null"
        )
        let afterTruncatedPage = ChatScheduledPaymentCollectionPolicy.reconcile(
            previous: [retained],
            fetched: [newlyFetched],
            exact: [],
            conversationID: "22222222-2222-4222-8222-222222222222"
        )
        XCTAssertEqual(Set(afterTruncatedPage.map(\.id)), Set([retained.id, newlyFetched.id]))

        let terminal = try decodeScheduledPayment(
            id: retained.id,
            status: "completed",
            paymentExecutionID: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
            walletTransactionID: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
            failure: "null",
            completedAt: "\"2026-08-30T09:15:03Z\"",
            cancelledAt: "null"
        )
        let afterExactRead = ChatScheduledPaymentCollectionPolicy.reconcile(
            previous: afterTruncatedPage,
            fetched: [newlyFetched],
            exact: [terminal],
            conversationID: "22222222-2222-4222-8222-222222222222"
        )
        XCTAssertEqual(afterExactRead.map(\.id), [newlyFetched.id])
    }

    private func decodeScheduledPayment(
        id: String = "11111111-1111-4111-8111-111111111111",
        conversationID: String = "22222222-2222-4222-8222-222222222222",
        sourceWalletID: String? = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        status: String,
        paymentExecutionID: String?,
        walletTransactionID: String?,
        failure: String,
        completedAt: String,
        cancelledAt: String
    ) throws -> ScheduledPaymentDTO {
        let execution = paymentExecutionID.map { "\"\($0)\"" } ?? "null"
        let transaction = walletTransactionID.map { "\"\($0)\"" } ?? "null"
        let sourceWallet = sourceWalletID.map { "\"\($0)\"" } ?? "null"
        let json = """
        {
          "id":"\(id)",
          "type":"scheduled_payment",
          "status":"\(status)",
          "conversation_id":"\(conversationID)",
          "source_wallet_id":\(sourceWallet),
          "destination_wallet_id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
          "amount":"500000",
          "currency":{"code":"UGX","scale":"0"},
          "note":"School fees",
          "scheduled_for":"2026-08-30T09:15:00Z",
          "payment_execution_id":\(execution),
          "wallet_transaction_id":\(transaction),
          "failure":\(failure),
          "completed_at":\(completedAt),
          "cancelled_at":\(cancelledAt),
          "created_at":"2026-08-29T09:15:00Z"
        }
        """
        return try JSONDecoder().decode(ScheduledPaymentDTO.self, from: Data(json.utf8))
    }

    private func decodeScheduledPaymentSyncEvent(
        type: String,
        status: String,
        walletTransactionID: String?,
        failureCode: String?,
        failureMessage: String?,
        completedAt: String?,
        cancelledAt: String?
    ) throws -> MessagingSyncEventDTO {
        func json(_ value: String?) -> String { value.map { "\"\($0)\"" } ?? "null" }
        let body = """
        {
          "id":"event-1",
          "type":"\(type)",
          "conversation_id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc",
          "resource_type":"scheduled_payment",
          "resource_id":"11111111-1111-4111-8111-111111111111",
          "occurred_at":"2026-08-30T09:15:04Z",
          "data":{
            "schema":"kit.scheduled-payment.v1",
            "scheduled_payment_id":"11111111-1111-4111-8111-111111111111",
            "conversation_id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc",
            "sender_user_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            "recipient_user_id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            "status":"\(status)",
            "amount_minor":"500000",
            "currency":"UGX",
            "currency_scale":0,
            "scheduled_for":"2026-08-30T09:15:00Z",
            "wallet_transaction_id":\(json(walletTransactionID)),
            "failure_code":\(json(failureCode)),
            "failure_message":\(json(failureMessage)),
            "completed_at":\(json(completedAt)),
            "cancelled_at":\(json(cancelledAt)),
            "note":"School fees"
          }
        }
        """
        return try JSONDecoder().decode(MessagingSyncEventDTO.self, from: Data(body.utf8))
    }

    private func paymentRequest(
        id: String = "request-id",
        status: String = "pending",
        destinationWalletId: String,
        requestedFromUserId: String?,
        amount: String = "10.00",
        currency: CurrencyDTO = CurrencyDTO(code: "UGX", scale: "2"),
        expiresAt: String? = nil,
        walletTransactionId: String? = nil
    ) -> PaymentRequestDTO {
        PaymentRequestDTO(
            id: id,
            type: "payment_request",
            status: status,
            destinationWalletId: destinationWalletId,
            requestedFromUserId: requestedFromUserId,
            amount: amount,
            currency: currency,
            note: "Lunch",
            expiresAt: expiresAt,
            walletTransactionId: walletTransactionId,
            paidAt: nil,
            createdAt: "2026-08-18T00:00:00Z"
        )
    }

    private func paymentRequestCreationRecovery(
        id: UUID,
        idempotencyKey: String,
        createdAt: Date
    ) -> PaymentRequestChatReceiptRecoveryRecord? {
        PaymentRequestChatReceiptRecoveryRecord(
            id: id,
            ownerUserID: recoveryRequesterID,
            destinationWalletID: recoveryWalletID,
            recipientUserID: recoveryPayerID,
            recipientName: "Payer",
            conversationID: recoveryConversationID,
            amount: "10.00",
            currency: CurrencyDTO(code: "UGX", scale: "2"),
            note: "Lunch",
            idempotencyKey: idempotencyKey,
            createdAt: createdAt
        )
    }

    private func wallet(status: String, currency: CurrencyDTO) -> Wallet {
        Wallet(
            id: "payer-wallet",
            name: "Primary",
            accountNumber: nil,
            accountType: nil,
            currency: currency,
            balances: WalletBalances(available: "100.00", ledger: "100.00"),
            status: status,
            isPrimary: true
        )
    }

    private func localMessage(_ body: String, isOutgoing: Bool) -> LocalMessage {
        LocalMessage(
            id: UUID(),
            conversationId: "conversation",
            senderId: "sender",
            body: body,
            createdAt: Date(),
            sentAt: nil,
            state: .sent,
            failureReason: nil,
            isOutgoing: isOutgoing,
            attachmentData: nil,
            pendingAttachment: nil
        )
    }
}
