import Foundation
import OSLog

struct LocalMediaLatencyMeasurement: Equatable, Sendable {
    let captureToVisibleMilliseconds: Double?
    let captureToPlayableMilliseconds: Double?
    let captureToEncryptedMilliseconds: Double?
    let captureToServerAcceptedMilliseconds: Double?
    let recipientDescriptorToLocalMilliseconds: Double?

    init(
        captureToVisibleMilliseconds: Double? = nil,
        captureToPlayableMilliseconds: Double? = nil,
        captureToEncryptedMilliseconds: Double? = nil,
        captureToServerAcceptedMilliseconds: Double? = nil,
        recipientDescriptorToLocalMilliseconds: Double? = nil
    ) {
        self.captureToVisibleMilliseconds = captureToVisibleMilliseconds
        self.captureToPlayableMilliseconds = captureToPlayableMilliseconds
        self.captureToEncryptedMilliseconds = captureToEncryptedMilliseconds
        self.captureToServerAcceptedMilliseconds = captureToServerAcceptedMilliseconds
        self.recipientDescriptorToLocalMilliseconds = recipientDescriptorToLocalMilliseconds
    }

    static func milliseconds(from start: Date, to end: Date) -> Double {
        max(0, end.timeIntervalSince(start) * 1_000)
    }
}

/// Lightweight, privacy-safe timing for local availability and the independent background
/// encryption/upload/recipient-hydration milestones. IDs index in-memory state only; logs carry
/// durations and never a filename, media id, MIME payload, contact or content.
@MainActor
final class LocalMediaPerformanceMonitor {
    static let shared = LocalMediaPerformanceMonitor()
    private static let maximumTrackedItems = 256

    private struct Milestones {
        let capturedAt: Date
        var visibleAt: Date? = nil
        var playableAt: Date? = nil
        var encryptedAt: Date? = nil
        var serverAcceptedAt: Date? = nil
    }

    private let logger = Logger(subsystem: "africa.kit.pay.ios", category: "LocalFirstMedia")
    private var milestones: [UUID: Milestones] = [:]
    private var recipientDescriptorDates: [UUID: Date] = [:]

    func begin(mediaID: UUID, at date: Date = Date()) {
        guard milestones[mediaID] == nil else { return }
        if milestones.count >= Self.maximumTrackedItems,
           let oldest = milestones.min(by: {
               $0.value.capturedAt < $1.value.capturedAt
           })?.key {
            milestones.removeValue(forKey: oldest)
        }
        milestones[mediaID] = Milestones(capturedAt: date)
    }

    @discardableResult
    func markVisible(mediaID: UUID, at date: Date = Date()) -> LocalMediaLatencyMeasurement? {
        guard var value = milestones[mediaID] else { return nil }
        guard value.visibleAt == nil else { return measurement(value) }
        value.visibleAt = date
        milestones[mediaID] = value
        let result = measurement(value)
        if let milliseconds = result.captureToVisibleMilliseconds {
            logger.info("capture_to_visible_ms=\(milliseconds, privacy: .public)")
        }
        retireCompletedMeasurement(mediaID: mediaID, milestones: value)
        return result
    }

    @discardableResult
    func markPlayable(mediaID: UUID, at date: Date = Date()) -> LocalMediaLatencyMeasurement? {
        guard var value = milestones[mediaID] else { return nil }
        guard value.playableAt == nil else { return measurement(value) }
        value.playableAt = date
        milestones[mediaID] = value
        let result = measurement(value)
        if let milliseconds = result.captureToPlayableMilliseconds {
            logger.info("capture_to_playable_ms=\(milliseconds, privacy: .public)")
        }
        retireCompletedMeasurement(mediaID: mediaID, milestones: value)
        return result
    }

    @discardableResult
    func markEncrypted(mediaID: UUID, at date: Date = Date()) -> LocalMediaLatencyMeasurement? {
        guard var value = milestones[mediaID] else { return nil }
        if value.encryptedAt == nil {
            value.encryptedAt = date
            milestones[mediaID] = value
        }
        let result = measurement(value)
        if let milliseconds = result.captureToEncryptedMilliseconds {
            logger.info("capture_to_encrypted_ms=\(milliseconds, privacy: .public)")
        }
        return result
    }

    @discardableResult
    func markServerAccepted(
        mediaID: UUID,
        at date: Date = Date()
    ) -> LocalMediaLatencyMeasurement? {
        guard var value = milestones[mediaID] else { return nil }
        if value.serverAcceptedAt == nil {
            value.serverAcceptedAt = date
            milestones[mediaID] = value
        }
        let result = measurement(value)
        if let milliseconds = result.captureToServerAcceptedMilliseconds {
            logger.info("capture_to_server_accepted_ms=\(milliseconds, privacy: .public)")
        }
        retireCompletedMeasurement(mediaID: mediaID, milestones: value)
        return result
    }

    /// A very fast local/LAN upload may receive server acceptance before SwiftUI mounts the
    /// staged bubble. Keep that sample until the two local-first milestones have also arrived;
    /// the global 256-entry bound still retires abandoned measurements deterministically.
    private func retireCompletedMeasurement(mediaID: UUID, milestones value: Milestones) {
        guard value.visibleAt != nil,
              value.playableAt != nil,
              value.serverAcceptedAt != nil
        else { return }
        milestones.removeValue(forKey: mediaID)
    }

    func beginRecipientHydration(mediaID: UUID, descriptorObservedAt: Date = Date()) {
        recipientDescriptorDates[mediaID] = min(
            recipientDescriptorDates[mediaID] ?? descriptorObservedAt,
            descriptorObservedAt
        )
        if recipientDescriptorDates.count > Self.maximumTrackedItems,
           let oldest = recipientDescriptorDates.min(by: { $0.value < $1.value })?.key {
            recipientDescriptorDates.removeValue(forKey: oldest)
        }
    }

    @discardableResult
    func markRecipientHydrated(
        mediaID: UUID,
        at date: Date = Date()
    ) -> LocalMediaLatencyMeasurement? {
        guard let observedAt = recipientDescriptorDates.removeValue(forKey: mediaID) else {
            return nil
        }
        let milliseconds = LocalMediaLatencyMeasurement.milliseconds(
            from: observedAt,
            to: date
        )
        logger.info("recipient_descriptor_to_local_ms=\(milliseconds, privacy: .public)")
        return LocalMediaLatencyMeasurement(
            recipientDescriptorToLocalMilliseconds: milliseconds
        )
    }

    private func measurement(_ value: Milestones) -> LocalMediaLatencyMeasurement {
        LocalMediaLatencyMeasurement(
            captureToVisibleMilliseconds: value.visibleAt.map {
                LocalMediaLatencyMeasurement.milliseconds(from: value.capturedAt, to: $0)
            },
            captureToPlayableMilliseconds: value.playableAt.map {
                LocalMediaLatencyMeasurement.milliseconds(from: value.capturedAt, to: $0)
            },
            captureToEncryptedMilliseconds: value.encryptedAt.map {
                LocalMediaLatencyMeasurement.milliseconds(from: value.capturedAt, to: $0)
            },
            captureToServerAcceptedMilliseconds: value.serverAcceptedAt.map {
                LocalMediaLatencyMeasurement.milliseconds(from: value.capturedAt, to: $0)
            },
            recipientDescriptorToLocalMilliseconds: nil
        )
    }
}

/// Classifies an end-to-end encrypted attachment by its wire MIME type.
///
/// The v1 `KITMEDIA1` descriptor deliberately carries no dedicated kind field, so the MIME type
/// in `mt` is the single cross-platform source of truth for how a bubble should render.
enum KitChatMediaKind: String, Codable, CaseIterable, Sendable {
    case image
    case voice
    case audio
    case video
    case document

    init(mediaType: String) {
        let normalized = mediaType.lowercased()
        if normalized.hasPrefix("image/") {
            self = .image
        } else if normalized == "audio/mp4" {
            // Kit voice notes are recorded and assembled as canonical M4A. Other supported audio
            // MIME types are imported files and must not be presented as microphone recordings.
            self = .voice
        } else if normalized.hasPrefix("audio/") {
            self = .audio
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
        case .audio: "music.note"
        case .video: "video.fill"
        case .document: "doc.fill"
        }
    }

    var previewLabel: String {
        switch self {
        case .image: "Photo"
        case .voice: "Voice note"
        case .audio: "Audio"
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

/// Family-wide safe projection of a message body for every presentation surface: bubbles,
/// list previews, reply quotes, scheduled previews, accessibility labels, copy, and search.
///
/// This is the single place that decides what a `KITMEDIA` body may show. Raw reserved-family
/// text is never returned from any method here — a descriptor carries attachment key material,
/// so an unparseable or future-version family body renders only as the generic placeholder,
/// and the only user-visible prose a valid descriptor contributes is its caption. All of it is
/// feature-flag independent (§4 rule 6): receive-side safety never consults a capability.
enum KitMediaMessageFamilyPresentation {
    /// §4 rule 6 placeholder for any reserved-family body this build cannot strictly parse.
    static let genericAttachmentLabel = "Attachment"

    /// How a body may render. Exactly one case applies; `confinedPlaceholder` is terminal —
    /// callers must show `genericAttachmentLabel` and expose nothing else of the body.
    enum BodyContent {
        case text(String)
        case mediaV1(KitMediaMessageDescriptor)
        case mediaV2(KitMediaMessageV2Descriptor)
        case confinedPlaceholder
    }

    static func content(for body: String) -> BodyContent {
        if let v2 = KitMediaMessageV2Descriptor.parse(body) { return .mediaV2(v2) }
        if let v1 = KitMediaMessageDescriptor.parse(body) { return .mediaV1(v1) }
        if KitMediaMessageFamilyPolicy.isReservedFamilyText(body) { return .confinedPlaceholder }
        return .text(body)
    }

    /// One safe label for an ordered batch: "3 Photos" when every item shares a kind,
    /// "4 Attachments" for a mixed batch. §4 keeps `n` in 2…8, so the plural always reads.
    static func summaryLabel(forMediaTypes mediaTypes: [String]) -> String {
        let kinds = Set(mediaTypes.map { KitChatMediaKind(mediaType: $0) })
        guard mediaTypes.count > 1 else {
            return kinds.first?.previewLabel ?? genericAttachmentLabel
        }
        if kinds.count == 1, let kind = kinds.first {
            return "\(mediaTypes.count) \(kind.previewLabel)s"
        }
        return "\(mediaTypes.count) \(genericAttachmentLabel)s"
    }

    static func summaryLabel(for descriptor: KitMediaMessageV2Descriptor) -> String {
        summaryLabel(forMediaTypes: descriptor.items.map(\.mediaType))
    }

    /// §8 reply-quote label for an ordered batch: the first item's kind leads, the rest ride as
    /// a count, and a validated caption follows as garnish — "Video +1 · Family photos", matching
    /// Android's mediaAlbumQuoteLabel. The caption rides byte-exact: a validated v2 caption is
    /// canonical by construction (nil/non-nil is the whole test), and the contract's boundary
    /// rule deliberately admits scalars — NBSP, U+0085, U+2028/U+2029 — that Foundation trims
    /// would mutate or drop.
    static func mediaAlbumQuoteLabel(forMediaTypes mediaTypes: [String], caption: String?) -> String {
        let lead = mediaTypes.first.map { KitChatMediaKind(mediaType: $0).previewLabel }
            ?? genericAttachmentLabel
        let label = mediaTypes.count > 1 ? "\(lead) +\(mediaTypes.count - 1)" : lead
        guard let caption else { return label }
        return "\(label) · \(caption)"
    }

    /// One-line preview: media bodies read label-first with the caption as garnish; ordinary
    /// text reads verbatim; confined bodies read as the bare placeholder.
    static func previewText(for body: String) -> String {
        switch content(for: body) {
        case .text(let text):
            return text
        case .mediaV1(let media):
            let label = KitChatMediaKind(mediaType: media.mediaType).previewLabel
            if let caption = media.caption, !caption.isEmpty { return "\(label) · \(caption)" }
            return label
        case .mediaV2(let media):
            let label = summaryLabel(for: media)
            if let caption = media.caption, !caption.isEmpty { return "\(label) · \(caption)" }
            return label
        case .confinedPlaceholder:
            return genericAttachmentLabel
        }
    }

    /// The only text of a media body that may leave the bubble — reach the pasteboard, match
    /// in-chat search, or seed a share — is a valid descriptor's caption. Ordinary text passes
    /// through; a family body without a parseable caption yields nil, never the raw body.
    static func safeUserText(for body: String) -> String? {
        switch content(for: body) {
        case .text(let text):
            return text
        case .mediaV1(let media):
            return media.caption?.isEmpty == false ? media.caption : nil
        case .mediaV2(let media):
            return media.caption?.isEmpty == false ? media.caption : nil
        case .confinedPlaceholder:
            return nil
        }
    }
}

/// One-line conversation-list preview for any message body, including media descriptors.
enum KitChatMessagePreview {
    static func text(for body: String) -> String {
        KitMediaMessageFamilyPresentation.previewText(for: body)
    }

    static func symbolName(for body: String) -> String? {
        switch KitMediaMessageFamilyPresentation.content(for: body) {
        case .text:
            return nil
        case .mediaV1(let media):
            return KitChatMediaKind(mediaType: media.mediaType).symbolName
        case .mediaV2(let media):
            let kinds = Set(media.items.map { KitChatMediaKind(mediaType: $0.mediaType) })
            if kinds.count == 1, let kind = kinds.first { return kind.symbolName }
            return "paperclip"
        case .confinedPlaceholder:
            return "paperclip"
        }
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
