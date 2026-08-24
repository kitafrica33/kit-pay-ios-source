import Foundation
import XCTest
@testable import KitPay

final class PaymentRequestTests: XCTestCase {
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

    func testChatShareLeaseRejectsEveryReplacementAccountBoundary() throws {
        let epoch = UUID(uuidString: "dddddddd-dddd-4ddd-8ddd-dddddddddddd")!
        let replacementEpoch = UUID(uuidString: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")!
        let recipient = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let confirmedRequest = paymentRequest(
            id: "ffffffff-ffff-4fff-8fff-ffffffffffff",
            destinationWalletId: "requester-wallet",
            requestedFromUserId: recipient,
            amount: "5.00"
        )
        let confirmedShare = try XCTUnwrap(KitPaymentRequestChatShare(
            paymentRequest: confirmedRequest,
            recipientUserID: recipient,
            recipientName: "ExampleContact"
        ))
        let lease = PaymentRequestChatShareLease(
            accountEpoch: epoch,
            userID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            sessionID: "session-a",
            recipientUserID: recipient,
            descriptor: confirmedShare.descriptor
        )

        XCTAssertTrue(lease.authorizes(confirmedShare))
        let alteredRequest = paymentRequest(
            id: confirmedRequest.id,
            destinationWalletId: confirmedRequest.destinationWalletId,
            requestedFromUserId: recipient,
            amount: "6.00"
        )
        let alteredShare = try XCTUnwrap(KitPaymentRequestChatShare(
            paymentRequest: alteredRequest,
            recipientUserID: recipient,
            recipientName: "ExampleContact"
        ))
        XCTAssertFalse(lease.authorizes(alteredShare))

        XCTAssertTrue(lease.matches(
            accountEpoch: epoch,
            userID: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA",
            sessionID: "session-a",
            recipientUserID: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
        ))
        XCTAssertFalse(lease.matches(
            accountEpoch: replacementEpoch,
            userID: lease.userID,
            sessionID: lease.sessionID,
            recipientUserID: lease.recipientUserID
        ))
        XCTAssertFalse(lease.matches(
            accountEpoch: epoch,
            userID: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
            sessionID: lease.sessionID,
            recipientUserID: lease.recipientUserID
        ))
        XCTAssertFalse(lease.matches(
            accountEpoch: epoch,
            userID: lease.userID,
            sessionID: "session-b",
            recipientUserID: lease.recipientUserID
        ))
        XCTAssertFalse(lease.matches(
            accountEpoch: epoch,
            userID: lease.userID,
            sessionID: lease.sessionID,
            recipientUserID: "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
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

    private func paymentRequest(
        id: String = "request-id",
        status: String = "pending",
        destinationWalletId: String,
        requestedFromUserId: String?,
        amount: String = "10.00",
        currency: CurrencyDTO = CurrencyDTO(code: "UGX", scale: "2"),
        expiresAt: String? = nil
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
            walletTransactionId: nil,
            paidAt: nil,
            createdAt: "2026-08-18T00:00:00Z"
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
