import Foundation

/// Phases of one voice-note draft. A draft is plaintext audio that exists only on this
/// device: nothing about it is encrypted, uploaded, or sent until the user presses Send,
/// and only an explicit discard throws it away.
enum VoiceNoteDraftPhase: Equatable, Sendable {
    /// No draft. The composer shows the ordinary message field.
    case idle
    /// The microphone is capturing an active segment.
    case recording
    /// Capture is stopped mid-draft. What exists so far is a row of finalized,
    /// individually playable segments; the user may listen back, resume, send, or discard.
    case paused
    /// Playing the draft back locally, from `paused`. Nothing leaves the device.
    case previewing
}

/// The transition table for a voice-note draft, kept pure so every row is pinned by a
/// unit test rather than by a microphone. Durations are the caller's fact — the recorder
/// owns the segment files and their summed length; this owns only what may happen next.
/// A transition returns the next phase, or nil when refused from the current phase.
enum VoiceNoteDraftPolicy {
    /// Shared with Android (`KitChatMediaLimits`): one second to thirty minutes.
    static let minimumDuration: TimeInterval = 1
    static let maximumDuration: TimeInterval = 30 * 60

    /// A fresh recording may only begin when no draft exists.
    static func startRecording(_ phase: VoiceNoteDraftPhase) -> VoiceNoteDraftPhase? {
        phase == .idle ? .recording : nil
    }

    /// Pausing is only meaningful while the microphone is live.
    static func pause(_ phase: VoiceNoteDraftPhase) -> VoiceNoteDraftPhase? {
        phase == .recording ? .paused : nil
    }

    /// Resuming appends a new segment to the paused draft. Allowed from a preview too —
    /// hearing the draft and continuing it is the whole flow this exists for — but never
    /// once the draft has reached the maximum length a note may be.
    static func resume(
        _ phase: VoiceNoteDraftPhase,
        recorded: TimeInterval
    ) -> VoiceNoteDraftPhase? {
        guard phase == .paused || phase == .previewing,
              recorded < maximumDuration
        else { return nil }
        return .recording
    }

    /// Listening back requires a paused draft with at least one finalized segment.
    static func beginPreview(
        _ phase: VoiceNoteDraftPhase,
        hasSegments: Bool
    ) -> VoiceNoteDraftPhase? {
        phase == .paused && hasSegments ? .previewing : nil
    }

    /// A finished or interrupted preview settles back onto the paused draft.
    static func endPreview(_ phase: VoiceNoteDraftPhase) -> VoiceNoteDraftPhase? {
        phase == .previewing ? .paused : nil
    }

    /// Whether Send may take the draft right now. Sending is allowed while still
    /// recording — the tap finalizes the active segment on its way out — as long as the
    /// draft has reached the one-second minimum a note must be.
    static func sendable(_ phase: VoiceNoteDraftPhase, recorded: TimeInterval) -> Bool {
        phase != .idle && recorded >= minimumDuration
    }

    /// What a live recording does at the maximum length: it pauses. A send the user never
    /// asked for sits badly with a draft flow whose whole point is that encryption and
    /// upload happen strictly at Send — the capped draft stays local, listenable, and
    /// explicitly theirs to send or discard.
    static func capacityReached(_ recorded: TimeInterval) -> Bool {
        recorded >= maximumDuration
    }

    /// What an ordinary UI interruption — navigation, backgrounding, a read-only flip —
    /// does to each phase. Live capture pauses (the microphone must not keep running
    /// behind the user's back, and a finalized segment survives anything short of process
    /// death); a preview stops for the same reason; a paused draft is simply kept.
    /// Nothing here ever discards: only the user does that, explicitly.
    static func phaseAfterInterruption(_ phase: VoiceNoteDraftPhase) -> VoiceNoteDraftPhase {
        phase == .idle ? .idle : .paused
    }
}
