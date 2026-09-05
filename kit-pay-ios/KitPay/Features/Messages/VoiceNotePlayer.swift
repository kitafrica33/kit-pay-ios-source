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
    private var queuePlayer: AVQueuePlayer?
    private var queueURLs: [URL] = []
    private var queueDurations: [TimeInterval] = []
    /// Keeps a receiver-cache file ineligible for eviction for the whole lifetime of playback,
    /// including while its originating bubble has scrolled away and the floating player owns the
    /// controls. Sender originals are not evictable, but use the same optional handoff shape.
    private var protectedOriginalLease: SecureMediaOriginalAccessLease?
    private var queueEndObserver: NSObjectProtocol?
    private var progressTask: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?
    private var hasRemoteCommands = false
    private var ownsPlaybackAudioSession = false
    private var ownsNowPlayingInfo = false
    private var playbackGeneration = UUID()

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
        toggle(id: id, context: context, protectedOriginalLease: nil) {
            try AVAudioPlayer(data: data)
        }
    }

    func toggle(
        fileURL: URL,
        id: UUID,
        context: VoiceNotePlaybackContext,
        protectedOriginalLease: SecureMediaOriginalAccessLease? = nil
    ) {
        toggle(
            id: id,
            context: context,
            protectedOriginalLease: protectedOriginalLease
        ) {
            try AVAudioPlayer(contentsOf: fileURL)
        }
    }

    /// Plays finalized capture segments directly while their durable background assembly is in
    /// flight. No upload, remote URL, or re-download is involved.
    func toggle(
        fileURLs: [URL],
        segmentDurations: [TimeInterval],
        id: UUID,
        context: VoiceNotePlaybackContext
    ) {
        guard !fileURLs.isEmpty,
              fileURLs.count == segmentDurations.count,
              segmentDurations.allSatisfy({ $0.isFinite && $0 > 0 })
        else { return }
        if playing?.id == id, queuePlayer != nil {
            if isPaused { resume() } else { pause() }
            return
        }
        stop()
        guard CallMediaCoordinator.shared.activeCall == nil else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            ownsPlaybackAudioSession = true
            queueURLs = fileURLs
            queueDurations = segmentDurations
            playing = VoiceNotePlayingNote(id: id, context: context)
            isPaused = false
            duration = segmentDurations.reduce(0, +)
            progress = 0
            isSourceOnScreen = true
            rebuildQueue(startingAt: 0, offset: 0, shouldPlay: true)
            startProgressUpdates()
            installRemoteCommands()
            publishNowPlaying()
            VoiceNoteOverlayWindowController.shared.refresh()
        } catch {
            stop()
        }
    }

    private func toggle(
        id: UUID,
        context: VoiceNotePlaybackContext,
        protectedOriginalLease: SecureMediaOriginalAccessLease?,
        makePlayer: () throws -> AVAudioPlayer
    ) {
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
            ownsPlaybackAudioSession = true
            let player = try makePlayer()
            player.delegate = self
            player.prepareToPlay()
            player.play()
            self.player = player
            self.protectedOriginalLease = protectedOriginalLease
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
        guard player?.isPlaying == true || (queuePlayer?.rate ?? 0) != 0 else { return }
        player?.pause()
        queuePlayer?.pause()
        isPaused = true
        publishNowPlaying()
    }

    func resume() {
        guard playing != nil, (player != nil || queuePlayer != nil) else { return }
        // The session may have been deactivated by an interruption or by another note stopping.
        try? AVAudioSession.sharedInstance().setActive(true)
        player?.play()
        queuePlayer?.play()
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
        guard playing != nil else { return }
        if let player {
            let target = VoiceNoteSeekPolicy.time(
                forFraction: fraction,
                duration: player.duration
            )
            player.currentTime = target
            progress = VoiceNoteSeekPolicy.fraction(forTime: target, duration: player.duration)
            publishNowPlaying()
            return
        }
        guard queuePlayer != nil, duration > 0 else { return }
        let target = VoiceNoteSeekPolicy.time(
            forFraction: fraction,
            duration: duration
        )
        var prefix: TimeInterval = 0
        var targetIndex = queueDurations.index(before: queueDurations.endIndex)
        for index in queueDurations.indices {
            if target <= prefix + queueDurations[index] {
                targetIndex = index
                break
            }
            prefix += queueDurations[index]
        }
        rebuildQueue(
            startingAt: targetIndex,
            offset: max(0, target - prefix),
            shouldPlay: !isPaused
        )
        progress = VoiceNoteSeekPolicy.fraction(forTime: target, duration: duration)
        publishNowPlaying()
    }

    /// Nudges playback by `delta` seconds, for the lock screen's skip controls.
    func seek(by delta: TimeInterval) {
        guard playing != nil, duration > 0 else { return }
        seek(
            toFraction: VoiceNoteSeekPolicy.fraction(
                forTime: elapsedPlaybackTime + delta,
                duration: duration
            )
        )
    }

    func stop() {
        playbackGeneration = UUID()
        // A representable can re-offer the same video layer on every SwiftUI update. Stopping an
        // idle voice player must not publish fresh state or perform MediaPlayer/audio IPC again.
        guard playing != nil || player != nil || queuePlayer != nil || progressTask != nil
                || protectedOriginalLease != nil || queueEndObserver != nil
                || hasRemoteCommands || ownsPlaybackAudioSession || ownsNowPlayingInfo
        else { return }
        progressTask?.cancel()
        progressTask = nil
        player?.stop()
        player = nil
        queuePlayer?.pause()
        queuePlayer?.removeAllItems()
        queuePlayer = nil
        queueURLs = []
        queueDurations = []
        protectedOriginalLease = nil
        if let queueEndObserver { NotificationCenter.default.removeObserver(queueEndObserver) }
        queueEndObserver = nil
        playing = nil
        isPaused = false
        isSourceOnScreen = false
        progress = 0
        duration = 0
        clearNowPlaying()
        removeRemoteCommands()
        if ownsPlaybackAudioSession {
            ownsPlaybackAudioSession = false
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: [.notifyOthersOnDeactivation]
            )
        }
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
        Task { @MainActor [weak self, weak player] in
            guard let self, let player, self.player === player else { return }
            self.stop()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self, weak player] in
            guard let self, let player, self.player === player else { return }
            self.stop()
        }
    }

    // MARK: Progress

    private func startProgressUpdates() {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.player != nil || self.queuePlayer != nil else { return }
                // A call that starts mid-note takes the session; end the note rather than let it
                // fight the call for the route.
                if CallMediaCoordinator.shared.activeCall != nil {
                    self.stop()
                    return
                }
                if self.duration > 0 {
                    self.progress = VoiceNoteSeekPolicy.fraction(
                        forTime: self.elapsedPlaybackTime,
                        duration: self.duration
                    )
                }
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    // MARK: Lock screen & Control Center

    private func installRemoteCommands() {
        guard !hasRemoteCommands else { return }
        hasRemoteCommands = true
        let generation = playbackGeneration
        let center = MPRemoteCommandCenter.shared()
        // MediaPlayer does not promise these arrive on the main thread, so each hop rather than
        // asserting isolation it has not been given.
        center.playCommand.addTarget { _ in
            Task { @MainActor in
                VoiceNotePlayer.shared.performRemoteCommand(generation: generation) { $0.resume() }
            }
            return .success
        }
        center.pauseCommand.addTarget { _ in
            Task { @MainActor in
                VoiceNotePlayer.shared.performRemoteCommand(generation: generation) { $0.pause() }
            }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { _ in
            Task { @MainActor in
                VoiceNotePlayer.shared.performRemoteCommand(generation: generation) { $0.toggleCurrent() }
            }
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.addTarget { _ in
            Task { @MainActor in
                VoiceNotePlayer.shared.performRemoteCommand(generation: generation) { $0.seek(by: 15) }
            }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { _ in
            Task { @MainActor in
                VoiceNotePlayer.shared.performRemoteCommand(generation: generation) { $0.seek(by: -15) }
            }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let positionTime = event.positionTime
            Task { @MainActor in
                let player = VoiceNotePlayer.shared
                guard player.playbackGeneration == generation else { return }
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

    private func performRemoteCommand(generation: UUID, action: (VoiceNotePlayer) -> Void) {
        guard playbackGeneration == generation else { return }
        action(self)
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
        guard let playing, (player != nil || queuePlayer != nil) else { return }
        ownsNowPlayingInfo = true
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: playing.context.title,
            MPMediaItemPropertyArtist: playing.context.subtitle,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsedPlaybackTime,
            MPNowPlayingInfoPropertyPlaybackRate:
                (player?.isPlaying == true || (queuePlayer?.rate ?? 0) != 0) ? 1.0 : 0.0,
        ]
    }

    private var elapsedPlaybackTime: TimeInterval {
        if let player { return player.currentTime }
        guard let queuePlayer else { return 0 }
        let remaining = queuePlayer.items().count
        let completedCount = max(0, queueDurations.count - remaining)
        return queueDurations.prefix(completedCount).reduce(0, +)
            + max(0, queuePlayer.currentTime().seconds.isFinite
                ? queuePlayer.currentTime().seconds
                : 0)
    }

    private func rebuildQueue(
        startingAt index: Int,
        offset: TimeInterval,
        shouldPlay: Bool
    ) {
        guard queueURLs.indices.contains(index) else { return }
        if let queueEndObserver { NotificationCenter.default.removeObserver(queueEndObserver) }
        queueEndObserver = nil
        queuePlayer?.pause()
        queuePlayer?.removeAllItems()
        let items = queueURLs[index...].map { AVPlayerItem(url: $0) }
        guard let last = items.last else { return }
        let queue = AVQueuePlayer(items: items)
        queueEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: last,
            queue: .main
        ) { [weak self, weak queue] _ in
            MainActor.assumeIsolated {
                guard let self, let queue, self.queuePlayer === queue else { return }
                self.stop()
            }
        }
        queuePlayer = queue
        queue.seek(to: CMTime(seconds: offset, preferredTimescale: 600))
        if shouldPlay { queue.play() }
    }

    private func clearNowPlaying() {
        guard ownsNowPlayingInfo else { return }
        ownsNowPlayingInfo = false
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
