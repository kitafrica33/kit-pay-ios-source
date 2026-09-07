import Foundation

/// Media/container metadata can be finite without fitting Swift's integer range. Formatting
/// must never trap while a received clip, trim editor or voice note is being displayed.
enum ChatMediaPlaybackClock {
    static func label(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0,
              let seconds = Int(exactly: interval.rounded())
        else { return "--:--" }
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}

/// Client-side limits for encrypted chat media. The cipher and wire caps in
/// `SecureMessagingWire` are the hard bound; these values keep each media kind
/// inside that bound with kind-appropriate ceilings.
enum KitChatMediaLimits {
    /// Hard per-file transfer cap shared by every media kind (matches the attachment cipher).
    static let maximumTransferBytes = SecureMediaAttachmentCipher.maximumPlaintextBytes

    /// Images are re-encoded before send, so they stay small for cheap offline history.
    static let imageEncodeTargetBytes = 2 * 1_024 * 1_024

    /// Plaintext blobs at or under this size may live inside the encrypted state file for
    /// instant offline access. Anything larger goes to the encrypted media file cache so a
    /// wallet-balance update never rewrites hundreds of megabytes.
    static let maximumInlineCacheBytes = 4 * 1_024 * 1_024

    static let maximumTransferLabel = "200 MB"

    /// A local video may temporarily exceed the wire ceiling while the user trims it. Keeping
    /// that source app-owned and protected preserves local-first editing; only the resulting clip
    /// may enter a message/outbox record and it must still satisfy `maximumTransferBytes`.
    static let maximumEditableLocalVideoBytes = 1_073_741_824

    static func fits(_ byteCount: Int, kind _: KitChatMediaKind) -> Bool {
        byteCount > 0 && byteCount <= maximumTransferBytes
    }

    static func fitsLocalOriginal(byteCount: Int, mediaType: String) -> Bool {
        if mediaType.lowercased().hasPrefix("video/") {
            return byteCount > 0 && byteCount <= maximumEditableLocalVideoBytes
        }
        return fits(byteCount, kind: KitChatMediaKind(mediaType: mediaType))
    }

    static func shouldCacheInline(byteCount: Int) -> Bool {
        byteCount > 0 && byteCount <= maximumInlineCacheBytes
    }
}
