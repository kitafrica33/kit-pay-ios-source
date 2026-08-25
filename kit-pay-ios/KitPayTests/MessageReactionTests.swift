import XCTest
@testable import KitPay

final class MessageReactionTests: XCTestCase {
    private let target = "40000000-0000-0000-0000-000000000001"
    private let otherTarget = "40000000-0000-0000-0000-000000000002"
    private let userA = "10000000-0000-0000-0000-00000000000a"
    private let userB = "10000000-0000-0000-0000-00000000000b"
    private let userC = "10000000-0000-0000-0000-00000000000c"
    private let userD = "10000000-0000-0000-0000-00000000000d"

    // MARK: - Descriptor round-trip

    func testReactionCapabilityIsFailClosed() {
        XCTAssertFalse(MessagingReactionCapabilityPolicy.isEnabled(features: nil))
        XCTAssertFalse(MessagingReactionCapabilityPolicy.isEnabled(features: [:]))
        XCTAssertFalse(MessagingReactionCapabilityPolicy.isEnabled(features: [
            MessagingReactionCapabilityPolicy.featureKey: false,
        ]))
        XCTAssertFalse(MessagingReactionCapabilityPolicy.isEnabled(features: [
            MessagingReactionCapabilityPolicy.featureKey: nil,
        ]))
        XCTAssertTrue(MessagingReactionCapabilityPolicy.isEnabled(features: [
            MessagingReactionCapabilityPolicy.featureKey: true,
        ]))
    }

    func testAddRoundTripWithSkinToneModifierEmoji() throws {
        let reaction = try XCTUnwrap(
            KitMessageReaction(
                operation: .add,
                targetServerMessageID: target,
                emoji: "👍🏽"
            )
        )
        XCTAssertEqual(
            reaction.encoded,
            "KITRXN1:v=1&a=add&t=\(target)&e=%F0%9F%91%8D%F0%9F%8F%BD"
        )
        XCTAssertTrue(KitMessageReaction.isReactionText(reaction.encoded))
        XCTAssertEqual(KitMessageReaction.parse(reaction.encoded), reaction)
    }

    func testRemoveRoundTripWithVariationSelectorEmoji() throws {
        let reaction = try XCTUnwrap(
            KitMessageReaction(
                operation: .remove,
                targetServerMessageID: target,
                emoji: "❤️"
            )
        )
        XCTAssertEqual(
            reaction.encoded,
            "KITRXN1:v=1&a=remove&t=\(target)&e=%E2%9D%A4%EF%B8%8F"
        )
        XCTAssertEqual(KitMessageReaction.parse(reaction.encoded), reaction)
    }

    func testEncodingMatchesJavaURLEncoderGoldenCases() throws {
        let variationSelector = try XCTUnwrap(KitMessageReaction(
            operation: .add,
            targetServerMessageID: target,
            emoji: "*️"
        ))
        XCTAssertEqual(
            variationSelector.encoded,
            "KITRXN1:v=1&a=add&t=\(target)&e=*%EF%B8%8F"
        )

        let tilde = try XCTUnwrap(KitMessageReaction(
            operation: .add,
            targetServerMessageID: target,
            emoji: "~👍"
        ))
        XCTAssertEqual(
            tilde.encoded,
            "KITRXN1:v=1&a=add&t=\(target)&e=%7E%F0%9F%91%8D"
        )
    }

    func testCreationCanonicalizesNFCAndWireRejectsNonCanonicalNFD() throws {
        let decomposed = "e\u{301}"
        let reaction = try XCTUnwrap(KitMessageReaction(
            operation: .add,
            targetServerMessageID: target,
            emoji: decomposed
        ))
        XCTAssertEqual(reaction.emoji, "é")
        XCTAssertEqual(
            reaction.encoded,
            "KITRXN1:v=1&a=add&t=\(target)&e=%C3%A9"
        )
        XCTAssertNil(KitMessageReaction.parse(
            "KITRXN1:v=1&a=add&t=\(target)&e=e%CC%81"
        ))
    }

    func testRejectsNextLineWhitespace() {
        XCTAssertNil(KitMessageReaction(
            operation: .add,
            targetServerMessageID: target,
            emoji: "👍\u{0085}"
        ))
        XCTAssertNil(KitMessageReaction.parse(
            "KITRXN1:v=1&a=add&t=\(target)&e=%F0%9F%91%8D%C2%85"
        ))
    }

    func testQuickReactionPaletteMatchesCrossPlatformContract() {
        XCTAssertEqual(
            MessageReactionAggregationPolicy.quickReactions,
            ["👍", "✅", "❤️", "😂", "😮", "🙏"]
        )
    }

    // MARK: - Strict parsing

    func testParseRejectsWrongPrefix() {
        let body = "KITPAY1:v=1&a=add&t=\(target)&e=%F0%9F%91%8D"
        XCTAssertNil(KitMessageReaction.parse(body))
        XCTAssertFalse(KitMessageReaction.isReactionText(body))
    }

    func testUserAuthoredTextCannotEnterReactionNamespace() throws {
        let reaction = try XCTUnwrap(
            KitMessageReaction(
                operation: .add,
                targetServerMessageID: target,
                emoji: "👍"
            )
        )
        XCTAssertFalse(SecureMessageReservedPrefixPolicy.allowsUserAuthoredText(
            reaction.encoded
        ))
        XCTAssertFalse(SecureMessageReservedPrefixPolicy.allowsUserAuthoredText(
            "  \nKITRXN1:not-even-valid"
        ))
        XCTAssertTrue(SecureMessageReservedPrefixPolicy.allowsUserAuthoredText(
            "About KITRXN1: mid-sentence is fine"
        ))
    }

    func testParseRejectsDuplicateKey() {
        XCTAssertNil(
            KitMessageReaction.parse(
                "KITRXN1:v=1&a=add&t=\(target)&e=%F0%9F%91%8D&a=add"
            )
        )
    }

    func testParseRejectsMissingKey() {
        XCTAssertNil(KitMessageReaction.parse("KITRXN1:v=1&a=add&t=\(target)"))
    }

    func testParseRejectsExtraKey() {
        XCTAssertNil(
            KitMessageReaction.parse(
                "KITRXN1:v=1&a=add&t=\(target)&e=%F0%9F%91%8D&x=1"
            )
        )
    }

    func testParseRejectsUppercaseTargetUUID() {
        // Deliberately not `target`: that id is all digits, so uppercasing it changes nothing and
        // the case rule would never actually be exercised.
        let hexTarget = "4a0bc0de-0f0a-4b0c-8d0e-00000000abcd"
        XCTAssertNotNil(
            KitMessageReaction.parse("KITRXN1:v=1&a=add&t=\(hexTarget)&e=%F0%9F%91%8D")
        )
        XCTAssertNil(
            KitMessageReaction.parse(
                "KITRXN1:v=1&a=add&t=\(hexTarget.uppercased())&e=%F0%9F%91%8D"
            )
        )
    }

    func testParseRejectsReorderedFields() {
        XCTAssertNil(
            KitMessageReaction.parse(
                "KITRXN1:v=1&t=\(target)&a=add&e=%F0%9F%91%8D"
            )
        )
    }

    func testParseRejectsTrailingAmpersand() {
        XCTAssertNil(
            KitMessageReaction.parse(
                "KITRXN1:v=1&a=add&t=\(target)&e=%F0%9F%91%8D&"
            )
        )
    }

    func testRejectsOversizedEmoji() {
        // Five scalars exceed the four-scalar bound that covers real modifier sequences.
        let oversized = "😀😀😀😀😀"
        XCTAssertNil(
            KitMessageReaction(
                operation: .add,
                targetServerMessageID: target,
                emoji: oversized
            )
        )
        let encodedEmoji = String(repeating: "%F0%9F%98%80", count: 5)
        XCTAssertNil(
            KitMessageReaction.parse("KITRXN1:v=1&a=add&t=\(target)&e=\(encodedEmoji)")
        )
    }

    // MARK: - Aggregation

    func testTwoUsersSameEmojiTallyWithPreservedOrder() throws {
        let messages = try [
            reactionMessage(.add, emoji: "👍", sender: userB, at: 10),
            reactionMessage(.add, emoji: "👍", sender: userA, at: 5),
            targetMessage(),
        ]
        let tallies = MessageReactionAggregationPolicy.tallies(
            in: messages,
            currentUserID: userA.uppercased()
        )
        XCTAssertEqual(tallies.count, 1)
        let targetTallies = try XCTUnwrap(tallies[target])
        XCTAssertEqual(targetTallies.count, 1)
        XCTAssertEqual(targetTallies[0].emoji, "👍")
        XCTAssertEqual(targetTallies[0].count, 2)
        XCTAssertEqual(targetTallies[0].reactorUserIDs, [userA, userB])
        XCTAssertTrue(targetTallies[0].includesCurrentUser)
        XCTAssertEqual(targetTallies[0].id, "👍")
    }

    func testIncludesCurrentUserIsFalseForNonReactor() throws {
        let messages = try [
            targetMessage(),
            reactionMessage(.add, emoji: "👍", sender: userA, at: 0),
        ]
        let tallies = MessageReactionAggregationPolicy.tallies(
            in: messages,
            currentUserID: userB
        )
        XCTAssertEqual(tallies[target]?.first?.includesCurrentUser, false)
    }

    func testAddThenRemoveLeavesNoTally() throws {
        let messages = try [
            targetMessage(),
            reactionMessage(.add, emoji: "👍", sender: userA, at: 0),
            reactionMessage(.remove, emoji: "👍", sender: userA, at: 1),
        ]
        XCTAssertTrue(
            MessageReactionAggregationPolicy.tallies(
                in: messages,
                currentUserID: userA
            ).isEmpty
        )
        XCTAssertNil(
            MessageReactionAggregationPolicy.currentUserReaction(
                to: target,
                in: messages,
                currentUserID: userA
            )
        )
    }

    func testAddingSecondEmojiImplicitlyReplacesFirst() throws {
        let messages = try [
            targetMessage(),
            reactionMessage(.add, emoji: "❤️", sender: userA, at: 0),
            reactionMessage(.add, emoji: "👍", sender: userA, at: 1),
        ]
        let targetTallies = try XCTUnwrap(
            MessageReactionAggregationPolicy.tallies(
                in: messages,
                currentUserID: userA
            )[target]
        )
        XCTAssertEqual(targetTallies.count, 1)
        XCTAssertEqual(targetTallies[0].emoji, "👍")
        XCTAssertEqual(targetTallies[0].count, 1)
        XCTAssertEqual(
            MessageReactionAggregationPolicy.currentUserReaction(
                to: target.uppercased(),
                in: messages,
                currentUserID: userA.uppercased()
            ),
            "👍"
        )
    }

    func testFailedOutgoingReactionIsIgnoredButStillSuppressed() throws {
        let failed = try reactionMessage(
            .add,
            emoji: "👍",
            sender: userA,
            at: 0,
            state: .failed,
            isOutgoing: true
        )
        XCTAssertTrue(
            MessageReactionAggregationPolicy.tallies(
                in: [failed],
                currentUserID: userA
            ).isEmpty
        )
        XCTAssertEqual(
            MessageReactionAggregationPolicy.suppressedMessageIDs(in: [failed]),
            [failed.id]
        )
    }

    func testSuppressionSetContainsExactlyTheReactionMessages() throws {
        let text = message(body: "see you at noon", sender: userA, at: 0)
        let almostReaction = message(
            body: "KITRXN1:v=1&t=\(target)&a=add&e=%F0%9F%91%8D",
            sender: userA,
            at: 1
        )
        let addReaction = try reactionMessage(.add, emoji: "👍", sender: userA, at: 2)
        let removeReaction = try reactionMessage(.remove, emoji: "👍", sender: userB, at: 3)
        XCTAssertEqual(
            MessageReactionAggregationPolicy.suppressedMessageIDs(
                in: [text, almostReaction, addReaction, removeReaction]
            ),
            [addReaction.id, removeReaction.id]
        )
    }

    func testOrdinaryAuthenticatedTextCannotImpersonateReaction() throws {
        var spoof = try reactionMessage(.add, emoji: "👍", sender: userA, at: 0)
        let metadata = try XCTUnwrap(spoof.secureMessagingHistory)
        spoof.secureMessagingHistory = SecureMessagingRetainedMessageMetadata(
            clientMessageID: metadata.clientMessageID,
            senderUserID: metadata.senderUserID,
            senderDeviceID: metadata.senderDeviceID,
            senderEnrollmentEpoch: metadata.senderEnrollmentEpoch,
            senderSignalDeviceID: metadata.senderSignalDeviceID,
            rosterRevision: metadata.rosterRevision,
            kind: .encrypted,
            replyToMessageID: nil
        )
        XCTAssertTrue(MessageReactionAggregationPolicy.tallies(
            in: [spoof],
            currentUserID: userA
        ).isEmpty)
        XCTAssertTrue(MessageReactionAggregationPolicy.suppressedMessageIDs(in: [spoof]).isEmpty)
    }

    func testAuthenticatedReactionTargetMustMatchOuterReply() throws {
        var spoof = try reactionMessage(.add, emoji: "👍", sender: userA, at: 0)
        let metadata = try XCTUnwrap(spoof.secureMessagingHistory)
        spoof.secureMessagingHistory = SecureMessagingRetainedMessageMetadata(
            clientMessageID: metadata.clientMessageID,
            senderUserID: metadata.senderUserID,
            senderDeviceID: metadata.senderDeviceID,
            senderEnrollmentEpoch: metadata.senderEnrollmentEpoch,
            senderSignalDeviceID: metadata.senderSignalDeviceID,
            rosterRevision: metadata.rosterRevision,
            kind: .encryptedReaction,
            replyToMessageID: otherTarget
        )
        XCTAssertTrue(MessageReactionAggregationPolicy.tallies(
            in: [targetMessage(), spoof],
            currentUserID: userA
        ).isEmpty)
    }

    func testAuthenticatedOrphanReactionIsSuppressedButNeverTalliedOrCommitted() throws {
        let orphan = try reactionMessage(.add, emoji: "👍", sender: userA, at: 0)

        XCTAssertTrue(MessageReactionAggregationPolicy.tallies(
            in: [orphan],
            currentUserID: userA
        ).isEmpty)
        XCTAssertEqual(
            MessageReactionAggregationPolicy.suppressedMessageIDs(in: [orphan]),
            [orphan.id]
        )
        XCTAssertTrue(
            MessageReactionAggregationPolicy.retainingValidReactionTargets(
                [orphan],
                among: [orphan]
            ).isEmpty
        )
    }

    func testReactionTargetMustBeOrdinaryAndInTheSameConversation() throws {
        let reaction = try reactionMessage(.add, emoji: "👍", sender: userA, at: 1)
        let crossConversationTarget = targetMessage(
            conversationID: "30000000-0000-0000-0000-000000000099"
        )
        XCTAssertTrue(MessageReactionAggregationPolicy.tallies(
            in: [crossConversationTarget, reaction],
            currentUserID: userA
        ).isEmpty)

        let reactionTarget = try reactionMessage(
            .add,
            emoji: "❤️",
            sender: userB,
            at: 0,
            target: otherTarget,
            serverMessageID: target,
            sentAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertNil(MessageReactionAggregationPolicy.tallies(
            in: [targetMessage(serverMessageID: otherTarget), reactionTarget, reaction],
            currentUserID: userA
        )[target])
    }

    func testCommittedReactionRequiresServerIdentityAndSenderProvenance() throws {
        let targetRow = targetMessage()
        var missingServerID = try reactionMessage(.add, emoji: "👍", sender: userA, at: 0)
        missingServerID.serverMessageId = nil
        XCTAssertTrue(MessageReactionAggregationPolicy.tallies(
            in: [targetRow, missingServerID],
            currentUserID: userA
        ).isEmpty)

        var missingSender = try reactionMessage(.add, emoji: "👍", sender: userA, at: 1)
        let metadata = try XCTUnwrap(missingSender.secureMessagingHistory)
        missingSender.secureMessagingHistory = SecureMessagingRetainedMessageMetadata(
            clientMessageID: metadata.clientMessageID,
            senderUserID: nil,
            senderDeviceID: metadata.senderDeviceID,
            senderEnrollmentEpoch: metadata.senderEnrollmentEpoch,
            senderSignalDeviceID: metadata.senderSignalDeviceID,
            rosterRevision: metadata.rosterRevision,
            kind: metadata.kind,
            replyToMessageID: metadata.replyToMessageID
        )
        XCTAssertTrue(MessageReactionAggregationPolicy.tallies(
            in: [targetRow, missingSender],
            currentUserID: userA
        ).isEmpty)

        var mismatchedSender = try reactionMessage(.add, emoji: "👍", sender: userA, at: 2)
        mismatchedSender.secureMessagingHistory = SecureMessagingRetainedMessageMetadata(
            clientMessageID: metadata.clientMessageID,
            senderUserID: userB,
            senderDeviceID: metadata.senderDeviceID,
            senderEnrollmentEpoch: metadata.senderEnrollmentEpoch,
            senderSignalDeviceID: metadata.senderSignalDeviceID,
            rosterRevision: metadata.rosterRevision,
            kind: metadata.kind,
            replyToMessageID: metadata.replyToMessageID
        )
        XCTAssertTrue(MessageReactionAggregationPolicy.tallies(
            in: [targetRow, mismatchedSender],
            currentUserID: userA
        ).isEmpty)
    }

    func testCurrentUserReactionReflectsLatestStateAcrossShuffledInput() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // Identical timestamps: the id.uuidString tiebreak keeps replay order deterministic.
        let first = try reactionMessage(
            .add,
            emoji: "❤️",
            sender: userA,
            at: 0,
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        )
        let second = try reactionMessage(
            .add,
            emoji: "👍",
            sender: userA,
            at: 0,
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        )
        XCTAssertEqual(first.createdAt, base)
        XCTAssertEqual(
            MessageReactionAggregationPolicy.currentUserReaction(
                to: target,
                in: [targetMessage(), second, first],
                currentUserID: userA
            ),
            "👍"
        )
        XCTAssertNil(
            MessageReactionAggregationPolicy.currentUserReaction(
                to: target,
                in: [targetMessage(), second, first],
                currentUserID: nil
            )
        )
    }

    func testServerOrderingConvergesForOriginatingAndReceivingDevices() throws {
        let serverTime = Date(timeIntervalSince1970: 1_700_000_100)
        let addServerID = "50000000-0000-0000-0000-000000000001"
        let removeServerID = "50000000-0000-0000-0000-000000000002"

        // The origin retains client ids and skewed local creation times after acknowledgement.
        let originAdd = try reactionMessage(
            .add,
            emoji: "👍",
            sender: userA,
            at: 20,
            id: XCTUnwrap(UUID(uuidString: "ffffffff-0000-0000-0000-000000000001")),
            serverMessageID: addServerID,
            sentAt: serverTime
        )
        let originRemove = try reactionMessage(
            .remove,
            emoji: "👍",
            sender: userA,
            at: 10,
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001")),
            serverMessageID: removeServerID,
            sentAt: serverTime
        )

        // A receiving device projects the same events with server ids and server timestamps.
        let receivedAdd = try reactionMessage(
            .add,
            emoji: "👍",
            sender: userA,
            at: 100,
            id: XCTUnwrap(UUID(uuidString: addServerID)),
            serverMessageID: addServerID,
            sentAt: serverTime
        )
        let receivedRemove = try reactionMessage(
            .remove,
            emoji: "👍",
            sender: userA,
            at: 100,
            id: XCTUnwrap(UUID(uuidString: removeServerID)),
            serverMessageID: removeServerID,
            sentAt: serverTime
        )

        XCTAssertNil(MessageReactionAggregationPolicy.currentUserReaction(
            to: target,
            in: [targetMessage(), originRemove, originAdd],
            currentUserID: userA
        ))
        XCTAssertNil(MessageReactionAggregationPolicy.currentUserReaction(
            to: target,
            in: [targetMessage(), receivedRemove, receivedAdd],
            currentUserID: userA
        ))
    }

    func testServerTimestampPrecedesServerIDInCanonicalReactionOrder() throws {
        let earlierRemove = try reactionMessage(
            .remove,
            emoji: "👍",
            sender: userA,
            at: 50,
            id: XCTUnwrap(UUID(uuidString: "ffffffff-0000-0000-0000-000000000001")),
            serverMessageID: "ffffffff-0000-0000-0000-000000000001",
            sentAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let laterAdd = try reactionMessage(
            .add,
            emoji: "👍",
            sender: userA,
            at: 10,
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001")),
            serverMessageID: "00000000-0000-0000-0000-000000000001",
            sentAt: Date(timeIntervalSince1970: 1_700_000_101)
        )

        XCTAssertEqual(
            MessageReactionAggregationPolicy.currentUserReaction(
                to: target,
                in: [targetMessage(), laterAdd, earlierRemove],
                currentUserID: userA
            ),
            "👍"
        )
    }

    func testFractionalServerTimestampControlsReactionOrder() throws {
        let remove = try reactionMessage(
            .remove,
            emoji: "👍",
            sender: userA,
            at: 10,
            serverMessageID: "ffffffff-0000-0000-0000-000000000001",
            sentAt: Date(timeIntervalSince1970: 1_700_000_100.100_000)
        )
        let add = try reactionMessage(
            .add,
            emoji: "👍",
            sender: userA,
            at: 0,
            serverMessageID: "00000000-0000-0000-0000-000000000001",
            sentAt: Date(timeIntervalSince1970: 1_700_000_100.200_000)
        )
        XCTAssertEqual(
            MessageReactionAggregationPolicy.currentUserReaction(
                to: target,
                in: [targetMessage(), add, remove],
                currentUserID: userA
            ),
            "👍"
        )
    }

    func testTalliesSortByCountDescendingThenEmojiAscending() throws {
        let messages = try [
            targetMessage(),
            targetMessage(serverMessageID: otherTarget),
            reactionMessage(.add, emoji: "👍", sender: userA, at: 0),
            reactionMessage(.add, emoji: "🙏", sender: userC, at: 1),
            reactionMessage(.add, emoji: "👍", sender: userB, at: 2),
            reactionMessage(.add, emoji: "😂", sender: userD, at: 3),
            reactionMessage(.add, emoji: "👍", sender: userD, at: 4, target: otherTarget),
        ]
        let tallies = MessageReactionAggregationPolicy.tallies(
            in: messages,
            currentUserID: userA
        )
        XCTAssertEqual(Set(tallies.keys), [target, otherTarget])
        XCTAssertEqual(tallies[target]?.map(\.emoji), ["👍", "😂", "🙏"])
        XCTAssertEqual(tallies[target]?.map(\.count), [2, 1, 1])
        XCTAssertEqual(tallies[otherTarget]?.map(\.emoji), ["👍"])
    }

    // MARK: - Fixtures

    private func targetMessage(
        serverMessageID: String? = nil,
        conversationID: String = "30000000-0000-0000-0000-000000000001"
    ) -> LocalMessage {
        let serverMessageID = serverMessageID ?? target
        return message(
            body: "Reaction target",
            sender: userB,
            at: -1,
            id: UUID(uuidString: serverMessageID)!,
            serverMessageID: serverMessageID,
            sentAt: Date(timeIntervalSince1970: 1_699_999_999),
            conversationID: conversationID
        )
    }

    private func reactionMessage(
        _ operation: KitMessageReactionOperation,
        emoji: String,
        sender: String,
        at seconds: TimeInterval,
        target: String? = nil,
        state: MessageDeliveryState = .sent,
        isOutgoing: Bool = false,
        id: UUID = UUID(),
        serverMessageID: String? = nil,
        sentAt: Date? = nil,
        conversationID: String = "30000000-0000-0000-0000-000000000001"
    ) throws -> LocalMessage {
        let reactionTarget = target ?? self.target
        let descriptor = try XCTUnwrap(
            KitMessageReaction(
                operation: operation,
                targetServerMessageID: reactionTarget,
                emoji: emoji
            )
        )
        let effectiveServerMessageID = serverMessageID
            ?? (isOutgoing ? nil : id.uuidString.lowercased())
        var result = message(
            body: descriptor.encoded,
            sender: sender,
            at: seconds,
            state: state,
            isOutgoing: isOutgoing,
            id: id,
            serverMessageID: effectiveServerMessageID,
            sentAt: sentAt ?? effectiveServerMessageID.map { _ in
                Date(timeIntervalSince1970: 1_700_000_000 + seconds)
            },
            conversationID: conversationID
        )
        if effectiveServerMessageID != nil {
            result.secureMessagingHistory = SecureMessagingRetainedMessageMetadata(
                clientMessageID: id.uuidString.lowercased(),
                senderUserID: sender,
                senderDeviceID: "20000000-0000-4000-8000-000000000001",
                senderEnrollmentEpoch: 1,
                senderSignalDeviceID: 1,
                rosterRevision: "v1:sha256:" + String(repeating: "a", count: 64),
                kind: .encryptedReaction,
                replyToMessageID: reactionTarget
            )
        }
        return result
    }

    private func message(
        body: String,
        sender: String,
        at seconds: TimeInterval,
        state: MessageDeliveryState = .sent,
        isOutgoing: Bool = false,
        id: UUID = UUID(),
        serverMessageID: String? = nil,
        sentAt: Date? = nil,
        conversationID: String = "30000000-0000-0000-0000-000000000001"
    ) -> LocalMessage {
        LocalMessage(
            id: id,
            serverMessageId: serverMessageID,
            conversationId: conversationID,
            senderId: sender,
            body: body,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000 + seconds),
            sentAt: sentAt,
            state: state,
            failureReason: nil,
            isOutgoing: isOutgoing,
            attachmentData: nil,
            pendingAttachment: nil
        )
    }
}
