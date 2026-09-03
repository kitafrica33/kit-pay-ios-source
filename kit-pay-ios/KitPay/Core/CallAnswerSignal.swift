import Foundation

/// One validated "this call was answered" fact, whichever transport carried it.
///
/// The socket frame, the `call.answered` push, and the accept response all describe the same
/// server instant. Reducing them to this one value before anything downstream may act is what
/// keeps the two live routes equally strict — neither is the softer way in, because there is
/// only one way in.
struct CallAnswerSignal: Equatable, Sendable {
    /// Canonical lowercase UUID of the answered call.
    let callId: String
    /// The server-authoritative instant the call became active.
    let answeredAt: Date
    /// The server's own clock when it sent this signal, so the receiver can turn
    /// `answeredAt` into elapsed seconds without consulting the device's wall clock.
    let serverTime: Date
}

/// Admission rules for an answer signal. Acting on one starts a call timer, silences a ringing
/// device, and moves CallKit state, so anything that is not the shape the server actually sends
/// has to stop here rather than downstream.
enum CallAnswerSignalPolicy {
    /// The server hard-caps a call at four hours, so a signal claiming to have been answered
    /// longer ago than that describes a call that cannot still be running — a replay.
    static let maximumAgeSeconds: TimeInterval = 14_400
    /// Two server processes stamped the two instants; a small inversion means "no time has
    /// passed", not a lie. A large one is a forged or corrupted pair.
    static let maximumFutureSkewSeconds: TimeInterval = 60
    /// The one state an answer may announce, on every route alike.
    static let activeState = "active"

    /// Normalises a call id, refusing anything that is not the UUID the server issues.
    /// Foundation's `UUID(uuidString:)` already rejects short groups; the round-trip
    /// comparison additionally refuses padding, wrapping, or embedded whitespace.
    static func callId(_ raw: String?) -> String? {
        guard let raw,
              raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
              let identifier = UUID(uuidString: raw)
        else { return nil }
        let canonical = identifier.uuidString.lowercased()
        return canonical.caseInsensitiveCompare(raw) == .orderedSame ? canonical : nil
    }

    /// The call's age at the moment the server sent the signal, or `nil` when the pair is not
    /// one the server could have produced. Every rule compares the two server instants to each
    /// other — never to this device's clock — so a phone that is years wrong still takes a
    /// genuine answer, and a forged pair is refused no matter what the phone believes.
    static func age(answeredAt: Date, serverTime: Date) -> TimeInterval? {
        let age = serverTime.timeIntervalSince(answeredAt)
        guard age <= maximumAgeSeconds, age >= -maximumFutureSkewSeconds else { return nil }
        return max(0, age)
    }

    /// Builds the one validated signal from raw wire strings, or nothing at all. Both instants
    /// must be present and readable and the pair must pass `age` — half an anchor would start
    /// the timer from a number the server never sent.
    static func signal(
        callId rawCallId: String?,
        answeredAt rawAnsweredAt: String?,
        serverTime rawServerTime: String?
    ) -> CallAnswerSignal? {
        guard let callId = callId(rawCallId),
              let answeredAt = CallLifecyclePolicy.serverTimestamp(rawAnsweredAt),
              let serverTime = CallLifecyclePolicy.serverTimestamp(rawServerTime),
              age(answeredAt: answeredAt, serverTime: serverTime) != nil
        else { return nil }
        return CallAnswerSignal(
            callId: callId,
            answeredAt: answeredAt,
            serverTime: serverTime
        )
    }
}

/// The push fallback of the answer signal. Delivered by APNs when the socket is not, and held
/// to the same rules: the id and state validate or the push is not an answer at all, while a
/// timestamp pair that fails the rules costs the timer its anchor, not the answer itself —
/// this route is authenticated by APNs and the server behind it, and an older server sends no
/// timestamps at all, so the caller still has to stop ringing.
struct CallAnsweredPush: Equatable, Sendable {
    static let pushType = "call.answered"

    let callId: String
    let signal: CallAnswerSignal?

    init?(payload: [AnyHashable: Any]) {
        guard Self.string(payload["type"]) == Self.pushType,
              Self.string(payload["state"]) == CallAnswerSignalPolicy.activeState,
              let callId = CallAnswerSignalPolicy.callId(Self.string(payload["call_id"]))
        else { return nil }
        self.callId = callId
        signal = CallAnswerSignalPolicy.signal(
            callId: callId,
            answeredAt: Self.string(payload["answered_at"]),
            serverTime: Self.string(payload["server_time"])
        )
    }

    private static func string(_ value: Any?) -> String? {
        value as? String
    }
}

/// One terminal call-lifecycle fact delivered by the backend's silent APNs channel.
///
/// These events close native CallKit surfaces even when no media room was ever attached. In
/// particular, a caller can end a still-ringing call, so waiting for a LiveKit disconnect cannot
/// be the only remote-end path. Type and state are validated as a pair before the UUID may affect
/// CallKit; a non-terminal `call.declined` sent to another participant is deliberately ignored.
enum CallTerminalPushDisposition: Equatable, Sendable {
    case remoteEnded
    case declinedElsewhere
    case unanswered

    var publicationRetirement: IncomingCallPublicationRetirement {
        switch self {
        case .remoteEnded:
            return .terminal(.remoteEnded)
        case .declinedElsewhere:
            return .terminal(.declinedElsewhere)
        case .unanswered:
            return .naturallyExpired
        }
    }
}

enum CallTerminalPushHandlingDisposition: Equatable, Sendable {
    case rememberTerminal
    case retireOfferedCall
}

/// Keeps an authoritative terminal signal scoped to one exact UUID. A signal may precede its
/// VoIP ring, in which case it creates only a tombstone; once that UUID has a pending, quarantined,
/// or authenticated native surface, the same signal is allowed to retire it.
enum CallTerminalPushPolicy {
    static func disposition(
        hasPendingPublication: Bool,
        hasMatchingQuarantinedCall: Bool,
        hasMatchingAuthenticatedCall: Bool
    ) -> CallTerminalPushHandlingDisposition {
        if hasPendingPublication || hasMatchingQuarantinedCall || hasMatchingAuthenticatedCall {
            return .retireOfferedCall
        }
        return .rememberTerminal
    }
}

struct CallTerminalPush: Equatable, Sendable {
    let callId: String
    let disposition: CallTerminalPushDisposition

    init?(payload: [AnyHashable: Any]) {
        guard let type = payload["type"] as? String,
              let state = payload["state"] as? String
        else { return nil }
        let disposition: CallTerminalPushDisposition
        switch (type, state) {
        case ("call.ended", "ended"):
            disposition = .remoteEnded
        case ("call.declined", "declined"):
            disposition = .declinedElsewhere
        case ("call.missed", "missed"):
            disposition = .unanswered
        default:
            return nil
        }
        guard let callId = CallAnswerSignalPolicy.callId(payload["call_id"] as? String) else {
            return nil
        }
        self.callId = callId
        self.disposition = disposition
    }
}

/// Where a call's displayed duration counts from, in monotonic-clock seconds.
///
/// Monotonic rather than wall-clock, because an NTP correction mid-call would otherwise jump
/// the timer, and the whole point of the server anchor is that neither side's wall clock is
/// trusted. `serverAuthoritative` records which kind of fact produced the origin: a locally
/// observed media connection is never earlier than the real answer, so a server anchor may
/// replace it, but never the other way round.
struct CallDurationAnchor: Equatable, Sendable {
    let callId: String
    let monotonicOrigin: TimeInterval
    let serverAuthoritative: Bool
}

enum CallDurationAnchorPolicy {
    /// Takes a validated answer signal into the anchor. The signal's age is measured entirely
    /// on the server's clock and mapped onto this device's monotonic clock at receipt, so the
    /// device's wall clock never enters the arithmetic. Repeated signals converge on the
    /// earliest origin: the displayed duration only ever moves forward.
    static func anchor(
        signal: CallAnswerSignal,
        monotonicNow: TimeInterval,
        previous: CallDurationAnchor?
    ) -> CallDurationAnchor {
        guard let age = CallAnswerSignalPolicy.age(
            answeredAt: signal.answeredAt,
            serverTime: signal.serverTime
        ) else { return previous ?? localAnchor(callId: signal.callId, monotonicNow: monotonicNow) }
        let origin = monotonicNow - age
        guard let previous,
              previous.callId == signal.callId,
              previous.serverAuthoritative,
              previous.monotonicOrigin <= origin
        else {
            return CallDurationAnchor(
                callId: signal.callId,
                monotonicOrigin: origin,
                serverAuthoritative: true
            )
        }
        return previous
    }

    /// Media is up, so the call is running whether or not anything authoritative has arrived
    /// yet. Anchoring here is never earlier than the real answer, so a server signal that
    /// arrives later still corrects the timer forward — while a second local observation for
    /// the same call never resets a timer that is already counting.
    static func anchorOnConnect(
        callId: String,
        monotonicNow: TimeInterval,
        previous: CallDurationAnchor?
    ) -> CallDurationAnchor {
        if let previous, previous.callId == callId { return previous }
        return localAnchor(callId: callId, monotonicNow: monotonicNow)
    }

    static func seconds(
        _ anchor: CallDurationAnchor?,
        monotonicNow: TimeInterval
    ) -> Int {
        guard let anchor else { return 0 }
        return max(0, Int(monotonicNow - anchor.monotonicOrigin))
    }

    private static func localAnchor(
        callId: String,
        monotonicNow: TimeInterval
    ) -> CallDurationAnchor {
        CallDurationAnchor(
            callId: callId,
            monotonicOrigin: monotonicNow,
            serverAuthoritative: false
        )
    }
}

/// The device's monotonic clock, in seconds. `CLOCK_MONOTONIC_RAW` keeps counting while the
/// device sleeps and never jumps with wall-clock adjustments, which is exactly what a call
/// timer needs from a phone that may sync NTP mid-call.
enum CallMonotonicClock {
    static func now() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
    }
}

/// What the caller's screen says while its own media is up but the other side's is not.
///
/// "Ringing…" after the callee has already picked up hands back exactly the latency the
/// answer signal exists to remove — and no second signal is coming to correct it. The
/// answering side never rings at all: its own accept is the answer.
enum CallAwaitingRemoteStatusPolicy {
    static func label(isOutgoing: Bool, answered: Bool) -> String {
        guard isOutgoing, !answered else { return "Connecting…" }
        return "Ringing…"
    }
}
