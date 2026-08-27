import XCTest
@testable import KitPay

final class MessageEditTests: XCTestCase {
    private let target = "40000000-0000-0000-0000-000000000001"
    private let otherTarget = "40000000-0000-0000-0000-000000000002"
    private let conversation = "30000000-0000-0000-0000-000000000001"
    private let userA = "10000000-0000-0000-0000-00000000000a"
    private let userB = "10000000-0000-0000-0000-00000000000b"

    // MARK: - Capability

    func testEditCapabilityIsFailClosed() {
        XCTAssertFalse(MessagingMessageEditCapabilityPolicy.isEnabled(features: nil))
        XCTAssertFalse(MessagingMessageEditCapabilityPolicy.isEnabled(features: [:]))
        XCTAssertFalse(MessagingMessageEditCapabilityPolicy.isEnabled(features: [
            MessagingMessageEditCapabilityPolicy.featureKey: false,
        ]))
        XCTAssertFalse(MessagingMessageEditCapabilityPolicy.isEnabled(features: [
            MessagingMessageEditCapabilityPolicy.featureKey: nil,
        ]))
        XCTAssertTrue(MessagingMessageEditCapabilityPolicy.isEnabled(features: [
            MessagingMessageEditCapabilityPolicy.featureKey: true,
        ]))
    }

    // MARK: - The wire descriptor

    func testEditRoundTripsItsTargetAndItsWording() throws {
        let edit = try XCTUnwrap(
            KitMessageEdit(targetServerMessageID: target, body: "See you at eight")
        )

        XCTAssertEqual(edit.encoded, "KITEDIT1:v=1&t=\(target)&b=See you at eight")
        XCTAssertTrue(KitMessageEdit.isEditText(edit.encoded))
        XCTAssertEqual(KitMessageEdit.parse(edit.encoded), edit)
    }

    func testWordingIsCarriedVerbatimSeparatorsAndAll() throws {
        // The body is the last field and is not encoded, so punctuation that happens to look like
        // a field separator costs nothing and survives exactly as it was typed.
        let body = "Send R&D the invoice: total=200&VAT=36"
        let edit = try XCTUnwrap(KitMessageEdit(targetServerMessageID: target, body: body))

        XCTAssertEqual(KitMessageEdit.parse(edit.encoded)?.body, body)
    }

    func testEditDescriptorHasExactlyOneSpelling() {
        // A target whose hex actually contains letters, so uppercasing it is a real change.
        // `target` is digits and dashes only, and uppercasing that spells the canonical
        // descriptor rather than a rejected one.
        let hexTarget = "4a0bc0de-0f0a-4b0c-8d0e-00000000abcd"
        XCTAssertNotNil(KitMessageEdit.parse("KITEDIT1:v=1&t=\(hexTarget)&b=Hi"))

        // Anything that does not re-encode to itself is refused rather than interpreted, so a
        // later parser cannot find a second meaning in already-authenticated bytes.
        for malformed in [
            "KITEDIT1:v=1&t=\(target)",
            "KITEDIT1:v=2&t=\(target)&b=Hello",
            "KITEDIT1:v=1&t=\(hexTarget.uppercased())&b=Hi",
            "KITEDIT1:v=1&t=not-a-uuid-at-all-not-a-uuid-at-all-x&b=Hi",
            "KITEDIT1:v=1&t=\(target)&x=Hello",
            "KITEDIT1:v=1&t=\(target)&b=",
            "Meet me at KITEDIT1:v=1&t=\(target)&b=Hi",
            "See you at eight",
        ] {
            XCTAssertNil(KitMessageEdit.parse(malformed), malformed)
        }
    }

    func testCorrectionHasToBeSomethingTheComposerCouldHaveSent() {
        XCTAssertFalse(KitMessageEdit.isAcceptableBody(""))
        XCTAssertFalse(KitMessageEdit.isAcceptableBody("  padded  "))
        XCTAssertTrue(KitMessageEdit.isAcceptableBody("See you at eight"))
    }

    func testCorrectionCannotSmuggleInADescriptorTheComposerWouldRefuse() throws {
        // Otherwise editing a message would become a way to author a payment, a reaction or a
        // second edit — content the send path deliberately reserves to itself.
        let reaction = try XCTUnwrap(
            KitMessageReaction(operation: .add, targetServerMessageID: target, emoji: "👍")
        )
        let edit = try XCTUnwrap(
            KitMessageEdit(targetServerMessageID: target, body: "See you at eight")
        )
        for body in [reaction.encoded, edit.encoded, KitSystemMessage.prefix + "v=1"] {
            XCTAssertFalse(KitMessageEdit.isAcceptableBody(body), body)
            XCTAssertNil(KitMessageEdit(targetServerMessageID: target, body: body), body)
        }
    }

    func testCorrectionMayBeAsLongAsTheMessageItReplacesWas() throws {
        // The ceiling is on the whole descriptor, so the header and the target UUID come out of
        // the same allowance the wire gives ordinary text.
        let headerLength = "KITEDIT1:v=1&t=".utf16.count + 36 + "&b=".utf16.count
        let longest = String(
            repeating: "a",
            count: KitMessageEdit.maximumDescriptorLength - headerLength
        )

        XCTAssertTrue(KitMessageEdit.isAcceptableBody(longest))
        XCTAssertFalse(KitMessageEdit.isAcceptableBody(longest + "a"))
        let edit = try XCTUnwrap(KitMessageEdit(targetServerMessageID: target, body: longest))
        XCTAssertEqual(edit.encoded.utf16.count, KitMessageEdit.maximumDescriptorLength)
        XCTAssertEqual(KitMessageEdit.parse(edit.encoded)?.body, longest)
    }

    func testClientAndServerAgreeOnHowLongFifteenMinutesIs() {
        XCTAssertEqual(KitMessageEdit.editWindow, 15 * 60)
    }

    // MARK: - Wire binding

    func testEditPlaintextBindsToTheEncryptedEditKind() throws {
        let edit = try XCTUnwrap(
            KitMessageEdit(targetServerMessageID: target, body: "See you at eight")
        )

        XCTAssertEqual(
            SecureMessagingContentBindingPolicy.kind(
                for: edit.encoded,
                replyToMessageID: target,
                attachments: []
            ),
            .encryptedEdit
        )
        // The envelope pointer is authenticated metadata, not a second claim: it has to name the
        // very message the descriptor names, and a correction never carries attachments.
        XCTAssertNil(SecureMessagingContentBindingPolicy.kind(
            for: edit.encoded,
            replyToMessageID: otherTarget,
            attachments: []
        ))
        XCTAssertNil(SecureMessagingContentBindingPolicy.kind(
            for: edit.encoded,
            replyToMessageID: nil,
            attachments: []
        ))
        XCTAssertNil(SecureMessagingContentBindingPolicy.kind(
            for: "KITEDIT1:v=1&t=\(target)",
            replyToMessageID: target,
            attachments: []
        ))
    }

    func testComposerRefusesTheEditNamespace() throws {
        let edit = try XCTUnwrap(
            KitMessageEdit(targetServerMessageID: target, body: "See you at eight")
        )
        XCTAssertFalse(
            SecureMessageReservedPrefixPolicy.allowsUserAuthoredText(edit.encoded)
        )
    }

    func testEditKindIsTimelineMetadataAndRequiresItsPointer() {
        XCTAssertTrue(SecureMessagingMessageKind.encryptedEdit.isTimelineMetadata)
        XCTAssertTrue(SecureMessagingMessageKind.encryptedReaction.isTimelineMetadata)
        XCTAssertFalse(SecureMessagingMessageKind.encrypted.isTimelineMetadata)
        XCTAssertFalse(SecureMessagingMessageKind.encryptedAttachment.isTimelineMetadata)

        XCTAssertTrue(SecureMessagingContentBindingPolicy.validatesOuterEnvelope(
            kind: .encryptedEdit,
            replyToMessageID: target,
            attachmentCount: 0
        ))
        XCTAssertFalse(SecureMessagingContentBindingPolicy.validatesOuterEnvelope(
            kind: .encryptedEdit,
            replyToMessageID: nil,
            attachmentCount: 0
        ))
        XCTAssertFalse(SecureMessagingContentBindingPolicy.validatesOuterEnvelope(
            kind: .encryptedEdit,
            replyToMessageID: target,
            attachmentCount: 1
        ))
    }

    // MARK: - Folding the projection

    func testEditReplacesTheWordingOfItsOwnAuthorsMessage() throws {
        let original = message(
            body: "See you at seven",
            sender: userA,
            at: 0,
            serverMessageID: target
        )
        let correction = try editMessage("See you at eight", sender: userA, at: 10)

        let applied = MessageEditAggregationPolicy.appliedEdits(in: [original, correction])

        XCTAssertEqual(applied[target]?.body, "See you at eight")
        XCTAssertEqual(
            MessageEditAggregationPolicy.suppressedMessageIDs(in: [original, correction]),
            [correction.id]
        )
    }

    func testLastCorrectionWinsAndReplayDoesNotChangeThat() throws {
        let rows = [
            message(body: "See you at seven", sender: userA, at: 0, serverMessageID: target),
            try editMessage("See you at eight", sender: userA, at: 10),
            try editMessage("See you at nine", sender: userA, at: 20),
        ]

        let expected = MessageEditAggregationPolicy.appliedEdits(in: rows)
        XCTAssertEqual(expected[target]?.body, "See you at nine")
        XCTAssertEqual(MessageEditAggregationPolicy.appliedEdits(in: rows + rows), expected)
        XCTAssertEqual(MessageEditAggregationPolicy.appliedEdits(in: rows.reversed()), expected)
    }

    func testNobodyCanRewordSomebodyElsesMessage() throws {
        // Identity comes from the authenticated Signal sender of the carrying message, so a peer
        // cannot pass off a correction as the original author's second thought.
        let original = message(
            body: "See you at seven",
            sender: userA,
            at: 0,
            serverMessageID: target
        )
        let forged = try editMessage("Send me your PIN", sender: userB, at: 10)

        XCTAssertTrue(
            MessageEditAggregationPolicy.appliedEdits(in: [original, forged]).isEmpty
        )
        XCTAssertFalse(
            MessageEditAggregationPolicy.hasValidTarget(for: forged, among: [original, forged])
        )
        XCTAssertEqual(
            MessageEditAggregationPolicy.retainingValidEditTargets(
                [forged],
                among: [original, forged]
            ),
            []
        )
    }

    func testEditForAnUnknownMessageRewordsNothing() throws {
        // Paging or a partial sync can deliver a correction before its target authenticates here.
        let original = message(
            body: "See you at seven",
            sender: userA,
            at: 0,
            serverMessageID: target
        )
        let orphan = try editMessage(
            "See you at eight",
            sender: userA,
            at: 10,
            editTarget: otherTarget
        )

        XCTAssertTrue(
            MessageEditAggregationPolicy.appliedEdits(in: [original, orphan]).isEmpty
        )
        XCTAssertEqual(
            MessageEditAggregationPolicy.retainingValidEditTargets(
                [orphan],
                among: [original, orphan]
            ),
            []
        )
    }

    func testEditInAnotherConversationRewordsNothing() throws {
        let original = message(
            body: "See you at seven",
            sender: userA,
            at: 0,
            serverMessageID: target
        )
        let elsewhere = try editMessage(
            "See you at eight",
            sender: userA,
            at: 10,
            conversationID: "30000000-0000-0000-0000-000000000002"
        )

        XCTAssertTrue(
            MessageEditAggregationPolicy.appliedEdits(in: [original, elsewhere]).isEmpty
        )
    }

    func testPermanentlyFailedCorrectionNeverRewordsAnything() throws {
        let original = message(
            body: "See you at seven",
            sender: userA,
            at: 0,
            serverMessageID: target
        )
        var failed = try editMessage("See you at eight", sender: userA, at: 10)
        failed.state = .failed

        XCTAssertTrue(
            MessageEditAggregationPolicy.appliedEdits(in: [original, failed]).isEmpty
        )
    }

    func testReactionsAndEditsStayOutOfEachOthersWay() throws {
        // Neither is a bubble of its own, and neither is a thing the other can act on: an edit of
        // a reaction, or of an earlier edit, would be a correction with nothing to show for it.
        let original = message(
            body: "See you at seven",
            sender: userA,
            at: 0,
            serverMessageID: target
        )
        let reactionServerID = "40000000-0000-0000-0000-00000000000a"
        let reaction = try XCTUnwrap(
            KitMessageReaction(operation: .add, targetServerMessageID: target, emoji: "👍")
        )
        var reactionRow = message(
            body: reaction.encoded,
            sender: userA,
            at: 5,
            serverMessageID: reactionServerID
        )
        reactionRow.secureMessagingHistory = metadata(
            sender: userA,
            kind: .encryptedReaction,
            replyToMessageID: target,
            clientMessageID: reactionRow.id
        )
        let editServerID = "40000000-0000-0000-0000-00000000000b"
        let correction = try editMessage(
            "See you at eight",
            sender: userA,
            at: 10,
            serverMessageID: editServerID
        )
        let editOfReaction = try editMessage(
            "See you at nine",
            sender: userA,
            at: 15,
            editTarget: reactionServerID
        )
        let editOfEdit = try editMessage(
            "See you at ten",
            sender: userA,
            at: 20,
            editTarget: editServerID
        )
        let rows = [original, reactionRow, correction, editOfReaction, editOfEdit]

        let applied = MessageEditAggregationPolicy.appliedEdits(in: rows)
        XCTAssertEqual(Set(applied.keys), [target])
        XCTAssertEqual(applied[target]?.body, "See you at eight")
    }

    func testMediaCannotBeReworded() throws {
        // A photo is not wording. Replacing its descriptor with a sentence would strand the media
        // its recipients have already downloaded.
        var media = message(
            body: try mediaDescriptorBody(),
            sender: userA,
            at: 0,
            serverMessageID: target
        )
        media.secureMessagingHistory = metadata(
            sender: userA,
            kind: .encryptedAttachment,
            replyToMessageID: nil,
            clientMessageID: media.id
        )
        let correction = try editMessage("See you at eight", sender: userA, at: 10)

        XCTAssertTrue(MessageEditAggregationPolicy.appliedEdits(in: [media, correction]).isEmpty)
        XCTAssertFalse(MessageEditAggregationPolicy.canEdit(
            outgoing(media),
            now: Date(timeIntervalSince1970: 1_700_000_060)
        ))
    }

    // MARK: - What the composer offers

    func testOnlyASettledMessageOfOnesOwnIsStillEditable() {
        let sentAt = Date(timeIntervalSince1970: 1_700_000_000)
        let editable = outgoing(
            message(
                body: "See you at seven",
                sender: userA,
                at: 0,
                state: .read,
                serverMessageID: target,
                sentAt: sentAt
            )
        )

        XCTAssertTrue(MessageEditAggregationPolicy.canEdit(editable, now: sentAt))

        var incoming = editable
        incoming.isOutgoing = false
        XCTAssertFalse(MessageEditAggregationPolicy.canEdit(incoming, now: sentAt))

        // A send still on its way is identified by its client id, which the server id replaces on
        // acknowledgement — a correction pinned to it in between would be stranded.
        let everyState: [MessageDeliveryState] = [
            .queued, .encrypting, .sending, .sent, .delivered, .read, .failed, .received,
        ]
        for state in everyState {
            var candidate = editable
            candidate.state = state
            XCTAssertEqual(
                MessageEditAggregationPolicy.canEdit(candidate, now: sentAt),
                [.sent, .delivered, .read].contains(state),
                "\(state)"
            )
        }

        var unacknowledged = editable
        unacknowledged.serverMessageId = nil
        XCTAssertFalse(MessageEditAggregationPolicy.canEdit(unacknowledged, now: sentAt))
    }

    func testWindowClosesFifteenMinutesAfterTheMessageWasSent() {
        let sentAt = Date(timeIntervalSince1970: 1_700_000_000)
        let editable = outgoing(
            message(
                body: "See you at seven",
                sender: userA,
                at: 0,
                state: .sent,
                serverMessageID: target,
                sentAt: sentAt
            )
        )

        XCTAssertEqual(
            MessageEditAggregationPolicy.editWindowRemaining(for: editable, now: sentAt),
            KitMessageEdit.editWindow
        )
        XCTAssertTrue(MessageEditAggregationPolicy.canEdit(
            editable,
            now: sentAt.addingTimeInterval(KitMessageEdit.editWindow - 1)
        ))
        XCTAssertFalse(MessageEditAggregationPolicy.canEdit(
            editable,
            now: sentAt.addingTimeInterval(KitMessageEdit.editWindow)
        ))
        XCTAssertEqual(
            MessageEditAggregationPolicy.editWindowRemaining(
                for: editable,
                now: sentAt.addingTimeInterval(KitMessageEdit.editWindow)
            ),
            0
        )

        // A message with no send time of its own has no window to be inside of.
        var undated = editable
        undated.sentAt = nil
        XCTAssertFalse(MessageEditAggregationPolicy.canEdit(undated, now: sentAt))
    }

    func testACorrectionIsNeverItselfARepliableOrEditableBubble() throws {
        let correction = try editMessage("See you at eight", sender: userA, at: 10)

        XCTAssertFalse(MessageReplyQuotePolicy.canReply(to: correction))
        XCTAssertNil(MessageReplyQuotePolicy.targetServerMessageID(of: correction))
        XCTAssertFalse(MessageEditAggregationPolicy.canEdit(
            outgoing(correction),
            now: Date(timeIntervalSince1970: 1_700_000_060)
        ))
    }

    // MARK: - Locally queued corrections

    func testAQueuedOutgoingCorrectionIsRecognisedBeforeTheServerAnswers() throws {
        // The one metadata-free carve-out: this device authored the row, so its own outbox is the
        // authority until an acknowledgement arrives.
        let edit = try XCTUnwrap(
            KitMessageEdit(targetServerMessageID: target, body: "See you at eight")
        )
        var queued = message(body: edit.encoded, sender: userA, at: 10)
        queued.isOutgoing = true
        queued.state = .queued
        // Nothing has been acknowledged yet, so there is neither a server id nor a send time.
        queued.sentAt = nil

        XCTAssertEqual(MessageEditAggregationPolicy.authenticatedEdit(in: queued), edit)

        // An inbound row claiming the same thing without authenticated metadata is not one.
        var forged = queued
        forged.isOutgoing = false
        XCTAssertNil(MessageEditAggregationPolicy.authenticatedEdit(in: forged))

        // Nor is an outgoing row the server has already named: from then on the metadata decides.
        var acknowledged = queued
        acknowledged.serverMessageId = otherTarget
        XCTAssertNil(MessageEditAggregationPolicy.authenticatedEdit(in: acknowledged))
    }

    func testAuthenticatedMetadataMustBindTheSameTargetAndSender() throws {
        let correction = try editMessage("See you at eight", sender: userA, at: 10)
        XCTAssertNotNil(MessageEditAggregationPolicy.authenticatedEdit(in: correction))

        var mismatchedPointer = correction
        mismatchedPointer.secureMessagingHistory = metadata(
            sender: userA,
            kind: .encryptedEdit,
            replyToMessageID: otherTarget,
            clientMessageID: correction.id
        )
        XCTAssertNil(MessageEditAggregationPolicy.authenticatedEdit(in: mismatchedPointer))

        var mismatchedSender = correction
        mismatchedSender.secureMessagingHistory = metadata(
            sender: userB,
            kind: .encryptedEdit,
            replyToMessageID: target,
            clientMessageID: correction.id
        )
        XCTAssertNil(MessageEditAggregationPolicy.authenticatedEdit(in: mismatchedSender))

        var mismatchedKind = correction
        mismatchedKind.secureMessagingHistory = metadata(
            sender: userA,
            kind: .encrypted,
            replyToMessageID: target,
            clientMessageID: correction.id
        )
        XCTAssertNil(MessageEditAggregationPolicy.authenticatedEdit(in: mismatchedKind))
    }

    // MARK: - Helpers

    private func mediaDescriptorBody() throws -> String {
        try KitMediaMessageDescriptor(
            attachmentID: "50000000-0000-4000-8000-000000000001",
            storageKey: "50000000-0000-4000-8000-000000000002",
            mediaType: "image/jpeg",
            ciphertextByteSize: 4_096,
            ciphertextSHA256: String(repeating: "a", count: 64),
            keyMaterial: Data(
                repeating: 7,
                count: SecureMediaAttachmentCipher.keyMaterialBytes
            ),
            plaintextByteSize: 4_000,
            caption: "A photo"
        ).encoded
    }

    private func outgoing(_ message: LocalMessage) -> LocalMessage {
        var result = message
        result.isOutgoing = true
        return result
    }

    private func metadata(
        sender: String,
        kind: SecureMessagingMessageKind,
        replyToMessageID: String?,
        clientMessageID: UUID
    ) -> SecureMessagingRetainedMessageMetadata {
        SecureMessagingRetainedMessageMetadata(
            clientMessageID: clientMessageID.uuidString.lowercased(),
            senderUserID: sender,
            senderDeviceID: "20000000-0000-4000-8000-000000000001",
            senderEnrollmentEpoch: 1,
            senderSignalDeviceID: 1,
            rosterRevision: "v1:sha256:" + String(repeating: "a", count: 64),
            kind: kind,
            replyToMessageID: replyToMessageID
        )
    }

    private func editMessage(
        _ body: String,
        sender: String,
        at seconds: TimeInterval,
        editTarget: String? = nil,
        serverMessageID: String? = nil,
        conversationID: String? = nil,
        id: UUID = UUID()
    ) throws -> LocalMessage {
        let pointer = editTarget ?? target
        let descriptor = try XCTUnwrap(
            KitMessageEdit(targetServerMessageID: pointer, body: body)
        )
        var result = message(
            body: descriptor.encoded,
            sender: sender,
            at: seconds,
            id: id,
            serverMessageID: serverMessageID ?? id.uuidString.lowercased(),
            sentAt: Date(timeIntervalSince1970: 1_700_000_000 + seconds),
            conversationID: conversationID ?? conversation
        )
        result.secureMessagingHistory = metadata(
            sender: sender,
            kind: .encryptedEdit,
            replyToMessageID: pointer,
            clientMessageID: id
        )
        return result
    }

    private func message(
        body: String,
        sender: String,
        at seconds: TimeInterval,
        state: MessageDeliveryState = .sent,
        id: UUID = UUID(),
        serverMessageID: String? = nil,
        sentAt: Date? = nil,
        conversationID: String? = nil
    ) -> LocalMessage {
        LocalMessage(
            id: id,
            serverMessageId: serverMessageID,
            conversationId: conversationID ?? conversation,
            senderId: sender,
            body: body,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000 + seconds),
            sentAt: sentAt ?? Date(timeIntervalSince1970: 1_700_000_000 + seconds),
            state: state,
            failureReason: nil,
            isOutgoing: false,
            attachmentData: nil,
            pendingAttachment: nil
        )
    }
}
