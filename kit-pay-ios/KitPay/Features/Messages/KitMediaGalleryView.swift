import AVFoundation
import SwiftUI
import UIKit

// MARK: - Gallery item

/// One visual-media message (image or video) shown by the unified full-screen gallery.
struct KitGalleryItem: Identifiable, Equatable {
    let messageID: UUID
    let conversationID: String
    /// The raw message body; parseable via `KitMediaMessageDescriptor.parse(_:)`.
    let descriptorText: String
    let mediaType: String
    let isOutgoing: Bool
    let createdAt: Date
    let senderName: String

    var id: UUID { messageID }
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
    /// Loads decrypted plaintext for an item (cache-first upstream). Throws on failure.
    let loadData: (KitGalleryItem) async throws -> Data
    /// Optional 'Show in chat' action; gallery dismisses itself first, then calls this.
    let showInChat: ((KitGalleryItem) -> Void)?
    let onDismiss: () -> Void

    @StateObject private var loader = GalleryPageLoader()
    @State private var selection: Int
    @State private var chromeVisible = true
    @State private var currentPageIsZoomed = false
    @State private var dismissDrag: CGFloat = 0
    @State private var isDragDismissing = false
    @State private var shareURL: URL?
    @State private var toastText: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        items: [KitGalleryItem],
        initialItemID: UUID,
        loadData: @escaping (KitGalleryItem) async throws -> Data,
        showInChat: ((KitGalleryItem) -> Void)?,
        onDismiss: @escaping () -> Void
    ) {
        self.items = items
        self.initialItemID = initialItemID
        self.loadData = loadData
        self.showInChat = showInChat
        self.onDismiss = onDismiss
        _selection = State(
            initialValue: items.firstIndex(where: { $0.messageID == initialItemID }) ?? 0
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
            cleanUpShareFile()
        }
    }

    // MARK: Pager

    private var pager: some View {
        TabView(selection: $selection) {
            ForEach(Array(items.enumerated()), id: \.element.messageID) { index, item in
                page(for: item, index: index)
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea()
        .simultaneousGesture(dismissDragGesture)
        .task(id: shareTaskIdentity) {
            await prepareShareFile()
        }
    }

    @ViewBuilder
    private func page(for item: KitGalleryItem, index: Int) -> some View {
        let isActive = index == selection
        Group {
            switch loader.state(for: item.messageID) {
            case let .loaded(data):
                loadedPage(for: item, data: data, isActive: isActive)
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
    private func loadedPage(for item: KitGalleryItem, data: Data, isActive: Bool) -> some View {
        switch KitChatMediaKind(mediaType: item.mediaType) {
        case .video:
            GalleryVideoPage(
                item: item,
                data: data,
                isActive: isActive,
                chromeVisible: chromeVisible,
                onToggleChrome: toggleChrome
            )
        default:
            GalleryImagePage(
                data: data,
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
                onDismiss()
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
            if let shareURL {
                ShareLink(item: shareURL) {
                    bottomBarLabel(systemName: "square.and.arrow.up", title: "Share")
                }
                .accessibilityLabel("Share media")
            } else {
                bottomBarLabel(systemName: "square.and.arrow.up", title: "Share")
                    .opacity(0.4)
                    .accessibilityLabel("Share media, unavailable while loading")
            }

            Button {
                saveCurrentItem()
            } label: {
                bottomBarLabel(systemName: "square.and.arrow.down", title: "Save")
            }
            .disabled(currentLoadedData == nil)
            .opacity(currentLoadedData == nil ? 0.4 : 1)
            .accessibilityLabel("Save media to Photos")

            if let showInChat, let currentItem {
                Button {
                    onDismiss()
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
                    onDismiss()
                } else if reduceMotion {
                    dismissDrag = 0
                } else {
                    withAnimation(.spring(duration: 0.3)) { dismissDrag = 0 }
                }
            }
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

    private var currentLoadedData: Data? {
        guard let currentItem else { return nil }
        return loader.loadedData(for: currentItem.messageID)
    }

    private func byteLabel(for item: KitGalleryItem) -> String? {
        KitMediaMessageDescriptor.parse(item.descriptorText)
            .map { ChatMediaBytes.label($0.plaintextByteSize) }
    }

    private func dateLabel(for item: KitGalleryItem) -> String {
        item.createdAt.formatted(date: .abbreviated, time: .shortened)
    }

    private func accessibilityLabel(for item: KitGalleryItem) -> String {
        let kind = KitChatMediaKind(mediaType: item.mediaType) == .video ? "Video" : "Photo"
        return "\(kind) from \(item.senderName), \(dateLabel(for: item))"
    }

    // MARK: Share

    private var shareTaskIdentity: String {
        "\(selection)-\(currentLoadedData != nil)"
    }

    /// Stages the current item's loaded plaintext in a file-protected temp file so ShareLink can
    /// hand a real file to the share sheet. Images are shared as JPEG; videos in their own type.
    private func prepareShareFile() async {
        cleanUpShareFile()
        guard let currentItem, let data = currentLoadedData else { return }
        switch KitChatMediaKind(mediaType: currentItem.mediaType) {
        case .video:
            shareURL = try? ChatMediaTempFiles.writeTemporaryFile(
                data: data,
                mediaType: currentItem.mediaType,
                suggestedName: "Kit video"
            )
        default:
            guard let image = UIImage(data: data),
                  let jpeg = image.jpegData(compressionQuality: 0.9)
            else { return }
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

    private func saveCurrentItem() {
        guard let currentItem, let data = currentLoadedData else { return }
        switch KitChatMediaKind(mediaType: currentItem.mediaType) {
        case .video:
            saveVideo(data: data, mediaType: currentItem.mediaType)
        default:
            saveImage(data: data)
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
        let completion = MediaSaveCompletion { error in
            ChatMediaTempFiles.removeTemporaryFile(url)
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
private final class GalleryPageLoader: ObservableObject {
    enum PageState {
        case idle
        case loading
        case loaded(Data)
        case failed
    }

    @Published private(set) var states: [UUID: PageState] = [:]

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var loadData: ((KitGalleryItem) async throws -> Data)?

    func configure(_ loadData: @escaping (KitGalleryItem) async throws -> Data) {
        self.loadData = loadData
    }

    func state(for id: UUID) -> PageState {
        states[id] ?? .idle
    }

    func loadedData(for id: UUID) -> Data? {
        if case let .loaded(data) = state(for: id) { return data }
        return nil
    }

    func ensureLoaded(_ item: KitGalleryItem) {
        switch state(for: item.messageID) {
        case .loading, .loaded:
            return
        case .idle, .failed:
            break
        }
        guard let loadData else { return }
        states[item.messageID] = .loading
        tasks[item.messageID] = Task { [weak self] in
            do {
                let data = try await loadData(item)
                self?.states[item.messageID] = .loaded(data)
            } catch {
                if error is CancellationError || Task.isCancelled {
                    self?.states[item.messageID] = .idle
                } else {
                    self?.states[item.messageID] = .failed
                }
            }
            self?.tasks[item.messageID] = nil
        }
    }

    func retry(_ item: KitGalleryItem) {
        if case .failed = state(for: item.messageID) {
            states[item.messageID] = .idle
        }
        ensureLoaded(item)
    }

    /// Cancels in-flight loads for pages 2+ positions away from the current page, and evicts
    /// far pages' loaded plaintext. Media can be up to 200 MB each, so keeping every visited
    /// page's bytes for the whole gallery session would eventually jetsam the app; evicted
    /// pages reload instantly from the encrypted file cache when paged back to.
    func cancelLoadsFar(from index: Int, items: [KitGalleryItem]) {
        for (offset, item) in items.enumerated() where abs(offset - index) >= 2 {
            if let task = tasks[item.messageID] {
                task.cancel()
                tasks[item.messageID] = nil
            }
            switch state(for: item.messageID) {
            case .loading, .loaded:
                states[item.messageID] = .idle
            case .idle, .failed:
                break
            }
        }
    }
}

// MARK: - Image page (zoomable)

private struct GalleryImagePage: View {
    let data: Data
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
        .task(id: data) {
            let bytes = data
            let image = await Task.detached(priority: .userInitiated) {
                UIImage(data: bytes)
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

private struct GalleryVideoPage: View {
    let item: KitGalleryItem
    let data: Data
    let isActive: Bool
    let chromeVisible: Bool
    let onToggleChrome: () -> Void

    @StateObject private var controller = GalleryVideoController()
    @State private var poster: UIImage?

    private var storageKey: String? {
        KitMediaMessageDescriptor.parse(item.descriptorText)?.storageKey
    }

    var body: some View {
        ZStack {
            if let player = controller.player {
                PlayerLayerView(player: player)
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
        .task(id: item.messageID) {
            if let storageKey {
                poster = await ChatMediaThumbnailStore.shared.videoThumbnail(
                    forKey: storageKey,
                    maxPixel: 400,
                    from: data,
                    mediaType: item.mediaType
                )
            }
            controller.prepare(data: data, mediaType: item.mediaType)
        }
        .onChange(of: isActive) { _, nowActive in
            if !nowActive { controller.pause() }
        }
        .onDisappear {
            controller.teardown()
        }
    }

    @ViewBuilder
    private var controlsOverlay: some View {
        // The big play/pause control stays visible while paused so playback is always reachable.
        if chromeVisible || !controller.isPlaying {
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
        let whole = Int(seconds.rounded())
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

/// Owns the AVPlayer, its protected temp file, and observers for one video page.
@MainActor
private final class GalleryVideoController: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var isPlaying = false
    @Published private(set) var isMuted = false
    @Published private(set) var hasStartedPlayback = false
    @Published var duration: Double = 0
    @Published var currentTime: Double = 0

    private var isScrubbing = false
    private var fileURL: URL?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    func prepare(data: Data, mediaType: String) {
        guard player == nil else { return }
        guard let url = try? ChatMediaTempFiles.writeTemporaryFile(
            data: data,
            mediaType: mediaType
        ) else { return }
        fileURL = url
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        self.player = player

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self, !self.isScrubbing else { return }
                let seconds = time.seconds
                if seconds.isFinite { self.currentTime = seconds }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handlePlaybackEnded() }
        }

        Task { [weak self] in
            let loaded = try? await asset.load(.duration)
            guard let self else { return }
            if let seconds = loaded?.seconds, seconds.isFinite {
                self.duration = seconds
            }
        }
    }

    func teardown() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
        hasStartedPlayback = false
        currentTime = 0
        ChatMediaTempFiles.removeTemporaryFile(fileURL)
        fileURL = nil
    }

    func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
            hasStartedPlayback = true
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
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

    private func handlePlaybackEnded() {
        isPlaying = false
        currentTime = 0
        player?.seek(to: .zero)
    }
}

/// Bare AVPlayerLayer host so the gallery can draw its own minimal controls.
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context _: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context _: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
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
