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
    /// Shown in the staging chip; doubles as the caption for documents so the
    /// filename survives the v1 wire format.
    let displayName: String
    let previewImage: UIImage?
    /// Shares retained in the app-group inbox reuse their source UUID across retries. Ordinary
    /// camera/library attachments leave this nil and receive the queue's usual fresh identifier.
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
    /// preview; callers remove it when the preview closes.
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
        try data.write(to: url, options: [.atomic, .completeFileProtection])
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
    @Published var data: Data?
    @Published var isLoading = false
    @Published var errorMessage: String?

    func load(
        model: AppModel,
        conversationId: String,
        descriptorText: String
    ) async {
        guard data == nil, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            data = try await model.loadSecureMedia(
                conversationId: conversationId,
                descriptorText: descriptorText
            )
        } catch {
            errorMessage = model.isOnline ? "Tap to retry" : "Available when online"
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
    /// Plaintext for large media parked in the encrypted file cache instead of inline.
    @State private var parkedData: Data?

    private var kind: KitChatMediaKind {
        KitChatMediaKind(mediaType: attachment.mediaType)
    }

    private var mediaData: Data? {
        message.attachmentData ?? parkedData
    }

    private var sizeLabel: String? {
        if let byteCount = mediaData?.count ?? attachment.byteCount {
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
                guard mediaData == nil, kind == .image,
                      attachment.localStorageKey != nil else { return }
                parkedData = await model.loadPendingMedia(for: message)
            }
    }

    @ViewBuilder
    private var pendingContent: some View {
        if kind == .image,
           let data = mediaData,
           let image = UIImage(data: data) {
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
        (loader.data ?? message.attachmentData).flatMap(UIImage.init(data:))
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
                            showsViewer = true
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
                conversationId: message.conversationId,
                descriptorText: message.body
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
    @State private var retryGeneration = 0
    /// Fraction playback was at when the current slide began, so a slide moves the note relative
    /// to where the finger went down instead of jumping to it.
    @State private var scrubOrigin: Double?

    private var data: Data? { loader.data ?? message.attachmentData }
    private var isCurrent: Bool { player.playingID == message.id }
    private var isPlaying: Bool { isCurrent && !player.isPaused }
    private var accent: Color { message.isOutgoing ? .white : KitColor.green }

    private var playbackContext: VoiceNotePlaybackContext {
        chatContext.playbackContext(senderUserID: message.senderId)
    }

    var body: some View {
        HStack(spacing: 11) {
            Button {
                if let data {
                    player.toggle(data: data, id: message.id, context: playbackContext)
                } else {
                    retryGeneration &+= 1
                }
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
        .task(id: "\(descriptor.storageKey):\(model.isOnline):\(retryGeneration)") {
            guard data == nil else { return }
            await loader.load(
                model: model,
                conversationId: message.conversationId,
                descriptorText: message.body
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
                    if !isCurrent {
                        guard let data else { return }
                        player.toggle(data: data, id: message.id, context: playbackContext)
                    }
                    player.seek(toFraction: fraction)
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
            } else if let data = loader.data ?? message.attachmentData {
                present(data: data)
            } else {
                Task { await load() }
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
            if let data = message.attachmentData ?? loader.data {
                await makePoster(from: data)
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
        if loader.data == nil && message.attachmentData == nil {
            return ChatMediaBytes.label(descriptor.plaintextByteSize)
        }
        return "Play"
    }

    private func load() async {
        await loader.load(
            model: model,
            conversationId: message.conversationId,
            descriptorText: message.body
        )
        if let data = loader.data {
            await makePoster(from: data)
            present(data: data)
        }
    }

    private func present(data: Data) {
        guard playbackURL == nil else { return }
        playbackURL = try? ChatMediaTempFiles.writeTemporaryFile(
            data: data,
            mediaType: descriptor.mediaType
        )
    }

    private func closePlayer() {
        ChatMediaTempFiles.removeTemporaryFile(playbackURL)
        playbackURL = nil
    }

    private func makePoster(from data: Data) async {
        guard poster == nil,
              let url = try? ChatMediaTempFiles.writeTemporaryFile(
                  data: data,
                  mediaType: descriptor.mediaType
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
    @State private var player: AVPlayer?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            }
            Button {
                player?.pause()
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
            let player = AVPlayer(url: fileURL)
            self.player = player
            player.play()
        }
        .onDisappear { player?.pause() }
    }
}

// MARK: - Document

struct DocumentMessageBubbleView: View {
    @EnvironmentObject private var model: AppModel
    let message: LocalMessage
    let descriptor: KitMediaMessageDescriptor
    @StateObject private var loader = SecureMediaLoader()
    @State private var previewURL: URL?

    private var fileName: String {
        descriptor.caption?.isEmpty == false
            ? descriptor.caption!
            : "Document.\(ChatMediaTempFiles.fileExtension(forMediaType: descriptor.mediaType))"
    }

    var body: some View {
        Button {
            if let data = loader.data ?? message.attachmentData {
                present(data: data)
            } else {
                Task { await load() }
            }
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
                KitDocumentViewerView(
                    fileURL: previewURL,
                    displayName: fileName,
                    mediaType: descriptor.mediaType,
                    byteCount: descriptor.plaintextByteSize,
                    onClose: { closePreview() }
                )
            }
        }
    }

    private var subtitle: String {
        if let errorMessage = loader.errorMessage { return errorMessage }
        if loader.isLoading { return "Decrypting…" }
        return ChatMediaBytes.label(descriptor.plaintextByteSize)
    }

    private func load() async {
        await loader.load(
            model: model,
            conversationId: message.conversationId,
            descriptorText: message.body
        )
        if let data = loader.data {
            present(data: data)
        }
    }

    private func present(data: Data) {
        guard previewURL == nil else { return }
        previewURL = try? ChatMediaTempFiles.writeTemporaryFile(
            data: data,
            mediaType: descriptor.mediaType,
            suggestedName: fileName
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
