import Foundation

enum CallTerminationKind: String, Codable, Hashable {
    case decline
    case end
}

struct CallTerminationReplay: Equatable {
    let callId: String
    let kind: CallTerminationKind
    let reason: String?
}

/// One outgoing call that exists only for the lifetime of the running application process.
/// Unlike secure messages and accepted-call termination commands, this value must never be
/// encoded into `PersistedState` or handed to background replay.
struct EphemeralOutgoingCallAttempt: Equatable, Sendable {
    let clientCallID: UUID
    let recipientUserID: String
    let recipientName: String
    let video: Bool
    let conversationID: String?
    let createdAt: Date
    let lease: CallMediaAccountLease

    var clientCallIDString: String { clientCallID.uuidString.lowercased() }
}

/// Fences every suspended start-call request to the exact in-memory attempt and account lease.
/// Cancelling, background suspension, or account replacement invalidates the token immediately;
/// a late HTTP response can then be terminated without reviving the local call screen.
struct EphemeralOutgoingCallAttemptGate: Sendable {
    struct Submission: Equatable, Sendable {
        fileprivate let generation: UInt64
        let attempt: EphemeralOutgoingCallAttempt
    }

    private(set) var attempt: EphemeralOutgoingCallAttempt?
    private(set) var retryCount = 0
    private var generation: UInt64 = 0
    private var submissionInFlight = false

    @discardableResult
    mutating func begin(_ newAttempt: EphemeralOutgoingCallAttempt) -> Bool {
        guard attempt == nil else { return false }
        generation &+= 1
        attempt = newAttempt
        retryCount = 0
        submissionInFlight = false
        return true
    }

    mutating func beginSubmission() -> Submission? {
        guard let attempt, !submissionInFlight else { return nil }
        generation &+= 1
        submissionInFlight = true
        return Submission(generation: generation, attempt: attempt)
    }

    func accepts(_ submission: Submission) -> Bool {
        submissionInFlight
            && generation == submission.generation
            && attempt == submission.attempt
    }

    /// Retains the same stable client call ID while allowing a later foreground retry.
    mutating func finishRetryableFailure(_ submission: Submission) -> Int? {
        guard accepts(submission) else { return nil }
        generation &+= 1
        submissionInFlight = false
        retryCount += 1
        return retryCount
    }

    /// Invalidates a suspended HTTP request without deleting the visible in-memory attempt.
    mutating func suspendSubmission() {
        guard attempt != nil else { return }
        generation &+= 1
        submissionInFlight = false
    }

    mutating func finishAccepted(_ submission: Submission) -> EphemeralOutgoingCallAttempt? {
        guard accepts(submission) else { return nil }
        let accepted = attempt
        generation &+= 1
        attempt = nil
        retryCount = 0
        submissionInFlight = false
        return accepted
    }

    /// Lets the first successful response for this exact attempt win even when connectivity has
    /// already started a replacement request with the same idempotency key. The caller cancels
    /// that replacement transport, and any duplicate response is ignored if it resolves to the
    /// authenticated call that is already active.
    mutating func finishCurrentAttemptAccepted(
        _ expectedAttempt: EphemeralOutgoingCallAttempt
    ) -> EphemeralOutgoingCallAttempt? {
        guard attempt == expectedAttempt else { return nil }
        let accepted = attempt
        generation &+= 1
        attempt = nil
        retryCount = 0
        submissionInFlight = false
        return accepted
    }

    mutating func cancel(
        clientCallID: String? = nil
    ) -> EphemeralOutgoingCallAttempt? {
        guard let current = attempt else { return nil }
        if let clientCallID,
           current.clientCallIDString.caseInsensitiveCompare(clientCallID) != .orderedSame {
            return nil
        }
        generation &+= 1
        attempt = nil
        retryCount = 0
        submissionInFlight = false
        return current
    }
}

enum EphemeralOutgoingCallRetryPolicy {
    static func delay(
        failureCount: Int,
        retryAfter: TimeInterval?
    ) -> TimeInterval {
        let exponent = Double(max(0, failureCount - 1))
        let localDelay = min(pow(2, exponent), 15)
        let serverDelay = min(120, max(0, retryAfter ?? 0))
        return max(localDelay, serverDelay)
    }
}

struct CallableContact: Identifiable, Hashable {
    let id: String
    let name: String
    let subtitle: String
    let isKitUser: Bool
    let phoneIdentity: String?
    let source: WalletContactDTO?
}

struct IncomingCallPush: Equatable, Sendable {
    static let pushType = "call.ringing"

    let callId: String
    let callerName: String
    let callerUserId: String?
    let video: Bool
    let ringExpiresAt: String?

    var callUUID: UUID { UUID(uuidString: callId)! }

    var ringExpiryDate: Date? {
        guard let ringExpiresAt else { return nil }
        let standard = ISO8601DateFormatter()
        if let expiry = standard.date(from: ringExpiresAt) { return expiry }
        standard.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return standard.date(from: ringExpiresAt)
    }

    enum CallKitDisposition: Equatable {
        case ringing
        case reportAsUnanswered
    }

    func callKitDisposition(at now: Date = Date()) -> CallKitDisposition {
        isExpired(at: now) ? .reportAsUnanswered : .ringing
    }

    func isExpired(at now: Date = Date()) -> Bool {
        ringExpiryDate.map { $0 <= now } ?? false
    }

    init?(payload: [AnyHashable: Any]) {
        guard Self.string(payload["type"]) == Self.pushType,
              let rawCallId = Self.string(payload["call_id"])?.lowercased(),
              UUID(uuidString: rawCallId) != nil
        else { return nil }

        callId = rawCallId
        callerName = Self.safeCallerName(Self.string(payload["initiator_name"]))
        callerUserId = Self.normalizedUUID(Self.string(payload["initiator_user_id"]))
        video = Self.string(payload["call_type"])?.lowercased() == "video"
            || Self.bool(payload["video"])
        ringExpiresAt = Self.string(payload["ring_expires_at"])
    }

    private static func string(_ value: Any?) -> String? {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private static func bool(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return string(value)?.lowercased() == "true"
    }

    private static func normalizedUUID(_ value: String?) -> String? {
        value.flatMap(UUID.init(uuidString:))?.uuidString.lowercased()
    }

    private static func safeCallerName(_ value: String?) -> String {
        guard let value else { return "Kit Pay contact" }
        let cleaned = value.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .prefix(100)
        let name = String(String.UnicodeScalarView(cleaned))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.nilIfEmpty ?? "Kit Pay contact"
    }
}

/// Opaque process-local authority to verify one generic CallKit presentation. The coordinator
/// changes its generation whenever communication ownership is quarantined or replaced, so an
/// authenticated lookup that finishes late cannot reveal or admit a call in a newer account.
struct IncomingCallVerificationRequest: Equatable, Sendable {
    let eventId: UUID
    let push: IncomingCallPush
    let admissionGeneration: UInt64

    init(
        eventId: UUID = UUID(),
        push: IncomingCallPush,
        admissionGeneration: UInt64
    ) {
        self.eventId = eventId
        self.push = push
        self.admissionGeneration = admissionGeneration
    }
}

/// The only incoming-call value that may enter the encrypted account projection or reveal caller
/// identity in CallKit. Every field is derived from an authenticated, account-scoped call lookup;
/// untrusted PushKit metadata is used only to bind the lookup to its original generic call.
struct AuthenticatedIncomingCall: Equatable, Sendable {
    let record: CallRecord
    let callUUID: UUID
    let ringExpiryDate: Date
    let initiatorUserID: String?
}

enum IncomingCallAuthenticationPolicy {
    /// The authenticated call presenter returns only the other participants. The backend limits
    /// a call to 21 total participants, leaving at most 20 remote identities for this projection.
    static let maximumRemoteParticipantCount = 20

    static func authenticatedCall(
        response: CallDTO,
        matching push: IncomingCallPush,
        currentUserID: String,
        now: Date = Date()
    ) -> AuthenticatedIncomingCall? {
        guard let callID = canonicalUUID(response.id),
              response.id == callID,
              callID == push.callId,
              canonicalContractValue(response.direction) == "incoming",
              isRingingInvitationState(response.state),
              let expiry = CallLifecyclePolicy.serverTimestamp(response.ringExpiresAt),
              expiry > now,
              push.ringExpiryDate.map({ $0 > now }) ?? true,
              let startedAt = CallLifecyclePolicy.serverTimestamp(response.startedAt),
              startedAt <= expiry,
              let currentUserID = canonicalUUID(currentUserID),
              let rawParticipantIDs = response.participantUserIds,
              (1 ... maximumRemoteParticipantCount).contains(rawParticipantIDs.count)
        else { return nil }

        var participantIDs: [String] = []
        var uniqueParticipantIDs: Set<String> = []
        participantIDs.reserveCapacity(rawParticipantIDs.count)
        for rawParticipantID in rawParticipantIDs {
            guard let participantID = canonicalUUID(rawParticipantID),
                  uniqueParticipantIDs.insert(participantID).inserted
            else { return nil }
            participantIDs.append(participantID)
        }
        // GET /calls/{id} proves ownership by returning 404 to non-participants. Its presentation
        // deliberately excludes the authenticated viewer, so seeing that identity in this remote
        // roster is a contradictory response and must fail closed.
        guard !uniqueParticipantIDs.contains(currentUserID) else { return nil }
        if let initiatorUserID = push.callerUserId,
           !uniqueParticipantIDs.contains(initiatorUserID) {
            return nil
        }

        let conversationID: String?
        if let rawConversationID = response.conversationId {
            guard let canonicalConversationID = canonicalUUID(rawConversationID) else {
                return nil
            }
            conversationID = canonicalConversationID
        } else {
            conversationID = nil
        }

        let video = response.isVideoCall
        let record = CallRecord(
            id: callID,
            name: safeAuthenticatedName(response.name),
            participantUserIds: participantIDs,
            direction: "incoming",
            type: video ? "video" : "voice",
            video: video,
            state: .ringing,
            startedAt: startedAt,
            endedAt: nil,
            isDeferredAttempt: false,
            conversationId: conversationID,
            answeredAt: nil
        )
        return AuthenticatedIncomingCall(
            record: record,
            callUUID: push.callUUID,
            ringExpiryDate: expiry,
            initiatorUserID: push.callerUserId
        )
    }

    private static func canonicalUUID(_ value: String) -> String? {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              let identifier = UUID(uuidString: value)
        else { return nil }
        return identifier.uuidString.lowercased()
    }

    private static func canonicalContractValue(_ value: String) -> String? {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return value.lowercased()
    }

    private static func isRingingInvitationState(_ value: String) -> Bool {
        guard let state = canonicalContractValue(value) else { return false }
        // Adding a participant to an established group call keeps the global call active while
        // issuing that viewer a fresh ring expiry. Both states therefore describe an unanswered
        // invitation; completed/declined/failed states never do.
        return state == "ringing" || state == "active"
    }

    private static func safeAuthenticatedName(_ value: String?) -> String {
        guard let value else { return "Kit Pay contact" }
        let cleaned = value.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .prefix(100)
        let name = String(String.UnicodeScalarView(cleaned))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.nilIfEmpty ?? "Kit Pay contact"
    }
}

/// A narrow, SDK-independent projection of the media states that determine whether another
/// authenticated incoming call belongs on the ordinary incoming surface or the in-call waiting
/// surface. Call waiting begins only after the primary media session has connected; dialing and
/// initial connection continue to use the primary-call flow.
enum CallWaitingMediaState: Equatable, Sendable {
    case idle
    case preparing
    case connecting
    case connected
    case reconnecting
    case ending

    fileprivate var permitsWaitingCall: Bool {
        self == .connected || self == .reconnecting
    }
}

/// One server-authenticated incoming call that can be displayed beside an already connected call.
/// Construction is file-scoped so an untrusted push cannot manufacture the non-optional user id
/// later submitted to the authenticated call-invite endpoint.
struct AuthenticatedWaitingCall: Equatable, Sendable {
    let incoming: AuthenticatedIncomingCall
    let callID: String
    let initiatorUserID: String

    var callUUID: UUID { incoming.callUUID }
    var name: String { incoming.record.name }
    var video: Bool { incoming.record.isVideoCall }
    var ringExpiryDate: Date { incoming.ringExpiryDate }

    fileprivate init(
        incoming: AuthenticatedIncomingCall,
        callID: String,
        initiatorUserID: String
    ) {
        self.incoming = incoming
        self.callID = callID
        self.initiatorUserID = initiatorUserID
    }
}

enum CallWaitingRoute: Equatable, Sendable {
    /// No connected primary media session owns the screen, so use the ordinary incoming flow.
    case primary
    /// The authenticated event refers to the call that already owns the media session.
    case currentCall
    /// Present this different authenticated call on the in-call waiting surface.
    case waiting(AuthenticatedWaitingCall)
    /// A different call arrived during connected media but lacks safe waiting/merge authority.
    case decline
}

/// Routes only authenticated calls. In particular, an initiator id copied directly from PushKit
/// is never enough authority for a later group-call invitation: it must still be canonical and be
/// present in the account-scoped GET /calls/{id} participant projection.
enum CallWaitingRoutingPolicy {
    static func route(
        incoming: AuthenticatedIncomingCall,
        activeCallID: String?,
        mediaState: CallWaitingMediaState,
        now: Date = Date()
    ) -> CallWaitingRoute {
        guard mediaState.permitsWaitingCall else { return .primary }
        guard let activeCallID = CallWaitingCanonicalIdentity.uuid(activeCallID) else {
            return .decline
        }
        guard let incomingCallID = CallWaitingCanonicalIdentity.uuid(incoming.record.id),
              incoming.callUUID.uuidString.lowercased() == incomingCallID
        else { return .decline }
        guard activeCallID != incomingCallID else { return .currentCall }
        guard incoming.ringExpiryDate > now,
              incoming.record.state == .ringing,
              incoming.record.direction.caseInsensitiveCompare("incoming") == .orderedSame,
              let initiatorUserID = CallWaitingCanonicalIdentity.uuid(incoming.initiatorUserID),
              let participantUserIDs = CallWaitingCanonicalIdentity.roster(
                incoming.record.participantUserIds
              ),
              participantUserIDs.contains(initiatorUserID)
        else { return .decline }

        return .waiting(AuthenticatedWaitingCall(
            incoming: incoming,
            callID: incomingCallID,
            initiatorUserID: initiatorUserID
        ))
    }
}

struct CallWaitingMergeTarget: Equatable, Sendable {
    let activeCallID: String
    let waitingCallID: String
    let recipientUserID: String
}

enum CallWaitingMergeDenial: Equatable, Sendable {
    case noWaitingCall
    case mergeInProgress
    case mediaUnavailable
    case waitingCallExpired
    case invalidActiveCall
    case sameCall
    case activeCallNotFound
    case ambiguousActiveCall
    case activeCallNotActive
    case conversationBound
    case invalidRoster
    case callerAlreadyParticipant
    case participantLimitReached
}

enum CallWaitingMergeEligibility: Equatable, Sendable {
    case eligible(CallWaitingMergeTarget)
    case denied(CallWaitingMergeDenial)
}

/// Validates the complete local authority needed for Android-parity "Merge": invite the waiting
/// caller into the one current backend call, then decline their separate waiting call. This does
/// not model holding, swapping, or fusing two media sessions.
enum CallWaitingMergePolicy {
    static let maximumParticipantCount = 21

    static func eligibility(
        waitingCall: AuthenticatedWaitingCall,
        activeCallID: String?,
        mediaState: CallWaitingMediaState,
        calls: [CallRecord],
        currentUserID: String?,
        participantLimit: Int = CallWaitingMergePolicy.maximumParticipantCount,
        now: Date = Date()
    ) -> CallWaitingMergeEligibility {
        guard mediaState.permitsWaitingCall else { return .denied(.mediaUnavailable) }
        guard waitingCall.ringExpiryDate > now else {
            return .denied(.waitingCallExpired)
        }
        guard let activeCallID = CallWaitingCanonicalIdentity.uuid(activeCallID) else {
            return .denied(.invalidActiveCall)
        }
        guard activeCallID != waitingCall.callID else { return .denied(.sameCall) }

        let matchingCalls = calls.filter {
            CallWaitingCanonicalIdentity.uuid($0.id) == activeCallID
        }
        guard !matchingCalls.isEmpty else { return .denied(.activeCallNotFound) }
        guard matchingCalls.count == 1, let activeCall = matchingCalls.first else {
            return .denied(.ambiguousActiveCall)
        }
        guard activeCall.state == .active else { return .denied(.activeCallNotActive) }
        guard activeCall.conversationId == nil else { return .denied(.conversationBound) }
        guard participantLimit >= 2,
              let currentUserID = CallWaitingCanonicalIdentity.uuid(currentUserID),
              var participantUserIDs = CallWaitingCanonicalIdentity.roster(
                activeCall.participantUserIds
              )
        else { return .denied(.invalidRoster) }

        participantUserIDs.insert(currentUserID)
        guard !participantUserIDs.contains(waitingCall.initiatorUserID) else {
            return .denied(.callerAlreadyParticipant)
        }
        guard participantUserIDs.count < participantLimit else {
            return .denied(.participantLimitReached)
        }

        return .eligible(CallWaitingMergeTarget(
            activeCallID: activeCallID,
            waitingCallID: waitingCall.callID,
            recipientUserID: waitingCall.initiatorUserID
        ))
    }
}

enum CallWaitingRetention: Equatable, Sendable {
    case retained
    case refreshed
    /// The first waiting call remains authoritative; the returned call was not retained.
    case occupied(AuthenticatedWaitingCall)
}

struct CallWaitingMergeAttempt: Equatable, Sendable {
    fileprivate let generation: UInt64
    let target: CallWaitingMergeTarget
}

enum CallWaitingMergeDecision: Equatable, Sendable {
    case begin(CallWaitingMergeAttempt)
    case denied(CallWaitingMergeDenial)
}

enum CallWaitingMergeResult: Equatable, Sendable {
    case success
    case failure
}

enum CallWaitingMergeCompletion: Equatable, Sendable {
    /// The waiting call is removed; the caller should now decline its separate backend call.
    case merged(AuthenticatedWaitingCall)
    /// The waiting call remains visible and may be retried.
    case retainedForRetry(AuthenticatedWaitingCall)
    /// A newer offer, decline, expiry, or lifecycle clear invalidated this asynchronous result.
    case stale
}

/// Owns exactly one waiting call and fences asynchronous merge completions with a monotonic token.
/// All removals also cancel the in-flight merge locally, so late HTTP success cannot clear a newer
/// waiting presentation.
struct CallWaitingState: Equatable, Sendable {
    private(set) var waitingCall: AuthenticatedWaitingCall?
    private(set) var mergeAttempt: CallWaitingMergeAttempt?
    private var generation: UInt64 = 0

    init() {}

    var isMerging: Bool { mergeAttempt != nil }

    @discardableResult
    mutating func retain(
        _ call: AuthenticatedWaitingCall
    ) -> CallWaitingRetention {
        guard let current = waitingCall else {
            generation &+= 1
            waitingCall = call
            mergeAttempt = nil
            return .retained
        }
        guard current.callID == call.callID,
              current.initiatorUserID == call.initiatorUserID
        else { return .occupied(call) }
        waitingCall = call
        return .refreshed
    }

    mutating func beginMerge(
        activeCallID: String?,
        mediaState: CallWaitingMediaState,
        calls: [CallRecord],
        currentUserID: String?,
        participantLimit: Int = CallWaitingMergePolicy.maximumParticipantCount,
        now: Date = Date()
    ) -> CallWaitingMergeDecision {
        guard mergeAttempt == nil else { return .denied(.mergeInProgress) }
        guard let waitingCall else { return .denied(.noWaitingCall) }
        switch CallWaitingMergePolicy.eligibility(
            waitingCall: waitingCall,
            activeCallID: activeCallID,
            mediaState: mediaState,
            calls: calls,
            currentUserID: currentUserID,
            participantLimit: participantLimit,
            now: now
        ) {
        case .denied(let reason):
            return .denied(reason)
        case .eligible(let target):
            generation &+= 1
            let attempt = CallWaitingMergeAttempt(
                generation: generation,
                target: target
            )
            mergeAttempt = attempt
            return .begin(attempt)
        }
    }

    mutating func completeMerge(
        _ attempt: CallWaitingMergeAttempt,
        result: CallWaitingMergeResult
    ) -> CallWaitingMergeCompletion {
        guard mergeAttempt == attempt,
              let waitingCall,
              waitingCall.callID == attempt.target.waitingCallID,
              waitingCall.initiatorUserID == attempt.target.recipientUserID
        else { return .stale }

        mergeAttempt = nil
        switch result {
        case .success:
            self.waitingCall = nil
            generation &+= 1
            return .merged(waitingCall)
        case .failure:
            return .retainedForRetry(waitingCall)
        }
    }

    /// A local decline always wins over an in-flight merge response.
    @discardableResult
    mutating func decline() -> AuthenticatedWaitingCall? {
        clearWaitingCall()
    }

    /// Clears the waiting presentation exactly at its authenticated server deadline.
    @discardableResult
    mutating func expire(at now: Date = Date()) -> AuthenticatedWaitingCall? {
        guard let waitingCall, waitingCall.ringExpiryDate <= now else { return nil }
        return clearWaitingCall()
    }

    /// Consumes an authenticated lifecycle transition for this waiting call. The integration layer
    /// chooses which server event is terminal for its viewer, while this identity fence guarantees
    /// that an event for another call cannot dismiss the current banner.
    @discardableResult
    mutating func clearForLifecycle(callID: String) -> AuthenticatedWaitingCall? {
        guard let callID = CallWaitingCanonicalIdentity.uuid(callID),
              waitingCall?.callID == callID
        else { return nil }
        return clearWaitingCall()
    }

    @discardableResult
    private mutating func clearWaitingCall() -> AuthenticatedWaitingCall? {
        guard let removed = waitingCall else { return nil }
        waitingCall = nil
        mergeAttempt = nil
        generation &+= 1
        return removed
    }
}

private enum CallWaitingCanonicalIdentity {
    static func uuid(_ value: String?) -> String? {
        guard let value,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              let identifier = UUID(uuidString: value)
        else { return nil }
        return identifier.uuidString.lowercased()
    }

    static func roster(_ values: [String]) -> Set<String>? {
        var result: Set<String> = []
        result.reserveCapacity(values.count)
        for value in values {
            guard let identifier = uuid(value), result.insert(identifier).inserted else {
                return nil
            }
        }
        return result
    }
}

enum IncomingCallLookupFailureDisposition: Equatable, Sendable {
    case terminal
    case transient
}

enum IncomingCallLookupFailurePolicy {
    static func disposition(for error: Error) -> IncomingCallLookupFailureDisposition {
        if error is CancellationError { return .transient }
        if error is URLError { return .transient }
        if let payload = error as? APIErrorPayload {
            guard let status = payload.httpStatus else { return .terminal }
            return disposition(forHTTPStatus: status)
        }
        if let apiError = error as? APIClientError {
            switch apiError {
            case .signedOut, .invalidURL, .invalidResponse:
                return .terminal
            case .invalidPayload(let status), .httpStatus(let status):
                return disposition(forHTTPStatus: status)
            case .httpResponse(let status, _):
                return disposition(forHTTPStatus: status)
            }
        }
        return .transient
    }

    private static func disposition(forHTTPStatus status: Int) -> IncomingCallLookupFailureDisposition {
        status == 408 || status == 425 || status == 429 || status >= 500
            ? .transient
            : .terminal
    }
}

enum IncomingCallLookupRetryPolicy {
    /// A normal ring lasts 45 seconds. One-, two-, four-, then eight-second delays keep transient
    /// recovery responsive without turning a generic CallKit surface into a request hammer.
    private static let exponentialDelays: [TimeInterval] = [1, 2, 4, 8]

    static func retryAfter(from error: Error) -> TimeInterval? {
        if let payload = error as? APIErrorPayload { return payload.retryAfter }
        if let clientError = error as? APIClientError,
           case .httpResponse(_, let retryAfter) = clientError {
            return retryAfter
        }
        return nil
    }

    static func delay(
        failureCount: Int,
        retryAfter: TimeInterval?,
        remainingLifetime: TimeInterval
    ) -> TimeInterval? {
        guard remainingLifetime.isFinite, remainingLifetime > 0 else { return nil }
        let index = min(max(0, failureCount - 1), exponentialDelays.count - 1)
        let exponentialDelay = exponentialDelays[index]
        let serverDelay: TimeInterval
        if let retryAfter {
            guard retryAfter.isFinite else { return nil }
            serverDelay = max(0, retryAfter)
        } else {
            serverDelay = 0
        }
        let delay = max(exponentialDelay, serverDelay)
        return delay < remainingLifetime ? delay : nil
    }
}

enum IncomingCallQuarantinePolicy {
    /// Missing or malformed push expiry gets only a short grace period. A valid but hostile future
    /// timestamp is capped slightly above the backend's 45-second ring window. Once authenticated,
    /// the server's viewer-specific expiry replaces this local quarantine deadline.
    static let defaultLifetime: TimeInterval = 10
    static let maximumLifetime: TimeInterval = 60

    static func expiry(pushExpiry: Date?, receivedAt: Date) -> Date {
        guard let pushExpiry else {
            return receivedAt.addingTimeInterval(defaultLifetime)
        }
        return min(
            pushExpiry,
            receivedAt.addingTimeInterval(maximumLifetime)
        )
    }
}

enum IncomingCallVerificationAdmissionPolicy {
    static func permits(
        _ request: IncomingCallVerificationRequest,
        callUUID: UUID,
        pendingEventID: UUID?,
        admissionGeneration: UInt64?,
        currentGeneration: UInt64
    ) -> Bool {
        request.push.callUUID == callUUID
            && pendingEventID == request.eventId
            && admissionGeneration == request.admissionGeneration
            && request.admissionGeneration == currentGeneration
    }
}

/// Authenticated CallKit state is reusable only when protected-state recovery proves the exact
/// same account owner. An absent or replacement owner must retire the old calls instead of merely
/// concealing their display metadata and rebinding their action generation.
enum RetainedCallOwnerRecoveryPolicy {
    static func mayReuseAuthenticatedCalls(
        previousOwnerFingerprint: String?,
        recoveredOwnerFingerprint: String
    ) -> Bool {
        previousOwnerFingerprint == recoveredOwnerFingerprint
    }
}

struct IncomingCallNotice: Equatable, Sendable {
    let eventId: UUID
    let call: AuthenticatedIncomingCall

    init(eventId: UUID = UUID(), call: AuthenticatedIncomingCall) {
        self.eventId = eventId
        self.call = call
    }
}

enum CallSystemActionKind: Equatable, Sendable {
    case answer
    /// CallKit offered Answer for a second call while one media room was already connected. The
    /// action is translated into invite-current-plus-decline-waiting, never a second media room.
    case mergeWaiting
    case decline
    case end
    case timedOut
}

struct CallSystemAction: Equatable, Sendable {
    let eventId: UUID
    let callId: String
    let callUUID: UUID
    let kind: CallSystemActionKind
    let presentation: ActiveCallPresentation?

    init(
        eventId: UUID = UUID(),
        callId: String,
        callUUID: UUID,
        kind: CallSystemActionKind,
        presentation: ActiveCallPresentation? = nil
    ) {
        self.eventId = eventId
        self.callId = callId
        self.callUUID = callUUID
        self.kind = kind
        self.presentation = presentation
    }
}

enum CallLifecycleEvent: Equatable, Sendable {
    case verificationRequested(IncomingCallVerificationRequest)
    case incoming(IncomingCallNotice)
    case systemAction(CallSystemAction)

    var id: UUID {
        switch self {
        case .verificationRequested(let request): request.eventId
        case .incoming(let notice): notice.eventId
        case .systemAction(let action): action.eventId
        }
    }
}

/// Retains CallKit/PushKit events until the authenticated model has consumed them. This closes
/// the launch race where the system wakes the process and invokes delegates before SwiftUI has
/// installed its observers. Events remain ordered and are acknowledged only after handling.
final class PendingCallEventCache: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private var order: [UUID] = []
    private var events: [UUID: CallLifecycleEvent] = [:]

    init(capacity: Int = 64) {
        self.capacity = max(1, capacity)
    }

    func store(_ event: CallLifecycleEvent) {
        lock.lock()
        defer { lock.unlock() }
        guard events[event.id] == nil else { return }
        order.append(event.id)
        events[event.id] = event
        while order.count > capacity {
            events.removeValue(forKey: order.removeFirst())
        }
    }

    func acknowledge(_ eventId: UUID) {
        lock.lock()
        events.removeValue(forKey: eventId)
        order.removeAll { $0 == eventId }
        lock.unlock()
    }

    func pendingEvents() -> [CallLifecycleEvent] {
        lock.lock()
        let snapshot = order.compactMap { events[$0] }
        lock.unlock()
        return snapshot
    }

    func removeAll() {
        lock.lock()
        order.removeAll()
        events.removeAll()
        lock.unlock()
    }
}

enum CallLifecyclePolicy {
    private static let serverTimestampFormat = Date.ISO8601FormatStyle(
        includingFractionalSeconds: false
    )
    private static let fractionalServerTimestampFormat = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true
    )

    /// A decline is complete from this device's perspective when the server reports that the
    /// participant/call has already moved beyond the only state in which declining is valid.
    /// Match the stable backend code and endpoint operation narrowly; a generic 409 can still
    /// describe an actionable call failure and must not be hidden.
    static func isIdempotentTerminationFailure(
        _ error: Error,
        kind: CallTerminationKind
    ) -> Bool {
        guard kind == .decline,
              let payload = error as? APIErrorPayload,
              payload.code.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("CALL_NOT_DECLINABLE") == .orderedSame
        else { return false }
        return payload.httpStatus == nil || payload.httpStatus == 409
    }

    static func featureEnabled(_ capabilities: CapabilitiesDTO?) -> Bool {
        capabilities?.features?["calls"] == true
    }

    static func mayCreateCall(
        signedIn: Bool,
        online: Bool,
        capabilities: CapabilitiesDTO?
    ) -> Bool {
        guard signedIn else { return false }
        if online { return featureEnabled(capabilities) }
        return capabilities?.features?["calls"] != false
    }

    static func mappedState(_ rawValue: String) -> CallState {
        switch rawValue.lowercased() {
        case "queued": .queued
        case "ringing", "initiated": .ringing
        case "active", "answered", "connected": .active
        case "missed", "no_answer", "timed_out": .missed
        case "declined", "rejected": .declined
        case "failed", "cancelled": .failed
        case "completed", "ended": .completed
        default: .completed
        }
    }

    static func merge(remote: [CallRecord], local: [CallRecord]) -> [CallRecord] {
        var records = deduplicated(local)
        for remoteCall in deduplicated(remote).values {
            let call = preservingDurableContext(
                in: remoteCall,
                from: records[remoteCall.id.lowercased()]
            )
            records[call.id.lowercased()] = call
        }
        return records.values.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            return $0.id.lowercased() < $1.id.lowercased()
        }
    }

    /// Duplicate rows can be produced at cursor boundaries or by a legacy local projection. Pick
    /// the same lifecycle winner regardless of array/dictionary order, then retain useful context
    /// from the loser. This keeps merge results reproducible across launches and Swift runtimes.
    private static func deduplicated(_ calls: [CallRecord]) -> [String: CallRecord] {
        var groups: [String: [CallRecord]] = [:]
        groups.reserveCapacity(calls.count)
        for call in calls {
            let identity = call.id.lowercased()
            groups[identity, default: []].append(call)
        }

        var records: [String: CallRecord] = [:]
        records.reserveCapacity(groups.count)
        for (identity, duplicates) in groups {
            let ordered = duplicates.sorted { duplicateRecord($0, isNewerThan: $1) }
            guard var resolved = ordered.first else { continue }
            // Fold context in the same total order on every launch. Comparing an already enriched
            // intermediate record would otherwise let a different input permutation change which
            // later duplicate wins.
            for context in ordered.dropFirst() {
                resolved = preservingDurableContext(in: resolved, from: context)
            }
            records[identity] = resolved
        }
        return records
    }

    private static func duplicateRecord(_ lhs: CallRecord, isNewerThan rhs: CallRecord) -> Bool {
        let lhsLifecycle = lifecycleRank(lhs.state)
        let rhsLifecycle = lifecycleRank(rhs.state)
        if lhsLifecycle != rhsLifecycle { return lhsLifecycle > rhsLifecycle }

        let lhsEventDate = lhs.endedAt ?? lhs.answeredAt ?? lhs.startedAt
        let rhsEventDate = rhs.endedAt ?? rhs.answeredAt ?? rhs.startedAt
        if lhsEventDate != rhsEventDate { return lhsEventDate > rhsEventDate }

        let lhsState = stateTieBreakRank(lhs.state)
        let rhsState = stateTieBreakRank(rhs.state)
        if lhsState != rhsState { return lhsState > rhsState }
        if (lhs.answeredAt != nil) != (rhs.answeredAt != nil) { return lhs.answeredAt != nil }
        if (lhs.endedAt != nil) != (rhs.endedAt != nil) { return lhs.endedAt != nil }
        if lhs.isDeferredAttempt != rhs.isDeferredAttempt { return !lhs.isDeferredAttempt }

        let lhsConversation = OutboxPolicy.canonicalConversationID(lhs.conversationId)
        let rhsConversation = OutboxPolicy.canonicalConversationID(rhs.conversationId)
        if (lhsConversation != nil) != (rhsConversation != nil) { return lhsConversation != nil }
        if lhs.participantUserIds.count != rhs.participantUserIds.count {
            return lhs.participantUserIds.count > rhs.participantUserIds.count
        }
        return duplicateStableSignature(lhs) > duplicateStableSignature(rhs)
    }

    private static func lifecycleRank(_ state: CallState) -> Int {
        switch state {
        case .queued: 0
        case .ringing: 1
        case .active: 2
        case .completed, .missed, .declined, .failed: 3
        }
    }

    private static func stateTieBreakRank(_ state: CallState) -> Int {
        switch state {
        case .queued: 0
        case .ringing: 1
        case .active: 2
        case .failed: 3
        case .missed: 4
        case .declined: 5
        case .completed: 6
        }
    }

    private static func duplicateStableSignature(_ call: CallRecord) -> String {
        let components = [
            call.id,
            call.state.rawValue,
            call.direction.lowercased(),
            call.direction,
            call.type.lowercased(),
            call.type,
            call.video ? "1" : "0",
            call.name,
            OutboxPolicy.canonicalConversationID(call.conversationId) ?? "",
            call.conversationId ?? "",
            call.participantUserIds.map { lengthPrefixed($0.lowercased()) }.sorted().joined(),
            call.participantUserIds.map { lengthPrefixed($0) }.joined(),
            String(call.startedAt.timeIntervalSince1970),
            call.answeredAt.map { String($0.timeIntervalSince1970) } ?? "",
            call.endedAt.map { String($0.timeIntervalSince1970) } ?? "",
            call.isDeferredAttempt ? "1" : "0",
        ]
        // Length-prefixing keeps the ordering total even if arbitrary field contents or two
        // participant arrays would otherwise concatenate to the same bytes.
        return components.map { lengthPrefixed($0) }.joined()
    }

    private static func lengthPrefixed(_ value: String) -> String {
        "\(value.utf8.count):\(value)"
    }

    /// A paginated history response is a snapshot, so local answer/termination activity that
    /// happened while its pages were loading must not be rolled back by an older live state.
    static func mergeHistory(remote: [CallRecord], local: [CallRecord]) -> [CallRecord] {
        let localByID = deduplicated(local)
        let adjustedRemote = remote.map { remoteCall in
            guard let localCall = localByID[remoteCall.id.lowercased()],
                  localLifecycleDominatesHistory(localCall.state, remoteCall.state)
            else { return remoteCall }
            return preservingDurableContext(in: localCall, from: remoteCall)
        }
        return merge(remote: adjustedRemote, local: local)
    }

    private static func localLifecycleDominatesHistory(
        _ local: CallState,
        _ remote: CallState
    ) -> Bool {
        switch local {
        case .active:
            return [.queued, .ringing].contains(remote)
        case .completed, .missed, .declined, .failed:
            return [.queued, .ringing, .active].contains(remote)
        case .queued, .ringing:
            return false
        }
    }

    /// A call-start response can arrive after a concurrent history refresh has already observed
    /// answer or termination. In that narrow race, the start endpoint's ringing state is stale.
    static func mergingStartResponse(
        _ response: CallRecord,
        with existingServerCall: CallRecord?
    ) -> CallRecord {
        guard let existingServerCall,
              localLifecycleDominatesHistory(existingServerCall.state, response.state)
        else {
            return preservingDurableContext(in: response, from: existingServerCall)
        }
        return preservingDurableContext(in: existingServerCall, from: response)
    }

    /// Media credentials in a delayed start response are usable only while the reconciled server
    /// call is still live. A history/event update may have ended the call while the request was in
    /// flight, in which case reopening LiveKit would resurrect an already terminal call.
    static func allowsMediaStart(callID: String, in calls: [CallRecord]) -> Bool {
        guard let resolved = calls.first(where: {
            $0.id.caseInsensitiveCompare(callID) == .orderedSame
        }) else { return false }
        return [.ringing, .active].contains(resolved.state)
    }

    /// Lifecycle endpoints are allowed to omit immutable context. Preserve the authenticated
    /// local projection rather than letting a partial replay erase chat placement or duration.
    /// A previously bound conversation is immutable for the lifetime of a call; malformed or
    /// contradictory later bindings cannot move the row into another chat.
    static func preservingDurableContext(
        in remote: CallRecord,
        from local: CallRecord?,
        fallbackConversationID: String? = nil,
        fallbackParticipantUserIDs: [String] = [],
        fallbackName: String? = nil
    ) -> CallRecord {
        var call = remote
        let durableConversationID = OutboxPolicy.canonicalConversationID(local?.conversationId)
            ?? OutboxPolicy.canonicalConversationID(fallbackConversationID)
        let remoteConversationID = OutboxPolicy.canonicalConversationID(remote.conversationId)
        if let durableConversationID {
            call.conversationId = remoteConversationID == durableConversationID
                ? remoteConversationID
                : durableConversationID
        } else {
            call.conversationId = remoteConversationID
        }

        call.answeredAt = remote.answeredAt ?? local?.answeredAt
        call.endedAt = remote.endedAt ?? local?.endedAt
        if call.participantUserIds.isEmpty {
            if let localParticipants = local?.participantUserIds, !localParticipants.isEmpty {
                call.participantUserIds = localParticipants
            } else {
                call.participantUserIds = fallbackParticipantUserIDs
            }
        }
        if call.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || call.name == "Kit Pay user" {
            let durableName = local?.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
                ?? fallbackName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            if let durableName { call.name = durableName }
        }
        if call.startedAt == Date(timeIntervalSince1970: 0), let local {
            call.startedAt = local.startedAt
        }
        return call
    }

    /// A delayed/replayed ringing event must not downgrade an answer or terminal state already
    /// learned from the authenticated call API.
    static func mergingIncomingRing(_ incoming: CallRecord, into local: [CallRecord]) -> [CallRecord] {
        if let existing = local.first(where: {
            $0.id.caseInsensitiveCompare(incoming.id) == .orderedSame
        }), existing.state != .ringing {
            return local
        }
        return merge(remote: [incoming], local: local)
    }

    /// The authenticated lookup launched for an incoming push can have been serialized before a
    /// local CallKit timeout. Viewer-scoped missed direction and later lifecycle states must win
    /// over that delayed lookup rather than resurrecting a finished ring.
    static func mergingVerifiedIncomingLookup(
        _ verified: CallRecord,
        into local: [CallRecord]
    ) -> [CallRecord] {
        guard let existing = local.first(where: {
            $0.id.caseInsensitiveCompare(verified.id) == .orderedSame
        }) else { return merge(remote: [verified], local: local) }
        let existingIsMissed = existing.direction.caseInsensitiveCompare("missed") == .orderedSame
        let existingIsTerminal = [CallState.completed, .missed, .declined, .failed]
            .contains(existing.state)
        let verifiedIsLive = [CallState.queued, .ringing, .active].contains(verified.state)
        let verifiedRegressesActive = existing.state == .active
            && [CallState.queued, .ringing].contains(verified.state)
        guard !existingIsMissed,
              !(existingIsTerminal && verifiedIsLive),
              !verifiedRegressesActive
        else {
            let preserved = preservingDurableContext(in: existing, from: verified)
            return merge(remote: [preserved], local: local)
        }
        return merge(remote: [verified], local: local)
    }

    static func applyingPendingTerminations(
        to calls: [CallRecord],
        outbox: [OfflineCommand]
    ) -> [CallRecord] {
        var pendingByCallID: [String: CallTerminationReplay] = [:]
        pendingByCallID.reserveCapacity(outbox.count)
        for command in outbox {
            guard let action = OutboxPolicy.terminationReplay(for: command) else { continue }
            let identity = action.callId.lowercased()
            if pendingByCallID[identity] == nil { pendingByCallID[identity] = action }
        }
        guard !pendingByCallID.isEmpty else { return calls }
        return calls.map { call in
            guard let action = pendingByCallID[call.id.lowercased()] else { return call }
            var updated = call
            updated.state = action.kind == .decline ? .declined : .completed
            updated.endedAt = updated.endedAt ?? Date()
            return updated
        }
    }

    static func contactOptions(
        remote: [WalletContactDTO],
        history: [CallRecord],
        context: PhoneIdentityContext = .uganda,
        excludingUserId: String? = nil,
        remoteAlreadyOrdered: Bool = false
    ) -> [CallableContact] {
        var remoteOptions: [CallableContact] = []
        var remoteUserIds: Set<String> = []

        let directory = remoteAlreadyOrdered
            ? remote
            : ContactRecipientDirectory.ordered(remote, context: context)
        for contact in directory {
            let phoneIdentity = PhoneIdentityNormalizer.normalizedE164(contact.phone, context: context)
            let isCallable = contact.isKitUser == true && UUID(uuidString: contact.id) != nil
            let subtitle: String
            if let tag = contact.tag, !tag.isEmpty {
                subtitle = "@\(tag)"
            } else {
                subtitle = contact.phone
            }
            let option = CallableContact(
                id: contact.id,
                name: contact.name,
                subtitle: subtitle,
                isKitUser: isCallable,
                phoneIdentity: phoneIdentity,
                source: contact
            )
            remoteUserIds.insert(contact.id.lowercased())
            remoteOptions.append(option)
        }

        var historyOptions: [CallableContact] = []
        for call in history {
            guard let participantId = call.participantUserIds.first(where: {
                UUID(uuidString: $0) != nil
                    && $0.caseInsensitiveCompare(excludingUserId ?? "") != .orderedSame
            }),
                  !remoteUserIds.contains(participantId.lowercased())
            else { continue }
            guard !historyOptions.contains(where: { $0.id.caseInsensitiveCompare(participantId) == .orderedSame })
            else { continue }
            historyOptions.append(
                CallableContact(
                    id: participantId,
                    name: call.name,
                    subtitle: "Recent Kit Pay contact",
                    isKitUser: true,
                    phoneIdentity: nil,
                    source: nil
                )
            )
        }

        historyOptions.sort {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return remoteOptions.filter(\.isKitUser)
            + historyOptions
            + remoteOptions.filter { !$0.isKitUser }
    }

    static func serverTimestamp(_ value: String?) -> Date? {
        guard let value else { return nil }
        if let date = try? serverTimestampFormat.parse(value) { return date }
        return try? fractionalServerTimestampFormat.parse(value)
    }
}

struct ConversationTimelineDateSeparator: Equatable, Sendable {
    let day: Date
    let label: String

    var accessibilityLabel: String { "Chat events from \(label)" }
}

enum ConversationTimelineItem: Identifiable, Equatable {
    case message(LocalMessage)
    case payment(LocalMessage, KitPaymentMessage)
    case call(CallRecord)
    case dateSeparator(ConversationTimelineDateSeparator)

    var id: String {
        switch self {
        case .message(let message):
            "message:\(message.id.uuidString.lowercased())"
        case .payment(let message, _):
            "payment:\(message.id.uuidString.lowercased())"
        case .call(let call):
            "call:\(call.id.lowercased())"
        case .dateSeparator(let separator):
            "date:\(Int64(separator.day.timeIntervalSinceReferenceDate))"
        }
    }

    var occurredAt: Date {
        switch self {
        case .message(let message): message.createdAt
        case .payment(let message, _): message.createdAt
        case .call(let call): call.startedAt
        case .dateSeparator(let separator): separator.day
        }
    }
}

enum ConversationTimelineDateLabelPolicy {
    /// WhatsApp-style headings: Today, Yesterday, weekday names for the rest of the recent week,
    /// then an unambiguous localized calendar date. The caller supplies calendar/locale so tests
    /// and rendering use the same day boundary and remain deterministic.
    static func label(
        for date: Date,
        relativeTo referenceDate: Date,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        let day = calendar.startOfDay(for: date)
        let referenceDay = calendar.startOfDay(for: referenceDate)
        let daysAgo = calendar.dateComponents([.day], from: day, to: referenceDay).day
        guard let daysAgo else { return calendarDateLabel(for: day, calendar: calendar, locale: locale) }
        switch daysAgo {
        case 0: return "Today"
        case 1: return "Yesterday"
        case 2 ... 6:
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = locale
            formatter.timeZone = calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate("EEEE")
            return formatter.string(from: day)
        default:
            return calendarDateLabel(for: day, calendar: calendar, locale: locale)
        }
    }

    private static func calendarDateLabel(
        for day: Date,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: day)
    }
}

enum ConversationTimelinePolicy {
    static func items(
        for conversation: Conversation,
        allConversations: [Conversation],
        currentUserID: String?,
        messages: [LocalMessage],
        calls: [CallRecord],
        dateSeparatorsRelativeTo referenceDate: Date? = nil,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> [ConversationTimelineItem] {
        var candidates: [Candidate] = []
        let paymentRecipient = paymentRecipientUserID(
            for: conversation,
            currentUserID: currentUserID
        )
        let matchingMessages = messages.filter {
            if $0.conversationId == conversation.id { return true }
            guard let conversationID = canonicalUUID(conversation.id) else { return false }
            return canonicalUUID($0.conversationId) == conversationID
        }
        candidates.reserveCapacity(matchingMessages.count + calls.count)
        for message in matchingMessages {
            let item: ConversationTimelineItem
            if let paymentRecipient,
               paymentMessageSenderIsValid(
                   message,
                   currentUserID: currentUserID,
                   recipientUserID: paymentRecipient
               ),
               let descriptor = KitPaymentMessage.parse(message.body) {
                item = .payment(message, descriptor)
            } else {
                item = .message(message)
            }
            candidates.append(
                Candidate(
                    item: item,
                    kindOrder: 0,
                    stableID: message.id.uuidString.lowercased()
                )
            )
        }

        var seenCallIDs: Set<String> = []
        let relevantCalls = calls.compactMap { call -> CallRecord? in
            guard let callID = canonicalUUID(call.id),
                  seenCallIDs.insert(callID).inserted,
                  belongs(
                    call,
                    to: conversation,
                    allConversations: allConversations,
                    currentUserID: currentUserID
                  )
            else { return nil }
            var canonicalCall = call
            canonicalCall.conversationId = call.conversationId.flatMap(canonicalUUID)
            return canonicalCall
        }
        for call in relevantCalls {
            candidates.append(
                Candidate(
                    item: .call(call),
                    kindOrder: 1,
                    stableID: call.id.lowercased()
                )
            )
        }

        let ordered = candidates.sorted(by: comesBefore).map(\.item)
        guard let referenceDate else { return ordered }
        return insertingDateSeparators(
            into: ordered,
            relativeTo: referenceDate,
            calendar: calendar,
            locale: locale
        )
    }

    private static func insertingDateSeparators(
        into items: [ConversationTimelineItem],
        relativeTo referenceDate: Date,
        calendar: Calendar,
        locale: Locale
    ) -> [ConversationTimelineItem] {
        guard !items.isEmpty else { return [] }
        var result: [ConversationTimelineItem] = []
        result.reserveCapacity(items.count + min(items.count, 16))
        var previousDay: Date?
        for item in items {
            let day = calendar.startOfDay(for: item.occurredAt)
            if previousDay.map({ !calendar.isDate($0, inSameDayAs: day) }) ?? true {
                result.append(
                    .dateSeparator(
                        ConversationTimelineDateSeparator(
                            day: day,
                            label: ConversationTimelineDateLabelPolicy.label(
                                for: day,
                                relativeTo: referenceDate,
                                calendar: calendar,
                                locale: locale
                            )
                        )
                    )
                )
                previousDay = day
            }
            result.append(item)
        }
        return result
    }

    /// Payment actions are projected only in a canonical one-to-one server conversation. Sender
    /// binding is checked separately for each event, so a descriptor received through corrupt
    /// legacy state or a future group thread remains inert text instead of gaining controls.
    static func paymentRecipientUserID(
        for conversation: Conversation,
        currentUserID: String?
    ) -> String? {
        guard canonicalUUID(conversation.id) != nil,
              let currentUserID = canonicalUUID(currentUserID),
              conversation.participantUserIds.count == 2,
              var participants = canonicalParticipants(conversation.participantUserIds),
              participants.count == 2,
              participants.remove(currentUserID) != nil
        else { return nil }
        return participants.first
    }

    private static func paymentMessageSenderIsValid(
        _ message: LocalMessage,
        currentUserID: String?,
        recipientUserID: String
    ) -> Bool {
        guard let currentUserID = canonicalUUID(currentUserID),
              let senderUserID = canonicalUUID(message.senderId)
        else { return false }
        return senderUserID == (message.isOutgoing ? currentUserID : recipientUserID)
    }

    private static func belongs(
        _ call: CallRecord,
        to conversation: Conversation,
        allConversations: [Conversation],
        currentUserID: String?
    ) -> Bool {
        guard let conversationID = canonicalUUID(conversation.id) else { return false }
        if let explicit = call.conversationId {
            // An explicit malformed or different binding is never replaced by a display-name or
            // participant guess. A contradictory participant roster also fails closed so corrupt
            // lifecycle data cannot place Alice's call in Bob's thread.
            guard canonicalUUID(explicit) == conversationID else { return false }
            return explicitParticipantsAreConsistent(
                call.participantUserIds,
                conversationParticipants: conversation.participantUserIds,
                currentUserID: currentUserID
            )
        }
        guard let currentUserID = canonicalUUID(currentUserID),
              let callPeer = remotePeer(in: call.participantUserIds, currentUserID: currentUserID),
              let conversationPeer = directConversationPeer(
                in: conversation.participantUserIds,
                currentUserID: currentUserID
              ),
              callPeer == conversationPeer
        else { return false }

        // A legacy call without a server conversation id belongs to a thread only when there is
        // exactly one matching direct conversation. Choosing by mutable recency could otherwise
        // move the same historical call between duplicate threads as new messages arrive.
        var matchingConversationIDs: Set<String> = []
        for candidate in allConversations + [conversation] {
            guard let candidateID = canonicalUUID(candidate.id) else { continue }
            guard directConversationPeer(
                in: candidate.participantUserIds,
                currentUserID: currentUserID
            ) == callPeer else { continue }
            matchingConversationIDs.insert(candidateID)
        }
        return matchingConversationIDs.count == 1
            && matchingConversationIDs.contains(conversationID)
    }

    private static func explicitParticipantsAreConsistent(
        _ callParticipants: [String],
        conversationParticipants: [String],
        currentUserID: String?
    ) -> Bool {
        guard !callParticipants.isEmpty else { return true }
        guard let currentUserID = canonicalUUID(currentUserID),
              var callPeers = canonicalParticipants(callParticipants),
              var conversationPeers = canonicalParticipants(conversationParticipants)
        else { return false }
        callPeers.remove(currentUserID)
        conversationPeers.remove(currentUserID)
        return !callPeers.isEmpty
            && !conversationPeers.isEmpty
            && callPeers == conversationPeers
    }

    private static func canonicalParticipants(_ values: [String]) -> Set<String>? {
        var participants: Set<String> = []
        for value in values {
            guard let participant = canonicalUUID(value) else { return nil }
            participants.insert(participant)
        }
        return participants
    }

    private static func remotePeer(
        in participantUserIDs: [String],
        currentUserID: String
    ) -> String? {
        guard !participantUserIDs.isEmpty else { return nil }
        var participants: Set<String> = []
        for rawID in participantUserIDs {
            guard let participant = canonicalUUID(rawID) else { return nil }
            participants.insert(participant)
        }
        participants.remove(currentUserID)
        guard participants.count == 1 else { return nil }
        return participants.first
    }

    private static func directConversationPeer(
        in participantUserIDs: [String],
        currentUserID: String
    ) -> String? {
        var participants: Set<String> = []
        for rawID in participantUserIDs {
            guard let participant = canonicalUUID(rawID) else { return nil }
            participants.insert(participant)
        }
        guard participants.count == 2, participants.remove(currentUserID) != nil else { return nil }
        return participants.first
    }

    private static func canonicalUUID(_ value: String?) -> String? {
        guard let value,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              let uuid = UUID(uuidString: value)
        else { return nil }
        return uuid.uuidString.lowercased()
    }

    private static func comesBefore(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.item.occurredAt != rhs.item.occurredAt {
            return lhs.item.occurredAt < rhs.item.occurredAt
        }
        if lhs.kindOrder != rhs.kindOrder { return lhs.kindOrder < rhs.kindOrder }
        return lhs.stableID < rhs.stableID
    }

    private struct Candidate {
        let item: ConversationTimelineItem
        let kindOrder: Int
        let stableID: String
    }
}

/// Resolves the one conversation that an in-call message action may open. An authenticated
/// server conversation id wins unless the exact persisted call roster contradicts that binding.
/// Older/unbound one-to-one calls may fall back to the participant roster only when exactly one
/// direct conversation matches, so the call screen can never route into an arbitrary duplicate
/// or group thread.
enum ActiveCallConversationPolicy {
    struct CreationTarget: Equatable {
        let recipientUserID: String
        /// When the call carries a server conversation binding, the idempotent create response
        /// must resolve to that exact thread. A different id is a contradictory server response.
        let expectedConversationID: String?
    }

    static func conversation(
        callID: String,
        explicitConversationID: String?,
        calls: [CallRecord],
        conversations: [Conversation],
        currentUserID: String?
    ) -> Conversation? {
        guard let canonicalCallID = canonicalUUID(callID) else { return nil }

        if let explicitConversationID {
            guard let canonicalConversationID = canonicalUUID(explicitConversationID) else {
                return nil
            }
            let matches = conversations.filter {
                canonicalUUID($0.id) == canonicalConversationID
            }
            guard matches.count == 1 else { return nil }

            let matchingCalls = calls.filter { canonicalUUID($0.id) == canonicalCallID }
            guard matchingCalls.count <= 1 else { return nil }
            if let matchingCall = matchingCalls.first,
               !explicitParticipantsAreConsistent(
                   matchingCall.participantUserIds,
                   conversationParticipants: matches[0].participantUserIds,
                   currentUserID: currentUserID
               ) {
                return nil
            }
            return matches[0]
        }

        guard let currentUserID = canonicalUUID(currentUserID) else { return nil }
        let matchingCalls = calls.filter { canonicalUUID($0.id) == canonicalCallID }
        guard matchingCalls.count == 1,
              let remoteUserID = callRemoteUserID(
                matchingCalls[0].participantUserIds,
                currentUserID: currentUserID
              )
        else { return nil }

        let matchingConversations = conversations.filter {
            conversationRemoteUserID($0.participantUserIds, currentUserID: currentUserID)
                == remoteUserID
        }
        guard matchingConversations.count == 1 else { return nil }
        return matchingConversations[0]
    }

    static func unreadCount(
        callID: String,
        explicitConversationID: String?,
        calls: [CallRecord],
        conversations: [Conversation],
        currentUserID: String?
    ) -> Int {
        max(
            0,
            conversation(
                callID: callID,
                explicitConversationID: explicitConversationID,
                calls: calls,
                conversations: conversations,
                currentUserID: currentUserID
            )?.unreadCount ?? 0
        )
    }

    /// Resolves the only peer for whom an authenticated direct conversation may be created.
    /// Existing exact conversations are handled by `conversation`; this path is intentionally
    /// limited to one persisted call record, one remote UUID, and no ambiguous local direct chat.
    static func creationTarget(
        callID: String,
        explicitConversationID: String?,
        calls: [CallRecord],
        conversations: [Conversation],
        currentUserID: String?
    ) -> CreationTarget? {
        guard conversation(
            callID: callID,
            explicitConversationID: explicitConversationID,
            calls: calls,
            conversations: conversations,
            currentUserID: currentUserID
        ) == nil,
              let canonicalCallID = canonicalUUID(callID),
              let currentUserID = canonicalUUID(currentUserID)
        else { return nil }

        let matchingCalls = calls.filter { canonicalUUID($0.id) == canonicalCallID }
        guard matchingCalls.count == 1,
              let remoteUserID = callRemoteUserID(
                matchingCalls[0].participantUserIds,
                currentUserID: currentUserID
              )
        else { return nil }

        let matchingDirectConversations = conversations.filter {
            conversationRemoteUserID($0.participantUserIds, currentUserID: currentUserID)
                == remoteUserID
        }
        guard matchingDirectConversations.isEmpty else {
            // One match would already have been returned above. Reaching here means either a
            // contradictory explicit binding or duplicate direct threads; both fail closed.
            return nil
        }

        if let explicitConversationID {
            guard let expectedConversationID = canonicalUUID(explicitConversationID),
                  !conversations.contains(where: {
                    canonicalUUID($0.id) == expectedConversationID
                  })
            else { return nil }
            return CreationTarget(
                recipientUserID: remoteUserID,
                expectedConversationID: expectedConversationID
            )
        }

        return CreationTarget(
            recipientUserID: remoteUserID,
            expectedConversationID: nil
        )
    }

    private static func callRemoteUserID(
        _ participantUserIDs: [String],
        currentUserID: String
    ) -> String? {
        var participants: Set<String> = []
        for value in participantUserIDs {
            guard let participant = canonicalUUID(value) else { return nil }
            participants.insert(participant)
        }
        participants.remove(currentUserID)
        guard participants.count == 1 else { return nil }
        return participants.first
    }

    private static func conversationRemoteUserID(
        _ participantUserIDs: [String],
        currentUserID: String
    ) -> String? {
        var participants: Set<String> = []
        for value in participantUserIDs {
            guard let participant = canonicalUUID(value) else { return nil }
            participants.insert(participant)
        }
        guard participants.count == 2, participants.remove(currentUserID) != nil else { return nil }
        return participants.first
    }

    private static func explicitParticipantsAreConsistent(
        _ callParticipants: [String],
        conversationParticipants: [String],
        currentUserID: String?
    ) -> Bool {
        guard !callParticipants.isEmpty else { return true }
        guard let currentUserID = canonicalUUID(currentUserID),
              var callPeers = canonicalParticipants(callParticipants),
              var conversationPeers = canonicalParticipants(conversationParticipants)
        else { return false }
        callPeers.remove(currentUserID)
        conversationPeers.remove(currentUserID)
        return !callPeers.isEmpty
            && !conversationPeers.isEmpty
            && callPeers == conversationPeers
    }

    private static func canonicalParticipants(_ values: [String]) -> Set<String>? {
        var participants: Set<String> = []
        for value in values {
            guard let participant = canonicalUUID(value) else { return nil }
            participants.insert(participant)
        }
        return participants
    }

    private static func canonicalUUID(_ value: String?) -> String? {
        guard let value,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              let uuid = UUID(uuidString: value)
        else { return nil }
        return uuid.uuidString.lowercased()
    }
}

struct ConversationCallPresentation: Equatable {
    let title: String
    let symbolName: String
    let isOutgoing: Bool
    let isMissed: Bool
    let statusText: String?
    let durationSeconds: Int?
    let callbackEnabled: Bool
}

enum ConversationCallPresentationPolicy {
    static func presentation(for call: CallRecord) -> ConversationCallPresentation {
        let normalizedDirection = call.direction.lowercased()
        let isOutgoing = normalizedDirection == "outgoing"
        // The backend direction is viewer-scoped; global call state is not. An outgoing no-answer
        // must remain an outgoing call instead of becoming a contradictory right-aligned “missed”.
        let isMissed = normalizedDirection == "missed"
        let mediaName = call.isVideoCall ? "Video call" : "Voice call"
        let statusText: String? = if isMissed {
            nil
        } else {
            switch call.state {
            case .queued: "Waiting for connection"
            case .ringing: "Ringing"
            case .active: "In call"
            case .declined: "Declined"
            case .failed: "Failed"
            case .completed, .missed: nil
            }
        }
        return ConversationCallPresentation(
            title: isMissed ? "Missed \(mediaName.lowercased())" : mediaName,
            symbolName: isMissed
                ? "phone.down.fill"
                : (isOutgoing ? "phone.arrow.up.right" : "phone.arrow.down.left"),
            isOutgoing: isOutgoing,
            isMissed: isMissed,
            statusText: statusText,
            durationSeconds: durationSeconds(for: call),
            callbackEnabled: isMissed
                || ![CallState.queued, .ringing, .active].contains(call.state)
        )
    }

    static func durationSeconds(for call: CallRecord) -> Int? {
        guard let answeredAt = call.answeredAt, let endedAt = call.endedAt else { return nil }
        return max(0, Int(endedAt.timeIntervalSince(answeredAt)))
    }

    static func durationText(_ seconds: Int) -> String {
        let safeSeconds = max(0, seconds)
        let hours = safeSeconds / 3_600
        let minutes = (safeSeconds % 3_600) / 60
        let remainder = safeSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }
}

/// How the screen behaves while a call is active. A video call must never auto-dim or lock
/// (the user is watching, not touching); an audio call held to the ear must blank via the
/// proximity sensor like the system Phone app.
enum CallScreenWakePolicy {
    static func idleTimerDisabled(hasActiveCall: Bool, carriesVideo: Bool) -> Bool {
        hasActiveCall && carriesVideo
    }

    static func proximityMonitoringEnabled(
        hasActiveCall: Bool,
        carriesVideo: Bool,
        audioRoute: CallAudioRoute
    ) -> Bool {
        // Only the built-in receiver is held to the ear. Speaker, wired, Bluetooth and car
        // routes must keep the display usable instead of blanking it whenever a hand is nearby.
        hasActiveCall && !carriesVideo && audioRoute == .receiver
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
