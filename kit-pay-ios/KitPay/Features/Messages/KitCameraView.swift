import AVFoundation
import SwiftUI
import UIKit

/// Full-screen in-app camera: photo and video with pause/resume, flash/torch, flip,
/// tap-to-focus, and pinch zoom. Reports one `KitCameraOutput` (or nil on cancel);
/// review/editing happens in the presenter's editor step.
struct KitCameraView: View {
    var startInVideoMode = false
    let onFinish: (KitCameraOutput?) -> Void

    @StateObject private var controller = KitCameraController()
    @State private var focusReticle: CGPoint?
    @State private var didFinish = false

    static var isCameraAvailable: Bool {
        KitCameraController.isCameraAvailable
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if controller.isAuthorized {
                KitCameraPreviewView(
                    session: controller.session,
                    onTapToFocus: { devicePoint, layerPoint in
                        controller.focus(at: devicePoint)
                        showFocusReticle(at: layerPoint)
                    },
                    onPinchZoom: { scale, ended in
                        controller.setZoom(scale: scale, ended: ended)
                    }
                )
                .ignoresSafeArea()
            } else if controller.authorizationChecked {
                cameraDeniedState
            }

            if let focusReticle {
                Circle()
                    .stroke(KitColor.green, lineWidth: 1.6)
                    .frame(width: 68, height: 68)
                    .position(focusReticle)
                    .transition(.opacity.combined(with: .scale(scale: 1.35)))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            VStack {
                topBar
                Spacer()
                if controller.isRecording {
                    recordingStatus
                        .padding(.bottom, 10)
                }
                bottomBar
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 24)

            if controller.isProcessing {
                processingOverlay
            }
        }
        .statusBarHidden()
        .onAppear {
            if startInVideoMode { controller.mode = .video }
            controller.start()
        }
        .onDisappear { controller.stop() }
        .alert(
            "Camera",
            isPresented: Binding(
                get: { controller.errorMessage != nil },
                set: { if !$0 { controller.errorMessage = nil } }
            )
        ) {
            Button("OK") { controller.errorMessage = nil }
        } message: {
            Text(controller.errorMessage ?? "")
        }
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack {
            Button {
                finish(with: nil)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Close camera")

            Spacer()

            if controller.mode == .photo {
                Button {
                    controller.flashEnabled.toggle()
                } label: {
                    Image(systemName: controller.flashEnabled ? "bolt.fill" : "bolt.slash")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(controller.flashEnabled ? KitColor.green : .white)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel(controller.flashEnabled ? "Turn flash off" : "Turn flash on")
            } else if controller.position == .back {
                Button {
                    controller.toggleTorch()
                } label: {
                    Image(systemName: controller.torchActive ? "flashlight.on.fill" : "flashlight.off.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(controller.torchActive ? KitColor.green : .white)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel(controller.torchActive ? "Turn torch off" : "Turn torch on")
            }

            if controller.zoomFactor > 1.05 {
                Text(String(format: "%.1f×", controller.zoomFactor))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(.ultraThinMaterial, in: Capsule())
                    .accessibilityLabel(
                        String(format: "Zoom %.1f times", controller.zoomFactor)
                    )
            }
        }
    }

    private var recordingStatus: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.red)
                .frame(width: 9, height: 9)
                .opacity(controller.isPaused ? 0.35 : 1)
            Text(recordingTimeLabel)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
            if controller.isPaused {
                Text("Paused")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            controller.isPaused
                ? "Recording paused at \(recordingTimeLabel)"
                : "Recording, \(recordingTimeLabel)"
        )
    }

    private var recordingTimeLabel: String {
        let seconds = Int(controller.recordedSeconds)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var bottomBar: some View {
        VStack(spacing: 16) {
            if !controller.isRecording {
                modeSwitch
            }
            HStack {
                if controller.isRecording {
                    Button {
                        controller.cancelRecording()
                    } label: {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.red)
                            .frame(width: 52, height: 52)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("Discard recording")
                } else {
                    Color.clear.frame(width: 52, height: 52)
                }

                Spacer()

                shutterButton

                Spacer()

                if controller.isRecording {
                    Button {
                        if controller.isPaused {
                            controller.resumeRecording()
                        } else {
                            controller.pauseRecording()
                        }
                    } label: {
                        Image(systemName: controller.isPaused ? "record.circle" : "pause.fill")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel(
                        controller.isPaused ? "Resume recording" : "Pause recording"
                    )
                } else {
                    Button {
                        controller.flipCamera()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("Switch camera")
                }
            }
        }
    }

    private var modeSwitch: some View {
        HStack(spacing: 6) {
            modeChip("Photo", mode: .photo)
            modeChip("Video", mode: .video)
        }
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func modeChip(_ title: String, mode: KitCameraController.Mode) -> some View {
        let selected = controller.mode == mode
        return Button {
            withAnimation(.snappy(duration: 0.2)) { controller.mode = mode }
        } label: {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(selected ? KitColor.navy : .white)
                .padding(.horizontal, 16)
                .frame(height: 32)
                .background(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.clear), in: Capsule())
        }
        .accessibilityLabel("\(title) mode")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var shutterButton: some View {
        Button(action: shutterTapped) {
            ZStack {
                Circle()
                    .stroke(.white, lineWidth: 4)
                    .frame(width: 76, height: 76)
                if controller.mode == .photo {
                    Circle()
                        .fill(.white)
                        .frame(width: 62, height: 62)
                } else if controller.isRecording {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.red)
                        .frame(width: 30, height: 30)
                } else {
                    Circle()
                        .fill(.red)
                        .frame(width: 62, height: 62)
                }
            }
        }
        .disabled(controller.isProcessing || !controller.isAuthorized)
        .accessibilityLabel(
            controller.mode == .photo
                ? "Take photo"
                : controller.isRecording ? "Finish recording" : "Start recording"
        )
    }

    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().tint(.white)
                Text("Preparing…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preparing capture")
    }

    private var cameraDeniedState: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            Text("Camera access is off")
                .font(.headline)
                .foregroundStyle(.white)
            Text("Allow camera access in Settings to take photos and videos in chats.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(KitColor.green)
        }
        .padding(30)
    }

    // MARK: Actions

    private func shutterTapped() {
        switch controller.mode {
        case .photo:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            controller.capturePhoto { image in
                guard let image else { return }
                finish(with: .photo(image))
            }
        case .video:
            if controller.isRecording {
                controller.finishRecording { output in
                    finish(with: output)
                }
            } else {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                controller.startRecording()
            }
        }
    }

    private func finish(with output: KitCameraOutput?) {
        guard !didFinish else { return }
        didFinish = true
        onFinish(output)
    }

    private func showFocusReticle(at point: CGPoint) {
        withAnimation(.snappy(duration: 0.18)) { focusReticle = point }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            withAnimation(.easeOut(duration: 0.25)) { focusReticle = nil }
        }
    }
}

// MARK: - Preview layer host

private struct KitCameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    /// (device point 0...1, layer point) from a tap.
    let onTapToFocus: (CGPoint, CGPoint) -> Void
    /// (relative pinch scale, gesture ended)
    let onPinchZoom: (CGFloat, Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTapToFocus: onTapToFocus, onPinchZoom: onPinchZoom)
    }

    func makeUIView(context: Context) -> PreviewHostView {
        let view = PreviewHostView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        context.coordinator.attachGestures(to: view)
        return view
    }

    func updateUIView(_ uiView: PreviewHostView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
    }

    final class PreviewHostView: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }

    final class Coordinator: NSObject {
        private let onTapToFocus: (CGPoint, CGPoint) -> Void
        private let onPinchZoom: (CGFloat, Bool) -> Void

        init(
            onTapToFocus: @escaping (CGPoint, CGPoint) -> Void,
            onPinchZoom: @escaping (CGFloat, Bool) -> Void
        ) {
            self.onTapToFocus = onTapToFocus
            self.onPinchZoom = onPinchZoom
        }

        func attachGestures(to view: PreviewHostView) {
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            let pinch = UIPinchGestureRecognizer(
                target: self,
                action: #selector(handlePinch(_:))
            )
            view.addGestureRecognizer(tap)
            view.addGestureRecognizer(pinch)
        }

        @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view as? PreviewHostView else { return }
            let layerPoint = recognizer.location(in: view)
            let devicePoint = view.previewLayer.captureDevicePointConverted(
                fromLayerPoint: layerPoint
            )
            onTapToFocus(devicePoint, layerPoint)
        }

        @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            switch recognizer.state {
            case .changed:
                onPinchZoom(recognizer.scale, false)
            case .ended, .cancelled:
                onPinchZoom(recognizer.scale, true)
            default:
                break
            }
        }
    }
}
