import XCTest
import UIKit
@testable import KitPay

@MainActor
final class ConversationNativeOpeningTests: XCTestCase {
    func testNativeOpeningUsesObservedBottomOffsetForLongAndShortContent() async {
        for contentHeight in [CGFloat(1_000), CGFloat(200)] {
            var acknowledgements = 0
            let harness = NativeOpeningHarness(onPositioned: { acknowledgements += 1 })
            defer { harness.close() }
            harness.scroll.contentSize.height = contentHeight
            harness.attach()
            XCTAssertEqual(acknowledgements, 0, "Enqueuing work is not a positioning receipt")

            await drainMainQueue()

            let expectedOffset = max(-20, contentHeight - 600 + 50)
            XCTAssertEqual(harness.scroll.contentOffset.y, expectedOffset, accuracy: 1)
            XCTAssertEqual(acknowledgements, 1)
        }
    }

    func testNativeOpeningRetriesEmptyLayoutAndLaterContentOrInsetGrowth() async {
        var acknowledgements = 0
        let harness = NativeOpeningHarness(onPositioned: { acknowledgements += 1 })
        defer { harness.close() }
        harness.scroll.contentSize.height = 0
        harness.attach()
        await drainMainQueue()
        XCTAssertEqual(acknowledgements, 0)

        // These changes do not resize the background Probe. Native geometry must trigger retry.
        harness.scroll.contentSize.height = 1_000
        await drainMainQueue()
        XCTAssertEqual(harness.scroll.contentOffset.y, 450, accuracy: 1)
        XCTAssertEqual(acknowledgements, 1)

        harness.scroll.contentSize.height = 1_240
        harness.scroll.contentInset.bottom = 90
        await drainMainQueue()
        XCTAssertEqual(harness.scroll.contentOffset.y, 730, accuracy: 1)

        harness.scroll.frame.size.height = 500
        await drainMainQueue()
        XCTAssertEqual(harness.scroll.contentOffset.y, 830, accuracy: 1)
        XCTAssertEqual(acknowledgements, 1, "Geometry following must not renew opening ownership")
    }

    func testAcknowledgedOpeningYieldsToNonPanNativeScrollingDespiteStaleCallbacks() async {
        var acknowledgements = 0
        let harness = NativeOpeningHarness(onPositioned: { acknowledgements += 1 })
        defer { harness.close() }
        harness.attach()
        await drainMainQueue()
        XCTAssertEqual(harness.scroll.contentOffset.y, 450, accuracy: 1)
        XCTAssertEqual(acknowledgements, 1)

        // Keep shouldKeepOpening true: an old SwiftUI render cannot reclaim native scrolling.
        harness.scroll.setContentOffset(CGPoint(x: 0, y: 123), animated: false)
        harness.attach()
        await drainMainQueue()
        XCTAssertEqual(harness.scroll.contentOffset.y, 123, accuracy: 1)

        harness.scroll.contentSize.height = 1_240
        harness.scroll.contentInset.bottom = 90
        harness.attach()
        await drainMainQueue()
        XCTAssertEqual(harness.scroll.contentOffset.y, 123, accuracy: 1)
        XCTAssertEqual(acknowledgements, 1)
    }

    func testNativeOriginChangeCancelsCoalescedGeometryFollow() async {
        let harness = NativeOpeningHarness(onPositioned: {})
        defer { harness.close() }
        harness.attach()
        await drainMainQueue()

        harness.scroll.contentSize.height = 1_240
        harness.scroll.contentInset.bottom = 90
        harness.scroll.setContentOffset(CGPoint(x: 0, y: 123), animated: false)
        harness.attach()
        await drainMainQueue()

        XCTAssertEqual(harness.scroll.contentOffset.y, 123, accuracy: 1)
    }

    func testNativeOriginChangeDuringLayoutCancelsGeometryFollow() async {
        let harness = NativeOpeningHarness(onPositioned: {})
        defer { harness.close() }
        harness.attach()
        await drainMainQueue()

        harness.scroll.contentSize.height = 1_240
        harness.scroll.onNextLayout = { [weak scroll = harness.scroll] in
            scroll?.setContentOffset(CGPoint(x: 0, y: 123), animated: false)
        }
        harness.scroll.setNeedsLayout()
        await drainMainQueue()

        XCTAssertEqual(harness.scroll.contentOffset.y, 123, accuracy: 1)
    }

    func testExplicitTargetChosenDuringLayoutCancelsGeometryFollow() async {
        var allowsFollowing = true
        let harness = NativeOpeningHarness(
            shouldFollowLayout: { allowsFollowing }, onPositioned: {}
        )
        defer { harness.close() }
        harness.attach()
        await drainMainQueue()

        harness.scroll.contentSize.height = 1_240
        harness.scroll.onNextLayout = { allowsFollowing = false }
        harness.scroll.setNeedsLayout()
        await drainMainQueue()

        XCTAssertEqual(harness.scroll.contentOffset.y, 450, accuracy: 1)
    }

    func testNativeOffsetsAndLayoutNeverGenerateCameraGestureCallbacks() async {
        var gestureCallbacks = 0
        let harness = NativeOpeningHarness(
            onPositioned: {}, onGesture: { gestureCallbacks += 1 }
        )
        defer { harness.close() }
        harness.attach()
        await drainMainQueue()
        harness.scroll.setContentOffset(CGPoint(x: 0, y: 700), animated: false)
        harness.scroll.contentSize.height = 1_240
        harness.scroll.contentInset.bottom = 90
        harness.attach()
        await drainMainQueue()
        harness.scroll.setContentOffset(CGPoint(x: 0, y: 123), animated: false)
        await drainMainQueue()

        XCTAssertEqual(gestureCallbacks, 0)
    }

    func testNativeCameraAdmissionReplacesMissingOrStaleViewGeometry() async {
        let expected = ConversationCameraPullGeometry(
            contentHeight: 1_000, viewportHeight: 600, viewportWidth: 320,
            topInset: 20, bottomInset: 50
        )
        let oldViewMeasurements: [ConversationCameraPullGeometry?] = [
            nil,
            .init(contentHeight: 0, viewportHeight: 658, viewportWidth: 320,
                  topInset: 0, bottomInset: 0),
            .init(contentHeight: 200, viewportHeight: 400, viewportWidth: 320,
                  topInset: 0, bottomInset: 0),
        ]
        for oldMeasurement in oldViewMeasurements {
            var admittedGeometry = oldMeasurement
            var admittedDistance: CGFloat?
            var gesture = ConversationCameraPullGesture()
            var cameraOpens = 0
            let harness = NativeOpeningHarness(
                onPositioned: {},
                onBegin: { geometry, distance in
                    admittedGeometry = geometry
                    admittedDistance = distance
                    gesture.begin(
                        isEligible: ConversationCameraPullPolicy.isEligible(
                            geometry: geometry, isSelectingMessages: false,
                            isSearchingMessages: false, hasVoiceNoteDraft: false,
                            isEditingMessage: false
                        ),
                        distanceFromLatest: distance
                    )
                },
                onProgress: { progress in
                    gesture.dragged(progress: progress)
                    _ = gesture.overscrolled(to: progress)
                },
                onCancel: { gesture.cancel() },
                onEnd: { cancelled in
                    if cancelled { gesture.cancel() }
                    if gesture.released() { cameraOpens += 1 }
                }
            )
            defer { harness.close() }
            harness.attach()
            await drainMainQueue()

            let pan = OpeningTestPan()
            harness.coordinator.panChanged(pan)
            XCTAssertEqual(admittedGeometry, expected,
                           "Admission must receive the native geometry of this exact pan")
            XCTAssertEqual(admittedDistance ?? .nan, 0, accuracy: 0.001)
            XCTAssertTrue(gesture.isTracking)

            pan.reportedState = .changed
            pan.reportedTranslation = CGPoint(x: 0, y: -150)
            harness.scroll.contentOffset.y = expected.bottomOffset + 59
            harness.coordinator.panChanged(pan)
            XCTAssertFalse(gesture.isArmed)
            harness.scroll.contentOffset.y = expected.bottomOffset + 60
            harness.coordinator.panChanged(pan)
            XCTAssertTrue(gesture.isArmed)
            XCTAssertEqual(cameraOpens, 0, "Crossing the threshold only arms the camera")

            pan.reportedState = .ended
            harness.coordinator.panChanged(pan)
            XCTAssertEqual(cameraOpens, 1)
            XCTAssertFalse(gesture.isTracking)
        }
    }

    func testCameraAdmissionRejectsEmptyNativeContentDespiteOldValidViewMeasurement() {
        var admittedGeometry: ConversationCameraPullGeometry? = .init(
            contentHeight: 1_000, viewportHeight: 600, viewportWidth: 320,
            topInset: 20, bottomInset: 50
        )
        let harness = NativeOpeningHarness(
            shouldKeepOpening: { false }, onPositioned: {},
            onBegin: { geometry, _ in admittedGeometry = geometry }
        )
        defer { harness.close() }
        harness.scroll.contentSize.height = 0
        harness.attach()
        harness.coordinator.panChanged(OpeningTestPan())

        XCTAssertEqual(admittedGeometry?.contentHeight, 0)
        XCTAssertFalse(ConversationCameraPullPolicy.isEligible(
            geometry: admittedGeometry, isSelectingMessages: false,
            isSearchingMessages: false, hasVoiceNoteDraft: false, isEditingMessage: false
        ))
    }

    func testNativeCameraPullCancelsForGeometryChangesBeforeProgressOrRelease() async {
        for change in 0 ..< 3 {
            for reportsChangeBeforeRelease in [true, false] {
                var progress: [CGFloat] = []
                var cancellations = 0
                var releases: [Bool] = []
                let harness = NativeOpeningHarness(
                    onPositioned: {}, onProgress: { progress.append($0) },
                    onCancel: { cancellations += 1 }, onEnd: { releases.append($0) }
                )
                defer { harness.close() }
                harness.attach()
                await drainMainQueue()
                let pan = OpeningTestPan()
                harness.coordinator.panChanged(pan)
                harness.scroll.contentOffset.y += 60
                pan.reportedState = .changed
                pan.reportedTranslation = CGPoint(x: 0, y: -150)
                harness.coordinator.panChanged(pan)
                XCTAssertEqual(progress, [60])

                switch change {
                case 0: harness.scroll.contentSize.height += 100
                case 1: harness.scroll.frame.size.height -= 100
                default: harness.scroll.contentInset.bottom += 20
                }
                if reportsChangeBeforeRelease { harness.coordinator.panChanged(pan) }
                pan.reportedState = .ended
                harness.coordinator.panChanged(pan)

                XCTAssertEqual(progress, [60], "Layout changes cannot count as finger travel")
                XCTAssertEqual(cancellations, reportsChangeBeforeRelease ? 1 : 0)
                XCTAssertEqual(releases, [true], "Even an armed drag must release as cancelled")
            }
        }
    }

    func testExactMessageNavigationBeforeQueuedPositioningWins() async {
        var allowsOpening = true
        var acknowledgements = 0
        let harness = NativeOpeningHarness(
            shouldKeepOpening: { allowsOpening },
            onPositioned: { acknowledgements += 1 }
        )
        defer { harness.close() }
        harness.attach()
        allowsOpening = false
        harness.scroll.contentOffset.y = 123

        await drainMainQueue()

        XCTAssertEqual(harness.scroll.contentOffset.y, 123, accuracy: 1)
        XCTAssertEqual(acknowledgements, 0)
    }

    func testNavigationChosenDuringNativeLayoutWinsBeforeOffsetMutation() async {
        var allowsOpening = true
        var acknowledgements = 0
        let harness = NativeOpeningHarness(
            shouldKeepOpening: { allowsOpening },
            onPositioned: { acknowledgements += 1 }
        )
        defer { harness.close() }
        harness.scroll.onNextLayout = { allowsOpening = false }
        harness.scroll.setNeedsLayout()
        harness.attach()

        await drainMainQueue()

        XCTAssertEqual(harness.scroll.contentOffset.y, 0, accuracy: 1)
        XCTAssertEqual(acknowledgements, 0)
    }

    func testPanBeginFencesQueuedWorkBeforeSwiftUIStateIsUpdated() async {
        var acknowledgements = 0
        let harness = NativeOpeningHarness(onPositioned: { acknowledgements += 1 })
        defer { harness.close() }
        harness.attach()
        // Leave the policy closure true to simulate SwiftUI not having rendered the touch yet.
        let pan = OpeningTestPan()
        harness.coordinator.panChanged(pan)
        pan.reportedState = .ended
        harness.coordinator.panChanged(pan)
        harness.scroll.contentOffset.y = 123
        await drainMainQueue()

        harness.scroll.contentSize.height = 1_240
        harness.attach()
        await drainMainQueue()
        XCTAssertEqual(harness.scroll.contentOffset.y, 123, accuracy: 1)
        XCTAssertEqual(acknowledgements, 0,
                       "Lifting the finger must not let a stale opening callback reclaim history")
    }

    func testDetachInvalidatesQueuedWorkAndRebindPositionsOnlyTheNewScrollView() async {
        var acknowledgements = 0
        let harness = NativeOpeningHarness(onPositioned: { acknowledgements += 1 })
        defer { harness.close() }
        harness.attach()
        harness.coordinator.detach()
        let replacement = UIScrollView(frame: harness.scroll.frame)
        replacement.contentInsetAdjustmentBehavior = .never
        replacement.contentSize = CGSize(width: 320, height: 1_500)
        harness.window.addSubview(replacement)
        replacement.addSubview(harness.probe)
        harness.coordinator.attach(from: harness.probe)

        await drainMainQueue()

        XCTAssertEqual(harness.scroll.contentOffset.y, 0, accuracy: 1)
        XCTAssertEqual(replacement.contentOffset.y, 900, accuracy: 1)
        XCTAssertGreaterThan(acknowledgements, 0)
    }

    func testConversationReplacementInvalidatesItsQueuedAcknowledgement() async {
        var oldAcknowledgements = 0
        var newAcknowledgements = 0
        let harness = NativeOpeningHarness(onPositioned: { oldAcknowledgements += 1 })
        defer { harness.close() }
        harness.attach()
        harness.coordinator.updateCallbacks(NativeOpeningHarness.reporter(
            conversationID: "other-chat", shouldKeepOpening: { true },
            onPositioned: { newAcknowledgements += 1 }
        ))
        harness.attach()

        await drainMainQueue()

        XCTAssertEqual(oldAcknowledgements, 0)
        XCTAssertGreaterThan(newAcknowledgements, 0)
        XCTAssertEqual(harness.scroll.contentOffset.y, 450, accuracy: 1)
    }

    func testRejectedNativeOffsetDoesNotClaimOpeningSuccess() async {
        var acknowledgements = 0
        let harness = NativeOpeningHarness(onPositioned: { acknowledgements += 1 })
        defer { harness.close() }
        harness.scroll.refusesOffset = true
        harness.attach()

        await drainMainQueue()

        XCTAssertEqual(harness.scroll.contentOffset.y, 0, accuracy: 1)
        XCTAssertEqual(acknowledgements, 0,
                       "An unobserved or ignored scroll request must leave opening unclaimed")
    }

    private func drainMainQueue() async {
        // Opening runs on the main queue. A second turn also drains geometry-triggered retries.
        for _ in 0 ..< 2 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}

@MainActor
private final class NativeOpeningHarness {
    let window: UIWindow
    let scroll: OpeningTestScrollView
    let probe: ConversationScrollPanReporter.Probe
    let coordinator: ConversationScrollPanReporter.Coordinator

    init(
        shouldKeepOpening: @escaping () -> Bool = { true },
        shouldFollowLayout: @escaping () -> Bool = { true },
        onPositioned: @escaping () -> Void,
        onGesture: @escaping () -> Void = {},
        onBegin: @escaping (ConversationCameraPullGeometry, CGFloat) -> Void = { _, _ in },
        onProgress: @escaping (CGFloat) -> Void = { _ in },
        onCancel: @escaping () -> Void = {},
        onEnd: @escaping (Bool) -> Void = { _ in }
    ) {
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
        scroll = OpeningTestScrollView(frame: window.bounds)
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.contentInset = UIEdgeInsets(top: 20, left: 0, bottom: 50, right: 0)
        scroll.contentSize = CGSize(width: 320, height: 1_000)
        scroll.contentOffset = .zero
        probe = ConversationScrollPanReporter.Probe(frame: CGRect(x: 0, y: 0, width: 320, height: 1))
        probe.isUserInteractionEnabled = false
        coordinator = ConversationScrollPanReporter.Coordinator(Self.reporter(
            conversationID: "direct-chat", shouldKeepOpening: shouldKeepOpening,
            shouldFollowLayout: shouldFollowLayout, onPositioned: onPositioned,
            onGesture: onGesture, onBegin: onBegin, onProgress: onProgress,
            onCancel: onCancel, onEnd: onEnd
        ))
        probe.coordinator = coordinator
        window.addSubview(scroll)
        scroll.addSubview(probe)
        window.isHidden = false
    }

    static func reporter(
        conversationID: String,
        shouldKeepOpening: @escaping () -> Bool,
        shouldFollowLayout: @escaping () -> Bool = { true },
        onPositioned: @escaping () -> Void,
        onGesture: @escaping () -> Void = {},
        onBegin: @escaping (ConversationCameraPullGeometry, CGFloat) -> Void = { _, _ in },
        onProgress: @escaping (CGFloat) -> Void = { _ in },
        onCancel: @escaping () -> Void = {},
        onEnd: @escaping (Bool) -> Void = { _ in }
    ) -> ConversationScrollPanReporter {
        ConversationScrollPanReporter(
            conversationID: conversationID, shouldKeepOpeningAtBottom: shouldKeepOpening,
            shouldFollowLayoutChanges: shouldFollowLayout,
            onOpeningPositioned: onPositioned,
            onBegin: { geometry, distance in onGesture(); onBegin(geometry, distance) },
            onProgress: { progress in onGesture(); onProgress(progress) },
            onCancel: { onGesture(); onCancel() },
            onEnd: { cancelled in onGesture(); onEnd(cancelled) }
        )
    }

    func attach() { coordinator.attach(from: probe) }
    func close() {
        coordinator.detach()
        window.isHidden = true
    }
}

@MainActor
private final class OpeningTestScrollView: UIScrollView {
    var refusesOffset = false
    var onNextLayout: (() -> Void)?

    override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
        if !refusesOffset { super.setContentOffset(contentOffset, animated: animated) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let callback = onNextLayout
        onNextLayout = nil
        callback?()
    }
}

@MainActor
private final class OpeningTestPan: UIPanGestureRecognizer {
    var reportedState: UIGestureRecognizer.State = .began
    var reportedTranslation: CGPoint = .zero
    override var state: UIGestureRecognizer.State {
        get { reportedState }
        set { reportedState = newValue }
    }

    override func translation(in view: UIView?) -> CGPoint { reportedTranslation }
}

final class ConversationInteractionPolicyTests: XCTestCase {
    private func message(
        _ body: String,
        pendingCaption: String? = nil,
        hasPendingAttachment: Bool = false
    ) -> LocalMessage {
        LocalMessage(
            id: UUID(),
            conversationId: "30000000-0000-0000-0000-000000000001",
            senderId: "10000000-0000-0000-0000-000000000001",
            body: body,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            sentAt: nil,
            state: .sent,
            failureReason: nil,
            isOutgoing: true,
            attachmentData: nil,
            pendingAttachment: hasPendingAttachment
                ? LocalPendingAttachment(mediaType: "image/jpeg", caption: pendingCaption)
                : nil
        )
    }

    func testSearchMatchesPlainTextCaseAndDiacriticInsensitively() {
        let hit = message("Chapati funds for Kampala")
        let miss = message("Completely unrelated")
        let ids = ConversationMessageSearchPolicy.matchingMessageIDs(
            query: "  KAMPALÁ ",
            messages: [hit, miss]
        )
        XCTAssertEqual(ids, [hit.id])
    }

    func testSearchIgnoresBlankQueriesAndPaymentDescriptors() {
        guard let descriptor = KitPaymentMessage(
            action: .request,
            paymentRequestId: "9c14e2c6-1f6a-4a6a-9f7e-6a1e2b3c4d5e",
            amountMinor: 1_000,
            currencyCode: "UGX",
            currencyScale: 2,
            note: "lunch"
        ) else {
            XCTFail("Canonical payment descriptor must construct")
            return
        }
        let payment = message(descriptor.encoded)
        XCTAssertEqual(
            ConversationMessageSearchPolicy.matchingMessageIDs(
                query: "   ",
                messages: [payment]
            ),
            []
        )
        XCTAssertNil(ConversationMessageSearchPolicy.searchableText(for: payment))
    }

    func testSearchReadsPendingAttachmentCaptions() {
        let pending = message("Photo", pendingCaption: "Quarterly report.pdf", hasPendingAttachment: true)
        let ids = ConversationMessageSearchPolicy.matchingMessageIDs(
            query: "quarterly",
            messages: [pending]
        )
        XCTAssertEqual(ids, [pending.id])
    }

    func testSearchResultsStayChronological() {
        let first = message("alpha budget")
        let second = message("beta budget")
        let ids = ConversationMessageSearchPolicy.matchingMessageIDs(
            query: "budget",
            messages: [first, second]
        )
        XCTAssertEqual(ids, [first.id, second.id])
    }

    func testCameraPullThresholdsAreOrdered() {
        XCTAssertGreaterThan(
            ConversationCameraPullPolicy.triggerDistance,
            ConversationCameraPullPolicy.nearLatestDistance
        )
        XCTAssertGreaterThan(
            ConversationCameraPullPolicy.nearLatestDistance,
            ConversationCameraPullPolicy.bottomStartTolerance
        )
    }

    func testEveryOpenedConversationClaimsOneInitialJumpToItsNewestMessage() {
        var policy = ConversationLatestPositionPolicy()

        XCTAssertFalse(policy.claimOpening(
            conversationID: "direct-chat",
            hasTimelineContent: false
        ))
        XCTAssertNil(
            policy.positionedConversationID,
            "An empty shell must leave the opening jump available for restored inbound history"
        )
        XCTAssertTrue(policy.claimOpening(
            conversationID: "direct-chat",
            hasTimelineContent: true
        ))
        XCTAssertTrue(policy.hasPositioned(conversationID: "DIRECT-CHAT"))
        XCTAssertFalse(
            policy.claimOpening(
                conversationID: "DIRECT-CHAT",
                hasTimelineContent: true
            ),
            "A redraw of the same one-to-one chat must not keep stealing the reading position"
        )
        XCTAssertTrue(
            policy.claimOpening(
                conversationID: "group-chat",
                hasTimelineContent: true
            ),
            "Opening a group must independently position its newest sent or received message"
        )
    }

    func testOpeningJumpWaitsUntilTimelineAndViewportHaveRealLayout() {
        XCTAssertFalse(ConversationLatestPositionPolicy.openingLayoutIsReady(
            hasTimelineContent: false,
            contentHeight: 900,
            viewportHeight: 700
        ))
        XCTAssertFalse(ConversationLatestPositionPolicy.openingLayoutIsReady(
            hasTimelineContent: true,
            contentHeight: 0,
            viewportHeight: 700
        ))
        XCTAssertFalse(ConversationLatestPositionPolicy.openingLayoutIsReady(
            hasTimelineContent: true,
            contentHeight: 900,
            viewportHeight: 0
        ))
        XCTAssertFalse(ConversationLatestPositionPolicy.openingLayoutIsReady(
            hasTimelineContent: true,
            contentHeight: .infinity,
            viewportHeight: 700
        ))
        XCTAssertTrue(ConversationLatestPositionPolicy.openingLayoutIsReady(
            hasTimelineContent: true,
            contentHeight: 900,
            viewportHeight: 700
        ))
    }

    func testNativeOpeningAnchorWaitsForContentAndYieldsToExplicitUserIntent() {
        for conversationID in ["direct-chat", "group-chat"] {
            var policy = ConversationLatestPositionPolicy()
            XCTAssertFalse(policy.shouldApplyNativeOpeningAnchor(
                conversationID: conversationID, hasTimelineContent: false,
                hasExplicitTarget: false, isInteracting: false
            ))
            XCTAssertFalse(policy.shouldApplyNativeOpeningAnchor(
                conversationID: conversationID, hasTimelineContent: true,
                hasExplicitTarget: true, isInteracting: false
            ))
            XCTAssertFalse(policy.shouldApplyNativeOpeningAnchor(
                conversationID: conversationID, hasTimelineContent: true,
                hasExplicitTarget: false, isInteracting: true
            ))
            XCTAssertTrue(policy.shouldApplyNativeOpeningAnchor(
                conversationID: conversationID, hasTimelineContent: true,
                hasExplicitTarget: false, isInteracting: false
            ), "Native positioning must run before the opening has been acknowledged")
            XCTAssertTrue(policy.claimOpening(conversationID: conversationID))
            XCTAssertFalse(policy.shouldApplyNativeOpeningAnchor(
                conversationID: conversationID.uppercased(), hasTimelineContent: true,
                hasExplicitTarget: false, isInteracting: false
            ), "A native acknowledgement ends unconditional opening ownership")

            policy.userDidChoosePosition(conversationID: conversationID)
            XCTAssertFalse(policy.shouldApplyNativeOpeningAnchor(
                conversationID: conversationID, hasTimelineContent: true,
                hasExplicitTarget: false, isInteracting: false
            ), "Lifting a finger or clearing an exact target cannot restart the opening anchor")
        }
    }

    func testUserPositionBeforeFirstLayoutCancelsTheOpeningJump() {
        for conversationID in ["direct-chat", "group-chat"] {
            var policy = ConversationLatestPositionPolicy()
            policy.userDidChoosePosition(conversationID: conversationID)

            XCTAssertFalse(policy.claimOpening(
                conversationID: conversationID.uppercased(), hasTimelineContent: true
            ), "A completed drag or exact-message jump must survive the first real layout")
            XCTAssertFalse(policy.shouldApplyNativeOpeningAnchor(
                conversationID: conversationID, hasTimelineContent: true,
                hasExplicitTarget: false, isInteracting: false
            ), "Clearing a navigation target or lifting the finger cannot resurrect opening")
            XCTAssertTrue(policy.hasPositioned(conversationID: conversationID))
            XCTAssertTrue(policy.claimOpening(conversationID: "other-chat"))
        }
    }

    func testOnlyOwnSendsRequestAnExplicitTimelineJump() {
        XCTAssertFalse(ConversationLatestPositionPolicy.shouldFollowOutgoingMessage(
            hasPositionedCurrentConversation: false, latestMessageIsOutgoing: true
        ), "Native opening exclusively owns the initially hydrated timeline")
        XCTAssertTrue(ConversationLatestPositionPolicy.shouldFollowOutgoingMessage(
            hasPositionedCurrentConversation: true, latestMessageIsOutgoing: true
        ))
        XCTAssertFalse(ConversationLatestPositionPolicy.shouldFollowOutgoingMessage(
            hasPositionedCurrentConversation: true, latestMessageIsOutgoing: false
        ), "Incoming rows and hydration follow prior native position, not stale SwiftUI metrics")
        XCTAssertFalse(ConversationLatestPositionPolicy.shouldFollowOutgoingMessage(
            hasPositionedCurrentConversation: true, latestMessageIsOutgoing: true,
            isInteracting: true
        ))
        XCTAssertFalse(ConversationLatestPositionPolicy.shouldFollowOutgoingMessage(
            hasPositionedCurrentConversation: true, latestMessageIsOutgoing: true,
            hasExplicitTarget: true
        ))
    }

    func testCameraPullEligibilityAcceptsShortIdleTimelines() {
        let long = ConversationCameraPullGeometry(
            contentHeight: 700, viewportHeight: 600, viewportWidth: 320,
            topInset: 20, bottomInset: 50
        )
        let short = ConversationCameraPullGeometry(
            contentHeight: 500, viewportHeight: 600, viewportWidth: 320,
            topInset: 20, bottomInset: 50
        )
        XCTAssertTrue(ConversationCameraPullPolicy.isEligible(
            geometry: long,
            isSelectingMessages: false,
            isSearchingMessages: false,
            hasVoiceNoteDraft: false,
            isEditingMessage: false
        ))

        XCTAssertTrue(ConversationCameraPullPolicy.isEligible(
            geometry: short,
            isSelectingMessages: false,
            isSearchingMessages: false,
            hasVoiceNoteDraft: false,
            isEditingMessage: false
        ), "A nonempty short timeline must offer the same deliberate bottom pull")
        XCTAssertFalse(ConversationCameraPullPolicy.isEligible(
            geometry: long,
            isSelectingMessages: true,
            isSearchingMessages: false,
            hasVoiceNoteDraft: false,
            isEditingMessage: false
        ), "Message selection must own the conversation gesture")
        XCTAssertFalse(ConversationCameraPullPolicy.isEligible(
            geometry: long,
            isSelectingMessages: false,
            isSearchingMessages: true,
            hasVoiceNoteDraft: false,
            isEditingMessage: false
        ), "Search must not advertise or open the camera")
        XCTAssertFalse(ConversationCameraPullPolicy.isEligible(
            geometry: long,
            isSelectingMessages: false,
            isSearchingMessages: false,
            hasVoiceNoteDraft: true,
            isEditingMessage: false
        ), "Recording, paused and previewing voice drafts must retain the exclusive composer")
        XCTAssertFalse(ConversationCameraPullPolicy.isEligible(
            geometry: long,
            isSelectingMessages: false,
            isSearchingMessages: false,
            hasVoiceNoteDraft: false,
            isEditingMessage: true
        ), "Message editing must suppress camera pull even after the keyboard is dismissed")
    }

    func testCameraAdmissionRequiresCompleteFiniteNativeGeometry() {
        let invalid: [ConversationCameraPullGeometry?] = [
            nil,
            .init(contentHeight: 0, viewportHeight: 600, viewportWidth: 320,
                  topInset: 20, bottomInset: 50),
            .init(contentHeight: .nan, viewportHeight: 600, viewportWidth: 320,
                  topInset: 20, bottomInset: 50),
            .init(contentHeight: 700, viewportHeight: 0, viewportWidth: 320,
                  topInset: 20, bottomInset: 50),
            .init(contentHeight: 700, viewportHeight: .infinity, viewportWidth: 320,
                  topInset: 20, bottomInset: 50),
            .init(contentHeight: 700, viewportHeight: 600, viewportWidth: 0,
                  topInset: 20, bottomInset: 50),
            .init(contentHeight: 700, viewportHeight: 600, viewportWidth: .nan,
                  topInset: 20, bottomInset: 50),
            .init(contentHeight: 700, viewportHeight: 600, viewportWidth: 320,
                  topInset: .nan, bottomInset: 50),
            .init(contentHeight: 700, viewportHeight: 600, viewportWidth: 320,
                  topInset: 20, bottomInset: .infinity),
        ]
        for geometry in invalid {
            XCTAssertFalse(ConversationCameraPullPolicy.isEligible(
                geometry: geometry, isSelectingMessages: false,
                isSearchingMessages: false, hasVoiceNoteDraft: false, isEditingMessage: false
            ))
        }
    }

    func testCameraOpensOnTheReleaseTheIndicatorPromisesAndNotMidDrag() {
        var gesture = ConversationCameraPullGesture()
        gesture.begin(isEligible: true, distanceFromLatest: 0)
        let trigger = ConversationCameraPullPolicy.triggerDistance

        XCTAssertFalse(gesture.overscrolled(to: trigger - 1))
        XCTAssertFalse(gesture.isArmed, "Short of the threshold nothing is promised")

        XCTAssertTrue(
            gesture.overscrolled(to: trigger),
            "Crossing the threshold is the one moment the haptic fires"
        )
        XCTAssertTrue(gesture.isArmed, "The indicator now reads Release for camera")
        XCTAssertFalse(
            gesture.overscrolled(to: trigger + 40),
            "Pulling further must not fire the haptic again"
        )
        XCTAssertTrue(gesture.isArmed, "Still only armed — the finger has not come up")

        XCTAssertTrue(gesture.released(), "The release is what opens the camera")
        XCTAssertFalse(gesture.isArmed)
    }

    func testAPullTakenBackBeforeReleasingDoesNotOpenTheCamera() {
        var gesture = ConversationCameraPullGesture()
        gesture.begin(isEligible: true, distanceFromLatest: 0)
        _ = gesture.overscrolled(to: ConversationCameraPullPolicy.triggerDistance)
        XCTAssertTrue(gesture.isArmed)

        gesture.dragged(progress: ConversationCameraPullPolicy.triggerDistance - 1)
        XCTAssertFalse(gesture.isArmed, "Retracting below the trigger must restore the pull-further hint")

        gesture.dragged(progress: 0)
        XCTAssertFalse(gesture.isArmed)
        XCTAssertFalse(gesture.released(), "Pulled all the way back: nothing should open")
    }

    func testTheBounceBackToRestCannotSwallowAnArmedRelease() {
        // The release and the bounce that follows it both drive the overscroll to zero. Only the
        // drag may disarm, so the order of those two events cannot decide whether the camera opens.
        var gesture = ConversationCameraPullGesture()
        gesture.begin(isEligible: true, distanceFromLatest: 0)
        _ = gesture.overscrolled(to: ConversationCameraPullPolicy.triggerDistance + 30)
        XCTAssertFalse(
            gesture.overscrolled(to: 0),
            "Settling back to rest is not a gesture the customer made"
        )
        XCTAssertTrue(gesture.isArmed)
        XCTAssertTrue(gesture.released())
    }

    func testAnArmedPullLeftOverFromACancelledGestureIsDroppedAtTheNextDrag() {
        var gesture = ConversationCameraPullGesture()
        gesture.begin(isEligible: true, distanceFromLatest: 0)
        _ = gesture.overscrolled(to: ConversationCameraPullPolicy.triggerDistance)
        XCTAssertTrue(gesture.isArmed)

        // A new drag starts from rest, so a stale arm can never survive into it and open the
        // camera on a release the customer never associated with the camera.
        gesture.dragged(progress: 0)
        XCTAssertFalse(gesture.released())
    }

    func testLeavingTheGestureBehindDisarmsIt() {
        var gesture = ConversationCameraPullGesture()
        gesture.begin(isEligible: true, distanceFromLatest: 0)
        _ = gesture.overscrolled(to: ConversationCameraPullPolicy.triggerDistance)
        gesture.cancel()
        XCTAssertFalse(gesture.isArmed)
        XCTAssertFalse(gesture.released())
    }

    func testLayoutAndProgrammaticOffsetsCannotArmWithoutABottomUserDrag() {
        var gesture = ConversationCameraPullGesture()
        let threshold = ConversationCameraPullPolicy.triggerDistance
        XCTAssertFalse(gesture.overscrolled(to: threshold * 2))
        XCTAssertFalse(gesture.released())

        gesture.begin(isEligible: false, distanceFromLatest: 0)
        XCTAssertFalse(gesture.overscrolled(to: threshold * 2))
        XCTAssertFalse(gesture.released())

        gesture.begin(isEligible: true, distanceFromLatest: 150)
        XCTAssertFalse(gesture.overscrolled(to: threshold * 2),
                       "A normal scroll reaching the bottom midway cannot become a camera pull")
        XCTAssertFalse(gesture.released())

        gesture.begin(isEligible: true, distanceFromLatest: 0)
        XCTAssertTrue(gesture.overscrolled(to: threshold))
        gesture.cancel() // Keyboard/layout change, navigation, cancellation, or background.
        XCTAssertFalse(gesture.overscrolled(to: threshold * 2),
                       "A canceled drag must start a fresh gesture before it can arm again")
        XCTAssertFalse(gesture.released())
    }

    func testCameraPullRetractsAndHapticsOnlyOncePerDrag() {
        var gesture = ConversationCameraPullGesture()
        let threshold = ConversationCameraPullPolicy.triggerDistance
        gesture.begin(isEligible: true, distanceFromLatest: 0)
        XCTAssertTrue(gesture.overscrolled(to: threshold))
        gesture.dragged(progress: threshold - 1)
        XCTAssertFalse(gesture.isArmed)
        XCTAssertFalse(gesture.overscrolled(to: threshold),
                       "Re-crossing in the same drag must not repeat haptics or announcements")
        XCTAssertTrue(gesture.isArmed)
        XCTAssertTrue(gesture.released())
        XCTAssertFalse(gesture.released(), "A release is consumed exactly once")

        gesture.begin(isEligible: true, distanceFromLatest: 0)
        XCTAssertTrue(gesture.overscrolled(to: threshold), "The next drag has its own haptic")
        gesture.dragged(progress: threshold - 1)
        XCTAssertFalse(gesture.released(), "Releasing below the visible threshold never opens")
    }

    func testCameraPullRejectsInvalidGeometryAndCalculatesShortChatBottom() {
        var gesture = ConversationCameraPullGesture()
        for distance in [CGFloat.nan, .infinity, -1] {
            gesture.begin(isEligible: true, distanceFromLatest: distance)
            XCTAssertFalse(gesture.overscrolled(to: 120))
            XCTAssertFalse(gesture.released())
        }
        gesture.begin(isEligible: true, distanceFromLatest: 0)
        XCTAssertFalse(gesture.overscrolled(to: .infinity))
        gesture.dragged(progress: .nan)
        XCTAssertFalse(gesture.isTracking)

        let short = ConversationCameraPullGeometry(
            contentHeight: 200, viewportHeight: 600, viewportWidth: 320,
            topInset: 40, bottomInset: 20
        )
        XCTAssertEqual(short.bottomOffset, -40,
                       "A short chat bounces from its resting offset, not a negative content gap")
        let long = ConversationCameraPullGeometry(
            contentHeight: 1000, viewportHeight: 600, viewportWidth: 320,
            topInset: 40, bottomInset: 20
        )
        XCTAssertEqual(long.bottomOffset, 420, "Bottom safe-area/composer insets count toward rest")
    }

    func testAttachmentStagingCapAllowsAlbums() {
        XCTAssertGreaterThanOrEqual(
            ConversationAttachmentStagingPolicy.maximumStagedAttachments,
            5
        )
    }

    func testGroupPickerExcludesSelfBlockedAndDuplicateContacts() {
        let currentUserID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        let allowedUserID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let blockedUserID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let contacts = [
            contact(id: currentUserID, name: "Me"),
            contact(id: allowedUserID, name: "Allowed"),
            contact(id: allowedUserID.uppercased(), name: "Allowed duplicate"),
            contact(id: blockedUserID, name: "Blocked"),
        ]

        let eligible = GroupCreatePolicy.eligibleContacts(
            contacts,
            currentUserID: currentUserID,
            allowsOutbound: { $0 != blockedUserID }
        )

        XCTAssertEqual(eligible.map(\.name), ["Allowed"])
    }

    func testGroupPolicyMatchesServerMemberAndUnicodeScalarBounds() {
        XCTAssertEqual(SecureMessagingWire.maximumGroupMembers, 32)
        XCTAssertEqual(GroupCreatePolicy.minimumMembers, 1)
        XCTAssertEqual(GroupCreatePolicy.maximumMembers, 31)
        XCTAssertTrue(GroupCreatePolicy.isValidName("A"))
        XCTAssertTrue(GroupCreatePolicy.isValidName(String(repeating: "🟢", count: 30)))
        XCTAssertFalse(GroupCreatePolicy.isValidName(String(repeating: "🟢", count: 31)))
        XCTAssertFalse(GroupCreatePolicy.isValidName("   "))

        let combining = String(repeating: "e\u{301}", count: 33)
        XCTAssertEqual(combining.count, 33)
        XCTAssertEqual(combining.unicodeScalars.count, 66)
        XCTAssertEqual(combining.utf8.count, 99)
        XCTAssertFalse(GroupCreatePolicy.isValidName(combining))
    }

    private func contact(id: String, name: String) -> WalletContactDTO {
        WalletContactDTO(
            id: id,
            contactId: nil,
            name: name,
            phone: "+256700000000",
            isKitUser: true,
            favorite: false,
            status: nil,
            tag: nil,
            avatarURL: nil,
            receivingWalletId: nil
        )
    }
}
