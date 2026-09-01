import AVFoundation
import AVKit
import QuickLook
import SwiftUI
import UIKit

// MARK: - Staged (not yet sent) attachments

/// A file the user picked and can still review/remove before sending.
struct ChatStagedAttachment: Identifiable {
    let id: UUID
    let kind: KitChatMediaKind
    /// Small media can stay in memory. Large video/document originals are file-backed so the
    /// composer and player never require a 200 MB allocation merely to remain local-first.
    let data: Data?
    let localFileURL: URL?
    let byteCount: Int
    let mediaType: String
    /// MIME type of the capture/provider original when `mediaType` describes a later optimized
    /// representation. Kept separate so a HEIC/PNG source is never relabeled as JPEG on disk.
    let originalMediaType: String?
    /// Stable destination reserved for a durable preprocessing job.
    let preprocessingOutputStorageKey: String?
    /// Shown in the staging chip; for a lone document it also becomes the caption when no
    /// typed text rides along, so the filename survives the v1 wire format.
    let displayName: String
    let previewImage: UIImage?
    let duration: TimeInterval?
    /// When the app accepted the picker/camera/recorder output, before local persistence or any
    /// send-time work. Performance milestones use this instead of starting after processing.
    let acceptedAt: Date
    /// Shared-in rows carry their source item UUID so the composer can recognize and detach
    /// exactly the rows a handoff introduced. It is only a fallback send identity: while a
    /// shared delivery is applied, the whole send queues under the delivery's batch UUID.
    /// Ordinary camera/library attachments leave this nil and receive the queue's usual
    /// fresh identifier.
    let clientMessageID: UUID?

    init(
        id: UUID = UUID(),
        kind: KitChatMediaKind,
        data: Data,
        mediaType: String,
        displayName: String,
        previewImage: UIImage?,
        duration: TimeInterval? = nil,
        acceptedAt: Date = Date(),
        clientMessageID: UUID? = nil,
        originalMediaType: String? = nil,
        preprocessingOutputStorageKey: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.data = data
        self.localFileURL = nil
        self.byteCount = data.count
        self.mediaType = mediaType
        self.originalMediaType = originalMediaType
        self.preprocessingOutputStorageKey = preprocessingOutputStorageKey
        self.displayName = displayName
        self.previewImage = previewImage
        self.duration = duration
        self.acceptedAt = acceptedAt
        self.clientMessageID = clientMessageID
    }

    /// A camera image can render from its in-memory UIKit object while its protected JPEG is
    /// encoded and persisted off the main actor. Sending remains disabled during that short
    /// transition; this initializer must never cross into the durable queue unchanged.
    init(
        preparingImage id: UUID,
        previewImage: UIImage,
        displayName: String,
        acceptedAt: Date
    ) {
        self.id = id
        self.kind = .image
        self.data = nil
        self.localFileURL = nil
        self.byteCount = 0
        self.mediaType = "image/jpeg"
        self.originalMediaType = nil
        self.preprocessingOutputStorageKey = nil
        self.displayName = displayName
        self.previewImage = previewImage
        self.duration = nil
        self.acceptedAt = acceptedAt
        self.clientMessageID = nil
    }

    init(
        id: UUID = UUID(),
        kind: KitChatMediaKind,
        localFileURL: URL,
        byteCount: Int,
        mediaType: String,
        displayName: String,
        previewImage: UIImage?,
        duration: TimeInterval? = nil,
        acceptedAt: Date = Date(),
        clientMessageID: UUID? = nil,
        originalMediaType: String? = nil,
        preprocessingOutputStorageKey: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.data = nil
        self.localFileURL = localFileURL
        self.byteCount = byteCount
        self.mediaType = mediaType
        self.originalMediaType = originalMediaType
        self.preprocessingOutputStorageKey = preprocessingOutputStorageKey
        self.displayName = displayName
        self.previewImage = previewImage
        self.duration = duration
        self.acceptedAt = acceptedAt
        self.clientMessageID = clientMessageID
    }

    var isFileBacked: Bool { localFileURL != nil && data == nil }
    var byteLabel: String { ChatMediaBytes.label(byteCount) }

    /// The encrypted draft persists only attachments whose app-owned bytes already exist. A
    /// camera preview or security-scoped provider URL remains visible while its import runs, but
    /// cannot claim restart durability until that import has been verified by AppModel.
    var draftMediaAttachment: ConversationDraftMediaAttachment? {
        guard byteCount > 0, data != nil || localFileURL != nil else { return nil }
        let attachment = ConversationDraftMediaAttachment(
            id: id,
            storageKind: isFileBacked ? .protectedFile : .encryptedBlob,
            mediaType: mediaType,
            originalMediaType: originalMediaType,
            byteCount: byteCount,
            displayName: ConversationDraftMediaAttachment.boundedDisplayName(
                displayName,
                fallback: kind.previewLabel
            ),
            duration: duration,
            acceptedAt: acceptedAt,
            clientMessageID: clientMessageID,
            preprocessingOutputStorageKey: preprocessingOutputStorageKey
        )
        return attachment.isStructurallyValid ? attachment : nil
    }

    init(
        restored manifest: ConversationDraftMediaAttachment,
        data: Data?,
        localFileURL: URL?
    ) {
        self.id = manifest.id
        self.kind = KitChatMediaKind(mediaType: manifest.mediaType)
        self.data = data
        self.localFileURL = localFileURL
        self.byteCount = manifest.byteCount
        self.mediaType = manifest.mediaType
        self.originalMediaType = manifest.originalMediaType
        self.preprocessingOutputStorageKey = manifest.preprocessingOutputStorageKey
        self.displayName = manifest.displayName
        self.previewImage = nil
        self.duration = manifest.duration
        self.acceptedAt = manifest.acceptedAt
        self.clientMessageID = manifest.clientMessageID
    }

    func replacingDuration(_ duration: TimeInterval) -> ChatStagedAttachment {
        guard duration.isFinite, duration > 0 else { return self }
        if let localFileURL {
            return ChatStagedAttachment(
                id: id,
                kind: kind,
                localFileURL: localFileURL,
                byteCount: byteCount,
                mediaType: mediaType,
                displayName: displayName,
                previewImage: previewImage,
                duration: duration,
                acceptedAt: acceptedAt,
                clientMessageID: clientMessageID,
                originalMediaType: originalMediaType,
                preprocessingOutputStorageKey: preprocessingOutputStorageKey
            )
        }
        if let data {
            return ChatStagedAttachment(
                id: id,
                kind: kind,
                data: data,
                mediaType: mediaType,
                displayName: displayName,
                previewImage: previewImage,
                duration: duration,
                acceptedAt: acceptedAt,
                clientMessageID: clientMessageID,
                originalMediaType: originalMediaType,
                preprocessingOutputStorageKey: preprocessingOutputStorageKey
            )
        }
        return self
    }
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

    /// File-to-file export for a protected local original. This preserves bounded memory while
    /// giving share/save consumers an independently owned, correctly extended temporary path.
    static func copyTemporaryFile(
        from sourceURL: URL,
        mediaType: String,
        suggestedName: String? = nil
    ) throws -> URL {
        let base = suggestedName?
            .components(separatedBy: CharacterSet(charactersIn: "/\\:"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = base?.isEmpty == false ? base! : "kit-media-\(UUID().uuidString)"
        let ext = fileExtension(forMediaType: mediaType)
        let named = stem.lowercased().hasSuffix(".\(ext)") ? stem : "\(stem).\(ext)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kit-preview-\(UUID().uuidString)",
            isDirectory: true
        )
        let destination = directory.appendingPathComponent(named, isDirectory: false)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUnlessOpen],
            ofItemAtPath: destination.path
        )
        return destination
    }

    /// Gives AVFoundation a filename that agrees with the container bytes without copying a
    /// potentially 200 MiB received original. The source lease remains the lifetime authority;
    /// this same-volume hard link is presentation-owned and removed with its private directory.
    static func linkTemporaryFile(from sourceURL: URL, mediaType: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kit-preview-\(UUID().uuidString)",
            isDirectory: true
        )
        let destination = directory.appendingPathComponent(
            "kit-video.\(fileExtension(forMediaType: mediaType))",
            isDirectory: false
        )
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try FileManager.default.linkItem(at: sourceURL, to: destination)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
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
    var hasLoaded: Bool { loaded != nil }

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
        case .voice, .audio:
            VoiceNoteBubbleView(
                message: message,
                descriptor: descriptor,
                displayKind: KitChatMediaKind(mediaType: descriptor.mediaType)
            )
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
private struct PendingMediaPresentation: Identifiable {
    let id = UUID()
    let kind: KitChatMediaKind
    let image: UIImage?
    let fileURL: URL?
    let displayName: String
    let mediaType: String
    let byteCount: Int
    let ownsTemporaryFile: Bool
    /// Retains receiver-cache ownership until the presented video/document is dismissed.
    let protectedOriginalLease: SecureMediaOriginalAccessLease?
}

struct PendingSecureMediaMessageView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.voiceNoteChatContext) private var chatContext
    @ObservedObject private var player = VoiceNotePlayer.shared
    let message: LocalMessage
    let attachment: LocalPendingAttachment
    /// Bytes plus the MIME facts of the same authoritative identity resolution. Loaded by
    /// message identity — never from this view's captured row snapshot — so the preview and
    /// the facts shown with it can only ever be the current persisted pending attachment's.
    @State private var loaded: SecureMediaLoadPolicy.LoadedItem?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var presentedMedia: PendingMediaPresentation?

    private var kind: KitChatMediaKind {
        KitChatMediaKind(mediaType: attachment.mediaType)
    }

    private var sizeLabel: String? {
        if let byteCount = loaded?.byteCount ?? attachment.byteCount {
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

    private var mediaID: UUID {
        let matching = (message.localMediaRecords ?? []).filter { record in
            record.messageID == message.id
                && record.conversationID == message.conversationId
                && record.mediaType == attachment.mediaType
                && (attachment.byteCount.map { record.fileSize == $0 } ?? true)
        }
        return matching.count == 1
            ? UUID(uuidString: matching[0].id) ?? message.id
            : message.id
    }

    var body: some View {
        pendingContent
            .task(id: message.id) {
                guard loaded == nil, kind == .image else { return }
                await loadLocalOriginal(markPlayableWhenLoaded: true)
            }
            .onAppear {
                LocalMediaPerformanceMonitor.shared.markVisible(mediaID: mediaID)
                if kind == .voice || kind == .audio {
                    player.noteSourceVisibility(true, for: mediaID)
                }
            }
            .onDisappear {
                if kind == .voice || kind == .audio {
                    player.noteSourceVisibility(false, for: mediaID)
                }
            }
            .fullScreenCover(item: $presentedMedia) { presentation in
                Group {
                    switch presentation.kind {
                    case .image:
                        if let image = presentation.image {
                            MediaImageViewer(image: image)
                        }
                    case .video:
                        if let fileURL = presentation.fileURL {
                            MediaVideoPlayerView(
                                fileURL: fileURL,
                                mediaType: presentation.mediaType,
                                expectedByteCount: presentation.byteCount,
                                protectedOriginalLease: presentation.protectedOriginalLease
                            ) { closePresentation() }
                        }
                    case .document:
                        if let fileURL = presentation.fileURL {
                            KitDocumentViewerView(
                                fileURL: fileURL,
                                displayName: presentation.displayName,
                                mediaType: presentation.mediaType,
                                byteCount: presentation.byteCount,
                                onClose: { closePresentation() }
                            )
                        }
                    case .voice, .audio:
                        EmptyView()
                    }
                }
                .onDisappear {
                    if presentation.ownsTemporaryFile {
                        ChatMediaTempFiles.removeTemporaryFile(presentation.fileURL)
                    }
                }
            }
    }

    @ViewBuilder
    private var pendingContent: some View {
        if let loaded,
           KitChatMediaKind(mediaType: loaded.mediaType) == .image,
           let image = loaded.downsampledImage(maximumPixelSize: 2_048) {
            Button {
                LocalMediaPerformanceMonitor.shared.markPlayable(mediaID: mediaID)
                presentedMedia = PendingMediaPresentation(
                    kind: .image,
                    image: image,
                    fileURL: nil,
                    displayName: title,
                    mediaType: loaded.mediaType,
                    byteCount: loaded.byteCount,
                    ownsTemporaryFile: false,
                    protectedOriginalLease: nil
                )
            } label: {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 224, height: 168)
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("End-to-end encrypted photo queued to send")
        } else {
            Button {
                Task { await openLocalOriginal() }
            } label: {
                HStack(spacing: 11) {
                    ZStack {
                        Image(systemName: pendingSymbol)
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(message.isOutgoing ? .white : KitColor.green)
                        if isLoading {
                            ProgressView()
                                .tint(message.isOutgoing ? .white : KitColor.green)
                        }
                    }
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
                        Text(errorMessage ?? pendingSubtitle)
                            .font(.caption)
                            .foregroundStyle(
                                message.isOutgoing
                                    ? .white.opacity(0.72)
                                    : KitColor.secondaryText
                            )
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "End-to-end encrypted \(kind.previewLabel.lowercased()) queued to send"
            )
        }
    }

    private var pendingSymbol: String {
        guard kind == .voice || kind == .audio,
              player.playingID == mediaID,
              !player.isPaused
        else { return (kind == .voice || kind == .audio) ? "play.fill" : kind.symbolName }
        return "pause.fill"
    }

    private var pendingSubtitle: String {
        let size = sizeLabel ?? "Saved locally"
        if kind == .voice || kind == .audio,
           let duration = message.localMediaRecords?.first(where: { $0.id == mediaID.uuidString.lowercased() })?.duration {
            let seconds = Int(duration.rounded())
            return "Queued · \(seconds / 60):\(String(format: "%02d", seconds % 60)) · \(size)"
        }
        return "Queued · \(size)"
    }

    private func loadLocalOriginal(markPlayableWhenLoaded: Bool = false) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        guard let fresh = await model.loadPendingMedia(
            messageID: message.id,
            conversationId: message.conversationId
        ) else {
            loaded = nil
            errorMessage = "Local copy unavailable"
            return
        }
        loaded = fresh
        if markPlayableWhenLoaded,
           KitChatMediaKind(mediaType: fresh.mediaType) == .image,
           fresh.downsampledImage(maximumPixelSize: 256) != nil {
            LocalMediaPerformanceMonitor.shared.markPlayable(mediaID: mediaID)
        }
    }

    private func openLocalOriginal() async {
        if kind == .voice || kind == .audio,
           let playback = await model.loadPendingVoicePlayback(
               messageID: message.id,
               conversationId: message.conversationId
           ) {
            player.toggle(
                fileURLs: playback.fileURLs,
                segmentDurations: playback.segmentDurations,
                id: mediaID,
                context: chatContext.playbackContext(senderUserID: message.senderId)
            )
            guard player.playingID == mediaID else {
                errorMessage = "Voice note unavailable"
                return
            }
            LocalMediaPerformanceMonitor.shared.markPlayable(mediaID: mediaID)
            return
        }
        if kind == .video || kind == .document || kind == .voice || kind == .audio,
           let localFile = await model.loadProtectedLocalMediaFile(
               messageID: message.id,
               conversationId: message.conversationId,
               itemIndex: nil
           ) {
            if kind == .voice || kind == .audio {
                player.toggle(
                    fileURL: localFile.url,
                    id: mediaID,
                    context: chatContext.playbackContext(senderUserID: message.senderId),
                    protectedOriginalLease: localFile.accessLease
                )
                guard player.playingID == mediaID else {
                    errorMessage = "Voice note unavailable"
                    return
                }
            } else {
                presentedMedia = PendingMediaPresentation(
                    kind: kind,
                    image: nil,
                    fileURL: localFile.url,
                    displayName: localFile.caption ?? title,
                    mediaType: localFile.mediaType,
                    byteCount: localFile.byteCount,
                    ownsTemporaryFile: false,
                    protectedOriginalLease: localFile.accessLease
                )
            }
            LocalMediaPerformanceMonitor.shared.markPlayable(mediaID: mediaID)
            return
        }
        await loadLocalOriginal()
        guard let loaded else { return }
        switch KitChatMediaKind(mediaType: loaded.mediaType) {
        case .image:
            guard let image = loaded.downsampledImage(maximumPixelSize: 4_096) else {
                errorMessage = "Local copy unavailable"
                return
            }
            presentedMedia = PendingMediaPresentation(
                kind: .image,
                image: image,
                fileURL: nil,
                displayName: title,
                mediaType: loaded.mediaType,
                byteCount: loaded.byteCount,
                ownsTemporaryFile: false,
                protectedOriginalLease: nil
            )
        case .voice, .audio:
            if let fileURL = loaded.localFileURL {
                player.toggle(
                    fileURL: fileURL,
                    id: mediaID,
                    context: chatContext.playbackContext(senderUserID: message.senderId),
                    protectedOriginalLease: loaded.localFileLease
                )
            } else {
                player.toggle(
                    data: loaded.data,
                    id: mediaID,
                    context: chatContext.playbackContext(senderUserID: message.senderId)
                )
            }
            guard player.playingID == mediaID else {
                errorMessage = "Voice note unavailable"
                return
            }
        case .video, .document:
            let ownsTemporaryFile = loaded.localFileURL == nil
            let url = loaded.localFileURL ?? (try? ChatMediaTempFiles.writeTemporaryFile(
                data: loaded.data,
                mediaType: loaded.mediaType,
                suggestedName: kind == .document ? attachment.caption : nil
            ))
            guard let url else {
                errorMessage = "Local copy unavailable"
                return
            }
            presentedMedia = PendingMediaPresentation(
                kind: kind,
                image: nil,
                fileURL: url,
                displayName: attachment.caption ?? title,
                mediaType: loaded.mediaType,
                byteCount: loaded.byteCount,
                ownsTemporaryFile: ownsTemporaryFile,
                protectedOriginalLease: loaded.localFileLease
            )
        }
        LocalMediaPerformanceMonitor.shared.markPlayable(mediaID: mediaID)
    }

    private func closePresentation() {
        if presentedMedia?.ownsTemporaryFile == true {
            ChatMediaTempFiles.removeTemporaryFile(presentedMedia?.fileURL)
        }
        presentedMedia = nil
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
    @State private var localPresentation: SecureMediaLoadPolicy.LocalFileItem?
    @State private var ownsPresentationURL = false

    private var kind: KitChatMediaKind { KitChatMediaKind(mediaType: mediaType) }

    private var voiceNoteID: UUID {
        UUID(uuidString: attachmentID) ?? message.id
    }

    /// Photos fetch themselves for immediate visual rendering. Audio, video and documents wait
    /// for a tap even while pending: their read is local, but eagerly decrypting as many as eight
    /// 200 MB originals merely to draw a bubble would defeat the background-throughput goal.
    private var loadsAutomatically: Bool {
        kind == .image
    }

    private var accessibilityPosition: String {
        "item \(itemIndex + 1) of \(itemCount)"
    }

    var body: some View {
        itemContent
            .onAppear {
                if let id = UUID(uuidString: attachmentID) {
                    LocalMediaPerformanceMonitor.shared.markVisible(mediaID: id)
                }
            }
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
                if kind == .image,
                   loader.loaded?.downsampledImage(maximumPixelSize: 256) != nil,
                   let id = UUID(uuidString: attachmentID) {
                    LocalMediaPerformanceMonitor.shared.markPlayable(mediaID: id)
                }
            }
    }

    @ViewBuilder
    private var itemContent: some View {
        switch kind {
        case .image:
            imageCell
        case .voice, .audio:
            voiceRow
        case .video, .document:
            fileRow
        }
    }

    @ViewBuilder
    private var imageCell: some View {
        if let image = loader.loaded?.downsampledImage(maximumPixelSize: 1_024) {
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
                              ), fresh.downsampledImage(maximumPixelSize: 256) != nil else { return }
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
                title: kind.previewLabel,
                subtitle: subtitleLabel
            )
        }
        .buttonStyle(.plain)
        .disabled(loader.isLoading)
        .accessibilityLabel(
            "End-to-end encrypted \(kind.previewLabel.lowercased()), \(accessibilityPosition)"
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
                let mediaType = localPresentation?.mediaType ?? loader.loaded?.mediaType
                let byteCount = localPresentation?.byteCount ?? loader.loaded?.byteCount
                if let mediaType, let byteCount {
                    MediaVideoPlayerView(
                        fileURL: playbackURL,
                        mediaType: mediaType,
                        expectedByteCount: byteCount,
                        protectedOriginalLease:
                            localPresentation?.accessLease ?? loader.loaded?.localFileLease
                    ) { closePresentation() }
                }
            } else if let documentURL {
                let mediaType = localPresentation?.mediaType ?? loader.loaded?.mediaType
                let byteCount = localPresentation?.byteCount ?? loader.loaded?.byteCount
                // Viewer facts from the same fresh resolution that produced the temp file —
                // never the item fields this bubble captured at render time.
                if let mediaType, let byteCount {
                    KitDocumentViewerView(
                        fileURL: documentURL,
                        displayName: presentedDisplayName(mediaType: mediaType),
                        mediaType: mediaType,
                        byteCount: byteCount,
                        onClose: { closePresentation() }
                    )
                }
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
        let bytes = localPresentation?.byteCount ?? loader.loaded?.byteCount ?? plaintextByteSize
        if isPending { return "Queued · \(ChatMediaBytes.label(bytes))" }
        return ChatMediaBytes.label(bytes)
    }

    /// Every play/pause tap re-proves the row — account, current persisted row, full
    /// projection — with a fresh resolution before any plaintext reaches the player;
    /// previously loaded UI state never services it. If the row no longer resolves, a note
    /// still playing under this identity is stopped rather than left presenting stale audio.
    private func refreshThenPlay() async {
        guard !loader.isLoading else { return }
        if let localFile = await model.loadProtectedLocalMediaFile(
            messageID: message.id,
            conversationId: message.conversationId,
            itemIndex: itemIndex
        ) {
            player.toggle(
                fileURL: localFile.url,
                id: voiceNoteID,
                context: chatContext.playbackContext(senderUserID: message.senderId),
                protectedOriginalLease: localFile.accessLease
            )
            if player.playingID == voiceNoteID {
                LocalMediaPerformanceMonitor.shared.markPlayable(mediaID: voiceNoteID)
            }
            return
        }
        guard let fresh = await loader.refreshForPresentation(
            model: model,
            messageID: message.id,
            conversationId: message.conversationId,
            itemIndex: itemIndex
        ) else {
            if player.playingID == voiceNoteID { player.stop() }
            return
        }
        if let fileURL = fresh.localFileURL {
            player.toggle(
                fileURL: fileURL,
                id: voiceNoteID,
                context: chatContext.playbackContext(senderUserID: message.senderId),
                protectedOriginalLease: fresh.localFileLease
            )
        } else {
            player.toggle(
                data: fresh.data,
                id: voiceNoteID,
                context: chatContext.playbackContext(senderUserID: message.senderId)
            )
        }
        if player.playingID == voiceNoteID {
            LocalMediaPerformanceMonitor.shared.markPlayable(mediaID: voiceNoteID)
        }
    }

    private func refreshThenPresent() async {
        guard !loader.isLoading else { return }
        if let localFile = await model.loadProtectedLocalMediaFile(
            messageID: message.id,
            conversationId: message.conversationId,
            itemIndex: itemIndex
        ) {
            localPresentation = localFile
            if kind == .video {
                playbackURL = localFile.url
            } else {
                documentURL = localFile.url
            }
            ownsPresentationURL = false
            if let id = UUID(uuidString: localFile.attachmentID) {
                LocalMediaPerformanceMonitor.shared.markPlayable(mediaID: id)
            }
            return
        }
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
        let url = item.localFileURL ?? (try? ChatMediaTempFiles.writeTemporaryFile(
            data: item.data,
            mediaType: item.mediaType,
            suggestedName: presentedKind == .document
                ? presentedDisplayName(mediaType: item.mediaType)
                : nil
        ))
        if presentedKind == .video {
            playbackURL = url
        } else {
            documentURL = url
        }
        ownsPresentationURL = url != nil && item.localFileURL == nil
        if url != nil, let id = UUID(uuidString: attachmentID) {
            LocalMediaPerformanceMonitor.shared.markPlayable(mediaID: id)
        }
    }

    private func closePresentation() {
        if ownsPresentationURL {
            ChatMediaTempFiles.removeTemporaryFile(playbackURL ?? documentURL)
        }
        playbackURL = nil
        documentURL = nil
        localPresentation = nil
        ownsPresentationURL = false
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
        // The loader resolves the current persisted row first. Protected originals and receiver
        // cache files downsample directly from disk; legacy inline blobs keep the data path.
        guard let loaded = loader.loaded else { return nil }
        if let localFileURL = loaded.localFileURL {
            return ChatMediaThumbnailStore.shared.thumbnail(
                forKey: descriptor.storageKey,
                maxPixel: 1_024,
                fromFileURL: localFileURL
            )
        }
        return ChatMediaThumbnailStore.shared.thumbnail(
            forKey: descriptor.storageKey,
            maxPixel: 1_024,
            from: loaded.data
        )
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
                                      ), fresh.downsampledImage(maximumPixelSize: 256) != nil else {
                                    return
                                }
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
        .onAppear {
            if let id = UUID(uuidString: descriptor.attachmentID) {
                LocalMediaPerformanceMonitor.shared.markVisible(mediaID: id)
            }
        }
        .task(id: "\(descriptor.storageKey):\(model.isOnline):\(retryGeneration)") {
            guard image == nil else { return }
            await loader.load(
                model: model,
                messageID: message.id,
                conversationId: message.conversationId,
                itemIndex: nil
            )
            if image != nil, let id = UUID(uuidString: descriptor.attachmentID) {
                LocalMediaPerformanceMonitor.shared.markPlayable(mediaID: id)
            }
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
    let displayKind: KitChatMediaKind
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
            .accessibilityLabel(
                isPlaying
                    ? "Pause \(displayKind.previewLabel.lowercased())"
                    : "Play \(displayKind.previewLabel.lowercased())"
            )

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
                .accessibilityLabel("\(displayKind.previewLabel) position")
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
        .accessibilityLabel("End-to-end encrypted \(displayKind.previewLabel.lowercased())")
        .task(id: "\(descriptor.storageKey):\(model.isOnline)") {
            guard !loader.hasLoaded else { return }
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
        if let localFile = await model.loadProtectedLocalMediaFile(
            messageID: message.id,
            conversationId: message.conversationId,
            itemIndex: nil
        ) {
            player.toggle(
                fileURL: localFile.url,
                id: message.id,
                context: playbackContext,
                protectedOriginalLease: localFile.accessLease
            )
            if player.playingID == message.id,
               let id = UUID(uuidString: localFile.attachmentID) {
                LocalMediaPerformanceMonitor.shared.markPlayable(mediaID: id)
            }
            return
        }
        guard let fresh = await loader.refreshForPresentation(
            model: model,
            messageID: message.id,
            conversationId: message.conversationId,
            itemIndex: nil
        ) else {
            if isCurrent { player.stop() }
            return
        }
        if let fileURL = fresh.localFileURL {
            player.toggle(
                fileURL: fileURL,
                id: message.id,
                context: playbackContext,
                protectedOriginalLease: fresh.localFileLease
            )
        } else {
            player.toggle(data: fresh.data, id: message.id, context: playbackContext)
        }
        if player.playingID == message.id,
           let id = UUID(uuidString: descriptor.attachmentID) {
            LocalMediaPerformanceMonitor.shared.markPlayable(mediaID: id)
        }
    }

    private var subtitle: String {
        if isCurrent, player.duration > 0 {
            let remaining = max(0, player.duration * (1 - player.progress))
            return durationLabel(remaining)
        }
        if let errorMessage = loader.errorMessage { return errorMessage }
        if !loader.hasLoaded { return ChatMediaBytes.label(descriptor.plaintextByteSize) }
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
    @State private var ownsPlaybackURL = false
    @State private var protectedOriginalLease: SecureMediaOriginalAccessLease?
    @State private var playbackMediaType: String?
    @State private var playbackByteCount: Int?

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
            if let localFile = await model.loadProtectedLocalMediaFile(
                messageID: message.id,
                conversationId: message.conversationId,
                itemIndex: nil
            ) {
                await makePoster(fileURL: localFile.url)
                return
            }
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
            if let playbackURL, let playbackMediaType, let playbackByteCount {
                MediaVideoPlayerView(
                    fileURL: playbackURL,
                    mediaType: playbackMediaType,
                    expectedByteCount: playbackByteCount,
                    protectedOriginalLease: protectedOriginalLease
                ) { closePlayer() }
            }
        }
    }

    private var subtitle: String {
        if let errorMessage = loader.errorMessage { return errorMessage }
        if loader.isLoading { return "Decrypting…" }
        if !loader.hasLoaded {
            return ChatMediaBytes.label(descriptor.plaintextByteSize)
        }
        return "Play"
    }

    /// A tap presents playback: re-prove the row — account, current persisted row, full
    /// projection — with a fresh resolution and present exactly that result; previously loaded
    /// UI state never services it.
    private func refreshThenPresent() async {
        guard !loader.isLoading else { return }
        if let localFile = await model.loadProtectedLocalMediaFile(
            messageID: message.id,
            conversationId: message.conversationId,
            itemIndex: nil
        ) {
            await makePoster(fileURL: localFile.url)
            protectedOriginalLease = localFile.accessLease
            playbackURL = localFile.url
            playbackMediaType = localFile.mediaType
            playbackByteCount = localFile.byteCount
            ownsPlaybackURL = false
            if let id = UUID(uuidString: localFile.attachmentID) {
                LocalMediaPerformanceMonitor.shared.markPlayable(mediaID: id)
            }
            return
        }
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
        playbackURL = item.localFileURL ?? (try? ChatMediaTempFiles.writeTemporaryFile(
            data: item.data,
            mediaType: item.mediaType
        ))
        protectedOriginalLease = item.localFileLease
        playbackMediaType = item.mediaType
        playbackByteCount = item.byteCount
        ownsPlaybackURL = playbackURL != nil && item.localFileURL == nil
        if playbackURL != nil, let id = UUID(uuidString: descriptor.attachmentID) {
            LocalMediaPerformanceMonitor.shared.markPlayable(mediaID: id)
        }
    }

    private func closePlayer() {
        if ownsPlaybackURL { ChatMediaTempFiles.removeTemporaryFile(playbackURL) }
        playbackURL = nil
        ownsPlaybackURL = false
        protectedOriginalLease = nil
        playbackMediaType = nil
        playbackByteCount = nil
    }

    private func makePoster(from item: SecureMediaLoadPolicy.LoadedItem) async {
        guard poster == nil else { return }
        if let localFileURL = item.localFileURL {
            await makePoster(fileURL: localFileURL)
            return
        }
        poster = await ChatMediaThumbnailStore.shared.videoThumbnail(
            forKey: descriptor.storageKey,
            maxPixel: 248,
            from: item.data,
            mediaType: item.mediaType
        )
    }

    private func makePoster(fileURL: URL) async {
        guard poster == nil else { return }
        poster = await ChatMediaThumbnailStore.shared.videoThumbnail(
            forKey: descriptor.storageKey,
            maxPixel: 248,
            fromFileURL: fileURL
        )
    }
}

struct MediaVideoPlayerView: View {
    let fileURL: URL
    let mediaType: String
    let expectedByteCount: Int
    let protectedOriginalLease: SecureMediaOriginalAccessLease?
    let onClose: () -> Void
    @StateObject private var playback = MediaVideoPlaybackController()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if playback.isPreparing {
                ProgressView("Preparing video…")
                    .tint(.white)
                    .foregroundStyle(.white)
            } else if let errorMessage = playback.errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 30, weight: .semibold))
                    Text(errorMessage)
                        .font(.body.weight(.semibold))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white)
                .padding(32)
            } else if let player = playback.player {
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
        .task(id: fileURL) {
            await playback.start(
                fileURL: fileURL,
                mediaType: mediaType,
                expectedByteCount: expectedByteCount,
                protectedOriginalLease: protectedOriginalLease
            )
        }
        .onDisappear { playback.stop() }
    }
}

/// Owns the simple single-video viewer's complete playback graph. In particular, the protected
/// receiver-cache lease lives beside the asset/item/player rather than in an ancestor SwiftUI
/// value whose destruction order AVFoundation cannot control.
@MainActor
private final class MediaVideoPlaybackController: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var isPreparing = false
    @Published private(set) var errorMessage: String?

    private var sourceFileURL: URL?
    private var temporaryAliasURL: URL?
    private var asset: AVURLAsset?
    private var playerItem: AVPlayerItem?
    private var protectedOriginalLease: SecureMediaOriginalAccessLease?
    private var playbackFileHandle: FileHandle?
    private var intendsToPlay = false
    private var endObserver: NSObjectProtocol?
    private var stallObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var preparationID: UUID?

    func start(
        fileURL: URL,
        mediaType: String,
        expectedByteCount: Int,
        protectedOriginalLease: SecureMediaOriginalAccessLease?
    ) async {
        guard player == nil, !isPreparing else { return }
        let identifier = UUID()
        preparationID = identifier
        sourceFileURL = fileURL
        self.protectedOriginalLease = protectedOriginalLease
        guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else {
            failPreparation(ChatVideoPlaybackPreparationError.invalidFile)
            return
        }
        playbackFileHandle = fileHandle
        isPreparing = true
        errorMessage = nil
        intendsToPlay = true
        do {
            let prepared = try await ChatVideoPlaybackAssetPolicy.prepare(
                fileURL: fileURL,
                declaredMediaType: mediaType,
                expectedByteCount: expectedByteCount
            )
            guard !Task.isCancelled,
                  preparationID == identifier,
                  sourceFileURL == fileURL
            else {
                ChatMediaTempFiles.removeTemporaryFile(prepared.temporaryAliasURL)
                return
            }
            temporaryAliasURL = prepared.temporaryAliasURL
            asset = prepared.asset
            let item = AVPlayerItem(asset: prepared.asset)
            playerItem = item
            let player = AVPlayer(playerItem: item)
            player.automaticallyWaitsToMinimizeStalling = true
            self.player = player
            observePlaybackItem(item)
            isPreparing = false
            player.play()
        } catch {
            guard preparationID == identifier else { return }
            failPreparation(error)
        }
    }

    func stop() {
        preparationID = nil
        isPreparing = false
        intendsToPlay = false
        removePlaybackItemObservers()
        player?.pause()
        player = nil
        playerItem = nil
        asset = nil
        if let playbackFileHandle {
            try? playbackFileHandle.close()
        }
        playbackFileHandle = nil
        ChatMediaTempFiles.removeTemporaryFile(temporaryAliasURL)
        temporaryAliasURL = nil
        sourceFileURL = nil
        protectedOriginalLease = nil
    }

    private func observePlaybackItem(_ item: AVPlayerItem) {
        removePlaybackItemObservers()
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.intendsToPlay = false }
        }
        stallObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleInterruption(.stalled, item: item)
            }
        }
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleInterruption(.failed, item: item)
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

    private func handleInterruption(
        _ interruption: ChatVideoPlaybackFailurePolicy.Interruption,
        item: AVPlayerItem
    ) {
        guard intendsToPlay, playerItem === item else { return }
        switch ChatVideoPlaybackFailurePolicy.action(for: interruption) {
        case .letPlayerRecover:
            // AVFoundation may resume an ordinary decoder stall itself. The controller never
            // mutates the live item from inside its notification callback.
            break
        case .stopAndReport:
            intendsToPlay = false
            player?.pause()
            errorMessage = "This video could not be played completely."
        }
    }

    private func failPreparation(_ error: Error) {
        isPreparing = false
        intendsToPlay = false
        errorMessage = (error as? LocalizedError)?.errorDescription
            ?? "This video could not be played."
        if let playbackFileHandle { try? playbackFileHandle.close() }
        playbackFileHandle = nil
        protectedOriginalLease = nil
        sourceFileURL = nil
    }
}

// MARK: - Document

struct DocumentMessageBubbleView: View {
    @EnvironmentObject private var model: AppModel
    let message: LocalMessage
    let descriptor: KitMediaMessageDescriptor
    @StateObject private var loader = SecureMediaLoader()
    @State private var previewURL: URL?
    @State private var localPresentation: SecureMediaLoadPolicy.LocalFileItem?
    @State private var ownsPreviewURL = false

    /// Before bytes exist the row label comes from the parse-gated bubble descriptor; once a
    /// fresh resolution has loaded, every fact tracks that result instead.
    private var fileName: String {
        if let localPresentation {
            return Self.fileName(
                caption: localPresentation.caption,
                mediaType: localPresentation.mediaType
            )
        }
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
            if let previewURL {
                let mediaType = localPresentation?.mediaType ?? loader.loaded?.mediaType
                let caption = localPresentation?.caption ?? loader.loaded?.caption
                let byteCount = localPresentation?.byteCount ?? loader.loaded?.byteCount
                // Viewer facts from the same fresh resolution that produced the temp file —
                // never the descriptor this bubble captured at render time.
                if let mediaType, let byteCount {
                    KitDocumentViewerView(
                        fileURL: previewURL,
                        displayName: Self.fileName(caption: caption, mediaType: mediaType),
                        mediaType: mediaType,
                        byteCount: byteCount,
                        onClose: { closePreview() }
                    )
                }
            }
        }
    }

    private var subtitle: String {
        if let errorMessage = loader.errorMessage { return errorMessage }
        if loader.isLoading { return "Decrypting…" }
        // Once loaded, the size fact tracks the resolved bytes, not the captured descriptor.
        return ChatMediaBytes.label(
            localPresentation?.byteCount
                ?? loader.loaded?.byteCount
                ?? descriptor.plaintextByteSize
        )
    }

    /// A tap presents the preview: re-prove the row — account, current persisted row, full
    /// projection — with a fresh resolution and present exactly that result; previously loaded
    /// UI state never services it.
    private func refreshThenPresent() async {
        guard !loader.isLoading else { return }
        if let localFile = await model.loadProtectedLocalMediaFile(
            messageID: message.id,
            conversationId: message.conversationId,
            itemIndex: nil
        ) {
            localPresentation = localFile
            previewURL = localFile.url
            ownsPreviewURL = false
            if let id = UUID(uuidString: localFile.attachmentID) {
                LocalMediaPerformanceMonitor.shared.markPlayable(mediaID: id)
            }
            return
        }
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
        previewURL = item.localFileURL ?? (try? ChatMediaTempFiles.writeTemporaryFile(
            data: item.data,
            mediaType: item.mediaType,
            suggestedName: Self.fileName(caption: item.caption, mediaType: item.mediaType)
        ))
        ownsPreviewURL = previewURL != nil && item.localFileURL == nil
        if previewURL != nil, let id = UUID(uuidString: descriptor.attachmentID) {
            LocalMediaPerformanceMonitor.shared.markPlayable(mediaID: id)
        }
    }

    private func closePreview() {
        if ownsPreviewURL { ChatMediaTempFiles.removeTemporaryFile(previewURL) }
        previewURL = nil
        localPresentation = nil
        ownsPreviewURL = false
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
