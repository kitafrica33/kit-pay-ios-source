import Combine
import XCTest
@testable import KitPay

@MainActor
final class CallScreenSharingTests: XCTestCase {
    func testSystemConsentIsRequiredBeforePublishingAndStoppingRetiresTrack() async throws {
        let harness = Harness()
        let publisher = Publisher()
        harness.controller.bind(publisher: publisher, callID: "call-a")
        try harness.controller.requestStart(callID: "CALL-A", applicationIsActive: true)
        await drain()
        XCTAssertEqual(harness.activations, 1)
        XCTAssertEqual(publisher.starts, 0)
        XCTAssertEqual(harness.controller.phase, .awaitingApproval)

        await drain()
        harness.broadcast(true)
        await drain()
        XCTAssertEqual(publisher.starts, 0)
        XCTAssertEqual(harness.controller.phase, .awaitingConfirmation)
        try harness.controller.confirmSharing(callID: "call-a")
        await drain()
        XCTAssertEqual(publisher.starts, 1)
        XCTAssertEqual(harness.controller.phase, .sharing)

        harness.broadcast(false)
        await drain()
        XCTAssertEqual(publisher.stops, 1)
        XCTAssertEqual(harness.controller.phase, .idle)
    }

    func testLateApprovalAfterHangupCannotPublishIntoReplacementCall() async throws {
        let harness = Harness()
        let first = Publisher()
        let replacement = Publisher()
        harness.controller.bind(publisher: first, callID: "first")
        try harness.controller.requestStart(callID: "first", applicationIsActive: true)
        harness.controller.unbind()
        harness.controller.bind(publisher: replacement, callID: "replacement")
        await drain()
        await drain()
        harness.broadcast(true)
        await drain()

        XCTAssertEqual(first.starts, 0)
        XCTAssertEqual(replacement.starts, 0)
        XCTAssertGreaterThan(harness.stopRequests, 0)
        XCTAssertNotEqual(harness.controller.phase, .sharing)
        harness.broadcast(false)
    }

    func testStopDuringPublicationWaitsForOldTrackBeforeAllowingAnotherShare() async throws {
        let harness = Harness()
        let publisher = Publisher()
        publisher.suspendsStart = true
        harness.controller.bind(publisher: publisher, callID: "call")
        try harness.controller.requestStart(callID: "call", applicationIsActive: true)
        await drain()
        harness.broadcast(true)
        await drain()
        try harness.controller.confirmSharing(callID: "call")
        await drain()
        XCTAssertEqual(harness.controller.phase, .starting)

        harness.controller.stop()
        harness.broadcast(false)
        await drain()
        XCTAssertEqual(harness.controller.phase, .stopping)
        XCTAssertThrowsError(try harness.controller.requestStart(callID: "call", applicationIsActive: true))
        publisher.completeStart()
        await drain()
        XCTAssertEqual(publisher.stops, 1)
        XCTAssertEqual(harness.controller.phase, .idle)
        XCTAssertEqual(publisher.starts, 1)
    }

    func testHangupBeforeConfirmedTaskRunsNeverStartsCapture() async throws {
        let harness = Harness()
        let publisher = Publisher()
        harness.controller.bind(publisher: publisher, callID: "call")
        try harness.controller.requestStart(callID: "call", applicationIsActive: true)
        harness.broadcast(true)
        await drain()
        try harness.controller.confirmSharing(callID: "call")
        harness.controller.unbind()
        harness.broadcast(false)
        await drain()
        XCTAssertEqual(publisher.starts, 0)
        XCTAssertEqual(harness.controller.phase, .idle)
    }

    func testCancelingSystemPickerNeverStartsCapture() async throws {
        let harness = Harness()
        let publisher = Publisher()
        harness.controller.bind(publisher: publisher, callID: "call")
        try harness.controller.requestStart(callID: "call", applicationIsActive: true)
        harness.controller.stop()
        await drain()
        XCTAssertEqual(publisher.starts, 0)
        XCTAssertEqual(harness.controller.phase, .idle)
    }

    func testPublicationFailureStopsBroadcastAndReportsAnError() async throws {
        let harness = Harness()
        let publisher = Publisher()
        publisher.failsStart = true
        var failures = 0
        harness.controller.onError = { _ in failures += 1 }
        harness.controller.bind(publisher: publisher, callID: "call")
        try harness.controller.requestStart(callID: "call", applicationIsActive: true)
        await drain()
        harness.broadcast(true)
        await drain()
        try harness.controller.confirmSharing(callID: "call")
        await drain()
        XCTAssertEqual(failures, 1)
        XCTAssertGreaterThan(harness.stopRequests, 0)
        XCTAssertNotEqual(harness.controller.phase, .sharing)
        harness.broadcast(false)
        await drain()
        XCTAssertEqual(publisher.stops, 1)
        XCTAssertEqual(harness.controller.phase, .idle)
    }

    func testBackgroundWrongCallAndDisconnectedRoomCannotRequestCapture() throws {
        let harness = Harness()
        let publisher = Publisher()
        harness.controller.bind(publisher: publisher, callID: "call")
        XCTAssertThrowsError(try harness.controller.requestStart(callID: "call", applicationIsActive: false))
        XCTAssertThrowsError(try harness.controller.requestStart(callID: "other", applicationIsActive: true))
        publisher.isConnected = false
        XCTAssertThrowsError(try harness.controller.requestStart(callID: "call", applicationIsActive: true))
        XCTAssertEqual(harness.activations, 0)
    }

    func testReplacingRoomRequiresFreshScreenSharingConsent() async throws {
        let harness = Harness()
        let old = Publisher()
        let replacement = Publisher()
        harness.controller.bind(publisher: old, callID: "call")
        try harness.controller.requestStart(callID: "call", applicationIsActive: true)
        await drain()
        harness.broadcast(true)
        await drain()
        try harness.controller.confirmSharing(callID: "call")
        await drain()
        harness.controller.bind(publisher: replacement, callID: "call")
        harness.broadcast(false)
        await drain()
        XCTAssertEqual(old.stops, 1)
        XCTAssertEqual(replacement.starts, 0)
        XCTAssertEqual(harness.controller.phase, .idle)
    }

    func testOldSystemGrantCannotPublishIntoNewRequestWithoutNamedCallConfirmation() async throws {
        let harness = Harness()
        let old = Publisher()
        let replacement = Publisher()
        harness.controller.bind(publisher: old, callID: "old")
        try harness.controller.requestStart(callID: "old", applicationIsActive: true)
        await drain()
        harness.controller.unbind()
        harness.controller.bind(publisher: replacement, callID: "new")
        await drain()
        try harness.controller.requestStart(callID: "new", applicationIsActive: true)
        await drain()
        harness.broadcast(true) // A late, globally scoped ReplayKit grant from the old picker.
        await drain()
        XCTAssertEqual(old.starts, 0)
        XCTAssertEqual(replacement.starts, 0)
        XCTAssertThrowsError(try harness.controller.confirmSharing(callID: "old"))
        try harness.controller.confirmSharing(callID: "new")
        await drain()
        XCTAssertEqual(replacement.starts, 1, "Only a fresh post-grant action naming the current call may publish")
        harness.broadcast(false)
        await drain()
    }

    func testDisconnectBeforeSystemApprovalRetiresIntentImmediately() async throws {
        let harness = Harness()
        let publisher = Publisher()
        harness.controller.bind(publisher: publisher, callID: "call")
        try harness.controller.requestStart(callID: "call", applicationIsActive: true)
        await drain()
        publisher.isConnected = false
        harness.broadcast(true)
        await drain()
        harness.broadcast(false)
        await drain()
        XCTAssertEqual(publisher.starts, 0)
        XCTAssertEqual(harness.controller.phase, .idle)
        XCTAssertThrowsError(try harness.controller.confirmSharing(callID: "call"))
    }

    func testReplacementDuringSuspendedPublicationRetiresOnlyTheOldRoom() async throws {
        let harness = Harness()
        let old = Publisher()
        old.suspendsStart = true
        let replacement = Publisher()
        harness.controller.bind(publisher: old, callID: "old")
        try harness.controller.requestStart(callID: "old", applicationIsActive: true)
        await drain()
        harness.broadcast(true)
        await drain()
        try harness.controller.confirmSharing(callID: "old")
        await drain()
        harness.controller.bind(publisher: replacement, callID: "new")
        harness.broadcast(false)
        old.completeStart()
        await drain()
        XCTAssertEqual(old.stops, 1)
        XCTAssertEqual(replacement.starts, 0)
        XCTAssertEqual(replacement.stops, 0)
        XCTAssertEqual(harness.controller.phase, .idle)
    }

    func testScreenOnlyCallIsReportedAsVideoWithoutEnablingCamera() {
        XCTAssertTrue(CallVideoStatePolicy.carriesVideo(
            originalCallWasVideo: false, localCameraEnabled: false,
            remoteVideoAvailable: false, localScreenSharing: true
        ))
    }

    func testBannerControlsClearRealNotchInsetsWithoutReservingTheNotchTwice() {
        let container = CGRect(x: 0, y: 0, width: 393, height: 852)
        for inset: CGFloat in [0, 20, 47, 59, 62] {
            let frame = CallBannerMetrics.contentFrame(container: container, topInset: inset)
            XCTAssertEqual(frame.minY, inset)
            XCTAssertEqual(frame.height, 56)
            XCTAssertEqual(frame.maxY, inset + CallBannerMetrics.contentHeight)
        }
    }

    private func drain() async {
        for _ in 0..<6 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    @MainActor
    private final class Harness {
        let events = CurrentValueSubject<Bool, Never>(false)
        var activations = 0
        var stopRequests = 0
        lazy var controller = CallScreenSharingController(
            events: events.eraseToAnyPublisher(),
            isBroadcasting: { [unowned self] in events.value },
            requestActivation: { [unowned self] in activations += 1 },
            requestStop: { [unowned self] in stopRequests += 1 }
        )
        func broadcast(_ active: Bool) { events.send(active) }
    }

    @MainActor
    private final class Publisher: CallScreenSharePublishing {
        var isConnected = true
        var starts = 0
        var stops = 0
        var suspendsStart = false
        var failsStart = false
        var startContinuation: CheckedContinuation<Void, Never>?

        func startScreenSharing() async throws {
            starts += 1
            if failsStart { throw CallScreenSharingError.publicationFailed }
            if suspendsStart {
                await withCheckedContinuation { startContinuation = $0 }
            }
        }
        func stopScreenSharing() async { stops += 1 }
        func completeStart() {
            startContinuation?.resume()
            startContinuation = nil
        }
    }
}
