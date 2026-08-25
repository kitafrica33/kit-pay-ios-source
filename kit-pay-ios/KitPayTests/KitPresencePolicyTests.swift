import XCTest
@testable import KitPay

final class KitPresencePolicyTests: XCTestCase {
    // 2001-09-09T12:53:20Z — midday UTC so same-day arithmetic has room on both sides.
    private let now = Date(timeIntervalSince1970: 1_000_040_000)

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    private let locale = Locale(identifier: "en_US_POSIX")

    private func state(
        isOnline: Bool,
        lastSeenAt: Date? = nil,
        receivedSecondsAgo: TimeInterval
    ) -> PeerPresenceState {
        PeerPresenceState(
            isOnline: isOnline,
            lastSeenAt: lastSeenAt,
            receivedAt: now.addingTimeInterval(-receivedSecondsAgo)
        )
    }

    // MARK: - isConsideredOnline

    func testFreshOnlineHeartbeatIsConsideredOnline() {
        let fresh = state(isOnline: true, receivedSecondsAgo: 30)
        XCTAssertTrue(KitPresencePolicy.isConsideredOnline(fresh, now: now))
    }

    func testOnlineMembershipDoesNotExpireOnAClientTimer() {
        let stale = state(isOnline: true, receivedSecondsAgo: 80)
        XCTAssertTrue(KitPresencePolicy.isConsideredOnline(stale, now: now))
    }

    func testOnlineMembershipRemainsAuthoritativeUntilRemovalOrTransportLoss() {
        let oldMembership = state(isOnline: true, receivedSecondsAgo: 86_400)
        XCTAssertTrue(KitPresencePolicy.isConsideredOnline(oldMembership, now: now))
    }

    func testFreshOfflineHeartbeatIsNotConsideredOnline() {
        let offline = state(isOnline: false, receivedSecondsAgo: 5)
        XCTAssertFalse(KitPresencePolicy.isConsideredOnline(offline, now: now))
    }

    // MARK: - lastSeenLabel

    private func label(for state: PeerPresenceState?) -> String? {
        KitPresencePolicy.lastSeenLabel(
            for: state,
            now: now,
            calendar: calendar,
            locale: locale
        )
    }

    func testLastSeenLabelIsNilWithoutAnyPresenceData() {
        XCTAssertNil(label(for: nil))
    }

    func testLastSeenLabelIsOnlineForFreshOnlineState() {
        let fresh = state(isOnline: true, receivedSecondsAgo: 10)
        XCTAssertEqual(label(for: fresh), "online")
    }

    func testLastSeenLabelIsNilWhenOfflineWithoutLastSeenTimestamp() {
        let offline = state(isOnline: false, lastSeenAt: nil, receivedSecondsAgo: 10)
        XCTAssertNil(label(for: offline))
    }

    func testOnlineMembershipWinsOverAnOlderLastSeenTimestamp() {
        let stale = state(
            isOnline: true,
            lastSeenAt: now.addingTimeInterval(-3_000),
            receivedSecondsAgo: 3_000
        )
        XCTAssertEqual(label(for: stale), "online")
    }

    func testLastSeenLabelJustNowUnderTwoMinutes() {
        let recent = state(
            isOnline: false,
            lastSeenAt: now.addingTimeInterval(-60),
            receivedSecondsAgo: 60
        )
        XCTAssertEqual(label(for: recent), "last seen just now")
    }

    func testLastSeenLabelMinutesTierUnderOneHour() {
        let fiveMinutes = state(
            isOnline: false,
            lastSeenAt: now.addingTimeInterval(-300),
            receivedSecondsAgo: 300
        )
        XCTAssertEqual(label(for: fiveMinutes), "last seen 5 min ago")

        let fiftyNineMinutes = state(
            isOnline: false,
            lastSeenAt: now.addingTimeInterval(-3_599),
            receivedSecondsAgo: 3_599
        )
        XCTAssertEqual(label(for: fiftyNineMinutes), "last seen 59 min ago")
    }

    func testLastSeenLabelTodayTierUsesShortTimeFormat() {
        // Three hours earlier: 2001-09-09T09:53:20Z, still the same UTC calendar day.
        let lastSeenAt = now.addingTimeInterval(-10_800)
        let earlierToday = state(
            isOnline: false,
            lastSeenAt: lastSeenAt,
            receivedSecondsAgo: 10_800
        )

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.dateStyle = .none
        formatter.timeStyle = .short

        let result = label(for: earlierToday)
        XCTAssertEqual(result, "last seen today at \(formatter.string(from: lastSeenAt))")
        XCTAssertEqual(result?.hasPrefix("last seen today at "), true)
    }

    func testLastSeenLabelOlderThanTodayUsesDayMonthFormat() {
        // 1_000_040_000 - 200_000 = 999_840_000 → 2001-09-07T05:20:00Z.
        let previousDay = state(
            isOnline: false,
            lastSeenAt: now.addingTimeInterval(-200_000),
            receivedSecondsAgo: 200_000
        )
        XCTAssertEqual(label(for: previousDay), "last seen 7 Sep")
    }

    // MARK: - typingLabel

    func testTypingLabelIsNilForNoNames() {
        XCTAssertNil(KitPresencePolicy.typingLabel(names: []))
    }

    func testTypingLabelForOneName() {
        XCTAssertEqual(KitPresencePolicy.typingLabel(names: ["Ana"]), "Ana is typing…")
    }

    func testTypingLabelForTwoNames() {
        XCTAssertEqual(
            KitPresencePolicy.typingLabel(names: ["Ana", "Ben"]),
            "Ana and Ben are typing…"
        )
    }

    func testTypingLabelForThreeOrMoreNames() {
        XCTAssertEqual(
            KitPresencePolicy.typingLabel(names: ["Ana", "Ben", "Cleo"]),
            "Several people are typing…"
        )
        XCTAssertEqual(
            KitPresencePolicy.typingLabel(names: ["Ana", "Ben", "Cleo", "Dev"]),
            "Several people are typing…"
        )
    }
}

final class KitRealtimeProtocolTests: XCTestCase {
    private let userID = "10000000-0000-4000-8000-000000000001"
    private let conversationID = "20000000-0000-4000-8000-000000000002"

    func testExactRealtimeCapabilityBuildsProtocolSevenURL() throws {
        let decoded = try decodeRealtime([
            "v": 1,
            "scheme": "wss",
            "host": "pay.kit.africa",
            "port": 443,
            "path": "/app/realtime-key",
            "key": "realtime-key",
            "protocol": 7,
            "auth_path": KitRealtimeConfiguration.expectedAuthPath,
            "activity_timeout": 30,
            "max_connection_seconds": 1_800,
            "channels": [
                "user": KitRealtimeConfiguration.expectedUserChannelTemplate,
                "conversation": KitRealtimeConfiguration.expectedConversationChannelTemplate,
            ],
            "presence": true,
            "typing": true,
        ])

        let configuration = try XCTUnwrap(decoded.validatedConfiguration)
        XCTAssertEqual(configuration.userChannel(userID: userID), "private-kit.user.\(userID)")
        XCTAssertEqual(
            configuration.conversationChannel(conversationID: conversationID),
            "presence-kit.conv.\(conversationID)"
        )
        XCTAssertEqual(configuration.socketURL?.scheme, "wss")
        XCTAssertEqual(configuration.socketURL?.host, "pay.kit.africa")
        XCTAssertEqual(configuration.socketURL?.path, "/app/realtime-key")
        XCTAssertEqual(
            configuration.socketURL?.queryItemsDictionary,
            ["client": "kit-ios", "flash": "false", "protocol": "7", "version": "1"]
        )
    }

    func testRealtimeConfigurationRemainsAvailableWhenPresenceIsNotEffective() throws {
        let decoded = try decodeRealtime([
            "v": 1,
            "scheme": "wss",
            "host": "pay.kit.africa",
            "port": 443,
            "path": "/app/realtime-key",
            "key": "realtime-key",
            "protocol": 7,
            "auth_path": KitRealtimeConfiguration.expectedAuthPath,
            "activity_timeout": 30,
            "max_connection_seconds": 1_800,
            "channels": [
                "user": KitRealtimeConfiguration.expectedUserChannelTemplate,
                "conversation": KitRealtimeConfiguration.expectedConversationChannelTemplate,
            ],
            "presence": false,
            "typing": false,
        ])

        let configuration = try XCTUnwrap(decoded.validatedConfiguration)
        XCTAssertFalse(configuration.presenceEnabled)
        XCTAssertFalse(configuration.typingEnabled)
    }

    func testRealtimeCapabilityFailsClosedForEverySecurityBoundary() throws {
        let valid: [String: Any] = [
            "v": 1,
            "scheme": "wss",
            "host": "pay.kit.africa",
            "port": 443,
            "path": "/app/realtime-key",
            "key": "realtime-key",
            "protocol": 7,
            "auth_path": KitRealtimeConfiguration.expectedAuthPath,
            "activity_timeout": 30,
            "max_connection_seconds": 1_800,
            "channels": [
                "user": KitRealtimeConfiguration.expectedUserChannelTemplate,
                "conversation": KitRealtimeConfiguration.expectedConversationChannelTemplate,
            ],
            "presence": true,
            "typing": true,
        ]
        let mutations: [(String, Any)] = [
            ("v", 2), ("scheme", "ws"), ("host", "evil.example"), ("port", 80),
            ("path", "/app/a-different-key"), ("protocol", 8),
            ("auth_path", "/broadcasting/auth"), ("activity_timeout", 9),
            ("max_connection_seconds", 1_801), ("typing", true),
        ]

        for (index, mutation) in mutations.enumerated() {
            var candidate = valid
            candidate[mutation.0] = mutation.1
            if index == mutations.count - 1 { candidate["presence"] = false }
            XCTAssertNil(
                try decodeRealtime(candidate).validatedConfiguration,
                "expected \(mutation.0) mutation to fail closed"
            )
        }
    }

    func testMalformedOptionalRealtimeBlockDoesNotPoisonOtherCapabilities() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "currency": ["code": "UGX", "scale": "0"],
            "features": ["messaging": true],
            "protocols": [
                "messaging": [
                    "ready": true,
                    "version": SecureMessagingWire.protocolVersion,
                    "suite": SecureMessagingWire.protocolSuite,
                    "post_quantum": true,
                ],
                "realtime": "not-an-object",
            ],
        ])
        let capabilities = try JSONDecoder().decode(CapabilitiesDTO.self, from: data)
        XCTAssertTrue(capabilities.protocols?.messaging?.supportsReviewedV2 == true)
        XCTAssertNil(capabilities.protocols?.realtime)
    }

    func testCodecHandlesDoubleEncodedProtocolFramesAndObjectApplicationFrames() {
        XCTAssertEqual(
            KitPusherCodec.decode(
                #"{"event":"pusher:connection_established","data":"{\"socket_id\":\"812.4471\",\"activity_timeout\":30}"}"#
            ),
            .connectionEstablished(socketID: "812.4471", activityTimeout: 30)
        )
        XCTAssertEqual(
            KitPusherCodec.decode(
                #"{"event":"kit.sync.nudge","channel":"private-kit.user.10000000-0000-4000-8000-000000000001","data":{"v":1}}"#
            ),
            .syncNudge(channel: "private-kit.user.\(userID)")
        )
        XCTAssertEqual(
            KitPusherCodec.decode(
                #"{"event":"kit.typing","channel":"presence-kit.conv.20000000-0000-4000-8000-000000000002","data":{"v":1,"user":"10000000-0000-4000-8000-000000000001"}}"#
            ),
            .typing(
                channel: "presence-kit.conv.\(conversationID)",
                userID: userID,
                isTyping: true
            )
        )
        XCTAssertEqual(
            KitPusherCodec.decode(
                #"{"event":"kit.sync.nudge","channel":"private-kit.user.10000000-0000-4000-8000-000000000001","data":"{\"v\":1}"}"#
            ),
            .syncNudge(channel: "private-kit.user.\(userID)")
        )
        XCTAssertEqual(
            KitPusherCodec.decode(
                #"{"event":"kit.typing.stop","channel":"presence-kit.conv.20000000-0000-4000-8000-000000000002","data":"{\"v\":1,\"user\":\"10000000-0000-4000-8000-000000000001\"}"}"#
            ),
            .typing(
                channel: "presence-kit.conv.\(conversationID)",
                userID: userID,
                isTyping: false
            )
        )
    }

    func testCodecRejectsClientEventsBeforeParsingAndDropsContentBearingNudges() {
        XCTAssertEqual(
            KitPusherCodec.decode(
                #"{"event":"client-kit.typing","channel":"anything","data":"not-json"}"#
            ),
            .rejectedClientEvent
        )
        XCTAssertFalse(
            KitPusherInboundFrame.rejectedClientEvent.countsTowardDroppedFrameFlood
        )
        XCTAssertTrue(KitPusherInboundFrame.ignored.countsTowardDroppedFrameFlood)
        XCTAssertNil(KitPusherCodec.decode(
            #"{"event":"kit.sync.nudge","channel":"private-kit.user.x","data":{"v":1,"ciphertext":"forbidden"}}"#
        ))
        XCTAssertNil(KitPusherCodec.decode(
            #"{"event":"kit.sync.nudge","channel":"private-kit.user.x","data":{"v":1,"reason":"message.created"}}"#
        ))
        XCTAssertNil(KitPusherCodec.decode(
            #"{"event":"kit.sync.nudge","channel":"private-kit.user.x","data":{"v":2}}"#
        ))
    }

    func testPresenceRosterAndMemberFramesUseStringEncodedData() {
        let channel = "presence-kit.conv.\(conversationID)"
        XCTAssertEqual(
            KitPusherCodec.decode(
                #"{"event":"pusher_internal:subscription_succeeded","channel":"presence-kit.conv.20000000-0000-4000-8000-000000000002","data":"{\"presence\":{\"count\":1,\"ids\":[\"10000000-0000-4000-8000-000000000001\"],\"hash\":{}}}"}"#
            ),
            .subscriptionSucceeded(channel: channel, presenceUserIDs: [userID])
        )
        XCTAssertNil(KitPusherCodec.decode(
            #"{"event":"pusher_internal:member_added","channel":"presence-kit.conv.20000000-0000-4000-8000-000000000002","data":{"user_id":"10000000-0000-4000-8000-000000000001"}}"#
        ))
    }

    func testReconnectAndDropPoliciesAreBounded() {
        XCTAssertEqual(
            KitRealtimeReconnectPolicy.disposition(forPusherErrorCode: 4_009),
            .suspendSession
        )
        XCTAssertEqual(
            KitRealtimeReconnectPolicy.disposition(forPusherErrorCode: 4_101),
            .backoff(minimumDelay: 1)
        )
        XCTAssertEqual(
            KitRealtimeReconnectPolicy.disposition(forPusherErrorCode: 4_201),
            .reconnectImmediately
        )
        XCTAssertEqual(KitRealtimeReconnectPolicy.maximumDelay(attempt: 100), 60)

        var guardrail = KitRealtimeDropGuard()
        let now = Date(timeIntervalSince1970: 1_000)
        for offset in 0 ..< KitRealtimeDropGuard.limit - 1 {
            XCTAssertFalse(guardrail.record(at: now.addingTimeInterval(Double(offset))))
        }
        XCTAssertTrue(guardrail.record(at: now.addingTimeInterval(19)))
        guardrail.reset()
        XCTAssertFalse(guardrail.record(at: now.addingTimeInterval(100)))
    }

    private func decodeRealtime(_ realtime: [String: Any]) throws
        -> RealtimeProtocolCapabilityDTO {
        let data = try JSONSerialization.data(withJSONObject: [
            "currency": ["code": "UGX", "scale": "0"],
            "protocols": ["realtime": realtime],
        ])
        return try XCTUnwrap(
            JSONDecoder().decode(CapabilitiesDTO.self, from: data).protocols?.realtime
        )
    }
}

private extension URL {
    var queryItemsDictionary: [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(
            url: self,
            resolvingAgainstBaseURL: false
        )?.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
    }
}

final class KitPresenceCenterTests: XCTestCase {
    private let firstUserID = "10000000-0000-0000-0000-000000000001"
    private let secondUserID = "10000000-0000-0000-0000-000000000002"
    private let thirdUserID = "10000000-0000-0000-0000-000000000003"

    @MainActor
    func testDifferentSessionStartPerformsOrderedAccountSwitch() async {
        let transport = PresenceTestTransport()
        let center = KitPresenceCenter()
        center.transport = transport
        center.start(userID: firstUserID, sessionID: "first-session")
        await waitForCall(
            .startFinished(userID: firstUserID, sessionID: "first-session"),
            on: transport
        )

        await transport.suspendNextStop()
        center.start(userID: secondUserID, sessionID: "second-session")
        await waitForCall(.stopBegan, on: transport)
        var calls = await transport.recordedCalls()
        XCTAssertFalse(calls.contains(.startBegan(
            userID: secondUserID,
            sessionID: "second-session"
        )))

        await transport.releaseStop()
        await waitForCall(
            .startFinished(userID: secondUserID, sessionID: "second-session"),
            on: transport
        )
        calls = await transport.recordedCalls()
        let stopFinished = try? XCTUnwrap(calls.firstIndex(of: .stopFinished))
        let nextStart = try? XCTUnwrap(calls.firstIndex(of: .startBegan(
            userID: secondUserID,
            sessionID: "second-session"
        )))
        if let stopFinished, let nextStart {
            XCTAssertLessThan(stopFinished, nextStart)
        }

        center.stop()
        await waitForCallCount(.stopFinished, count: 2, on: transport)
        await transport.finishEvents()
    }

    @MainActor
    func testChangedRealtimeConfigurationRestartsSameAccountSession() async throws {
        let transport = PresenceTestTransport()
        let center = KitPresenceCenter()
        center.transport = transport
        let first = try realtimeConfiguration(key: "first-key")
        let second = try realtimeConfiguration(key: "second-key")

        center.start(userID: firstUserID, sessionID: "same-session", configuration: first)
        await waitForCall(
            .startFinished(userID: firstUserID, sessionID: "same-session"),
            on: transport
        )
        center.start(userID: firstUserID, sessionID: "same-session", configuration: first)
        try? await Task.sleep(for: .milliseconds(10))
        var calls = await transport.recordedCalls()
        XCTAssertEqual(calls.filter {
            $0 == .startBegan(userID: firstUserID, sessionID: "same-session")
        }.count, 1)

        center.start(userID: firstUserID, sessionID: "same-session", configuration: second)
        await waitForCallCount(
            .startFinished(userID: firstUserID, sessionID: "same-session"),
            count: 2,
            on: transport
        )
        calls = await transport.recordedCalls()
        XCTAssertEqual(calls.filter { $0 == .stopBegan }.count, 1)

        center.stop()
        await waitForCallCount(.stopFinished, count: 2, on: transport)
        await transport.finishEvents()
    }

    @MainActor
    func testStopUnblocksSuspendedStartBeforeReplacementSessionStarts() async {
        let transport = PresenceTestTransport()
        await transport.suspendNextStart()
        let center = KitPresenceCenter()
        center.transport = transport
        center.start(userID: firstUserID, sessionID: "suspended-session")
        await waitForCall(
            .startBegan(userID: firstUserID, sessionID: "suspended-session"),
            on: transport
        )

        center.stop()
        center.start(userID: secondUserID, sessionID: "replacement-session")
        await waitForCall(
            .startFinished(userID: secondUserID, sessionID: "replacement-session"),
            on: transport
        )

        let calls = await transport.recordedCalls()
        let stopBegan = try? XCTUnwrap(calls.firstIndex(of: .stopBegan))
        let suspendedFinished = try? XCTUnwrap(calls.firstIndex(of: .startFinished(
            userID: firstUserID,
            sessionID: "suspended-session"
        )))
        let replacementBegan = try? XCTUnwrap(calls.firstIndex(of: .startBegan(
            userID: secondUserID,
            sessionID: "replacement-session"
        )))
        if let stopBegan, let suspendedFinished, let replacementBegan {
            XCTAssertLessThan(stopBegan, suspendedFinished)
            XCTAssertLessThan(suspendedFinished, replacementBegan)
        }

        center.stop()
        await waitForCallCount(.stopFinished, count: 2, on: transport)
        await transport.finishEvents()
    }

    @MainActor
    func testRestartUsesFreshEventStreamAndRejectsRetiredSessionEvents() async {
        let transport = PresenceTestTransport()
        let center = KitPresenceCenter()
        center.transport = transport
        center.start(userID: firstUserID, sessionID: "first-session")
        await waitForCall(
            .startFinished(userID: firstUserID, sessionID: "first-session"),
            on: transport
        )

        let firstReceivedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let firstAccepted = await transport.yieldEvent(
            .presence(userID: thirdUserID, isOnline: true, lastSeenAt: firstReceivedAt),
            sessionIndex: 0
        )
        XCTAssertTrue(firstAccepted)
        await waitForPresenceState(
            isOnline: true,
            lastSeenAt: firstReceivedAt,
            userID: thirdUserID,
            in: center
        )

        center.stop()
        await waitForCall(.stopFinished, on: transport)
        XCTAssertNil(center.presenceState(for: thirdUserID))

        center.start(userID: secondUserID, sessionID: "second-session")
        await waitForCall(
            .startFinished(userID: secondUserID, sessionID: "second-session"),
            on: transport
        )

        let staleAccepted = await transport.yieldEvent(
            .presence(userID: firstUserID, isOnline: true, lastSeenAt: firstReceivedAt),
            sessionIndex: 0
        )
        XCTAssertFalse(staleAccepted)
        let currentReceivedAt = firstReceivedAt.addingTimeInterval(1)
        let currentAccepted = await transport.yieldEvent(
            .presence(userID: thirdUserID, isOnline: true, lastSeenAt: currentReceivedAt),
            sessionIndex: 1
        )
        XCTAssertTrue(currentAccepted)
        await waitForPresenceState(
            isOnline: true,
            lastSeenAt: currentReceivedAt,
            userID: thirdUserID,
            in: center
        )
        XCTAssertNil(center.presenceState(for: firstUserID))

        center.stop()
        await waitForCallCount(.stopFinished, count: 2, on: transport)
        await transport.finishEvents()
    }

    @MainActor
    func testRestartWaitsForOnlyInFlightStopAndForNewStartBeforeTyping() async {
        let transport = PresenceTestTransport()
        let center = KitPresenceCenter()
        center.transport = transport

        center.start(userID: firstUserID, sessionID: "first-session")
        await waitForCall(
            .startFinished(userID: firstUserID, sessionID: "first-session"),
            on: transport
        )

        await transport.suspendNextStop()
        center.stop()
        // Repeated lifecycle invalidations are common while profile/capability state settles.
        // They must not replace the one stop that the next start awaits.
        center.stop()
        await waitForCall(.stopBegan, on: transport)

        await transport.suspendNextStart()
        center.start(userID: secondUserID, sessionID: "second-session")
        let conversationID = "30000000-0000-4000-8000-000000000001"
        center.observeConversation(conversationID)
        center.recordLocalTyping(conversationID: conversationID)

        var calls = await transport.recordedCalls()
        XCTAssertFalse(calls.contains(.startBegan(
            userID: secondUserID,
            sessionID: "second-session"
        )))
        XCTAssertEqual(calls.filter { $0 == .stopBegan }.count, 1)

        await transport.releaseStop()
        await waitForCall(
            .startBegan(userID: secondUserID, sessionID: "second-session"),
            on: transport
        )
        calls = await transport.recordedCalls()
        XCTAssertFalse(calls.contains(.typing(
            conversationID: conversationID,
            isTyping: true
        )))

        await transport.releaseStart()
        await waitForCall(
            .typing(conversationID: conversationID, isTyping: true),
            on: transport
        )
        calls = await transport.recordedCalls()
        let stopFinished = try? XCTUnwrap(calls.firstIndex(of: .stopFinished))
        let startBegan = try? XCTUnwrap(calls.firstIndex(of: .startBegan(
            userID: secondUserID,
            sessionID: "second-session"
        )))
        let startFinished = try? XCTUnwrap(calls.firstIndex(of: .startFinished(
            userID: secondUserID,
            sessionID: "second-session"
        )))
        let typing = try? XCTUnwrap(calls.firstIndex(of: .typing(
            conversationID: conversationID,
            isTyping: true
        )))
        if let stopFinished, let startBegan, let startFinished, let typing {
            XCTAssertLessThan(stopFinished, startBegan)
            XCTAssertLessThan(startBegan, startFinished)
            XCTAssertLessThan(startFinished, typing)
        }

        center.stop()
        await waitForCallCount(.stopFinished, count: 2, on: transport)
        await transport.finishEvents()
    }

    @MainActor
    func testPrivacyOffClearsInboundStateAndRetractsActiveTypingInOrder() async {
        let transport = PresenceTestTransport()
        let center = KitPresenceCenter()
        center.transport = transport
        center.start(userID: firstUserID, sessionID: "privacy-session")
        await waitForCall(
            .startFinished(userID: firstUserID, sessionID: "privacy-session"),
            on: transport
        )

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let activeConversationID = "30000000-0000-4000-8000-000000000011"
        let blockedConversationID = "30000000-0000-4000-8000-000000000012"
        let freshConversationID = "30000000-0000-4000-8000-000000000013"
        center.apply(.presence(
            userID: secondUserID,
            isOnline: true,
            lastSeenAt: now
        ), now: now)
        center.apply(.typing(
            conversationID: "incoming-conversation",
            userID: secondUserID,
            isTyping: true
        ), now: now)
        await transport.suspendNextTyping()
        center.observeConversation(activeConversationID)
        center.recordLocalTyping(conversationID: activeConversationID, now: now)
        await waitForCall(
            .typing(conversationID: activeConversationID, isTyping: true),
            on: transport
        )

        center.broadcastsPresence = false
        XCTAssertTrue(center.peerPresence.isEmpty)
        XCTAssertTrue(center.typing.isEmpty)

        // Events delivered by an already-connected transport remain invisible while private.
        center.apply(.presence(
            userID: secondUserID,
            isOnline: true,
            lastSeenAt: now
        ), now: now)
        center.apply(.typing(
            conversationID: "incoming-conversation",
            userID: secondUserID,
            isTyping: true
        ), now: now)
        XCTAssertTrue(center.peerPresence.isEmpty)
        XCTAssertTrue(center.typing.isEmpty)

        // A retraction queued behind an in-flight `true` must survive later privacy changes.
        center.broadcastsPresence = true
        center.broadcastsPresence = false
        await transport.releaseTyping()
        await waitForCall(
            .typing(conversationID: activeConversationID, isTyping: false),
            on: transport
        )
        center.recordLocalTyping(conversationID: blockedConversationID, now: now)
        center.observeConversation(freshConversationID)
        center.broadcastsPresence = true
        center.recordLocalTyping(conversationID: freshConversationID, now: now)
        await waitForCall(
            .typing(conversationID: freshConversationID, isTyping: true),
            on: transport
        )

        let calls = await transport.recordedCalls()
        XCTAssertFalse(calls.contains(.typing(
            conversationID: blockedConversationID,
            isTyping: true
        )))
        let sentTrue = try? XCTUnwrap(calls.firstIndex(of: .typing(
            conversationID: activeConversationID,
            isTyping: true
        )))
        let sentFalse = try? XCTUnwrap(calls.firstIndex(of: .typing(
            conversationID: activeConversationID,
            isTyping: false
        )))
        let freshTrue = try? XCTUnwrap(calls.firstIndex(of: .typing(
            conversationID: freshConversationID,
            isTyping: true
        )))
        let unobserve = try? XCTUnwrap(calls.firstIndex(of: .unobserve(activeConversationID)))
        let reobserve = try? XCTUnwrap(calls.lastIndex(of: .observe(freshConversationID)))
        if let sentTrue, let sentFalse, let unobserve, let reobserve, let freshTrue {
            XCTAssertLessThan(sentTrue, sentFalse)
            XCTAssertLessThan(sentFalse, unobserve)
            XCTAssertLessThan(unobserve, reobserve)
            XCTAssertLessThan(reobserve, freshTrue)
        }

        center.stop()
        await waitForCall(.stopFinished, on: transport)
        await transport.finishEvents()
    }

    @MainActor
    func testPrivacyOffKeepsRealtimeSyncLiveWithoutRenderingOrSendingEphemeralState() async {
        let transport = PresenceTestTransport()
        let center = KitPresenceCenter()
        center.transport = transport
        center.broadcastsPresence = false
        var syncContexts: [(String, String)] = []
        var liveTransitions: [Bool] = []
        center.syncRequestHandler = { syncContexts.append(($0, $1)) }
        center.connectionStateHandler = { liveTransitions.append($0) }
        center.start(userID: firstUserID, sessionID: "private-realtime-session")
        await waitForCall(
            .startFinished(userID: firstUserID, sessionID: "private-realtime-session"),
            on: transport
        )

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let acceptedLive = await transport.yieldEvent(.connectionLive(true), sessionIndex: 0)
        let acceptedSync = await transport.yieldEvent(.syncRequested, sessionIndex: 0)
        XCTAssertTrue(acceptedLive)
        XCTAssertTrue(acceptedSync)
        for _ in 0..<1_000 {
            if center.isLive, !syncContexts.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        center.apply(.presence(
            userID: secondUserID,
            isOnline: true,
            lastSeenAt: now
        ), now: now)
        center.apply(.typing(
            conversationID: "30000000-0000-0000-0000-000000000001",
            userID: secondUserID,
            isTyping: true
        ), now: now)
        center.recordLocalTyping(
            conversationID: "30000000-0000-0000-0000-000000000001",
            now: now
        )
        XCTAssertTrue(center.isLive)
        XCTAssertEqual(liveTransitions, [true])
        XCTAssertEqual(syncContexts.count, 1)
        XCTAssertEqual(syncContexts.first?.0, firstUserID)
        XCTAssertEqual(syncContexts.first?.1, "private-realtime-session")
        XCTAssertTrue(center.peerPresence.isEmpty)
        XCTAssertTrue(center.typing.isEmpty)
        let calls = await transport.recordedCalls()
        XCTAssertFalse(calls.contains(.typing(
            conversationID: "30000000-0000-0000-0000-000000000001",
            isTyping: true
        )))

        center.apply(.availabilityLost, now: now)
        XCTAssertFalse(center.isLive)
        XCTAssertEqual(liveTransitions, [true, false])

        center.stop()
        await waitForCall(.stopFinished, on: transport)
        await transport.finishEvents()
    }

    @MainActor
    func testForegroundLifecycleIsForwardedWithoutABackgroundGraceWindow() async {
        let transport = PresenceTestTransport()
        let center = KitPresenceCenter()
        center.transport = transport

        center.setForeground(true)
        await waitForCall(.foreground(true), on: transport)
        center.setForeground(false)
        await waitForCall(.foreground(false), on: transport)

        let calls = await transport.recordedCalls()
        let foreground = try? XCTUnwrap(calls.firstIndex(of: .foreground(true)))
        let background = try? XCTUnwrap(calls.firstIndex(of: .foreground(false)))
        if let foreground, let background {
            XCTAssertLessThan(foreground, background)
        }
    }

    @MainActor
    func testDelayedForegroundCompletionCannotOverrideLatestInactiveState() async {
        let transport = PresenceTestTransport()
        await transport.suspendNextForeground()
        let center = KitPresenceCenter()
        center.transport = transport

        center.setForeground(true)
        for _ in 0..<1_000 {
            if await transport.hasSuspendedForegroundCall() { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        let didSuspendForeground = await transport.hasSuspendedForegroundCall()
        XCTAssertTrue(didSuspendForeground)

        // The newer inactive transition is allowed to finish while the older foreground call is
        // suspended, exactly as two independent transport actor hops can complete out of order.
        center.setForeground(false)
        await waitForCall(.foreground(false), on: transport)
        var appliedForeground = await transport.appliedForegroundState()
        XCTAssertEqual(appliedForeground, false)

        // When the stale `true` finally lands, the generation fence must immediately reconcile
        // the latest intent and leave the transport inactive.
        await transport.releaseForeground()
        await waitForCallCount(.foreground(false), count: 2, on: transport)
        appliedForeground = await transport.appliedForegroundState()
        XCTAssertEqual(appliedForeground, false)
        let foregroundCalls = await transport.recordedCalls().filter {
            if case .foreground = $0 { return true }
            return false
        }
        XCTAssertEqual(
            foregroundCalls,
            [.foreground(false), .foreground(true), .foreground(false)]
        )
    }

    @MainActor
    func testPrivacyTransitionInvalidatesTypingQueuedBeforeStartCompletes() async {
        let transport = PresenceTestTransport()
        await transport.suspendNextStart()
        let center = KitPresenceCenter()
        center.transport = transport
        center.start(userID: firstUserID, sessionID: "delayed-start")
        await waitForCall(
            .startBegan(userID: firstUserID, sessionID: "delayed-start"),
            on: transport
        )

        let staleConversationID = "30000000-0000-4000-8000-000000000021"
        let currentConversationID = "30000000-0000-4000-8000-000000000022"
        center.observeConversation(staleConversationID)
        center.recordLocalTyping(conversationID: staleConversationID)
        center.broadcastsPresence = false
        center.observeConversation(currentConversationID)
        center.broadcastsPresence = true
        center.recordLocalTyping(conversationID: currentConversationID)

        await transport.releaseStart()
        await waitForCall(
            .typing(conversationID: currentConversationID, isTyping: true),
            on: transport
        )
        let calls = await transport.recordedCalls()
        XCTAssertFalse(calls.contains(.typing(
            conversationID: staleConversationID,
            isTyping: true
        )))

        center.stop()
        await waitForCall(.stopFinished, on: transport)
        await transport.finishEvents()
    }

    @MainActor
    func testSweepKeepsAuthoritativeMembershipAndDropsExpiredTyping() {
        let center = KitPresenceCenter()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let lastSeenAt = now.addingTimeInterval(-60)
        center.apply(.presence(
            userID: secondUserID,
            isOnline: true,
            lastSeenAt: lastSeenAt
        ), now: now)
        center.apply(.typing(
            conversationID: "expiring-conversation",
            userID: secondUserID,
            isTyping: true
        ), now: now)

        center.sweepExpiredState(
            now: now.addingTimeInterval(KitPresencePolicy.typingExpiry)
        )

        XCTAssertEqual(
            center.presenceState(for: secondUserID),
            PeerPresenceState(isOnline: true, lastSeenAt: lastSeenAt, receivedAt: now)
        )
        XCTAssertTrue(center.typingUserIDs(
            in: "expiring-conversation",
            now: now.addingTimeInterval(KitPresencePolicy.typingExpiry)
        ).isEmpty)
        XCTAssertTrue(center.typing.isEmpty)
    }

    @MainActor
    private func waitForCall(
        _ call: PresenceTransportCall,
        on transport: PresenceTestTransport,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        await waitForCallCount(call, count: 1, on: transport, file: file, line: line)
    }

    @MainActor
    private func waitForCallCount(
        _ call: PresenceTransportCall,
        count: Int,
        on transport: PresenceTestTransport,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            let calls = await transport.recordedCalls()
            if calls.filter({ $0 == call }).count >= count {
                return
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for transport call: \(call)", file: file, line: line)
    }

    @MainActor
    private func waitForPresenceState(
        isOnline: Bool,
        lastSeenAt: Date?,
        userID: String,
        in center: KitPresenceCenter,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            let state = center.presenceState(for: userID)
            if state?.isOnline == isOnline, state?.lastSeenAt == lastSeenAt {
                return
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for presence state for: \(userID)", file: file, line: line)
    }

    private func realtimeConfiguration(key: String) throws -> KitRealtimeConfiguration {
        let data = try JSONSerialization.data(withJSONObject: [
            "currency": ["code": "UGX", "scale": "0"],
            "protocols": [
                "realtime": [
                    "v": 1,
                    "scheme": "wss",
                    "host": "pay.kit.africa",
                    "port": 443,
                    "path": "/app/\(key)",
                    "key": key,
                    "protocol": 7,
                    "auth_path": KitRealtimeConfiguration.expectedAuthPath,
                    "activity_timeout": 30,
                    "max_connection_seconds": 1_800,
                    "channels": [
                        "user": KitRealtimeConfiguration.expectedUserChannelTemplate,
                        "conversation": KitRealtimeConfiguration
                            .expectedConversationChannelTemplate,
                    ],
                    "presence": true,
                    "typing": true,
                ],
            ],
        ])
        let capability = try XCTUnwrap(
            JSONDecoder().decode(CapabilitiesDTO.self, from: data).protocols?.realtime
        )
        return try XCTUnwrap(capability.validatedConfiguration)
    }
}

private enum PresenceTransportCall: Equatable, Sendable {
    case startBegan(userID: String, sessionID: String)
    case startFinished(userID: String, sessionID: String)
    case stopBegan
    case stopFinished
    case typing(conversationID: String, isTyping: Bool)
    case heartbeat
    case foreground(Bool)
    case observe(String)
    case unobserve(String)
}

private actor PresenceTestTransport: KitRealtimeTransport {
    private var calls: [PresenceTransportCall] = []
    private var eventContinuations: [AsyncStream<KitRealtimeEvent>.Continuation] = []
    private var activeEventContinuation: AsyncStream<KitRealtimeEvent>.Continuation?
    private var shouldSuspendNextStart = false
    private var shouldSuspendNextStop = false
    private var shouldSuspendNextTyping = false
    private var shouldSuspendNextForeground = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var typingContinuation: CheckedContinuation<Void, Never>?
    private var foregroundContinuation: CheckedContinuation<Void, Never>?
    private var appliedForeground: Bool?

    func suspendNextStart() {
        shouldSuspendNextStart = true
    }

    func suspendNextStop() {
        shouldSuspendNextStop = true
    }

    func suspendNextTyping() {
        shouldSuspendNextTyping = true
    }

    func suspendNextForeground() {
        shouldSuspendNextForeground = true
    }

    func releaseStart() {
        let continuation = startContinuation
        startContinuation = nil
        continuation?.resume()
    }

    func releaseStop() {
        let continuation = stopContinuation
        stopContinuation = nil
        continuation?.resume()
    }

    func releaseTyping() {
        let continuation = typingContinuation
        typingContinuation = nil
        continuation?.resume()
    }

    func releaseForeground() {
        let continuation = foregroundContinuation
        foregroundContinuation = nil
        continuation?.resume()
    }

    func hasSuspendedForegroundCall() -> Bool {
        foregroundContinuation != nil
    }

    func appliedForegroundState() -> Bool? {
        appliedForeground
    }

    func recordedCalls() -> [PresenceTransportCall] {
        calls
    }

    func finishEvents() {
        for continuation in eventContinuations {
            continuation.finish()
        }
        activeEventContinuation = nil
    }

    func yieldEvent(_ event: KitRealtimeEvent, sessionIndex: Int) -> Bool {
        guard eventContinuations.indices.contains(sessionIndex) else { return false }
        switch eventContinuations[sessionIndex].yield(event) {
        case .enqueued, .dropped:
            return true
        case .terminated:
            return false
        @unknown default:
            return false
        }
    }

    func start(
        userID: String,
        sessionID: String
    ) async -> AsyncStream<KitRealtimeEvent> {
        calls.append(.startBegan(userID: userID, sessionID: sessionID))
        activeEventContinuation?.finish()
        let pair = AsyncStream.makeStream(of: KitRealtimeEvent.self)
        eventContinuations.append(pair.continuation)
        activeEventContinuation = pair.continuation
        if shouldSuspendNextStart {
            shouldSuspendNextStart = false
            await withCheckedContinuation { continuation in
                startContinuation = continuation
            }
        }
        calls.append(.startFinished(userID: userID, sessionID: sessionID))
        return pair.stream
    }

    func stop() async {
        calls.append(.stopBegan)
        activeEventContinuation?.finish()
        activeEventContinuation = nil
        let pendingStart = startContinuation
        startContinuation = nil
        pendingStart?.resume()
        let pendingTyping = typingContinuation
        typingContinuation = nil
        pendingTyping?.resume()
        let pendingForeground = foregroundContinuation
        foregroundContinuation = nil
        pendingForeground?.resume()
        if shouldSuspendNextStop {
            shouldSuspendNextStop = false
            await withCheckedContinuation { continuation in
                stopContinuation = continuation
            }
        }
        calls.append(.stopFinished)
    }

    func sendTyping(conversationID: String, isTyping: Bool) async {
        calls.append(.typing(conversationID: conversationID, isTyping: isTyping))
        if shouldSuspendNextTyping {
            shouldSuspendNextTyping = false
            await withCheckedContinuation { continuation in
                typingContinuation = continuation
            }
        }
    }

    func sendPresenceHeartbeat() async {
        calls.append(.heartbeat)
    }

    func setForeground(_ foreground: Bool) async {
        if shouldSuspendNextForeground {
            shouldSuspendNextForeground = false
            await withCheckedContinuation { continuation in
                foregroundContinuation = continuation
            }
        }
        calls.append(.foreground(foreground))
        appliedForeground = foreground
    }

    func observeConversation(_ conversationID: String) async {
        calls.append(.observe(conversationID))
    }

    func unobserveConversation(_ conversationID: String) async {
        calls.append(.unobserve(conversationID))
    }
}
