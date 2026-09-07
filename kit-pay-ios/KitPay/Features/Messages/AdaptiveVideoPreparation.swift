import AVFoundation
import Foundation

/// Normal chat video has a bounded upload representation. Files explicitly selected through
/// the document picker keep their exact bytes; a small or efficient clip needs no extra export.
enum AdaptiveVideoPreparationPolicy {
    static let minimumOptimizationBytes = 12 * 1_024 * 1_024
    static let maximumEfficientBitsPerSecond: Double = 8_000_000
    static let maximumLongEdge: Double = 1_920
    static let maximumShortEdge: Double = 1_080
    static let exportTimeoutNanoseconds: UInt64 = 300_000_000_000

    struct Metadata: Equatable, Sendable {
        let width: Double
        let height: Double
        let estimatedBitsPerSecond: Double
        let duration: TimeInterval
        let videoStart: TimeInterval
        let videoEnd: TimeInterval
        let hasAudio: Bool

        var isValid: Bool {
            width.isFinite && height.isFinite && width > 0 && height > 0
                && estimatedBitsPerSecond.isFinite && estimatedBitsPerSecond >= 0
                && duration.isFinite && duration > 0
                && videoStart.isFinite && videoEnd.isFinite
                && videoStart >= 0 && videoEnd > videoStart
                && abs(videoStart) <= AdaptiveVideoPreparationPolicy.durationTolerance(duration)
                && abs(videoEnd - duration) <= AdaptiveVideoPreparationPolicy.durationTolerance(duration)
        }
    }

    static func shouldOptimize(byteCount: Int, metadata: Metadata, preserveOriginal: Bool = false) -> Bool {
        guard !preserveOriginal, byteCount > minimumOptimizationBytes,
              KitChatMediaLimits.fits(byteCount, kind: .video), metadata.isValid
        else { return false }
        return max(metadata.width, metadata.height) > maximumLongEdge
            || min(metadata.width, metadata.height) > maximumShortEdge
            || metadata.estimatedBitsPerSecond > maximumEfficientBitsPerSecond
    }

    static func durationTolerance(_ duration: TimeInterval) -> TimeInterval {
        // Permit normal frame/timebase rounding, but never a percentage-sized missing tail.
        min(0.25, max(0.1, duration * 0.001))
    }

    static func outputMatches(
        _ metadata: Metadata, sourceDuration: TimeInterval, sourceHasAudio: Bool
    ) -> Bool {
        guard metadata.isValid, sourceDuration.isFinite, sourceDuration > 0 else { return false }
        return max(metadata.width, metadata.height) <= maximumLongEdge
            && min(metadata.width, metadata.height) <= maximumShortEdge
            && abs(metadata.duration - sourceDuration) <= durationTolerance(sourceDuration)
            && metadata.hasAudio == sourceHasAudio
    }

    static func sourceCopyMatches(
        _ metadata: Metadata, sourceDuration: TimeInterval, sourceHasAudio: Bool,
        sourceWidth: Double, sourceHeight: Double
    ) -> Bool {
        metadata.isValid && sourceDuration.isFinite && sourceDuration > 0
            && abs(metadata.duration - sourceDuration) <= durationTolerance(sourceDuration)
            && metadata.hasAudio == sourceHasAudio
            && abs(metadata.width - sourceWidth) < 0.5 && abs(metadata.height - sourceHeight) < 0.5
    }
}

enum AdaptiveVideoPreparation {
    typealias Metadata = AdaptiveVideoPreparationPolicy.Metadata
    private static let sourceMediaTypes: Set<String> = ["video/mp4", "video/quicktime"]

    /// Resolve only track metadata after the source is protected. Encoding begins later, after
    /// the same source/output identities have been committed to the durable message/outbox.
    static func plan(sourceURL: URL, mediaType: String, byteCount: Int) async -> Metadata? {
        guard sourceMediaTypes.contains(mediaType),
              byteCount > AdaptiveVideoPreparationPolicy.minimumOptimizationBytes,
              KitChatMediaLimits.fits(byteCount, kind: .video),
              (try? verifiedByteCount(sourceURL)) == byteCount,
              let metadata = try? await metadata(at: sourceURL),
              AdaptiveVideoPreparationPolicy.shouldOptimize(byteCount: byteCount, metadata: metadata)
        else { return nil }
        return metadata
    }

    static func job(
        sourceURL: URL, source: LocalMediaOriginalSource, outputStorageKey: String
    ) async throws -> LocalMediaPreprocessingJob {
        guard source.isStructurallyValid, let duration = source.duration,
              let metadata = await plan(sourceURL: sourceURL, mediaType: source.mediaType,
                                        byteCount: source.fileSize),
              abs(metadata.duration - duration) <= AdaptiveVideoPreparationPolicy.durationTolerance(duration)
        else { throw SecureMediaAttachmentError.invalidMedia }
        let job = LocalMediaPreprocessingJob(
            kind: .video1080p, sources: [source], outputStorageKey: outputStorageKey,
            outputMediaType: source.mediaType, videoSourceHasAudio: metadata.hasAudio,
            videoSourceWidth: metadata.width, videoSourceHeight: metadata.height
        )
        guard job.isStructurallyValid else { throw SecureMediaAttachmentError.invalidMedia }
        return job
    }

    static func optimize(sourceURL: URL, job: LocalMediaPreprocessingJob) async throws -> URL {
        guard job.kind == .video1080p, job.isStructurallyValid,
              let source = job.sources.first,
              let duration = source.duration,
              let sourceHasAudio = job.videoSourceHasAudio,
              let sourceWidth = job.videoSourceWidth, let sourceHeight = job.videoSourceHeight,
              try verifiedByteCount(sourceURL) == source.fileSize,
              AdaptiveVideoPreparationPolicy.sourceCopyMatches(
                  try await metadata(at: sourceURL), sourceDuration: duration,
                  sourceHasAudio: sourceHasAudio, sourceWidth: sourceWidth, sourceHeight: sourceHeight
              )
        else { throw SecureMediaAttachmentError.invalidMedia }
        try Task.checkCancellation()
        do {
            let candidate = try await exportCandidate(sourceURL: sourceURL, job: job)
            if (try? verifiedByteCount(candidate)).map({ $0 < source.fileSize }) == true,
               await isValidPublishedOutput(at: candidate, for: job) {
                return candidate
            }
            try? FileManager.default.removeItem(at: candidate.deletingLastPathComponent())
        } catch {
            // Cancellation still respects logout/account changes. A codec failure or timeout
            // must not strand a source that was already valid for ordinary chat transmission.
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
        let fallback = try KitCaptureTemporaryFileStore.makeFileURL(
            directoryPrefix: KitCaptureTemporaryFileStore.editorDirectoryPrefix,
            fileName: source.mediaType == "video/quicktime" ? "original.mov" : "original.mp4"
        )
        do {
            // Never return or move the original: the caller owns and retires this scratch copy
            // after importing it under the job's immutable output key.
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.copyItem(at: sourceURL, to: fallback)
                try KitCaptureTemporaryFileStore.protectFile(at: fallback)
            }.value
            try Task.checkCancellation()
            guard await isValidPublishedOutput(at: fallback, for: job) else {
                throw SecureMediaAttachmentError.invalidMedia
            }
            return fallback
        } catch {
            try? FileManager.default.removeItem(at: fallback.deletingLastPathComponent())
            throw error
        }
    }

    private static func exportCandidate(sourceURL: URL, job: LocalMediaPreprocessingJob) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        let fileType: AVFileType = job.outputMediaType == "video/quicktime" ? .mov : .mp4
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1920x1080),
              export.supportedFileTypes.contains(fileType)
        else { throw SecureMediaAttachmentError.invalidMedia }
        let outputURL = try KitCaptureTemporaryFileStore.makeFileURL(
            directoryPrefix: KitCaptureTemporaryFileStore.editorDirectoryPrefix,
            fileName: fileType == .mov ? "optimized.mov" : "optimized.mp4"
        )
        var completed = false
        defer {
            if !completed { try? FileManager.default.removeItem(at: outputURL.deletingLastPathComponent()) }
        }
        export.outputURL = outputURL
        export.outputFileType = fileType
        export.shouldOptimizeForNetworkUse = true
        // A fileLengthLimit may finish with a shortened movie. Export the full range and reject
        // an oversized result afterward; the durable protected source remains available to retry.
        export.timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        let cancellation = AdaptiveVideoExportCancellation(export)
        let timeout = Task {
            do {
                try await Task.sleep(nanoseconds: AdaptiveVideoPreparationPolicy.exportTimeoutNanoseconds)
                cancellation.cancel(timedOut: true)
            } catch { }
        }
        defer { timeout.cancel() }
        await withTaskCancellationHandler {
            await cancellation.run()
        } onCancel: {
            cancellation.cancel(timedOut: false)
        }
        try Task.checkCancellation()
        if cancellation.didTimeOut { throw URLError(.timedOut) }
        guard export.status == .completed else {
            throw export.error ?? SecureMediaAttachmentError.invalidMedia
        }
        try KitCaptureTemporaryFileStore.protectFile(at: outputURL)
        completed = true
        return outputURL
    }

    static func isValidPublishedOutput(at fileURL: URL, for job: LocalMediaPreprocessingJob) async -> Bool {
        guard job.kind == .video1080p, job.isStructurallyValid,
              let source = job.sources.first, let sourceDuration = source.duration,
              let sourceHasAudio = job.videoSourceHasAudio,
              let sourceWidth = job.videoSourceWidth, let sourceHeight = job.videoSourceHeight,
              let byteCount = try? verifiedByteCount(fileURL),
              KitChatMediaLimits.fits(byteCount, kind: .video)
        else { return false }
        let hasMPEG4Container = await Task.detached(priority: .userInitiated) {
            guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return false }
            defer { try? handle.close() }
            guard let header = try? handle.read(upToCount: 8), header.count == 8 else { return false }
            let atom = String(decoding: header[4..<8], as: UTF8.self)
            if atom == "ftyp" { return true }
            // Older, valid QuickTime originals can begin with a movie/media or padding atom.
            // AVFoundation still validates the complete track/duration metadata below.
            return job.outputMediaType == "video/quicktime"
                && ["wide", "mdat", "moov", "free", "skip", "pnot"].contains(atom)
        }.value
        guard hasMPEG4Container, let metadata = try? await metadata(at: fileURL) else { return false }
        if byteCount == source.fileSize {
            return AdaptiveVideoPreparationPolicy.sourceCopyMatches(
                metadata, sourceDuration: sourceDuration, sourceHasAudio: sourceHasAudio,
                sourceWidth: sourceWidth, sourceHeight: sourceHeight
            )
        }
        guard byteCount < source.fileSize else { return false }
        return AdaptiveVideoPreparationPolicy.outputMatches(
            metadata, sourceDuration: sourceDuration, sourceHasAudio: sourceHasAudio
        )
    }

    private static func verifiedByteCount(_ fileURL: URL) throws -> Int {
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let byteCount = values.fileSize, byteCount > 0
        else { throw SecureMediaAttachmentError.invalidMedia }
        return byteCount
    }

    private static func metadata(at fileURL: URL) async throws -> Metadata {
        let asset = AVURLAsset(url: fileURL)
        async let playable = asset.load(.isPlayable)
        async let assetDuration = asset.load(.duration)
        async let videoTracks = asset.loadTracks(withMediaType: .video)
        async let audioTracks = asset.loadTracks(withMediaType: .audio)
        let (isPlayable, duration, videos, audios) = try await (playable, assetDuration, videoTracks, audioTracks)
        guard isPlayable, videos.count == 1, let track = videos.first else {
            throw SecureMediaAttachmentError.invalidMedia
        }
        async let naturalSize = track.load(.naturalSize)
        async let preferredTransform = track.load(.preferredTransform)
        async let estimatedDataRate = track.load(.estimatedDataRate)
        async let timeRange = track.load(.timeRange)
        let (size, transform, dataRate, range) = try await (naturalSize, preferredTransform, estimatedDataRate, timeRange)
        let bounds = CGRect(origin: .zero, size: size).applying(transform)
        let metadata = Metadata(width: Double(abs(bounds.width)), height: Double(abs(bounds.height)),
                                estimatedBitsPerSecond: Double(dataRate), duration: duration.seconds,
                                videoStart: range.start.seconds, videoEnd: CMTimeRangeGetEnd(range).seconds,
                                hasAudio: !audios.isEmpty)
        guard metadata.isValid else { throw SecureMediaAttachmentError.invalidMedia }
        return metadata
    }
}

private final class AdaptiveVideoExportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private let export: AVAssetExportSession
    private var timedOut = false
    private var cancelled = false
    init(_ export: AVAssetExportSession) { self.export = export }
    var didTimeOut: Bool { lock.withLock { timedOut } }
    func run() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.withLock {
                guard !cancelled else { continuation.resume(); return }
                export.exportAsynchronously { continuation.resume() }
            }
        }
    }
    func cancel(timedOut: Bool) {
        lock.withLock { self.timedOut = self.timedOut || timedOut; cancelled = true }
        export.cancelExport()
    }
}
