import AVFoundation
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Owns plaintext camera/editor scratch files. Every directory is protected before AVFoundation
/// receives its output URL, and leftovers from a crash or process termination are removed at the
/// next launch.
enum KitCaptureTemporaryFileStore {
    static let cameraDirectoryPrefix = "kit-camera-"
    static let editorDirectoryPrefix = "kit-trim-"

    static func makeFileURL(
        directoryPrefix: String,
        fileName: String,
        in temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> URL {
        guard [cameraDirectoryPrefix, editorDirectoryPrefix].contains(directoryPrefix) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let directory = temporaryDirectory.appendingPathComponent(
            "\(directoryPrefix)\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: directory.path
            )
            return directory.appendingPathComponent(fileName, isDirectory: false)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func protectFile(at url: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
    }

    static func removeAbandonedFiles(
        in temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix(cameraDirectoryPrefix)
                    || name.hasPrefix(editorDirectoryPrefix)
            else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }
}

// MARK: - Output

/// Final artifact produced by the in-app camera. Videos are temporary files the caller owns
/// (and removes after reading).
enum KitCameraOutput {
    /// The exact AVCapturePhoto bytes are retained beside the decoded preview. The preview can
    /// render immediately; the file is the secure source of truth adopted into Sent Media.
    case photo(fileURL: URL, mediaType: String, preview: UIImage)
    case video(URL, mediaType: String)
}

// MARK: - Controller

/// Permission callbacks, the main queue and the capture queue share this exact presentation
/// lifetime. Closing and reopening the camera never lets an older permission result restart it.
final class KitCameraSessionLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var current: UUID?

    func begin() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let token = UUID()
        current = token
        return token
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        current = nil
    }

    func isCurrent(_ token: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return current == token
    }
}

/// Owns the AVFoundation capture stack for `KitCameraView`: photo capture with flash,
/// segmented video recording with pause/resume, torch, camera flip, tap-to-focus, and zoom.
///
/// Classic AVFoundation threading: the session and its devices are touched only on
/// `sessionQueue`; every `@Published` mutation hops back to the main queue.
final class KitCameraController: NSObject, ObservableObject, @unchecked Sendable {
    enum Mode: Equatable {
        case photo
        case video
    }

    /// Video notes and clips stay well under the encrypted-transfer ceiling.
    static let maximumRecordingSeconds: TimeInterval = 5 * 60
    static let maximumZoomFactor: CGFloat = 8

    static var isCameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    @Published private(set) var isAuthorized = false
    @Published private(set) var authorizationChecked = false
    @Published var mode: Mode = .photo
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var recordedSeconds: TimeInterval = 0
    @Published private(set) var position: AVCaptureDevice.Position = .back
    @Published var flashEnabled = false
    @Published private(set) var torchActive = false
    @Published private(set) var zoomFactor: CGFloat = 1
    @Published private(set) var isProcessing = false
    @Published var errorMessage: String?

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "africa.kit.pay.ios.camera-session")
    private let sessionLifetime = KitCameraSessionLifetime()
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    // Delegates must outlive their capture; each is released when its own callback fires.
    private var activePhotoDelegate: PhotoCaptureDelegate?
    private var retainedSegmentDelegates: [SegmentRecordingDelegate] = []
    private var segmentURLs: [URL] = []
    private var completedSegmentsSeconds: TimeInterval = 0
    private var durationTimer: Timer?
    private var pendingFinish: ((KitCameraOutput?) -> Void)?
    /// A cancel/stop arrived while a segment was still finalizing on disk.
    private var discardSegmentsWhenFinalized = false
    /// Bumped per take so a superseded take's late callback cannot contaminate the next one.
    private var recordingGeneration = 0
    private var currentZoom: CGFloat = 1

    // MARK: Lifecycle

    func start() {
        let token = sessionLifetime.begin()
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self, self.sessionLifetime.isCurrent(token) else { return }
            DispatchQueue.main.async {
                guard self.sessionLifetime.isCurrent(token) else { return }
                self.isAuthorized = granted
                self.authorizationChecked = true
            }
            guard granted else { return }
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .notDetermined:
                // Do not configure while the first-use prompt is unresolved. Creating the audio
                // input during that window fails, and the already-installed video input used to
                // prevent every later start from retrying it.
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                    self?.configureAndStartSession(lifetime: token)
                }
            case .authorized, .denied, .restricted:
                self.configureAndStartSession(lifetime: token)
            @unknown default:
                self.configureAndStartSession(lifetime: token)
            }
        }
    }

    private func configureAndStartSession(lifetime token: UUID) {
        sessionQueue.async { [weak self] in
            guard let self, self.sessionLifetime.isCurrent(token) else { return }
            self.configureSessionIfNeeded()
            if self.sessionLifetime.isCurrent(token), !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    func stop() {
        sessionLifetime.invalidate()
        // The repeating timer lives on the main run loop; invalidate it here (stop() is
        // called from onDisappear on main) or it outlives the controller and fires forever.
        stopDurationTimer()
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.pendingFinish = nil
            if self.movieOutput.isRecording || !self.retainedSegmentDelegates.isEmpty {
                // A segment is live or still finalizing on disk; delete everything once the
                // last callback lands so no temp file is stranded.
                self.discardSegmentsWhenFinalized = true
                if self.movieOutput.isRecording {
                    self.movieOutput.stopRecording()
                }
            } else {
                self.removeSegments()
            }
            self.setTorch(enabled: false)
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    deinit {
        durationTimer?.invalidate()
    }

    private func configureSessionIfNeeded() {
        session.beginConfiguration()
        session.sessionPreset = .high
        if videoInput == nil,
           let camera = Self.camera(at: .back) ?? Self.camera(at: .front),
           let input = try? AVCaptureDeviceInput(device: camera),
           session.canAddInput(input) {
            session.addInput(input)
            videoInput = input
            DispatchQueue.main.async { self.position = camera.position }
        }
        if audioInput == nil,
           AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
           let microphone = AVCaptureDevice.default(for: .audio),
           let input = try? AVCaptureDeviceInput(device: microphone),
           session.canAddInput(input) {
            session.addInput(input)
            audioInput = input
        }
        if !session.outputs.contains(where: { $0 === photoOutput }),
           session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }
        if !session.outputs.contains(where: { $0 === movieOutput }),
           session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
            movieOutput.maxRecordedDuration = CMTime(
                seconds: Self.maximumRecordingSeconds,
                preferredTimescale: 600
            )
        }
        session.commitConfiguration()
        if videoInput == nil {
            DispatchQueue.main.async {
                self.errorMessage = "The camera is not available on this device."
            }
        }
    }

    private static func camera(at position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    }

    // MARK: Photo

    func capturePhoto(completion: @escaping (KitCameraOutput?) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self, self.videoInput != nil else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let settings = AVCapturePhotoSettings()
            if self.videoInput?.device.isFlashAvailable == true,
               self.photoOutput.supportedFlashModes.contains(.on) {
                var flashOn = false
                DispatchQueue.main.sync { flashOn = self.flashEnabled }
                settings.flashMode = flashOn ? .on : .off
            }
            let delegate = PhotoCaptureDelegate { [weak self] result in
                DispatchQueue.main.async {
                    completion(result)
                    self?.activePhotoDelegate = nil
                }
            }
            self.activePhotoDelegate = delegate
            self.photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }

    // MARK: Video (segments give pause/resume; the segments compose at finish)

    func startRecording() {
        sessionQueue.async { [weak self] in
            guard let self, !self.movieOutput.isRecording else { return }
            // A new take supersedes any cancelled one whose final callback is still in
            // flight; the generation stamp keeps its stale segment out of this recording.
            self.recordingGeneration &+= 1
            self.discardSegmentsWhenFinalized = false
            self.pendingFinish = nil
            self.removeSegments()
            DispatchQueue.main.async {
                self.completedSegmentsSeconds = 0
                self.recordedSeconds = 0
                self.isRecording = true
                self.isPaused = false
                self.startDurationTimer()
            }
            self.beginSegment()
        }
    }

    func pauseRecording() {
        sessionQueue.async { [weak self] in
            guard let self, self.movieOutput.isRecording else { return }
            self.movieOutput.stopRecording()
            DispatchQueue.main.async {
                self.isPaused = true
                self.stopDurationTimer()
            }
        }
    }

    func resumeRecording() {
        sessionQueue.async { [weak self] in
            guard let self, !self.movieOutput.isRecording else { return }
            DispatchQueue.main.async {
                self.isPaused = false
                self.startDurationTimer()
            }
            self.beginSegment()
        }
    }

    /// Stops any live segment, stitches every segment into one file, and reports it.
    func finishRecording(completion: @escaping (KitCameraOutput?) -> Void) {
        DispatchQueue.main.async {
            self.isProcessing = true
            self.stopDurationTimer()
        }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.movieOutput.isRecording {
                self.pendingFinish = completion
                self.movieOutput.stopRecording()
            } else if !self.retainedSegmentDelegates.isEmpty {
                // A just-paused segment is still finalizing on disk; compose when it lands.
                self.pendingFinish = completion
            } else {
                self.composeSegments(completion: completion)
            }
        }
    }

    func cancelRecording() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.pendingFinish = nil
            if self.movieOutput.isRecording || !self.retainedSegmentDelegates.isEmpty {
                // Let the in-flight segment finalize, then delete everything at once so no
                // temp file is stranded on disk.
                self.discardSegmentsWhenFinalized = true
                if self.movieOutput.isRecording {
                    self.movieOutput.stopRecording()
                }
            } else {
                self.removeSegments()
            }
            DispatchQueue.main.async {
                self.isRecording = false
                self.isPaused = false
                self.isProcessing = false
                self.recordedSeconds = 0
                self.completedSegmentsSeconds = 0
                self.stopDurationTimer()
            }
        }
    }

    private func beginSegment() {
        let url: URL
        do {
            url = try KitCaptureTemporaryFileStore.makeFileURL(
                directoryPrefix: KitCaptureTemporaryFileStore.cameraDirectoryPrefix,
                fileName: "segment.mov"
            )
        } catch {
            DispatchQueue.main.async {
                self.isRecording = false
                self.isPaused = false
                self.isProcessing = false
                self.stopDurationTimer()
                self.errorMessage = "The video note could not be recorded securely."
            }
            return
        }
        let delegate = SegmentRecordingDelegate()
        let generation = recordingGeneration
        delegate.generation = generation
        delegate.completion = { [weak self, weak delegate] finishedURL, error in
            guard let self else { return }
            self.sessionQueue.async {
                if let delegate {
                    self.retainedSegmentDelegates.removeAll { $0 === delegate }
                }
                guard generation == self.recordingGeneration else {
                    // A superseded take's segment: its footage must not join the new one.
                    try? FileManager.default.removeItem(
                        at: finishedURL.deletingLastPathComponent()
                    )
                    return
                }
                if error == nil || FileManager.default.fileExists(atPath: finishedURL.path) {
                    do {
                        try KitCaptureTemporaryFileStore.protectFile(at: finishedURL)
                        self.segmentURLs.append(finishedURL)
                        let seconds = AVURLAsset(url: finishedURL).duration.seconds
                        if seconds.isFinite {
                            DispatchQueue.main.async {
                                self.completedSegmentsSeconds += seconds
                                self.recordedSeconds = self.completedSegmentsSeconds
                            }
                        }
                    } catch {
                        try? FileManager.default.removeItem(
                            at: finishedURL.deletingLastPathComponent()
                        )
                        DispatchQueue.main.async {
                            self.errorMessage = "The video note could not be protected securely."
                        }
                    }
                }
                // A late callback can land after a newer segment already started (fast
                // pause→resume); terminal transitions wait for the LAST outstanding segment
                // of THIS take (older takes' stragglers clean themselves up above).
                let anotherSegmentActive = self.movieOutput.isRecording
                    || self.retainedSegmentDelegates.contains { $0.generation == generation }
                if self.discardSegmentsWhenFinalized {
                    self.pendingFinish = nil
                    self.removeSegments()
                    if !anotherSegmentActive {
                        self.discardSegmentsWhenFinalized = false
                    }
                } else if !anotherSegmentActive, let completion = self.pendingFinish {
                    self.pendingFinish = nil
                    self.composeSegments(completion: completion)
                } else if !anotherSegmentActive, self.pendingFinish == nil {
                    // The output stopped on its own (for example maxRecordedDuration).
                    // Convert that into the normal paused state so the UI stays truthful.
                    DispatchQueue.main.async {
                        if self.isRecording, !self.isPaused {
                            self.isPaused = true
                            self.stopDurationTimer()
                        }
                    }
                }
            }
        }
        retainedSegmentDelegates.append(delegate)
        movieOutput.startRecording(to: url, recordingDelegate: delegate)
    }

    private func composeSegments(completion: @escaping (KitCameraOutput?) -> Void) {
        let urls = segmentURLs
        let finish: (KitCameraOutput?) -> Void = { output in
            DispatchQueue.main.async {
                self.isRecording = false
                self.isPaused = false
                self.isProcessing = false
                self.recordedSeconds = 0
                self.completedSegmentsSeconds = 0
                completion(output)
            }
        }
        guard !urls.isEmpty else {
            finish(nil)
            return
        }
        // One uninterrupted segment ships as-is when it already fits the transfer ceiling.
        if urls.count == 1,
           let size = try? urls[0].resourceValues(forKeys: [.fileSizeKey]).fileSize,
           KitChatMediaLimits.fits(size, kind: .video) {
            segmentURLs = []
            finish(.video(urls[0], mediaType: "video/quicktime"))
            return
        }
        Task { [weak self] in
            let output = await Self.exportComposition(of: urls)
            self?.sessionQueue.async {
                self?.removeSegments()
                finish(output)
            }
        }
    }

    private static func exportComposition(of urls: [URL]) async -> KitCameraOutput? {
        let composition = AVMutableComposition()
        let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )
        let audioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )
        var cursor = CMTime.zero
        var transform = CGAffineTransform.identity
        for url in urls {
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration) else { continue }
            let range = CMTimeRange(start: .zero, duration: duration)
            if let source = try? await asset.loadTracks(withMediaType: .video).first {
                if let sourceTransform = try? await source.load(.preferredTransform) {
                    transform = sourceTransform
                }
                try? videoTrack?.insertTimeRange(range, of: source, at: cursor)
            }
            if let source = try? await asset.loadTracks(withMediaType: .audio).first {
                try? audioTrack?.insertTimeRange(range, of: source, at: cursor)
            }
            cursor = CMTimeAdd(cursor, duration)
        }
        videoTrack?.preferredTransform = transform
        guard let export = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else { return nil }
        guard let outputURL = try? KitCaptureTemporaryFileStore.makeFileURL(
            directoryPrefix: KitCaptureTemporaryFileStore.cameraDirectoryPrefix,
            fileName: "clip.mp4"
        ) else { return nil }
        export.outputURL = outputURL
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        // Leave headroom under the plaintext ceiling for container overhead.
        export.fileLengthLimit = Int64(
            Double(SecureMediaAttachmentCipher.maximumPlaintextBytes) * 0.92
        )
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { continuation.resume() }
        }
        guard export.status == .completed,
              (try? KitCaptureTemporaryFileStore.protectFile(at: outputURL)) != nil
        else {
            try? FileManager.default.removeItem(at: outputURL.deletingLastPathComponent())
            return nil
        }
        return .video(outputURL, mediaType: "video/mp4")
    }

    private func removeSegments() {
        for url in segmentURLs {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        segmentURLs = []
    }

    // MARK: Flip / torch / focus / zoom

    func flipCamera() {
        sessionQueue.async { [weak self] in
            guard let self, !self.movieOutput.isRecording, let current = self.videoInput else {
                return
            }
            let newPosition: AVCaptureDevice.Position =
                current.device.position == .back ? .front : .back
            guard let camera = Self.camera(at: newPosition),
                  let input = try? AVCaptureDeviceInput(device: camera)
            else { return }
            self.session.beginConfiguration()
            self.session.removeInput(current)
            if self.session.canAddInput(input) {
                self.session.addInput(input)
                self.videoInput = input
            } else {
                self.session.addInput(current)
            }
            self.session.commitConfiguration()
            self.currentZoom = 1
            DispatchQueue.main.async {
                self.position = self.videoInput?.device.position ?? .back
                self.zoomFactor = 1
                self.torchActive = false
            }
        }
    }

    func toggleTorch() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let target = !(self.videoInput?.device.torchMode == .on)
            self.setTorch(enabled: target)
        }
    }

    private func setTorch(enabled: Bool) {
        guard let device = videoInput?.device, device.hasTorch, device.isTorchAvailable else {
            return
        }
        do {
            try device.lockForConfiguration()
            device.torchMode = enabled ? .on : .off
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.torchActive = enabled }
        } catch {
            // Torch is cosmetic; never surface a failure for it.
        }
    }

    /// `devicePoint` is in capture-device space (0...1), from
    /// `AVCaptureVideoPreviewLayer.captureDevicePointConverted(fromLayerPoint:)`.
    func focus(at devicePoint: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let device = self?.videoInput?.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = devicePoint
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = devicePoint
                    device.exposureMode = .autoExpose
                }
                device.unlockForConfiguration()
            } catch {
                // Focus is best-effort.
            }
        }
    }

    func setZoom(scale: CGFloat, ended: Bool) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoInput?.device else { return }
            let upperBound = min(
                Self.maximumZoomFactor,
                device.activeFormat.videoMaxZoomFactor
            )
            let target = max(1, min(self.currentZoom * scale, upperBound))
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = target
                device.unlockForConfiguration()
                if ended { self.currentZoom = target }
                DispatchQueue.main.async { self.zoomFactor = target }
            } catch {
                // Zoom is best-effort.
            }
        }
    }

    // MARK: Duration timer

    private func startDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) {
            [weak self] _ in
            guard let self else { return }
            let live = self.movieOutput.recordedDuration.seconds
            self.recordedSeconds =
                self.completedSegmentsSeconds + (live.isFinite ? live : 0)
            if self.recordedSeconds >= Self.maximumRecordingSeconds {
                self.pauseRecording()
            }
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }
}

// MARK: - Capture delegates

private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (KitCameraOutput?) -> Void

    init(completion: @escaping (KitCameraOutput?) -> Void) {
        self.completion = completion
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data)
        else {
            completion(nil)
            return
        }
        let mediaType = Self.mediaType(for: data)
        let fileExtension = SecureMediaLocalFilePolicy.fileExtension(for: mediaType)
        do {
            let url = try KitCaptureTemporaryFileStore.makeFileURL(
                directoryPrefix: KitCaptureTemporaryFileStore.cameraDirectoryPrefix,
                fileName: "photo.\(fileExtension)"
            )
            do {
                try data.write(to: url, options: .atomic)
                try KitCaptureTemporaryFileStore.protectFile(at: url)
                completion(.photo(fileURL: url, mediaType: mediaType, preview: image))
            } catch {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                throw error
            }
        } catch {
            completion(nil)
        }
    }

    private static func mediaType(for data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source) as String?,
              let mediaType = UTType(identifier)?.preferredMIMEType?.lowercased(),
              mediaType.hasPrefix("image/")
        else { return "image/jpeg" }
        return mediaType
    }
}

private final class SegmentRecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate {
    /// Assigned after init so the closure can capture the delegate itself weakly (the
    /// controller retains it in `retainedSegmentDelegates` until this fires).
    var completion: ((URL, Error?) -> Void)?
    /// Which take this segment belongs to; a superseded take's segment is discarded.
    var generation = 0

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        // Hitting maxRecordedDuration reports an error alongside a perfectly usable file;
        // the controller checks the file on disk before deciding.
        completion?(outputFileURL, error)
    }
}
