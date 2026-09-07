import Foundation

/// The lifecycle layer deliberately depends on this narrow boundary, not a concrete LiveKit SDK.
/// A transport owns capture/playback only; backend accept/end/decline remains in `AppModel`.
@MainActor
protocol CallMediaTransport: AnyObject {
    func connect(_ handoff: CallMediaHandoff) async throws
    func disconnect() async
}

/// Validated credentials at the boundary between Kit's call lifecycle and a media SDK.
/// A LiveKit-backed implementation can consume this without owning backend state transitions.
struct CallMediaHandoff: Sendable {
    let callId: String
    let conversationId: String?
    let participantName: String
    let participantAvatarURL: String?
    let participantVerification: AccountVerificationDesignation?
    let direction: String
    let video: Bool
    let url: URL
    let token: String
    let room: String
    let expiresAt: String
    let canHold: Bool
    let holdRevision: Int?
    /// The server's answer instant and its own send clock, verbatim from the response that
    /// carried this handoff. Present only on an accept — the answering device already holds
    /// the authoritative anchor and must not wait for a frame or a push to learn it. A start
    /// response carries neither: nobody has answered yet.
    let answeredAt: String?
    let serverTime: String?

    init(
        session: CallSessionDTO,
        participantAvatarURL: String? = nil,
        participantVerification: AccountVerificationDesignation? = nil
    ) throws {
        try self.init(
            call: session.call,
            rtc: session.rtc,
            participantAvatarURL: participantAvatarURL,
            participantVerification: participantVerification,
            serverTime: session.serverTime
        )
    }

    init(
        call: CallDTO,
        rtc: RTCDetails,
        participantAvatarURL: String? = nil,
        participantVerification: AccountVerificationDesignation? = nil,
        serverTime: String? = nil
    ) throws {
        try self.init(
            callId: call.id,
            conversationId: call.conversationId,
            participantName: call.name?.nilIfEmpty ?? "Kit Pay contact",
            participantAvatarURL: participantAvatarURL,
            participantVerification: participantVerification,
            direction: call.direction,
            video: call.isVideoCall,
            rtc: rtc,
            answeredAt: call.answeredAt,
            serverTime: serverTime,
            canHold: call.canHold,
            holdRevision: call.holdRevision
        )
    }

    /// Replaces only the short-lived LiveKit admission credentials. Call identity and UI
    /// metadata remain bound to the already accepted backend call, and a token response that
    /// unexpectedly points at another room is rejected rather than crossing call boundaries.
    func refreshingRTC(_ rtc: RTCDetails) throws -> CallMediaHandoff {
        try CallMediaHandoff(
            callId: callId,
            conversationId: conversationId,
            participantName: participantName,
            participantAvatarURL: participantAvatarURL,
            participantVerification: participantVerification,
            direction: direction,
            video: video,
            rtc: rtc,
            answeredAt: answeredAt,
            serverTime: serverTime,
            expectedRoom: room,
            canHold: canHold,
            holdRevision: holdRevision
        )
    }

    /// A reviewed invitation is an explicit user join. CallKit must admit that join through a
    /// Start (or an existing ring's Answer) before media attaches, even for a server-incoming call.
    func asUserInitiatedJoin() throws -> CallMediaHandoff {
        try CallMediaHandoff(
            callId: callId, conversationId: conversationId, participantName: participantName,
            participantAvatarURL: participantAvatarURL, participantVerification: participantVerification,
            direction: "outgoing", video: video,
            rtc: RTCDetails(provider: "livekit", url: url.absoluteString, token: token,
                            room: room, iceServers: nil, expiresAt: expiresAt),
            answeredAt: answeredAt, serverTime: serverTime, expectedRoom: room,
            canHold: canHold, holdRevision: holdRevision
        )
    }

    private init(
        callId: String,
        conversationId: String?,
        participantName: String,
        participantAvatarURL: String?,
        participantVerification: AccountVerificationDesignation?,
        direction: String,
        video: Bool,
        rtc: RTCDetails,
        answeredAt: String? = nil,
        serverTime: String? = nil,
        expectedRoom: String? = nil,
        canHold: Bool = false,
        holdRevision: Int? = nil
    ) throws {
        guard UUID(uuidString: callId) != nil,
              rtc.provider.lowercased() == "livekit",
              let url = URL(string: rtc.url),
              url.scheme?.lowercased() == "wss",
              url.host != nil,
              url.user == nil,
              url.password == nil,
              !rtc.token.isEmpty,
              !rtc.room.isEmpty,
              expectedRoom == nil || expectedRoom == rtc.room
        else { throw CallQueueError.invalidRTC }

        self.callId = callId.lowercased()
        self.conversationId = conversationId.flatMap {
            UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines))?
                .uuidString
                .lowercased()
        }
        self.participantName = participantName
        self.participantAvatarURL = participantAvatarURL
        self.participantVerification = participantVerification
        self.direction = direction.lowercased()
        self.video = video
        self.url = url
        token = rtc.token
        room = rtc.room
        expiresAt = rtc.expiresAt
        self.answeredAt = answeredAt
        self.serverTime = serverTime
        self.canHold = canHold
        self.holdRevision = holdRevision
    }
}

/// Immutable ownership for media credentials. The account epoch changes before sign-out can
/// suspend, while the session ID prevents LiveKit token refresh from borrowing replacement-account
/// authorization after a login switch.
struct CallMediaAccountLease: Hashable, Sendable {
    let accountEpoch: UUID
    let userID: String
    let sessionID: String

    init(accountEpoch: UUID, userID: String, sessionID: String) {
        self.accountEpoch = accountEpoch
        self.userID = userID.lowercased()
        self.sessionID = sessionID
    }
}

/// A replacement account cannot overwrite media authorization left by another account. The old
/// lease must be explicitly revoked first, which makes account activation deterministic and keeps
/// stale handoffs fail-closed even when login/resume tasks complete out of order.
struct CallMediaAccountLeaseGate: Sendable {
    private(set) var authorizedLease: CallMediaAccountLease?

    @discardableResult
    mutating func activate(_ lease: CallMediaAccountLease) -> Bool {
        guard authorizedLease == nil || authorizedLease == lease else { return false }
        authorizedLease = lease
        return true
    }

    mutating func revoke(_ lease: CallMediaAccountLease?) {
        guard lease == nil || authorizedLease == lease else { return }
        authorizedLease = nil
    }

    func accepts(_ lease: CallMediaAccountLease) -> Bool {
        authorizedLease == lease
    }
}

struct AuthenticatedCallMediaHandoff: Sendable {
    let lease: CallMediaAccountLease
    let handoff: CallMediaHandoff
}

struct ActiveCallPresentation: Identifiable, Equatable, Sendable {
    let id: String
    let conversationId: String?
    let participantName: String
    let participantAvatarURL: String?
    let participantVerification: AccountVerificationDesignation?
    let video: Bool
    let direction: String

    init(_ handoff: CallMediaHandoff) {
        self.init(
            id: handoff.callId,
            conversationId: handoff.conversationId,
            participantName: handoff.participantName,
            participantAvatarURL: handoff.participantAvatarURL,
            participantVerification: handoff.participantVerification,
            video: handoff.video,
            direction: handoff.direction
        )
    }

    init(
        id: String,
        conversationId: String? = nil,
        participantName: String,
        participantAvatarURL: String? = nil,
        participantVerification: AccountVerificationDesignation? = nil,
        video: Bool,
        direction: String
    ) {
        self.id = id.lowercased()
        self.conversationId = conversationId.flatMap {
            UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines))?
                .uuidString
                .lowercased()
        }
        self.participantName = participantName
        self.participantAvatarURL = participantAvatarURL
        self.participantVerification = participantVerification
        self.video = video
        self.direction = direction.lowercased()
    }
}

enum ConversationCallIndicatorPolicy {
    static func isLive(
        for conversationId: String,
        activeCall: ActiveCallPresentation?,
        resolvedConversationId: String?,
        isConnected: Bool,
        hasRemoteParticipant: Bool
    ) -> Bool {
        guard isConnected,
              hasRemoteParticipant,
              let activeCall,
              let activeConversationId = resolvedConversationId,
              activeConversationId.caseInsensitiveCompare(conversationId) == .orderedSame
        else { return false }
        return true
    }

    static func label(
        for conversationId: String,
        activeCall: ActiveCallPresentation?,
        resolvedConversationId: String?,
        isConnected: Bool,
        hasRemoteParticipant: Bool,
        elapsedSeconds: Int? = nil
    ) -> String? {
        guard isLive(
            for: conversationId,
            activeCall: activeCall,
            resolvedConversationId: resolvedConversationId,
            isConnected: isConnected,
            hasRemoteParticipant: hasRemoteParticipant
        ), let activeCall
        else { return nil }
        let state = elapsedSeconds.map {
            ConversationCallPresentationPolicy.durationText(max(0, $0))
        } ?? "In call"
        return "\(activeCall.video ? "Video call" : "Voice call") • \(state)"
    }
}

struct CallMediaFailure: Sendable {
    let lease: CallMediaAccountLease
    let callId: String
    let message: String
}

/// Owns the one-media-session-at-a-time invariant independently of LiveKit or CallKit.
/// This narrow type is exercised with a fake transport in unit tests.
@MainActor
final class CallMediaSessionDriver {
    private let transport: any CallMediaTransport
    private(set) var activeCallId: String?
    private var generation: UInt64 = 0
    private var pendingConnect: (generation: UInt64, callId: String)?
    private var teardownTask: Task<Void, Never>?
    private var teardownGeneration: UInt64 = 0

    init(transport: any CallMediaTransport) {
        self.transport = transport
    }

    func connect(_ handoff: CallMediaHandoff) async throws {
        try Task.checkCancellation()
        let callId = handoff.callId.lowercased()
        generation &+= 1
        let connectGeneration = generation
        // A replacement owns its intent before waiting for the old devices to be released.
        // An older connect completing in that gap must not enqueue teardown behind it.
        pendingConnect = (connectGeneration, callId)
        defer {
            if pendingConnect?.generation == connectGeneration { pendingConnect = nil }
        }
        if activeCallId != nil {
            activeCallId = nil
            await enqueueTeardown().value
        } else {
            await teardownTask?.value
        }
        guard generation == connectGeneration, !Task.isCancelled else {
            throw CancellationError()
        }

        activeCallId = callId
        do {
            try await transport.connect(handoff)
        } catch {
            let isCurrentAttempt = generation == connectGeneration
                && activeCallId?.caseInsensitiveCompare(callId) == .orderedSame
            if isCurrentAttempt {
                activeCallId = nil
            } else {
                throw CancellationError()
            }
            throw error
        }

        guard generation == connectGeneration,
              activeCallId?.caseInsensitiveCompare(callId) == .orderedSame
        else {
            // Pending replacements count as owners even before their prior teardown finishes.
            // Only a fully idle state may append cleanup for this stale successful connection.
            if activeCallId == nil, pendingConnect == nil {
                await enqueueTeardown().value
            }
            throw CancellationError()
        }
        if Task.isCancelled {
            activeCallId = nil
            await enqueueTeardown().value
            throw CancellationError()
        }
    }

    func disconnect(callId: String? = nil) async {
        if let callId,
           activeCallId?.caseInsensitiveCompare(callId) != .orderedSame,
           pendingConnect?.callId.caseInsensitiveCompare(callId) != .orderedSame {
            return
        }
        guard activeCallId != nil || pendingConnect != nil else { return }
        let hadActiveTransport = activeCallId != nil
        generation &+= 1
        activeCallId = nil
        pendingConnect = nil
        if hadActiveTransport {
            await enqueueTeardown().value
        } else {
            // A cancelled replacement had not entered transport.connect yet. Its predecessor's
            // teardown already owns device retirement, so wait without another disconnect.
            await teardownTask?.value
        }
    }

    /// Account revocation must invalidate a transport even when a suspended connect has not yet
    /// published `activeCallId`. The generation fence makes its eventual completion stale.
    func reset() async {
        generation &+= 1
        activeCallId = nil
        pendingConnect = nil
        await enqueueTeardown().value
    }

    func didDisconnect(callId: String) {
        guard activeCallId?.caseInsensitiveCompare(callId) == .orderedSame else { return }
        generation &+= 1
        activeCallId = nil
        pendingConnect = nil
    }

    /// Device release may suspend. Every new connection waits for all previously requested
    /// teardowns, including resets that arrived while an earlier disconnect was still running.
    private func enqueueTeardown() -> Task<Void, Never> {
        let previous = teardownTask
        teardownGeneration &+= 1
        let expected = teardownGeneration
        let task = Task { @MainActor [self] in
            await previous?.value
            await transport.disconnect()
            if teardownGeneration == expected { teardownTask = nil }
        }
        teardownTask = task
        return task
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
