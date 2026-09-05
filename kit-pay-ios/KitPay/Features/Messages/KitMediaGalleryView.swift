import AVFoundation
import Photos
import SwiftUI
import UIKit

// MARK: - Gallery item

/// One visual-media item (image or video) shown by the unified full-screen gallery.
///
/// A KITMEDIA1 message contributes one entry; a KITMEDIA2 message contributes one entry per
/// visual item — same `messageID`, distinct `itemIndex` — while remaining one logical message.
/// Entries carry identity and display facts only, never descriptor text: a descriptor holds
/// attachment key material, so loaders re-read the persisted row by identity instead.
struct KitGalleryItem: Identifiable, Equatable {
    let messageID: UUID
    /// Runtime-only attachment identity used to correlate local diagnostics; never exported.
    let mediaID: UUID
    /// Index into the KITMEDIA2 descriptor's display-ordered items; nil for KITMEDIA1.
    let itemIndex: Int?
    let conversationID: String
    let mediaType: String
    let plaintextByteSize: Int
    /// Opaque thumbnail-store key (the item's storage key); carries no key material.
    let thumbnailKey: String
    let isOutgoing: Bool
    let createdAt: Date
    let senderName: String

    var id: String {
        itemIndex.map { "\(messageID.uuidString):\($0)" } ?? messageID.uuidString
    }
}

// MARK: - Gallery view

/// Unified full-screen media pager for a conversation's photos and videos.
///
/// Pages horizontally through `items`, preloading the current page's neighbors, with
/// pinch-to-zoom images, minimal custom video controls, tap-to-hide chrome, and
/// drag-down-to-dismiss (when not zoomed).
struct KitMediaGalleryView: View {
    /// Chronological; images and videos only.
    let items: [KitGalleryItem]
    let initialItemID: UUID
    /// Opens a specific item of a multi-attachment message; nil lands on the message's
    /// first visual entry.
    let initialItemIndex: Int?
    /// Loads decrypted plaintext for an item (cache-first upstream) together with the
    /// MIME/caption facts of the same authoritative resolution — render, temp-file, save, and
    /// share decisions must use those returned facts, never the constructed item's captured
    /// fields. Throws on failure.
    let loadData: (KitGalleryItem) async throws -> SecureMediaLoadPolicy.LoadedItem
    /// Reuses the duration already loaded by playback preparation instead of starting a second
    /// AVURLAsset metadata probe for a received video.
    let persistVideoDuration: (UUID, TimeInterval) async -> Void
    /// Optional 'Show in chat' action; gallery dismisses itself first, then calls this.
    let showInChat: ((KitGalleryItem) -> Void)?
    /// Reopens the conversation gallery at the handed-off video — the exact (message, item)
    /// identity, so item 3 of a multi-attachment message restores to item 3 — when the system
    /// PiP window asks to restore. This closure is bound to that video at attach time, not kept
    /// as mutable global state that a later conversation could overwrite.
    let restoreFromPictureInPicture: (ChatVideoGalleryIdentity) -> Void
    let onDismiss: () -> Void

    @StateObject private var loader = GalleryPageLoader()
    @State private var selection: Int
    @State private var chromeVisible = true
    @State private var currentPageIsZoomed = false
    @State private var dismissDrag: CGFloat = 0
    @State private var isDragDismissing = false
    @State private var shareURL: URL?
    @State private var isPreparingShare = false
    @State private var toastText: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        items: [KitGalleryItem],
        initialItemID: UUID,
        initialItemIndex: Int? = nil,
        loadData: @escaping (KitGalleryItem) async throws -> SecureMediaLoadPolicy.LoadedItem,
        persistVideoDuration: @escaping (UUID, TimeInterval) async -> Void,
        showInChat: ((KitGalleryItem) -> Void)?,
        restoreFromPictureInPicture: @escaping (ChatVideoGalleryIdentity) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.items = items
        self.initialItemID = initialItemID
        self.initialItemIndex = initialItemIndex
        self.loadData = loadData
        self.persistVideoDuration = persistVideoDuration
        self.showInChat = showInChat
        self.restoreFromPictureInPicture = restoreFromPictureInPicture
        self.onDismiss = onDismiss
        _selection = State(
            initialValue: items.firstIndex(where: {
                $0.messageID == initialItemID && $0.itemIndex == initialItemIndex
            })
                ?? items.firstIndex(where: { $0.messageID == initialItemID })
                ?? 0
        )
    }

    private var currentItem: KitGalleryItem? {
        items.indices.contains(selection) ? items[selection] : nil
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(backdropOpacity)
                .ignoresSafeArea()

            pager
                .offset(y: dismissDrag)

            if chromeVisible {
                chrome
                    .transition(reduceMotion ? .identity : .opacity)
            }

            if let toastText {
                toast(toastText)
            }
        }
        .statusBarHidden(true)
        .preferredColorScheme(.dark)
        .task {
            loader.configure(loadData)
            preload(around: selection)
        }
        .onChange(of: selection) { _, newValue in
            currentPageIsZoomed = false
            preload(around: newValue)
        }
        .onDisappear {
            // A canceled loader can finish after SwiftUI has removed the cover. Invalidate every
            // request before releasing the published pages so a non-cooperative media read cannot
            // put a large inline value (or protected-original lease) back into an off-screen
            // StateObject.
            loader.cancelAllAndRelease()
            cleanUpShareFile()
        }
    }

    // MARK: Pager

    private var pager: some View {
        TabView(selection: $selection) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                page(for: item, index: index)
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea()
        .simultaneousGesture(dismissDragGesture)
        .sheet(
            isPresented: Binding(
                get: { shareURL != nil },
                set: { if !$0 { cleanUpShareFile() } }
            )
        ) {
            if let shareURL {
                GalleryShareSheet(items: [shareURL])
            }
        }
    }

    @ViewBuilder
    private func page(for item: KitGalleryItem, index: Int) -> some View {
        let isActive = index == selection
        Group {
            switch loader.state(for: item.id) {
            case let .loaded(loaded):
                loadedPage(for: item, loaded: loaded, isActive: isActive)
            case .failed:
                failedPage(for: item)
            case .idle, .loading:
                loadingPage(for: item)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel(for: item))
    }

    @ViewBuilder
    private func loadedPage(
        for item: KitGalleryItem,
        loaded: SecureMediaLoadPolicy.LoadedItem,
        isActive: Bool
    ) -> some View {
        // Render branch and playback facts come from the same resolution as the bytes —
        // never from the constructed item's captured mediaType.
        switch KitChatMediaKind(mediaType: loaded.mediaType) {
        case .video:
            GalleryVideoPage(
                item: item,
                loaded: loaded,
                isActive: isActive,
                chromeVisible: chromeVisible,
                onToggleChrome: toggleChrome,
                onDismiss: dismissGallery,
                persistDuration: persistVideoDuration,
                restoreFromPictureInPicture: restoreFromPictureInPicture
            )
        default:
            GalleryImagePage(
                loaded: loaded,
                isActive: isActive,
                onZoomChanged: { zoomed in
                    if isActive { currentPageIsZoomed = zoomed }
                },
                onSingleTap: toggleChrome
            )
        }
    }

    private func loadingPage(for item: KitGalleryItem) -> some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(.white)
                .controlSize(.large)
            Text(byteLabel(for: item) ?? "Loading…")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.75))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { toggleChrome() }
    }

    private func failedPage(for item: KitGalleryItem) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title)
                .foregroundStyle(.white.opacity(0.8))
            Text("This media could not be loaded.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
            Button {
                loader.retry(item)
            } label: {
                Text("Retry")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .frame(minHeight: 44)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .accessibilityLabel("Retry loading media")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { toggleChrome() }
    }

    // MARK: Chrome

    private var chrome: some View {
        VStack {
            topBar
            Spacer()
            bottomBar
        }
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                dismissGallery()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Close media viewer")

            if let currentItem {
                VStack(alignment: .leading, spacing: 1) {
                    Text(currentItem.senderName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(dateLabel(for: currentItem))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }
            }

            Spacer()

            Text("\(selection + 1) of \(items.count)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(minHeight: 30)
                .background(.ultraThinMaterial, in: Capsule())
                .accessibilityLabel("Item \(selection + 1) of \(items.count)")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var bottomBar: some View {
        HStack(spacing: 6) {
            Button {
                Task { await shareCurrentItem() }
            } label: {
                bottomBarLabel(systemName: "square.and.arrow.up", title: "Share")
            }
            .disabled(currentLoadedItem == nil || isPreparingShare)
            .opacity(currentLoadedItem == nil ? 0.4 : 1)
            .accessibilityLabel(
                currentLoadedItem == nil
                    ? "Share media, unavailable while loading"
                    : "Share media"
            )

            Button {
                Task { await saveCurrentItem() }
            } label: {
                bottomBarLabel(systemName: "square.and.arrow.down", title: "Save")
            }
            .disabled(currentLoadedItem == nil)
            .opacity(currentLoadedItem == nil ? 0.4 : 1)
            .accessibilityLabel("Save media to Photos")

            if let showInChat, let currentItem {
                Button {
                    dismissGallery()
                    showInChat(currentItem)
                } label: {
                    bottomBarLabel(systemName: "text.bubble", title: "Show in chat")
                }
                .accessibilityLabel("Show this media in the chat")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 14)
    }

    private func bottomBarLabel(systemName: String, title: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
            Text(title)
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(.white)
        .frame(minWidth: 66, minHeight: 44)
        .contentShape(Rectangle())
    }

    private func toast(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 90)
        }
        .transition(reduceMotion ? .identity : .opacity)
        .accessibilityLabel(text)
    }

    // MARK: Dismiss drag

    private var backdropOpacity: Double {
        max(0.35, 1 - Double(dismissDrag) / 500)
    }

    private var dismissDragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !currentPageIsZoomed else { return }
                let translation = value.translation
                if !isDragDismissing {
                    guard translation.height > 16,
                          abs(translation.height) > abs(translation.width)
                    else { return }
                    isDragDismissing = true
                }
                dismissDrag = max(0, translation.height)
            }
            .onEnded { value in
                guard isDragDismissing else { return }
                isDragDismissing = false
                if dismissDrag > 120 || value.predictedEndTranslation.height > 320 {
                    dismissGallery()
                } else if reduceMotion {
                    dismissDrag = 0
                } else {
                    withAnimation(.spring(duration: 0.3)) { dismissDrag = 0 }
                }
            }
    }

    /// X, drag-to-dismiss and "Show in chat" are explicit stop intents. Picture in Picture is
    /// reserved for the system background transition; closing a viewer must actually close it.
    private func dismissGallery() {
        ChatVideoPictureInPicture.shared.stopForExplicitViewerDismissal()
        onDismiss()
    }

    private func toggleChrome() {
        if reduceMotion {
            chromeVisible.toggle()
        } else {
            withAnimation(.easeInOut(duration: 0.18)) { chromeVisible.toggle() }
        }
    }

    // MARK: Loading

    private func preload(around index: Int) {
        for offset in (index - 1) ... (index + 1) where items.indices.contains(offset) {
            loader.ensureLoaded(items[offset])
        }
        loader.cancelLoadsFar(from: index, items: items)
    }

    private var currentLoadedItem: SecureMediaLoadPolicy.LoadedItem? {
        guard let currentItem else { return nil }
        return loader.loadedItem(for: currentItem.id)
    }

    private func byteLabel(for item: KitGalleryItem) -> String? {
        ChatMediaBytes.label(item.plaintextByteSize)
    }

    private func dateLabel(for item: KitGalleryItem) -> String {
        item.createdAt.formatted(date: .abbreviated, time: .shortened)
    }

    private func accessibilityLabel(for item: KitGalleryItem) -> String {
        let kind = KitChatMediaKind(mediaType: item.mediaType) == .video ? "Video" : "Photo"
        return "\(kind) from \(item.senderName), \(dateLabel(for: item))"
    }

    // MARK: Share

    /// Exporting is a user-triggered presentation: the tap re-resolves the item's identity —
    /// account, current persisted row, full projection — and stages ONLY that fresh result in a
    /// file-protected temp file for the share sheet. The page's already-displayed bytes are
    /// never authority for what leaves the app. Images are shared as JPEG; videos in the fresh
    /// resolution's own type.
    private func shareCurrentItem() async {
        guard !isPreparingShare, let currentItem else { return }
        isPreparingShare = true
        defer { isPreparingShare = false }
        cleanUpShareFile()
        guard let fresh = try? await loadData(currentItem) else {
            showToast("Could not share")
            return
        }
        switch KitChatMediaKind(mediaType: fresh.mediaType) {
        case .video:
            if let localFileURL = fresh.localFileURL {
                shareURL = try? ChatMediaTempFiles.copyTemporaryFile(
                    from: localFileURL,
                    mediaType: fresh.mediaType,
                    suggestedName: "Kit video"
                )
            } else {
                shareURL = try? ChatMediaTempFiles.writeTemporaryFile(
                    data: fresh.data,
                    mediaType: fresh.mediaType,
                    suggestedName: "Kit video"
                )
            }
        default:
            if let localFileURL = fresh.localFileURL {
                shareURL = try? ChatMediaTempFiles.copyTemporaryFile(
                    from: localFileURL,
                    mediaType: fresh.mediaType,
                    suggestedName: "Kit photo"
                )
                if shareURL == nil { showToast("Could not share") }
                return
            }
            guard let image = UIImage(data: fresh.data),
                  let jpeg = image.jpegData(compressionQuality: 0.9)
            else {
                showToast("Could not share")
                return
            }
            shareURL = try? ChatMediaTempFiles.writeTemporaryFile(
                data: jpeg,
                mediaType: "image/jpeg",
                suggestedName: "Kit photo"
            )
        }
    }

    private func cleanUpShareFile() {
        ChatMediaTempFiles.removeTemporaryFile(shareURL)
        shareURL = nil
    }

    // MARK: Save to Photos

    /// Same rule as sharing: the save tap re-resolves the item's identity and exports exactly
    /// that fresh result — bytes and kind together — not the page's already-displayed state.
    private func saveCurrentItem() async {
        guard let currentItem else { return }
        guard let fresh = try? await loadData(currentItem) else {
            showToast("Could not save")
            return
        }
        switch KitChatMediaKind(mediaType: fresh.mediaType) {
        case .video:
            if let localFileURL = fresh.localFileURL {
                saveVideo(
                    fileURL: localFileURL,
                    removeAfterSave: false,
                    protectedOriginalLease: fresh.localFileLease
                )
            } else {
                saveVideo(data: fresh.data, mediaType: fresh.mediaType)
            }
        default:
            if let localFileURL = fresh.localFileURL {
                saveImage(
                    fileURL: localFileURL,
                    protectedOriginalLease: fresh.localFileLease
                )
            } else {
                saveImage(data: fresh.data)
            }
        }
    }

    private func saveImage(
        fileURL: URL,
        protectedOriginalLease: SecureMediaOriginalAccessLease?
    ) {
        PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: fileURL, options: nil)
        } completionHandler: { success, error in
            // PhotoKit reads the resource asynchronously. Retain receiver-cache ownership until
            // it has consumed the protected file, just as video export retains its lease.
            _ = protectedOriginalLease
            Task { @MainActor in
                showToast(success && error == nil ? "Saved to Photos" : "Could not save photo")
            }
        }
    }

    private func saveImage(data: Data) {
        guard let image = UIImage(data: data) else {
            showToast("Could not save photo")
            return
        }
        let completion = MediaSaveCompletion { error in
            showToast(error == nil ? "Saved to Photos" : "Could not save photo")
        }
        MediaSaveCompletion.retain(completion)
        UIImageWriteToSavedPhotosAlbum(
            image,
            completion,
            #selector(MediaSaveCompletion.image(_:didFinishSavingWithError:contextInfo:)),
            nil
        )
    }

    private func saveVideo(data: Data, mediaType: String) {
        guard let url = try? ChatMediaTempFiles.writeTemporaryFile(
            data: data,
            mediaType: mediaType
        ) else {
            showToast("Could not save video")
            return
        }
        saveVideo(
            fileURL: url,
            removeAfterSave: true,
            protectedOriginalLease: nil
        )
    }

    private func saveVideo(
        fileURL url: URL,
        removeAfterSave: Bool,
        protectedOriginalLease: SecureMediaOriginalAccessLease?
    ) {
        let completion = MediaSaveCompletion { [protectedOriginalLease] error in
            // UISaveVideoAtPathToSavedPhotosAlbum reads asynchronously after this method returns.
            // Keep a received-cache lease alive until UIKit reports that it has finished.
            _ = protectedOriginalLease
            if removeAfterSave { ChatMediaTempFiles.removeTemporaryFile(url) }
            showToast(error == nil ? "Saved to Photos" : "Could not save video")
        }
        MediaSaveCompletion.retain(completion)
        UISaveVideoAtPathToSavedPhotosAlbum(
            url.path,
            completion,
            #selector(MediaSaveCompletion.video(_:didFinishSavingWithError:contextInfo:)),
            nil
        )
    }

    private func showToast(_ text: String) {
        if reduceMotion {
            toastText = text
        } else {
            withAnimation(.easeInOut(duration: 0.18)) { toastText = text }
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard toastText == text else { return }
            if reduceMotion {
                toastText = nil
            } else {
                withAnimation(.easeInOut(duration: 0.18)) { toastText = nil }
            }
        }
    }
}

// MARK: - Per-page load state

@MainActor
final class GalleryPageLoader: ObservableObject {
    enum PageState {
        case idle
        case loading
        /// Bytes plus the MIME/caption facts of the same authoritative resolution.
        case loaded(SecureMediaLoadPolicy.LoadedItem)
        case failed
    }

    @Published private(set) var states: [String: PageState] = [:]

    private var tasks: [String: Task<Void, Never>] = [:]
    /// Distinguishes a current load from an older canceled load for the same gallery identity.
    /// Cancellation is cooperative, so the task object alone cannot prevent stale publication.
    private var requestIDs: [String: UUID] = [:]
    private var loadData: ((KitGalleryItem) async throws -> SecureMediaLoadPolicy.LoadedItem)?

    func configure(
        _ loadData: @escaping (KitGalleryItem) async throws -> SecureMediaLoadPolicy.LoadedItem
    ) {
        self.loadData = loadData
    }

    func state(for id: String) -> PageState {
        states[id] ?? .idle
    }

    func loadedItem(for id: String) -> SecureMediaLoadPolicy.LoadedItem? {
        if case let .loaded(loaded) = state(for: id) { return loaded }
        return nil
    }

    func ensureLoaded(_ item: KitGalleryItem) {
        switch state(for: item.id) {
        case .loading, .loaded:
            return
        case .idle, .failed:
            break
        }
        guard let loadData else { return }
        states[item.id] = .loading
        let requestID = UUID()
        requestIDs[item.id] = requestID
        tasks[item.id] = Task { [weak self] in
            do {
                let loaded = try await loadData(item)
                guard let self, self.requestIDs[item.id] == requestID else { return }
                guard !Task.isCancelled else {
                    self.states[item.id] = .idle
                    self.finishRequest(for: item.id, requestID: requestID)
                    return
                }
                self.states[item.id] = .loaded(loaded)
            } catch {
                guard let self, self.requestIDs[item.id] == requestID else { return }
                if error is CancellationError || Task.isCancelled {
                    self.states[item.id] = .idle
                } else {
                    self.states[item.id] = .failed
                }
            }
            self?.finishRequest(for: item.id, requestID: requestID)
        }
    }

    func retry(_ item: KitGalleryItem) {
        if case .failed = state(for: item.id) {
            states[item.id] = .idle
        }
        ensureLoaded(item)
    }

    /// Cancels in-flight loads for pages 2+ positions away from the current page, and evicts
    /// far pages' loaded plaintext. Media can be up to 200 MB each, so keeping every visited
    /// page's bytes for the whole gallery session would eventually jetsam the app; evicted
    /// pages reload instantly from the encrypted file cache when paged back to.
    func cancelLoadsFar(from index: Int, items: [KitGalleryItem]) {
        for (offset, item) in items.enumerated() where abs(offset - index) >= 2 {
            invalidateRequest(for: item.id)
            switch state(for: item.id) {
            case .loading, .loaded:
                states[item.id] = .idle
            case .idle, .failed:
                break
            }
        }
    }

    /// Cancels all work and synchronously releases every loaded value retained by the gallery.
    /// Each file-backed value may own an eviction lease, while an old inline value can own several
    /// megabytes; neither should wait for an implementation-detail StateObject lifetime after the
    /// full-screen cover has gone away.
    func cancelAllAndRelease() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll(keepingCapacity: false)
        requestIDs.removeAll(keepingCapacity: false)
        states.removeAll(keepingCapacity: false)
        loadData = nil
    }

    private func invalidateRequest(for id: String) {
        requestIDs[id] = nil
        tasks[id]?.cancel()
        tasks[id] = nil
    }

    private func finishRequest(for id: String, requestID: UUID) {
        guard requestIDs[id] == requestID else { return }
        requestIDs[id] = nil
        tasks[id] = nil
    }
}

// MARK: - Image page (zoomable)

private struct GalleryImagePage: View {
    let loaded: SecureMediaLoadPolicy.LoadedItem
    let isActive: Bool
    let onZoomChanged: (Bool) -> Void
    let onSingleTap: () -> Void

    /// Decoded once per `data` and reused across body evaluations: a per-render `UIImage(data:)`
    /// would defeat ZoomableImageView's identity guard and reset the zoom on every state change.
    @State private var decodedImage: UIImage?
    @State private var decodeFinished = false

    var body: some View {
        Group {
            if let decodedImage {
                ZoomableImageView(
                    image: decodedImage,
                    isActive: isActive,
                    onZoomChanged: onZoomChanged,
                    onSingleTap: onSingleTap
                )
                .ignoresSafeArea()
            } else if decodeFinished {
                VStack(spacing: 10) {
                    Image(systemName: "photo.fill")
                        .font(.title)
                    Text("This photo could not be displayed.")
                        .font(.subheadline)
                }
                .foregroundStyle(.white.opacity(0.8))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { onSingleTap() }
            } else {
                Color.clear
            }
        }
        .task(id: "\(loaded.localFileURL?.path ?? "inline"):\(loaded.byteCount)") {
            let fileURL = loaded.localFileURL
            let bytes = loaded.data
            let image = await Task.detached(priority: .userInitiated) {
                if let fileURL {
                    return ChatMediaImageDecoder.downsample(
                        fileURL: fileURL,
                        maximumPixelSize: 4_096
                    )
                }
                return ChatMediaImageDecoder.downsample(
                    data: bytes,
                    maximumPixelSize: 4_096
                )
            }.value
            decodedImage = image
            decodeFinished = true
        }
    }
}

/// UIScrollView-backed zoom container: pinch 1x...5x, pan while zoomed, double-tap 1 <-> 2.5x
/// anchored at the tap point. At zoomScale 1 the scroll view has nothing to pan
/// (contentSize == fitted image size), so the surrounding TabView receives paging swipes; when
/// zoomed the scroll view consumes pans and paging is naturally disabled.
private struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    let isActive: Bool
    let onZoomChanged: (Bool) -> Void
    let onSingleTap: () -> Void

    func makeUIView(context _: Context) -> ZoomableImageScrollView {
        let view = ZoomableImageScrollView()
        view.onZoomStateChange = onZoomChanged
        view.onSingleTap = onSingleTap
        view.display(image: image)
        return view
    }

    func updateUIView(_ uiView: ZoomableImageScrollView, context _: Context) {
        uiView.onZoomStateChange = onZoomChanged
        uiView.onSingleTap = onSingleTap
        if uiView.displayedImage !== image {
            uiView.display(image: image)
        }
        // Reset zoom when this page is no longer the visible page.
        if !isActive, uiView.zoomScale > 1.001 {
            uiView.setZoomScale(1, animated: false)
        }
    }
}

final class ZoomableImageScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var lastLayoutSize: CGSize = .zero

    var onZoomStateChange: ((Bool) -> Void)?
    var onSingleTap: (() -> Void)?

    private(set) var displayedImage: UIImage?

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 5
        bouncesZoom = true
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear

        imageView.contentMode = .scaleAspectFill
        imageView.isUserInteractionEnabled = false
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    func display(image: UIImage) {
        displayedImage = image
        imageView.image = image
        lastLayoutSize = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastLayoutSize {
            lastLayoutSize = bounds.size
            configureFittedLayout()
        }
        centerContent()
    }

    /// Sizes the image view to aspect-fit the bounds at zoomScale 1, so contentSize never exceeds
    /// the viewport until the user zooms — which is what lets TabView paging work at 1x.
    private func configureFittedLayout() {
        guard let image = imageView.image,
              image.size.width > 0, image.size.height > 0,
              bounds.width > 0, bounds.height > 0
        else { return }
        zoomScale = 1
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let fitted = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        imageView.frame = CGRect(origin: .zero, size: fitted)
        contentSize = fitted
        centerContent()
    }

    private func centerContent() {
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        let vertical = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(
            top: vertical,
            left: horizontal,
            bottom: vertical,
            right: horizontal
        )
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        if zoomScale > 1.01 {
            setZoomScale(1, animated: true)
        } else {
            let targetScale: CGFloat = 2.5
            let point = recognizer.location(in: imageView)
            let width = bounds.width / targetScale
            let height = bounds.height / targetScale
            let rect = CGRect(
                x: point.x - width / 2,
                y: point.y - height / 2,
                width: width,
                height: height
            )
            zoom(to: rect, animated: true)
        }
    }

    @objc private func handleSingleTap() {
        onSingleTap?()
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in _: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_: UIScrollView) {
        centerContent()
        onZoomStateChange?(zoomScale > 1.01)
    }
}

// MARK: - Video page

enum GalleryVideoActivationPolicy {
    static let galleryPosterMaxPixel: CGFloat = 400
    static let conversationPosterMaxPixel: CGFloat = 248

    static func permitsPreparation(isActive: Bool) -> Bool { isActive }

    /// The active video page must never put optional frame extraction in front of playback.
    /// Reuse a poster another surface has already decoded, preferring the gallery-sized entry;
    /// a cache miss deliberately returns nil so AVPlayer preparation can begin immediately.
    @MainActor
    static func cachedPoster(
        forKey contentKey: String,
        in store: ChatMediaThumbnailStore? = nil
    ) -> UIImage? {
        let store = store ?? .shared
        return store.cachedThumbnail(forKey: contentKey, maxPixel: galleryPosterMaxPixel)
            ?? store.cachedThumbnail(forKey: contentKey, maxPixel: conversationPosterMaxPixel)
    }
}

private struct GalleryVideoPage: View {
    let item: KitGalleryItem
    /// Bytes plus the facts of the same resolution; playback and poster use these, never the
    /// constructed item's captured mediaType.
    let loaded: SecureMediaLoadPolicy.LoadedItem
    let isActive: Bool
    let chromeVisible: Bool
    let onToggleChrome: () -> Void
    let onDismiss: () -> Void
    let persistDuration: (UUID, TimeInterval) async -> Void
    let restoreFromPictureInPicture: (ChatVideoGalleryIdentity) -> Void

    @StateObject private var controller = GalleryVideoController()
    @State private var poster: UIImage?

    var body: some View {
        ZStack {
            if let player = controller.player {
                PlayerLayerView(
                    player: player,
                    onLayerReady: { controller.attachLayer($0) }
                )
                .ignoresSafeArea()
            }
            if let poster, !controller.hasStartedPlayback {
                Image(uiImage: poster)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityHidden(true)
            }
            controlsOverlay
        }
        .contentShape(Rectangle())
        .onTapGesture { onToggleChrome() }
        .task(id: isActive) {
            guard GalleryVideoActivationPolicy.permitsPreparation(isActive: isActive) else {
                controller.deactivatePage()
                return
            }
            // Picture in Picture restores at exact gallery identity: item 3 of a
            // multi-attachment message reopens on item 3, still within its one bubble.
            let identity = ChatVideoGalleryIdentity(
                messageID: item.messageID,
                itemIndex: item.itemIndex
            )
            // Poster extraction performs its own AVAsset preparation and frame decode. Never
            // serialize that optional work ahead of the active player's preparation; a bubble or
            // prior gallery visit may still provide a cached frame at zero decoding cost.
            poster = GalleryVideoActivationPolicy.cachedPoster(forKey: item.thumbnailKey)

            let didPrepare: Bool
            if let localFileURL = loaded.localFileURL {
                didPrepare = await controller.prepare(
                    fileURL: localFileURL,
                    ownsFile: false,
                    protectedOriginalLease: loaded.localFileLease,
                    mediaType: loaded.mediaType,
                    expectedByteCount: loaded.byteCount,
                    contentKey: item.thumbnailKey,
                    mediaID: item.mediaID,
                    isOutgoing: item.isOutgoing,
                    galleryIdentity: identity,
                    restoreFromPictureInPicture: restoreFromPictureInPicture
                )
            } else {
                didPrepare = await controller.prepare(
                    data: loaded.data,
                    mediaType: loaded.mediaType,
                    contentKey: item.thumbnailKey,
                    mediaID: item.mediaID,
                    isOutgoing: item.isOutgoing,
                    galleryIdentity: identity,
                    restoreFromPictureInPicture: restoreFromPictureInPicture
                )
            }
            if didPrepare, !Task.isCancelled {
                await persistDuration(item.mediaID, controller.duration)
            }
        }
        .onChange(of: isActive) { _, nowActive in
            if !nowActive {
                ChatVideoPosterGenerator.cancelPosters(forKey: item.thumbnailKey)
                controller.deactivatePage()
            }
        }
        .onDisappear {
            ChatVideoPosterGenerator.cancelPosters(forKey: item.thumbnailKey)
            controller.teardown()
        }
    }

    @ViewBuilder
    private var controlsOverlay: some View {
        if controller.isPreparing {
            ProgressView("Preparing video…")
                .tint(.white)
                .foregroundStyle(.white)
        } else if let errorMessage = controller.errorMessage {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 30, weight: .semibold))
                Text(errorMessage)
                    .font(.body.weight(.semibold))
                    .multilineTextAlignment(.center)
                Button("Close", action: onDismiss)
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Close media viewer")
            }
            .foregroundStyle(.white)
            .padding(32)
        } else if controller.player != nil, chromeVisible || !controller.isPlaying {
            // The big play/pause control stays visible while paused so playback is always
            // reachable after the file has passed the local playback probe.
            Button {
                controller.togglePlayback()
            } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .accessibilityLabel(controller.isPlaying ? "Pause video" : "Play video")
        }

        if chromeVisible {
            VStack {
                Spacer()
                scrubberBar
                    .padding(.horizontal, 16)
                    .padding(.bottom, 96)
            }
        }
    }

    private var scrubberBar: some View {
        HStack(spacing: 10) {
            Text(Self.timeLabel(controller.currentTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white)

            Slider(
                value: Binding(
                    get: { controller.currentTime },
                    set: { controller.scrub(to: $0) }
                ),
                in: 0 ... max(controller.duration, 0.01),
                onEditingChanged: { editing in
                    controller.setScrubbing(editing)
                }
            )
            .tint(.white)
            .accessibilityLabel("Video position")

            Text("-" + Self.timeLabel(max(0, controller.duration - controller.currentTime)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white)

            Button {
                controller.toggleMute()
            } label: {
                Image(systemName: controller.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(controller.isMuted ? "Unmute video" : "Mute video")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private static func timeLabel(_ seconds: Double) -> String {
        ChatMediaPlaybackClock.label(seconds)
    }
}

/// Owns the AVPlayer, its protected temp file, and observers for one video page.
@MainActor
final class GalleryVideoController: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var isPlaying = false
    @Published private(set) var isMuted = false
    @Published private(set) var hasStartedPlayback = false
    @Published private(set) var isPreparing = false
    @Published private(set) var errorMessage: String?
    @Published var duration: Double = 0
    @Published var currentTime: Double = 0

    private(set) var playbackURL: URL?

    private var isScrubbing = false
    private var sourceFileURL: URL?
    private var playbackFileLease: ChatVideoPlaybackFileLease?
    private var ownsFileURL = false
    private var asset: AVURLAsset?
    private var playerItem: AVPlayerItem?
    /// Retained by the controller, rather than the SwiftUI page value, so a Picture in Picture
    /// handoff continues to exclude this received-cache file from eviction after the gallery is
    /// dismissed. `releaseResources` drops it only when playback ownership truly ends.
    private var protectedOriginalLease: SecureMediaOriginalAccessLease?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var stallObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var preparationID: UUID?
    private var playbackClaim: ChatVideoPosterGenerator.PlaybackClaim?
    private var diagnosticMediaID: UUID?
    private var diagnosticIsOutgoing = false
    private var diagnosticByteCount: Int?
    private let mediaAccountLifetime = ChatMediaAccountLifetime.current
    private let diagnosticProducerScope = LocalMediaPerformanceMonitor.shared.captureProducerScope()
    private var didRecordPlaybackStart = false
    private var didRecordTerminalFailure = false
    /// The layer this page is drawing into, reported by `PlayerLayerView`. Picture in Picture
    /// hands off a *layer*, so the window can only be armed once one exists.
    private weak var playerLayer: AVPlayerLayer?
    /// Identifies the handed-off video — down to the item within a multi-attachment message —
    /// so restoring from the floating window reopens the gallery on that exact item rather than
    /// wherever the thread happens to be.
    private var galleryIdentity: ChatVideoGalleryIdentity?
    private var restoreFromPictureInPicture: ((ChatVideoGalleryIdentity) -> Void)?

    func prepare(
        data: Data,
        mediaType: String,
        contentKey: String,
        mediaID: UUID,
        isOutgoing: Bool,
        galleryIdentity: ChatVideoGalleryIdentity,
        restoreFromPictureInPicture: @escaping (ChatVideoGalleryIdentity) -> Void
    ) async -> Bool {
        guard mediaAccountLifetime == ChatMediaAccountLifetime.current else { return false }
        self.galleryIdentity = galleryIdentity
        self.restoreFromPictureInPicture = restoreFromPictureInPicture
        guard player == nil, !isPreparing else { return player != nil }
        diagnosticMediaID = mediaID
        diagnosticIsOutgoing = isOutgoing
        diagnosticByteCount = data.count
        didRecordPlaybackStart = false
        didRecordTerminalFailure = false
        guard let url = try? ChatMediaTempFiles.writeTemporaryFile(
            data: data,
            mediaType: mediaType
        ) else {
            failPreparation(ChatVideoPlaybackPreparationError.invalidFile)
            return false
        }
        return await prepare(
            fileURL: url,
            ownsFile: true,
            protectedOriginalLease: nil,
            mediaType: mediaType,
            expectedByteCount: data.count,
            contentKey: contentKey,
            mediaID: mediaID,
            isOutgoing: isOutgoing,
            galleryIdentity: galleryIdentity,
            restoreFromPictureInPicture: restoreFromPictureInPicture
        )
    }

    func prepare(
        fileURL url: URL,
        ownsFile: Bool,
        protectedOriginalLease: SecureMediaOriginalAccessLease?,
        mediaType: String,
        expectedByteCount: Int,
        contentKey: String,
        mediaID: UUID,
        isOutgoing: Bool,
        galleryIdentity: ChatVideoGalleryIdentity,
        restoreFromPictureInPicture: @escaping (ChatVideoGalleryIdentity) -> Void
    ) async -> Bool {
        guard mediaAccountLifetime == ChatMediaAccountLifetime.current else {
            if ownsFile { ChatMediaTempFiles.removeTemporaryFile(url) }
            return false
        }
        self.galleryIdentity = galleryIdentity
        self.restoreFromPictureInPicture = restoreFromPictureInPicture
        guard player == nil, !isPreparing else {
            if ownsFile { ChatMediaTempFiles.removeTemporaryFile(url) }
            return player != nil
        }
        diagnosticMediaID = mediaID
        diagnosticIsOutgoing = isOutgoing
        diagnosticByteCount = expectedByteCount
        didRecordPlaybackStart = false
        didRecordTerminalFailure = false
        let identifier = UUID()
        preparationID = identifier
        sourceFileURL = url
        ownsFileURL = ownsFile
        self.protectedOriginalLease = protectedOriginalLease
        isPreparing = true
        errorMessage = nil
        guard let claim = await ChatVideoPosterGenerator.acquirePlayback(forKey: contentKey)
        else {
            failPreparation(ChatVideoPlaybackPreparationError.invalidFile)
            return false
        }
        guard !Task.isCancelled,
              mediaAccountLifetime == ChatMediaAccountLifetime.current,
              preparationID == identifier,
              sourceFileURL == url
        else {
            ChatVideoPosterGenerator.releasePlayback(claim)
            if preparationID == identifier { releaseResources() }
            return false
        }
        playbackClaim = claim
        do {
            let prepared = try await ChatVideoPlaybackAssetPolicy.prepare(
                fileURL: url,
                declaredMediaType: mediaType,
                expectedByteCount: expectedByteCount
            )
            guard !Task.isCancelled,
                  mediaAccountLifetime == ChatMediaAccountLifetime.current,
                  preparationID == identifier,
                  sourceFileURL == url
            else {
                prepared.playbackFileLease.release()
                if preparationID == identifier { releaseResources() }
                return false
            }
            playbackFileLease = prepared.playbackFileLease
            playbackURL = prepared.playbackURL
            asset = prepared.asset
            duration = prepared.duration
            let item = AVPlayerItem(asset: prepared.asset)
            playerItem = item
            let player = AVPlayer(playerItem: item)
            player.automaticallyWaitsToMinimizeStalling = true
            player.isMuted = isMuted
            self.player = player
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                queue: .main
            ) { [weak self] time in
                Task { @MainActor in
                    self?.receivePlaybackTime(time, from: item)
                }
            }
            observePlaybackItem(item)
            isPreparing = false
            return true
        } catch {
            guard preparationID == identifier else { return false }
            failPreparation(error)
            return false
        }
    }

    /// AVFoundation's callbacks hop to the main actor. Removing an observer cannot recall an
    /// already-enqueued callback, so its item identity must still match after that hop.
    func receivePlaybackTime(_ time: CMTime, from item: AVPlayerItem) {
        guard playerItem === item, !isScrubbing else { return }
        let seconds = time.seconds
        guard seconds.isFinite else { return }
        currentTime = max(0, min(seconds, duration))
        recordPlaybackStartedIfNeeded(position: currentTime)
    }

    /// Reported by the layer host as it comes up, and again on reuse.
    func attachLayer(_ layer: AVPlayerLayer) {
        playerLayer = layer
        if isPlaying { armPictureInPicture() }
    }

    /// Leaves the page. A video that is still playing keeps going in the system's floating window,
    /// and the plaintext it is playing from stays on disk until that window closes — hence the
    /// deferral rather than an unconditional teardown.
    func teardown(allowsPictureInPictureRetention: Bool = true) {
        if allowsPictureInPictureRetention,
           ChatVideoPictureInPicture.shared.retainTeardown(owner: self, { [self] in
               releaseResources()
           }) {
            return
        }
        ChatVideoPictureInPicture.shared.detach(owner: self)
        releaseResources()
    }

    /// Paging away is a terminal viewing intent for this owner, but AVKit may still be between its
    /// asynchronous start/stop callbacks. Ask the PiP coordinator to stop first, then use the same
    /// deferred teardown path as disappearance so the player and both file leases survive until
    /// AVKit has actually released them.
    func deactivatePage() {
        pause()
        ChatVideoPictureInPicture.shared.stopForPageDeactivation(owner: self)
        teardown()
    }

    private func releaseResources() {
        preparationID = nil
        isPreparing = false
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        removePlaybackItemObservers()
        let retainedPlayer = player
        retainedPlayer?.pause()
        retainedPlayer?.replaceCurrentItem(with: nil)
        player = nil
        playerItem = nil
        asset = nil
        playerLayer = nil
        isPlaying = false
        isScrubbing = false
        hasStartedPlayback = false
        currentTime = 0
        duration = 0
        playbackFileLease?.release()
        playbackFileLease = nil
        playbackURL = nil
        if ownsFileURL { ChatMediaTempFiles.removeTemporaryFile(sourceFileURL) }
        sourceFileURL = nil
        ownsFileURL = false
        protectedOriginalLease = nil
        galleryIdentity = nil
        restoreFromPictureInPicture = nil
        diagnosticMediaID = nil
        diagnosticByteCount = nil
        didRecordPlaybackStart = false
        didRecordTerminalFailure = false
        ChatVideoPosterGenerator.releasePlayback(playbackClaim)
        playbackClaim = nil
    }

    func togglePlayback() {
        guard mediaAccountLifetime == ChatMediaAccountLifetime.current else { return }
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
            hasStartedPlayback = true
            armPictureInPicture()
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    /// Points the floating window at this page's video. Armed on every play, so the hand-off
    /// always follows the video the user is actually watching.
    private func armPictureInPicture() {
        guard mediaAccountLifetime == ChatMediaAccountLifetime.current else { return }
        guard let playerLayer, let galleryIdentity, let restoreFromPictureInPicture else { return }
        ChatVideoPictureInPicture.shared.attach(
            playerLayer: playerLayer,
            owner: self,
            galleryIdentity: galleryIdentity,
            restore: restoreFromPictureInPicture
        )
    }

    func toggleMute() {
        isMuted.toggle()
        player?.isMuted = isMuted
    }

    func setScrubbing(_ scrubbing: Bool) {
        isScrubbing = scrubbing
        if !scrubbing {
            player?.seek(
                to: CMTime(seconds: currentTime, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }
    }

    func scrub(to seconds: Double) {
        currentTime = seconds
        if isScrubbing {
            player?.seek(
                to: CMTime(seconds: seconds, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }
    }

    private func observePlaybackItem(_ item: AVPlayerItem) {
        removePlaybackItemObservers()
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handlePlaybackEnded(item: item) }
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
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleInterruption(
                    .failed,
                    item: item,
                    notificationError: notification.userInfo?[
                        AVPlayerItemFailedToPlayToEndTimeErrorKey
                    ] as? Error
                )
            }
        }
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in
                await Task.yield()
                self?.handleItemStatusFailure(item: item)
            }
        }
    }

    private func removePlaybackItemObservers() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let stallObserver { NotificationCenter.default.removeObserver(stallObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        statusObservation?.invalidate()
        endObserver = nil
        stallObserver = nil
        failureObserver = nil
        statusObservation = nil
    }

    private func handleInterruption(
        _ interruption: ChatVideoPlaybackFailurePolicy.Interruption,
        item: AVPlayerItem,
        notificationError: Error? = nil
    ) {
        guard playerItem === item else { return }
        switch interruption {
        case .stalled:
            let diagnostic = ChatVideoPlayerDiagnosticPolicy.snapshot(
                failureSource: .stalledNotification,
                item: item
            )
            recordPlayback(
                .stalled,
                position: item.currentTime().seconds,
                diagnostic: diagnostic
            )
        case .failed:
            handleTerminalFailure(
                item: item,
                source: .failedToEndNotification,
                notificationError: notificationError
            )
            return
        }
        switch ChatVideoPlaybackFailurePolicy.action(for: interruption) {
        case .letPlayerRecover:
            // A local decoder stall remains AVFoundation-owned. Mutating the current item from
            // this callback is unsafe because AVKit still has observations attached to it.
            break
        case .stopAndReport:
            isPlaying = false
            player?.pause()
            errorMessage = "This video could not be played completely."
        }
    }

    private func handleItemStatusFailure(item: AVPlayerItem) {
        guard playerItem === item, item.status == .failed else { return }
        handleTerminalFailure(item: item, source: .itemStatus)
    }

    private func handleTerminalFailure(
        item: AVPlayerItem,
        source: LocalMediaPlaybackFailureSource,
        notificationError: Error? = nil
    ) {
        guard !didRecordTerminalFailure, playerItem === item else { return }
        didRecordTerminalFailure = true
        let diagnostic = ChatVideoPlayerDiagnosticPolicy.snapshot(
            failureSource: source,
            item: item,
            notificationError: notificationError
        )
        recordPlayback(
            didRecordPlaybackStart ? .failedToEnd : .preparationFailed,
            position: item.currentTime().seconds,
            diagnostic: diagnostic
        )
        isPlaying = false
        player?.pause()
        errorMessage = "This video could not be played completely.\nReference: \(diagnostic.supportReference)"
        ChatVideoPictureInPicture.shared.stopForPlaybackEnd(owner: self)
    }

    func handlePlaybackEnded(item: AVPlayerItem) {
        guard playerItem === item, isPlaying else { return }
        let position = item.currentTime().seconds
        recordPlaybackStartedIfNeeded(position: position)
        recordPlayback(.completed, position: position)
        isPlaying = false
        didRecordPlaybackStart = false
        currentTime = 0
        player?.seek(to: .zero)
        // Nothing left to watch: the floating window closes itself rather than sitting on the
        // user's screen showing a frozen last frame.
        ChatVideoPictureInPicture.shared.stopForPlaybackEnd(owner: self)
    }

    private func recordPlaybackStartedIfNeeded(position: Double) {
        guard isPlaying, !didRecordPlaybackStart, position.isFinite, position > 0 else { return }
        didRecordPlaybackStart = true
        recordPlayback(.started, position: position)
    }

    private func recordPlayback(
        _ outcome: LocalMediaPlaybackOutcome,
        position: Double?,
        diagnostic: LocalMediaPlaybackDiagnostic? = nil
    ) {
        guard let mediaID = diagnosticMediaID else { return }
        LocalMediaPerformanceMonitor.shared.recordPlayback(
            outcome: outcome,
            mediaID: mediaID,
            isOutgoing: diagnosticIsOutgoing,
            byteCount: diagnosticByteCount,
            expectedDuration: duration.isFinite && duration > 0 ? duration : nil,
            position: position.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
            diagnostic: diagnostic,
            producerScope: diagnosticProducerScope
        )
    }

    private func failPreparation(_ error: Error) {
        let nsError = error as NSError
        let diagnostic = LocalMediaPlaybackDiagnostic.sanitized(
            failureSource: .assetPreparation,
            errorDomain: nsError.domain,
            errorCode: nsError.code
        )
        recordPlayback(.preparationFailed, position: nil, diagnostic: diagnostic)
        isPreparing = false
        preparationID = nil
        ChatVideoPosterGenerator.releasePlayback(playbackClaim)
        playbackClaim = nil
        let description = (error as? LocalizedError)?.errorDescription
            ?? "This video could not be played."
        errorMessage = "\(description)\nReference: \(diagnostic.supportReference)"
        playbackFileLease?.release()
        playbackFileLease = nil
        playbackURL = nil
        if ownsFileURL { ChatMediaTempFiles.removeTemporaryFile(sourceFileURL) }
        sourceFileURL = nil
        ownsFileURL = false
        protectedOriginalLease = nil
    }
}

/// Bare AVPlayerLayer host so the gallery can draw its own minimal controls.
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    /// Reports the backing layer up to the page's controller: Picture in Picture hands off a
    /// layer, not a player, so the hand-off cannot be armed until this exists.
    var onLayerReady: ((AVPlayerLayer) -> Void)? = nil

    func makeUIView(context _: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        onLayerReady?(view.playerLayer)
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context _: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
        onLayerReady?(uiView.playerLayer)
    }

    final class PlayerContainerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

// MARK: - Save-to-Photos completion target

/// UIKit's save functions report through an Objective-C selector; this object carries the
/// completion and keeps itself alive until the callback fires.
@MainActor
final class MediaSaveCompletion: NSObject {
    private static var active: [MediaSaveCompletion] = []

    private let onFinish: (Error?) -> Void

    init(onFinish: @escaping (Error?) -> Void) {
        self.onFinish = onFinish
    }

    static func retain(_ completion: MediaSaveCompletion) {
        active.append(completion)
    }

    @objc func image(
        _: UIImage,
        didFinishSavingWithError error: Error?,
        contextInfo _: UnsafeRawPointer
    ) {
        finish(error)
    }

    @objc func video(
        _: String,
        didFinishSavingWithError error: Error?,
        contextInfo _: UnsafeMutableRawPointer?
    ) {
        finish(error)
    }

    private func finish(_ error: Error?) {
        onFinish(error)
        Self.active.removeAll { $0 === self }
    }
}

// MARK: - Share sheet

/// The share sheet is presented only after the tap's own fresh identity resolution has staged
/// its result, so it is a plain sheet rather than a `ShareLink` (which would hand over a file
/// staged before the tap).
private struct GalleryShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context _: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_: UIActivityViewController, context _: Context) {}
}
