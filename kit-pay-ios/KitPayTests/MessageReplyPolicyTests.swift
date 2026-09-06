import XCTest
import UIKit
import SwiftUI
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

    func testSwipeReplyVisualThresholdRemainsBelowTheReplyTrigger() {
        XCTAssertGreaterThan(SwipeToReplyPolicy.activationDistance, 0)
        XCTAssertLessThan(SwipeToReplyPolicy.activationDistance, SwipeToReplyPolicy.replyTrigger)
        XCTAssertGreaterThan(SwipeToReplyPolicy.horizontalDominance, 1)
    }

    func testNativePanAdmissionRejectsVerticalAmbiguousAndNonfiniteDisplacements() {
        for translation in [
            CGSize.zero, CGSize(width: 0, height: 12), CGSize(width: 0, height: -180),
            CGSize(width: 12, height: 8), CGSize(width: -12, height: -8),
            CGSize(width: CGFloat.nan, height: 0), CGSize(width: 50, height: CGFloat.infinity),
        ] {
            XCTAssertFalse(SwipeToReplyPolicy.nativePanShouldBegin(translation: translation))
        }
        for translation in [CGSize(width: 9, height: 1), CGSize(width: -9, height: -1)] {
            XCTAssertTrue(SwipeToReplyPolicy.nativePanShouldBegin(translation: translation),
                          "UIKit admission must not wait for the later visual threshold")
        }
    }

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

    func testOrdinaryMetadataAndSelfRepliesNeverEvaluateHistory() {
        var historyReads = 0
        func history() -> [LocalMessage] {
            historyReads += 1
            return []
        }
        let rows = [
            message("Ordinary message"),
            message("Self reference", serverMessageID: targetID,
                    replyToServerMessageID: targetID.uppercased()),
            message("Metadata", serverMessageID: targetID,
                    historyKind: .encryptedReaction, historyReplyToMessageID: targetID),
        ]
        for _ in 0 ..< 100 {
            for row in rows {
                XCTAssertNil(MessageReplyQuotePolicy.quote(
                    for: row, in: history(), currentUserID: me, displayName: { _ in nil }
                ))
            }
        }
        XCTAssertEqual(historyReads, 0,
                       "Rendering non-replies must not project or search conversation history")
    }

    func testReplyEvaluatesHistoryOnceAndReflectsSubsequentEdits() {
        var target = message("Before correction", serverMessageID: targetID)
        let answer = message("Answer", replyToServerMessageID: targetID)
        var historyReads = 0
        func history() -> [LocalMessage] {
            historyReads += 1
            return [target, answer]
        }
        let first = MessageReplyQuotePolicy.quote(
            for: answer, in: history(), currentUserID: me, displayName: { _ in "Amina" }
        )
        XCTAssertEqual(first?.preview, "Before correction")
        XCTAssertEqual(historyReads, 1)

        target.body = "Corrected wording"
        let corrected = MessageReplyQuotePolicy.quote(
            for: answer, in: history(), currentUserID: me, displayName: { _ in "Amina" }
        )
        XCTAssertEqual(corrected?.preview, "Corrected wording")
        XCTAssertEqual(historyReads, 2, "Lazy evaluation must not cache stale quoted text")
    }

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

/// Exercises the native coordinator's admission decision, shared registration and view lifecycle.
/// A real idle pan recognizer has no synthetic touch stream, so admission receives explicit
/// translation through the same method the UIKit delegate calls. Real touch arbitration is
/// covered by the slow vertical and horizontal-reply UI regression on Simulator.
@MainActor
final class SwipeToReplyNativeGestureTests: XCTestCase {
    func testSwiftUIBackgroundProbesMatchRowAndWaveformBounds() async {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
        let host = UIHostingController(rootView: ScrollView {
            VStack {
                SwipeToReplyContainer(isEnabled: true, onReply: {}) {
                    Color.blue.frame(width: 240, height: 80)
                }
                Color.clear.frame(width: 120, height: 22)
                    .background(SwipeToReplyGestureExclusion())
            }
        })
        window.rootViewController = host
        window.isHidden = false
        defer {
            host.view.removeFromSuperview()
            window.rootViewController = nil
            window.isHidden = true
        }
        for _ in 0..<3 {
            window.layoutIfNeeded()
            host.view.layoutIfNeeded()
            await drainMainQueue()
        }
        func probes(in view: UIView) -> [SwipeToReplyGestureProbe] {
            (view as? SwipeToReplyGestureProbe).map { [$0] } ?? view.subviews.flatMap { probes(in: $0) }
        }
        let regions = probes(in: host.view)
        XCTAssertEqual(regions.count, 2)
        let row = regions.first { !$0.excludesReply }
        let waveform = regions.first { $0.excludesReply }
        XCTAssertEqual(row?.bounds.size, CGSize(width: 240, height: 80))
        XCTAssertEqual(waveform?.bounds.size, CGSize(width: 120, height: 22))
        XCTAssertNotNil(row?.coordinator)
        XCTAssertTrue(row?.coordinator === waveform?.coordinator)
        XCTAssertTrue(regions.allSatisfy { !$0.isUserInteractionEnabled })
    }

    func testVerticalAndDiagonalAdmissionNeverStartsReply() {
        let harness = Harness()
        defer { harness.close() }
        let events = Events()
        let row = harness.row(y: 40, events: events)
        let owner = row.coordinator!
        for translation in [CGPoint(x: 0, y: 12), CGPoint(x: 0, y: -180), CGPoint(x: 12, y: 8)] {
            XCTAssertTrue(harness.select(row))
            XCTAssertFalse(owner.shouldBegin(translation: CGSize(width: translation.x, height: translation.y)))
            owner.handle(state: .began, translation: translation.x)
            owner.handle(state: .ended, translation: 120)
        }
        XCTAssertTrue(events.changes.isEmpty)
        XCTAssertTrue(events.ends.isEmpty)
        XCTAssertEqual(events.cancellations, 0)
    }

    func testHorizontalAdmissionPrecedesTwentyPointVisibleActivation() {
        let harness = Harness()
        defer { harness.close() }
        let events = Events()
        let row = harness.row(y: 40, events: events)
        let owner = row.coordinator!
        for direction in [CGFloat(1), CGFloat(-1)] {
            XCTAssertTrue(harness.select(row))
            XCTAssertTrue(owner.shouldBegin(translation: CGSize(width: direction * 9, height: 1)))
            let previous = events.changes.count
            owner.handle(state: .began, translation: direction * 9)
            owner.handle(state: .changed, translation: direction * 19)
            XCTAssertEqual(events.changes.count, previous)
            owner.handle(state: .changed, translation: direction * 20)
            XCTAssertEqual(events.changes.last, direction * 20)
            owner.handle(state: .ended, translation: direction * 60)
            owner.handle(state: .ended, translation: direction * 60)
        }
        XCTAssertEqual(events.ends, [60, -60], "Final displacement is delivered exactly once")
    }

    func testOnePanRoutesOnlyTheSelectedRowAndUsesUpdatedCallbacks() {
        let harness = Harness()
        defer { harness.close() }
        let firstEvents = Events(), secondEvents = Events(), updatedEvents = Events()
        let first = harness.row(y: 40, events: firstEvents)
        let second = harness.row(y: 140, events: secondEvents)
        let owner = first.coordinator!
        XCTAssertTrue(owner === second.coordinator)
        XCTAssertEqual(harness.scroll.gestureRecognizers?.filter { $0 === owner.pan }.count, 1)
        XCTAssertFalse(first.isUserInteractionEnabled)
        XCTAssertTrue(harness.begin(second))
        owner.handle(state: .changed, translation: 30)
        second.configure(identity: second.identity, callbacks: updatedEvents.callbacks)
        owner.handle(state: .changed, translation: 55)
        owner.handle(state: .ended, translation: 65)
        XCTAssertTrue(firstEvents.changes.isEmpty)
        XCTAssertTrue(firstEvents.ends.isEmpty)
        XCTAssertEqual(secondEvents.changes, [30])
        XCTAssertTrue(secondEvents.ends.isEmpty, "An edited row must not commit a stale callback")
        XCTAssertEqual(updatedEvents.changes, [55])
        XCTAssertEqual(updatedEvents.ends, [65])
    }

    func testWaveformControlsAndNestedScrollsAreExcludedAtAdmission() {
        let harness = Harness()
        defer { harness.close() }
        let row = harness.row(y: 40, events: Events())
        let owner = row.coordinator!
        let exclusion = SwipeToReplyGestureProbe(frame: CGRect(x: 80, y: 55, width: 100, height: 25))
        exclusion.configure(identity: nil, callbacks: nil, excludesReply: true)
        harness.scroll.addSubview(exclusion)
        XCTAssertFalse(exclusion.isUserInteractionEnabled)
        XCTAssertTrue(exclusion.coordinator === owner)
        XCTAssertFalse(owner.selectRow(at: CGPoint(x: 100, y: 65), hitView: harness.scroll))
        XCTAssertTrue(owner.selectRow(at: CGPoint(x: 30, y: 65), hitView: harness.scroll))
        let control = UISlider(frame: CGRect(x: 20, y: 50, width: 40, height: 20))
        harness.scroll.addSubview(control)
        XCTAssertFalse(owner.selectRow(at: CGPoint(x: 30, y: 65), hitView: control))
        let nested = UIScrollView(frame: CGRect(x: 20, y: 50, width: 40, height: 20))
        harness.scroll.addSubview(nested)
        XCTAssertFalse(owner.selectRow(at: CGPoint(x: 30, y: 65), hitView: nested))
        XCTAssertFalse(owner.pan.cancelsTouchesInView)
        XCTAssertFalse(owner.pan.delaysTouchesBegan)
        XCTAssertFalse(owner.pan.delaysTouchesEnded)
        XCTAssertEqual(owner.pan.maximumNumberOfTouches, 1)
    }

    func testSimultaneousRecognitionIsLimitedToTheEnclosingScrollPan() {
        let harness = Harness()
        defer { harness.close() }
        let owner = harness.row(y: 40, events: Events()).coordinator!
        XCTAssertTrue(owner.gestureRecognizer(owner.pan,
            shouldRecognizeSimultaneouslyWith: harness.scroll.panGestureRecognizer))
        let competitors: [UIGestureRecognizer] = [
            UIPanGestureRecognizer(), UITapGestureRecognizer(), UILongPressGestureRecognizer(),
        ]
        for other in competitors {
            XCTAssertFalse(owner.gestureRecognizer(owner.pan, shouldRecognizeSimultaneouslyWith: other))
        }
    }

    func testDisableIdentityChangeAndDetachCancelWithoutCompletingReply() async {
        for mutation in 0..<3 {
            let harness = Harness()
            let events = Events()
            let row = harness.row(y: 40, events: events)
            let owner = row.coordinator!
            XCTAssertTrue(harness.begin(row))
            owner.handle(state: .changed, translation: 60)
            switch mutation {
            case 0: row.configure(identity: row.identity, callbacks: nil)
            case 1: row.configure(identity: UUID(), callbacks: events.callbacks)
            default: row.removeFromSuperview()
            }
            owner.handle(state: .ended, translation: 120)
            await drainMainQueue()
            XCTAssertTrue(events.ends.isEmpty)
            XCTAssertEqual(events.cancellations, 1)
            harness.close()
        }
    }

    func testReparentingCancelsOldHostAndRegistersOnlyWithTheNewScroll() async {
        let harness = Harness()
        defer { harness.close() }
        let events = Events()
        let row = harness.row(y: 40, events: events)
        let original = row.coordinator!
        XCTAssertTrue(harness.begin(row))
        original.handle(state: .changed, translation: 60)
        let replacement = UIScrollView(frame: harness.scroll.frame)
        harness.window.addSubview(replacement)
        replacement.addSubview(row)
        let rebound = row.coordinator!
        XCTAssertFalse(original === rebound)
        XCTAssertTrue(rebound.scrollView === replacement)
        XCTAssertFalse(harness.scroll.gestureRecognizers?.contains { $0 === original.pan } ?? false)
        original.handle(state: .ended, translation: 120)
        await drainMainQueue()
        XCTAssertTrue(events.ends.isEmpty)
        XCTAssertEqual(events.cancellations, 1)
        row.removeFromSuperview()
        XCTAssertFalse(replacement.gestureRecognizers?.contains { $0 === rebound.pan } ?? false)
        replacement.removeFromSuperview()
    }

    func testDeferredCancellationCannotEraseAReplacementProbesNewGesture() async {
        let harness = Harness()
        defer { harness.close() }
        let oldEvents = Events(), newEvents = Events()
        let lifetime = SwipeToReplyGestureLifetime()
        // Keep this scroll's shared owner alive while the selected lazy row is replaced.
        let retainedRow = harness.row(y: 140, events: Events())
        let owner = retainedRow.coordinator!
        weak var retired: SwipeToReplyGestureProbe?
        // Drain UIKit's temporary references without running the deferred cancellation.
        autoreleasepool {
            let row = harness.row(y: 40, events: oldEvents, lifetime: lifetime)
            XCTAssertTrue(harness.begin(row))
            owner.handle(state: .changed, translation: 60)
            retired = row
            row.removeFromSuperview()
        }
        XCTAssertNil(retired)
        let replacement = harness.row(y: 40, events: newEvents, lifetime: lifetime)
        XCTAssertTrue(harness.begin(replacement))
        owner.handle(state: .changed, translation: -55)
        await drainMainQueue()
        XCTAssertTrue(oldEvents.ends.isEmpty)
        XCTAssertEqual(newEvents.cancellations, 0)
        XCTAssertEqual(newEvents.changes, [0, -55], "Pending old feedback resets before new movement")
        owner.handle(state: .ended, translation: -65)
        XCTAssertEqual(newEvents.ends, [-65])
    }

    func testProbeDeallocationStillResetsTheSurvivingRowsFeedback() async {
        let harness = Harness()
        defer { harness.close() }
        let events = Events()
        let lifetime = SwipeToReplyGestureLifetime()
        weak var retired: SwipeToReplyGestureProbe?
        autoreleasepool {
            let row = harness.row(y: 40, events: events, lifetime: lifetime)
            let owner = row.coordinator!
            XCTAssertTrue(harness.begin(row))
            owner.handle(state: .changed, translation: 60)
            retired = row
            row.removeFromSuperview()
        }
        XCTAssertNil(retired)
        await drainMainQueue()
        XCTAssertTrue(events.ends.isEmpty)
        XCTAssertEqual(events.cancellations, 1)
        XCTAssertNil(lifetime.feedbackToken)
    }

    func testCancelledPanAndLastProbeRemovalPreserveNativeScrollOwnership() {
        let harness = Harness()
        defer { harness.close() }
        let events = Events()
        let row = harness.row(y: 40, events: events)
        let owner = row.coordinator!
        let nativePan = harness.scroll.panGestureRecognizer
        let nativeDelegate = nativePan.delegate
        let offset = harness.scroll.contentOffset
        XCTAssertTrue(harness.begin(row))
        owner.handle(state: .changed, translation: -60)
        owner.handle(state: .cancelled, translation: -60)
        owner.handle(state: .ended, translation: -120)
        XCTAssertEqual(events.cancellations, 1)
        XCTAssertTrue(events.ends.isEmpty)
        row.removeFromSuperview()
        XCTAssertFalse(harness.scroll.gestureRecognizers?.contains { $0 === owner.pan } ?? false)
        XCTAssertTrue(harness.scroll.panGestureRecognizer === nativePan)
        XCTAssertTrue(nativePan.delegate === nativeDelegate)
        XCTAssertTrue(nativePan.isEnabled)
        XCTAssertEqual(harness.scroll.contentOffset, offset)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private final class Events {
        var changes: [CGFloat] = []
        var ends: [CGFloat] = []
        var cancellations = 0
        var callbacks: SwipeToReplyGestureCallbacks {
            SwipeToReplyGestureCallbacks(
                changed: { self.changes.append($0) },
                ended: { self.ends.append($0) },
                cancelled: { self.cancellations += 1 }
            )
        }
    }

    @MainActor
    private final class Harness {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 600))

        init() {
            scroll.contentInsetAdjustmentBehavior = .never
            scroll.contentSize = CGSize(width: 320, height: 1_000)
            window.addSubview(scroll)
            window.isHidden = false
        }

        func row(
            y: CGFloat, events: Events, lifetime: SwipeToReplyGestureLifetime? = nil
        ) -> SwipeToReplyGestureProbe {
            let probe = SwipeToReplyGestureProbe(frame: CGRect(x: 10, y: y, width: 300, height: 80))
            probe.configure(identity: lifetime?.identity ?? UUID(), callbacks: events.callbacks, lifetime: lifetime)
            scroll.addSubview(probe)
            return probe
        }

        func select(_ row: SwipeToReplyGestureProbe) -> Bool {
            let point = row.convert(CGPoint(x: row.bounds.midX, y: row.bounds.midY), to: scroll)
            return row.coordinator?.selectRow(at: point, hitView: scroll) ?? false
        }

        func begin(_ row: SwipeToReplyGestureProbe) -> Bool {
            guard select(row), let owner = row.coordinator else { return false }
            guard owner.shouldBegin(translation: CGSize(width: 9, height: 0)) else { return false }
            owner.handle(state: .began, translation: 9)
            return true
        }

        func close() {
            for view in scroll.subviews { view.removeFromSuperview() }
            window.isHidden = true
        }
    }
}
