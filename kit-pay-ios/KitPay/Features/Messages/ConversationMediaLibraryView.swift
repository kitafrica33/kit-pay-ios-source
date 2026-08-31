import AVFoundation
import ImageIO
import SwiftUI
import UIKit

// MARK: - Item + section models

/// One browsable media *item*: a whole KITMEDIA1 message, or one attachment of a KITMEDIA2
/// message — which remains one logical chat message; only this library indexes it per item
/// (§8: every visual v2 item is addressable by (message ID, item index)).
///
/// Rows carry identity and display facts only, never descriptor text: a descriptor holds
/// attachment key material, so loads re-read the persisted row by identity instead.
private struct ConversationMediaItem: Identifiable {
    let messageID: UUID
    let conversationID: String
    let senderID: String
    let direction: LocalMediaRecord.Direction
    let createdAt: Date
    /// Display-order index within a multi-attachment message; nil for a KITMEDIA1 message.
    let itemIndex: Int?
    let kind: KitChatMediaKind
    let mediaType: String
    let plaintextByteSize: Int
    /// KITMEDIA1 whole-message caption (a lone document's filename travels here). A v2
    /// message's one shared caption belongs to the message, not to any single item, so v2
    /// rows leave this nil and title themselves by kind.
    let caption: String?
    /// Thumbnail-cache identity only — a public storage name, never key material, and never
    /// used to fetch directly. Content-bound: a replaced row gets a new key.
    let storageKey: String
    /// Voice-note playback identity: the message ID for v1, the item's attachment UUID for
    /// v2 — same convention as the in-bubble batch rows, so the floating player and this
    /// list always agree on which note is playing.
    let playbackID: UUID

    var id: String {
        itemIndex.map { "\(messageID.uuidString):\($0)" } ?? messageID.uuidString
    }

    var byteLabel: String { ChatMediaBytes.label(plaintextByteSize) }

    var dateLabel: String {
        createdAt.formatted(date: .abbreviated, time: .omitted)
    }
}

private struct MediaMonthSection: Identifiable {
    let id: String
    let title: String
    var items: [ConversationMediaItem]
}

private enum MediaLibraryCategory: String, CaseIterable, Identifiable {
    case photos = "Photos"
    case videos = "Videos"
    case audio = "Audio"
    case documents = "Documents"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .photos: KitChatMediaKind.image.symbolName
        case .videos: KitChatMediaKind.video.symbolName
        case .audio: KitChatMediaKind.audio.symbolName
        case .documents: KitChatMediaKind.document.symbolName
        }
    }

    func includes(_ kind: KitChatMediaKind) -> Bool {
        switch self {
        case .photos: kind == .image
        case .videos: kind == .video
        case .audio: kind == .voice || kind == .audio
        case .documents: kind == .document
        }
    }

    var emptyTitle: String {
        switch self {
        case .photos: "No photos"
        case .videos: "No videos"
        case .audio: "No audio"
        case .documents: "No documents"
        }
    }

    var emptyDescription: String {
        switch self {
        case .photos: "Photos shared in this chat will appear here."
        case .videos: "Videos shared in this chat will appear here."
        case .audio: "Voice notes and audio shared in this chat will appear here."
        case .documents: "Documents shared in this chat will appear here."
        }
    }
}

private enum MediaLibraryDirectionFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case sent = "Sent"
    case received = "Received"

    var id: String { rawValue }

    func includes(_ direction: LocalMediaRecord.Direction) -> Bool {
        switch self {
        case .all: true
        case .sent: direction == .sent
        case .received: direction == .received
        }
    }
}

// MARK: - Private thumbnail cache

/// Grid-sized thumbnails only. Deliberately private to this feature so it stays decoupled from
/// any shared thumbnail store owned by other workstreams.
@MainActor
private final class ConversationMediaThumbnailCache {
    static let shared = ConversationMediaThumbnailCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 500
    }

    func image(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func insert(_ image: UIImage, forKey key: String) {
        cache.setObject(image, forKey: key as NSString)
    }
}

private enum ConversationMediaThumbnailFactory {
    /// Downscaled decode straight from the compressed bytes; never inflates the full-size image.
    static func imageThumbnail(data: Data, maxPixel: CGFloat) -> UIImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            sourceOptions as CFDictionary
        ) else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel.rounded(.up)),
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// Poster frame from locally available plaintext only. The bytes are staged in a
    /// file-protected temp file for the duration of the generation and removed immediately.
    static func videoThumbnail(
        data: Data,
        mediaType: String,
        maxPixel: CGFloat
    ) async -> UIImage? {
        guard let url = try? ChatMediaTempFiles.writeTemporaryFile(
            data: data,
            mediaType: mediaType
        ) else { return nil }
        defer { ChatMediaTempFiles.removeTemporaryFile(url) }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        guard let cgImage = try? await generator.image(
            at: .init(seconds: 0.1, preferredTimescale: 600)
        ).image else { return nil }
        return UIImage(cgImage: cgImage)
    }

    static func videoThumbnail(fileURL: URL, maxPixel: CGFloat) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: fileURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        guard let cgImage = try? await generator.image(
            at: .init(seconds: 0.1, preferredTimescale: 600)
        ).image else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - Media library

/// "Media, audio & documents" browser for one conversation.
struct ConversationMediaLibraryView: View {
    let conversationID: String
    let conversationTitle: String
    /// Called when the user picks a photo/video so the presenter can open the shared gallery
    /// on exactly the tapped item: the message plus, for a multi-attachment message, the item
    /// index within it (nil for a single-attachment message).
    let openGallery: (_ tappedMessageID: UUID, _ itemIndex: Int?) -> Void

    @EnvironmentObject private var model: AppModel
    @State private var selectedCategory: MediaLibraryCategory = .photos
    @State private var selectedDirection: MediaLibraryDirectionFilter = .all

    private static let gridSpacing: CGFloat = 2
    private static let horizontalPadding: CGFloat = 16

    var body: some View {
        GeometryReader { proxy in
            let cellEdge = Self.cellEdge(containerWidth: proxy.size.width)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                    summaryHeader
                    directionPicker
                    categoryChips
                    categoryContent(cellEdge: cellEdge)
                }
                .padding(.horizontal, Self.horizontalPadding)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
        }
        .background(KitColor.canvas.ignoresSafeArea())
        .navigationTitle("Media & documents")
        .navigationBarTitleDisplayMode(.inline)
    }

    static func cellEdge(containerWidth: CGFloat) -> CGFloat {
        let usable = containerWidth - horizontalPadding * 2 - gridSpacing * 2
        return max(44, (usable / 3).rounded(.down))
    }

    // MARK: Source of truth

    /// Conversation IDs may arrive in mixed case from different backends; both sides are reduced
    /// to the canonical lowercase UUID string before comparing.
    private static func canonicalConversationID(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return UUID(uuidString: trimmed)?.uuidString.lowercased() ?? trimmed.lowercased()
    }

    /// All browsable media items of this conversation, newest message first. A KITMEDIA1
    /// message contributes one item; a sealed KITMEDIA2 message contributes one per attachment
    /// in display order — still one logical chat message, indexed per item only here (§8).
    /// Pending sends index their permanent client ids immediately, so Sent Media is useful while
    /// offline and before upload. A family body that fails strict parsing indexes nothing:
    /// nothing here ever reads or exposes raw descriptor text.
    private var mediaItems: [ConversationMediaItem] {
        let target = Self.canonicalConversationID(conversationID)
        return model.state.messages
            .flatMap { message -> [ConversationMediaItem] in
                guard Self.canonicalConversationID(message.conversationId) == target else {
                    return []
                }
                let direction: LocalMediaRecord.Direction = message.isOutgoing ? .sent : .received
                if let pending = message.pendingAttachment {
                    guard message.isOutgoing,
                          let size = pending.byteCount ?? message.attachmentData?.count,
                          let record = message.localMediaRecords?.first(where: {
                              $0.direction == .sent
                                  && $0.mediaType == pending.mediaType
                                  && $0.fileSize == size
                                  && $0.isStructurallyValid
                          })
                    else { return [] }
                    return [ConversationMediaItem(
                        messageID: message.id,
                        conversationID: message.conversationId,
                        senderID: message.senderId,
                        direction: .sent,
                        createdAt: message.createdAt,
                        itemIndex: nil,
                        kind: KitChatMediaKind(mediaType: pending.mediaType),
                        mediaType: pending.mediaType,
                        plaintextByteSize: size,
                        caption: pending.caption,
                        storageKey: record.id,
                        playbackID: UUID(uuidString: record.id) ?? message.id
                    )]
                }
                if let batch = message.pendingMediaBatch {
                    guard message.isOutgoing, batch.isStructurallyValid else { return [] }
                    return batch.items.enumerated().map { index, item in
                        ConversationMediaItem(
                            messageID: message.id,
                            conversationID: message.conversationId,
                            senderID: message.senderId,
                            direction: .sent,
                            createdAt: message.createdAt,
                            itemIndex: index,
                            kind: KitChatMediaKind(mediaType: item.mediaType),
                            mediaType: item.mediaType,
                            plaintextByteSize: item.plaintextByteSize,
                            caption: nil,
                            storageKey: item.attachmentID,
                            playbackID: UUID(uuidString: item.attachmentID) ?? message.id
                        )
                    }
                }
                if let descriptor = KitMediaMessageDescriptor.parse(message.body) {
                    return [ConversationMediaItem(
                        messageID: message.id,
                        conversationID: message.conversationId,
                        senderID: message.senderId,
                        direction: direction,
                        createdAt: message.createdAt,
                        itemIndex: nil,
                        kind: KitChatMediaKind(mediaType: descriptor.mediaType),
                        mediaType: descriptor.mediaType,
                        plaintextByteSize: descriptor.plaintextByteSize,
                        caption: descriptor.caption,
                        storageKey: descriptor.storageKey,
                        playbackID: message.id
                    )]
                }
                if let descriptor = KitMediaMessageV2Descriptor.parse(message.body) {
                    return descriptor.items.enumerated().map { index, item in
                        ConversationMediaItem(
                            messageID: message.id,
                            conversationID: message.conversationId,
                            senderID: message.senderId,
                            direction: direction,
                            createdAt: message.createdAt,
                            itemIndex: index,
                            kind: KitChatMediaKind(mediaType: item.mediaType),
                            mediaType: item.mediaType,
                            plaintextByteSize: item.plaintextByteSize,
                            caption: nil,
                            storageKey: item.storageKey,
                            playbackID: UUID(uuidString: item.attachmentID) ?? message.id
                        )
                    }
                }
                return []
            }
            .sorted {
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt > $1.createdAt
                }
                // Same-date order is deterministic: message identity first, then the batch's
                // own display order within one message.
                if $0.messageID != $1.messageID {
                    return $0.messageID.uuidString > $1.messageID.uuidString
                }
                return ($0.itemIndex ?? 0) < ($1.itemIndex ?? 0)
            }
    }

    private func items(for category: MediaLibraryCategory) -> [ConversationMediaItem] {
        mediaItems.filter {
            category.includes($0.kind) && selectedDirection.includes($0.direction)
        }
    }

    // MARK: Summary

    private var summaryHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(conversationTitle)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(KitColor.secondaryText)
                .lineLimit(1)
            Text(summaryLine)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(KitColor.primaryText)
        }
        .accessibilityElement(children: .combine)
    }

    private var summaryLine: String {
        let all = mediaItems.filter { selectedDirection.includes($0.direction) }
        func label(_ count: Int, _ singular: String, _ plural: String) -> String {
            "\(count) \(count == 1 ? singular : plural)"
        }
        let photoCount = all.lazy.filter { $0.kind == .image }.count
        let videoCount = all.lazy.filter { $0.kind == .video }.count
        let audioCount = all.lazy.filter { $0.kind == .voice || $0.kind == .audio }.count
        let documentCount = all.lazy.filter { $0.kind == .document }.count
        return [
            label(photoCount, "photo", "photos"),
            label(videoCount, "video", "videos"),
            label(audioCount, "audio item", "audio items"),
            label(documentCount, "document", "documents"),
        ].joined(separator: " · ")
    }

    private var directionPicker: some View {
        Picker("Media direction", selection: $selectedDirection) {
            ForEach(MediaLibraryDirectionFilter.allCases) { direction in
                Text(direction.rawValue).tag(direction)
            }
        }
        .pickerStyle(.segmented)
    }

    // MARK: Category chips (match the chats-list filter chips)

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MediaLibraryCategory.allCases) { category in
                    let selected = selectedCategory == category
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { selectedCategory = category }
                    } label: {
                        Text(category.rawValue)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(selected ? KitColor.navy : KitColor.secondaryText)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background {
                                if selected {
                                    Capsule().fill(KitColor.paleGreen)
                                }
                            }
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay {
                                Capsule()
                                    .stroke(
                                        .white.opacity(selected ? 0.75 : 0.5),
                                        lineWidth: 0.7
                                    )
                                    .allowsHitTesting(false)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(category.rawValue)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: Content per category

    @ViewBuilder
    private func categoryContent(cellEdge: CGFloat) -> some View {
        let items = items(for: selectedCategory)
        if items.isEmpty {
            emptyState(for: selectedCategory)
        } else {
            switch selectedCategory {
            case .photos, .videos:
                mediaGrid(items: items, cellEdge: cellEdge)
            case .audio:
                LazyVStack(spacing: 10) {
                    ForEach(items) { item in
                        MediaLibraryAudioRow(item: item)
                    }
                }
            case .documents:
                LazyVStack(spacing: 10) {
                    ForEach(items) { item in
                        MediaLibraryDocumentRow(item: item)
                    }
                }
            }
        }
    }

    private func emptyState(for category: MediaLibraryCategory) -> some View {
        ContentUnavailableView(
            category.emptyTitle,
            systemImage: category.symbolName,
            description: Text(category.emptyDescription)
        )
        .frame(maxWidth: .infinity)
        .padding(.top, 44)
    }

    @ViewBuilder
    private func mediaGrid(items: [ConversationMediaItem], cellEdge: CGFloat) -> some View {
        let columns = Array(
            repeating: GridItem(.fixed(cellEdge), spacing: Self.gridSpacing),
            count: 3
        )
        ForEach(monthSections(for: items)) { section in
            Section {
                LazyVGrid(columns: columns, alignment: .leading, spacing: Self.gridSpacing) {
                    ForEach(section.items) { item in
                        MediaLibraryGridCell(
                            item: item,
                            edge: cellEdge,
                            openGallery: openGallery
                        )
                    }
                }
            } header: {
                monthHeader(section.title)
            }
        }
    }

    private func monthHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(KitColor.primaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
            Spacer()
        }
        .padding(.vertical, 4)
        .accessibilityAddTraits(.isHeader)
    }

    /// Items arrive newest first, so contiguous runs share a month and one pass suffices.
    private func monthSections(for items: [ConversationMediaItem]) -> [MediaMonthSection] {
        var sections: [MediaMonthSection] = []
        let calendar = Calendar.current
        for item in items {
            let components = calendar.dateComponents([.year, .month], from: item.createdAt)
            let key = "\(components.year ?? 0)-\(components.month ?? 0)"
            if let lastIndex = sections.indices.last, sections[lastIndex].id == key {
                sections[lastIndex].items.append(item)
            } else {
                sections.append(
                    MediaMonthSection(
                        id: key,
                        title: item.createdAt.formatted(.dateTime.month(.wide).year()),
                        items: [item]
                    )
                )
            }
        }
        return sections
    }
}

// MARK: - Grid cell (photos + videos)

private struct MediaLibraryGridCell: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.displayScale) private var displayScale

    let item: ConversationMediaItem
    let edge: CGFloat
    let openGallery: (UUID, Int?) -> Void

    @State private var thumbnail: UIImage?
    @State private var isLoading = false
    @State private var didFail = false

    private var isVideo: Bool { item.kind == .video }

    private var maxPixel: CGFloat { edge * displayScale }

    private var cacheKey: String {
        "\(item.storageKey):\(Int(maxPixel.rounded(.up)))"
    }

    var body: some View {
        Button(action: handleTap) {
            ZStack {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: edge, height: edge)
                        .clipped()
                } else {
                    placeholder
                }
                if isVideo {
                    playBadge
                }
                if isLoading {
                    Color.black.opacity(0.18)
                    ProgressView()
                        .tint(.white)
                }
            }
            .frame(width: edge, height: edge)
            .clipped()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
        .task(id: "\(item.messageID):\(cacheKey)") {
            await prepareThumbnail()
        }
    }

    private var placeholder: some View {
        ZStack {
            Rectangle()
                .fill(KitColor.paleGreen.opacity(0.35))
            VStack(spacing: 5) {
                Image(systemName: didFail ? "arrow.clockwise" : placeholderSymbol)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(KitColor.green)
                Text(didFail ? "Retry" : item.byteLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(KitColor.secondaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
        }
    }

    private var placeholderSymbol: String {
        if isVideo { return "video.fill" }
        return model.isOnline ? "photo.badge.arrow.down" : "photo.fill"
    }

    private var playBadge: some View {
        Image(systemName: "play.circle.fill")
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(.white, .black.opacity(0.45))
            .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
            .allowsHitTesting(false)
    }

    private var accessibilityText: String {
        let kindLabel = item.kind.previewLabel
        if thumbnail != nil { return "\(kindLabel), \(item.dateLabel)" }
        if didFail { return "\(kindLabel), download failed, double tap to retry" }
        return "\(kindLabel), \(item.byteLabel), not downloaded"
    }

    private func handleTap() {
        // Videos always open the shared gallery, which owns download and playback.
        if isVideo {
            openGallery(item.messageID, item.itemIndex)
            return
        }
        if thumbnail != nil {
            openGallery(item.messageID, item.itemIndex)
            return
        }
        guard !isLoading else { return }
        Task { await downloadAndDecode() }
    }

    /// Passive appear-work: a fresh local-only identity resolution of the persisted row first —
    /// nothing, including a cache hit under this content-bound key, is shown for a row that no
    /// longer resolves for this account — then a thumbnail from exactly the resolved bytes.
    /// Never downloads; a v2 item or large v1 media without local bytes stays a placeholder.
    private func prepareThumbnail() async {
        guard thumbnail == nil else { return }
        if isVideo,
           let localFile = await model.loadProtectedLocalMediaFile(
               messageID: item.messageID,
               conversationId: item.conversationID,
               itemIndex: item.itemIndex
           ) {
            if let cached = ConversationMediaThumbnailCache.shared.image(forKey: cacheKey) {
                thumbnail = cached
                return
            }
            if let image = await ConversationMediaThumbnailFactory.videoThumbnail(
                fileURL: localFile.url,
                maxPixel: maxPixel
            ) {
                ConversationMediaThumbnailCache.shared.insert(image, forKey: cacheKey)
                thumbnail = image
            }
            return
        }
        guard let loaded = try? await model.loadSecureMediaItem(
            messageID: item.messageID,
            conversationId: item.conversationID,
            itemIndex: item.itemIndex,
            allowsDownload: false
        ) else { return }
        if let cached = ConversationMediaThumbnailCache.shared.image(forKey: cacheKey) {
            thumbnail = cached
            return
        }
        await decodeThumbnail(from: loaded)
    }

    /// User-triggered download of an image cell: one fresh authoritative resolution, with the
    /// decode facts bound to that same result rather than list-build-time fields.
    private func downloadAndDecode() async {
        isLoading = true
        didFail = false
        defer { isLoading = false }
        do {
            let loaded = try await model.loadSecureMediaItem(
                messageID: item.messageID,
                conversationId: item.conversationID,
                itemIndex: item.itemIndex
            )
            await decodeThumbnail(from: loaded)
            if thumbnail == nil { didFail = true }
        } catch {
            didFail = true
        }
    }

    private func decodeThumbnail(from loaded: SecureMediaLoadPolicy.LoadedItem) async {
        let pixel = maxPixel
        let image: UIImage?
        if KitChatMediaKind(mediaType: loaded.mediaType) == .video {
            if let localFileURL = loaded.localFileURL {
                image = await ConversationMediaThumbnailFactory.videoThumbnail(
                    fileURL: localFileURL,
                    maxPixel: pixel
                )
            } else {
                image = await ConversationMediaThumbnailFactory.videoThumbnail(
                    data: loaded.data,
                    mediaType: loaded.mediaType,
                    maxPixel: pixel
                )
            }
        } else {
            let data = loaded.data
            image = await Task.detached(priority: .utility) {
                ConversationMediaThumbnailFactory.imageThumbnail(data: data, maxPixel: pixel)
            }.value
        }
        guard let image else { return }
        ConversationMediaThumbnailCache.shared.insert(image, forKey: cacheKey)
        thumbnail = image
    }
}

// MARK: - Audio row

private struct MediaLibraryAudioRow: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.voiceNoteChatContext) private var chatContext
    @ObservedObject private var player = VoiceNotePlayer.shared

    let item: ConversationMediaItem

    /// Bytes and facts of this row's own fresh identity resolution, kept only for the row's
    /// lifetime so the play/pause affordance reflects that the note is locally decryptable.
    @State private var loaded: SecureMediaLoadPolicy.LoadedItem?
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var isCurrent: Bool { player.playingID == item.playbackID }
    private var isPlaying: Bool { isCurrent && !player.isPaused }

    private var title: String {
        item.caption?.isEmpty == false ? item.caption! : "Voice note"
    }

    var body: some View {
        HStack(spacing: 12) {
            actionButton
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KitColor.primaryText)
                    .lineLimit(1)
                if isCurrent {
                    ProgressView(value: min(max(player.progress, 0), 1))
                        .tint(KitColor.green)
                }
                Text(detailLine)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(errorMessage == nil ? KitColor.secondaryText : .orange)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .kitGlass(cornerRadius: 18, shadow: false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(item.byteLabel), \(item.dateLabel)")
        // While this row is on screen it is the control for its own note; the floating bar only
        // takes over once the note is playing somewhere the user can no longer reach it.
        .onAppear { player.noteSourceVisibility(true, for: item.playbackID) }
        .onDisappear { player.noteSourceVisibility(false, for: item.playbackID) }
    }

    private var actionButton: some View {
        Button(action: handleTap) {
            Group {
                if isLoading {
                    ProgressView().tint(.white)
                } else if loaded != nil {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: errorMessage == nil
                        ? "arrow.down.circle.fill"
                        : "arrow.clockwise")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 44, height: 44)
            .background(KitColor.green, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .accessibilityLabel(
            loaded == nil
                ? "Download audio"
                : (isPlaying ? "Pause audio" : "Play audio")
        )
    }

    private var detailLine: String {
        if let errorMessage { return errorMessage }
        if isLoading { return "Downloading…" }
        if isCurrent, player.duration > 0 {
            let remaining = max(0, player.duration * (1 - player.progress))
            let seconds = Int(remaining.rounded())
            return String(format: "%d:%02d left · %@", seconds / 60, seconds % 60, item.byteLabel)
        }
        return "\(item.byteLabel) · \(item.dateLabel)"
    }

    private func handleTap() {
        guard !isLoading else { return }
        Task { await refreshThenToggle() }
    }

    /// Every tap is a presentation: re-resolve the persisted row and hand the player exactly
    /// that fresh result. A note that no longer resolves stops playing instead of continuing
    /// from stale bytes.
    private func refreshThenToggle() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            if item.itemIndex == nil,
               let playback = await model.loadPendingVoicePlayback(
                   messageID: item.messageID,
                   conversationId: item.conversationID
               ) {
                player.toggle(
                    fileURLs: playback.fileURLs,
                    segmentDurations: playback.segmentDurations,
                    id: item.playbackID,
                    context: chatContext.playbackContext(senderUserID: item.senderID)
                )
                return
            }
            if let localFile = await model.loadProtectedLocalMediaFile(
                messageID: item.messageID,
                conversationId: item.conversationID,
                itemIndex: item.itemIndex
            ) {
                let fresh = SecureMediaLoadPolicy.LoadedItem(localFile: localFile)
                loaded = fresh
                player.toggle(
                    fileURL: localFile.url,
                    id: item.playbackID,
                    context: chatContext.playbackContext(senderUserID: item.senderID),
                    protectedOriginalLease: localFile.accessLease
                )
                return
            }
            let fresh = try await model.loadSecureMediaItem(
                messageID: item.messageID,
                conversationId: item.conversationID,
                itemIndex: item.itemIndex
            )
            loaded = fresh
            if let fileURL = fresh.localFileURL {
                player.toggle(
                    fileURL: fileURL,
                    id: item.playbackID,
                    context: chatContext.playbackContext(senderUserID: item.senderID),
                    protectedOriginalLease: fresh.localFileLease
                )
            } else {
                player.toggle(
                    data: fresh.data,
                    id: item.playbackID,
                    context: chatContext.playbackContext(senderUserID: item.senderID)
                )
            }
        } catch {
            loaded = nil
            if player.playingID == item.playbackID { player.stop() }
            errorMessage = model.isOnline ? "Couldn't play. Tap to retry." : "Available when online"
        }
    }
}

// MARK: - Document row

private struct PresentedDocumentFile: Identifiable {
    let id = UUID()
    let url: URL
    /// The same fresh resolution that produced the file: the viewer's display facts must come
    /// from it, never from fields captured when the list was built.
    let loaded: SecureMediaLoadPolicy.LoadedItem
    let ownsTemporaryFile: Bool
}

private struct MediaLibraryDocumentRow: View {
    @EnvironmentObject private var model: AppModel

    let item: ConversationMediaItem

    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var presented: PresentedDocumentFile?

    /// v1 carries a lone document's filename in its caption; a v2 item has no per-item
    /// filename, so it names itself by position — "Document 2" — exactly as its bubble row does.
    /// List display only; the presented viewer names itself from its own fresh resolution.
    private var fileName: String {
        if let itemIndex = item.itemIndex {
            return "\(item.kind.previewLabel) \(itemIndex + 1)"
        }
        return item.caption?.isEmpty == false ? item.caption! : "Document"
    }

    /// Viewer/temp-file name bound to the fresh resolution's facts, mirroring the in-bubble
    /// conventions: v2 items title by kind and position, v1 by caption or a typed fallback.
    private static func presentedFileName(
        itemIndex: Int?,
        loaded: SecureMediaLoadPolicy.LoadedItem
    ) -> String {
        if let itemIndex {
            return "\(KitChatMediaKind(mediaType: loaded.mediaType).previewLabel) \(itemIndex + 1)"
        }
        if let caption = loaded.caption, !caption.isEmpty { return caption }
        return "Document.\(ChatMediaTempFiles.fileExtension(forMediaType: loaded.mediaType))"
    }

    private var typeLabel: String {
        ChatMediaTempFiles.fileExtension(forMediaType: item.mediaType).uppercased()
    }

    var body: some View {
        Button {
            guard !isLoading else { return }
            Task { await open() }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(KitColor.paleGreen.opacity(0.55))
                        .frame(width: 44, height: 44)
                    if isLoading {
                        ProgressView().tint(KitColor.green)
                    } else {
                        Image(systemName: "doc.fill")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(KitColor.green)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(fileName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(KitColor.primaryText)
                        .lineLimit(1)
                    Text(detailLine)
                        .font(.caption)
                        .foregroundStyle(errorMessage == nil ? KitColor.secondaryText : .orange)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(KitColor.secondaryText)
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .kitGlass(cornerRadius: 18, shadow: false)
        .disabled(isLoading)
        .accessibilityLabel("Document, \(fileName), \(typeLabel), \(item.byteLabel), \(item.dateLabel)")
        .fullScreenCover(item: $presented) { file in
            KitDocumentViewerView(
                fileURL: file.url,
                displayName: Self.presentedFileName(itemIndex: item.itemIndex, loaded: file.loaded),
                mediaType: file.loaded.mediaType,
                byteCount: file.loaded.byteCount,
                onClose: { close() }
            )
        }
    }

    private var detailLine: String {
        if let errorMessage { return errorMessage }
        if isLoading { return "Decrypting…" }
        return "\(typeLabel) · \(item.byteLabel) · \(item.dateLabel)"
    }

    /// Every open is a presentation: one fresh authoritative resolution, with the temp file and
    /// viewer facts bound to exactly that result.
    private func open() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            if let localFile = await model.loadProtectedLocalMediaFile(
                messageID: item.messageID,
                conversationId: item.conversationID,
                itemIndex: item.itemIndex
            ) {
                present(SecureMediaLoadPolicy.LoadedItem(localFile: localFile))
                return
            }
            let fresh = try await model.loadSecureMediaItem(
                messageID: item.messageID,
                conversationId: item.conversationID,
                itemIndex: item.itemIndex
            )
            present(fresh)
        } catch {
            errorMessage = model.isOnline ? "Couldn't open. Tap to retry." : "Available when online"
        }
    }

    private func present(_ fresh: SecureMediaLoadPolicy.LoadedItem) {
        guard presented == nil else { return }
        do {
            if let localFileURL = fresh.localFileURL {
                presented = PresentedDocumentFile(
                    url: localFileURL,
                    loaded: fresh,
                    ownsTemporaryFile: false
                )
            } else {
                let url = try ChatMediaTempFiles.writeTemporaryFile(
                    data: fresh.data,
                    mediaType: fresh.mediaType,
                    suggestedName: Self.presentedFileName(itemIndex: item.itemIndex, loaded: fresh)
                )
                presented = PresentedDocumentFile(
                    url: url,
                    loaded: fresh,
                    ownsTemporaryFile: true
                )
            }
        } catch {
            errorMessage = "Couldn't open. Tap to retry."
        }
    }

    private func close() {
        if presented?.ownsTemporaryFile == true {
            ChatMediaTempFiles.removeTemporaryFile(presented?.url)
        }
        presented = nil
    }
}
