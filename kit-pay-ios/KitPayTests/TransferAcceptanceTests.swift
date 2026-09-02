import XCTest
@testable import KitPay

final class TransferAcceptanceTests: XCTestCase {
    private let transferID = "7b1f9d2c-3a54-4e6b-8f01-2c9d4e5f6a7b"
    private let senderUserID = "10000000-0000-0000-0000-000000000001"
    private let recipientUserID = "10000000-0000-0000-0000-000000000002"
    private let outsiderUserID = "10000000-0000-0000-0000-000000000003"
    private let sourceWalletID = "20000000-0000-0000-0000-000000000001"
    private let destinationWalletID = "20000000-0000-0000-0000-000000000002"
    private let conversationID = "30000000-0000-0000-0000-000000000001"

    /// The signed-in user is the transfer's recipient talking to its sender.
    private var recipientBinding: KitTransferPartyBinding {
        KitTransferPartyBinding(
            currentUserID: recipientUserID,
            peerUserID: senderUserID
        )!
    }

    /// The signed-in user is the transfer's sender talking to its recipient.
    private var senderBinding: KitTransferPartyBinding {
        KitTransferPartyBinding(
            currentUserID: senderUserID,
            peerUserID: recipientUserID
        )!
    }

    private func descriptor(
        action: KitPaymentMessageAction = .transfer,
        amountMinor: Int64 = 250_000,
        note: String? = "Lunch",
        reason: String? = nil
    ) -> KitPaymentMessage {
        KitPaymentMessage(
            action: action,
            paymentRequestId: transferID,
            amountMinor: amountMinor,
            currencyCode: "UGX",
            currencyScale: 2,
            note: note,
            reason: reason
        )!
    }

    private func transfer(
        status: String = "pending",
        amount: String = "2500.00",
        id: String? = nil,
        transactionId: String = "20000000-0000-0000-0000-000000000001",
        senderUserId: String? = nil,
        recipientUserId: String? = nil,
        canAccept: Bool = true,
        canReject: Bool = true,
        canReverse: Bool = true
    ) -> TransferAcceptanceDTO {
        try! JSONDecoder().decode(
            TransferAcceptanceDTO.self,
            from: JSONSerialization.data(withJSONObject: [
                "id": id ?? transferID,
                "transaction_id": transactionId,
                "status": status,
                "amount": amount,
                "currency": ["code": "UGX", "scale": "2"],
                "sender": ["id": senderUserId ?? senderUserID],
                "recipient": ["id": recipientUserId ?? recipientUserID],
                "note": "Lunch",
                "can_accept": canAccept,
                "can_reject": canReject,
                "can_reverse": canReverse,
            ])
        )
    }

    private func message(_ body: String, isOutgoing: Bool = false) -> LocalMessage {
        LocalMessage(
            id: UUID(),
            conversationId: "30000000-0000-0000-0000-000000000001",
            senderId: senderUserID,
            body: body,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            sentAt: nil,
            state: .sent,
            failureReason: nil,
            isOutgoing: isOutgoing,
            attachmentData: nil,
            pendingAttachment: nil
        )
    }

    private func recovery(
        id: UUID = UUID(),
        amount: String = "2500.00",
        note: String? = "Lunch",
        createdAt: Date = Date(timeIntervalSince1970: 1_780_000_000)
    ) -> TransferChatReceiptRecoveryRecord {
        TransferChatReceiptRecoveryRecord(
            id: id,
            ownerUserID: senderUserID,
            sourceWalletID: sourceWalletID,
            destinationWalletID: destinationWalletID,
            recipientUserID: recipientUserID,
            recipientName: "Waswa Titus Zera",
            conversationID: conversationID,
            amount: amount,
            currency: CurrencyDTO(code: "UGX", scale: "2"),
            note: note,
            createdAt: createdAt
        )!
    }

    private func walletTransaction(
        id: String = "40000000-0000-0000-0000-000000000001",
        counterpartyUserID: String? = nil,
        amount: String = "2500.00",
        note: String? = "Lunch",
        status: String = "completed",
        claim: TransferAcceptanceDTO? = nil,
        occurredAt: Date = Date(timeIntervalSince1970: 1_780_000_030)
    ) -> WalletTransaction {
        WalletTransaction(
            id: id,
            walletId: sourceWalletID,
            reference: "TRF-RECOVERY",
            amount: amount,
            totals: CustomerTransactionTotals(added: "0", deducted: amount),
            currency: CurrencyDTO(code: "UGX", scale: "2"),
            type: "internal_transfer",
            direction: "debit",
            status: status,
            counterparty: counterpartyUserID.map {
                Counterparty(id: $0, name: "Waswa Titus Zera", phone: nil, accountNumber: nil)
            },
            note: note,
            claim: claim,
            occurredAt: ISO8601DateFormatter().string(from: occurredAt)
        )
    }

    // MARK: Durable transfer chat-receipt recovery

    func testRecoveryRecordRoundTripsAndLegacyStateWithoutJournalStillDecodes() throws {
        let original = recovery(
            id: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!
        )
        let confirmation = try XCTUnwrap(
            TransferChatReceiptConfirmation(
                transaction: walletTransaction(),
                recovery: original,
                evidence: .directResponse
            )
        )
        var records = [original]
        XCTAssertTrue(
            TransferChatReceiptRecoveryPolicy.markSubmitted(
                recordID: original.id,
                in: &records
            )
        )
        XCTAssertTrue(
            TransferChatReceiptRecoveryPolicy.storeConfirmation(
                confirmation,
                for: original.id,
                in: &records
            )
        )
        let encoded = try JSONEncoder().encode(records[0])
        XCTAssertEqual(
            try JSONDecoder().decode(TransferChatReceiptRecoveryRecord.self, from: encoded),
            records[0]
        )

        let legacy = Data(
            #"{"wallets":[],"transactions":[],"conversations":[],"messages":[],"calls":[],"outbox":[]}"#.utf8
        )
        XCTAssertNil(
            try JSONDecoder().decode(PersistedState.self, from: legacy)
                .pendingTransferChatReceipts
        )
        let decoded = try JSONDecoder().decode(PersistedState.self, from: legacy)
        XCTAssertNil(decoded.pendingPaymentRequestChatReceipts)
        XCTAssertNil(decoded.pendingPaymentRequestResolutionChatReceipts)
        XCTAssertNil(decoded.pendingGroupPaymentChatReceipts)
        XCTAssertNil(decoded.pendingGroupContributionChatReceipts)
    }

    func testIdenticalAmbiguousRetryReusesTheOriginalIdempotencyAuthority() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_100)
        let original = recovery(
            id: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!,
            createdAt: now.addingTimeInterval(-30)
        )
        let retry = recovery(
            id: UUID(uuidString: "50000000-0000-0000-0000-000000000002")!,
            createdAt: now
        )
        var records: [TransferChatReceiptRecoveryRecord] = []

        let first = try XCTUnwrap(
            TransferChatReceiptRecoveryPolicy.insertOrReuse(original, in: &records, now: now)
        )
        let reused = try XCTUnwrap(
            TransferChatReceiptRecoveryPolicy.insertOrReuse(retry, in: &records, now: now)
        )

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(reused.id, first.id)
        XCTAssertEqual(reused.idempotencyKey, first.idempotencyKey)
        XCTAssertEqual(
            reused.idempotencyKey,
            "ios-transfer-50000000-0000-0000-0000-000000000001"
        )
    }

    func testLegacyTransferJournalDecodesAsSubmittedWithItsOriginalRetryClock() throws {
        let original = recovery(
            id: UUID(uuidString: "50000000-0000-0000-0000-000000000004")!
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any]
        )
        object.removeValue(forKey: "phase")
        object["nextLookupAt"] = object.removeValue(forKey: "nextRecoveryAt")
        XCTAssertNotNil(object.removeValue(forKey: "recoveryAttemptCount"))
        object["lookupAttemptCount"] = 3
        let decoded = try JSONDecoder().decode(
            TransferChatReceiptRecoveryRecord.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.phase, .submitted)
        XCTAssertEqual(decoded.nextRecoveryAt, original.nextRecoveryAt)
        XCTAssertEqual(decoded.recoveryAttemptCount, 3)
        XCTAssertNil(decoded.confirmation)
        XCTAssertTrue(decoded.isStructurallyValid)
    }

    func testExactPostResponseProducesTheDeterministicCanonicalSentCard() throws {
        let record = recovery()
        let transaction = walletTransaction(counterpartyUserID: nil)
        let confirmation = try XCTUnwrap(
            TransferChatReceiptConfirmation(
                transaction: transaction,
                recovery: record,
                evidence: .directResponse
            )
        )
        let descriptor = try XCTUnwrap(
            KitPaymentMessage.parse(confirmation.encodedDescriptor)
        )

        XCTAssertEqual(confirmation.transactionID, transaction.id)
        XCTAssertEqual(confirmation.messageID, transaction.id)
        XCTAssertEqual(confirmation.clientMessageID, UUID(uuidString: transaction.id))
        XCTAssertEqual(descriptor.action, .sent)
        XCTAssertEqual(descriptor.amountMinor, 250_000)
        XCTAssertEqual(descriptor.note, "Lunch")
        XCTAssertTrue(confirmation.isValid(for: record))
        let recovered = TransferChatReceiptConfirmation(
            transaction: transaction,
            recovery: record,
            evidence: .exactRecovery
        )
        XCTAssertEqual(recovered, confirmation)
    }

    func testClaimableResponseUsesTheClaimUUIDForItsDeterministicTransferCard() throws {
        let record = recovery()
        let transactionID = "40000000-0000-0000-0000-000000000003"
        let transaction = walletTransaction(
            id: transactionID,
            status: "pending",
            claim: transfer(
                transactionId: transactionID,
                senderUserId: senderUserID,
                recipientUserId: recipientUserID
            )
        )
        let confirmation = try XCTUnwrap(
            TransferChatReceiptConfirmation(
                transaction: transaction,
                recovery: record,
                evidence: .directResponse
            )
        )
        let descriptor = try XCTUnwrap(
            KitPaymentMessage.parse(confirmation.encodedDescriptor)
        )

        XCTAssertEqual(confirmation.transactionID, transactionID)
        XCTAssertEqual(confirmation.messageID, transferID)
        XCTAssertEqual(descriptor.action, .transfer)
        XCTAssertEqual(descriptor.paymentRequestId, transferID)
    }

    func testOnlyPreparedRecordsExpireAndSubmittedOrConfirmedRemainPending() throws {
        let createdAt = Date(timeIntervalSince1970: 1_780_000_000)
        let now = createdAt.addingTimeInterval(
            FinancialChatReceiptRecoveryPolicy.preparedRetentionLifetime + 1
        )
        var prepared = recovery(createdAt: createdAt)
        var submitted = recovery(createdAt: createdAt)
        var confirmed = recovery(createdAt: createdAt)
        var submittedRecords = [submitted]
        XCTAssertTrue(
            TransferChatReceiptRecoveryPolicy.markSubmitted(
                recordID: submitted.id,
                in: &submittedRecords,
                now: createdAt
            )
        )
        submitted = submittedRecords[0]
        var confirmedRecords = [confirmed]
        XCTAssertTrue(
            TransferChatReceiptRecoveryPolicy.markSubmitted(
                recordID: confirmed.id,
                in: &confirmedRecords,
                now: createdAt
            )
        )
        let confirmation = try XCTUnwrap(
            TransferChatReceiptConfirmation(
                transaction: walletTransaction(),
                recovery: confirmed,
                evidence: .exactRecovery
            )
        )
        XCTAssertTrue(
            TransferChatReceiptRecoveryPolicy.storeConfirmation(
                confirmation,
                for: confirmed.id,
                in: &confirmedRecords
            )
        )
        confirmed = confirmedRecords[0]
        var records = [prepared, submitted, confirmed]

        TransferChatReceiptRecoveryPolicy.sanitize(
            &records,
            ownerUserID: senderUserID,
            now: now
        )

        XCTAssertEqual(Set(records.map(\.phase)), Set([.submitted, .confirmed]))
    }

    func testRecoveryFailureBacksOffWithoutDroppingSubmittedAuthority() {
        let now = Date(timeIntervalSince1970: 1_780_000_100)
        let record = recovery(createdAt: now)
        var records = [record]
        XCTAssertTrue(
            TransferChatReceiptRecoveryPolicy.markSubmitted(
                recordID: record.id,
                in: &records,
                now: now
            )
        )
        XCTAssertTrue(
            TransferChatReceiptRecoveryPolicy.recordRecoveryFailure(
                for: record.id,
                in: &records,
                now: now
            )
        )
        XCTAssertEqual(records[0].phase, .submitted)
        XCTAssertEqual(records[0].recoveryAttemptCount, 1)
        XCTAssertGreaterThan(records[0].nextRecoveryAt, now)
    }

    func testJournalIsAcknowledgedOnlyByItsExactDurableMessageID() throws {
        let record = recovery()
        let confirmation = try XCTUnwrap(
            TransferChatReceiptConfirmation(
                transaction: walletTransaction(),
                recovery: record,
                evidence: .directResponse
            )
        )
        var records = [record]
        XCTAssertTrue(
            TransferChatReceiptRecoveryPolicy.markSubmitted(
                recordID: record.id,
                in: &records
            )
        )
        XCTAssertTrue(
            TransferChatReceiptRecoveryPolicy.storeConfirmation(
                confirmation,
                for: record.id,
                in: &records
            )
        )
        XCTAssertFalse(
            TransferChatReceiptRecoveryPolicy.acknowledgeDurableMessage(
                recordID: record.id,
                messageID: UUID(),
                in: &records
            )
        )
        XCTAssertEqual(records.count, 1)
        XCTAssertTrue(
            TransferChatReceiptRecoveryPolicy.acknowledgeDurableMessage(
                recordID: record.id,
                messageID: try XCTUnwrap(confirmation.clientMessageID),
                in: &records
            )
        )
        XCTAssertTrue(records.isEmpty)
    }

    func testOnlyStructuredDefinitiveTransferRejectionsDiscardTheJournal() {
        XCTAssertTrue(
            TransferChatReceiptRecoveryPolicy.isDefinitiveRejection(
                APIErrorPayload(
                    code: "VALIDATION_FAILED",
                    message: "Invalid transfer",
                    httpStatus: 422
                )
            )
        )
        XCTAssertFalse(
            TransferChatReceiptRecoveryPolicy.isDefinitiveRejection(
                APIClientError.httpResponse(status: 422, retryAfter: nil)
            )
        )
        for code in [
            "IDEMPOTENCY_REQUEST_IN_PROGRESS",
            "IDEMPOTENCY_KEY_REUSED",
            "IDEMPOTENCY_REPLAY_UNAVAILABLE",
        ] {
            XCTAssertFalse(
                TransferChatReceiptRecoveryPolicy.isDefinitiveRejection(
                    APIErrorPayload(code: code, message: "retain", httpStatus: 409)
                )
            )
        }
        for status in 500 ... 599 {
            XCTAssertFalse(
                TransferChatReceiptRecoveryPolicy.isDefinitiveRejection(
                    APIErrorPayload(code: "SERVER_ERROR", message: "retain", httpStatus: status)
                )
            )
        }
        XCTAssertFalse(
            TransferChatReceiptRecoveryPolicy.isDefinitiveRejection(CancellationError())
        )
        XCTAssertEqual(
            TransferChatReceiptRecoveryPolicy.recoveryDecision(
                for: APIErrorPayload(
                    code: "TRANSFER_RECOVERY_NOT_FOUND",
                    message: "not committed",
                    httpStatus: 404
                )
            ),
            .notCommitted
        )
        XCTAssertEqual(
            TransferChatReceiptRecoveryPolicy.recoveryDecision(
                for: APIErrorPayload(
                    code: "IDEMPOTENCY_REQUEST_IN_PROGRESS",
                    message: "wait",
                    httpStatus: 409
                )
            ),
            .retain
        )
        XCTAssertEqual(
            TransferChatReceiptRecoveryPolicy.recoveryDecision(
                for: APIErrorPayload(
                    code: "TRANSFER_NOT_FOUND",
                    message: "opaque",
                    httpStatus: 404
                )
            ),
            .retain
        )
        XCTAssertEqual(
            TransferChatReceiptRecoveryPolicy.recoveryDecision(
                for: APIClientError.invalidResponse
            ),
            .retain
        )
        XCTAssertFalse(
            TransferChatReceiptRecoveryPolicy.isDefinitiveRejection(
                APIErrorPayload(
                    code: "TEMPORARY_FAILURE",
                    message: "Try again",
                    httpStatus: 503
                )
            )
        )
    }

    // MARK: Wire

    func testTransferFamilyActionsRoundTripOnTheCanonicalWire() {
        for action in KitPaymentMessageAction.allCases {
            let original = descriptor(action: action)
            let parsed = KitPaymentMessage.parse(original.encoded)
            XCTAssertEqual(parsed, original, "\(action.rawValue) must round-trip")
            XCTAssertTrue(original.encoded.hasPrefix("KITPAY1:v=1&a=\(action.rawValue)&"))
        }
    }

    func testCanonicalWireCarriesReasonAfterNoteAndRejectsInvalidReasons() throws {
        let original = descriptor(
            action: .reversed,
            note: "Lunch & drinks",
            reason: "Wrong person & account"
        )
        let encoded = original.encoded
        let noteRange = try XCTUnwrap(encoded.range(of: "&note="))
        let reasonRange = try XCTUnwrap(encoded.range(of: "&rsn="))
        XCTAssertLessThan(noteRange.lowerBound, reasonRange.lowerBound)
        XCTAssertEqual(KitPaymentMessage.parse(encoded), original)
        XCTAssertEqual(KitPaymentMessage.parse(encoded)?.reason, "Wrong person & account")
        XCTAssertNil(KitPaymentMessage.parse("\(encoded)&rsn=again"))
        XCTAssertNil(
            KitPaymentMessage(
                action: .reversed,
                paymentRequestId: transferID,
                amountMinor: 1,
                currencyCode: "UGX",
                currencyScale: 0,
                note: nil,
                reason: String(repeating: "x", count: 141)
            )
        )
    }

    func testResolutionReasonIsTrimmedAndCappedToTheWireLimit() {
        XCTAssertEqual(ChatTransfersViewModel.canonicalReason("  Wrong person  "), "Wrong person")
        let capped = ChatTransfersViewModel.canonicalReason(String(repeating: "🙂", count: 100))
        XCTAssertEqual(capped?.utf16.count, KitPaymentMessage.maximumReasonLength)
        XCTAssertNil(ChatTransfersViewModel.canonicalReason(" \n\t "))
    }

    func testTransferResponseDecodesTheClaimUsedAsTheChatReference() throws {
        let object: [String: Any] = [
            "id": "20000000-0000-0000-0000-000000000001",
            "wallet_id": "30000000-0000-0000-0000-000000000001",
            "reference": "TRF-1",
            "amount": "-2500.00",
            "currency": ["code": "UGX", "scale": "2"],
            "type": "internal_transfer",
            "direction": "debit",
            "status": "pending",
            "note": "Lunch",
            "occurred_at": "2026-08-24T10:00:00Z",
            "claim": [
                "id": transferID,
                "transaction_id": "20000000-0000-0000-0000-000000000001",
                "status": "pending",
                "amount": "2500.00",
                "currency": ["code": "UGX", "scale": "2"],
                "sender": ["id": senderUserID],
                "recipient": ["id": recipientUserID],
                "expires_at": "2026-08-31T10:00:00Z",
                "can_reverse": true,
            ] as [String: Any],
        ]
        let transaction = try JSONDecoder().decode(
            WalletTransaction.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(transaction.claim?.id, transferID)
        XCTAssertEqual(transaction.claim?.knownStatus, .pending)
        XCTAssertTrue(transaction.claim?.canReverse == true)
    }

    func testChangingActionDerivesResponsesFromTheTransferEvent() {
        let event = descriptor()
        let accepted = event.changingAction(to: .accepted)
        XCTAssertEqual(accepted?.action, .accepted)
        XCTAssertEqual(accepted?.paymentRequestId, transferID)
        XCTAssertEqual(accepted?.amountMinor, event.amountMinor)
    }

    // MARK: Capability gate

    func testAcceptanceRequiresEveryFeatureFlag() {
        XCTAssertFalse(TransferAcceptancePolicy(features: nil).acceptanceEnabled)
        XCTAssertFalse(
            TransferAcceptancePolicy(features: [
                "wallets": true, "internal_transfers": true,
            ]).acceptanceEnabled
        )
        XCTAssertFalse(
            TransferAcceptancePolicy(features: [
                "wallets": true, "internal_transfers": nil, "claimable_transfers": true,
            ]).acceptanceEnabled
        )
        let enabled = TransferAcceptancePolicy(features: [
            "wallets": true, "internal_transfers": true, "claimable_transfers": true,
        ])
        XCTAssertTrue(enabled.acceptanceEnabled)
        XCTAssertTrue(enabled.transfersEnabled)
    }

    // MARK: Party binding

    func testBindingRequiresTwoDistinctNonEmptyParties() {
        XCTAssertNil(KitTransferPartyBinding(currentUserID: nil, peerUserID: senderUserID))
        XCTAssertNil(KitTransferPartyBinding(currentUserID: senderUserID, peerUserID: ""))
        XCTAssertNil(
            KitTransferPartyBinding(currentUserID: senderUserID, peerUserID: senderUserID)
        )
        XCTAssertNotNil(
            KitTransferPartyBinding(
                currentUserID: senderUserID.uppercased(),
                peerUserID: recipientUserID
            )
        )
    }

    // MARK: Resolution

    func testResolutionMatchesOnlyTheFieldExactBoundTransfer() {
        XCTAssertEqual(
            KitTransferResolutionPolicy.resolve(
                descriptor(),
                in: [transfer()],
                binding: recipientBinding
            ),
            .match(transfer())
        )
        XCTAssertEqual(
            KitTransferResolutionPolicy.resolve(
                descriptor(),
                in: [],
                binding: recipientBinding
            ),
            .missing
        )
        XCTAssertEqual(
            KitTransferResolutionPolicy.resolve(
                descriptor(),
                in: [transfer(amount: "9999.00")],
                binding: recipientBinding
            ),
            .mismatch
        )
        XCTAssertEqual(
            KitTransferResolutionPolicy.resolve(
                descriptor(action: .accepted),
                in: [transfer()],
                binding: recipientBinding
            ),
            .mismatch,
            "Only the transfer event itself resolves; responses are receipts"
        )
        XCTAssertEqual(
            KitTransferResolutionPolicy.resolve(
                descriptor(),
                in: [transfer(status: "future_state")],
                binding: recipientBinding
            ),
            .mismatch,
            "Unknown server states must never gain actions"
        )
    }

    func testRelayedDescriptorInTheWrongConversationNeverResolves() {
        // A peer relays the descriptor of a REAL transfer that involves a third party: the
        // party binding must reject it even though id/amount/currency all match.
        let wrongPeer = KitTransferPartyBinding(
            currentUserID: recipientUserID,
            peerUserID: outsiderUserID
        )!
        XCTAssertEqual(
            KitTransferResolutionPolicy.resolve(
                descriptor(),
                in: [transfer()],
                binding: wrongPeer
            ),
            .mismatch
        )
        XCTAssertEqual(
            KitTransferResolutionPolicy.resolve(
                descriptor(),
                in: [transfer(senderUserId: nil, recipientUserId: "")],
                binding: recipientBinding
            ),
            .mismatch,
            "Blank party fields fail closed"
        )
    }

    func testResolutionIsCaseInsensitiveOnIDsAndParties() {
        let upper = transfer(
            id: transferID.uppercased(),
            senderUserId: senderUserID.uppercased(),
            recipientUserId: recipientUserID.uppercased()
        )
        XCTAssertEqual(
            KitTransferResolutionPolicy.resolve(
                descriptor(),
                in: [upper],
                binding: recipientBinding
            ),
            .match(upper)
        )
    }

    // MARK: Presentation

    func testImmediateTransferIsFinalAndHeldTransferStaysInertWithoutCapability() {
        let immediate = KitTransferMessagePresentationPolicy.presentation(
            for: descriptor(action: .sent),
            isOutgoing: false,
            authoritativeTransfer: nil,
            localOutcome: nil,
            binding: recipientBinding,
            acceptanceEnabled: false,
            isOnline: true
        )
        XCTAssertEqual(immediate.title, "Payment received")
        XCTAssertEqual(immediate.statusText, "Completed")
        XCTAssertFalse(immediate.showsAnyAction)

        let held = KitTransferMessagePresentationPolicy.presentation(
            for: descriptor(),
            isOutgoing: false,
            authoritativeTransfer: transfer(),
            localOutcome: nil,
            binding: recipientBinding,
            acceptanceEnabled: false,
            isOnline: true
        )
        XCTAssertEqual(held.title, "Payment awaiting acceptance")
        XCTAssertFalse(held.showsAnyAction)
    }

    func testPendingIncomingTransferOffersAcceptAndRejectOnlyOnlineToItsRecipient() {
        let online = KitTransferMessagePresentationPolicy.presentation(
            for: descriptor(),
            isOutgoing: false,
            authoritativeTransfer: transfer(),
            localOutcome: nil,
            binding: recipientBinding,
            acceptanceEnabled: true,
            isOnline: true
        )
        XCTAssertTrue(online.showsAccept)
        XCTAssertTrue(online.showsReject)
        XCTAssertFalse(online.showsReverse)

        let offline = KitTransferMessagePresentationPolicy.presentation(
            for: descriptor(),
            isOutgoing: false,
            authoritativeTransfer: transfer(),
            localOutcome: nil,
            binding: recipientBinding,
            acceptanceEnabled: true,
            isOnline: false
        )
        XCTAssertFalse(offline.showsAnyAction)

        // The transfer's SENDER must never see Accept, even if chat direction says incoming.
        let senderSeesIncoming = KitTransferMessagePresentationPolicy.presentation(
            for: descriptor(),
            isOutgoing: false,
            authoritativeTransfer: transfer(),
            localOutcome: nil,
            binding: senderBinding,
            acceptanceEnabled: true,
            isOnline: true
        )
        XCTAssertFalse(senderSeesIncoming.showsAccept)
        XCTAssertFalse(senderSeesIncoming.showsReject)
    }

    func testPendingOutgoingTransferOffersReverseOnlyToItsSenderUntilAccepted() {
        let pending = KitTransferMessagePresentationPolicy.presentation(
            for: descriptor(),
            isOutgoing: true,
            authoritativeTransfer: transfer(),
            localOutcome: nil,
            binding: senderBinding,
            acceptanceEnabled: true,
            isOnline: true
        )
        XCTAssertTrue(pending.showsReverse)
        XCTAssertFalse(pending.showsAccept)
        XCTAssertFalse(pending.showsReject)

        // The transfer's RECIPIENT must never see Reverse, even on an outgoing bubble.
        let recipientSeesOutgoing = KitTransferMessagePresentationPolicy.presentation(
            for: descriptor(),
            isOutgoing: true,
            authoritativeTransfer: transfer(),
            localOutcome: nil,
            binding: recipientBinding,
            acceptanceEnabled: true,
            isOnline: true
        )
        XCTAssertFalse(recipientSeesOutgoing.showsReverse)

        let accepted = KitTransferMessagePresentationPolicy.presentation(
            for: descriptor(),
            isOutgoing: true,
            authoritativeTransfer: transfer(status: "accepted"),
            localOutcome: nil,
            binding: senderBinding,
            acceptanceEnabled: true,
            isOnline: true
        )
        XCTAssertFalse(accepted.showsAnyAction)
        XCTAssertEqual(accepted.statusText, "Accepted · Final")
    }

    func testServerPermissionFlagsAreRequiredEvenForTheCorrectParty() {
        let recipient = KitTransferMessagePresentationPolicy.presentation(
            for: descriptor(),
            isOutgoing: false,
            authoritativeTransfer: transfer(canAccept: false, canReject: false),
            localOutcome: nil,
            binding: recipientBinding,
            acceptanceEnabled: true,
            isOnline: true
        )
        XCTAssertFalse(recipient.showsAccept)
        XCTAssertFalse(recipient.showsReject)

        let sender = KitTransferMessagePresentationPolicy.presentation(
            for: descriptor(),
            isOutgoing: true,
            authoritativeTransfer: transfer(canReverse: false),
            localOutcome: nil,
            binding: senderBinding,
            acceptanceEnabled: true,
            isOnline: true
        )
        XCTAssertFalse(sender.showsReverse)
    }

    func testUnresolvedTransferNeverShowsButtonsAndUsesTheThreadHint() {
        let verifying = KitTransferMessagePresentationPolicy.presentation(
            for: descriptor(),
            isOutgoing: false,
            authoritativeTransfer: nil,
            localOutcome: nil,
            binding: recipientBinding,
            acceptanceEnabled: true,
            isOnline: true
        )
        XCTAssertFalse(verifying.showsAnyAction)
        XCTAssertEqual(verifying.statusText, "Verifying payment status")

        let hinted = KitTransferMessagePresentationPolicy.presentation(
            for: descriptor(),
            isOutgoing: true,
            authoritativeTransfer: nil,
            localOutcome: .reversed,
            binding: senderBinding,
            acceptanceEnabled: true,
            isOnline: false
        )
        XCTAssertFalse(hinted.showsAnyAction)
        XCTAssertEqual(hinted.statusText, "Reversed by the sender")
    }

    func testMismatchedAuthoritativeObjectDisablesActions() {
        let presentation = KitTransferMessagePresentationPolicy.presentation(
            for: descriptor(),
            isOutgoing: false,
            authoritativeTransfer: transfer(amount: "9999.00"),
            localOutcome: nil,
            binding: recipientBinding,
            acceptanceEnabled: true,
            isOnline: true
        )
        XCTAssertFalse(presentation.showsAnyAction)
    }

    func testResponseEventsAreImmutableReceipts() {
        for action in [KitPaymentMessageAction.accepted, .rejected, .reversed] {
            let presentation = KitTransferMessagePresentationPolicy.presentation(
                for: descriptor(action: action),
                isOutgoing: false,
                authoritativeTransfer: transfer(),
                localOutcome: nil,
                binding: recipientBinding,
                acceptanceEnabled: true,
                isOnline: true
            )
            XCTAssertFalse(presentation.showsAnyAction, action.rawValue)
        }
    }

    // MARK: Acceptance window

    func testDaysRemainingRoundsUpAndFailsClosedOnGarbage() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let inThreeAndABitDays = ISO8601DateFormatter().string(
            from: now.addingTimeInterval(3.2 * 86_400)
        )
        XCTAssertEqual(
            TransferAcceptanceWindowPolicy.daysRemaining(
                untilExpiry: inThreeAndABitDays,
                now: now
            ),
            4
        )
        XCTAssertEqual(
            TransferAcceptanceWindowPolicy.daysRemaining(
                untilExpiry: ISO8601DateFormatter().string(from: now.addingTimeInterval(-60)),
                now: now
            ),
            0
        )
        XCTAssertNil(TransferAcceptanceWindowPolicy.daysRemaining(untilExpiry: nil, now: now))
        XCTAssertNil(
            TransferAcceptanceWindowPolicy.daysRemaining(untilExpiry: "not-a-date", now: now)
        )
    }

    func testExpiryReasonFitsTheWireReasonLimit() {
        XCTAssertLessThanOrEqual(
            TransferAcceptanceWindowPolicy.autoReversalReason.utf16.count,
            KitPaymentMessage.maximumReasonLength
        )
        XCTAssertNotNil(
            KitPaymentMessage(
                action: .expired,
                paymentRequestId: transferID,
                amountMinor: 250_000,
                currencyCode: "UGX",
                currencyScale: 2,
                note: nil,
                reason: TransferAcceptanceWindowPolicy.autoReversalReason
            )
        )
    }

    func testAutoReversalReceiptReasonCapsServerCopyAndFallsBack() throws {
        let longServerReason = String(repeating: "🙂", count: 100)
        let capped = ChatTransfersViewModel.autoReversalReceiptReason(longServerReason)
        XCTAssertEqual(capped.utf16.count, KitPaymentMessage.maximumReasonLength)
        XCTAssertNotNil(
            KitPaymentMessage(
                action: .expired,
                paymentRequestId: transferID,
                amountMinor: 250_000,
                currencyCode: "UGX",
                currencyScale: 2,
                note: nil,
                reason: capped
            )
        )
        XCTAssertEqual(
            ChatTransfersViewModel.autoReversalReceiptReason(" \n\t "),
            TransferAcceptanceWindowPolicy.autoReversalReason
        )
    }

    func testAutoReversalReceiptIDIsDeterministicPerTransfer() {
        let first = TransferAcceptanceWindowPolicy.autoReversalReceiptMessageID(
            forTransferID: transferID
        )
        let second = TransferAcceptanceWindowPolicy.autoReversalReceiptMessageID(
            forTransferID: transferID.uppercased()
        )
        XCTAssertEqual(first, second, "Case must not change the receipt identity")
        XCTAssertNotEqual(
            first,
            TransferAcceptanceWindowPolicy.autoReversalReceiptMessageID(
                forTransferID: "9c14e2c6-1f6a-4a6a-9f7e-6a1e2b3c4d5e"
            )
        )
        XCTAssertNotEqual(
            first.uuidString.lowercased(),
            transferID,
            "The receipt id must differ from the transfer event's own message id"
        )
    }

    func testResolutionReceiptIDsAreDeterministicActionScopedAndFailClosed() throws {
        let accepted = try XCTUnwrap(
            TransferAcceptanceWindowPolicy.resolutionReceiptMessageID(
                forTransferID: transferID,
                action: .accepted
            )
        )
        XCTAssertEqual(
            accepted,
            TransferAcceptanceWindowPolicy.resolutionReceiptMessageID(
                forTransferID: transferID.uppercased(),
                action: .accepted
            )
        )
        let terminalIDs = try [
            KitPaymentMessageAction.accepted,
            .rejected,
            .reversed,
        ].map { action in
            try XCTUnwrap(
                TransferAcceptanceWindowPolicy.resolutionReceiptMessageID(
                    forTransferID: transferID,
                    action: action
                )
            )
        }
        XCTAssertEqual(Set(terminalIDs).count, terminalIDs.count)
        XCTAssertNotEqual(
            accepted,
            TransferAcceptanceWindowPolicy.autoReversalReceiptMessageID(
                forTransferID: transferID
            )
        )
        XCTAssertNotEqual(accepted.uuidString.lowercased(), transferID)
        XCTAssertNil(
            TransferAcceptanceWindowPolicy.resolutionReceiptMessageID(
                forTransferID: transferID,
                action: .transfer
            )
        )
    }

    func testExpiredTransfersRenderTheDocumentedReason() {
        let auto = KitTransferMessagePresentationPolicy.presentation(
            for: descriptor(),
            isOutgoing: true,
            authoritativeTransfer: transfer(status: "expired"),
            localOutcome: nil,
            binding: senderBinding,
            acceptanceEnabled: true,
            isOnline: true
        )
        XCTAssertFalse(auto.showsAnyAction)
        XCTAssertTrue(auto.statusText.contains("Returned automatically"))

        let receipt = KitTransferMessagePresentationPolicy.presentation(
            for: descriptor(
                action: .expired,
                note: nil,
                reason: TransferAcceptanceWindowPolicy.autoReversalReason
            ),
            isOutgoing: true,
            authoritativeTransfer: nil,
            localOutcome: nil,
            binding: senderBinding,
            acceptanceEnabled: true,
            isOnline: true
        )
        XCTAssertEqual(receipt.title, "Payment returned")
    }

    // MARK: Thread hint

    func testThreadStateAcceptsOnlyDirectionConsistentOutcomes() {
        // My outgoing transfer: only the PEER (incoming messages) can accept/reject, and only
        // I (outgoing) can reverse.
        let peerAccepted = [
            message(descriptor().encoded, isOutgoing: true),
            message(descriptor(action: .accepted).encoded, isOutgoing: false),
        ]
        XCTAssertEqual(
            KitTransferThreadStatePolicy.latestLocalOutcome(
                forTransferID: transferID,
                transferIsOutgoing: true,
                messages: peerAccepted
            ),
            .accepted
        )

        // A peer forging "reversed" for MY outgoing transfer must be ignored: only the sender
        // (me, outgoing) authors reversals.
        let forgedReversal = [
            message(descriptor().encoded, isOutgoing: true),
            message(descriptor(action: .reversed).encoded, isOutgoing: false),
        ]
        XCTAssertNil(
            KitTransferThreadStatePolicy.latestLocalOutcome(
                forTransferID: transferID,
                transferIsOutgoing: true,
                messages: forgedReversal
            )
        )

        // A sender forging "accepted" for their own transfer (to fake finality toward the
        // recipient) must be ignored: acceptance is authored by the recipient only.
        let forgedAcceptance = [
            message(descriptor().encoded, isOutgoing: false),
            message(descriptor(action: .accepted).encoded, isOutgoing: false),
        ]
        XCTAssertNil(
            KitTransferThreadStatePolicy.latestLocalOutcome(
                forTransferID: transferID,
                transferIsOutgoing: false,
                messages: forgedAcceptance
            )
        )
    }

    func testThreadStateIgnoresOtherTransfers() {
        let other = "9c14e2c6-1f6a-4a6a-9f7e-6a1e2b3c4d5e"
        let messages = [
            message(descriptor().encoded, isOutgoing: true),
            message(
                KitPaymentMessage(
                    action: .rejected,
                    paymentRequestId: other,
                    amountMinor: 1,
                    currencyCode: "UGX",
                    currencyScale: 2,
                    note: nil
                )!.encoded,
                isOutgoing: false
            ),
        ]
        XCTAssertNil(
            KitTransferThreadStatePolicy.latestLocalOutcome(
                forTransferID: "00000000-0000-0000-0000-000000000009",
                transferIsOutgoing: true,
                messages: messages
            )
        )
    }

    func testThreadStateMatchesTransferReferencesCaseInsensitively() {
        XCTAssertEqual(
            KitTransferThreadStatePolicy.latestLocalOutcome(
                forTransferID: transferID.uppercased(),
                transferIsOutgoing: true,
                messages: [message(descriptor(action: .accepted).encoded, isOutgoing: false)]
            ),
            .accepted
        )
    }
}
