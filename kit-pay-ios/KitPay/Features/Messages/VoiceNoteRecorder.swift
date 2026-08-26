import AVFoundation
import Foundation

/// Records AAC voice notes for end-to-end encrypted delivery.
///
/// Recordings land in a file-protected temporary file, are read back as `Data` for the encrypted
/// attachment pipeline, and the file is removed immediately afterwards — plaintext audio never
/// outlives the send flow on disk.
@MainActor
final class VoiceNoteRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    enum RecorderState: Equatable {
        case idle
        case recording
    }

    struct Recording {
        let data: Data
        let duration: TimeInterval
        static let mediaType = "audio/mp4"
    }

    static let minimumDuration: TimeInterval = 1
    static let maximumDuration: TimeInterval = 30 * 60

    @Published private(set) var state: RecorderState = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    /// 0…1 microphone level for the live waveform.
    @Published private(set) var level: Float = 0
    @Published var errorMessage: String?

    private var recorder: AVAudioRecorder?
    private var meterTask: Task<Void, Never>?
    private var fileURL: URL?
    /// Whether this recorder is the one that activated the shared audio session. The session is
    /// shared with `VoiceNotePlayer`, and handing it back is only ours to do if we took it.
    private var ownsAudioSession = false

    var isRecording: Bool { state == .recording }

    func start() async {
        guard state == .idle else { return }
        guard CallMediaCoordinator.shared.activeCall == nil else {
            errorMessage = "Finish your call before recording a voice note."
            return
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            errorMessage = "Allow microphone access in Settings to record voice notes."
            return
        }

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
            guard recorder.record(forDuration: Self.maximumDuration) else {
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
            elapsed = 0
            level = 0
            errorMessage = nil
            state = .recording
            startMetering()
        } catch {
            errorMessage = error.localizedDescription
            cleanUp(deleting: url)
        }
    }

    /// Stops and returns the finished note, or nil when it is too short to be worth sending.
    func finish() -> Recording? {
        guard state == .recording, let recorder, let fileURL else {
            cancel()
            return nil
        }
        // A note that hit the maximum duration has already auto-stopped; `currentTime`
        // reads 0 on a stopped recorder, so fall back to the metered elapsed time.
        let duration = recorder.isRecording ? recorder.currentTime : elapsed
        recorder.stop()
        stopMetering()
        defer { cleanUp(deleting: fileURL) }
        guard duration >= Self.minimumDuration,
              let data = try? Data(contentsOf: fileURL),
              !data.isEmpty
        else {
            state = .idle
            return nil
        }
        state = .idle
        return Recording(data: data, duration: duration)
    }

    func cancel() {
        recorder?.stop()
        stopMetering()
        cleanUp(deleting: fileURL)
        state = .idle
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

    private func startMetering() {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let recorder = self.recorder, self.state == .recording else {
                    return
                }
                recorder.updateMeters()
                self.elapsed = recorder.currentTime
                let decibels = recorder.averagePower(forChannel: 0)
                // Map -50 dB…0 dB onto 0…1 with a gentle floor so quiet speech still moves.
                self.level = max(0, min(1, (decibels + 50) / 50))
                if self.elapsed >= Self.maximumDuration - 0.1 {
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

    private func cleanUp(deleting url: URL?) {
        recorder = nil
        fileURL = nil
        if let url { try? FileManager.default.removeItem(at: url) }
        releaseAudioSession()
    }

    /// Gives the audio session back — but only as far as is actually ours to give.
    ///
    /// `cancel()` runs on every exit from a conversation, recording or not, so an unconditional
    /// deactivation here silenced a voice note that was playing quite happily in the floating bar:
    /// the note's own `AVAudioPlayer` survived, which is why pausing and playing it again brought
    /// the sound back. Leave the session alone unless this recorder is the one that took it, and
    /// even then hand it to the player rather than tearing it down if a note is still going.
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
