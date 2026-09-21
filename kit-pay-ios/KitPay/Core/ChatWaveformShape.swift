import Foundation

/// The bars a voice note draws, as arithmetic rather than as arrays.
///
/// The shape itself is unchanged from build 105 — same seed, same pseudo-noise, same heights —
/// but it is no longer *built* on every render. `VoiceNoteWaveform.body` re-ran for every
/// playback tick, which is 60 times a second while a note is playing, and each pass allocated a
/// 16-byte `[UInt8]` and a 26-element `[CGFloat]` before drawing anything. With several notes in
/// a mixed-media thread that is a few thousand short-lived allocations a second on the main
/// thread, all of them identical to the ones released a frame earlier.
///
/// Pure Foundation, no SwiftUI: exercised on Linux by
/// `.github/scripts/tests/run_chat_media_bucket_linux_gate.sh`.
enum ChatWaveformShape {
    /// Bars per note. Fixed, so the waveform of a 3-second note and a 3-minute note read alike.
    static let barCount = 26
    /// Shortest bar, in points.
    static let minimumHeight: Double = 6
    /// Number of distinct heights above `minimumHeight`.
    static let heightSteps: UInt8 = 16

    /// The height of one bar. Deterministic in the note's identity, so the same note always draws
    /// the same waveform and two notes rarely draw the same one.
    ///
    /// Reads the UUID's bytes in place — `withUnsafeBytes(of:)` over a tuple does not allocate —
    /// instead of copying them into an array to index once.
    static func height(seed: UUID, at index: Int) -> Double {
        guard index >= 0 else { return minimumHeight }
        let base = withUnsafeBytes(of: seed.uuid) { raw -> UInt8 in
            raw[index % raw.count]
        }
        let byte = base &+ UInt8(truncatingIfNeeded: index &* 37)
        return minimumHeight + Double(byte % heightSteps)
    }

    /// Whether a bar is behind the playhead. `progress` of 0 tints nothing: a note that has not
    /// been played must not look as though its first bar has been.
    static func isPlayed(index: Int, count: Int, progress: Double) -> Bool {
        guard count > 0, progress > 0, progress.isFinite else { return false }
        return Double(index) / Double(count) <= progress
    }
}
