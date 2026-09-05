import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

// MARK: - Editor input/output

enum KitMediaEditorInput {
    case photo(UIImage)
    /// A temporary file the presenter owns; the editor never deletes it.
    case video(URL, mediaType: String)
}

enum KitMediaEditorOutput {
    case photo(UIImage)
    /// May be the untouched input URL (no trim) or a new temporary file the presenter owns.
    case video(URL, mediaType: String)
}

/// Creative editor shown between capture/selection and staging: drawing, text and emoji
/// overlays, filters, rotate, and aspect crop for photos; trim for videos.
struct KitMediaEditorView: View {
    let input: KitMediaEditorInput
    let onFinish: (KitMediaEditorOutput?) -> Void

    var body: some View {
        switch input {
        case .photo(let image):
            KitPhotoEditorView(original: image, onFinish: onFinish)
        case .video(let url, let mediaType):
            KitVideoTrimView(fileURL: url, mediaType: mediaType, onFinish: onFinish)
        }
    }
}

// MARK: - Photo editor

private struct KitPhotoEditorView: View {
    let original: UIImage
    let onFinish: (KitMediaEditorOutput?) -> Void

    enum Tool: Equatable {
        case none, draw, text, sticker, filters, cropRotate
    }

    @State private var workingImage: UIImage
    @State private var filter: KitPhotoFilter = .original
    @State private var filteredPreview: UIImage?
    @State private var cropAspect: KitCropAspect = .original
    @State private var strokes: [EditorStroke] = []
    @State private var activeStroke: EditorStroke?
    @State private var overlays: [EditorOverlay] = []
    @State private var history: [EditorHistoryEntry] = []
    @State private var redoStack: [EditorHistoryEntry] = []
    @State private var tool: Tool = .none
    @State private var strokeColor: Color = .white
    @State private var strokeWidth: CGFloat = 0.012
    @State private var selectedOverlayID: UUID?
    @State private var draftText = ""
    @State private var isEnteringText = false
    @State private var isRendering = false
    @FocusState private var textFieldFocused: Bool

    init(original: UIImage, onFinish: @escaping (KitMediaEditorOutput?) -> Void) {
        self.original = original
        self.onFinish = onFinish
        _workingImage = State(initialValue: original.kitNormalizedOrientation())
    }

    private var displayImage: UIImage { filteredPreview ?? workingImage }

    var body: some View {
        VStack(spacing: 0) {
            editorHeader
            GeometryReader { geometry in
                let fitted = fittedRect(in: geometry.size)
                ZStack {
                    Color.black
                    canvas(in: fitted)
                }
            }
            .clipped()
            editorToolbar
        }
        .background(Color.black.ignoresSafeArea())
        .statusBarHidden()
        .overlay {
            if isRendering {
                ZStack {
                    Color.black.opacity(0.55).ignoresSafeArea()
                    ProgressView().tint(.white)
                }
            }
        }
    }

    // MARK: Layout

    private func fittedRect(in container: CGSize) -> CGRect {
        let size = displayImage.size
        guard size.width > 0, size.height > 0,
              container.width > 0, container.height > 0
        else { return .zero }
        let scale = min(container.width / size.width, container.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(
            x: (container.width - fitted.width) / 2,
            y: (container.height - fitted.height) / 2,
            width: fitted.width,
            height: fitted.height
        )
    }

    @ViewBuilder
    private func canvas(in rect: CGRect) -> some View {
        ZStack {
            Image(uiImage: displayImage)
                .resizable()
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            strokesLayer(in: rect)
            overlaysLayer(in: rect)
            cropMask(in: rect)
        }
        .contentShape(Rectangle())
        .gesture(tool == .draw ? drawGesture(in: rect) : nil)
        .onTapGesture {
            if tool != .draw { selectedOverlayID = nil }
        }
    }

    private func strokesLayer(in rect: CGRect) -> some View {
        Canvas { context, _ in
            for stroke in strokes + (activeStroke.map { [$0] } ?? []) {
                guard stroke.points.count > 1 else { continue }
                var path = Path()
                path.move(to: stroke.points[0].denormalized(in: rect))
                for point in stroke.points.dropFirst() {
                    path.addLine(to: point.denormalized(in: rect))
                }
                context.stroke(
                    path,
                    with: .color(stroke.color),
                    style: StrokeStyle(
                        lineWidth: stroke.normalizedWidth * rect.width,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            }
        }
        .allowsHitTesting(false)
    }

    private func overlaysLayer(in rect: CGRect) -> some View {
        ForEach(overlays) { overlay in
            overlayView(overlay, in: rect)
        }
    }

    private func overlayView(_ overlay: EditorOverlay, in rect: CGRect) -> some View {
        let isSelected = selectedOverlayID == overlay.id
        return Text(overlay.text)
            .font(.system(
                size: EditorOverlay.baseFontFraction * min(rect.width, rect.height)
                    * overlay.scale,
                weight: .bold
            ))
            .foregroundStyle(overlay.color)
            .shadow(color: .black.opacity(overlay.isEmoji ? 0 : 0.45), radius: 2, y: 1)
            .padding(6)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(
                            KitColor.green,
                            style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])
                        )
                }
            }
            .position(overlay.center.denormalized(in: rect))
            .gesture(
                DragGesture()
                    .onChanged { value in
                        selectedOverlayID = overlay.id
                        updateOverlay(overlay.id) {
                            $0.center = EditorPoint(
                                x: min(1, max(0, (value.location.x - rect.minX) / rect.width)),
                                y: min(1, max(0, (value.location.y - rect.minY) / rect.height))
                            )
                        }
                    }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in
                        selectedOverlayID = overlay.id
                        updateOverlay(overlay.id) {
                            $0.scale = min(5, max(0.35, $0.steadyScale * value))
                        }
                    }
                    .onEnded { _ in
                        updateOverlay(overlay.id) { $0.steadyScale = $0.scale }
                    }
            )
            .onTapGesture { selectedOverlayID = overlay.id }
            .accessibilityLabel(overlay.isEmoji ? "Sticker \(overlay.text)" : "Text \(overlay.text)")
    }

    @ViewBuilder
    private func cropMask(in rect: CGRect) -> some View {
        if cropAspect != .original, rect.width > 0 {
            let crop = cropAspect.rect(for: rect.size)
            Path { path in
                path.addRect(CGRect(origin: .zero, size: rect.size))
                path.addRect(crop)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .overlay(
                Rectangle()
                    .stroke(.white.opacity(0.9), lineWidth: 1)
                    .frame(width: crop.width, height: crop.height)
                    .position(x: crop.midX, y: crop.midY)
            )
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
        }
    }

    private func drawGesture(in rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let point = EditorPoint(
                    x: (value.location.x - rect.minX) / rect.width,
                    y: (value.location.y - rect.minY) / rect.height
                )
                if activeStroke == nil {
                    activeStroke = EditorStroke(
                        points: [point],
                        color: strokeColor,
                        normalizedWidth: strokeWidth
                    )
                } else {
                    activeStroke?.points.append(point)
                }
            }
            .onEnded { _ in
                guard let stroke = activeStroke else { return }
                activeStroke = nil
                guard stroke.points.count > 1 else { return }
                strokes.append(stroke)
                history.append(.stroke(stroke.id))
                redoStack = []
            }
    }

    // MARK: Header / toolbar

    private var editorHeader: some View {
        HStack(spacing: 10) {
            Button {
                onFinish(nil)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Discard edits")

            Spacer()

            Button(action: undo) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .disabled(history.isEmpty)
            .opacity(history.isEmpty ? 0.4 : 1)
            .accessibilityLabel("Undo")

            Button(action: redo) {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .disabled(redoStack.isEmpty)
            .opacity(redoStack.isEmpty ? 0.4 : 1)
            .accessibilityLabel("Redo")

            if selectedOverlayID != nil {
                Button {
                    if let id = selectedOverlayID {
                        removeOverlay(id)
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.red)
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Delete selected overlay")
            }

            Spacer()

            Button(action: renderAndFinish) {
                Text("Done")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .frame(height: 44)
                    .background(KitColor.green, in: Capsule())
            }
            .disabled(isRendering)
            .accessibilityLabel("Use photo")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var editorToolbar: some View {
        VStack(spacing: 10) {
            if isEnteringText {
                textEntryBar
            } else if tool == .draw {
                drawOptionsBar
            } else if tool == .sticker {
                stickerBar
            } else if tool == .filters {
                filterBar
            } else if tool == .cropRotate {
                cropRotateBar
            }

            HStack(spacing: 8) {
                toolChip("pencil.tip", tool: .draw, label: "Draw")
                toolChip("textformat", tool: .text, label: "Text")
                toolChip("face.smiling", tool: .sticker, label: "Sticker")
                toolChip("camera.filters", tool: .filters, label: "Filters")
                toolChip("crop.rotate", tool: .cropRotate, label: "Crop & rotate")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 20)
    }

    private func toolChip(_ systemName: String, tool target: Tool, label: String) -> some View {
        let selected = tool == target
        return Button {
            withAnimation(.snappy(duration: 0.2)) {
                if tool == target {
                    tool = .none
                    isEnteringText = false
                } else {
                    tool = target
                    if target == .text {
                        draftText = ""
                        isEnteringText = true
                        textFieldFocused = true
                    } else {
                        isEnteringText = false
                    }
                }
            }
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(selected ? KitColor.navy : .white)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(
                    selected ? AnyShapeStyle(.white) : AnyShapeStyle(.ultraThinMaterial),
                    in: Capsule()
                )
        }
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var drawOptionsBar: some View {
        HStack(spacing: 10) {
            ForEach(EditorPalette.colors, id: \.self) { color in
                Button {
                    strokeColor = color
                } label: {
                    Circle()
                        .fill(color)
                        .frame(width: 26, height: 26)
                        .overlay {
                            Circle().stroke(
                                .white,
                                lineWidth: strokeColor == color ? 2.4 : 0.8
                            )
                        }
                }
                .accessibilityLabel("Brush colour")
            }
            Spacer()
            Slider(value: $strokeWidth, in: 0.004 ... 0.035)
                .frame(width: 110)
                .tint(KitColor.green)
                .accessibilityLabel("Brush size")
        }
        .padding(.horizontal, 4)
    }

    private var textEntryBar: some View {
        HStack(spacing: 8) {
            TextField("Add text", text: $draftText)
                .focused($textFieldFocused)
                .submitLabel(.done)
                .onSubmit(commitDraftText)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 42)
                .background(.ultraThinMaterial, in: Capsule())
            ForEach([Color.white, KitColor.green, .yellow, .red], id: \.self) { color in
                Button {
                    strokeColor = color
                } label: {
                    Circle()
                        .fill(color)
                        .frame(width: 24, height: 24)
                        .overlay {
                            Circle().stroke(
                                .white,
                                lineWidth: strokeColor == color ? 2.2 : 0.7
                            )
                        }
                }
                .accessibilityLabel("Text colour")
            }
            Button("Add", action: commitDraftText)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(KitColor.green)
                .disabled(draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var stickerBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(EditorPalette.stickers, id: \.self) { emoji in
                    Button {
                        addOverlay(text: emoji, isEmoji: true, color: .white)
                    } label: {
                        Text(emoji).font(.system(size: 30))
                    }
                    .accessibilityLabel("Add \(emoji) sticker")
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(height: 44)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(KitPhotoFilter.allCases) { candidate in
                    Button {
                        applyFilter(candidate)
                    } label: {
                        Text(candidate.title)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(filter == candidate ? KitColor.navy : .white)
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .background(
                                filter == candidate
                                    ? AnyShapeStyle(.white)
                                    : AnyShapeStyle(.ultraThinMaterial),
                                in: Capsule()
                            )
                    }
                    .accessibilityLabel("\(candidate.title) filter")
                    .accessibilityAddTraits(filter == candidate ? .isSelected : [])
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(height: 40)
    }

    private var cropRotateBar: some View {
        HStack(spacing: 8) {
            Button {
                rotateQuarterTurn()
            } label: {
                Image(systemName: "rotate.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 40)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .accessibilityLabel("Rotate 90 degrees")

            ForEach(KitCropAspect.allCases) { aspect in
                Button {
                    cropAspect = aspect
                } label: {
                    Text(aspect.title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(cropAspect == aspect ? KitColor.navy : .white)
                        .padding(.horizontal, 12)
                        .frame(height: 40)
                        .background(
                            cropAspect == aspect
                                ? AnyShapeStyle(.white)
                                : AnyShapeStyle(.ultraThinMaterial),
                            in: Capsule()
                        )
                }
                .accessibilityLabel("Crop \(aspect.title)")
                .accessibilityAddTraits(cropAspect == aspect ? .isSelected : [])
            }
        }
    }

    // MARK: Mutations

    private func commitDraftText() {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        addOverlay(text: text, isEmoji: false, color: strokeColor)
        draftText = ""
        isEnteringText = false
        textFieldFocused = false
        tool = .none
    }

    private func addOverlay(text: String, isEmoji: Bool, color: Color) {
        let overlay = EditorOverlay(
            text: text,
            isEmoji: isEmoji,
            color: isEmoji ? .white : color,
            center: EditorPoint(x: 0.5, y: 0.5)
        )
        overlays.append(overlay)
        history.append(.overlay(overlay.id))
        redoStack = []
        selectedOverlayID = overlay.id
    }

    private func updateOverlay(_ id: UUID, _ mutate: (inout EditorOverlay) -> Void) {
        guard let index = overlays.firstIndex(where: { $0.id == id }) else { return }
        mutate(&overlays[index])
    }

    private func removeOverlay(_ id: UUID) {
        selectedOverlayID = nil
        guard let index = overlays.firstIndex(where: { $0.id == id }) else { return }
        let overlay = overlays.remove(at: index)
        history.removeAll { $0 == .overlay(overlay.id) }
        redoStack.removeAll { $0 == .overlay(overlay.id) }
    }

    private func undo() {
        guard let entry = history.popLast() else { return }
        redoStack.append(entry)
        switch entry {
        case .stroke(let id):
            if let index = strokes.lastIndex(where: { $0.id == id }) {
                redoStrokes[id] = strokes.remove(at: index)
            }
        case .overlay(let id):
            if selectedOverlayID == id { selectedOverlayID = nil }
            if let index = overlays.lastIndex(where: { $0.id == id }) {
                redoOverlays[id] = overlays.remove(at: index)
            }
        }
    }

    private func redo() {
        guard let entry = redoStack.popLast() else { return }
        history.append(entry)
        switch entry {
        case .stroke(let id):
            if let stroke = redoStrokes.removeValue(forKey: id) {
                strokes.append(stroke)
            }
        case .overlay(let id):
            if let overlay = redoOverlays.removeValue(forKey: id) {
                overlays.append(overlay)
            }
        }
    }

    @State private var redoStrokes: [UUID: EditorStroke] = [:]
    @State private var redoOverlays: [UUID: EditorOverlay] = [:]

    private func applyFilter(_ candidate: KitPhotoFilter) {
        filter = candidate
        guard candidate != .original else {
            filteredPreview = nil
            return
        }
        let source = workingImage
        Task.detached(priority: .userInitiated) {
            let rendered = candidate.apply(to: source)
            await MainActor.run {
                guard filter == candidate else { return }
                filteredPreview = rendered
            }
        }
    }

    private func rotateQuarterTurn() {
        workingImage = workingImage.kitRotatedQuarterTurnClockwise()
        // Rotate the preview synchronously so displayImage is never a stale, unrotated frame
        // under already-rotated annotations. All the filters are pointwise colour effects, so
        // rotating the filtered preview equals filtering the rotated base.
        filteredPreview = filteredPreview?.kitRotatedQuarterTurnClockwise()
        // Rotate every normalized annotation with the pixels: (x, y) -> (1 - y, x).
        strokes = strokes.map { stroke in
            var rotated = stroke
            rotated.points = stroke.points.map { EditorPoint(x: 1 - $0.y, y: $0.x) }
            return rotated
        }
        activeStroke = nil
        overlays = overlays.map { overlay in
            var rotated = overlay
            rotated.center = EditorPoint(x: 1 - overlay.center.y, y: overlay.center.x)
            return rotated
        }
    }

    // MARK: Final render

    private func renderAndFinish() {
        isRendering = true
        // Export from the working image plus the SELECTED filter, never the preview: an
        // in-flight preview task must not decide what the flattened photo looks like.
        let working = workingImage
        let selectedFilter = filter
        let strokesToDraw = strokes
        let overlaysToDraw = overlays
        let aspect = cropAspect
        Task.detached(priority: .userInitiated) {
            let base = selectedFilter.apply(to: working)
            let flattened = KitPhotoEditorRenderer.render(
                base: base,
                strokes: strokesToDraw,
                overlays: overlaysToDraw,
                cropAspect: aspect
            )
            await MainActor.run {
                isRendering = false
                onFinish(.photo(flattened))
            }
        }
    }
}

// MARK: - Photo editor model types

private struct EditorPoint: Equatable {
    var x: CGFloat
    var y: CGFloat

    func denormalized(in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
    }
}

private struct EditorStroke: Identifiable, Equatable {
    let id = UUID()
    var points: [EditorPoint]
    let color: Color
    /// Line width as a fraction of the image width, so it scales with the render size.
    let normalizedWidth: CGFloat
}

private struct EditorOverlay: Identifiable, Equatable {
    static let baseFontFraction: CGFloat = 0.10

    let id = UUID()
    let text: String
    let isEmoji: Bool
    let color: Color
    var center: EditorPoint
    var scale: CGFloat = 1
    var steadyScale: CGFloat = 1
}

private enum EditorHistoryEntry: Equatable {
    case stroke(UUID)
    case overlay(UUID)
}

private enum EditorPalette {
    static let colors: [Color] = [
        .white, .black, .red, .orange, .yellow, KitColor.green, .blue, .purple,
    ]
    static let stickers = [
        "😂", "❤️", "🔥", "👍", "🎉", "😍", "🙏", "💯", "😎", "🥳", "😭", "🤝",
        "🇺🇬", "💸", "☀️", "🌙",
    ]
}

private enum KitPhotoFilter: String, CaseIterable, Identifiable {
    case original, mono, noir, chrome, fade, vivid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: "Original"
        case .mono: "Mono"
        case .noir: "Noir"
        case .chrome: "Chrome"
        case .fade: "Fade"
        case .vivid: "Vivid"
        }
    }

    private static let context = CIContext()

    func apply(to image: UIImage) -> UIImage {
        guard self != .original, let cgImage = image.cgImage else { return image }
        let input = CIImage(cgImage: cgImage)
        let output: CIImage?
        switch self {
        case .original:
            output = input
        case .mono:
            let filter = CIFilter.photoEffectMono()
            filter.inputImage = input
            output = filter.outputImage
        case .noir:
            let filter = CIFilter.photoEffectNoir()
            filter.inputImage = input
            output = filter.outputImage
        case .chrome:
            let filter = CIFilter.photoEffectChrome()
            filter.inputImage = input
            output = filter.outputImage
        case .fade:
            let filter = CIFilter.photoEffectFade()
            filter.inputImage = input
            output = filter.outputImage
        case .vivid:
            let filter = CIFilter.colorControls()
            filter.inputImage = input
            filter.saturation = 1.35
            filter.contrast = 1.05
            filter.brightness = 0.01
            output = filter.outputImage
        }
        guard let output,
              let rendered = Self.context.createCGImage(output, from: output.extent)
        else { return image }
        return UIImage(cgImage: rendered, scale: image.scale, orientation: .up)
    }
}

private enum KitCropAspect: String, CaseIterable, Identifiable {
    case original, square, fourFive, sixteenNine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: "Original"
        case .square: "1:1"
        case .fourFive: "4:5"
        case .sixteenNine: "16:9"
        }
    }

    private var ratio: CGFloat? {
        switch self {
        case .original: nil
        case .square: 1
        case .fourFive: 4.0 / 5.0
        case .sixteenNine: 16.0 / 9.0
        }
    }

    /// Centered crop of `size` at this aspect (width/height), in the same coordinate space.
    func rect(for size: CGSize) -> CGRect {
        guard let ratio, size.width > 0, size.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        var cropSize = size
        if size.width / size.height > ratio {
            cropSize.width = size.height * ratio
        } else {
            cropSize.height = size.width / ratio
        }
        return CGRect(
            x: (size.width - cropSize.width) / 2,
            y: (size.height - cropSize.height) / 2,
            width: cropSize.width,
            height: cropSize.height
        )
    }
}

/// Flattens the base image plus annotations into one bitmap at full image resolution.
private enum KitPhotoEditorRenderer {
    static func render(
        base: UIImage,
        strokes: [EditorStroke],
        overlays: [EditorOverlay],
        cropAspect: KitCropAspect
    ) -> UIImage {
        let fullRect = CGRect(origin: .zero, size: base.size)
        let cropRect = cropAspect.rect(for: base.size)
        let format = UIGraphicsImageRendererFormat()
        format.scale = base.scale
        let renderer = UIGraphicsImageRenderer(size: cropRect.size, format: format)
        return renderer.image { rendererContext in
            let context = rendererContext.cgContext
            context.translateBy(x: -cropRect.minX, y: -cropRect.minY)

            base.draw(in: fullRect)

            for stroke in strokes where stroke.points.count > 1 {
                let path = UIBezierPath()
                path.move(to: stroke.points[0].denormalized(in: fullRect))
                for point in stroke.points.dropFirst() {
                    path.addLine(to: point.denormalized(in: fullRect))
                }
                path.lineWidth = stroke.normalizedWidth * fullRect.width
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                UIColor(stroke.color).setStroke()
                path.stroke()
            }

            for overlay in overlays {
                let fontSize = EditorOverlay.baseFontFraction
                    * min(fullRect.width, fullRect.height) * overlay.scale
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: fontSize, weight: .bold),
                    .foregroundColor: UIColor(overlay.color),
                ]
                if !overlay.isEmoji {
                    let shadow = NSShadow()
                    shadow.shadowColor = UIColor.black.withAlphaComponent(0.45)
                    shadow.shadowBlurRadius = fontSize * 0.06
                    shadow.shadowOffset = CGSize(width: 0, height: fontSize * 0.03)
                    attributes[.shadow] = shadow
                }
                let string = NSAttributedString(string: overlay.text, attributes: attributes)
                let bounds = string.size()
                let center = overlay.center.denormalized(in: fullRect)
                string.draw(at: CGPoint(
                    x: center.x - bounds.width / 2,
                    y: center.y - bounds.height / 2
                ))
            }
        }
    }
}

private extension UIImage {
    /// Redraws so `imageOrientation` is `.up`; annotation math assumes untransformed pixels.
    func kitNormalizedOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }

    func kitRotatedQuarterTurnClockwise() -> UIImage {
        let newSize = CGSize(width: size.height, height: size.width)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: newSize, format: format).image { context in
            let cg = context.cgContext
            cg.translateBy(x: newSize.width, y: 0)
            cg.rotate(by: .pi / 2)
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

// MARK: - Video trim

private struct KitVideoTrimView: View {
    let fileURL: URL
    let mediaType: String
    let onFinish: (KitMediaEditorOutput?) -> Void

    @State private var player: AVPlayer?
    @State private var duration: Double = 0
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 0
    @State private var isPlaying = false
    @State private var isExporting = false
    @State private var exportFailed = false
    @State private var timeObserver: Any?

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                Color.black
                if let player {
                    KitTrimPlayerLayerView(player: player)
                }
                Button {
                    togglePlayback()
                } label: {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 58))
                        .foregroundStyle(
                            .white.opacity(isPlaying ? 0.35 : 0.92),
                            KitColor.green.opacity(isPlaying ? 0.3 : 0.9)
                        )
                        .contentShape(Circle())
                }
                .accessibilityLabel(isPlaying ? "Pause" : "Play")
            }
            trimControls
        }
        .background(Color.black.ignoresSafeArea())
        .statusBarHidden()
        .onAppear(perform: preparePlayer)
        .onDisappear(perform: teardown)
        .overlay {
            if isExporting {
                ZStack {
                    Color.black.opacity(0.55).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView().tint(.white)
                        Text("Trimming…")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                }
            }
        }
        .alert("The video could not be trimmed.", isPresented: $exportFailed) {
            Button("OK") {}
        }
    }

    private var header: some View {
        HStack {
            Button {
                onFinish(nil)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Discard video")

            Spacer()

            Text(trimSummary)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))

            Spacer()

            Button(action: exportTrim) {
                Text("Done")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .frame(height: 44)
                    .background(KitColor.green, in: Capsule())
            }
            .disabled(isExporting || duration <= 0)
            .accessibilityLabel("Use video")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var trimSummary: String {
        guard duration > 0 else { return "" }
        return "\(timeLabel(trimStart)) – \(timeLabel(trimEnd)) · \(timeLabel(max(0, trimEnd - trimStart)))"
    }

    private var trimControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Text("Start")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 40, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { trimStart },
                        set: { value in
                            trimStart = min(value, max(0, trimEnd - 0.5))
                            seek(to: trimStart)
                        }
                    ),
                    in: 0 ... max(0.5, duration)
                )
                .tint(KitColor.green)
                .accessibilityLabel("Trim start")
                Text(timeLabel(trimStart))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 44, alignment: .trailing)
            }
            HStack(spacing: 10) {
                Text("End")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 40, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { trimEnd },
                        set: { value in
                            trimEnd = max(value, trimStart + 0.5)
                            seek(to: max(trimStart, trimEnd - 1))
                        }
                    ),
                    in: 0 ... max(0.5, duration)
                )
                .tint(KitColor.green)
                .accessibilityLabel("Trim end")
                Text(timeLabel(trimEnd))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 44, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 22)
    }

    private func timeLabel(_ seconds: Double) -> String {
        ChatMediaPlaybackClock.label(seconds)
    }

    private func preparePlayer() {
        let asset = AVURLAsset(url: fileURL)
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        self.player = player
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
            queue: .main
        ) { [weak player] time in
            // Loop playback within the trimmed window. When the trim end coincides with the
            // natural end of the asset the player pauses itself, so restart it explicitly.
            if isPlaying, trimEnd > 0, time.seconds >= trimEnd - 0.05 {
                seek(to: trimStart)
                player?.play()
            }
        }
        Task {
            if let loaded = try? await asset.load(.duration), loaded.seconds.isFinite {
                duration = loaded.seconds
                trimEnd = loaded.seconds
            }
        }
    }

    private func teardown() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.pause()
        player = nil
    }

    private func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if trimEnd > 0, player.currentTime().seconds >= trimEnd - 0.05 {
                seek(to: trimStart)
            }
            player.play()
            isPlaying = true
        }
    }

    private func seek(to seconds: Double) {
        player?.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    private func exportTrim() {
        player?.pause()
        isPlaying = false
        // Untrimmed: pass the original straight through.
        if trimStart <= 0.05, trimEnd >= duration - 0.05 {
            onFinish(.video(fileURL, mediaType: mediaType))
            return
        }
        isExporting = true
        let range = CMTimeRange(
            start: CMTime(seconds: trimStart, preferredTimescale: 600),
            end: CMTime(seconds: trimEnd, preferredTimescale: 600)
        )
        let sourceURL = fileURL
        Task {
            // Passthrough keeps the original encoding and is near-instant; some codecs
            // cannot passthrough into MP4, so fall back to a re-encode.
            var resolved = await Self.export(url: sourceURL, range: range, passthrough: true)
            if resolved == nil {
                resolved = await Self.export(url: sourceURL, range: range, passthrough: false)
            }
            await MainActor.run {
                isExporting = false
                if let resolved {
                    onFinish(.video(resolved, mediaType: "video/mp4"))
                } else {
                    exportFailed = true
                }
            }
        }
    }

    private static func export(url: URL, range: CMTimeRange, passthrough: Bool) async -> URL? {
        let asset = AVURLAsset(url: url)
        let preset = passthrough
            ? AVAssetExportPresetPassthrough
            : AVAssetExportPresetHighestQuality
        guard let export = AVAssetExportSession(asset: asset, presetName: preset) else {
            return nil
        }
        guard let outputURL = try? KitCaptureTemporaryFileStore.makeFileURL(
            directoryPrefix: KitCaptureTemporaryFileStore.editorDirectoryPrefix,
            fileName: "clip.mp4"
        ) else { return nil }
        export.outputURL = outputURL
        export.outputFileType = .mp4
        export.timeRange = range
        export.shouldOptimizeForNetworkUse = true
        export.fileLengthLimit = Int64(
            Double(SecureMediaAttachmentCipher.maximumPlaintextBytes) * 0.92
        )
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { continuation.resume() }
        }
        guard export.status == .completed,
              (try? KitCaptureTemporaryFileStore.protectFile(at: outputURL)) != nil
        else {
            try? FileManager.default.removeItem(at: outputURL.deletingLastPathComponent())
            return nil
        }
        return outputURL
    }
}

private struct KitTrimPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context _: Context) -> HostView {
        let view = HostView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: HostView, context _: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }

    final class HostView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
