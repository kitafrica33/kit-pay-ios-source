import XCTest
@testable import KitPay

/// Where a call's displayed duration counts from. The same answer arrives by up to three
/// routes — the accept response, the socket frame, and the push — each under-reporting by
/// its own transit delay, so the earliest server anchor is both the closest estimate and
/// the reason the displayed duration only ever moves forward.
final class CallDurationAnchorTests: XCTestCase {
    private let callID = "a3b3c3d3-e3f3-4333-8333-333333333333"
    private let otherCallID = "44444444-4444-4444-8444-444444444444"

    func testServerSignalAnchorsAtTheCallsAgeOnTheServersClock() throws {
        let anchor = CallDurationAnchorPolicy.anchor(
            signal: try signal(answeredAt: "2026-08-27T09:15:00Z", serverTime: "2026-08-27T09:15:06Z"),
            monotonicNow: 1_000,
            previous: nil
        )

        XCTAssertEqual(anchor.callId, callID)
        // Six seconds old when the server stamped it, so the origin sits six back.
        XCTAssertEqual(anchor.monotonicOrigin, 994)
        XCTAssertTrue(anchor.serverAuthoritative)
        XCTAssertEqual(CallDurationAnchorPolicy.seconds(anchor, monotonicNow: 1_000), 6)
        XCTAssertEqual(CallDurationAnchorPolicy.seconds(anchor, monotonicNow: 1_001.5), 7)
    }

    func testServerAnchorReplacesTheLocalOneAndCorrectsTheTimerForward() throws {
        // Media connected first: the timer starts counting from receipt.
        let local = CallDurationAnchorPolicy.anchorOnConnect(
            callId: callID,
            monotonicNow: 500,
            previous: nil
        )
        XCTAssertFalse(local.serverAuthoritative)
        XCTAssertEqual(CallDurationAnchorPolicy.seconds(local, monotonicNow: 501), 1)

        // The authoritative signal lands a moment later and says the call is older.
        let corrected = CallDurationAnchorPolicy.anchor(
            signal: try signal(answeredAt: "2026-08-27T09:15:00Z", serverTime: "2026-08-27T09:15:06Z"),
            monotonicNow: 501,
            previous: local
        )
        XCTAssertTrue(corrected.serverAuthoritative)
        XCTAssertEqual(CallDurationAnchorPolicy.seconds(corrected, monotonicNow: 501), 6)
    }

    func testRepeatedServerSignalsConvergeOnTheEarliestOrigin() throws {
        let first = CallDurationAnchorPolicy.anchor(
            signal: try signal(answeredAt: "2026-08-27T09:15:00Z", serverTime: "2026-08-27T09:15:06Z"),
            monotonicNow: 1_000,
            previous: nil
        )
        // The duplicate from the slower route claims a smaller age, so a later origin.
        let duplicate = CallDurationAnchorPolicy.anchor(
            signal: try signal(answeredAt: "2026-08-27T09:15:00Z", serverTime: "2026-08-27T09:15:03Z"),
            monotonicNow: 1_000,
            previous: first
        )

        // The earlier origin wins: the displayed duration never moves backward.
        XCTAssertEqual(duplicate, first)
    }

    func testAnEarlierServerSignalStillCorrectsALaterOne() throws {
        let late = CallDurationAnchorPolicy.anchor(
            signal: try signal(answeredAt: "2026-08-27T09:15:00Z", serverTime: "2026-08-27T09:15:01Z"),
            monotonicNow: 1_000,
            previous: nil
        )
        let earlier = CallDurationAnchorPolicy.anchor(
            signal: try signal(answeredAt: "2026-08-27T09:15:00Z", serverTime: "2026-08-27T09:15:09Z"),
            monotonicNow: 1_000,
            previous: late
        )

        XCTAssertEqual(earlier.monotonicOrigin, 991)
    }

    func testAnchorIsKeyedByCallSoAReplacementCallStartsFromNothing() throws {
        let previous = CallDurationAnchorPolicy.anchor(
            signal: try signal(answeredAt: "2026-08-27T09:15:00Z", serverTime: "2026-08-27T09:15:06Z"),
            monotonicNow: 1_000,
            previous: nil
        )
        let replacement = CallDurationAnchorPolicy.anchor(
            signal: try signal(
                callId: otherCallID,
                answeredAt: "2026-08-27T09:15:04Z",
                serverTime: "2026-08-27T09:15:05Z"
            ),
            monotonicNow: 2_000,
            previous: previous
        )

        XCTAssertEqual(replacement.callId, otherCallID)
        XCTAssertEqual(replacement.monotonicOrigin, 1_999)
    }

    func testConnectAnchorNeverResetsATimerAlreadyCounting() throws {
        let server = CallDurationAnchorPolicy.anchor(
            signal: try signal(answeredAt: "2026-08-27T09:15:00Z", serverTime: "2026-08-27T09:15:06Z"),
            monotonicNow: 1_000,
            previous: nil
        )

        // The remote participant joining later must not restart an anchored timer —
        // including across an SDK reconnect where presence flaps.
        XCTAssertEqual(
            CallDurationAnchorPolicy.anchorOnConnect(
                callId: callID,
                monotonicNow: 1_030,
                previous: server
            ),
            server
        )
        // But a different call's leftover anchor never leaks into this one.
        XCTAssertEqual(
            CallDurationAnchorPolicy.anchorOnConnect(
                callId: otherCallID,
                monotonicNow: 1_030,
                previous: server
            ).monotonicOrigin,
            1_030
        )
    }

    func testSecondsAreNeverNegativeAndAbsentAnchorReadsZero() {
        XCTAssertEqual(CallDurationAnchorPolicy.seconds(nil, monotonicNow: 1_000), 0)

        let anchor = CallDurationAnchorPolicy.anchorOnConnect(
            callId: callID,
            monotonicNow: 1_000,
            previous: nil
        )
        XCTAssertEqual(CallDurationAnchorPolicy.seconds(anchor, monotonicNow: 999), 0)
    }

    func testARefusedPairFallsBackToWhatIsAlreadyHeld() {
        // Only constructible in tests: the wire layer refuses such a pair before it can
        // become a signal. The policy still refuses to let it move an existing anchor.
        let forged = CallAnswerSignal(
            callId: callID,
            answeredAt: Date(timeIntervalSince1970: 0),
            serverTime: Date(timeIntervalSince1970: 100_000)
        )
        let held = CallDurationAnchorPolicy.anchorOnConnect(
            callId: callID,
            monotonicNow: 700,
            previous: nil
        )

        XCTAssertEqual(
            CallDurationAnchorPolicy.anchor(signal: forged, monotonicNow: 800, previous: held),
            held
        )
        // With nothing held, it degrades to anchoring at receipt rather than honouring
        // an age the server's own cap says is impossible.
        let fallback = CallDurationAnchorPolicy.anchor(
            signal: forged,
            monotonicNow: 800,
            previous: nil
        )
        XCTAssertEqual(fallback.monotonicOrigin, 800)
        XCTAssertFalse(fallback.serverAuthoritative)
    }

    private func signal(
        callId: String? = nil,
        answeredAt: String,
        serverTime: String
    ) throws -> CallAnswerSignal {
        try XCTUnwrap(CallAnswerSignalPolicy.signal(
            callId: callId ?? callID,
            answeredAt: answeredAt,
            serverTime: serverTime
        ))
    }
}
