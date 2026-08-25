import Combine
import Foundation

// MARK: - Realtime events

/// One event from the realtime broadcast channel. The client models only what presence
/// surfaces render; anything the transport cannot attribute to a concrete peer is dropped
/// at the transport boundary rather than guessed at here.
enum KitRealtimeEvent: Equatable, Sendable {
    case presence(userID: String, isOnline: Bool, lastSeenAt: Date?)
    case typing(conversationID: String, userID: String, isTyping: Bool)
    case syncRequested
    case connectionLive(Bool)
    case availabilityLost
    case conversationUnavailable(conversationID: String)
}

// MARK: - Transport

/// The realtime broadcast transport. The production implementation plugs in once the
/// backend contract is final; everything above this protocol (state, expiry, throttling,
/// UI-ready queries) is already exercised against it. Every completed `start` returns a fresh
/// event stream scoped to that session: cancelling an `AsyncStream` consumer terminates that
/// stream, so a stopped stream must never be reused by a later account. `stop()` is the
/// cancellation boundary and must promptly unblock any in-flight `start` or send call.
protocol KitRealtimeTransport: AnyObject, Sendable {
    func start(userID: String, sessionID: String) async -> AsyncStream<KitRealtimeEvent>
    func stop() async
    func sendTyping(conversationID: String, isTyping: Bool) async
    func sendPresenceHeartbeat() async
    func configure(_ configuration: KitRealtimeConfiguration?) async
    func setForeground(_ foreground: Bool) async
    func observeConversation(_ conversationID: String) async
    func unobserveConversation(_ conversationID: String) async
}

extension KitRealtimeTransport {
    func configure(_ configuration: KitRealtimeConfiguration?) async {}
    func setForeground(_ foreground: Bool) async {}
    func observeConversation(_ conversationID: String) async {}
    func unobserveConversation(_ conversationID: String) async {}
}

/// Placeholder transport used until the backend broadcast contract lands. It connects to
/// nothing, sends nothing, and never yields an event, so every presence surface stays
/// empty rather than guessing. Each start retains a new continuation so its stream parks
/// consumers instead of finishing immediately (a finished stream would look like a clean
/// shutdown).
actor PendingRealtimeTransport: KitRealtimeTransport {
    private var eventContinuation: AsyncStream<KitRealtimeEvent>.Continuation?

    func start(
        userID: String,
        sessionID: String
    ) async -> AsyncStream<KitRealtimeEvent> {
        eventContinuation?.finish()
        let pair = AsyncStream.makeStream(of: KitRealtimeEvent.self)
        eventContinuation = pair.continuation
        return pair.stream
    }

    func stop() async {
        eventContinuation?.finish()
        eventContinuation = nil
    }

    func sendTyping(conversationID: String, isTyping: Bool) async {}
    func sendPresenceHeartbeat() async {}
}

// MARK: - Presence state

/// The last presence fact received for one peer, stamped with when this client received it
/// so staleness is judged locally rather than trusting a remote clock.
struct PeerPresenceState: Equatable {
    let isOnline: Bool
    let lastSeenAt: Date?
    let receivedAt: Date
}

// MARK: - Policy

/// Pure presence rules. Every function takes `now` so expiry and labeling are testable
/// without waiting on wall clocks.
enum KitPresencePolicy {
    static let featureKey = "messaging_presence_v1"
    static let typingDebounce: TimeInterval = 0.3
    /// A typing signal disappears this long after the last keystroke event.
    static let typingExpiry: TimeInterval = 6
    /// Minimum spacing between outbound `isTyping: true` sends per conversation.
    static let typingSendMinimumInterval: TimeInterval = 4
    /// Reverb presence membership is authoritative until a member-removal or local transport-loss
    /// event arrives. It is not a peer-authored heartbeat and therefore has no client-side TTL.
    static func isConsideredOnline(_ state: PeerPresenceState, now: Date) -> Bool {
        state.isOnline
    }

    /// UI-ready availability line for a conversation header. Returns `nil` whenever there
    /// is no truthful statement to make (no data, or no last-seen timestamp).
    static func lastSeenLabel(
        for state: PeerPresenceState?,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String? {
        guard let state else { return nil }
        if isConsideredOnline(state, now: now) { return "online" }
        guard let lastSeenAt = state.lastSeenAt else { return nil }

        let interval = now.timeIntervalSince(lastSeenAt)
        if interval < 120 { return "last seen just now" }
        if interval < 3_600 { return "last seen \(Int(interval / 60)) min ago" }
        if calendar.isDate(lastSeenAt, inSameDayAs: now) {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = locale
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return "last seen today at \(formatter.string(from: lastSeenAt))"
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.dateFormat = "d MMM"
        return "last seen \(formatter.string(from: lastSeenAt))"
    }

    /// UI-ready typing line for a conversation. `names` are display names of currently
    /// typing peers; returns `nil` when nobody is typing.
    static func typingLabel(names: [String]) -> String? {
        switch names.count {
        case 0:
            return nil
        case 1:
            return "\(names[0]) is typing…"
        case 2:
            return "\(names[0]) and \(names[1]) are typing…"
        default:
            return "Several people are typing…"
        }
    }
}

// MARK: - Presence center

/// Client-side realtime presence store. Consumes `KitRealtimeEvent`s from whatever
/// transport is installed, keeps peer presence and per-conversation typing state with
/// local expiry, and throttles this client's outbound typing signals.
@MainActor
final class KitPresenceCenter: ObservableObject {
    static let shared = KitPresenceCenter()

    /// Last presence fact per peer, keyed by lowercased user ID.
    @Published private(set) var peerPresence: [String: PeerPresenceState] = [:]
    /// conversationID (lowercased) → userID (lowercased) → expiry of the typing signal.
    @Published private(set) var typing: [String: [String: Date]] = [:]

    var transport: any KitRealtimeTransport = KitReverbRealtimeTransport()
    /// A server capability alone must never expose a control backed by the no-op transport.
    var hasProductionTransport: Bool { !(transport is PendingRealtimeTransport) }
    @Published private(set) var isLive = false
    var syncRequestHandler: ((String, String) -> Void)?
    /// Notifies the durable-sync owner when the signalling transport becomes usable or is lost.
    /// Presence privacy does not gate this callback: message delivery still relies on the
    /// authenticated user channel when a user chooses not to publish or render presence.
    var connectionStateHandler: ((Bool) -> Void)?
    /// The communication privacy toggle sets this; while `false` this client sends no
    /// heartbeats and no new typing signals.
    /// The privacy toggle is symmetric, like read receipts: turning your own status off also
    /// stops this device from rendering anyone else's (and clears whatever it already holds).
    var broadcastsPresence = true {
        didSet {
            guard oldValue != broadcastsPresence else { return }
            if broadcastsPresence {
                enablePresenceBroadcasting()
                return
            }
            disablePresenceBroadcasting()
        }
    }
    private(set) var isStarted = false

    private var selfUserID: String?
    private var activeSessionID: String?
    private var activeConfiguration: KitRealtimeConfiguration?
    private var activeTransport: (any KitRealtimeTransport)?
    private var sessionReadyTask: Task<AsyncStream<KitRealtimeEvent>?, Never>?
    private var eventTask: Task<Void, Never>?
    private var sweepTask: Task<Void, Never>?
    /// The in-flight transport shutdown, so a start racing an account switch cannot connect
    /// before the previous session finished disconnecting.
    private var pendingTransportStop: Task<Void, Never>?
    /// Every heartbeat and typing command joins one ordered queue. Shutdown closes the transport
    /// and drains this tail before the next account may start.
    private var outboundTail: Task<Void, Never>?
    private var sessionGeneration: UInt64 = 0
    private var outboundGeneration: UInt64 = 0
    /// Throttle bookkeeping per lowercased conversation ID.
    private var lastTypingSentAt: [String: Date] = [:]
    /// Auto-stop timers per lowercased conversation ID.
    private var typingAutoStopTasks: [String: Task<Void, Never>] = [:]
    private var typingDebounceTasks: [String: Task<Void, Never>] = [:]
    /// The current local typing intent. Its token prevents an expired/cancelled intent's queued
    /// `true` from being sent after a later stop or a new typing cycle for the same conversation.
    private var typingIntentTokens: [String: UInt64] = [:]
    private var nextTypingIntentToken: UInt64 = 0
    /// Conversations where an `isTyping: true` was sent and not yet retracted.
    private var unstoppedTypingConversations: Set<String> = []
    private var activeConversationID: String?
    private var isForeground = false
    /// Monotonic intent fence for foreground delivery. Transport calls are actor hops and may
    /// suspend, so two rapid scene transitions are not guaranteed to complete in call order.
    /// Every completion replays the newest intent before it can become the final transport state.
    private var foregroundGeneration: UInt64 = 0

    private enum OutboundCommand: Sendable {
        case typing(conversationID: String, isTyping: Bool, intentToken: UInt64?)
        case observe(conversationID: String)
        case unobserve(conversationID: String)
    }

    /// Idempotent for the same account/session/configuration. A changed capability advertisement
    /// is an ordered restart too: socket key, timeouts, and feature flags are server authority.
    func start(
        userID: String,
        sessionID: String,
        configuration: KitRealtimeConfiguration? = nil
    ) {
        let canonicalUserID = userID.lowercased()
        if isStarted {
            guard selfUserID != canonicalUserID
                    || activeSessionID != sessionID
                    || activeConfiguration != configuration
            else { return }
            stop()
        }
        sessionGeneration &+= 1
        let generation = sessionGeneration
        isStarted = true
        selfUserID = canonicalUserID
        activeSessionID = sessionID
        activeConfiguration = configuration

        let transport = self.transport
        activeTransport = transport
        let previousStop = pendingTransportStop
        let readiness: Task<AsyncStream<KitRealtimeEvent>?, Never> = Task { [weak self] in
            // Order the lifecycle: never connect the next session while the previous
            // session's disconnect is still in flight (account switches) — and never
            // connect at all if this start was already cancelled while waiting.
            await previousStop?.value
            guard !Task.isCancelled,
                  let self,
                  self.isStarted,
                  self.sessionGeneration == generation
            else { return nil }
            await transport.configure(configuration)
            await self.deliverForeground(
                self.isForeground,
                generation: self.foregroundGeneration,
                to: transport
            )
            let events = await transport.start(userID: userID, sessionID: sessionID)
            guard !Task.isCancelled,
                  self.isStarted,
                  self.sessionGeneration == generation
            else { return nil }
            return events
        }
        sessionReadyTask = readiness
        eventTask = Task { [weak self] in
            guard let events = await readiness.value,
                  !Task.isCancelled,
                  let self,
                  self.isStarted,
                  self.sessionGeneration == generation
            else { return }
            for await event in events {
                guard !Task.isCancelled,
                      self.isStarted,
                      self.sessionGeneration == generation
                else { return }
                self.apply(event)
            }
        }
        sweepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                self.sweepExpiredState()
            }
        }
        if broadcastsPresence, let activeConversationID {
            enqueueOutbound(.observe(conversationID: activeConversationID))
        }
    }

    /// Cancels the consume/heartbeat/sweep loops, clears all published and private state,
    /// and stops the transport.
    func stop() {
        // A second reset while the first asynchronous stop is still running must not replace
        // the stop that the next start is required to await.
        guard isStarted else {
            peerPresence = [:]
            typing = [:]
            selfUserID = nil
            activeSessionID = nil
            return
        }

        let transport = activeTransport ?? self.transport
        let previousStop = pendingTransportStop
        let readiness = sessionReadyTask
        let pendingOutbound = outboundTail

        sessionGeneration &+= 1
        outboundGeneration &+= 1
        isStarted = false
        selfUserID = nil
        activeSessionID = nil
        activeConfiguration = nil

        readiness?.cancel()
        eventTask?.cancel()
        sweepTask?.cancel()
        sessionReadyTask = nil
        eventTask = nil
        sweepTask = nil
        activeTransport = nil
        outboundTail = nil
        for task in typingAutoStopTasks.values { task.cancel() }
        typingAutoStopTasks = [:]
        for task in typingDebounceTasks.values { task.cancel() }
        typingDebounceTasks = [:]
        typingIntentTokens = [:]
        lastTypingSentAt = [:]
        unstoppedTypingConversations = []
        peerPresence = [:]
        typing = [:]
        setLiveState(false)
        pendingTransportStop = Task {
            await previousStop?.value
            // Stop is the protocol's cancellation/close primitive. Invoke it before awaiting a
            // potentially suspended start or send so network work cannot deadlock shutdown.
            await transport.stop()
            _ = await readiness?.value
            await pendingOutbound?.value
        }
    }

    /// Full clear for sign-out or account switch. Nothing about the previous account's
    /// peers may survive into the next session.
    func reset() {
        stop()
        activeConversationID = nil
        syncRequestHandler = nil
        connectionStateHandler = nil
    }

    func setForeground(_ foreground: Bool) {
        isForeground = foreground
        foregroundGeneration &+= 1
        let generation = foregroundGeneration
        let transport = activeTransport ?? self.transport
        Task { [weak self] in
            await self?.deliverForeground(
                foreground,
                generation: generation,
                to: transport
            )
        }
    }

    private func deliverForeground(
        _ initialForeground: Bool,
        generation initialGeneration: UInt64,
        to transport: any KitRealtimeTransport
    ) async {
        var foreground = initialForeground
        var generation = initialGeneration
        while true {
            await transport.setForeground(foreground)

            // An account switch may replace the injected transport while this actor hop is
            // suspended. Its ordered stop owns the old transport; never replay new-account state
            // into that retired instance.
            let currentTransport = activeTransport ?? self.transport
            guard ObjectIdentifier(currentTransport) == ObjectIdentifier(transport) else { return }

            let latestGeneration = foregroundGeneration
            guard generation != latestGeneration else { return }
            foreground = isForeground
            generation = latestGeneration
        }
    }

    func observeConversation(_ conversationID: String) {
        guard let canonical = KitRealtimeIdentifierPolicy.canonicalConversationID(conversationID)
        else { return }
        if let previous = activeConversationID, previous != canonical {
            stopLocalTyping(conversationID: previous)
            if isStarted { enqueueOutbound(.unobserve(conversationID: previous), requiresBroadcast: false) }
        }
        activeConversationID = canonical
        guard broadcastsPresence, isStarted else { return }
        enqueueOutbound(.observe(conversationID: canonical), requiresBroadcast: false)
    }

    func unobserveConversation(_ conversationID: String) {
        guard let canonical = KitRealtimeIdentifierPolicy.canonicalConversationID(conversationID),
              activeConversationID == canonical
        else { return }
        stopLocalTyping(conversationID: canonical)
        activeConversationID = nil
        typing[canonical] = nil
        guard isStarted else { return }
        enqueueOutbound(.unobserve(conversationID: canonical), requiresBroadcast: false)
    }

    /// Applies one inbound event. Events about this client's own user are ignored — local
    /// surfaces must never render self-presence echoed back by the server.
    func apply(_ event: KitRealtimeEvent, now: Date = Date()) {
        switch event {
        case .presence(let userID, let isOnline, let lastSeenAt):
            // Symmetric privacy applies only to peer-visible ephemeral state. The user-channel
            // connection and durable sync nudges remain operational while presence is private.
            guard broadcastsPresence else { return }
            let key = userID.lowercased()
            guard key != selfUserID else { return }
            peerPresence[key] = PeerPresenceState(
                isOnline: isOnline,
                lastSeenAt: lastSeenAt,
                receivedAt: now
            )
        case .typing(let conversationID, let userID, let isTyping):
            guard broadcastsPresence else { return }
            let conversationKey = conversationID.lowercased()
            let userKey = userID.lowercased()
            guard userKey != selfUserID else { return }
            if isTyping {
                typing[conversationKey, default: [:]][userKey] =
                    now.addingTimeInterval(KitPresencePolicy.typingExpiry)
            } else if var members = typing[conversationKey] {
                members[userKey] = nil
                typing[conversationKey] = members.isEmpty ? nil : members
            }
        case .syncRequested:
            guard let selfUserID, let activeSessionID else { return }
            syncRequestHandler?(selfUserID, activeSessionID)
        case .connectionLive(let live):
            setLiveState(live)
        case .availabilityLost:
            setLiveState(false)
            peerPresence = [:]
            typing = [:]
        case .conversationUnavailable(let conversationID):
            typing[conversationID.lowercased()] = nil
        }
    }

    private func setLiveState(_ live: Bool) {
        guard isLive != live else { return }
        isLive = live
        connectionStateHandler?(live)
    }

    /// Unexpired typers in a conversation, sorted for deterministic rendering.
    func typingUserIDs(in conversationID: String, now: Date = Date()) -> [String] {
        guard let members = typing[conversationID.lowercased()] else { return [] }
        return members.filter { $0.value > now }.keys.sorted()
    }

    func presenceState(for userID: String?) -> PeerPresenceState? {
        guard let userID else { return nil }
        return peerPresence[userID.lowercased()]
    }

    func isPeerOnline(_ userID: String?, now: Date = Date()) -> Bool {
        guard let state = presenceState(for: userID) else { return false }
        return KitPresencePolicy.isConsideredOnline(state, now: now)
    }

    // MARK: Outbound typing

    /// Call on every local keystroke in a conversation. Sends at most one
    /// `isTyping: true` per `typingSendMinimumInterval` per conversation, and (re)arms an
    /// auto-stop that retracts the signal after `typingExpiry` seconds of silence.
    func recordLocalTyping(conversationID: String, now: Date = Date()) {
        guard broadcastsPresence, isStarted else { return }
        let key = conversationID.lowercased()
        let intentToken: UInt64
        if let existing = typingIntentTokens[key] {
            intentToken = existing
        } else {
            nextTypingIntentToken &+= 1
            intentToken = nextTypingIntentToken
            typingIntentTokens[key] = intentToken
        }

        let dueForSend: Bool
        if let lastSent = lastTypingSentAt[key] {
            dueForSend = now.timeIntervalSince(lastSent)
                >= KitPresencePolicy.typingSendMinimumInterval
        } else {
            dueForSend = true
        }
        if dueForSend, typingDebounceTasks[key] == nil {
            if lastTypingSentAt[key] == nil {
                typingDebounceTasks[key] = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(KitPresencePolicy.typingDebounce))
                    guard !Task.isCancelled else { return }
                    self?.sendDebouncedTypingStart(
                        forKey: key,
                        conversationID: conversationID,
                        intentToken: intentToken
                    )
                }
            } else {
                lastTypingSentAt[key] = now
                enqueueOutbound(.typing(
                    conversationID: conversationID,
                    isTyping: true,
                    intentToken: intentToken
                ))
            }
        }

        typingAutoStopTasks[key]?.cancel()
        typingAutoStopTasks[key] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(KitPresencePolicy.typingExpiry))
            guard !Task.isCancelled else { return }
            self?.retractLocalTyping(
                forKey: key,
                conversationID: conversationID,
                expectedIntentToken: intentToken
            )
        }
    }

    /// Call when the local user sends the message or leaves the conversation. Cancels the
    /// auto-stop and retracts immediately if a `true` is still outstanding.
    func stopLocalTyping(conversationID: String) {
        guard isStarted else { return }
        let key = conversationID.lowercased()
        typingDebounceTasks[key]?.cancel()
        typingDebounceTasks[key] = nil
        typingAutoStopTasks[key]?.cancel()
        typingAutoStopTasks[key] = nil
        retractLocalTyping(
            forKey: key,
            conversationID: conversationID,
            expectedIntentToken: nil
        )
    }

    private func sendDebouncedTypingStart(
        forKey key: String,
        conversationID: String,
        intentToken: UInt64
    ) {
        typingDebounceTasks[key] = nil
        guard broadcastsPresence,
              isStarted,
              activeConversationID == key,
              typingIntentTokens[key] == intentToken
        else { return }
        lastTypingSentAt[key] = Date()
        enqueueOutbound(.typing(
            conversationID: conversationID,
            isTyping: true,
            intentToken: intentToken
        ))
    }

    /// Sends `isTyping: false` if a `true` was sent and not yet retracted. Retraction is
    /// deliberately not gated on `broadcastsPresence`: if the privacy toggle flips off
    /// mid-composition, suppressing the clear would strand peers on a stale "typing…" row.
    private func retractLocalTyping(
        forKey key: String,
        conversationID: String,
        expectedIntentToken: UInt64?
    ) {
        if let expectedIntentToken,
           typingIntentTokens[key] != expectedIntentToken {
            return
        }
        typingAutoStopTasks[key] = nil
        typingIntentTokens[key] = nil
        lastTypingSentAt[key] = nil
        guard unstoppedTypingConversations.remove(key) != nil else { return }
        guard isStarted else { return }
        enqueueOutbound(
            .typing(conversationID: conversationID, isTyping: false, intentToken: nil),
            requiresBroadcast: false
        )
    }

    /// Invalidates queued public status sends before retracting any `true` that already entered
    /// the transport. Retractions remain ordered behind those in-flight sends and are allowed
    /// while private; a rapid re-enable queues new work behind the retractions.
    private func disablePresenceBroadcasting() {
        outboundGeneration &+= 1
        for task in typingAutoStopTasks.values { task.cancel() }
        typingAutoStopTasks = [:]
        for task in typingDebounceTasks.values { task.cancel() }
        typingDebounceTasks = [:]
        typingIntentTokens = [:]
        lastTypingSentAt = [:]
        let conversationsToRetract = unstoppedTypingConversations.sorted()
        unstoppedTypingConversations = []
        peerPresence = [:]
        typing = [:]

        guard isStarted else { return }
        for conversationID in conversationsToRetract {
            enqueueOutbound(
                .typing(conversationID: conversationID, isTyping: false, intentToken: nil),
                requiresBroadcast: false
            )
        }
        if let activeConversationID {
            enqueueOutbound(
                .unobserve(conversationID: activeConversationID),
                requiresBroadcast: false
            )
        }
    }

    private func enablePresenceBroadcasting() {
        guard isStarted, let activeConversationID else { return }
        enqueueOutbound(.observe(conversationID: activeConversationID))
    }

    /// Adds one outbound command to the current session's ordered transport queue. Public status
    /// commands validate both session and privacy generations after startup and prior commands
    /// finish. Retractions ignore later privacy changes but remain bound to the session.
    private func enqueueOutbound(
        _ command: OutboundCommand,
        requiresBroadcast: Bool = true
    ) {
        guard isStarted,
              let readiness = sessionReadyTask,
              let transport = activeTransport
        else { return }
        let previous = outboundTail
        let expectedSessionGeneration = sessionGeneration
        let expectedOutboundGeneration = outboundGeneration
        let task = Task { [weak self] in
            await previous?.value
            guard await readiness.value != nil,
                  !Task.isCancelled,
                  let self,
                  self.isStarted,
                  self.sessionGeneration == expectedSessionGeneration,
                  (!requiresBroadcast
                    || (self.outboundGeneration == expectedOutboundGeneration
                        && self.broadcastsPresence))
            else { return }

            switch command {
            case .typing(let conversationID, let isTyping, let intentToken):
                if isTyping {
                    let key = conversationID.lowercased()
                    guard let intentToken,
                          self.typingIntentTokens[key] == intentToken
                    else { return }
                    self.unstoppedTypingConversations.insert(key)
                }
                await transport.sendTyping(
                    conversationID: conversationID,
                    isTyping: isTyping
                )
            case .observe(let conversationID):
                await transport.observeConversation(conversationID)
            case .unobserve(let conversationID):
                await transport.unobserveConversation(conversationID)
            }
        }
        outboundTail = task
    }

    // MARK: Expiry sweep

    /// Drops expired typing entries, republishing only when something actually changed so the
    /// 2-second sweep does not cause redundant SwiftUI invalidation.
    func sweepExpiredState(now: Date = Date()) {
        var updated = typing
        var changed = false
        for (conversationKey, members) in typing {
            let live = members.filter { $0.value > now }
            guard live.count != members.count else { continue }
            changed = true
            updated[conversationKey] = live.isEmpty ? nil : live
        }
        if changed { typing = updated }
    }
}
