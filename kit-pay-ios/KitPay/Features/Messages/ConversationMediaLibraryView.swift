import AVFoundation
import ImageIO
import SwiftUI
import UIKit

// MARK: - Item + section models

/// One media message in the conversation, pre-parsed so grid/list rows never re-parse bodies.
private struct ConversationMediaItem: Identifiable {
    let message: LocalMessage
    let descriptor: KitMediaMessageDescriptor
    let kind: KitChatMediaKind

    var id: UUID { message.id }

    var byteLabel: String { ChatMediaBytes.label(descriptor.plaintextByteSize) }

    var dateLabel: String {
        message.createdAt.formatted(date: .abbreviated, time: .omitted)
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

    var kind: KitChatMediaKind {
        switch self {
        case .photos: .image
        case .videos: .video
        case .audio: .voice
        case .documents: .document
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
}

// MARK: - Media library

/// "Media, audio & documents" browser for one conversation.
struct ConversationMediaLibraryView: View {
    let conversationID: String
    let conversationTitle: String
    /// Called when the user picks a photo/video so the presenter can open the shared gallery.
    /// Items are chronological visual media for this conversation; second arg = tapped message ID.
    let openGallery: (_ tappedMessageID: UUID) -> Void

    @EnvironmentObject private var model: AppModel
    @State private var selectedCategory: MediaLibraryCategory = .photos

    private static let gridSpacing: CGFloat = 2
    private static let horizontalPadding: CGFloat = 16

    var body: some View {
        GeometryReader { proxy in
            let cellEdge = Self.cellEdge(containerWidth: proxy.size.width)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                    summaryHeader
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

    /// All media messages of this conversation, newest first for browsing.
    private var mediaItems: [ConversationMediaItem] {
        let target = Self.canonicalConversationID(conversationID)
        return model.state.messages
            .compactMap { message -> ConversationMediaItem? in
                guard Self.canonicalConversationID(message.conversationId) == target,
                      let descriptor = KitMediaMessageDescriptor.parse(message.body)
                else { return nil }
                return ConversationMediaItem(
                    message: message,
                    descriptor: descriptor,
                    kind: KitChatMediaKind(mediaType: descriptor.mediaType)
                )
            }
            .sorted {
                if $0.message.createdAt != $1.message.createdAt {
                    return $0.message.createdAt > $1.message.createdAt
                }
                return $0.message.id.uuidString > $1.message.id.uuidString
            }
    }

    private func items(for category: MediaLibraryCategory) -> [ConversationMediaItem] {
        mediaItems.filter { $0.kind == category.kind }
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
        let all = mediaItems
        func count(_ kind: KitChatMediaKind) -> Int {
            all.lazy.filter { $0.kind == kind }.count
        }
        func label(_ count: Int, _ singular: String, _ plural: String) -> String {
            "\(count) \(count == 1 ? singular : plural)"
        }
        return [
            label(count(.image), "photo", "photos"),
            label(count(.video), "video", "videos"),
            label(count(.voice), "voice note", "voice notes"),
            label(count(.document), "document", "documents"),
        ].joined(separator: " · ")
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
            systemImage: category.kind.symbolName,
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
            let components = calendar.dateComponents([.year, .month], from: item.message.createdAt)
            let key = "\(components.year ?? 0)-\(components.month ?? 0)"
            if let lastIndex = sections.indices.last, sections[lastIndex].id == key {
                sections[lastIndex].items.append(item)
            } else {
                sections.append(
                    MediaMonthSection(
                        id: key,
                        title: item.message.createdAt.formatted(.dateTime.month(.wide).year()),
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
    let openGallery: (UUID) -> Void

    @State private var thumbnail: UIImage?
    @State private var isLoading = false
    @State private var didFail = false

    private var isVideo: Bool { item.kind == .video }

    private var maxPixel: CGFloat { edge * displayScale }

    private var cacheKey: String {
        "\(item.descriptor.storageKey):\(Int(maxPixel.rounded(.up)))"
    }

    private var hasLocalData: Bool { item.message.attachmentData != nil }

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
        .task(id: "\(cacheKey):\(hasLocalData)") {
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
            openGallery(item.id)
            return
        }
        if thumbnail != nil {
            openGallery(item.id)
            return
        }
        guard !isLoading else { return }
        Task { await downloadAndDecode() }
    }

    private func prepareThumbnail() async {
        guard thumbnail == nil else { return }
        if let cached = ConversationMediaThumbnailCache.shared.image(forKey: cacheKey) {
            thumbnail = cached
            return
        }
        // Thumbnails come from locally available plaintext only; no implicit network work.
        guard let data = item.message.attachmentData else { return }
        await decodeThumbnail(from: data)
    }

    private func downloadAndDecode() async {
        isLoading = true
        didFail = false
        defer { isLoading = false }
        do {
            let data = try await model.loadSecureMedia(
                conversationId: item.message.conversationId,
                descriptorText: item.message.body
            )
            await decodeThumbnail(from: data)
            if thumbnail == nil { didFail = true }
        } catch {
            didFail = true
        }
    }

    private func decodeThumbnail(from data: Data) async {
        let pixel = maxPixel
        let mediaType = item.descriptor.mediaType
        let image: UIImage?
        if isVideo {
            image = await ConversationMediaThumbnailFactory.videoThumbnail(
                data: data,
                mediaType: mediaType,
                maxPixel: pixel
            )
        } else {
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

    /// Large files never persist inline in app state; keep the plaintext for this row's lifetime.
    @State private var downloadedData: Data?
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var localData: Data? { item.message.attachmentData ?? downloadedData }
    private var isCurrent: Bool { player.playingID == item.message.id }
    private var isPlaying: Bool { isCurrent && !player.isPaused }

    private var title: String {
        item.descriptor.caption?.isEmpty == false ? item.descriptor.caption! : "Voice note"
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
        .onAppear { player.noteSourceVisibility(true, for: item.message.id) }
        .onDisappear { player.noteSourceVisibility(false, for: item.message.id) }
    }

    private var actionButton: some View {
        Button(action: handleTap) {
            Group {
                if isLoading {
                    ProgressView().tint(.white)
                } else if localData != nil {
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
            localData == nil
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
        if let localData {
            player.toggle(
                data: localData,
                id: item.message.id,
                context: chatContext.playbackContext(senderUserID: item.message.senderId)
            )
            return
        }
        Task { await download() }
    }

    private func download() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            downloadedData = try await model.loadSecureMedia(
                conversationId: item.message.conversationId,
                descriptorText: item.message.body
            )
        } catch {
            errorMessage = model.isOnline ? "Couldn't download. Tap to retry." : "Available when online"
        }
    }
}

// MARK: - Document row

private struct PresentedDocumentFile: Identifiable {
    let id = UUID()
    let url: URL
}

private struct MediaLibraryDocumentRow: View {
    @EnvironmentObject private var model: AppModel

    let item: ConversationMediaItem

    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var presented: PresentedDocumentFile?

    private var fileName: String {
        item.descriptor.caption?.isEmpty == false ? item.descriptor.caption! : "Document"
    }

    private var typeLabel: String {
        ChatMediaTempFiles.fileExtension(forMediaType: item.descriptor.mediaType).uppercased()
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
                displayName: fileName,
                mediaType: item.descriptor.mediaType,
                byteCount: item.descriptor.plaintextByteSize,
                onClose: { close() }
            )
        }
    }

    private var detailLine: String {
        if let errorMessage { return errorMessage }
        if isLoading { return "Decrypting…" }
        return "\(typeLabel) · \(item.byteLabel) · \(item.dateLabel)"
    }

    private func open() async {
        if let data = item.message.attachmentData {
            present(data)
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let data = try await model.loadSecureMedia(
                conversationId: item.message.conversationId,
                descriptorText: item.message.body
            )
            present(data)
        } catch {
            errorMessage = model.isOnline ? "Couldn't open. Tap to retry." : "Available when online"
        }
    }

    private func present(_ data: Data) {
        guard presented == nil else { return }
        do {
            let url = try ChatMediaTempFiles.writeTemporaryFile(
                data: data,
                mediaType: item.descriptor.mediaType,
                suggestedName: fileName
            )
            presented = PresentedDocumentFile(url: url)
        } catch {
            errorMessage = "Couldn't open. Tap to retry."
        }
    }

    private func close() {
        ChatMediaTempFiles.removeTemporaryFile(presented?.url)
        presented = nil
    }
}
