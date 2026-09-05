import CoreGraphics
import Foundation

/// Plaintext presentation belongs to the account lifetime that created its view/controller.
/// A delayed media lookup cannot start playback after logout and replacement authentication.
@MainActor
enum ChatMediaAccountLifetime {
    private(set) static var current = UUID()

    static func invalidate() { current = UUID() }
}

/// Who is speaking and where, kept alongside a playing voice note so the floating bar can name it
/// after the bubble that started it has scrolled away or the chat has been left entirely.
struct VoiceNotePlaybackContext: Equatable {
    /// Conversation the note belongs to. Playback is not resumable across conversations, so this
    /// is identity only — the bar never fetches with it.
    var conversationID: String
    /// Speaker, already resolved to a display name ("You", a contact, or a neutral fallback).
    var speaker: String
    /// Chat the note was sent in, shown under the speaker so a note playing after the user has
    /// left the thread still says where it came from.
    var conversationTitle: String

    /// What the floating bar puts on its first line: who is speaking, never the note itself.
    var title: String {
        speaker.isEmpty ? "Voice note" : speaker
    }

    /// The bar's second line. A one-to-one chat already says who the speaker is in its title, so
    /// repeating it underneath would read as a stutter.
    var subtitle: String {
        guard !conversationTitle.isEmpty, conversationTitle != title else { return "Voice note" }
        return conversationTitle
    }
}

/// Reading a finger on a voice note's waveform.
///
/// A tap positions playback at the point touched; a horizontal slide scrubs relative to where the
/// finger went down, so a long note can be nudged a second at a time instead of only jumped to.
/// A mostly-vertical drag is the thread being scrolled and is deliberately not a seek — the
/// waveform's gesture runs *alongside* the scroll view rather than replacing it.
enum VoiceNoteSeekPolicy {
    /// Drawn width of the in-bubble waveform. One waveform-width of travel is the whole note, so
    /// the gesture's sensitivity is stated here rather than derived from a measured frame.
    static let waveformWidth: CGFloat = 138

    /// Movement under this is a stationary tap, not a slide.
    static let tapSlop: CGFloat = 6

    static func isTap(translation: CGSize) -> Bool {
        abs(translation.width) < tapSlop && abs(translation.height) < tapSlop
    }

    /// A slide the note should follow: past the tap slop and more horizontal than vertical.
    static func isScrub(translation: CGSize) -> Bool {
        !isTap(translation: translation) && abs(translation.width) > abs(translation.height)
    }

    /// Absolute position of a tap inside a waveform of `width`.
    static func fraction(atX x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return clamped(Double(x / width))
    }

    /// Position a slide has reached, measured from where the finger went down. Full-width travel
    /// covers the whole note in either direction.
    static func scrubbedFraction(
        from start: Double,
        translationWidth: CGFloat,
        width: CGFloat
    ) -> Double {
        guard width > 0 else { return clamped(start) }
        return clamped(start + Double(translationWidth / width))
    }

    static func clamped(_ fraction: Double) -> Double {
        // A malformed/unknown value starts safely at the beginning. Signed infinity still has a
        // useful direction, so it clamps to the corresponding end just like any finite overflow.
        guard !fraction.isNaN else { return 0 }
        if fraction == .infinity { return 1 }
        if fraction == -.infinity { return 0 }
        return min(1, max(0, fraction))
    }

    /// Seconds a fraction of a note of `duration` corresponds to.
    static func time(forFraction fraction: Double, duration: TimeInterval) -> TimeInterval {
        guard duration > 0 else { return 0 }
        return clamped(fraction) * duration
    }

    static func fraction(forTime time: TimeInterval, duration: TimeInterval) -> Double {
        guard duration > 0 else { return 0 }
        return clamped(time / duration)
    }
}

/// When the floating voice-note bar is on screen.
///
/// The bar exists for a note that is still playing somewhere the user can no longer see or stop
/// it: scrolled past in the thread, or left behind entirely. While the bubble that owns the note
/// is visible the bubble *is* the control, so a second one on top of it would be noise.
enum VoiceNoteMiniBarPolicy {
    /// Height of the bar's content below the top safe-area inset — the same claim the minimized
    /// call strip makes, so the two surfaces push content down identically.
    /// `AppWindowTopStripReservation` adds the gap that separates either one from the app below.
    static let contentHeight: CGFloat = 60

    static func isVisible(hasPlayback: Bool, isSourceOnScreen: Bool) -> Bool {
        hasPlayback && !isSourceOnScreen
    }
}
