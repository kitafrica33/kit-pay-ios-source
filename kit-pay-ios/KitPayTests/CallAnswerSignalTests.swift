import XCTest
@testable import KitPay

/// The admission rules for a "this call was answered" signal, and the proof that the socket
/// frame and the push are held to them equally. Acting on one silences a ringing device,
/// starts both call timers, and moves CallKit state, so anything that is not the shape the
/// server actually sends has to stop at the boundary rather than downstream.
final class CallAnswerSignalTests: XCTestCase {
    // Alphabetic hex digits on purpose: an all-digit id is its own uppercase, which would
    // make the normalisation assertions pass vacuously.
    private let callID = "a3b3c3d3-e3f3-4333-8333-333333333333"
    private let answeredAt = "2026-08-27T09:15:04Z"
    private let serverTime = "2026-08-27T09:15:05Z"

    // MARK: Policy

    func testCallIDIsAcceptedOnlyAsTheUUIDTheServerIssues() {
        XCTAssertEqual(CallAnswerSignalPolicy.callId(callID), callID)
        // Normalised, so the same call never presents as two different ids downstream.
        XCTAssertEqual(CallAnswerSignalPolicy.callId(callID.uppercased()), callID)

        XCTAssertNil(CallAnswerSignalPolicy.callId(nil))
        XCTAssertNil(CallAnswerSignalPolicy.callId(""))
        XCTAssertNil(CallAnswerSignalPolicy.callId("   "))
        XCTAssertNil(CallAnswerSignalPolicy.callId("not-a-uuid"))
        XCTAssertNil(CallAnswerSignalPolicy.callId(" \(callID) "))
        XCTAssertNil(CallAnswerSignalPolicy.callId(String(callID.dropLast())))
        XCTAssertNil(CallAnswerSignalPolicy.callId("../../calls/\(callID)"))
    }

    func testAgeWithinTheServersFourHourCapIsAccepted() throws {
        let answered = try XCTUnwrap(CallLifecyclePolicy.serverTimestamp("2026-08-27T05:15:05Z"))
        let sent = try XCTUnwrap(CallLifecyclePolicy.serverTimestamp("2026-08-27T09:15:05Z"))

        XCTAssertEqual(CallAnswerSignalPolicy.age(answeredAt: answered, serverTime: sent), 14_400)
        // One second beyond the cap describes a call that cannot still be running.
        XCTAssertNil(CallAnswerSignalPolicy.age(
            answeredAt: answered.addingTimeInterval(-1),
            serverTime: sent
        ))
    }

    func testSmallClockInversionIsOrdinaryAndLargeFutureSkewIsRefused() throws {
        let sent = try XCTUnwrap(CallLifecyclePolicy.serverTimestamp(serverTime))

        // Two processes, two clocks; a small inversion means "no time has passed".
        XCTAssertEqual(
            CallAnswerSignalPolicy.age(answeredAt: sent.addingTimeInterval(60), serverTime: sent),
            0
        )
        XCTAssertNil(
            CallAnswerSignalPolicy.age(answeredAt: sent.addingTimeInterval(61), serverTime: sent)
        )
    }

    func testTheRulesNeverConsultThisDevicesClock() throws {
        // A phone whose clock is years out must still take a genuine answer: every rule is
        // a comparison between the two server instants.
        let past = try XCTUnwrap(CallLifecyclePolicy.serverTimestamp("1999-01-01T00:00:00Z"))
        let future = try XCTUnwrap(CallLifecyclePolicy.serverTimestamp("2199-01-01T00:00:00Z"))

        XCTAssertEqual(
            CallAnswerSignalPolicy.age(
                answeredAt: past,
                serverTime: past.addingTimeInterval(1)
            ),
            1
        )
        XCTAssertEqual(
            CallAnswerSignalPolicy.age(
                answeredAt: future,
                serverTime: future.addingTimeInterval(1)
            ),
            1
        )
    }

    func testSignalRequiresACompleteValidPair() {
        XCTAssertNotNil(CallAnswerSignalPolicy.signal(
            callId: callID,
            answeredAt: answeredAt,
            serverTime: serverTime
        ))
        XCTAssertNil(CallAnswerSignalPolicy.signal(
            callId: callID,
            answeredAt: nil,
            serverTime: serverTime
        ))
        XCTAssertNil(CallAnswerSignalPolicy.signal(
            callId: callID,
            answeredAt: answeredAt,
            serverTime: "yesterday"
        ))
        XCTAssertNil(CallAnswerSignalPolicy.signal(
            callId: callID,
            answeredAt: "2026-08-20T09:15:05Z",
            serverTime: serverTime
        ))
        XCTAssertNil(CallAnswerSignalPolicy.signal(
            callId: "not-a-uuid",
            answeredAt: answeredAt,
            serverTime: serverTime
        ))
    }

    // MARK: Push route

    func testPushAnswerIsParsedAndNormalised() throws {
        let push = try XCTUnwrap(CallAnsweredPush(payload: pushPayload()))

        XCTAssertEqual(push.callId, callID)
        let signal = try XCTUnwrap(push.signal)
        XCTAssertEqual(signal.callId, callID)
        XCTAssertEqual(signal.answeredAt, CallLifecyclePolicy.serverTimestamp(answeredAt))
        XCTAssertEqual(signal.serverTime, CallLifecyclePolicy.serverTimestamp(serverTime))

        let uppercased = try XCTUnwrap(
            CallAnsweredPush(payload: pushPayload(callId: callID.uppercased()))
        )
        XCTAssertEqual(uppercased.callId, callID)
    }

    func testPushAnswerMustAnnounceTheActiveState() {
        XCTAssertNil(CallAnsweredPush(payload: pushPayload(state: "ringing")))
        XCTAssertNil(CallAnsweredPush(payload: pushPayload(state: "Active")))
        XCTAssertNil(CallAnsweredPush(payload: pushPayload(state: nil)))
        XCTAssertNil(CallAnsweredPush(payload: pushPayload(type: "call.ended")))
        XCTAssertNil(CallAnsweredPush(payload: pushPayload(callId: "not-a-uuid")))
        XCTAssertNil(CallAnsweredPush(payload: pushPayload(callId: String(callID.dropLast()))))
    }

    func testOlderServersPushWithoutInstantsStillAnswersButAnchorsNothing() throws {
        let push = try XCTUnwrap(
            CallAnsweredPush(payload: pushPayload(answeredAt: nil, serverTime: nil))
        )

        XCTAssertEqual(push.callId, callID)
        XCTAssertNil(push.signal)

        // A pair that is present but fails the rules also anchors nothing — the answer
        // itself still stands, because this route is authenticated by APNs and the server.
        let stale = try XCTUnwrap(
            CallAnsweredPush(payload: pushPayload(answeredAt: "2026-08-20T09:15:05Z"))
        )
        XCTAssertNil(stale.signal)
    }

    func testBothRoutesProduceTheSameSignal() throws {
        let fromPush = try XCTUnwrap(CallAnsweredPush(payload: pushPayload()).flatMap(\.signal))
        let frame = KitPusherCodec.decode(answeredFrameJSON())

        guard case .callAnswered(_, let fromSocket) = try XCTUnwrap(frame) else {
            return XCTFail("Expected a call-answered frame, got \(String(describing: frame))")
        }
        XCTAssertEqual(fromPush, fromSocket)
    }

    // MARK: Socket route

    func testCodecDecodesTheAnsweredFrame() throws {
        let frame = KitPusherCodec.decode(answeredFrameJSON())

        guard case .callAnswered(let channel, let signal) = try XCTUnwrap(frame) else {
            return XCTFail("Expected a call-answered frame, got \(String(describing: frame))")
        }
        XCTAssertEqual(channel, "private-kit.user.10000000-0000-4000-8000-000000000001")
        XCTAssertEqual(signal.callId, callID)
        XCTAssertEqual(signal.answeredAt, CallLifecyclePolicy.serverTimestamp(answeredAt))
        XCTAssertEqual(signal.serverTime, CallLifecyclePolicy.serverTimestamp(serverTime))
    }

    func testCodecDecodesTheStringEncodedAnsweredFrame() throws {
        // Reverb string-encodes application data; both encodings must land identically.
        let json = #"{"event":"kit.call.answered","channel":"private-kit.user.10000000-0000-4000-8000-000000000001","data":"{\"v\":1,\"call_id\":\"a3b3c3d3-e3f3-4333-8333-333333333333\",\"state\":\"active\",\"answered_at\":\"2026-08-27T09:15:04Z\",\"answered_by\":\"10000000-0000-4000-8000-000000000001\",\"server_time\":\"2026-08-27T09:15:05Z\"}"}"#

        guard case .callAnswered(_, let signal) = try XCTUnwrap(KitPusherCodec.decode(json)) else {
            return XCTFail("Expected a call-answered frame")
        }
        XCTAssertEqual(signal.callId, callID)
    }

    func testCodecRefusesEveryMalformedAnsweredFrame() {
        // Wrong version.
        XCTAssertNil(KitPusherCodec.decode(answeredFrameJSON(version: "2")))
        // Wrong state.
        XCTAssertNil(KitPusherCodec.decode(answeredFrameJSON(state: "ringing")))
        // A key the payload does not carry — the shape is exact.
        XCTAssertNil(KitPusherCodec.decode(answeredFrameJSON(extraKey: true)))
        // A missing member.
        XCTAssertNil(KitPusherCodec.decode(answeredFrameJSON(omitServerTime: true)))
        // A truncated id parses on some platforms; the round-trip rule refuses it.
        XCTAssertNil(KitPusherCodec.decode(
            answeredFrameJSON(callId: String(callID.dropLast()))
        ))
        // A replay older than the server lets a call run.
        XCTAssertNil(KitPusherCodec.decode(
            answeredFrameJSON(answeredAt: "2026-08-20T09:15:05Z")
        ))
        // An answer claimed far in the server's own future.
        XCTAssertNil(KitPusherCodec.decode(
            answeredFrameJSON(answeredAt: "2026-08-27T10:15:05Z")
        ))
        // Unreadable instants.
        XCTAssertNil(KitPusherCodec.decode(answeredFrameJSON(answeredAt: "yesterday")))
        // An answering identity that is not a canonical user id.
        XCTAssertNil(KitPusherCodec.decode(answeredFrameJSON(answeredBy: "NOT VALID")))
    }

    // MARK: Capability advertisement

    func testCallsCapabilityGatesTheFrameWithoutGatingTheSocket() throws {
        let enabled = try decodeRealtime(callsMember: "\"calls\":true,")
        XCTAssertEqual(enabled.validatedConfiguration?.callAnswerEnabled, true)

        let disabled = try decodeRealtime(callsMember: "\"calls\":false,")
        XCTAssertEqual(disabled.validatedConfiguration?.callAnswerEnabled, false)

        // An older advertisement omits the member: the socket stays fully valid and only
        // the frame is ignored, so the push keeps carrying the answer.
        let absent = try decodeRealtime(callsMember: "")
        let configuration = try XCTUnwrap(absent.validatedConfiguration)
        XCTAssertFalse(configuration.callAnswerEnabled)
    }

    func testLifecycleIdentityChangesWithTheCallsCapability() throws {
        let enabled = try XCTUnwrap(
            decodeRealtime(callsMember: "\"calls\":true,").validatedConfiguration
        )
        let disabled = try XCTUnwrap(
            decodeRealtime(callsMember: "\"calls\":false,").validatedConfiguration
        )
        // A flipped advertisement must restart the transport task, like presence/typing.
        XCTAssertNotEqual(enabled.lifecycleIdentity, disabled.lifecycleIdentity)
    }

    // MARK: Accept response and handoff threading

    func testAcceptResponseCarriesTheServersAnswerInstantIntoTheHandoff() throws {
        let session = try JSONDecoder().decode(
            CallSessionDTO.self,
            from: Data(acceptResponseJSON().utf8)
        )
        XCTAssertEqual(session.serverTime, serverTime)

        let handoff = try CallMediaHandoff(session: session)
        XCTAssertEqual(handoff.answeredAt, answeredAt)
        XCTAssertEqual(handoff.serverTime, serverTime)

        // Refreshing media credentials mid-call keeps the anchor bound to the call.
        let refreshed = try handoff.refreshingRTC(session.rtc)
        XCTAssertEqual(refreshed.answeredAt, answeredAt)
        XCTAssertEqual(refreshed.serverTime, serverTime)
    }

    func testStartResponseCarriesNoAnswer() throws {
        let session = try JSONDecoder().decode(
            CallSessionDTO.self,
            from: Data(acceptResponseJSON(answered: false).utf8)
        )
        XCTAssertNil(session.serverTime)

        let handoff = try CallMediaHandoff(session: session)
        XCTAssertNil(handoff.answeredAt)
        XCTAssertNil(handoff.serverTime)
    }

    // MARK: Awaiting-remote status

    func testCallerShowsRingingOnlyUntilTheAnswerArrives() {
        XCTAssertEqual(
            CallAwaitingRemoteStatusPolicy.label(isOutgoing: true, answered: false),
            "Ringing…"
        )
        // No second signal is coming to correct a "Ringing…" shown after the pickup.
        XCTAssertEqual(
            CallAwaitingRemoteStatusPolicy.label(isOutgoing: true, answered: true),
            "Connecting…"
        )
        XCTAssertEqual(
            CallAwaitingRemoteStatusPolicy.label(isOutgoing: false, answered: false),
            "Connecting…"
        )
        XCTAssertEqual(
            CallAwaitingRemoteStatusPolicy.label(isOutgoing: false, answered: true),
            "Connecting…"
        )
    }

    // MARK: Fixtures

    private func pushPayload(
        type: String = "call.answered",
        callId: String? = nil,
        state: String? = "active",
        answeredAt: String? = "2026-08-27T09:15:04Z",
        serverTime: String? = "2026-08-27T09:15:05Z"
    ) -> [AnyHashable: Any] {
        var payload: [AnyHashable: Any] = [
            "type": type,
            "call_id": callId ?? callID,
        ]
        if let state { payload["state"] = state }
        if let answeredAt { payload["answered_at"] = answeredAt }
        if let serverTime { payload["server_time"] = serverTime }
        return payload
    }

    private func answeredFrameJSON(
        version: String = "1",
        callId: String? = nil,
        state: String = "active",
        answeredAt: String = "2026-08-27T09:15:04Z",
        serverTime: String = "2026-08-27T09:15:05Z",
        answeredBy: String = "10000000-0000-4000-8000-000000000001",
        extraKey: Bool = false,
        omitServerTime: Bool = false
    ) -> String {
        var members = [
            "\"v\":\(version)",
            "\"call_id\":\"\(callId ?? callID)\"",
            "\"state\":\"\(state)\"",
            "\"answered_at\":\"\(answeredAt)\"",
            "\"answered_by\":\"\(answeredBy)\"",
        ]
        if !omitServerTime { members.append("\"server_time\":\"\(serverTime)\"") }
        if extraKey { members.append("\"room\":\"forbidden\"") }
        let data = "{\(members.joined(separator: ","))}"
        return #"{"event":"kit.call.answered","channel":"private-kit.user.10000000-0000-4000-8000-000000000001","data":"# + data + "}"
    }

    private func acceptResponseJSON(answered: Bool = true) -> String {
        let answeredMembers = answered
            ? #","answered_at":"2026-08-27T09:15:04Z""#
            : ""
        let serverTimeMember = answered
            ? #","server_time":"2026-08-27T09:15:05Z""#
            : ""
        return #"""
        {
            "call": {
                "id": "\#(callID)",
                "name": "Registered name",
                "participant_user_ids": ["10000000-0000-4000-8000-000000000001"],
                "direction": "incoming",
                "type": "voice",
                "video": false,
                "state": "active",
                "started_at": "2026-08-27T09:15:00Z"\#(answeredMembers)
            },
            "rtc": {
                "provider": "livekit",
                "url": "wss://rtc.pay.kit.africa",
                "token": "accepted-token",
                "room": "accepted-room",
                "expires_at": "2026-08-27T09:20:00Z"
            }\#(serverTimeMember)
        }
        """#
    }

    private func decodeRealtime(callsMember: String) throws -> RealtimeProtocolCapabilityDTO {
        let json = #"""
        {
            "v": 1,
            "scheme": "wss",
            "host": "pay.kit.africa",
            "port": 443,
            "path": "/app/realtime-key",
            "key": "realtime-key",
            "protocol": 7,
            "auth_path": "/api/kit-wallet/v1/messaging/realtime/auth",
            "activity_timeout": 30,
            "max_connection_seconds": 600,
            "channels": {
                "user": "private-kit.user.{user}",
                "conversation": "presence-kit.conv.{conversation}"
            },
            \#(callsMember)
            "presence": true,
            "typing": true
        }
        """#
        return try JSONDecoder().decode(
            RealtimeProtocolCapabilityDTO.self,
            from: Data(json.utf8)
        )
    }
}
