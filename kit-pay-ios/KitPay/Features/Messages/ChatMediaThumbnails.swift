import AVFoundation
import ImageIO
import UIKit

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
              let image = Self.decodeImageThumbnail(data: bytes, maxPixel: maxPixel)
        else { return nil }
        store(image, forKey: key, maxPixel: maxPixel)
        return image
    }

    // MARK: Video poster thumbnails

    /// Poster frame from locally available plaintext only. The bytes are staged in a
    /// file-protected temp file for the duration of the generation and removed immediately.
    /// The `mediaType` default keeps the documented three-argument call shape usable; pass the
    /// descriptor's media type when it is not MP4 so the temp file gets a decodable extension.
    func videoThumbnail(
        forKey key: String,
        maxPixel: CGFloat,
        from data: Data?,
        mediaType: String = "video/mp4"
    ) async -> UIImage? {
        if let cached = cachedThumbnail(forKey: key, maxPixel: maxPixel) {
            return cached
        }
        guard let data,
              let url = try? ChatMediaTempFiles.writeTemporaryFile(
                  data: data,
                  mediaType: mediaType
              )
        else { return nil }
        defer { ChatMediaTempFiles.removeTemporaryFile(url) }
        let pixelEdge = Self.pixelSize(forMaxPixel: maxPixel)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: pixelEdge, height: pixelEdge)
        guard let cgImage = try? await generator.image(
            at: CMTime(seconds: 0.1, preferredTimescale: 600)
        ).image else { return nil }
        let image = UIImage(cgImage: cgImage)
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

    private static func decodeImageThumbnail(data: Data, maxPixel: CGFloat) -> UIImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            sourceOptions as CFDictionary
        ) else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(pixelSize(forMaxPixel: maxPixel)),
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
