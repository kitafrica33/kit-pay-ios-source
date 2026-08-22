import Foundation

/// Pure, clock-independent decisions for the durable communication outbox.
///
/// Keeping these rules outside `AppModel` makes message retry ordering and terminal-call replay
/// deterministic while leaving storage and transport side effects in their existing owners.
enum OutboxPolicy {
    static let unavailableMessageFailure = CustomerFacingMessagingCopy.legacyConversationFailure

    enum FailureDecision: Equatable {
        case retry(after: TimeInterval?)
        case awaitSession
        case unchanged
        case permanent
    }

    static func readyCommands(_ commands: [OfflineCommand], at now: Date) -> [OfflineCommand] {
        orderedStreamHeads(commands)
            .filter { $0.nextAttemptAt <= now }
    }

    /// Returns the next command that can make transport progress. A secure-message row without a
    /// fanout is now an intentional offline draft: the online replay first commits fresh Signal
    /// ciphertext against the authoritative roster and then sends those exact bytes.
    static func nextWakeDate(_ commands: [OfflineCommand]) -> Date? {
        orderedStreamHeads(commands).lazy.map(\.nextAttemptAt).min()
    }

    /// Only the oldest pending message in each conversation may become runnable. A newer message
    /// must not overtake an older row merely because the older row is backing off after a
    /// transport failure. Other conversations and call lifecycle commands remain independent.
    private static func orderedStreamHeads(
        _ commands: [OfflineCommand]
    ) -> [OfflineCommand] {
        let ordered = commands
            // `.callAttempt` remains decodable only to migrate older encrypted state. New calls
            // are process-memory-only and legacy rows must never reach timers or background work.
            .filter { $0.failureDisposition == nil && $0.kind != .callAttempt }
            .sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        var seenMessageStreams: Set<String> = []
        return ordered.filter { command in
            guard command.kind == .secureMessage else { return true }
            let stream = command.conversationId?.lowercased()
                ?? "invalid:\(command.id.uuidString.lowercased())"
            return seenMessageStreams.insert(stream).inserted
        }
    }

    /// Messaging APIs identify conversations with server-issued UUIDs. A synthetic local value
    /// such as `direct:<user-id>` must never cross the encrypted transport boundary.
    static func canonicalConversationID(_ value: String?) -> String? {
        guard let value,
              let id = UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return id.uuidString.lowercased()
    }

    /// Quarantines commands produced by the pre-transport prototype without deleting the locally
    /// encrypted history. They cannot be replayed safely because no server conversation/roster was
    /// ever resolved for them.
    @discardableResult
    static func quarantineMessagesWithoutServerConversation(in state: inout PersistedState) -> Int {
        let invalidCommands = state.outbox.filter {
            $0.kind == .secureMessage && canonicalConversationID($0.conversationId) == nil
        }
        guard !invalidCommands.isEmpty else { return 0 }

        let commandIDs = Set(invalidCommands.map(\.id))
        let messageIDs = Set(invalidCommands.compactMap(\.messageId))
        state.outbox.removeAll { commandIDs.contains($0.id) }
        for index in state.messages.indices where messageIDs.contains(state.messages[index].id) {
            state.messages[index].state = .failed
            state.messages[index].failureReason = unavailableMessageFailure
        }
        return invalidCommands.count
    }

    /// Removes the durable prototype representation without replaying it. Only a queued local
    /// placeholder with the exact command ID is deleted; any server-authenticated ringing,
    /// active, or terminal history that happens to share the idempotency key is preserved.
    @discardableResult
    static func removeLegacyCallAttempts(in state: inout PersistedState) -> Int {
        let legacyCommands = state.outbox.filter { $0.kind == .callAttempt }
        guard !legacyCommands.isEmpty else { return 0 }
        let placeholderIDs = Set(legacyCommands.map { $0.id.uuidString.lowercased() })
        state.outbox.removeAll { $0.kind == .callAttempt }
        state.calls.removeAll {
            placeholderIDs.contains($0.id.lowercased()) && $0.state == .queued
        }
        return legacyCommands.count
    }

    static func terminationReplay(for command: OfflineCommand) -> CallTerminationReplay? {
        guard command.kind == .callTermination,
              let callId = command.callId?.trimmingCharacters(in: .whitespacesAndNewlines),
              UUID(uuidString: callId) != nil,
              let kind = command.terminationKind
        else { return nil }
        return CallTerminationReplay(callId: callId.lowercased(), kind: kind, reason: command.terminationReason)
    }

    /// Commits the local side of an idempotent terminal response. Every pending termination for
    /// the call is removed so an older decline/end command cannot keep replaying after the server
    /// has already advanced the call. An authoritative terminal history state is preserved.
    static func acknowledgeTermination(
        callId: String,
        kind: CallTerminationKind,
        in state: inout PersistedState,
        at now: Date
    ) {
        state.outbox.removeAll {
            $0.kind == .callTermination
                && $0.callId?.caseInsensitiveCompare(callId) == .orderedSame
        }
        guard let index = state.calls.firstIndex(where: {
            $0.id.caseInsensitiveCompare(callId) == .orderedSame
        }) else { return }

        if ![CallState.completed, .missed, .declined, .failed].contains(state.calls[index].state) {
            state.calls[index].state = kind == .decline ? .declined : .completed
        }
        state.calls[index].endedAt = state.calls[index].endedAt ?? now
    }

    /// Ceiling for the client's own exponential backoff.
    static let maximumBackoffDelay: TimeInterval = 120

    /// Ceiling for a delay the *server* asked for. Held well above the client backoff so a
    /// `Retry-After` on a 429 or a maintenance 503 is actually honoured: clamping server guidance
    /// to the client's own two-minute ceiling meant the app kept re-sending inside the window the
    /// backend had explicitly told it to wait out, which is how a rate limit turns into a longer
    /// one. Still bounded, so a hostile or mistaken header cannot park a message indefinitely.
    static let maximumServerRequestedDelay: TimeInterval = 900

    static func scheduleRetry(
        for command: OfflineCommand,
        in state: inout PersistedState,
        at now: Date,
        retryAfter: TimeInterval? = nil
    ) {
        guard let index = state.outbox.firstIndex(where: { $0.id == command.id }) else { return }
        state.outbox[index].attemptCount += 1
        state.outbox[index].failureDisposition = nil
        state.outbox[index].lastFailureReason = nil
        let exponentialDelay = min(
            pow(2, Double(state.outbox[index].attemptCount)) * 5,
            maximumBackoffDelay
        )
        let serverRequestedDelay = min(
            max(0, retryAfter ?? 0),
            maximumServerRequestedDelay
        )
        state.outbox[index].nextAttemptAt = now.addingTimeInterval(
            max(exponentialDelay, serverRequestedDelay)
        )
    }

    /// Stops automatic replay for a permanent response. Failed secure messages retain their
    /// exact command for an explicit retry; terminal call commands are simply removed because
    /// the authoritative call history already carries their final state.
    static func markPermanentFailure(
        for command: OfflineCommand,
        reason: String,
        in state: inout PersistedState
    ) {
        guard let index = state.outbox.firstIndex(where: { $0.id == command.id }) else { return }
        if command.kind == .secureMessage {
            state.outbox[index].failureDisposition = .requiresUserRetry
            state.outbox[index].lastFailureReason = reason
            if let messageID = command.messageId,
               let messageIndex = state.messages.firstIndex(where: { $0.id == messageID }) {
                state.messages[messageIndex].state = .failed
                state.messages[messageIndex].failureReason = reason
            }
            return
        }
        state.outbox.remove(at: index)
    }

    static func markAwaitingSession(
        for command: OfflineCommand,
        reason: String,
        in state: inout PersistedState
    ) {
        guard let index = state.outbox.firstIndex(where: { $0.id == command.id }) else { return }
        state.outbox[index].failureDisposition = .awaitingSession
        state.outbox[index].lastFailureReason = reason
    }

    @discardableResult
    static func resumeSessionDeferredCommands(
        in state: inout PersistedState,
        at now: Date
    ) -> Int {
        var resumed = 0
        for index in state.outbox.indices
            where state.outbox[index].failureDisposition == .awaitingSession {
            state.outbox[index].failureDisposition = nil
            state.outbox[index].lastFailureReason = nil
            state.outbox[index].nextAttemptAt = now
            resumed += 1
        }
        return resumed
    }

    @discardableResult
    static func resumeFailedMessage(
        messageID: UUID,
        in state: inout PersistedState,
        at now: Date
    ) -> Bool {
        guard let commandIndex = state.outbox.firstIndex(where: {
            $0.kind == .secureMessage
                && $0.messageId == messageID
                && $0.failureDisposition == .requiresUserRetry
        }) else { return false }

        state.outbox[commandIndex].failureDisposition = nil
        state.outbox[commandIndex].lastFailureReason = nil
        state.outbox[commandIndex].attemptCount = 0
        state.outbox[commandIndex].nextAttemptAt = now
        if let messageIndex = state.messages.firstIndex(where: { $0.id == messageID }) {
            state.messages[messageIndex].state = .queued
            state.messages[messageIndex].failureReason = nil
        }
        return true
    }

    static func canRetryMessage(_ messageID: UUID, in commands: [OfflineCommand]) -> Bool {
        commands.contains {
            $0.kind == .secureMessage
                && $0.messageId == messageID
                && $0.failureDisposition == .requiresUserRetry
        }
    }

    /// Only errors that can plausibly succeed without changing the command are replayed
    /// automatically. Permanent client/authorization/contract responses stop at once instead of
    /// generating an endless background loop and blocking newer messages in the conversation.
    static func failureDecision(for error: Error) -> FailureDecision {
        if error is CancellationError { return .unchanged }

        if let payload = error as? APIErrorPayload {
            let status = payload.httpStatus
            if status == 401 { return .awaitSession }
            if status == 408 || status == 425 || status == 429
                || status.map({ (500 ... 599).contains($0) }) == true
                || retryableAPICodes.contains(payload.code.uppercased()) {
                return .retry(after: payload.retryAfter)
            }
            return .permanent
        }

        if let clientError = error as? APIClientError {
            switch clientError {
            case .signedOut:
                return .awaitSession
            case .invalidResponse:
                return .retry(after: nil)
            case .invalidPayload(let status), .httpStatus(let status):
                return retryDecision(forHTTPStatus: status, retryAfter: nil)
            case .httpResponse(let status, let retryAfter):
                return retryDecision(forHTTPStatus: status, retryAfter: retryAfter)
            case .invalidURL:
                return .permanent
            }
        }

        if let urlError = error as? URLError {
            return retryableURLErrorCodes.contains(urlError.code)
                ? .retry(after: nil)
                : .permanent
        }

        if let exchangeError = error as? SecureMessagingExchangeError {
            switch exchangeError {
            case .retryLimitExceeded:
                return .retry(after: nil)
            case .invalidAccount:
                return .permanent
            case .invalidRecipient, .invalidConversation, .invalidServerResponse,
                    .unsupportedEvent, .staleOutboundFanout:
                return .permanent
            }
        }

        if let cryptoError = error as? SecureMessagingCryptoError {
            switch cryptoError {
            case .staleRoster, .sessionUnavailable, .staleState:
                return .retry(after: nil)
            case .notProvisioned:
                return .permanent
            case .invalidAddress, .invalidRegistrationID, .invalidPreKeyID,
                    .recordLimitExceeded, .missingRecord, .identityChanged,
                    .invalidSignature, .invalidContent, .unsupportedEnvelope,
                    .replayedKyberBaseKey:
                return .permanent
            }
        }

        return .permanent
    }

    private static func retryDecision(
        forHTTPStatus status: Int,
        retryAfter: TimeInterval?
    ) -> FailureDecision {
        if status == 401 { return .awaitSession }
        if status == 408 || status == 425 || status == 429 || (500 ... 599).contains(status) {
            return .retry(after: retryAfter)
        }
        return .permanent
    }

    private static let retryableAPICodes: Set<String> = [
        "CALL_ATTEMPT_NOT_EXPIRED",
        "GATEWAY_TIMEOUT",
        "INTERNAL_ERROR",
        "RATE_LIMIT_EXCEEDED",
        "RATE_LIMITED",
        "REQUEST_TIMEOUT",
        "SERVICE_UNAVAILABLE",
        "TOO_MANY_REQUESTS",
        "UPSTREAM_UNAVAILABLE",
    ]

    private static let retryableURLErrorCodes: Set<URLError.Code> = [
        .backgroundSessionInUseByAnotherProcess,
        .backgroundSessionRequiresSharedContainer,
        .cannotConnectToHost,
        .cannotFindHost,
        .dataNotAllowed,
        .dnsLookupFailed,
        .internationalRoamingOff,
        .networkConnectionLost,
        .notConnectedToInternet,
        .resourceUnavailable,
        .timedOut,
    ]

}
