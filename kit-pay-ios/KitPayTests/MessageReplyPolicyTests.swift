import XCTest
@testable import KitPay

final class MessageReplyPolicyTests: XCTestCase {
    private let conversation = "30000000-0000-0000-0000-000000000001"
    private let otherConversation = "30000000-0000-0000-0000-000000000002"
    private let me = "10000000-0000-0000-0000-000000000001"
    private let them = "10000000-0000-0000-0000-000000000002"
    private let targetID = "40000000-0000-0000-0000-0000000000aa"

    private func message(
        _ body: String,
        serverMessageID: String? = nil,
        conversationID: String? = nil,
        sender: String? = nil,
        isOutgoing: Bool = false,
        replyToServerMessageID: String? = nil,
        historyKind: SecureMessagingMessageKind? = nil,
        historyReplyToMessageID: String? = nil
    ) -> LocalMessage {
        var message = LocalMessage(
            id: UUID(),
            serverMessageId: serverMessageID,
            conversationId: conversationID ?? conversation,
            senderId: sender ?? them,
            body: body,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            sentAt: nil,
            state: .sent,
            failureReason: nil,
            isOutgoing: isOutgoing,
            replyToServerMessageID: replyToServerMessageID
        )
        if let historyKind {
            message.secureMessagingHistory = SecureMessagingRetainedMessageMetadata(
                clientMessageID: UUID().uuidString.lowercased(),
                senderUserID: message.senderId,
                senderDeviceID: "device-1",
                senderEnrollmentEpoch: 1,
                senderSignalDeviceID: 1,
                rosterRevision: "revision-1",
                kind: historyKind,
                replyToMessageID: historyReplyToMessageID
            )
        }
        return message
    }

    private func mediaBody(mediaType: String, caption: String? = nil) throws -> String {
        try KitMediaMessageDescriptor(
            attachmentID: "0a1b2c3d-0000-4000-8000-000000000001",
            storageKey: "0a1b2c3d-0000-4000-8000-000000000002",
            mediaType: mediaType,
            ciphertextByteSize: 4_064,
            ciphertextSHA256: String(repeating: "ab", count: 32),
            keyMaterial: Data(repeating: 7, count: SecureMediaAttachmentCipher.keyMaterialBytes),
            plaintextByteSize: 4_000,
            caption: caption
        ).encoded
    }

    // MARK: Gesture geometry

    func testTravelFollowsTheFingerOneForOneWithinTheLimit() {
        XCTAssertEqual(SwipeToReplyPolicy.travel(drag: 0), 0, accuracy: 0.001)
        XCTAssertEqual(SwipeToReplyPolicy.travel(drag: 30), 30, accuracy: 0.001)
        XCTAssertEqual(
            SwipeToReplyPolicy.travel(drag: SwipeToReplyPolicy.maximumTravel),
            SwipeToReplyPolicy.maximumTravel,
            accuracy: 0.001
        )
    }

    func testTravelIsSymmetricSoEitherDirectionReplies() {
        for drag in [12, 40, 68, 200] as [CGFloat] {
            XCTAssertEqual(
                SwipeToReplyPolicy.travel(drag: -drag),
                -SwipeToReplyPolicy.travel(drag: drag),
                accuracy: 0.001
            )
        }
    }

    func testTravelDampsAndCapsPastTheLimit() {
        let beyond = SwipeToReplyPolicy.travel(drag: SwipeToReplyPolicy.maximumTravel + 100)
        XCTAssertGreaterThan(beyond, SwipeToReplyPolicy.maximumTravel)
        XCTAssertLessThan(beyond, SwipeToReplyPolicy.maximumTravel + 100)

        let absurd = SwipeToReplyPolicy.travel(drag: 4_000)
        XCTAssertEqual(absurd, SwipeToReplyPolicy.maximumTravel * 1.2, accuracy: 0.001)
        XCTAssertEqual(
            SwipeToReplyPolicy.travel(drag: -4_000),
            -SwipeToReplyPolicy.maximumTravel * 1.2,
            accuracy: 0.001
        )
    }

    func testTravelIsInertWithoutARange() {
        XCTAssertEqual(SwipeToReplyPolicy.travel(drag: 40, maximum: 0), 0, accuracy: 0.001)
        XCTAssertEqual(SwipeToReplyPolicy.travel(drag: 40, maximum: -10), 0, accuracy: 0.001)
    }

    func testReplyFiresOnlyAtTheTriggerAndInEitherDirection() {
        let trigger = SwipeToReplyPolicy.replyTrigger
        XCTAssertFalse(SwipeToReplyPolicy.shouldReply(travel: trigger - 0.5))
        XCTAssertTrue(SwipeToReplyPolicy.shouldReply(travel: trigger))
        XCTAssertTrue(SwipeToReplyPolicy.shouldReply(travel: trigger + 20))
        XCTAssertFalse(SwipeToReplyPolicy.shouldReply(travel: -(trigger - 0.5)))
        XCTAssertTrue(SwipeToReplyPolicy.shouldReply(travel: -trigger))
        XCTAssertFalse(SwipeToReplyPolicy.shouldReply(travel: trigger, trigger: 0))
    }

    func testTheGestureCanAlwaysReachItsTrigger() {
        // A trigger the finger cannot reach would make the gesture impossible to perform.
        XCTAssertTrue(SwipeToReplyPolicy.shouldReply(
            travel: SwipeToReplyPolicy.travel(drag: 4_000)
        ))
        XCTAssertLessThan(SwipeToReplyPolicy.replyTrigger, SwipeToReplyPolicy.maximumTravel)
    }

    func testProgressRunsZeroToOneAndClampsAtBothEnds() {
        let trigger = SwipeToReplyPolicy.replyTrigger
        XCTAssertEqual(SwipeToReplyPolicy.progress(travel: 0), 0, accuracy: 0.001)
        XCTAssertEqual(SwipeToReplyPolicy.progress(travel: trigger / 2), 0.5, accuracy: 0.001)
        XCTAssertEqual(SwipeToReplyPolicy.progress(travel: trigger), 1, accuracy: 0.001)
        XCTAssertEqual(SwipeToReplyPolicy.progress(travel: trigger * 4), 1, accuracy: 0.001)
        XCTAssertEqual(SwipeToReplyPolicy.progress(travel: -trigger), 1, accuracy: 0.001)
        XCTAssertEqual(SwipeToReplyPolicy.progress(travel: 40, trigger: 0), 0, accuracy: 0.001)
    }

    // MARK: What can be answered

    func testOnlyMessagesTheServerKnowsCanBeAnswered() {
        XCTAssertFalse(MessageReplyQuotePolicy.canReply(to: message("Not sent yet")))
        XCTAssertTrue(MessageReplyQuotePolicy.canReply(
            to: message("Sent", serverMessageID: targetID)
        ))
    }

    func testReactionsAndSystemNoticesCannotBeAnswered() throws {
        let reaction = try XCTUnwrap(KitMessageReaction(
            operation: .add,
            targetServerMessageID: targetID,
            emoji: "👍"
        ))
        XCTAssertFalse(MessageReplyQuotePolicy.canReply(to: message(
            reaction.encoded,
            serverMessageID: "40000000-0000-0000-0000-0000000000bb"
        )))
        XCTAssertFalse(MessageReplyQuotePolicy.canReply(to: message(
            "Plain text claiming to be a reaction",
            serverMessageID: "40000000-0000-0000-0000-0000000000bb",
            historyKind: .encryptedReaction,
            historyReplyToMessageID: targetID
        )))
        XCTAssertFalse(MessageReplyQuotePolicy.canReply(to: message(
            KitSystemMessage.prefix + "anything",
            serverMessageID: "40000000-0000-0000-0000-0000000000bb"
        )))
    }

    func testMediaCanBeAnswered() throws {
        let photo = message(
            try mediaBody(mediaType: "image/jpeg"),
            serverMessageID: targetID
        )
        XCTAssertTrue(MessageReplyQuotePolicy.canReply(to: photo))
    }

    // MARK: Preview text

    func testPreviewUsesWordsThenCaptionThenKind() throws {
        XCTAssertEqual(
            MessageReplyQuotePolicy.previewText(for: message("  Bring the receipt  ")),
            "Bring the receipt"
        )
        XCTAssertEqual(
            MessageReplyQuotePolicy.previewText(
                for: message(try mediaBody(mediaType: "image/jpeg", caption: "  At the gate  "))
            ),
            "At the gate"
        )
        XCTAssertEqual(
            MessageReplyQuotePolicy.previewText(
                for: message(try mediaBody(mediaType: "image/jpeg"))
            ),
            KitChatMediaKind.image.previewLabel
        )
        XCTAssertEqual(
            MessageReplyQuotePolicy.previewText(
                for: message(try mediaBody(mediaType: "audio/mp4", caption: "   "))
            ),
            KitChatMediaKind.voice.previewLabel
        )
        XCTAssertEqual(MessageReplyQuotePolicy.previewText(for: message("   ")), "Message")
    }

    // MARK: The pointer

    func testPointerComesFromTheLocalFieldOrTheAuthenticatedEnvelope() {
        XCTAssertEqual(
            MessageReplyQuotePolicy.targetServerMessageID(of: message(
                "Queued answer",
                replyToServerMessageID: targetID.uppercased()
            )),
            targetID
        )
        XCTAssertEqual(
            MessageReplyQuotePolicy.targetServerMessageID(of: message(
                "Received answer",
                serverMessageID: "40000000-0000-0000-0000-0000000000bb",
                historyKind: .encrypted,
                historyReplyToMessageID: targetID.uppercased()
            )),
            targetID
        )
        XCTAssertNil(MessageReplyQuotePolicy.targetServerMessageID(of: message("Plain")))
    }

    func testReactionsNeverReadAsAnswersEvenThoughTheyPointAtATarget() throws {
        let reaction = try XCTUnwrap(KitMessageReaction(
            operation: .add,
            targetServerMessageID: targetID,
            emoji: "🎉"
        ))
        XCTAssertNil(MessageReplyQuotePolicy.targetServerMessageID(of: message(
            reaction.encoded,
            serverMessageID: "40000000-0000-0000-0000-0000000000bb",
            historyKind: .encryptedReaction,
            historyReplyToMessageID: targetID
        )))
    }

    // MARK: Quotes

    func testQuoteNamesTheAuthorOfTheAnsweredMessage() {
        let target = message("Bring the receipt", serverMessageID: targetID)
        let answer = message(
            "On my way",
            serverMessageID: "40000000-0000-0000-0000-0000000000bb",
            sender: me,
            isOutgoing: true,
            replyToServerMessageID: targetID
        )
        let quote = MessageReplyQuotePolicy.quote(
            for: answer,
            in: [target, answer],
            currentUserID: me,
            displayName: { $0 == self.them ? "Amina" : nil }
        )
        XCTAssertEqual(quote?.targetServerMessageID, targetID)
        XCTAssertEqual(quote?.authorName, "Amina")
        XCTAssertEqual(quote?.preview, "Bring the receipt")
        XCTAssertFalse(quote?.authorIsSelf ?? true)
    }

    func testQuotingYourOwnMessageIsMarkedAsSelfAndCarriesNoName() {
        let target = message("Bring the receipt", serverMessageID: targetID, isOutgoing: true)
        let answer = message(
            "Answering myself",
            serverMessageID: "40000000-0000-0000-0000-0000000000bb",
            replyToServerMessageID: targetID
        )
        let quote = MessageReplyQuotePolicy.quote(
            for: answer,
            in: [target, answer],
            currentUserID: nil,
            displayName: { _ in "Should not be used" }
        )
        XCTAssertTrue(quote?.authorIsSelf ?? false)
        XCTAssertNil(quote?.authorName)
    }

    func testAnUnknownOrForeignTargetLeavesTheAnswerPlain() {
        let answer = message(
            "On my way",
            serverMessageID: "40000000-0000-0000-0000-0000000000bb",
            replyToServerMessageID: targetID
        )
        XCTAssertNil(MessageReplyQuotePolicy.quote(
            for: answer,
            in: [answer],
            currentUserID: me,
            displayName: { _ in "Amina" }
        ))

        // A message with the same server id in a different thread is not this thread's target.
        let elsewhere = message(
            "Bring the receipt",
            serverMessageID: targetID,
            conversationID: otherConversation
        )
        XCTAssertNil(MessageReplyQuotePolicy.quote(
            for: answer,
            in: [elsewhere, answer],
            currentUserID: me,
            displayName: { _ in "Amina" }
        ))
    }

    func testAMessageCannotQuoteItself() {
        let looping = message(
            "Loop",
            serverMessageID: targetID,
            replyToServerMessageID: targetID.uppercased()
        )
        XCTAssertNil(MessageReplyQuotePolicy.quote(
            for: looping,
            in: [looping],
            currentUserID: me,
            displayName: { _ in "Amina" }
        ))
    }

    func testQuoteResolvesAgainstLocalHistoryRatherThanCarriedText() throws {
        // The wire never carries the quoted plaintext: the preview has to come from the copy of
        // the target this device already holds, so an edited or absent target cannot be spoofed.
        let target = message(
            try mediaBody(mediaType: "video/mp4", caption: "Outside the shop"),
            serverMessageID: targetID
        )
        let answer = message(
            "Nice",
            serverMessageID: "40000000-0000-0000-0000-0000000000bb",
            sender: me,
            isOutgoing: true,
            historyKind: .encrypted,
            historyReplyToMessageID: targetID
        )
        let quote = MessageReplyQuotePolicy.quote(
            for: answer,
            in: [target, answer],
            currentUserID: me,
            displayName: { _ in nil }
        )
        XCTAssertEqual(quote?.preview, "Outside the shop")
        XCTAssertNil(quote?.authorName)
        XCTAssertFalse(quote?.authorIsSelf ?? true)
    }
}
