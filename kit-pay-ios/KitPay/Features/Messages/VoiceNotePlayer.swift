import AVFoundation
import MediaPlayer
import SwiftUI

/// One-at-a-time voice-note playback with published progress, seeking, and a life of its own.
///
/// The player deliberately outlives the bubble that started it: the note keeps playing when the
/// thread is scrolled past it, when the chat is left, and when Kit Pay is put in the background —
/// the same expectation a call sets. `VoiceNoteOverlayWindowController` puts a floating bar on
/// screen for exactly the window where the note is playing but its own bubble is not visible, so
/// there is always something to pause, scrub or dismiss it with.
@MainActor
final class VoiceNotePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = VoiceNotePlayer()

    /// The note being played, or nil when nothing is.
    @Published private(set) var playing: VoiceNotePlayingNote?
    @Published private(set) var isPaused = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var duration: TimeInterval = 0
    /// Whether the bubble (or library row) that owns the playing note is currently on screen.
    /// The floating bar is the fallback control for when it is not.
    @Published private(set) var isSourceOnScreen = false

    /// Kept as the identity every existing call site already reads.
    var playingID: UUID? { playing?.id }

    private var player: AVAudioPlayer?
    private var progressTask: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?
    private var hasRemoteCommands = false

    override private init() {
        super.init()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { notification in
            // An interruption (a call, Siri, another app taking the session) must leave the note
            // paused rather than silently "playing" against a dead session.
            let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
            MainActor.assumeIsolated { VoiceNotePlayer.shared.pause() }
        }
    }

    // MARK: Transport

    func toggle(data: Data, id: UUID, context: VoiceNotePlaybackContext) {
        if playing?.id == id, player != nil {
            if isPaused { resume() } else { pause() }
            return
        }
        stop()
        // A live call owns the audio session; a voice note must never take it away.
        guard CallMediaCoordinator.shared.activeCall == nil else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            player.prepareToPlay()
            player.play()
            self.player = player
            playing = VoiceNotePlayingNote(id: id, context: context)
            isPaused = false
            duration = player.duration
            progress = 0
            // Playback always begins from a control the user just touched.
            isSourceOnScreen = true
            startProgressUpdates()
            installRemoteCommands()
            publishNowPlaying()
            VoiceNoteOverlayWindowController.shared.refresh()
        } catch {
            stop()
        }
    }

    func pause() {
        guard let player, player.isPlaying else { return }
        player.pause()
        isPaused = true
        publishNowPlaying()
    }

    func resume() {
        guard let player, playing != nil else { return }
        // The session may have been deactivated by an interruption or by another note stopping.
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
        isPaused = false
        startProgressUpdates()
        publishNowPlaying()
    }

    func toggleCurrent() {
        guard playing != nil else { return }
        if isPaused { resume() } else { pause() }
    }

    /// Positions playback at `fraction` of the note. Used by both a tap inside the waveform and a
    /// slide along it; scrubbing past either end simply rests at that end.
    func seek(toFraction fraction: Double) {
        guard let player, playing != nil else { return }
        let target = VoiceNoteSeekPolicy.time(
            forFraction: fraction,
            duration: player.duration
        )
        player.currentTime = target
        progress = VoiceNoteSeekPolicy.fraction(forTime: target, duration: player.duration)
        publishNowPlaying()
    }

    /// Nudges playback by `delta` seconds, for the lock screen's skip controls.
    func seek(by delta: TimeInterval) {
        guard let player, playing != nil, player.duration > 0 else { return }
        seek(
            toFraction: VoiceNoteSeekPolicy.fraction(
                forTime: player.currentTime + delta,
                duration: player.duration
            )
        )
    }

    func stop() {
        progressTask?.cancel()
        progressTask = nil
        player?.stop()
        player = nil
        playing = nil
        isPaused = false
        isSourceOnScreen = false
        progress = 0
        duration = 0
        clearNowPlaying()
        removeRemoteCommands()
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: [.notifyOthersOnDeactivation]
        )
        VoiceNoteOverlayWindowController.shared.refresh()
    }

    // MARK: Source visibility

    /// Reported by the bubble or library row that owns a note as it enters and leaves the screen.
    /// A stale report from another row can never move the bar, because only the playing note's own
    /// source is listened to.
    func noteSourceVisibility(_ visible: Bool, for id: UUID) {
        guard playing?.id == id, isSourceOnScreen != visible else { return }
        isSourceOnScreen = visible
        VoiceNoteOverlayWindowController.shared.refresh()
    }

    // MARK: AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in self.stop() }
    }

    // MARK: Progress

    private func startProgressUpdates() {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let player = self.player else { return }
                // A call that starts mid-note takes the session; end the note rather than let it
                // fight the call for the route.
                if CallMediaCoordinator.shared.activeCall != nil {
                    self.stop()
                    return
                }
                if player.duration > 0 {
                    self.progress = player.currentTime / player.duration
                }
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    // MARK: Lock screen & Control Center

    private func installRemoteCommands() {
        guard !hasRemoteCommands else { return }
        hasRemoteCommands = true
        let center = MPRemoteCommandCenter.shared()
        // MediaPlayer does not promise these arrive on the main thread, so each hop rather than
        // asserting isolation it has not been given.
        center.playCommand.addTarget { _ in
            Task { @MainActor in VoiceNotePlayer.shared.resume() }
            return .success
        }
        center.pauseCommand.addTarget { _ in
            Task { @MainActor in VoiceNotePlayer.shared.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { _ in
            Task { @MainActor in VoiceNotePlayer.shared.toggleCurrent() }
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.addTarget { _ in
            Task { @MainActor in VoiceNotePlayer.shared.seek(by: 15) }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { _ in
            Task { @MainActor in VoiceNotePlayer.shared.seek(by: -15) }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let positionTime = event.positionTime
            Task { @MainActor in
                let player = VoiceNotePlayer.shared
                player.seek(
                    toFraction: VoiceNoteSeekPolicy.fraction(
                        forTime: positionTime,
                        duration: player.duration
                    )
                )
            }
            return .success
        }
    }

    private func removeRemoteCommands() {
        guard hasRemoteCommands else { return }
        hasRemoteCommands = false
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)
    }

    /// The lock screen shows who is speaking and where, never the note's contents.
    private func publishNowPlaying() {
        guard let player, let playing else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: playing.context.title,
            MPMediaItemPropertyArtist: playing.context.subtitle,
            MPMediaItemPropertyPlaybackDuration: player.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? 1.0 : 0.0,
        ]
    }

    private func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}

/// The note the player is currently on, with everything the floating bar needs to name it.
struct VoiceNotePlayingNote: Equatable {
    let id: UUID
    let context: VoiceNotePlaybackContext
}

/// The conversation a voice-note bubble is being drawn in.
///
/// Passed through the environment rather than as parameters because voice notes are rendered by
/// `SecureMediaMessageView` (chat) and the media library, and neither knows the speaker's name:
/// only the conversation screen can resolve a user id to "You", a contact, or a neutral fallback.
struct VoiceNoteChatContext {
    var conversationID: String = ""
    var conversationTitle: String = ""
    var displayName: (String) -> String = { _ in "Kit Pay user" }

    func playbackContext(senderUserID: String) -> VoiceNotePlaybackContext {
        VoiceNotePlaybackContext(
            conversationID: conversationID,
            speaker: displayName(senderUserID),
            conversationTitle: conversationTitle
        )
    }
}

private struct VoiceNoteChatContextKey: EnvironmentKey {
    static let defaultValue = VoiceNoteChatContext()
}

extension EnvironmentValues {
    var voiceNoteChatContext: VoiceNoteChatContext {
        get { self[VoiceNoteChatContextKey.self] }
        set { self[VoiceNoteChatContextKey.self] = newValue }
    }
}
