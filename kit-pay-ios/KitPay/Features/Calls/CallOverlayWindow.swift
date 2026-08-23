import AVKit
import Combine
import LiveKit
import SwiftUI
import UIKit

/// Ownership of the floating minimized-call surface.
///
/// The bubble used to live in `RootView`'s overlay. UIKit places sheets and full-screen covers in
/// their own presentation contexts *above* that overlay, so opening a wallet flow, global search,
/// the profile editor, or any other modal hid an ongoing call until the user backed out. Hosting
/// the bubble in a dedicated pass-through window above `.normal` keeps exactly one call surface on
/// screen no matter what the app presents, and gives Picture in Picture a stable source view so a
/// video call keeps playing after the user leaves Kit Pay entirely.
@MainActor
final class CallOverlayPresenter: ObservableObject {
    /// Which screen edge the bubble rests against. Owned here rather than in the app scene so the
    /// resting corner survives every presentation change.
    @Published var corner: CallFloatingCorner = .bottomTrailing

    /// Whether the floating bubble is drawn. The window itself stays attached for the whole call
    /// so Picture in Picture always has a live source view, including while the full-screen call
    /// UI is what the user is looking at.
    @Published fileprivate var showsSurface = false

    /// Where the bubble is drawn, in window coordinates. Written outside the SwiftUI update cycle
    /// and read by the window's hit test, so touches anywhere else reach the app underneath.
    fileprivate let hitRegion = CallOverlayHitRegion()

    fileprivate var reopen: () -> Void = {}
}

/// A plain reference box. Deliberately not `@Published`: the bubble reports its frame during
/// layout, and publishing it would re-enter the SwiftUI update it was measured in.
@MainActor
final class CallOverlayHitRegion {
    var frame: CGRect = .zero
}

/// Only forwards touches that land on the call bubble itself. Every other point falls through to
/// the app's own window, so the overlay never blocks the interface it floats above.
final class CallOverlayPassthroughWindow: UIWindow {
    /// Set from the main actor; read on the main thread during hit testing.
    var interactiveFrameProvider: (() -> CGRect)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let frame = interactiveFrameProvider?(), frame.contains(point) else { return nil }
        return super.hitTest(point, with: event)
    }
}

@MainActor
final class CallOverlayWindowController {
    static let shared = CallOverlayWindowController()

    let presenter = CallOverlayPresenter()

    private var window: CallOverlayPassthroughWindow?
    private let pictureInPicture = CallPictureInPictureCoordinator()
    private var remoteVideoTrackObservation: AnyCancellable?
    private var audioRouteObservation: AnyCancellable?

    private init() {
        pictureInPicture.onDeferredInvalidationCompleted = { [weak self] in
            self?.refreshPictureInPicture()
        }
        remoteVideoTrackObservation = CallMediaCoordinator.shared.media.$remoteVideoTrack
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] _ in
                // LiveKit publishes on the main actor, but Combine's closure is not actor-typed.
                Task { @MainActor [weak self] in
                    CallMediaCoordinator.shared.refreshCallKitVideoState()
                    self?.refreshPictureInPicture()
                }
            }
        audioRouteObservation = CallMediaCoordinator.shared.media.$audioRoute
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let coordinator = CallMediaCoordinator.shared
                    self.applyScreenWakePolicy(
                        hasActiveCall: coordinator.activeCall != nil && self.window != nil
                    )
                }
            }
    }

    /// Attaches the call window for the lifetime of a call and controls whether the floating
    /// bubble is drawn. `reopen` runs when the user taps the bubble or restores from Picture in
    /// Picture.
    ///
    /// The window stays attached even while the full-screen call UI is showing, because Picture in
    /// Picture needs a source view that is already on screen: without it, leaving the app from the
    /// call screen — the most common way to trigger a hand-off — would not start Picture in
    /// Picture at all.
    func update(
        hasActiveCall: Bool,
        showsMinimizedSurface: Bool,
        reopen: @escaping () -> Void
    ) {
        presenter.reopen = reopen
        pictureInPicture.onRestore = reopen

        guard hasActiveCall else {
            hide()
            return
        }
        if presenter.showsSurface != showsMinimizedSurface {
            presenter.showsSurface = showsMinimizedSurface
        }
        if !showsMinimizedSurface {
            presenter.hitRegion.frame = .zero
        }
        applyScreenWakePolicy(hasActiveCall: true)
        guard let window = ensureWindow() else { return }
        window.isHidden = false
        refreshPictureInPicture()
    }

    /// Keeps the screen awake for video and arms the ear-proximity blanking for audio. Runs on
    /// every call/camera transition through `update`/`refreshPictureInPicture`/`hide`.
    /// `hasActiveCall` is passed in (not derived) so a call concealed behind the privacy shield
    /// releases the wake locks even though the coordinator still holds the call.
    private func applyScreenWakePolicy(hasActiveCall: Bool) {
        let coordinator = CallMediaCoordinator.shared
        let carriesVideo = coordinator.callCarriesVideo
        UIApplication.shared.isIdleTimerDisabled = CallScreenWakePolicy.idleTimerDisabled(
            hasActiveCall: hasActiveCall,
            carriesVideo: carriesVideo
        )
        UIDevice.current.isProximityMonitoringEnabled =
            CallScreenWakePolicy.proximityMonitoringEnabled(
                hasActiveCall: hasActiveCall,
                carriesVideo: carriesVideo,
                audioRoute: coordinator.media.audioRoute
            )
    }

    /// Arms or disarms Picture in Picture for the current call. Audio calls deliberately never
    /// hand off: a Picture in Picture window with nothing to show is worse than the system's own
    /// call indicator. Called again when the camera is toggled, so a call that escalates from
    /// audio to video gains the hand-off without restarting.
    func refreshPictureInPicture() {
        let coordinator = CallMediaCoordinator.shared
        // `window == nil` after hide() covers the concealed state without re-deriving it here.
        applyScreenWakePolicy(hasActiveCall: coordinator.activeCall != nil && window != nil)
        guard coordinator.callCarriesVideo,
              let sourceView = window?.rootViewController?.view
        else {
            pictureInPicture.invalidate()
            return
        }
        pictureInPicture.configure(
            sourceView: sourceView,
            coordinator: CallMediaCoordinator.shared
        )
    }

    /// Tears the surface and any Picture in Picture session down. Called when the call ends and
    /// whenever communication surfaces are concealed.
    func hide() {
        presenter.showsSurface = false
        pictureInPicture.invalidate()
        presenter.hitRegion.frame = .zero
        window?.isHidden = true
        window?.rootViewController = nil
        window?.windowScene = nil
        window = nil
        UIApplication.shared.isIdleTimerDisabled = false
        UIDevice.current.isProximityMonitoringEnabled = false
    }

    private func ensureWindow() -> CallOverlayPassthroughWindow? {
        if let window, window.windowScene != nil { return window }
        guard let scene = foregroundWindowScene() else { return nil }

        let created = window ?? CallOverlayPassthroughWindow(windowScene: scene)
        created.windowScene = scene
        // Above the app's own window so sheets and full-screen covers cannot bury the call, and
        // below the system alert level so permission prompts still come out on top.
        created.windowLevel = .normal + 1
        created.backgroundColor = .clear
        created.isOpaque = false
        let hitRegion = presenter.hitRegion
        created.interactiveFrameProvider = { MainActor.assumeIsolated { hitRegion.frame } }

        let host = UIHostingController(
            rootView: CallOverlayRootView(
                presenter: presenter,
                coordinator: CallMediaCoordinator.shared
            )
        )
        host.view.backgroundColor = .clear
        host.view.isOpaque = false
        created.rootViewController = host
        window = created
        return created
    }

    private func foregroundWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
            ?? scenes.first
    }
}

private struct CallOverlayRootView: View {
    @ObservedObject var presenter: CallOverlayPresenter
    @ObservedObject var coordinator: CallMediaCoordinator

    var body: some View {
        Group {
            if presenter.showsSurface {
                MinimizedCallView(
                    coordinator: coordinator,
                    corner: $presenter.corner,
                    reopen: { presenter.reopen() },
                    onSurfaceFrameChange: { frame in
                        presenter.hitRegion.frame = frame
                    }
                )
            } else {
                // The window stays attached so Picture in Picture keeps a live source view, but it
                // must draw nothing while the full-screen call UI is what the user sees.
                Color.clear
            }
        }
        // The bubble positions itself against the full screen, including the areas behind the
        // status bar and home indicator, exactly as it did inside the root overlay.
        .ignoresSafeArea()
    }
}

/// Keeps a video call playing after the user leaves Kit Pay.
///
/// Uses AVKit's video-call content source, so the Picture in Picture window renders a real view
/// hierarchy instead of a sample-buffer layer. That lets it reuse the same LiveKit-backed SwiftUI
/// surface the in-app bubble draws, rather than a second, separately maintained renderer.
///
/// Continuing to *capture* from the camera while backgrounded additionally requires Apple's
/// multitasking camera access entitlement. Without it the remote video keeps playing and the local
/// camera pauses until the app returns to the foreground.
private final class CallPictureInPictureCoordinator: NSObject {
    var onRestore: (@MainActor () -> Void)?
    var onDeferredInvalidationCompleted: (@MainActor () -> Void)?

    private var controller: AVPictureInPictureController?
    private var contentController: AVPictureInPictureVideoCallViewController?
    private var hostingController: UIViewController?
    private var releaseAfterPictureInPictureStops = false

    @MainActor
    func configure(sourceView: UIView, coordinator: CallMediaCoordinator) {
        guard AVPictureInPictureController.isPictureInPictureSupported(),
              controller == nil
        else { return }

        let content = AVPictureInPictureVideoCallViewController()
        // A portrait 9:16 window matches the call bubble and the usual phone camera aspect.
        content.preferredContentSize = CGSize(width: 9, height: 16)
        content.view.backgroundColor = .black

        let host = UIHostingController(
            rootView: CallPictureInPictureContent(
                coordinator: coordinator,
                media: coordinator.media
            )
        )
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        content.addChild(host)
        content.view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: content.view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: content.view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: content.view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: content.view.bottomAnchor),
        ])
        host.didMove(toParent: content)

        let source = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: sourceView,
            contentViewController: content
        )
        let pictureInPicture = AVPictureInPictureController(contentSource: source)
        pictureInPicture.canStartPictureInPictureAutomaticallyFromInline = true
        pictureInPicture.delegate = self

        controller = pictureInPicture
        contentController = content
        hostingController = host
    }

    @MainActor
    func invalidate() {
        guard let controller else {
            releaseResources()
            return
        }
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        if controller.isPictureInPictureActive {
            guard !releaseAfterPictureInPictureStops else { return }
            // AVKit still owns both the content controller and its renderer until the delegate's
            // did-stop callback. Releasing them here intermittently leaves a black/stuck PiP tile.
            releaseAfterPictureInPictureStops = true
            controller.stopPictureInPicture()
            return
        }
        releaseResources()
    }

    @MainActor
    private func releaseResources() {
        controller?.delegate = nil
        controller = nil
        contentController = nil
        hostingController = nil
        releaseAfterPictureInPictureStops = false
    }
}

extension CallPictureInPictureCoordinator: AVPictureInPictureControllerDelegate {
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        Task { @MainActor [weak self] in
            self?.onRestore?()
            completionHandler(true)
        }
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        // Picture in Picture is a convenience on top of an already-working call. A refusal from
        // AVKit must never disturb the call itself, so the in-app bubble simply stays authoritative.
        Task { @MainActor [weak self] in
            CallMediaCoordinator.shared.recordControlError(error)
            guard let self,
                  self.controller === pictureInPictureController,
                  self.releaseAfterPictureInPictureStops
            else { return }
            self.releaseResources()
            self.onDeferredInvalidationCompleted?()
        }
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Task { @MainActor [weak self] in
            guard let self,
                  self.controller === pictureInPictureController,
                  self.releaseAfterPictureInPictureStops
            else { return }
            self.releaseResources()
            self.onDeferredInvalidationCompleted?()
        }
    }
}

private struct CallPictureInPictureContent: View {
    @ObservedObject var coordinator: CallMediaCoordinator
    @ObservedObject var media: LiveKitCallMediaTransport

    var body: some View {
        ZStack {
            Color.black
            if let remoteTrack = media.remoteVideoTrack {
                SwiftUIVideoView(remoteTrack, layoutMode: .fill, mirrorMode: .off)
            } else if let call = coordinator.activeCall {
                RemoteAvatarView(
                    name: call.participantName,
                    avatarURL: call.participantAvatarURL,
                    size: 88
                )
            }
        }
        .accessibilityHidden(true)
    }
}
