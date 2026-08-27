import Foundation

/// Classifies an end-to-end encrypted attachment by its wire MIME type.
///
/// The v1 `KITMEDIA1` descriptor deliberately carries no dedicated kind field, so the MIME type
/// in `mt` is the single cross-platform source of truth for how a bubble should render.
enum KitChatMediaKind: String, Codable, CaseIterable, Sendable {
    case image
    case voice
    case video
    case document

    init(mediaType: String) {
        let normalized = mediaType.lowercased()
        if normalized.hasPrefix("image/") {
            self = .image
        } else if normalized.hasPrefix("audio/") {
            self = .voice
        } else if normalized.hasPrefix("video/") {
            self = .video
        } else {
            self = .document
        }
    }

    var symbolName: String {
        switch self {
        case .image: "photo.fill"
        case .voice: "mic.fill"
        case .video: "video.fill"
        case .document: "doc.fill"
        }
    }

    var previewLabel: String {
        switch self {
        case .image: "Photo"
        case .voice: "Voice note"
        case .video: "Video"
        case .document: "Document"
        }
    }
}

/// Client-side limits for encrypted chat media. The cipher and wire caps in
/// `SecureMessagingWire` are the hard bound; these values keep each media kind
/// inside that bound with kind-appropriate ceilings.
enum KitChatMediaLimits {
    /// Hard per-file transfer cap shared by every media kind (matches the attachment cipher).
    static let maximumTransferBytes = SecureMediaAttachmentCipher.maximumPlaintextBytes

    /// Images are re-encoded before send, so they stay small for cheap offline history.
    static let imageEncodeTargetBytes = 10 * 1_024 * 1_024

    /// Plaintext blobs at or under this size may live inside the encrypted state file for
    /// instant offline access. Anything larger goes to the encrypted media file cache so a
    /// wallet-balance update never rewrites hundreds of megabytes.
    static let maximumInlineCacheBytes = 4 * 1_024 * 1_024

    static let maximumTransferLabel = "200 MB"

    static func fits(_ byteCount: Int, kind _: KitChatMediaKind) -> Bool {
        byteCount > 0 && byteCount <= maximumTransferBytes
    }

    static func shouldCacheInline(byteCount: Int) -> Bool {
        byteCount > 0 && byteCount <= maximumInlineCacheBytes
    }
}

/// One-line conversation-list preview for any message body, including media descriptors.
enum KitChatMessagePreview {
    static func text(for body: String) -> String {
        guard let media = KitMediaMessageDescriptor.parse(body) else { return body }
        let kind = KitChatMediaKind(mediaType: media.mediaType)
        if let caption = media.caption, !caption.isEmpty {
            return "\(kind.previewLabel) · \(caption)"
        }
        return kind.previewLabel
    }

    static func symbolName(for body: String) -> String? {
        guard let media = KitMediaMessageDescriptor.parse(body) else { return nil }
        return KitChatMediaKind(mediaType: media.mediaType).symbolName
    }
}

/// Ordering and selection policy for the chats list: pinned conversations first
/// (most recent activity first within each group).
enum ConversationListPolicy {
    static func ordered(
        _ conversations: [Conversation],
        pinnedIds: Set<String>
    ) -> [Conversation] {
        conversations.sorted { first, second in
            let firstPinned = pinnedIds.contains(first.id)
            let secondPinned = pinnedIds.contains(second.id)
            if firstPinned != secondPinned { return firstPinned }
            if first.updatedAt != second.updatedAt { return first.updatedAt > second.updatedAt }
            return first.id < second.id
        }
    }

    static func togglingMembership(_ id: String, in ids: [String]?) -> [String] {
        var set = ids ?? []
        if let index = set.firstIndex(of: id) {
            set.remove(at: index)
        } else {
            set.append(id)
        }
        return set
    }
}
