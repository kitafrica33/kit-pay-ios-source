import AVFoundation
import Foundation

/// Records AAC voice notes for end-to-end encrypted delivery.
///
/// A draft is captured as a row of *segments*: an MPEG-4 file is only playable once its
/// metadata is finalized at stop, so pausing stops the current recorder outright — turning
/// what exists so far into a finished, listenable file — and resuming opens the next
/// segment. Send stitches the row back into the single `audio/mp4` the wire expects, by
/// copying samples rather than re-encoding.
///
/// Every segment lands in a file-protected temporary file, plaintext audio that never
/// leaves this device until Send reads it back for the encrypted attachment pipeline. Only
/// Send or an explicit discard deletes a draft; an ordinary UI interruption merely pauses
/// it, which is why the registry below keeps recorders alive across view teardowns.
@MainActor
final class VoiceNoteRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    struct Recording {
        let data: Data
        let duration: TimeInterval
        static let mediaType = "audio/mp4"
    }

    static let minimumDuration = VoiceNoteDraftPolicy.minimumDuration
    static let maximumDuration = VoiceNoteDraftPolicy.maximumDuration

    @Published private(set) var phase: VoiceNoteDraftPhase = .idle
    /// Total captured audio: every finalized segment plus the live one.
    @Published private(set) var elapsed: TimeInterval = 0
    /// 0…1 microphone level for the live waveform.
    @Published private(set) var level: Float = 0
    @Published var errorMessage: String?

    private var recorder: AVAudioRecorder?
    private var meterTask: Task<Void, Never>?
    private var fileURL: URL?
    private var segmentURLs: [URL] = []
    private var finalizedDuration: TimeInterval = 0
    private var previewPlayer: AVQueuePlayer?
    private var previewEndObserver: NSObjectProtocol?
    /// Whether this recorder is the one that activated the shared audio session. The session is
    /// shared with `VoiceNotePlayer`, and handing it back is only ours to do if we took it.
    private var ownsAudioSession = false

    var isRecording: Bool { phase == .recording }
    var isPreviewing: Bool { phase == .previewing }

    /// Whether any capture exists at all — an active segment or finalized ones.
    var hasDraft: Bool { phase != .idle }

    /// Whether at least one finalized, individually playable segment exists.
    var hasPlayableSegments: Bool { !segmentURLs.isEmpty }

    func start() async {
        guard VoiceNoteDraftPolicy.startRecording(phase) != nil else { return }
        guard CallMediaCoordinator.shared.activeCall == nil else {
            errorMessage = "Finish your call before recording a voice note."
            return
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            errorMessage = "Allow microphone access in Settings to record voice notes."
            return
        }
        elapsed = 0
        finalizedDuration = 0
        beginSegment()
    }

    /// Finalizes the active segment into a playable file and stops the microphone. A
    /// near-empty segment that MPEG-4 cannot finalize is silently dropped — its handful
    /// of milliseconds is not audio the user could miss.
    func pause() {
        guard let paused = VoiceNoteDraftPolicy.pause(phase) else { return }
        finalizeActiveSegment()
        phase = hasPlayableSegments ? paused : .idle
        if phase == .idle { releaseAudioSession() }
    }

    /// Opens the next segment of a paused draft, ending any listen-back first.
    func resume() {
        guard VoiceNoteDraftPolicy.resume(phase, recorded: elapsed) != nil else { return }
        stopPreviewPlayback()
        beginSegment()
    }

    /// Plays the draft back locally, in capture order. Nothing leaves the device.
    func beginPreview() {
        guard let previewing = VoiceNoteDraftPolicy.beginPreview(
            phase,
            hasSegments: hasPlayableSegments
        ) else { return }
        let items = segmentURLs.map { AVPlayerItem(url: $0) }
        guard let lastItem = items.last else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        ownsAudioSession = true
        let player = AVQueuePlayer(items: items)
        previewEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: lastItem,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.endPreview() }
        }
        previewPlayer = player
        phase = previewing
        player.play()
    }

    /// Stops the listen-back and settles onto the paused draft.
    func endPreview() {
        guard let paused = VoiceNoteDraftPolicy.endPreview(phase) else { return }
        stopPreviewPlayback()
        phase = paused
        releaseAudioSession()
    }

    /// Stops and returns the finished note, or nil when it is too short to be worth sending.
    /// This is the only path a draft may leave the device on, and it consumes the draft.
    func finish() async -> Recording? {
        stopPreviewPlayback()
        finalizeActiveSegment()
        let urls = segmentURLs
        let duration = finalizedDuration
        segmentURLs = []
        finalizedDuration = 0
        phase = .idle
        defer {
            urls.forEach { try? FileManager.default.removeItem(at: $0) }
            releaseAudioSession()
        }
        guard !urls.isEmpty,
              duration >= Self.minimumDuration,
              let data = await VoiceNoteSegmentAssembler.assemble(urls),
              !data.isEmpty
        else { return nil }
        return Recording(data: data, duration: min(duration, Self.maximumDuration))
    }

    /// The explicit discard: everything captured so far is deleted, live or finalized.
    func cancel() {
        stopPreviewPlayback()
        recorder?.stop()
        stopMetering()
        recorder = nil
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil
        segmentURLs.forEach { try? FileManager.default.removeItem(at: $0) }
        segmentURLs = []
        finalizedDuration = 0
        elapsed = 0
        phase = .idle
        releaseAudioSession()
    }

    /// An ordinary UI interruption — leaving the chat, a read-only flip, backgrounding.
    /// The microphone stops and the audio stays: the draft is preserved for the user's
    /// return, and only Send or an explicit discard ever deletes it.
    func suspend() {
        stopPreviewPlayback()
        finalizeActiveSegment()
        phase = VoiceNoteDraftPolicy.phaseAfterInterruption(
            hasPlayableSegments ? .paused : .idle
        )
        releaseAudioSession()
    }

    nonisolated func audioRecorderDidFinishRecording(
        _ recorder: AVAudioRecorder,
        successfully flag: Bool
    ) {
        guard !flag else { return }
        Task { @MainActor in
            self.errorMessage = "Recording stopped unexpectedly."
            self.cancel()
        }
    }

    private func beginSegment() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kit-voice-\(UUID().uuidString).m4a", isDirectory: false)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 24_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
            ownsAudioSession = true
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            // Each segment may only spend what the earlier ones have left of the cap.
            let remaining = max(1, Self.maximumDuration - finalizedDuration)
            guard recorder.record(forDuration: remaining) else {
                throw NSError(
                    domain: "africa.kit.pay.voice-note",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Recording could not start."]
                )
            }
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: url.path
            )
            self.recorder = recorder
            fileURL = url
            level = 0
            errorMessage = nil
            phase = .recording
            startMetering()
        } catch {
            errorMessage = error.localizedDescription
            try? FileManager.default.removeItem(at: url)
            recorder = nil
            fileURL = nil
            phase = hasPlayableSegments ? .paused : .idle
            if phase == .idle { releaseAudioSession() }
        }
    }

    /// Stops the live recorder, keeping its file as the next finalized segment when it
    /// holds any audio at all.
    private func finalizeActiveSegment() {
        guard let recorder else { return }
        // `currentTime` reads 0 on a recorder that already auto-stopped at the cap, so
        // fall back to the metered elapsed time for this segment.
        let segmentDuration = recorder.isRecording
            ? recorder.currentTime
            : max(0, elapsed - finalizedDuration)
        recorder.stop()
        stopMetering()
        self.recorder = nil
        let url = fileURL
        fileURL = nil
        if let url,
           let bytes = try? FileManager.default
               .attributesOfItem(atPath: url.path)[.size] as? NSNumber,
           bytes.intValue > 0,
           segmentDuration > 0 {
            segmentURLs.append(url)
            finalizedDuration += segmentDuration
        } else if let url {
            try? FileManager.default.removeItem(at: url)
        }
        elapsed = finalizedDuration
    }

    private func stopPreviewPlayback() {
        if let previewEndObserver {
            NotificationCenter.default.removeObserver(previewEndObserver)
        }
        previewEndObserver = nil
        previewPlayer?.pause()
        previewPlayer = nil
    }

    private func startMetering() {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let recorder = self.recorder, self.phase == .recording else {
                    return
                }
                recorder.updateMeters()
                self.elapsed = self.finalizedDuration + recorder.currentTime
                let decibels = recorder.averagePower(forChannel: 0)
                // Map -50 dB…0 dB onto 0…1 with a gentle floor so quiet speech still moves.
                self.level = max(0, min(1, (decibels + 50) / 50))
                if VoiceNoteDraftPolicy.capacityReached(self.elapsed) {
                    // The cap pauses the draft rather than sending it: encryption and
                    // upload happen strictly at Send, and Send stays the user's own act.
                    self.pause()
                    return
                }
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    private func stopMetering() {
        meterTask?.cancel()
        meterTask = nil
        level = 0
    }

    /// Gives the audio session back — but only as far as is actually ours to give.
    ///
    /// This runs on every draft teardown and suspension, recording or not, so an
    /// unconditional deactivation would silence a voice note playing in the floating bar.
    /// Leave the session alone unless this recorder is the one that took it, and even then
    /// hand it to the player rather than tearing it down if a note is still going.
    private func releaseAudioSession() {
        guard ownsAudioSession else { return }
        ownsAudioSession = false
        let session = AVAudioSession.sharedInstance()
        if VoiceNotePlayer.shared.playing != nil {
            try? session.setCategory(.playback, mode: .spokenAudio)
            try? session.setActive(true)
            return
        }
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

/// Keeps a voice-note draft alive across ordinary UI interruptions.
///
/// A recorder owned by the conversation view dies with it, and navigation, recomposition,
/// and read-only flips all destroy that view. The recorder instead lives here, keyed by
/// conversation, holding only temp files and counters — so leaving the chat and coming
/// back costs the user nothing they said. A draft leaves this registry in exactly two
/// ways: it is sent, or it is explicitly discarded. Process death is the one interruption
/// that still loses it, which is what makes these files safe to hold.
@MainActor
final class VoiceNoteDraftRegistry {
    static let shared = VoiceNoteDraftRegistry()

    private var recorders: [String: VoiceNoteRecorder] = [:]

    private init() {}

    /// The one recorder for this conversation, created on first use.
    func recorder(for conversationID: String) -> VoiceNoteRecorder {
        let key = conversationID.lowercased()
        if let existing = recorders[key] { return existing }
        let created = VoiceNoteRecorder()
        recorders[key] = created
        return created
    }

    /// Called after send or discard, when the draft no longer exists to preserve.
    func release(_ conversationID: String) {
        recorders.removeValue(forKey: conversationID.lowercased())
    }
}

/// Stitches the finalized segments of a paused-and-resumed voice note back into the single
/// `audio/mp4` the wire contract expects, by copying AAC samples — never re-encoding, so
/// pausing costs the note no quality. The unpaused note stays exactly what it always was:
/// one segment short-circuits to its own bytes. Any failure returns nil rather than half a
/// file — a note that cannot be assembled is not sent.
enum VoiceNoteSegmentAssembler {
    static func assemble(_ segments: [URL]) async -> Data? {
        if segments.count == 1 { return try? Data(contentsOf: segments[0]) }
        guard !segments.isEmpty else { return nil }

        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { return nil }

        var cursor = CMTime.zero
        for segment in segments {
            let asset = AVURLAsset(url: segment)
            guard let source = try? await asset.loadTracks(withMediaType: .audio).first,
                  let duration = try? await asset.load(.duration),
                  (try? track.insertTimeRange(
                      CMTimeRange(start: .zero, duration: duration),
                      of: source,
                      at: cursor
                  )) != nil
            else { return nil }
            cursor = CMTimeAdd(cursor, duration)
        }

        let joinedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kit-voice-joined-\(UUID().uuidString).m4a", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: joinedURL) }
        guard let export = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else { return nil }
        export.outputURL = joinedURL
        export.outputFileType = .m4a
        await export.export()
        guard export.status == .completed else { return nil }
        return try? Data(contentsOf: joinedURL)
    }
}
