import AVFoundation
import AVKit
import QuickLook
import SwiftUI
import UIKit

// MARK: - Staged (not yet sent) attachments

/// A file the user picked and can still review/remove before sending.
struct ChatStagedAttachment: Identifiable {
    let id = UUID()
    let kind: KitChatMediaKind
    let data: Data
    let mediaType: String
    /// Shown in the staging chip; for a lone document it also becomes the caption when no
    /// typed text rides along, so the filename survives the v1 wire format.
    let displayName: String
    let previewImage: UIImage?
    /// Shared-in rows carry their source item UUID so the composer can recognize and detach
    /// exactly the rows a handoff introduced. It is only a fallback send identity: while a
    /// shared delivery is applied, the whole send queues under the delivery's batch UUID.
    /// Ordinary camera/library attachments leave this nil and receive the queue's usual
    /// fresh identifier.
    let clientMessageID: UUID?

    init(
        kind: KitChatMediaKind,
        data: Data,
        mediaType: String,
        displayName: String,
        previewImage: UIImage?,
        clientMessageID: UUID? = nil
    ) {
        self.kind = kind
        self.data = data
        self.mediaType = mediaType
        self.displayName = displayName
        self.previewImage = previewImage
        self.clientMessageID = clientMessageID
    }

    var byteLabel: String { ChatMediaBytes.label(data.count) }
}

enum ChatMediaBytes {
    private static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static func label(_ bytes: Int) -> String {
        formatter.string(fromByteCount: Int64(bytes))
    }
}

enum ChatMediaTempFiles {
    /// Kept visible to tests so the protection contract can be verified even on Simulator
    /// filesystems, which do not consistently expose `NSFileProtectionKey` attributes.
    static let previewFileWritingOptions: Data.WritingOptions = [
        .atomic,
        .completeFileProtectionUnlessOpen,
    ]

    static func fileExtension(forMediaType mediaType: String) -> String {
        switch mediaType.lowercased() {
        case "image/jpeg": "jpg"
        case "image/png": "png"
        case "image/webp": "webp"
        case "image/gif": "gif"
        case "audio/mp4": "m4a"
        case "audio/aac": "aac"
        case "audio/mpeg": "mp3"
        case "audio/ogg": "ogg"
        case "video/mp4": "mp4"
        case "video/quicktime": "mov"
        case "video/webm": "webm"
        case "application/pdf": "pdf"
        case "application/zip": "zip"
        case "application/msword": "doc"
        case "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx"
        case "application/vnd.ms-excel": "xls"
        case "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "xlsx"
        case "application/vnd.ms-powerpoint": "ppt"
        case "application/vnd.openxmlformats-officedocument.presentationml.presentation": "pptx"
        case "text/plain": "txt"
        case "text/csv": "csv"
        default: "bin"
        }
    }

    /// Decrypted media is staged in a file-protected temporary file only for the lifetime of a
    /// preview; callers remove it when the preview closes. `UnlessOpen` is intentional: video
    /// players hold a read handle for their lifetime, so playback that began while unlocked can
    /// finish across a device-lock/background transition without ever making the plaintext
    /// generally readable while the device is locked.
    static func writeTemporaryFile(
        data: Data,
        mediaType: String,
        suggestedName: String? = nil
    ) throws -> URL {
        let base = suggestedName?
            .components(separatedBy: CharacterSet(charactersIn: "/\\:"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = (base?.isEmpty == false ? base! : "kit-media-\(UUID().uuidString)")
        let ext = fileExtension(forMediaType: mediaType)
        let named = stem.lowercased().hasSuffix(".\(ext)") ? stem : "\(stem).\(ext)"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kit-preview-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(named, isDirectory: false)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: previewFileWritingOptions)
        return url
    }

    static func removeTemporaryFile(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

// MARK: - Shared media loading state

/// Downloads/decrypts (or serves from cache) the plaintext for one media message.
@MainActor
private final class SecureMediaLoader: ObservableObject {
    /// Bytes together with the MIME/caption facts of the same authoritative resolution.
    /// Anything that displays or re-encodes what was loaded must take its facts from here,
    /// never from a row snapshot the view captured earlier.
    @Published var loaded: SecureMediaLoadPolicy.LoadedItem?
    @Published var isLoading = false
    @Published var errorMessage: String?

    var data: Data? { loaded?.data }

    /// Identity only: the model re-resolves the current persisted row and re-parses its
    /// descriptor before any cache probe, so a bubble's captured snapshot can never feed the
    /// verifying open paths. `itemIndex` nil is the single-attachment (v1) shape; non-nil
    /// addresses one item of a multi-attachment batch. `allowsDownload` false probes only what
    /// is already local (the row's inline slot or the encrypted cache) and fails silently —
    /// poster/preview surfaces must never turn scrolling into network transfers or error text.
    func load(
        model: AppModel,
        messageID: UUID,
        conversationId: String,
        itemIndex: Int?,
        allowsDownload: Bool = true
    ) async {
        guard loaded == nil, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            loaded = try await model.loadSecureMediaItem(
                messageID: messageID,
                conversationId: conversationId,
                itemIndex: itemIndex,
                allowsDownload: allowsDownload
            )
        } catch {
            guard allowsDownload else { return }
            errorMessage = model.isOnline ? "Tap to retry" : "Available when online"
        }
    }

    /// Fresh authoritative resolution for a user-triggered presentation. Unlike `load` — which
    /// keeps whatever it loaded for passive rendering — this never lets previously loaded UI
    /// state service a later action: it re-resolves the identity right now (account, current
    /// persisted row, full projection) and replaces `loaded` with the outcome, clearing it when
    /// the row no longer resolves so stale bytes cannot be presented again. Callers must present
    /// exactly the returned item — its bytes and its MIME/caption/size facts together.
    @discardableResult
    func refreshForPresentation(
        model: AppModel,
        messageID: UUID,
        conversationId: String,
        itemIndex: Int?
    ) async -> SecureMediaLoadPolicy.LoadedItem? {
        guard !isLoading else { return nil }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let fresh = try await model.loadSecureMediaItem(
                messageID: messageID,
                conversationId: conversationId,
                itemIndex: itemIndex
            )
            loaded = fresh
            return fresh
        } catch {
            loaded = nil
            errorMessage = model.isOnline ? "Tap to retry" : "Available when online"
            return nil
        }
    }
}

// MARK: - Media message bubble content

/// Renders any end-to-end encrypted media descriptor inside a chat bubble.
struct SecureMediaMessageView: View {
    let message: LocalMessage
    let descriptor: KitMediaMessageDescriptor
    /// When set, photo/video taps open the shared conversation gallery instead of the
    /// standalone single-item viewers.
    var openGallery: ((UUID) -> Void)? = nil

    var body: some View {
        switch KitChatMediaKind(mediaType: descriptor.mediaType) {
        case .image:
            SecureImageMessageView(
                message: message,
                descriptor: descriptor,
                openGallery: openGallery
            )
        case .voice:
            VoiceNoteBubbleView(message: message, descriptor: descriptor)
        case .video:
            VideoMessageBubbleView(
                message: message,
                descriptor: descriptor,
                openGallery: openGallery
            )
        case .document:
            DocumentMessageBubbleView(message: message, descriptor: descriptor)
        }
    }
}

/// Renders media that is durably queued locally but does not have an uploaded descriptor yet.
/// Pending rows must use the attachment MIME type rather than assuming every queued blob is a photo.
struct PendingSecureMediaMessageView: View {
    @EnvironmentObject private var model: AppModel
    let message: LocalMessage
    let attachment: LocalPendingAttachment
    /// Bytes plus the MIME facts of the same authoritative identity resolution. Loaded by
    /// message identity — never from this view's captured row snapshot — so the preview and
    /// the facts shown with it can only ever be the current persisted pending attachment's.
    @State private var loaded: SecureMediaLoadPolicy.LoadedItem?

    private var kind: KitChatMediaKind {
        KitChatMediaKind(mediaType: attachment.mediaType)
    }

    private var sizeLabel: String? {
        if let byteCount = loaded?.data.count ?? attachment.byteCount {
            return ChatMediaBytes.label(byteCount)
        }
        return nil
    }

    private var title: String {
        if kind == .document, let caption = attachment.caption, !caption.isEmpty {
            return caption
        }
        return "\(kind.previewLabel) queued"
    }

    var body: some View {
        pendingContent
            .task(id: message.id) {
                guard loaded == nil, kind == .image else { return }
                loaded = await model.loadPendingMedia(
                    messageID: message.id,
                    conversationId: message.conversationId
                )
            }
    }

    @ViewBuilder
    private var pendingContent: some View {
        if let loaded,
           KitChatMediaKind(mediaType: loaded.mediaType) == .image,
           let image = UIImage(data: loaded.data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 224, height: 168)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                .accessibilityLabel("End-to-end encrypted photo queued to send")
        } else {
            HStack(spacing: 11) {
                Image(systemName: kind.symbolName)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(message.isOutgoing ? .white : KitColor.green)
                    .frame(width: 38, height: 38)
                    .background(
                        message.isOutgoing
                            ? Color.white.opacity(0.14)
                            : KitColor.paleGreen.opacity(0.55),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(message.isOutgoing ? .white : KitColor.navy)
                        .lineLimit(2)
                    if let sizeLabel {
                        Text(sizeLabel)
                            .font(.caption)
                            .foregroundStyle(
                                message.isOutgoing
                                    ? .white.opacity(0.72)
                                    : KitColor.secondaryText
                            )
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("End-to-end encrypted \(kind.previewLabel.lowercased()) queued to send")
        }
    }
}

// MARK: - Multi-attachment (KITMEDIA2) message

/// One bubble for one multi-attachment message, whichever phase it is in: still uploading
/// (`pendingMediaBatch`), sealed outgoing, or received. Items render in display order inside
/// this single bubble — the batch is one message and must never read as several — and each item
/// downloads, decrypts, and opens on its own without touching its siblings. The caption and the
/// status/retry row belong to the enclosing bubble, not to any item.
struct SecureMediaBatchMessageView: View {
    let message: LocalMessage

    var body: some View {
        if let batch = message.pendingMediaBatch, batch.isStructurallyValid {
            itemStack(
                items: batch.items.map { ($0.attachmentID, $0.mediaType, $0.plaintextByteSize) },
                isPending: true
            )
        } else if let descriptor = KitMediaMessageV2Descriptor.parse(message.body) {
            itemStack(
                items: descriptor.items.map {
                    ($0.attachmentID, $0.mediaType, $0.plaintextByteSize)
                },
                isPending: false
            )
        } else {
            // A damaged batch row (structural gate refused it) still owns its bubble; it shows
            // the family placeholder rather than nothing, and never any raw wire text.
            HStack(spacing: 11) {
                Image(systemName: "paperclip")
                    .font(.system(size: 19, weight: .semibold))
                Text(KitMediaMessageFamilyPresentation.genericAttachmentLabel)
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(message.isOutgoing ? .white : KitColor.navy)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Attachment unavailable")
        }
    }

    private func itemStack(
        items: [(attachmentID: String, mediaType: String, plaintextByteSize: Int)],
        isPending: Bool
    ) -> some View {
        VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 5) {
            ForEach(Array(items.enumerated()), id: \.element.attachmentID) { index, item in
                SecureMediaBatchItemView(
                    message: message,
                    itemIndex: index,
                    itemCount: items.count,
                    attachmentID: item.attachmentID,
                    mediaType: item.mediaType,
                    plaintextByteSize: item.plaintextByteSize,
                    isPending: isPending
                )
            }
        }
    }
}

/// One attachment of a multi-attachment message. Photos show themselves; everything else is a
/// row that names its kind and size and opens (or first fetches) on tap. Pending items read
/// only the local cache — their plaintext was parked at queue time and nothing exists on the
/// server to fetch until the seal.
struct SecureMediaBatchItemView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.voiceNoteChatContext) private var chatContext
    @ObservedObject private var player = VoiceNotePlayer.shared
    let message: LocalMessage
    let itemIndex: Int
    let itemCount: Int
    /// Queue-minted canonical UUID; doubles as this item's stable playback identity.
    let attachmentID: String
    let mediaType: String
    let plaintextByteSize: Int
    let isPending: Bool

    @StateObject private var loader = SecureMediaLoader()
    @State private var retryGeneration = 0
    @State private var showsImageViewer = false
    @State private var playbackURL: URL?
    @State private var documentURL: URL?

    private var kind: KitChatMediaKind { KitChatMediaKind(mediaType: mediaType) }

    private var voiceNoteID: UUID {
        UUID(uuidString: attachmentID) ?? message.id
    }

    /// Photos fetch themselves the way v1 photos do; other kinds wait for a tap, because a
    /// batch can carry up to eight items of up to 200 MB each. Pending items always load —
    /// for them "loading" is a local cache read, never network.
    private var loadsAutomatically: Bool {
        isPending || kind == .image
    }

    private var accessibilityPosition: String {
        "item \(itemIndex + 1) of \(itemCount)"
    }

    var body: some View {
        itemContent
            .task(
                id: "\(message.id):\(itemIndex):\(model.isOnline):\(retryGeneration)"
            ) {
                guard loadsAutomatically, loader.data == nil else { return }
                await loader.load(
                    model: model,
                    messageID: message.id,
                    conversationId: message.conversationId,
                    itemIndex: itemIndex
                )
            }
    }

    @ViewBuilder
    private var itemContent: some View {
        switch kind {
        case .image:
            imageCell
        case .voice:
            voiceRow
        case .video, .document:
            fileRow
        }
    }

    @ViewBuilder
    private var imageCell: some View {
        if let image = loader.data.flatMap(UIImage.init(data:)) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: 224, maxHeight: 168)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                .onTapGesture {
                    // A tap presents full-screen: re-prove the row first, and show only the
                    // freshly resolved bytes — the rendered thumbnail is not authority.
                    Task {
                        guard !loader.isLoading,
                              let fresh = await loader.refreshForPresentation(
                                  model: model,
                                  messageID: message.id,
                                  conversationId: message.conversationId,
                                  itemIndex: itemIndex
                              ), UIImage(data: fresh.data) != nil else { return }
                        showsImageViewer = true
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("End-to-end encrypted photo, \(accessibilityPosition)")
                .accessibilityAddTraits(.isButton)
                .fullScreenCover(isPresented: $showsImageViewer) {
                    MediaImageViewer(image: image)
                }
        } else {
            Button { retryGeneration &+= 1 } label: {
                mediaPlaceholder(
                    systemImage: model.isOnline ? "photo.badge.arrow.down" : "photo.fill",
                    title: loader.errorMessage
                        ?? (isPending
                            ? "Photo queued"
                            : model.isOnline
                                ? "Loading encrypted photo…"
                                : "Photo available when online"),
                    isLoading: loader.isLoading,
                    isOutgoing: message.isOutgoing
                )
            }
            .buttonStyle(.plain)
            .disabled(loader.isLoading)
            .accessibilityLabel("End-to-end encrypted photo, \(accessibilityPosition)")
        }
    }

    private var voiceRow: some View {
        let isCurrent = player.playingID == voiceNoteID
        let isPlaying = isCurrent && !player.isPaused
        return Button {
            Task { await refreshThenPlay() }
        } label: {
            row(
                systemImage: isPlaying ? "pause.fill" : "play.fill",
                title: "Voice note",
                subtitle: subtitleLabel
            )
        }
        .buttonStyle(.plain)
        .disabled(loader.isLoading)
        .accessibilityLabel(
            "End-to-end encrypted voice note, \(accessibilityPosition)"
        )
    }

    private var fileRow: some View {
        Button {
            Task { await refreshThenPresent() }
        } label: {
            row(
                systemImage: kind.symbolName,
                title: kind.previewLabel,
                subtitle: subtitleLabel
            )
        }
        .buttonStyle(.plain)
        .disabled(loader.isLoading)
        .accessibilityLabel(
            "End-to-end encrypted \(kind.previewLabel.lowercased()), \(accessibilityPosition)"
        )
        .fullScreenCover(
            isPresented: Binding(
                get: { playbackURL != nil || documentURL != nil },
                set: { if !$0 { closePresentation() } }
            )
        ) {
            if let playbackURL {
                MediaVideoPlayerView(fileURL: playbackURL) { closePresentation() }
            } else if let documentURL, let loaded = loader.loaded {
                // Viewer facts from the same fresh resolution that produced the temp file —
                // never the item fields this bubble captured at render time.
                KitDocumentViewerView(
                    fileURL: documentURL,
                    displayName: presentedDisplayName(mediaType: loaded.mediaType),
                    mediaType: loaded.mediaType,
                    byteCount: loaded.data.count,
                    onClose: { closePresentation() }
                )
            }
        }
    }

    private func presentedDisplayName(mediaType: String) -> String {
        "\(KitChatMediaKind(mediaType: mediaType).previewLabel) \(itemIndex + 1)"
    }

    private func row(systemImage: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        message.isOutgoing
                            ? Color.white.opacity(0.14)
                            : KitColor.paleGreen.opacity(0.55)
                    )
                    .frame(width: 38, height: 38)
                if loader.isLoading {
                    ProgressView()
                        .tint(message.isOutgoing ? .white : KitColor.green)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(message.isOutgoing ? .white : KitColor.green)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(message.isOutgoing ? .white : KitColor.navy)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(
                        message.isOutgoing ? .white.opacity(0.72) : KitColor.secondaryText
                    )
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitleLabel: String {
        if let errorMessage = loader.errorMessage { return errorMessage }
        if loader.isLoading { return "Decrypting…" }
        // Once loaded, the size fact tracks the resolved bytes, not the captured item field.
        let bytes = loader.loaded?.data.count ?? plaintextByteSize
        if isPending { return "Queued · \(ChatMediaBytes.label(bytes))" }
        return ChatMediaBytes.label(bytes)
    }

    /// Every play/pause tap re-proves the row — account, current persisted row, full
    /// projection — with a fresh resolution before any plaintext reaches the player;
    /// previously loaded UI state never services it. If the row no longer resolves, a note
    /// still playing under this identity is stopped rather than left presenting stale audio.
    private func refreshThenPlay() async {
        guard !loader.isLoading else { return }
        guard let fresh = await loader.refreshForPresentation(
            model: model,
            messageID: message.id,
            conversationId: message.conversationId,
            itemIndex: itemIndex
        ) else {
            if player.playingID == voiceNoteID { player.stop() }
            return
        }
        player.toggle(
            data: fresh.data,
            id: voiceNoteID,
            context: chatContext.playbackContext(senderUserID: message.senderId)
        )
    }

    private func refreshThenPresent() async {
        guard !loader.isLoading else { return }
        guard let fresh = await loader.refreshForPresentation(
            model: model,
            messageID: message.id,
            conversationId: message.conversationId,
            itemIndex: itemIndex
        ) else { return }
        present(fresh)
    }

    // Temp-file bytes, declared type, viewer branch, and suggested name all come from the same
    // fresh resolution — never from the item facts this bubble captured at render time.
    private func present(_ item: SecureMediaLoadPolicy.LoadedItem) {
        guard playbackURL == nil, documentURL == nil else { return }
        let presentedKind = KitChatMediaKind(mediaType: item.mediaType)
        let url = try? ChatMediaTempFiles.writeTemporaryFile(
            data: item.data,
            mediaType: item.mediaType,
            suggestedName: presentedKind == .document
                ? presentedDisplayName(mediaType: item.mediaType)
                : nil
        )
        if presentedKind == .video {
            playbackURL = url
        } else {
            documentURL = url
        }
    }

    private func closePresentation() {
        ChatMediaTempFiles.removeTemporaryFile(playbackURL ?? documentURL)
        playbackURL = nil
        documentURL = nil
    }
}

// MARK: - Image

struct SecureImageMessageView: View {
    @EnvironmentObject private var model: AppModel
    let message: LocalMessage
    let descriptor: KitMediaMessageDescriptor
    var openGallery: ((UUID) -> Void)? = nil
    @StateObject private var loader = SecureMediaLoader()
    @State private var retryGeneration = 0
    @State private var showsViewer = false

    private var image: UIImage? {
        // Identity-resolved bytes only: the captured row's inline slot is a snapshot, and the
        // loader serves the same inline bytes through the current-row resolution instead.
        loader.data.flatMap(UIImage.init(data:))
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: 248, maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .onTapGesture {
                        if let openGallery {
                            openGallery(message.id)
                        } else {
                            // A tap presents full-screen: re-prove the row first, and show
                            // only the freshly resolved bytes — the rendered thumbnail is
                            // not authority.
                            Task {
                                guard !loader.isLoading,
                                      let fresh = await loader.refreshForPresentation(
                                          model: model,
                                          messageID: message.id,
                                          conversationId: message.conversationId,
                                          itemIndex: nil
                                      ), UIImage(data: fresh.data) != nil else { return }
                                showsViewer = true
                            }
                        }
                    }
            } else {
                Button { retryGeneration &+= 1 } label: {
                    mediaPlaceholder(
                        systemImage: model.isOnline ? "photo.badge.arrow.down" : "photo.fill",
                        title: loader.errorMessage
                            ?? (model.isOnline ? "Loading encrypted photo…" : "Photo available when online"),
                        isLoading: loader.isLoading,
                        isOutgoing: message.isOutgoing
                    )
                }
                .buttonStyle(.plain)
                .disabled(loader.isLoading)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("End-to-end encrypted photo")
        .task(id: "\(descriptor.storageKey):\(model.isOnline):\(retryGeneration)") {
            guard image == nil else { return }
            await loader.load(
                model: model,
                messageID: message.id,
                conversationId: message.conversationId,
                itemIndex: nil
            )
        }
        .fullScreenCover(isPresented: $showsViewer) {
            if let image {
                MediaImageViewer(image: image)
            }
        }
    }
}

/// Full-screen, pinch-zoomable photo viewer.
struct MediaImageViewer: View {
    @Environment(\.dismiss) private var dismiss
    let image: UIImage
    @State private var scale: CGFloat = 1
    @State private var steadyScale: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(max(1, scale))
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in scale = steadyScale * value }
                        .onEnded { _ in
                            steadyScale = max(1, min(scale, 4))
                            withAnimation(.snappy) { scale = steadyScale }
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.snappy) {
                        scale = scale > 1 ? 1 : 2
                        steadyScale = scale
                    }
                }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding(18)
            .accessibilityLabel("Close photo")
        }
        .statusBarHidden()
    }
}

// MARK: - Voice note

struct VoiceNoteBubbleView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.voiceNoteChatContext) private var chatContext
    @ObservedObject private var player = VoiceNotePlayer.shared
    let message: LocalMessage
    let descriptor: KitMediaMessageDescriptor
    @StateObject private var loader = SecureMediaLoader()
    /// Fraction playback was at when the current slide began, so a slide moves the note relative
    /// to where the finger went down instead of jumping to it.
    @State private var scrubOrigin: Double?

    // Identity-resolved bytes only — the loader serves even the row's inline slot through the
    // current-row resolution, never the view's captured snapshot.
    private var data: Data? { loader.data }
    private var isCurrent: Bool { player.playingID == message.id }
    private var isPlaying: Bool { isCurrent && !player.isPaused }
    private var accent: Color { message.isOutgoing ? .white : KitColor.green }

    private var playbackContext: VoiceNotePlaybackContext {
        chatContext.playbackContext(senderUserID: message.senderId)
    }

    var body: some View {
        HStack(spacing: 11) {
            Button {
                Task { await refreshThenToggle() }
            } label: {
                Group {
                    if loader.isLoading {
                        ProgressView().tint(accent)
                    } else {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 17, weight: .bold))
                    }
                }
                .foregroundStyle(message.isOutgoing ? KitColor.navy : .white)
                .frame(width: 38, height: 38)
                .background(accent, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Pause voice note" : "Play voice note")

            VStack(alignment: .leading, spacing: 5) {
                VoiceNoteWaveform(
                    progress: isCurrent ? player.progress : 0,
                    accent: accent,
                    seed: message.id
                )
                .frame(width: VoiceNoteSeekPolicy.waveformWidth, height: 22)
                .contentShape(Rectangle())
                // Runs *alongside* the thread's scroll rather than replacing it: a mostly-vertical
                // drag that starts on the waveform is someone scrolling past, and is left alone.
                .simultaneousGesture(seekGesture)
                .accessibilityElement()
                .accessibilityLabel("Voice note position")
                .accessibilityValue(
                    isCurrent ? "\(Int((player.progress * 100).rounded())) percent" : "Not playing"
                )
                .accessibilityAdjustableAction { direction in
                    guard isCurrent else { return }
                    switch direction {
                    case .increment: player.seek(by: 5)
                    case .decrement: player.seek(by: -5)
                    @unknown default: break
                    }
                }
                Text(subtitle)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(
                        message.isOutgoing ? .white.opacity(0.72) : KitColor.secondaryText
                    )
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("End-to-end encrypted voice note")
        .task(id: "\(descriptor.storageKey):\(model.isOnline)") {
            guard data == nil else { return }
            await loader.load(
                model: model,
                messageID: message.id,
                conversationId: message.conversationId,
                itemIndex: nil
            )
        }
        // While this bubble is on screen it *is* the control for its own note, so the floating bar
        // stays out of the way; the moment the thread scrolls past it, the bar takes over.
        .onAppear { player.noteSourceVisibility(true, for: message.id) }
        .onDisappear { player.noteSourceVisibility(false, for: message.id) }
    }

    /// A tap positions the note at the point touched — starting it there if it was not playing —
    /// and a horizontal slide scrubs from wherever the finger went down.
    private var seekGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard isCurrent else { return }
                if scrubOrigin == nil { scrubOrigin = player.progress }
                guard let origin = scrubOrigin,
                      VoiceNoteSeekPolicy.isScrub(translation: value.translation)
                else { return }
                player.seek(
                    toFraction: VoiceNoteSeekPolicy.scrubbedFraction(
                        from: origin,
                        translationWidth: value.translation.width,
                        width: VoiceNoteSeekPolicy.waveformWidth
                    )
                )
            }
            .onEnded { value in
                let origin = scrubOrigin ?? player.progress
                scrubOrigin = nil
                if VoiceNoteSeekPolicy.isTap(translation: value.translation) {
                    let fraction = VoiceNoteSeekPolicy.fraction(
                        atX: value.location.x,
                        width: VoiceNoteSeekPolicy.waveformWidth
                    )
                    if isCurrent {
                        player.seek(toFraction: fraction)
                    } else {
                        // Tap-to-position starts playback, which presents plaintext: the same
                        // fresh re-proof as the play button, then position at the tapped spot.
                        Task {
                            await refreshThenToggle()
                            if isCurrent { player.seek(toFraction: fraction) }
                        }
                    }
                } else if isCurrent, VoiceNoteSeekPolicy.isScrub(translation: value.translation) {
                    player.seek(
                        toFraction: VoiceNoteSeekPolicy.scrubbedFraction(
                            from: origin,
                            translationWidth: value.translation.width,
                            width: VoiceNoteSeekPolicy.waveformWidth
                        )
                    )
                }
            }
    }

    /// Every play/pause tap re-proves the row — account, current persisted row, full
    /// projection — with a fresh resolution before any plaintext reaches the player;
    /// previously loaded UI state never services it. If the row no longer resolves, a note
    /// still playing under this identity is stopped rather than left presenting stale audio.
    private func refreshThenToggle() async {
        guard !loader.isLoading else { return }
        guard let fresh = await loader.refreshForPresentation(
            model: model,
            messageID: message.id,
            conversationId: message.conversationId,
            itemIndex: nil
        ) else {
            if isCurrent { player.stop() }
            return
        }
        player.toggle(data: fresh.data, id: message.id, context: playbackContext)
    }

    private var subtitle: String {
        if isCurrent, player.duration > 0 {
            let remaining = max(0, player.duration * (1 - player.progress))
            return durationLabel(remaining)
        }
        if let errorMessage = loader.errorMessage { return errorMessage }
        if data == nil { return ChatMediaBytes.label(descriptor.plaintextByteSize) }
        return "Voice note"
    }

    private func durationLabel(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Deterministic bars per message with a played-progress tint.
struct VoiceNoteWaveform: View {
    let progress: Double
    let accent: Color
    let seed: UUID

    private var heights: [CGFloat] {
        // Cheap deterministic pseudo-noise from the UUID bytes.
        var bytes = [UInt8]()
        withUnsafeBytes(of: seed.uuid) { bytes.append(contentsOf: $0) }
        return (0..<26).map { index in
            let byte = bytes[index % bytes.count] &+ UInt8(truncatingIfNeeded: index &* 37)
            return 6 + CGFloat(byte % 16)
        }
    }

    var body: some View {
        let bars = heights
        HStack(alignment: .center, spacing: 2.4) {
            ForEach(bars.indices, id: \.self) { index in
                Capsule()
                    .fill(
                        Double(index) / Double(bars.count) <= progress && progress > 0
                            ? accent
                            : accent.opacity(0.38)
                    )
                    .frame(width: 2.6, height: bars[index])
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Video

struct VideoMessageBubbleView: View {
    @EnvironmentObject private var model: AppModel
    let message: LocalMessage
    let descriptor: KitMediaMessageDescriptor
    var openGallery: ((UUID) -> Void)? = nil
    @StateObject private var loader = SecureMediaLoader()
    @State private var poster: UIImage?
    @State private var playbackURL: URL?

    var body: some View {
        Button {
            if let openGallery {
                openGallery(message.id)
            } else {
                Task { await refreshThenPresent() }
            }
        } label: {
            ZStack {
                if let poster {
                    Image(uiImage: poster)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 248, height: 186)
                        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 17, style: .continuous)
                                .fill(.black.opacity(0.22))
                        }
                } else {
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .fill(
                            message.isOutgoing
                                ? Color.white.opacity(0.09)
                                : KitColor.paleGreen.opacity(0.28)
                        )
                        .frame(width: 248, height: 150)
                }
                VStack(spacing: 8) {
                    if loader.isLoading {
                        ProgressView()
                            .tint(message.isOutgoing ? .white : KitColor.green)
                    } else {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 42, weight: .semibold))
                            .foregroundStyle(.white, KitColor.green)
                            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                    }
                    Text(subtitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(
                            poster != nil
                                ? .white
                                : (message.isOutgoing ? .white.opacity(0.85) : KitColor.secondaryText)
                        )
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(loader.isLoading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("End-to-end encrypted video")
        .task(id: descriptor.storageKey) {
            // Poster only from bytes that are already local, but still through identity
            // resolution — never the captured row snapshot. `allowsDownload: false` keeps
            // scrolling a conversation from silently downloading large videos.
            await loader.load(
                model: model,
                messageID: message.id,
                conversationId: message.conversationId,
                itemIndex: nil,
                allowsDownload: false
            )
            if let loaded = loader.loaded {
                await makePoster(from: loaded)
            }
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { playbackURL != nil },
                set: { if !$0 { closePlayer() } }
            )
        ) {
            if let playbackURL {
                MediaVideoPlayerView(fileURL: playbackURL) { closePlayer() }
            }
        }
    }

    private var subtitle: String {
        if let errorMessage = loader.errorMessage { return errorMessage }
        if loader.isLoading { return "Decrypting…" }
        if loader.data == nil {
            return ChatMediaBytes.label(descriptor.plaintextByteSize)
        }
        return "Play"
    }

    /// A tap presents playback: re-prove the row — account, current persisted row, full
    /// projection — with a fresh resolution and present exactly that result; previously loaded
    /// UI state never services it.
    private func refreshThenPresent() async {
        guard !loader.isLoading else { return }
        guard let fresh = await loader.refreshForPresentation(
            model: model,
            messageID: message.id,
            conversationId: message.conversationId,
            itemIndex: nil
        ) else { return }
        await makePoster(from: fresh)
        present(fresh)
    }

    // The temp file's declared type must come from the same authoritative resolution as the
    // bytes it holds, not from the descriptor the bubble captured at render time.
    private func present(_ item: SecureMediaLoadPolicy.LoadedItem) {
        guard playbackURL == nil else { return }
        playbackURL = try? ChatMediaTempFiles.writeTemporaryFile(
            data: item.data,
            mediaType: item.mediaType
        )
    }

    private func closePlayer() {
        ChatMediaTempFiles.removeTemporaryFile(playbackURL)
        playbackURL = nil
    }

    private func makePoster(from item: SecureMediaLoadPolicy.LoadedItem) async {
        guard poster == nil,
              let url = try? ChatMediaTempFiles.writeTemporaryFile(
                  data: item.data,
                  mediaType: item.mediaType
              )
        else { return }
        defer { ChatMediaTempFiles.removeTemporaryFile(url) }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 600, height: 600)
        if let cgImage = try? await generator.image(at: .init(seconds: 0.1, preferredTimescale: 600)).image {
            poster = UIImage(cgImage: cgImage)
        }
    }
}

struct MediaVideoPlayerView: View {
    let fileURL: URL
    let onClose: () -> Void
    @StateObject private var playback = MediaVideoPlaybackController()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let player = playback.player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            }
            Button {
                playback.stop()
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding(18)
            .accessibilityLabel("Close video")
        }
        .onAppear {
            playback.start(fileURL: fileURL)
        }
        .onDisappear { playback.stop() }
    }
}

/// Owns the simple single-video viewer's AVPlayer and protected-file lease. The full gallery has
/// its own controller because it also coordinates scrubbing and Picture in Picture, but both use
/// the same fail-closed recovery policy for a provably premature local-file stop.
@MainActor
private final class MediaVideoPlaybackController: ObservableObject {
    @Published private(set) var player: AVPlayer?

    private var fileURL: URL?
    private var playbackFileHandle: FileHandle?
    private var duration: Double = 0
    private var intendsToPlay = false
    private var automaticRecoveryAttempts = 0
    private var lastObservedPlaybackTime: Double?
    private var lastPlaybackProgressUptime: TimeInterval?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var stallObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var recoveryTask: Task<Void, Never>?

    func start(fileURL: URL) {
        guard player == nil,
              let fileHandle = try? FileHandle(forReadingFrom: fileURL)
        else { return }
        self.fileURL = fileURL
        playbackFileHandle = fileHandle
        let asset = AVURLAsset(url: fileURL)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        self.player = player
        observePlaybackItem(item)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self, weak player] time in
            Task { @MainActor in
                guard let self else { return }
                let seconds = time.seconds
                guard seconds.isFinite else { return }
                if let previous = self.lastObservedPlaybackTime,
                   abs(seconds - previous) > 0.01,
                   player?.rate != 0 {
                    self.lastPlaybackProgressUptime = ProcessInfo.processInfo.systemUptime
                }
                self.lastObservedPlaybackTime = seconds
            }
        }
        intendsToPlay = true
        player.play()

        Task { @MainActor [weak self] in
            let loaded = try? await asset.load(.duration)
            guard let self,
                  self.fileURL == fileURL,
                  let seconds = loaded?.seconds,
                  seconds.isFinite
            else { return }
            self.duration = seconds
        }
    }

    func stop() {
        intendsToPlay = false
        recoveryTask?.cancel()
        recoveryTask = nil
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        removePlaybackItemObservers()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        duration = 0
        automaticRecoveryAttempts = 0
        lastObservedPlaybackTime = nil
        lastPlaybackProgressUptime = nil
        if let playbackFileHandle {
            try? playbackFileHandle.close()
        }
        playbackFileHandle = nil
        fileURL = nil
    }

    private func observePlaybackItem(_ item: AVPlayerItem) {
        removePlaybackItemObservers()
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.automaticRecoveryAttempts = 0 }
        }
        stallObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.requestAutomaticRecovery(
                    afterNanoseconds: 400_000_000,
                    interruption: .stalled
                )
            }
        }
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.requestAutomaticRecovery(
                    afterNanoseconds: 0,
                    interruption: .failed
                )
            }
        }
    }

    private func removePlaybackItemObservers() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let stallObserver { NotificationCenter.default.removeObserver(stallObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        endObserver = nil
        stallObserver = nil
        failureObserver = nil
    }

    private func requestAutomaticRecovery(
        afterNanoseconds delay: UInt64,
        interruption: ChatVideoPlaybackRecoveryPolicy.Interruption
    ) {
        guard intendsToPlay,
              automaticRecoveryAttempts
                  < ChatVideoPlaybackRecoveryPolicy.maximumAutomaticAttempts,
              let fileURL
        else { return }
        recoveryTask?.cancel()
        recoveryTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled,
                  let self,
                  self.intendsToPlay,
                  let player = self.player
            else { return }
            // `VideoPlayer` owns native controls, so its pause button does not call this
            // controller. Require AVPlayer-owned evidence that distinguishes a wait/failure from
            // an ordinary native-controls pause before replacing anything.
            let secondsSinceLastProgress = self.lastPlaybackProgressUptime.map {
                max(0, ProcessInfo.processInfo.systemUptime - $0)
            }
            guard ChatVideoPlaybackRecoveryPolicy.permitsNativeControlsRecovery(
                interruption: interruption,
                playerIsWaitingToPlay:
                    player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
                itemIsFailed: player.currentItem?.status == .failed,
                secondsSinceLastProgress: secondsSinceLastProgress
            ) else { return }

            let replacementAsset = AVURLAsset(url: fileURL)
            let loadedDuration = try? await replacementAsset.load(.duration)
            guard !Task.isCancelled, self.intendsToPlay else { return }
            let updatedSecondsSinceLastProgress = self.lastPlaybackProgressUptime.map {
                max(0, ProcessInfo.processInfo.systemUptime - $0)
            }
            guard ChatVideoPlaybackRecoveryPolicy.permitsNativeControlsRecovery(
                interruption: interruption,
                playerIsWaitingToPlay:
                    player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
                itemIsFailed: player.currentItem?.status == .failed,
                secondsSinceLastProgress: updatedSecondsSinceLastProgress
            ) else { return }
            let currentTime = player.currentTime().seconds
            let measuredDuration = loadedDuration?.seconds
            let provenDuration = if let measuredDuration, measuredDuration.isFinite {
                measuredDuration
            } else {
                self.duration
            }
            guard ChatVideoPlaybackRecoveryPolicy.shouldRecover(
                currentTime: currentTime,
                duration: provenDuration,
                intendsToPlay: self.intendsToPlay,
                attemptCount: self.automaticRecoveryAttempts
            ) else { return }

            self.duration = provenDuration
            self.automaticRecoveryAttempts += 1
            self.lastObservedPlaybackTime = currentTime
            let replacementItem = AVPlayerItem(asset: replacementAsset)
            self.observePlaybackItem(replacementItem)
            player.replaceCurrentItem(with: replacementItem)
            player.seek(
                to: CMTime(seconds: currentTime, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { [weak self, weak player] finished in
                Task { @MainActor in
                    guard finished, self?.intendsToPlay == true else { return }
                    player?.play()
                }
            }
        }
    }
}

// MARK: - Document

struct DocumentMessageBubbleView: View {
    @EnvironmentObject private var model: AppModel
    let message: LocalMessage
    let descriptor: KitMediaMessageDescriptor
    @StateObject private var loader = SecureMediaLoader()
    @State private var previewURL: URL?

    /// Before bytes exist the row label comes from the parse-gated bubble descriptor; once a
    /// fresh resolution has loaded, every fact tracks that result instead.
    private var fileName: String {
        if let loaded = loader.loaded {
            return Self.fileName(caption: loaded.caption, mediaType: loaded.mediaType)
        }
        return Self.fileName(caption: descriptor.caption, mediaType: descriptor.mediaType)
    }

    private static func fileName(caption: String?, mediaType: String) -> String {
        if let caption, !caption.isEmpty { return caption }
        return "Document.\(ChatMediaTempFiles.fileExtension(forMediaType: mediaType))"
    }

    var body: some View {
        Button {
            Task { await refreshThenPresent() }
        } label: {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(
                            message.isOutgoing
                                ? Color.white.opacity(0.14)
                                : KitColor.paleGreen.opacity(0.55)
                        )
                        .frame(width: 42, height: 42)
                    if loader.isLoading {
                        ProgressView()
                            .tint(message.isOutgoing ? .white : KitColor.green)
                    } else {
                        Image(systemName: "doc.fill")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(message.isOutgoing ? .white : KitColor.green)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(fileName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(message.isOutgoing ? .white : KitColor.navy)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(
                            message.isOutgoing ? .white.opacity(0.72) : KitColor.secondaryText
                        )
                }
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .disabled(loader.isLoading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("End-to-end encrypted document, \(fileName)")
        .fullScreenCover(
            isPresented: Binding(
                get: { previewURL != nil },
                set: { if !$0 { closePreview() } }
            )
        ) {
            if let previewURL, let loaded = loader.loaded {
                // Viewer facts from the same fresh resolution that produced the temp file —
                // never the descriptor this bubble captured at render time.
                KitDocumentViewerView(
                    fileURL: previewURL,
                    displayName: Self.fileName(
                        caption: loaded.caption,
                        mediaType: loaded.mediaType
                    ),
                    mediaType: loaded.mediaType,
                    byteCount: loaded.data.count,
                    onClose: { closePreview() }
                )
            }
        }
    }

    private var subtitle: String {
        if let errorMessage = loader.errorMessage { return errorMessage }
        if loader.isLoading { return "Decrypting…" }
        // Once loaded, the size fact tracks the resolved bytes, not the captured descriptor.
        return ChatMediaBytes.label(loader.loaded?.data.count ?? descriptor.plaintextByteSize)
    }

    /// A tap presents the preview: re-prove the row — account, current persisted row, full
    /// projection — with a fresh resolution and present exactly that result; previously loaded
    /// UI state never services it.
    private func refreshThenPresent() async {
        guard !loader.isLoading else { return }
        guard let fresh = await loader.refreshForPresentation(
            model: model,
            messageID: message.id,
            conversationId: message.conversationId,
            itemIndex: nil
        ) else { return }
        present(fresh)
    }

    // Temp-file bytes, declared type, and file name all come from the same fresh resolution —
    // never from the descriptor the bubble captured at render time.
    private func present(_ item: SecureMediaLoadPolicy.LoadedItem) {
        guard previewURL == nil else { return }
        previewURL = try? ChatMediaTempFiles.writeTemporaryFile(
            data: item.data,
            mediaType: item.mediaType,
            suggestedName: Self.fileName(caption: item.caption, mediaType: item.mediaType)
        )
    }

    private func closePreview() {
        ChatMediaTempFiles.removeTemporaryFile(previewURL)
        previewURL = nil
    }
}

struct DocumentQuickLookView: UIViewControllerRepresentable {
    let fileURL: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(fileURL: fileURL)
    }

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let fileURL: URL

        init(fileURL: URL) {
            self.fileURL = fileURL
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> QLPreviewItem {
            fileURL as NSURL
        }
    }
}

// MARK: - Shared placeholder

@ViewBuilder
private func mediaPlaceholder(
    systemImage: String,
    title: String,
    isLoading: Bool,
    isOutgoing: Bool
) -> some View {
    VStack(spacing: 9) {
        if isLoading {
            ProgressView().tint(isOutgoing ? .white : KitColor.green)
        } else {
            Image(systemName: systemImage)
                .font(.title2)
        }
        Text(title)
            .font(.caption)
            .multilineTextAlignment(.center)
    }
    .foregroundStyle(isOutgoing ? .white : KitColor.secondaryText)
    .frame(width: 224, height: 132)
    .background(
        isOutgoing ? Color.white.opacity(0.09) : KitColor.paleGreen.opacity(0.24),
        in: RoundedRectangle(cornerRadius: 15, style: .continuous)
    )
}
