import Foundation
import XCTest
@testable import KitPay

final class AbuseReportingContractTests: XCTestCase {
    private let currentUserID = "10000000-0000-4000-8000-000000000001"
    private let reportedUserID = "20000000-0000-4000-8000-000000000001"
    private let conversationID = "30000000-0000-4000-8000-000000000001"
    private let messageID = "40000000-0000-4000-8000-000000000001"
    private let reportID = "50000000-0000-4000-8000-000000000001"

    func testCapabilityFailsClosedForMissingFalseAndNullValues() {
        XCTAssertTrue(
            AbuseReportContract.isAvailable(features: ["abuse_reporting": true])
        )
        XCTAssertFalse(
            AbuseReportContract.isAvailable(features: ["abuse_reporting": false])
        )
        XCTAssertFalse(
            AbuseReportContract.isAvailable(features: ["abuse_reporting": nil])
        )
        XCTAssertFalse(AbuseReportContract.isAvailable(features: [:]))
        XCTAssertFalse(AbuseReportContract.isAvailable(features: nil))
    }

    func testReasonCodesExactlyMatchBackendContract() {
        XCTAssertEqual(
            AbuseReportReason.allCases.map(\.rawValue),
            [
                "spam",
                "scam_or_fraud",
                "harassment_or_bullying",
                "hate_speech",
                "credible_threat",
                "sexual_content",
                "child_safety",
                "self_harm",
                "impersonation",
                "illegal_activity",
                "privacy_violation",
                "other",
            ]
        )
    }

    func testContextRequiresCanonicalConversationMembership() throws {
        let valid = try XCTUnwrap(context())
        XCTAssertEqual(valid.reportedUserID, reportedUserID)
        XCTAssertEqual(valid.conversationID, conversationID)

        XCTAssertNil(
            AbuseReportContext(
                currentUserID: currentUserID,
                reportedUserID: currentUserID,
                conversation: conversation()
            )
        )
        XCTAssertNil(
            AbuseReportContext(
                currentUserID: currentUserID,
                reportedUserID: reportedUserID,
                conversation: conversation(participants: [currentUserID, reportedUserID, reportID])
            )
        )

        let group = try XCTUnwrap(
            AbuseReportContext(
                currentUserID: currentUserID,
                reportedUserID: reportedUserID,
                conversation: conversation(
                    participants: [currentUserID, reportedUserID, reportID],
                    type: "group"
                )
            )
        )
        XCTAssertEqual(group.reportedUserID, reportedUserID)
        XCTAssertEqual(group.conversationID, conversationID)

        XCTAssertNil(
            AbuseReportContext(
                currentUserID: currentUserID,
                reportedUserID: reportedUserID,
                conversation: conversation(
                    participants: [currentUserID, reportID],
                    type: "group"
                )
            )
        )
        XCTAssertNil(
            AbuseReportContext(
                currentUserID: currentUserID,
                reportedUserID: reportedUserID,
                conversation: conversation(
                    participants: [currentUserID, reportedUserID, reportedUserID],
                    type: "group"
                )
            )
        )
        XCTAssertNil(
            AbuseReportContext(
                currentUserID: currentUserID,
                reportedUserID: reportedUserID,
                conversation: conversation(participants: [currentUserID, "not-a-uuid"])
            )
        )
    }

    func testRequestEncodesOnlyExplicitBackendFieldsAndConsent() throws {
        let selected = try AbuseReportSelectedMessage(
            messageID: messageID.uppercased(),
            plaintext: "Exact selected plaintext & context"
        )
        let request = try CreateAbuseReportRequest(
            context: XCTUnwrap(context()),
            target: .message(messageID),
            reason: .harassmentOrBullying,
            reporterNote: "  Please review this message.  ",
            selectedMessages: [selected],
            shareSelectedMessagePlaintext: true
        )
        let object = try jsonObject(request)

        XCTAssertEqual(
            Set(object.keys),
            [
                "target_type",
                "reported_user_id",
                "conversation_id",
                "message_id",
                "reason_code",
                "reporter_note",
                "selected_messages",
                "consent",
            ]
        )
        XCTAssertEqual(object["target_type"] as? String, "message")
        XCTAssertEqual(object["reported_user_id"] as? String, reportedUserID)
        XCTAssertEqual(object["conversation_id"] as? String, conversationID)
        XCTAssertEqual(object["message_id"] as? String, messageID)
        XCTAssertEqual(object["reason_code"] as? String, "harassment_or_bullying")
        XCTAssertEqual(object["reporter_note"] as? String, "Please review this message.")

        let selectedObject = try XCTUnwrap(
            (object["selected_messages"] as? [[String: Any]])?.first
        )
        XCTAssertEqual(Set(selectedObject.keys), ["message_id", "plaintext"])
        XCTAssertEqual(selectedObject["message_id"] as? String, messageID)
        XCTAssertEqual(selectedObject["plaintext"] as? String, "Exact selected plaintext & context")

        let consent = try XCTUnwrap(object["consent"] as? [String: Any])
        XCTAssertEqual(
            Set(consent.keys),
            ["share_report_with_moderators", "share_selected_message_plaintext"]
        )
        XCTAssertEqual(consent["share_report_with_moderators"] as? Bool, true)
        XCTAssertEqual(consent["share_selected_message_plaintext"] as? Bool, true)
        XCTAssertNil(object["ciphertext"])
        XCTAssertNil(object["attachments"])
        XCTAssertNil(object["sender_id"])
        XCTAssertNil(object["device_id"])
    }

    func testRequestWithoutExplicitMessageSelectionSendsNoPlaintextArray() throws {
        let request = try CreateAbuseReportRequest(
            context: XCTUnwrap(context()),
            target: .account,
            reason: .spam,
            reporterNote: "   \n ",
            selectedMessages: [],
            shareSelectedMessagePlaintext: false
        )
        let object = try jsonObject(request)

        XCTAssertEqual(object["target_type"] as? String, "account")
        XCTAssertNil(object["message_id"])
        XCTAssertNil(object["reporter_note"])
        XCTAssertNil(object["selected_messages"])
        let consent = try XCTUnwrap(object["consent"] as? [String: Any])
        XCTAssertEqual(consent["share_report_with_moderators"] as? Bool, true)
        XCTAssertEqual(consent["share_selected_message_plaintext"] as? Bool, false)
    }

    func testMessageReportCanSendTargetReferenceWithoutPlaintext() throws {
        let request = try CreateAbuseReportRequest(
            context: XCTUnwrap(context()),
            target: .message(messageID),
            reason: .spam,
            reporterNote: nil,
            selectedMessages: [],
            shareSelectedMessagePlaintext: false
        )
        let object = try jsonObject(request)

        XCTAssertEqual(object["target_type"] as? String, "message")
        XCTAssertEqual(object["message_id"] as? String, messageID)
        XCTAssertNil(object["selected_messages"])
        let consent = try XCTUnwrap(object["consent"] as? [String: Any])
        XCTAssertEqual(consent["share_selected_message_plaintext"] as? Bool, false)
    }

    func testRequestRequiresPlaintextConsentAndEnforcesAllBounds() throws {
        let selected = try AbuseReportSelectedMessage(
            messageID: messageID,
            plaintext: "selected"
        )
        XCTAssertThrowsError(
            try CreateAbuseReportRequest(
                context: XCTUnwrap(context()),
                target: .conversation,
                reason: .other,
                reporterNote: nil,
                selectedMessages: [selected],
                shareSelectedMessagePlaintext: false
            )
        )
        XCTAssertThrowsError(
            try CreateAbuseReportRequest(
                context: XCTUnwrap(context()),
                target: .conversation,
                reason: .other,
                reporterNote: nil,
                selectedMessages: [],
                shareSelectedMessagePlaintext: true
            )
        )
        XCTAssertThrowsError(
            try AbuseReportSelectedMessage(
                messageID: messageID,
                plaintext: String(repeating: "a", count: 4_001)
            )
        )
        XCTAssertThrowsError(
            try CreateAbuseReportRequest(
                context: XCTUnwrap(context()),
                target: .account,
                reason: .other,
                reporterNote: String(repeating: "a", count: 1_001),
                selectedMessages: [],
                shareSelectedMessagePlaintext: false
            )
        )
    }

    func testCandidatePolicyExcludesUnsendableAndSensitiveWireMessages() throws {
        let context = try XCTUnwrap(context())
        let eligible = localMessage(id: messageID, body: "User-visible text")
        let noServerID = localMessage(id: nil, body: "Local draft")
        let media = localMessage(
            id: "40000000-0000-4000-8000-000000000002",
            body: "KITMEDIA1:key-material-must-not-leak"
        )
        let payment = localMessage(
            id: "40000000-0000-4000-8000-000000000003",
            body: "  KITPAY1:payment-metadata-must-not-leak"
        )
        let failed = localMessage(
            id: "40000000-0000-4000-8000-000000000004",
            body: "Failed text",
            state: .failed
        )
        let otherConversation = localMessage(
            id: "40000000-0000-4000-8000-000000000005",
            body: "Other conversation",
            conversationID: reportID
        )
        var attachment = localMessage(
            id: "40000000-0000-4000-8000-000000000006",
            body: "Attachment caption"
        )
        attachment.attachmentData = Data([0x01])

        let candidates = AbuseReportMessageSelectionPolicy.candidates(
            from: [eligible, noServerID, media, payment, failed, otherConversation, attachment],
            context: context
        )

        XCTAssertEqual(candidates.map(\.id), [messageID])
        XCTAssertEqual(candidates.first?.plaintext, "User-visible text")
    }

    func testOldTargetMessageIsAlwaysFirstButNeverAutomaticallySelected() throws {
        let context = try XCTUnwrap(context())
        let messages = (0 ..< 60).map { index in
            localMessage(
                id: String(format: "40000000-0000-4000-8000-%012d", index + 1),
                body: "Exact message \(index)\nwith all plaintext",
                createdAt: Date(timeIntervalSince1970: Double(index))
            )
        }
        let targetID = try XCTUnwrap(messages.first?.serverMessageId)
        let candidates = AbuseReportMessageSelectionPolicy.candidates(
            from: messages,
            context: context,
            targetMessageID: targetID
        )

        XCTAssertEqual(candidates.count, AbuseReportContract.maximumPresentedMessages)
        XCTAssertEqual(candidates.first?.id, targetID)
        XCTAssertEqual(candidates.first?.isReportTarget, true)
        XCTAssertEqual(candidates.first?.plaintext, "Exact message 0\nwith all plaintext")
        XCTAssertEqual(
            try AbuseReportMessageSelectionPolicy.payloads(
                selectedIDs: [],
                candidates: candidates
            ),
            []
        )
    }

    func testIneligibleTargetRemainsReferenceOnlyAndIsNeverAPlaintextCandidate() throws {
        let context = try XCTUnwrap(context())
        let targetID = "40000000-0000-4000-8000-000000000099"
        let payment = localMessage(id: targetID, body: "KITPAY1:private-wire-data")

        let candidates = AbuseReportMessageSelectionPolicy.candidates(
            from: [payment],
            context: context,
            targetMessageID: targetID
        )

        XCTAssertTrue(candidates.isEmpty)
    }

    func testSelectionRequiresKnownCandidatesAndHonorsCountAndByteCaps() throws {
        let candidates = try (0 ..< 6).map { index in
            try candidate(
                id: String(format: "40000000-0000-4000-8000-%012d", index + 1),
                plaintext: "message \(index)"
            )
        }
        let five = Set(candidates.prefix(5).map(\.id))
        XCTAssertFalse(
            AbuseReportMessageSelectionPolicy.canSelect(
                candidates[5],
                selectedIDs: five,
                candidates: candidates
            )
        )
        XCTAssertEqual(
            try AbuseReportMessageSelectionPolicy.payloads(
                selectedIDs: five,
                candidates: candidates
            ).count,
            5
        )
        XCTAssertThrowsError(
            try AbuseReportMessageSelectionPolicy.payloads(
                selectedIDs: [reportID],
                candidates: candidates
            )
        )

        let first = try candidate(
            id: "60000000-0000-4000-8000-000000000001",
            plaintext: String(repeating: "a", count: 3_500)
        )
        let second = try candidate(
            id: "60000000-0000-4000-8000-000000000002",
            plaintext: String(repeating: "🙂", count: 2_200)
        )
        XCTAssertFalse(
            AbuseReportMessageSelectionPolicy.canSelect(
                second,
                selectedIDs: [first.id],
                candidates: [first, second]
            )
        )
    }

    func testMessageTargetRequiresIncomingMessageFromReportedPeer() throws {
        let context = try XCTUnwrap(context())
        let incoming = localMessage(id: messageID, body: "Incoming")
        XCTAssertEqual(
            AbuseReportTarget.message(incoming, context: context),
            .message(messageID)
        )

        var outgoing = incoming
        outgoing.isOutgoing = true
        XCTAssertNil(AbuseReportTarget.message(outgoing, context: context))

        let otherSender = localMessage(id: messageID, body: "Wrong sender", senderID: reportID)
        XCTAssertNil(AbuseReportTarget.message(otherSender, context: context))
    }

    func testGroupReportBindsToSelectedSenderAndExcludesOtherMembersPlaintext() throws {
        let context = try XCTUnwrap(
            AbuseReportContext(
                currentUserID: currentUserID,
                reportedUserID: reportedUserID,
                conversation: conversation(
                    participants: [currentUserID, reportedUserID, reportID],
                    type: "group"
                )
            )
        )
        let target = localMessage(id: messageID, body: "Reported group message")
        let otherMember = localMessage(
            id: "40000000-0000-4000-8000-000000000002",
            body: "Another member's private context",
            senderID: reportID
        )

        XCTAssertEqual(AbuseReportTarget.message(target, context: context), .message(messageID))
        XCTAssertNil(AbuseReportTarget.message(otherMember, context: context))
        XCTAssertEqual(
            AbuseReportMessageSelectionPolicy.candidates(
                from: [target, otherMember],
                context: context,
                targetMessageID: messageID
            ).map(\.id),
            [messageID]
        )
    }

    func testReceiptStrictlyValidatesShapeAndConfirmsRequest() throws {
        let request = try CreateAbuseReportRequest(
            context: XCTUnwrap(context()),
            target: .message(messageID),
            reason: .privacyViolation,
            reporterNote: nil,
            selectedMessages: [],
            shareSelectedMessagePlaintext: false
        )
        let receipt = try decodeReceipt(receiptObject(
            targetType: "message",
            reasonCode: "privacy_violation",
            messageID: messageID,
            selectedMessageCount: 0
        ))
        XCTAssertTrue(receipt.confirms(request))

        var unknown = receiptObject()
        unknown["reporter_note"] = "must never be returned"
        XCTAssertThrowsError(try decodeReceipt(unknown))

        var invalidStatus = receiptObject()
        invalidStatus["status"] = "open"
        XCTAssertThrowsError(try decodeReceipt(invalidStatus))

        var missingMessage = receiptObject(targetType: "message")
        missingMessage["message_id"] = NSNull()
        XCTAssertThrowsError(try decodeReceipt(missingMessage))

        var invalidCount = receiptObject()
        invalidCount["selected_message_count"] = 6
        XCTAssertThrowsError(try decodeReceipt(invalidCount))
    }

    func testEndpointAndIdempotencyKeysMatchBackendContract() {
        XCTAssertEqual(AbuseReportAPIEndpoint.path, "communications/reports")
        let generated = AbuseReportContract.makeIdempotencyKey()
        XCTAssertTrue(AbuseReportContract.validIdempotencyKey(generated))
        XCTAssertFalse(AbuseReportContract.validIdempotencyKey("short"))
        XCTAssertFalse(
            AbuseReportContract.validIdempotencyKey("invalid key with spaces")
        )
    }

    func testRetryFingerprintIsDeterministicAndBindsEveryRequestField() throws {
        let selected = try AbuseReportSelectedMessage(
            messageID: messageID,
            plaintext: "Exact multiline plaintext\nwith emoji 🙂 and trailing space "
        )
        let request = try CreateAbuseReportRequest(
            context: XCTUnwrap(context()),
            target: .message(messageID),
            reason: .harassmentOrBullying,
            reporterNote: "Moderator note",
            selectedMessages: [selected],
            shareSelectedMessagePlaintext: true
        )
        let sameRequest = try CreateAbuseReportRequest(
            context: XCTUnwrap(context()),
            target: .message(messageID.uppercased()),
            reason: .harassmentOrBullying,
            reporterNote: "Moderator note",
            selectedMessages: [selected],
            shareSelectedMessagePlaintext: true
        )
        let changedRequest = try CreateAbuseReportRequest(
            context: XCTUnwrap(context()),
            target: .message(messageID),
            reason: .harassmentOrBullying,
            reporterNote: "Different note",
            selectedMessages: [selected],
            shareSelectedMessagePlaintext: true
        )

        let fingerprint = try request.retryFingerprint()
        XCTAssertTrue(AbuseReportContract.validRequestFingerprint(fingerprint))
        XCTAssertEqual(fingerprint, try sameRequest.retryFingerprint())
        XCTAssertNotEqual(fingerprint, try changedRequest.retryFingerprint())
    }

    func testAttemptStorePersistsNoPlaintextAndScopesRetriesByRequestAndAccount() async throws {
        let secretPlaintext = "never persist this selected plaintext"
        let secretNote = "never persist this moderator note"
        let selected = try AbuseReportSelectedMessage(
            messageID: messageID,
            plaintext: secretPlaintext
        )
        let request = try CreateAbuseReportRequest(
            context: XCTUnwrap(context()),
            target: .message(messageID),
            reason: .privacyViolation,
            reporterNote: secretNote,
            selectedMessages: [selected],
            shareSelectedMessagePlaintext: true
        )
        let changed = try CreateAbuseReportRequest(
            context: XCTUnwrap(context()),
            target: .message(messageID),
            reason: .privacyViolation,
            reporterNote: "A different note",
            selectedMessages: [selected],
            shareSelectedMessagePlaintext: true
        )
        let otherAccount = "10000000-0000-4000-8000-000000000002"
        let memory = AbuseReportAttemptMemory()

        let first = try await attemptStore(memory: memory).attempt(
            for: request,
            accountID: currentUserID
        )
        let restored = try await attemptStore(memory: memory).attempt(
            for: request,
            accountID: currentUserID
        )
        let differentRequest = try await attemptStore(memory: memory).attempt(
            for: changed,
            accountID: currentUserID
        )
        let differentAccount = try await attemptStore(memory: memory).attempt(
            for: request,
            accountID: otherAccount
        )

        XCTAssertEqual(restored, first)
        XCTAssertNotEqual(differentRequest.idempotencyKey, first.idempotencyKey)
        XCTAssertNotEqual(differentAccount.idempotencyKey, first.idempotencyKey)
        XCTAssertEqual(memory.count, 3)
        for account in memory.allAccounts {
            XCTAssertFalse(account.contains(secretPlaintext))
            XCTAssertFalse(account.contains(secretNote))
        }
        for data in memory.allData {
            let persisted = try XCTUnwrap(String(data: data, encoding: .utf8))
            XCTAssertFalse(persisted.contains(secretPlaintext))
            XCTAssertFalse(persisted.contains(secretNote))
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            XCTAssertEqual(
                Set(object.keys),
                ["version", "account_id", "request_fingerprint", "idempotency_key"]
            )
        }
    }

    @MainActor
    func testAttemptPersistenceFailureAndCorruptionFailClosedBeforeNetwork() async throws {
        let request = try CreateAbuseReportRequest(
            context: XCTUnwrap(context()),
            target: .account,
            reason: .spam,
            reporterNote: nil,
            selectedMessages: [],
            shareSelectedMessagePlaintext: false
        )
        let receipt = try decodeReceipt(receiptObject())

        let discardedMemory = AbuseReportAttemptMemory()
        discardedMemory.discardWrites = true
        let discardedProbe = AbuseReportSubmitterProbe(receipt: receipt, failFirstAttempt: false)
        let discardedFlow = AbuseReportViewModel(
            submitter: { request, key in
                try await discardedProbe.submit(request, key: key)
            },
            attemptStore: attemptStore(memory: discardedMemory)
        )
        let discardedResult = await discardedFlow.submit(
            request,
            reporterAccountID: currentUserID,
            reportingAvailable: true,
            isOnline: true
        )
        let discardedKeys = await discardedProbe.keys()
        XCTAssertFalse(discardedResult)
        XCTAssertTrue(discardedKeys.isEmpty)

        let corruptMemory = AbuseReportAttemptMemory()
        let fingerprint = try request.retryFingerprint()
        let account = AbuseReportAttemptStore.storageAccount(
            accountID: currentUserID,
            requestFingerprint: fingerprint
        )
        corruptMemory.seed(Data("contains plaintext instead of a marker".utf8), for: account)
        let corruptProbe = AbuseReportSubmitterProbe(receipt: receipt, failFirstAttempt: false)
        let corruptFlow = AbuseReportViewModel(
            submitter: { request, key in
                try await corruptProbe.submit(request, key: key)
            },
            attemptStore: attemptStore(memory: corruptMemory)
        )
        let corruptResult = await corruptFlow.submit(
            request,
            reporterAccountID: currentUserID,
            reportingAvailable: true,
            isOnline: true
        )
        let corruptKeys = await corruptProbe.keys()
        XCTAssertFalse(corruptResult)
        XCTAssertTrue(corruptKeys.isEmpty)
        XCTAssertEqual(corruptMemory.load(account), Data("contains plaintext instead of a marker".utf8))
    }

    @MainActor
    func testUnconfirmedOrInvalidReceiptNeverClearsRetryAuthority() async throws {
        let request = try CreateAbuseReportRequest(
            context: XCTUnwrap(context()),
            target: .account,
            reason: .spam,
            reporterNote: nil,
            selectedMessages: [],
            shareSelectedMessagePlaintext: false
        )
        let mismatchedReceipt = try decodeReceipt(receiptObject(reasonCode: "other"))
        let memory = AbuseReportAttemptMemory()
        let flow = AbuseReportViewModel(
            submitter: { _, _ in mismatchedReceipt },
            attemptStore: attemptStore(memory: memory)
        )

        let result = await flow.submit(
            request,
            reporterAccountID: currentUserID,
            reportingAvailable: true,
            isOnline: true
        )
        XCTAssertFalse(result)
        XCTAssertNil(flow.receipt)
        XCTAssertEqual(memory.count, 1)
        XCTAssertEqual(memory.removeCount, 0)
    }

    @MainActor
    func testConfirmedReceiptRemainsDefinitiveWhenAttemptRemovalCannotBeVerified() async throws {
        let request = try CreateAbuseReportRequest(
            context: XCTUnwrap(context()),
            target: .account,
            reason: .spam,
            reporterNote: nil,
            selectedMessages: [],
            shareSelectedMessagePlaintext: false
        )
        let receipt = try decodeReceipt(receiptObject())
        let memory = AbuseReportAttemptMemory()
        memory.retainOnRemove = true
        let probe = AbuseReportSubmitterProbe(receipt: receipt, failFirstAttempt: false)
        let flow = AbuseReportViewModel(
            submitter: { request, key in
                try await probe.submit(request, key: key)
            },
            attemptStore: attemptStore(memory: memory)
        )

        let result = await flow.submit(
            request,
            reporterAccountID: currentUserID,
            reportingAvailable: true,
            isOnline: true
        )

        XCTAssertTrue(result)
        XCTAssertEqual(flow.receipt, receipt)
        XCTAssertEqual(memory.count, 1)
        XCTAssertEqual(memory.removeCount, 1)
        let submittedKeys = await probe.keys()
        XCTAssertEqual(submittedKeys.count, 1)
    }

    func testErrorCopyNeverEchoesSensitiveServerMessages() {
        let targetError = APIErrorPayload(
            code: "REPORT_TARGET_UNAVAILABLE",
            message: "User 123 and message 456 do not match.",
            httpStatus: 404
        )
        XCTAssertEqual(
            AbuseReportErrorCopy.message(for: targetError),
            "This account or conversation is no longer available to report."
        )
        XCTAssertFalse(
            AbuseReportErrorCopy.message(for: targetError).contains("123")
        )

        let rateError = APIErrorPayload(
            code: "RATE_LIMIT_EXCEEDED",
            message: "Internal limiter key",
            httpStatus: 429
        )
        XCTAssertEqual(
            AbuseReportErrorCopy.message(for: rateError),
            "Too many reports were submitted. Please wait a moment and try again."
        )
    }

    @MainActor
    func testSubmissionRetriesIdenticalPayloadWithSameIdempotencyKey() async throws {
        let request = try CreateAbuseReportRequest(
            context: XCTUnwrap(context()),
            target: .account,
            reason: .spam,
            reporterNote: nil,
            selectedMessages: [],
            shareSelectedMessagePlaintext: false
        )
        let receipt = try decodeReceipt(receiptObject())
        let memory = AbuseReportAttemptMemory()
        let firstStore = attemptStore(memory: memory)
        let probe = AbuseReportSubmitterProbe(receipt: receipt, failFirstAttempt: true)
        let firstFlow = AbuseReportViewModel(
            submitter: { request, key in
                try await probe.submit(request, key: key)
            },
            attemptStore: firstStore
        )

        let firstResult = await firstFlow.submit(
            request,
            reporterAccountID: currentUserID,
            reportingAvailable: true,
            isOnline: true
        )
        XCTAssertEqual(memory.count, 1)

        // A new store and view model simulate dismissing the sheet and relaunching the app.
        let secondFlow = AbuseReportViewModel(
            submitter: { request, key in
                try await probe.submit(request, key: key)
            },
            attemptStore: attemptStore(memory: memory)
        )
        let secondResult = await secondFlow.submit(
            request,
            reporterAccountID: currentUserID,
            reportingAvailable: true,
            isOnline: true
        )
        XCTAssertFalse(firstResult)
        XCTAssertTrue(secondResult)
        let keys = await probe.keys()
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(keys[0], keys[1])
        XCTAssertEqual(secondFlow.receipt, receipt)
        XCTAssertEqual(memory.count, 0)
    }

    @MainActor
    func testSubmissionFailsClosedBeforeCallingNetwork() async throws {
        let request = try CreateAbuseReportRequest(
            context: XCTUnwrap(context()),
            target: .account,
            reason: .spam,
            reporterNote: nil,
            selectedMessages: [],
            shareSelectedMessagePlaintext: false
        )
        let receipt = try decodeReceipt(receiptObject())
        let memory = AbuseReportAttemptMemory()
        let probe = AbuseReportSubmitterProbe(receipt: receipt, failFirstAttempt: false)
        let flow = AbuseReportViewModel(
            submitter: { request, key in
                try await probe.submit(request, key: key)
            },
            attemptStore: attemptStore(memory: memory)
        )

        let unavailableResult = await flow.submit(
            request,
            reporterAccountID: currentUserID,
            reportingAvailable: false,
            isOnline: true
        )
        let offlineResult = await flow.submit(
            request,
            reporterAccountID: currentUserID,
            reportingAvailable: true,
            isOnline: false
        )
        let keys = await probe.keys()
        XCTAssertFalse(unavailableResult)
        XCTAssertFalse(offlineResult)
        XCTAssertTrue(keys.isEmpty)
        XCTAssertEqual(memory.count, 0)
    }

    private func conversation(
        participants: [String]? = nil,
        type: String? = nil
    ) -> Conversation {
        Conversation(
            id: conversationID,
            title: "Amina",
            participantUserIds: participants ?? [currentUserID, reportedUserID],
            unreadCount: 0,
            updatedAt: Date(timeIntervalSince1970: 1_777_000_000),
            conversationType: type
        )
    }

    private func context() -> AbuseReportContext? {
        AbuseReportContext(
            currentUserID: currentUserID,
            reportedUserID: reportedUserID,
            conversation: conversation()
        )
    }

    private func localMessage(
        id: String?,
        body: String,
        conversationID: String? = nil,
        senderID: String? = nil,
        state: MessageDeliveryState = .received,
        createdAt: Date = Date(timeIntervalSince1970: 1_777_000_000)
    ) -> LocalMessage {
        LocalMessage(
            id: UUID(),
            serverMessageId: id,
            conversationId: conversationID ?? self.conversationID,
            senderId: senderID ?? reportedUserID,
            body: body,
            createdAt: createdAt,
            sentAt: createdAt,
            state: state,
            failureReason: nil,
            isOutgoing: false
        )
    }

    private func candidate(
        id: String,
        plaintext: String
    ) throws -> AbuseReportMessageCandidate {
        AbuseReportMessageCandidate(
            payload: try AbuseReportSelectedMessage(messageID: id, plaintext: plaintext),
            isOutgoing: false,
            createdAt: Date(timeIntervalSince1970: Double(String(id.suffix(1))) ?? 0)
        )
    }

    private func jsonObject<Value: Encodable>(_ value: Value) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func receiptObject(
        targetType: String = "account",
        reasonCode: String = "spam",
        messageID: String? = nil,
        selectedMessageCount: Int = 0
    ) -> [String: Any] {
        let encodedMessageID: Any = messageID.map { $0 as Any } ?? NSNull()
        return [
            "id": reportID,
            "status": "received",
            "target_type": targetType,
            "reason_code": reasonCode,
            "conversation_id": conversationID,
            "message_id": encodedMessageID,
            "selected_message_count": selectedMessageCount,
            "submitted_at": "2026-08-24T18:30:00.125Z",
        ]
    }

    private func decodeReceipt(_ object: [String: Any]) throws -> AbuseReportReceipt {
        try JSONDecoder().decode(
            AbuseReportReceipt.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    private func attemptStore(memory: AbuseReportAttemptMemory) -> AbuseReportAttemptStore {
        AbuseReportAttemptStore(
            load: { memory.load($0) },
            save: { try memory.save($0, for: $1) },
            remove: { try memory.remove($0) }
        )
    }
}

private actor AbuseReportSubmitterProbe {
    private let receipt: AbuseReportReceipt
    private let failFirstAttempt: Bool
    private var submittedKeys: [String] = []

    init(receipt: AbuseReportReceipt, failFirstAttempt: Bool) {
        self.receipt = receipt
        self.failFirstAttempt = failFirstAttempt
    }

    func submit(
        _ request: CreateAbuseReportRequest,
        key: String
    ) throws -> AbuseReportReceipt {
        submittedKeys.append(key)
        if failFirstAttempt, submittedKeys.count == 1 {
            throw APIClientError.httpResponse(status: 503, retryAfter: nil)
        }
        guard receipt.confirms(request) else { throw APIClientError.invalidResponse }
        return receipt
    }

    func keys() -> [String] { submittedKeys }
}

private final class AbuseReportAttemptMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: Data] = [:]
    private var shouldDiscardWrites = false
    private var shouldRetainOnRemove = false
    private var removals = 0

    var discardWrites: Bool {
        get { withLock { shouldDiscardWrites } }
        set { withLock { shouldDiscardWrites = newValue } }
    }

    var retainOnRemove: Bool {
        get { withLock { shouldRetainOnRemove } }
        set { withLock { shouldRetainOnRemove = newValue } }
    }

    var count: Int { withLock { records.count } }
    var removeCount: Int { withLock { removals } }
    var allAccounts: [String] { withLock { Array(records.keys) } }
    var allData: [Data] { withLock { Array(records.values) } }

    func load(_ account: String) -> Data? {
        withLock { records[account] }
    }

    func save(_ data: Data, for account: String) throws {
        withLock {
            guard !shouldDiscardWrites else { return }
            records[account] = data
        }
    }

    func remove(_ account: String) throws {
        withLock {
            removals += 1
            guard !shouldRetainOnRemove else { return }
            records.removeValue(forKey: account)
        }
    }

    func seed(_ data: Data, for account: String) {
        withLock { records[account] = data }
    }

    @discardableResult
    private func withLock<Value>(_ operation: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}
