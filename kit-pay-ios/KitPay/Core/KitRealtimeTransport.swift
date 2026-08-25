import CoreFoundation
import Foundation

enum KitRealtimeConnectionState: Equatable, Sendable {
    case idle
    case connecting
    case handshaking
    case subscribing
    case live
    case backoff
    case suspended
}

struct KitRealtimeAuthorization: Decodable, Equatable, Sendable {
    let auth: String
    let channelData: String?

    private enum CodingKeys: String, CodingKey {
        case auth
        case channelData = "channel_data"
    }
}

struct KitRealtimeRequestError: Error, Equatable, Sendable {
    let status: Int
    let retryAfter: TimeInterval?
}

protocol KitRealtimeAPI: Sendable {
    func realtimeChannelAuthorization(
        path: String,
        socketID: String,
        channelName: String,
        boundSessionID: String
    ) async throws -> KitRealtimeAuthorization

    func sendRealtimeTyping(
        conversationID: String,
        state: String,
        socketID: String,
        boundSessionID: String
    ) async throws
}

extension APIClient: KitRealtimeAPI {}

enum KitRealtimeIdentifierPolicy {
    static func canonicalUserID(_ value: String) -> String? {
        let canonical = value.lowercased()
        guard canonical == value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              (1 ... 128).contains(canonical.utf8.count),
              canonical.unicodeScalars.allSatisfy({
                  (0x61 ... 0x7A).contains($0.value)
                      || (0x30 ... 0x39).contains($0.value)
                      || $0.value == 0x2D
                      || $0.value == 0x5F
              })
        else { return nil }
        return canonical
    }

    static func canonicalConversationID(_ value: String) -> String? {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              let identifier = UUID(uuidString: value)
        else { return nil }
        let canonical = identifier.uuidString.lowercased()
        return canonical.caseInsensitiveCompare(value) == .orderedSame ? canonical : nil
    }

    static func validSocketID(_ value: String) -> Bool {
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        return pieces.count == 2
            && value.utf8.count <= 64
            && pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
    }
}

enum KitPusherInboundFrame: Equatable, Sendable {
    case connectionEstablished(socketID: String, activityTimeout: TimeInterval)
    case ping
    case pong
    case error(code: Int?, message: String?)
    case subscriptionSucceeded(channel: String, presenceUserIDs: [String]?)
    case memberAdded(channel: String, userID: String)
    case memberRemoved(channel: String, userID: String)
    case syncNudge(channel: String)
    case typing(channel: String, userID: String, isTyping: Bool)
    case ignored
    case rejectedClientEvent

    /// Reverb does not authorize client events. They are expected hostile/noise input and are
    /// ignored without allowing a peer to force this client into its malformed-frame suspension.
    var countsTowardDroppedFrameFlood: Bool {
        if case .ignored = self { return true }
        return false
    }
}

enum KitPusherCodec {
    static let maximumFrameBytes = 16 * 1_024

    static func decode(_ text: String) -> KitPusherInboundFrame? {
        guard !text.isEmpty,
              text.utf8.count <= maximumFrameBytes,
              let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data),
              let object = root as? [String: Any],
              let event = object["event"] as? String,
              !event.isEmpty,
              event.utf8.count <= 160
        else { return nil }

        // The bounded top-level JSON parse is unavoidable, but no client-event data member is
        // semantically decoded: Reverb neither authorizes nor attributes those frames.
        if event.hasPrefix("client-") { return .rejectedClientEvent }

        switch event {
        case "pusher:connection_established":
            guard let payload = stringEncodedObject(object["data"]),
                  let socketID = payload["socket_id"] as? String,
                  KitRealtimeIdentifierPolicy.validSocketID(socketID),
                  let activityTimeout = exactInteger(payload["activity_timeout"]),
                  (10 ... 120).contains(activityTimeout)
            else { return nil }
            return .connectionEstablished(
                socketID: socketID,
                activityTimeout: TimeInterval(activityTimeout)
            )
        case "pusher:ping":
            return .ping
        case "pusher:pong":
            return .pong
        case "pusher:error":
            guard let payload = stringEncodedObject(object["data"]) else { return nil }
            let code = exactInteger(payload["code"])
            let message = (payload["message"] as? String).flatMap {
                $0.utf8.count <= 512 ? $0 : nil
            }
            return .error(code: code, message: message)
        case "pusher_internal:subscription_succeeded":
            guard let channel = channel(in: object),
                  let payload = stringEncodedObject(object["data"])
            else { return nil }
            guard channel.hasPrefix("presence-kit.conv.") else {
                return .subscriptionSucceeded(channel: channel, presenceUserIDs: nil)
            }
            guard let presence = payload["presence"] as? [String: Any],
                  let rawIDs = presence["ids"] as? [Any],
                  rawIDs.count <= 64
            else { return nil }
            let identifiers = rawIDs.compactMap { raw -> String? in
                guard let raw = raw as? String else { return nil }
                return KitRealtimeIdentifierPolicy.canonicalUserID(raw)
            }
            guard identifiers.count == rawIDs.count,
                  Set(identifiers).count == identifiers.count
            else { return nil }
            return .subscriptionSucceeded(
                channel: channel,
                presenceUserIDs: identifiers.sorted()
            )
        case "pusher_internal:member_added", "pusher_internal:member_removed":
            guard let channel = channel(in: object),
                  let payload = stringEncodedObject(object["data"]),
                  let rawUserID = payload["user_id"] as? String,
                  let userID = KitRealtimeIdentifierPolicy.canonicalUserID(rawUserID)
            else { return nil }
            return event.hasSuffix("member_added")
                ? .memberAdded(channel: channel, userID: userID)
                : .memberRemoved(channel: channel, userID: userID)
        case "kit.sync.nudge":
            guard let channel = channel(in: object),
                  let payload = applicationObject(object["data"]),
                  Set(payload.keys) == ["v"],
                  exactInteger(payload["v"]) == 1
            else { return nil }
            return .syncNudge(channel: channel)
        case "kit.typing", "kit.typing.stop":
            guard let channel = channel(in: object),
                  let payload = applicationObject(object["data"]),
                  Set(payload.keys) == ["v", "user"],
                  exactInteger(payload["v"]) == 1,
                  let rawUserID = payload["user"] as? String,
                  let userID = KitRealtimeIdentifierPolicy.canonicalUserID(rawUserID)
            else { return nil }
            return .typing(
                channel: channel,
                userID: userID,
                isTyping: event == "kit.typing"
            )
        default:
            return .ignored
        }
    }

    static func pong() -> String? { encode(event: "pusher:pong", data: [:]) }
    static func ping() -> String? { encode(event: "pusher:ping", data: [:]) }
    static func subscribe(channel: String, auth: String, channelData: String?) -> String? {
        var data = ["auth": auth, "channel": channel]
        if let channelData { data["channel_data"] = channelData }
        return encode(event: "pusher:subscribe", data: data)
    }
    static func unsubscribe(channel: String) -> String? {
        encode(event: "pusher:unsubscribe", data: ["channel": channel])
    }

    private static func channel(in object: [String: Any]) -> String? {
        guard let channel = object["channel"] as? String,
              !channel.isEmpty,
              channel.utf8.count <= 160,
              channel.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0)
                      || $0.value == 0x2D
                      || $0.value == 0x2E
                      || $0.value == 0x5F
              })
        else { return nil }
        return channel
    }

    private static func stringEncodedObject(_ value: Any?) -> [String: Any]? {
        guard let string = value as? String,
              string.utf8.count <= maximumFrameBytes,
              let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    private static func applicationObject(_ value: Any?) -> [String: Any]? {
        if let object = value as? [String: Any] { return object }
        return stringEncodedObject(value)
    }

    private static func exactInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let integer = number.intValue
        return number.doubleValue == Double(integer) ? integer : nil
    }

    private static func encode(event: String, data: [String: String]) -> String? {
        guard JSONSerialization.isValidJSONObject(["event": event, "data": data]),
              let encoded = try? JSONSerialization.data(
                  withJSONObject: ["event": event, "data": data],
                  options: [.sortedKeys]
              )
        else { return nil }
        return String(data: encoded, encoding: .utf8)
    }
}

enum KitRealtimeFailureDisposition: Equatable, Sendable {
    case suspendSession
    case backoff(minimumDelay: TimeInterval)
    case reconnectImmediately
}

enum KitRealtimeReconnectPolicy {
    static let maximumBackoff: TimeInterval = 60
    static func disposition(forPusherErrorCode code: Int?) -> KitRealtimeFailureDisposition {
        guard let code else { return .backoff(minimumDelay: 0) }
        switch code {
        case 4_000 ... 4_099: return .suspendSession
        case 4_100 ... 4_199: return .backoff(minimumDelay: 1)
        case 4_200...: return .reconnectImmediately
        default: return .backoff(minimumDelay: 0)
        }
    }
    static func maximumDelay(attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 1 }
        return min(pow(2, Double(min(attempt, 6))), maximumBackoff)
    }
}

struct KitRealtimeDropGuard: Equatable, Sendable {
    static let limit = 20
    static let window: TimeInterval = 60
    private(set) var timestamps: [Date] = []
    mutating func record(at now: Date) -> Bool {
        timestamps.removeAll { now.timeIntervalSince($0) >= Self.window }
        timestamps.append(now)
        return timestamps.count >= Self.limit
    }
    mutating func reset() { timestamps = [] }
}

enum KitRealtimePollingPolicy {
    static let legacyInterval: TimeInterval = 10
    static let disconnectedInterval: TimeInterval = 15
    static let degradedInterval: TimeInterval = 60
    static let liveIdleInterval: TimeInterval = 45
    static let degradeAfter: TimeInterval = 5 * 60
    static func interval(
        hasRealtimeConfiguration: Bool,
        isLive: Bool,
        disconnectedFor: TimeInterval
    ) -> TimeInterval {
        guard hasRealtimeConfiguration else { return legacyInterval }
        if isLive { return liveIdleInterval }
        return disconnectedFor >= degradeAfter ? degradedInterval : disconnectedInterval
    }
}

private enum KitRealtimeLoopFailure: Error {
    case retry(minimumDelay: TimeInterval)
    case reconnectImmediately
    case suspendSession
    case pause
    case rollover
    case droppedFrameFlood
}

/// Native Pusher-protocol-7 transport for Laravel Reverb. The socket is signalling-only: it can
/// request a durable REST sync and carry ephemeral presence/typing, but it never carries message
/// content, a cursor, an event identifier, or anything that can mutate the encrypted projection.
actor KitReverbRealtimeTransport: KitRealtimeTransport {
    private static let handshakeTimeout: TimeInterval = 10
    private static let pongTimeout: TimeInterval = 10
    private static let presenceReconnectHold: TimeInterval = 5
    private static let droppedFrameSuspension: TimeInterval = 15 * 60
    private static let liveBackoffResetAfter: TimeInterval = 60

    private let api: any KitRealtimeAPI
    private let urlSession: URLSession

    private var preparedConfiguration: KitRealtimeConfiguration?
    private var configuration: KitRealtimeConfiguration?
    private var userID: String?
    private var boundSessionID: String?
    private var eventContinuation: AsyncStream<KitRealtimeEvent>.Continuation?
    private var sessionGeneration: UInt64 = 0
    private var isForeground = false
    private var connectionState: KitRealtimeConnectionState = .idle
    private var runTask: Task<Void, Never>?
    /// Separates foreground reconnect loops within one authenticated session. A cancelled
    /// background loop must not clear the replacement task when its defer runs later.
    private var runLoopGeneration: UInt64 = 0
    private var heartbeatTask: Task<Void, Never>?
    private var lifetimeTask: Task<Void, Never>?
    private var liveResetTask: Task<Void, Never>?
    private var presenceHoldTask: Task<Void, Never>?
    private var webSocket: URLSessionWebSocketTask?
    private var socketID: String?
    private var userChannel: String?
    private var subscribedChannels: Set<String> = []
    private var pendingChannels: Set<String> = []
    private var desiredConversationIDs: Set<String> = []
    private var deniedConversationIDs: Set<String> = []
    private var conversationIDByChannel: [String: String] = [:]
    private var presenceRosterByChannel: [String: Set<String>] = [:]
    private var lastTypingFrameAt: [String: Date] = [:]
    private var lastInboundAt: Date?
    private var pingSentAt: Date?
    private var forcedFailure: KitRealtimeLoopFailure?
    private var reconnectAttempt = 0
    private var dropGuard = KitRealtimeDropGuard()

    init(
        api: any KitRealtimeAPI = APIClient.shared,
        urlSession: URLSession = .shared
    ) {
        self.api = api
        self.urlSession = urlSession
    }

    func configure(_ configuration: KitRealtimeConfiguration?) async {
        preparedConfiguration = configuration
    }

    func start(
        userID: String,
        sessionID: String
    ) async -> AsyncStream<KitRealtimeEvent> {
        await start(
            userID: userID,
            sessionID: sessionID,
            configuration: preparedConfiguration
        )
    }

    private func start(
        userID rawUserID: String,
        sessionID: String,
        configuration: KitRealtimeConfiguration?
    ) async -> AsyncStream<KitRealtimeEvent> {
        await stop()
        let pair = AsyncStream.makeStream(of: KitRealtimeEvent.self)
        eventContinuation = pair.continuation

        guard let configuration,
              let userID = KitRealtimeIdentifierPolicy.canonicalUserID(rawUserID),
              SessionRefreshPolicy.isValidSessionID(sessionID),
              configuration.socketURL != nil
        else {
            pair.continuation.finish()
            return pair.stream
        }

        sessionGeneration &+= 1
        self.configuration = configuration
        self.userID = userID
        boundSessionID = sessionID
        deniedConversationIDs = []
        dropGuard.reset()
        reconnectAttempt = 0
        let generation = sessionGeneration
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.consumerTerminated(generation: generation) }
        }
        ensureRunLoop()
        return pair.stream
    }

    func stop() async {
        sessionGeneration &+= 1
        let continuation = eventContinuation
        eventContinuation = nil
        configuration = nil
        userID = nil
        boundSessionID = nil
        desiredConversationIDs = []
        deniedConversationIDs = []
        runLoopGeneration &+= 1
        runTask?.cancel()
        runTask = nil
        await closeActiveSocket(clean: true, holdsPresenceBriefly: false)
        connectionState = .idle
        continuation?.finish()
    }

    func setForeground(_ foreground: Bool) async {
        guard isForeground != foreground else { return }
        isForeground = foreground
        if foreground {
            ensureRunLoop()
            return
        }
        await disconnectForBackground(generation: sessionGeneration)
    }

    func observeConversation(_ rawConversationID: String) async {
        guard let conversationID = KitRealtimeIdentifierPolicy.canonicalConversationID(
            rawConversationID
        ) else { return }
        desiredConversationIDs.insert(conversationID)
        guard connectionState == .live else { return }
        await subscribeConversationIfNeeded(conversationID)
    }

    func unobserveConversation(_ rawConversationID: String) async {
        guard let conversationID = KitRealtimeIdentifierPolicy.canonicalConversationID(
            rawConversationID
        ) else { return }
        desiredConversationIDs.remove(conversationID)
        guard let configuration else { return }
        let channel = configuration.conversationChannel(conversationID: conversationID)
        pendingChannels.remove(channel)
        if subscribedChannels.remove(channel) != nil,
           let frame = KitPusherCodec.unsubscribe(channel: channel) {
            try? await send(frame)
        }
        clearConversationChannel(channel, conversationID: conversationID)
    }

    func sendTyping(conversationID rawConversationID: String, isTyping: Bool) async {
        guard connectionState == .live,
              isForeground,
              let configuration,
              configuration.typingEnabled,
              let conversationID = KitRealtimeIdentifierPolicy.canonicalConversationID(
                  rawConversationID
              ),
              desiredConversationIDs.contains(conversationID),
              let socketID,
              let boundSessionID,
              subscribedChannels.contains(
                  configuration.conversationChannel(conversationID: conversationID)
              )
        else { return }
        // Typing is deliberately best-effort. The receiver expires it after six seconds, so a
        // retry would be both stale and capable of spending the wallet API's request budget.
        try? await api.sendRealtimeTyping(
            conversationID: conversationID,
            state: isTyping ? "start" : "stop",
            socketID: socketID,
            boundSessionID: boundSessionID
        )
    }

    func sendPresenceHeartbeat() async {
        // Presence is authenticated channel membership. There is no application heartbeat.
    }

    func currentState() -> KitRealtimeConnectionState {
        connectionState
    }

    private func consumerTerminated(generation: UInt64) async {
        guard generation == sessionGeneration, eventContinuation != nil else { return }
        await stop()
    }

    private func ensureRunLoop() {
        guard isForeground,
              configuration != nil,
              userID != nil,
              boundSessionID != nil,
              runTask == nil,
              connectionState != .suspended
        else { return }
        runLoopGeneration &+= 1
        let loopGeneration = runLoopGeneration
        let sessionGeneration = self.sessionGeneration
        runTask = Task { [weak self] in
            await self?.runConnectionLoop(
                sessionGeneration: sessionGeneration,
                loopGeneration: loopGeneration
            )
        }
    }

    private func runConnectionLoop(
        sessionGeneration generation: UInt64,
        loopGeneration: UInt64
    ) async {
        defer {
            if generation == sessionGeneration,
               loopGeneration == runLoopGeneration {
                runTask = nil
            }
        }
        while isCurrent(generation), isForeground, !Task.isCancelled {
            do {
                try await connectAndListen(generation: generation)
                throw KitRealtimeLoopFailure.retry(minimumDelay: 0)
            } catch let failure as KitRealtimeLoopFailure {
                guard isCurrent(generation), !Task.isCancelled else { return }
                switch failure {
                case .pause:
                    await closeActiveSocket(clean: true, holdsPresenceBriefly: false)
                    connectionState = .idle
                    return
                case .suspendSession:
                    await closeActiveSocket(clean: false, holdsPresenceBriefly: false)
                    connectionState = .suspended
                    return
                case .rollover:
                    await closeActiveSocket(clean: true, holdsPresenceBriefly: true)
                    guard isForeground else { return }
                    continue
                case .droppedFrameFlood:
                    await closeActiveSocket(clean: false, holdsPresenceBriefly: false)
                    connectionState = .suspended
                    do {
                        try await Task.sleep(for: .seconds(Self.droppedFrameSuspension))
                    } catch { return }
                    guard isCurrent(generation), isForeground else { return }
                    connectionState = .backoff
                    continue
                case .reconnectImmediately:
                    await closeActiveSocket(clean: false, holdsPresenceBriefly: false)
                    guard isForeground else { return }
                    connectionState = .backoff
                    continue
                case .retry(let minimumDelay):
                    await closeActiveSocket(clean: false, holdsPresenceBriefly: false)
                    guard isForeground else { return }
                    reconnectAttempt += 1
                    connectionState = .backoff
                    let ceiling = KitRealtimeReconnectPolicy.maximumDelay(
                        attempt: reconnectAttempt
                    )
                    let delay = max(minimumDelay, Double.random(in: 0 ... ceiling))
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                }
            } catch {
                guard isCurrent(generation), !Task.isCancelled else { return }
                await closeActiveSocket(clean: false, holdsPresenceBriefly: false)
                reconnectAttempt += 1
                connectionState = .backoff
                let delay = Double.random(
                    in: 0 ... KitRealtimeReconnectPolicy.maximumDelay(attempt: reconnectAttempt)
                )
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
        }
    }

    private func connectAndListen(generation: UInt64) async throws {
        guard isCurrent(generation),
              isForeground,
              let configuration,
              let userID,
              let boundSessionID,
              let socketURL = configuration.socketURL
        else { throw KitRealtimeLoopFailure.pause }

        connectionState = .connecting
        var request = URLRequest(url: socketURL)
        request.timeoutInterval = Self.handshakeTimeout
        request.setValue(APIClientIdentity.currentHeader, forHTTPHeaderField: "X-Kit-Wallet-Client")
        let socket = urlSession.webSocketTask(with: request)
        webSocket = socket
        forcedFailure = nil
        socketID = nil
        userChannel = nil
        subscribedChannels = []
        pendingChannels = []
        conversationIDByChannel = [:]
        lastInboundAt = Date()
        pingSentAt = nil
        connectionState = .handshaking
        socket.resume()

        let connectionFrame = try await nextRequiredFrame(
            on: socket,
            generation: generation,
            accepting: {
                if case .connectionEstablished = $0 { return true }
                return false
            }
        )
        guard case .connectionEstablished(let establishedSocketID, let serverTimeout) = connectionFrame,
              serverTimeout == configuration.activityTimeout
        else { throw KitRealtimeLoopFailure.suspendSession }
        socketID = establishedSocketID

        connectionState = .subscribing
        let userChannel = configuration.userChannel(userID: userID)
        let channelAuthorization: KitRealtimeAuthorization
        do {
            channelAuthorization = try await api.realtimeChannelAuthorization(
                path: configuration.relativeAuthPath,
                socketID: establishedSocketID,
                channelName: userChannel,
                boundSessionID: boundSessionID
            )
        } catch {
            throw loopFailure(for: error, isUserChannel: true)
        }
        guard validatedAuth(channelAuthorization.auth, key: configuration.key),
              channelAuthorization.channelData == nil,
              let subscription = KitPusherCodec.subscribe(
                  channel: userChannel,
                  auth: channelAuthorization.auth,
                  channelData: nil
              )
        else { throw KitRealtimeLoopFailure.suspendSession }
        self.userChannel = userChannel
        pendingChannels.insert(userChannel)
        try await send(subscription)

        _ = try await nextRequiredFrame(
            on: socket,
            generation: generation,
            accepting: { frame in
                if case .subscriptionSucceeded(let channel, _) = frame {
                    return channel == userChannel
                }
                return false
            }
        )
        pendingChannels.remove(userChannel)
        subscribedChannels.insert(userChannel)
        connectionState = .live
        presenceHoldTask?.cancel()
        presenceHoldTask = nil
        emit(.connectionLive(true))
        emit(.syncRequested)
        startConnectionTimers(
            socket: socket,
            generation: generation,
            configuration: configuration
        )

        for conversationID in desiredConversationIDs.sorted() {
            await subscribeConversationIfNeeded(conversationID)
        }

        while isCurrent(generation), isForeground, !Task.isCancelled {
            let frame = try await receiveFrame(on: socket, generation: generation)
            try await handle(frame, generation: generation)
        }
        throw KitRealtimeLoopFailure.pause
    }

    private func nextRequiredFrame(
        on socket: URLSessionWebSocketTask,
        generation: UInt64,
        accepting: (KitPusherInboundFrame) -> Bool
    ) async throws -> KitPusherInboundFrame {
        let deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.handshakeTimeout))
            guard !Task.isCancelled else { return }
            await self?.forceDisconnect(
                .retry(minimumDelay: 0),
                socket: socket,
                generation: generation,
                clean: false
            )
        }
        defer { deadline.cancel() }
        while true {
            let frame = try await receiveFrame(on: socket, generation: generation)
            if accepting(frame) {
                try await handle(frame, generation: generation)
                return frame
            }
            try await handle(frame, generation: generation)
        }
    }

    private func receiveFrame(
        on socket: URLSessionWebSocketTask,
        generation: UInt64
    ) async throws -> KitPusherInboundFrame {
        do {
            let message = try await socket.receive()
            guard isCurrent(generation), webSocket === socket else {
                throw KitRealtimeLoopFailure.pause
            }
            lastInboundAt = Date()
            let text: String?
            switch message {
            case .string(let value):
                text = value
            case .data(let data):
                text = data.count <= KitPusherCodec.maximumFrameBytes
                    ? String(data: data, encoding: .utf8)
                    : nil
            @unknown default:
                text = nil
            }
            guard let text, let frame = KitPusherCodec.decode(text) else {
                return .ignored
            }
            return frame
        } catch let failure as KitRealtimeLoopFailure {
            throw failure
        } catch {
            if let forcedFailure {
                self.forcedFailure = nil
                throw forcedFailure
            }
            if Task.isCancelled || !isForeground || !isCurrent(generation) {
                throw KitRealtimeLoopFailure.pause
            }
            throw KitRealtimeLoopFailure.retry(minimumDelay: 0)
        }
    }

    private func handle(
        _ frame: KitPusherInboundFrame,
        generation: UInt64
    ) async throws {
        guard isCurrent(generation) else { throw KitRealtimeLoopFailure.pause }
        switch frame {
        case .ping:
            guard let pong = KitPusherCodec.pong() else {
                throw KitRealtimeLoopFailure.suspendSession
            }
            try await send(pong)
        case .pong:
            pingSentAt = nil
        case .error(let code, _):
            switch KitRealtimeReconnectPolicy.disposition(forPusherErrorCode: code) {
            case .suspendSession:
                throw KitRealtimeLoopFailure.suspendSession
            case .backoff(let minimumDelay):
                throw KitRealtimeLoopFailure.retry(minimumDelay: minimumDelay)
            case .reconnectImmediately:
                throw KitRealtimeLoopFailure.reconnectImmediately
            }
        case .subscriptionSucceeded(let channel, let members):
            guard pendingChannels.remove(channel) != nil || subscribedChannels.contains(channel)
            else {
                try recordDroppedFrame()
                return
            }
            subscribedChannels.insert(channel)
            if let members, let conversationID = conversationIDByChannel[channel] {
                applyPresenceRoster(
                    Set(members),
                    channel: channel,
                    conversationID: conversationID
                )
            }
        case .memberAdded(let channel, let memberID):
            guard subscribedChannels.contains(channel),
                  let conversationID = conversationIDByChannel[channel]
            else {
                try recordDroppedFrame()
                return
            }
            let inserted = presenceRosterByChannel[channel, default: []].insert(memberID).inserted
            if inserted, memberID != userID {
                emit(.presence(userID: memberID, isOnline: true, lastSeenAt: nil))
            }
            _ = conversationID
        case .memberRemoved(let channel, let memberID):
            guard subscribedChannels.contains(channel),
                  conversationIDByChannel[channel] != nil
            else {
                try recordDroppedFrame()
                return
            }
            if presenceRosterByChannel[channel]?.remove(memberID) != nil, memberID != userID {
                emit(.presence(userID: memberID, isOnline: false, lastSeenAt: nil))
            }
        case .syncNudge(let channel):
            guard isForeground,
                  connectionState == .live,
                  channel == userChannel,
                  subscribedChannels.contains(channel)
            else {
                try recordDroppedFrame()
                return
            }
            emit(.syncRequested)
        case .typing(let channel, let actorID, let isTyping):
            guard isForeground,
                  configuration?.typingEnabled == true,
                  subscribedChannels.contains(channel),
                  let conversationID = conversationIDByChannel[channel],
                  actorID != userID,
                  presenceRosterByChannel[channel]?.contains(actorID) == true
            else {
                try recordDroppedFrame()
                return
            }
            if isTyping {
                let key = "\(channel)|\(actorID)"
                let now = Date()
                if let previous = lastTypingFrameAt[key], now.timeIntervalSince(previous) < 2 {
                    return
                }
                lastTypingFrameAt[key] = now
            }
            emit(.typing(
                conversationID: conversationID,
                userID: actorID,
                isTyping: isTyping
            ))
        case .connectionEstablished:
            if connectionState != .handshaking { try recordDroppedFrame() }
        case .ignored, .rejectedClientEvent:
            if frame.countsTowardDroppedFrameFlood {
                try recordDroppedFrame()
            }
        }
    }

    private func subscribeConversationIfNeeded(_ conversationID: String) async {
        guard connectionState == .live,
              isForeground,
              let configuration,
              configuration.presenceEnabled,
              let socketID,
              let boundSessionID,
              desiredConversationIDs.contains(conversationID),
              !deniedConversationIDs.contains(conversationID)
        else { return }
        let channel = configuration.conversationChannel(conversationID: conversationID)
        guard !subscribedChannels.contains(channel), !pendingChannels.contains(channel) else {
            return
        }

        do {
            let authorization = try await api.realtimeChannelAuthorization(
                path: configuration.relativeAuthPath,
                socketID: socketID,
                channelName: channel,
                boundSessionID: boundSessionID
            )
            guard connectionState == .live,
                  desiredConversationIDs.contains(conversationID),
                  self.socketID == socketID,
                  let channelData = validatedPresenceChannelData(
                      authorization,
                      configuration: configuration,
                      userID: userID
                  ),
                  let subscription = KitPusherCodec.subscribe(
                      channel: channel,
                      auth: authorization.auth,
                      channelData: channelData
                  )
            else { return }
            conversationIDByChannel[channel] = conversationID
            pendingChannels.insert(channel)
            try await send(subscription)
        } catch let error as KitRealtimeRequestError where error.status == 403 {
            deniedConversationIDs.insert(conversationID)
            clearConversationChannel(channel, conversationID: conversationID)
        } catch {
            let failure = loopFailure(for: error, isUserChannel: false)
            await forceDisconnect(
                failure,
                socket: webSocket,
                generation: sessionGeneration,
                clean: false
            )
        }
    }

    private func validatedPresenceChannelData(
        _ authorization: KitRealtimeAuthorization,
        configuration: KitRealtimeConfiguration,
        userID: String?
    ) -> String? {
        guard let userID,
              validatedAuth(authorization.auth, key: configuration.key),
              let channelData = authorization.channelData,
              channelData.utf8.count <= 4_096,
              let data = channelData.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["user_id", "user_info"],
              (object["user_id"] as? String)?.caseInsensitiveCompare(userID) == .orderedSame,
              let userInfo = object["user_info"] as? [String: Any],
              Set(userInfo.keys) == ["v"],
              let version = userInfo["v"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(),
              version.intValue == 1,
              version.doubleValue == 1
        else { return nil }
        return channelData
    }

    private func validatedAuth(_ auth: String, key: String) -> Bool {
        auth.utf8.count <= 4_096
            && auth.hasPrefix("\(key):")
            && auth.unicodeScalars.allSatisfy {
                !CharacterSet.whitespacesAndNewlines.contains($0)
                    && !CharacterSet.controlCharacters.contains($0)
            }
    }

    private func loopFailure(
        for error: Error,
        isUserChannel: Bool
    ) -> KitRealtimeLoopFailure {
        if let requestError = error as? KitRealtimeRequestError {
            switch requestError.status {
            case 401, 503:
                return .suspendSession
            case 403:
                return isUserChannel ? .suspendSession : .retry(minimumDelay: 0)
            case 429:
                return .retry(minimumDelay: max(1, requestError.retryAfter ?? 1))
            default:
                return .retry(minimumDelay: 0)
            }
        }
        if let clientError = error as? APIClientError,
           case .signedOut = clientError {
            return .suspendSession
        }
        return .retry(minimumDelay: 0)
    }

    private func applyPresenceRoster(
        _ roster: Set<String>,
        channel: String,
        conversationID: String
    ) {
        let previous = presenceRosterByChannel[channel] ?? []
        presenceRosterByChannel[channel] = roster
        for memberID in roster.subtracting(previous).sorted() where memberID != userID {
            emit(.presence(userID: memberID, isOnline: true, lastSeenAt: nil))
        }
        for memberID in previous.subtracting(roster).sorted() where memberID != userID {
            emit(.presence(userID: memberID, isOnline: false, lastSeenAt: nil))
        }
        if !desiredConversationIDs.contains(conversationID) {
            clearConversationChannel(channel, conversationID: conversationID)
        }
    }

    private func clearConversationChannel(_ channel: String, conversationID: String) {
        for memberID in (presenceRosterByChannel.removeValue(forKey: channel) ?? []).sorted()
            where memberID != userID {
            emit(.presence(userID: memberID, isOnline: false, lastSeenAt: nil))
        }
        lastTypingFrameAt = lastTypingFrameAt.filter { !$0.key.hasPrefix("\(channel)|") }
        conversationIDByChannel[channel] = nil
        emit(.conversationUnavailable(conversationID: conversationID))
    }

    private func send(_ frame: String) async throws {
        guard let webSocket else { throw KitRealtimeLoopFailure.retry(minimumDelay: 0) }
        try await webSocket.send(.string(frame))
    }

    private func startConnectionTimers(
        socket: URLSessionWebSocketTask,
        generation: UInt64,
        configuration: KitRealtimeConfiguration
    ) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await self?.heartbeatTick(
                    socket: socket,
                    generation: generation,
                    activityTimeout: configuration.activityTimeout
                )
            }
        }
        lifetimeTask?.cancel()
        lifetimeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(configuration.maximumConnectionSeconds))
            guard !Task.isCancelled else { return }
            await self?.forceDisconnect(
                .rollover,
                socket: socket,
                generation: generation,
                clean: true
            )
        }
        liveResetTask?.cancel()
        liveResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.liveBackoffResetAfter))
            guard !Task.isCancelled else { return }
            await self?.resetBackoffIfStillLive(socket: socket, generation: generation)
        }
    }

    private func heartbeatTick(
        socket: URLSessionWebSocketTask,
        generation: UInt64,
        activityTimeout: TimeInterval
    ) async {
        guard isCurrent(generation),
              webSocket === socket,
              connectionState == .live
        else { return }
        let now = Date()
        if let pingSentAt {
            guard now.timeIntervalSince(pingSentAt) >= Self.pongTimeout else { return }
            await forceDisconnect(
                .retry(minimumDelay: 0),
                socket: socket,
                generation: generation,
                clean: false
            )
            return
        }
        guard let lastInboundAt,
              now.timeIntervalSince(lastInboundAt) >= max(5, activityTimeout - 5),
              let ping = KitPusherCodec.ping()
        else { return }
        do {
            try await socket.send(.string(ping))
            self.pingSentAt = now
        } catch {
            await forceDisconnect(
                .retry(minimumDelay: 0),
                socket: socket,
                generation: generation,
                clean: false
            )
        }
    }

    private func resetBackoffIfStillLive(
        socket: URLSessionWebSocketTask,
        generation: UInt64
    ) {
        guard isCurrent(generation), webSocket === socket, connectionState == .live else { return }
        reconnectAttempt = 0
    }

    private func forceDisconnect(
        _ failure: KitRealtimeLoopFailure,
        socket: URLSessionWebSocketTask?,
        generation: UInt64,
        clean: Bool
    ) async {
        guard isCurrent(generation), let socket, webSocket === socket else { return }
        forcedFailure = failure
        socket.cancel(with: clean ? .normalClosure : .goingAway, reason: nil)
    }

    private func disconnectForBackground(generation: UInt64) async {
        guard isCurrent(generation), !isForeground else { return }
        runLoopGeneration &+= 1
        runTask?.cancel()
        runTask = nil
        await closeActiveSocket(clean: true, holdsPresenceBriefly: false)
        connectionState = .idle
    }

    private func closeActiveSocket(
        clean: Bool,
        holdsPresenceBriefly: Bool
    ) async {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        lifetimeTask?.cancel()
        lifetimeTask = nil
        liveResetTask?.cancel()
        liveResetTask = nil
        let wasLive = connectionState == .live
        webSocket?.cancel(with: clean ? .normalClosure : .goingAway, reason: nil)
        webSocket = nil
        socketID = nil
        userChannel = nil
        pendingChannels = []
        subscribedChannels = []
        conversationIDByChannel = [:]
        lastInboundAt = nil
        pingSentAt = nil
        forcedFailure = nil
        lastTypingFrameAt = [:]
        if wasLive { emit(.connectionLive(false)) }
        presenceHoldTask?.cancel()
        presenceHoldTask = nil
        if holdsPresenceBriefly, !presenceRosterByChannel.isEmpty {
            let generation = sessionGeneration
            presenceHoldTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.presenceReconnectHold))
                guard !Task.isCancelled else { return }
                await self?.expireHeldPresence(generation: generation)
            }
        } else {
            presenceRosterByChannel = [:]
            emit(.availabilityLost)
        }
    }

    private func expireHeldPresence(generation: UInt64) {
        guard isCurrent(generation), connectionState != .live else { return }
        presenceRosterByChannel = [:]
        emit(.availabilityLost)
    }

    private func recordDroppedFrame() throws {
        if dropGuard.record(at: Date()) {
            throw KitRealtimeLoopFailure.droppedFrameFlood
        }
    }

    private func emit(_ event: KitRealtimeEvent) {
        eventContinuation?.yield(event)
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        generation == sessionGeneration && configuration != nil && eventContinuation != nil
    }
}
