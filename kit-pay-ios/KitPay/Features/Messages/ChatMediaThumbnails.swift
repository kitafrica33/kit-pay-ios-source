import AVFoundation
import ImageIO
import UIKit

/// The only boundary that creates video poster frames. Poster extraction has the same container
/// and completeness requirements as playback: in particular, Android providers can supply
/// QuickTime bytes while declaring `video/mp4`. Preparing first gives AVFoundation a canonical
/// `.mov` hard link and keeps that alias alive until generation has completely finished.
@MainActor
enum ChatVideoPosterGenerator {
    typealias ImageGeneration = (AVURLAsset, CGSize) async throws -> CGImage

    struct PlaybackClaim: Equatable, Sendable {
        fileprivate let id: UUID
        fileprivate let contentKey: String
    }

    private struct RequestKey: Hashable {
        let contentKey: String
        let declaredMediaType: String
        let expectedByteCount: Int
        let pixelWidth: Int
        let pixelHeight: Int
    }

    private struct InFlightRequest {
        let id: UUID
        let task: Task<UIImage?, Never>
    }

    private static var inFlight: [RequestKey: InFlightRequest] = [:]
    private static var playbackClaims: [String: Set<UUID>] = [:]

    /// Playback and passive poster decoding for the same bytes never overlap. Registering the
    /// claim first closes the race while cancelled poster work drains; callers retain the token
    /// until AVPlayer and all of its file-backed resources have been released.
    static func acquirePlayback(forKey contentKey: String) async -> PlaybackClaim? {
        guard !contentKey.isEmpty else { return nil }
        let claim = PlaybackClaim(id: UUID(), contentKey: contentKey)
        playbackClaims[contentKey, default: []].insert(claim.id)
        let posterTasks = inFlight.compactMap { key, request in
            key.contentKey == contentKey ? request.task : nil
        }
        posterTasks.forEach { $0.cancel() }
        for task in posterTasks { _ = await task.value }
        return claim
    }

    static func releasePlayback(_ claim: PlaybackClaim?) {
        guard let claim else { return }
        playbackClaims[claim.contentKey]?.remove(claim.id)
        if playbackClaims[claim.contentKey]?.isEmpty == true {
            playbackClaims.removeValue(forKey: claim.contentKey)
        }
    }

    static func hasInFlightPoster(forKey contentKey: String) -> Bool {
        inFlight.keys.contains { $0.contentKey == contentKey }
    }

    static func cancelPosters(forKey contentKey: String) {
        inFlight.forEach { key, request in
            if key.contentKey == contentKey { request.task.cancel() }
        }
    }

    static func thumbnail(
        forKey contentKey: String,
        data: Data?,
        declaredMediaType: String,
        expectedByteCount: Int,
        maximumSize: CGSize,
        generateImage: ImageGeneration? = nil
    ) async -> UIImage? {
        guard let key = requestKey(
            contentKey: contentKey,
            declaredMediaType: declaredMediaType,
            expectedByteCount: expectedByteCount,
            maximumSize: maximumSize
        ) else { return nil }
        return await resolve(key: key) {
            await generateThumbnail(
                data: data,
                declaredMediaType: declaredMediaType,
                expectedByteCount: expectedByteCount,
                maximumSize: maximumSize,
                generateImage: generateImage
            )
        }
    }

    static func thumbnail(
        forKey contentKey: String,
        fileURL: URL,
        declaredMediaType: String,
        expectedByteCount: Int,
        protectedOriginalLease: SecureMediaOriginalAccessLease?,
        maximumSize: CGSize,
        generateImage: ImageGeneration? = nil
    ) async -> UIImage? {
        guard let key = requestKey(
            contentKey: contentKey,
            declaredMediaType: declaredMediaType,
            expectedByteCount: expectedByteCount,
            maximumSize: maximumSize
        ) else { return nil }
        return await resolve(key: key) {
            let image = await generateThumbnail(
                fileURL: fileURL,
                declaredMediaType: declaredMediaType,
                expectedByteCount: expectedByteCount,
                maximumSize: maximumSize,
                generateImage: generateImage
            )
            // A protected receiver-cache source must remain outside eviction until preparation
            // has created its hard-link alias and AVFoundation has finished reading that alias.
            withExtendedLifetime(protectedOriginalLease) {}
            return image
        }
    }

    private static func generateThumbnail(
        data: Data?,
        declaredMediaType: String,
        expectedByteCount: Int,
        maximumSize: CGSize,
        generateImage: ImageGeneration?
    ) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        guard let data, data.count == expectedByteCount,
              let sourceURL = try? ChatMediaTempFiles.writeTemporaryFile(
                  data: data,
                  mediaType: declaredMediaType
              )
        else { return nil }
        defer { ChatMediaTempFiles.removeTemporaryFile(sourceURL) }
        return await generateThumbnail(
            fileURL: sourceURL,
            declaredMediaType: declaredMediaType,
            expectedByteCount: expectedByteCount,
            maximumSize: maximumSize,
            generateImage: generateImage
        )
    }

    private static func generateThumbnail(
        fileURL: URL,
        declaredMediaType: String,
        expectedByteCount: Int,
        maximumSize: CGSize,
        generateImage: ImageGeneration? = nil
    ) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        guard maximumSize.width > 0, maximumSize.height > 0 else { return nil }
        guard let prepared = try? await ChatVideoPlaybackAssetPolicy.prepare(
            fileURL: fileURL,
            declaredMediaType: declaredMediaType,
            expectedByteCount: expectedByteCount
        ) else { return nil }
        defer { prepared.playbackFileLease.release() }
        guard !Task.isCancelled else { return nil }

        do {
            let cgImage: CGImage
            if let generateImage {
                cgImage = try await generateImage(prepared.asset, maximumSize)
            } else {
                let generator = AVAssetImageGenerator(asset: prepared.asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = maximumSize
                cgImage = try await generator.image(
                    at: CMTime(seconds: 0.1, preferredTimescale: 600)
                ).image
            }
            return UIImage(cgImage: cgImage)
        } catch {
            return nil
        }
    }

    private static func requestKey(
        contentKey: String,
        declaredMediaType: String,
        expectedByteCount: Int,
        maximumSize: CGSize
    ) -> RequestKey? {
        guard !contentKey.isEmpty,
              expectedByteCount > 0,
              maximumSize.width.isFinite,
              maximumSize.height.isFinite,
              maximumSize.width > 0,
              maximumSize.height > 0
        else { return nil }
        return RequestKey(
            contentKey: contentKey,
            declaredMediaType: declaredMediaType.lowercased(),
            expectedByteCount: expectedByteCount,
            pixelWidth: Int(maximumSize.width.rounded(.up)),
            pixelHeight: Int(maximumSize.height.rounded(.up))
        )
    }

    /// SwiftUI appearance and tap tasks can overlap for the same received item. Share one
    /// decoder probe for an identical content/size request instead of doubling AVFoundation's
    /// transient buffers at the moment playback is being opened.
    private static func resolve(
        key: RequestKey,
        operation: @escaping () async -> UIImage?
    ) async -> UIImage? {
        guard playbackClaims[key.contentKey]?.isEmpty != false else { return nil }
        if let request = inFlight[key] {
            return await request.task.value
        }
        let id = UUID()
        let task = Task { await operation() }
        inFlight[key] = InFlightRequest(id: id, task: task)
        let image = await task.value
        if inFlight[key]?.id == id {
            inFlight.removeValue(forKey: key)
        }
        return image
    }
}

/// Bounded ImageIO decode shared by bubbles and the full-screen gallery. Compressed attachment
/// bytes may be close to the wire ceiling; `UIImage(data:)` can inflate an adversarially large
/// pixel surface even when the compressed file itself is modest. Every passive render therefore
/// asks ImageIO for an explicit pixel ceiling.
enum ChatMediaImageDecoder {
    static func downsample(data: Data, maximumPixelSize: Int) -> UIImage? {
        guard maximumPixelSize > 0 else { return nil }
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            sourceOptions as CFDictionary
        ) else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ) else { return nil }
        return UIImage(cgImage: image)
    }

    static func downsample(fileURL: URL, maximumPixelSize: Int) -> UIImage? {
        guard maximumPixelSize > 0 else { return nil }
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(
            fileURL as CFURL,
            sourceOptions as CFDictionary
        ) else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ) else { return nil }
        return UIImage(cgImage: image)
    }
}

extension SecureMediaLoadPolicy.LoadedItem {
    /// Decode a bounded display representation without first copying a protected original into
    /// one whole-file Data value. Inline/legacy encrypted blobs retain their existing data path.
    func downsampledImage(maximumPixelSize: Int) -> UIImage? {
        if let localFileURL {
            return ChatMediaImageDecoder.downsample(
                fileURL: localFileURL,
                maximumPixelSize: maximumPixelSize
            )
        }
        return ChatMediaImageDecoder.downsample(
            data: data,
            maximumPixelSize: maximumPixelSize
        )
    }
}

/// In-memory, size-capped thumbnail cache for chat media. Keyed by descriptor storage key +
/// pixel bucket. Never persists thumbnails to disk (plaintext stays in the encrypted caches).
@MainActor
final class ChatMediaThumbnailStore: ObservableObject {
    static let shared = ChatMediaThumbnailStore()

    /// ~64 MB of decoded pixels; each entry's cost is its pixel count * 4 bytes.
    private static let totalCostLimitBytes = 64 * 1_024 * 1_024

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.totalCostLimit = Self.totalCostLimitBytes
    }

    // MARK: Lookup / store

    func cachedThumbnail(forKey key: String, maxPixel: CGFloat) -> UIImage? {
        cache.object(forKey: Self.cacheKey(key, maxPixel: maxPixel))
    }

    func store(_ image: UIImage, forKey key: String, maxPixel: CGFloat) {
        cache.setObject(
            image,
            forKey: Self.cacheKey(key, maxPixel: maxPixel),
            cost: Self.cost(of: image)
        )
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    // MARK: Image thumbnails (synchronous downscaled decode)

    /// Returns the cached thumbnail if present; otherwise decodes a downscaled thumbnail straight
    /// from the compressed bytes (never inflating the full-size image), caches, and returns it.
    /// The data closure is only evaluated on a cache miss.
    func thumbnail(
        forKey key: String,
        maxPixel: CGFloat,
        from data: @autoclosure () -> Data?
    ) -> UIImage? {
        if let cached = cachedThumbnail(forKey: key, maxPixel: maxPixel) {
            return cached
        }
        guard let bytes = data(),
              let image = ChatMediaImageDecoder.downsample(
                  data: bytes,
                  maximumPixelSize: Int(Self.pixelSize(forMaxPixel: maxPixel))
              )
        else { return nil }
        store(image, forKey: key, maxPixel: maxPixel)
        return image
    }

    /// File-backed counterpart for a sender original or persisted receiver cache. ImageIO reads
    /// and downsamples from the URL directly, so an album cell never materializes the complete
    /// compressed photo merely to draw a thumbnail.
    func thumbnail(
        forKey key: String,
        maxPixel: CGFloat,
        fromFileURL url: URL
    ) -> UIImage? {
        if let cached = cachedThumbnail(forKey: key, maxPixel: maxPixel) {
            return cached
        }
        guard let image = ChatMediaImageDecoder.downsample(
            fileURL: url,
            maximumPixelSize: Int(Self.pixelSize(forMaxPixel: maxPixel))
        ) else {
            return nil
        }
        store(image, forKey: key, maxPixel: maxPixel)
        return image
    }

    // MARK: Video poster thumbnails

    /// Poster frame from locally available plaintext only. The shared generator validates the
    /// exact bytes and gives AVFoundation a container-canonical URL before extracting a frame.
    func videoThumbnail(
        forKey key: String,
        maxPixel: CGFloat,
        from data: Data?,
        mediaType: String,
        expectedByteCount: Int
    ) async -> UIImage? {
        if let cached = cachedThumbnail(forKey: key, maxPixel: maxPixel) {
            return cached
        }
        let pixelEdge = Self.pixelSize(forMaxPixel: maxPixel)
        guard let image = await ChatVideoPosterGenerator.thumbnail(
            forKey: key,
            data: data,
            declaredMediaType: mediaType,
            expectedByteCount: expectedByteCount,
            maximumSize: CGSize(width: pixelEdge, height: pixelEdge)
        ) else { return nil }
        store(image, forKey: key, maxPixel: maxPixel)
        return image
    }

    /// File-backed sender-original/receiver-cache variant. The authoritative MIME and byte count
    /// come from the same freshly resolved item as the URL; no whole-file `Data` is created.
    func videoThumbnail(
        forKey key: String,
        maxPixel: CGFloat,
        fromFileURL url: URL,
        mediaType: String,
        expectedByteCount: Int,
        protectedOriginalLease: SecureMediaOriginalAccessLease?
    ) async -> UIImage? {
        if let cached = cachedThumbnail(forKey: key, maxPixel: maxPixel) {
            return cached
        }
        let pixelEdge = Self.pixelSize(forMaxPixel: maxPixel)
        guard let image = await ChatVideoPosterGenerator.thumbnail(
            forKey: key,
            fileURL: url,
            declaredMediaType: mediaType,
            expectedByteCount: expectedByteCount,
            protectedOriginalLease: protectedOriginalLease,
            maximumSize: CGSize(width: pixelEdge, height: pixelEdge)
        ) else { return nil }
        store(image, forKey: key, maxPixel: maxPixel)
        return image
    }

    // MARK: Internals

    private static func cacheKey(_ key: String, maxPixel: CGFloat) -> NSString {
        "\(key)#\(Int(maxPixel.rounded(.up)))" as NSString
    }

    private static func cost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 1 }
        return cgImage.width * cgImage.height * 4
    }

    /// Requested pixel edge for a point size: display scale, capped at 3x.
    private static func pixelSize(forMaxPixel maxPixel: CGFloat) -> CGFloat {
        let scale = min(max(UIScreen.main.scale, 1), 3)
        return (maxPixel * scale).rounded(.up)
    }

}
