import AVFoundation
import AVKit
import UIKit

/// The small state boundary between asking AVKit to start Picture in Picture and AVKit reporting
/// that the window is active. Starting is asynchronous, so teardown must already be retained in
/// that interval or the gallery can delete the protected plaintext file from under the player.
/// Exact gallery identity of a handed-off video. A KITMEDIA2 message can carry several videos
/// inside its one bubble, so restoring the floating window must reopen the very item that was
/// handed off — message ID alone would silently land on the message's first visual entry.
struct ChatVideoGalleryIdentity: Equatable {
    let messageID: UUID
    /// Index into the multi-attachment message's display-ordered items; nil for a
    /// single-attachment (KITMEDIA1) video.
    let itemIndex: Int?
}

/// A local AVPlayer may report a stall/failure while it is still well short of the duration that
/// AVFoundation read from the complete, integrity-verified file. Only that provable early stop is
/// eligible for automatic recovery; an unknown duration or a stop at the natural tail is never
/// replayed. The cap also prevents a malformed-but-parseable file from entering a retry loop.
enum ChatVideoPlaybackRecoveryPolicy {
    static let maximumAutomaticAttempts = 2
    static let recentPlaybackEvidenceWindow: TimeInterval = 3

    static func shouldRecover(
        currentTime: Double,
        duration: Double,
        intendsToPlay: Bool,
        attemptCount: Int
    ) -> Bool {
        guard intendsToPlay,
              attemptCount < maximumAutomaticAttempts,
              currentTime.isFinite,
              duration.isFinite,
              currentTime >= 0,
              duration > 0,
              currentTime < duration
        else { return false }

        // Treat the final sliver as a genuine end. The relative component scales for long clips,
        // while the floor keeps timestamp rounding from restarting very short videos.
        let endTolerance = max(0.25, min(1, duration * 0.02))
        return duration - currentTime > endTolerance
    }

    enum Interruption {
        case stalled
        case failed
    }

    /// SwiftUI's native `VideoPlayer` controls do not expose a play/pause callback. Its recovery
    /// path therefore requires AVPlayer-owned evidence: an active wait for a stall, or a failed
    /// item immediately after observed playback progress. An ordinary pause has neither and can
    /// never be mistaken for a request to resume.
    static func permitsNativeControlsRecovery(
        interruption: Interruption,
        playerIsWaitingToPlay: Bool,
        itemIsFailed: Bool,
        secondsSinceLastProgress: TimeInterval?
    ) -> Bool {
        switch interruption {
        case .stalled:
            return playerIsWaitingToPlay
        case .failed:
            guard itemIsFailed,
                  let secondsSinceLastProgress,
                  secondsSinceLastProgress.isFinite,
                  secondsSinceLastProgress >= 0
            else { return false }
            return secondsSinceLastProgress <= recentPlaybackEvidenceWindow
        }
    }
}

enum ChatVideoPictureInPictureHandoffPolicy {
    static func shouldRetainTeardown(
        ownerMatches: Bool,
        hasController: Bool,
        startRequested: Bool,
        isActive: Bool,
        alreadyRetained: Bool
    ) -> Bool {
        ownerMatches
            && hasController
            && !alreadyRetained
            && (startRequested || isActive)
    }
}

/// Keeps a chat video playing in the system's floating window once the user's attention moves on.
///
/// A video the user started is theirs until it ends: closing the viewer, swiping the gallery away,
/// or leaving Kit Pay entirely hands playback to Picture in Picture rather than cutting it off.
/// The little window closes by itself when the video finishes, which is the only ending the user
/// asked for and did not have to ask for.
///
/// The viewer's own teardown — the AVPlayer and the file-protected temporary file the plaintext was
/// decrypted into — is *deferred* through here while the window is up, so the handed-off video is
/// never playing from a file that has already been deleted. Deferral is released on every path out
/// of Picture in Picture, including AVKit refusing to start at all.
@MainActor
final class ChatVideoPictureInPicture: NSObject {
    static let shared = ChatVideoPictureInPicture()

    private var controller: AVPictureInPictureController?
    /// The viewer currently allowed to drive the window. Identity only — never dereferenced.
    private var ownerID: ObjectIdentifier?
    private weak var attachedPlayer: AVPlayer?
    private var galleryIdentity: ChatVideoGalleryIdentity?
    /// Bound to the same viewer as `galleryIdentity`. A later gallery can never redirect restore
    /// for a video that is already floating over the app.
    private var restoreHandler: ((ChatVideoGalleryIdentity) -> Void)?
    /// Set before calling AVKit and cleared only when AVKit confirms success/failure. This closes
    /// the start→active race in which the gallery disappears while `isPictureInPictureActive` is
    /// still false.
    private var startRequested = false
    /// The owning viewer's teardown, held for as long as the window keeps the video alive.
    private var deferredTeardown: (() -> Void)?

    private override init() {
        super.init()
    }

    /// True while the floating window is up (or on its way up) for a handed-off video.
    var isHandedOff: Bool {
        startRequested
            || deferredTeardown != nil
            || controller?.isPictureInPictureActive == true
    }

    // MARK: Attaching

    /// Binds the window to the layer of the video that just started playing. Called on every play,
    /// so the window always follows the video the user is actually watching.
    func attach(
        playerLayer: AVPlayerLayer,
        owner: AnyObject,
        galleryIdentity: ChatVideoGalleryIdentity,
        restore: @escaping (ChatVideoGalleryIdentity) -> Void
    ) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        // A live call owns the audio route; a chat video must never take it, and a voice note
        // playing underneath would fight this one for it.
        guard CallMediaCoordinator.shared.activeCall == nil else { return }
        VoiceNotePlayer.shared.stop()

        let identity = ObjectIdentifier(owner)
        if ownerID == identity, controller?.contentSource?.playerLayer === playerLayer {
            self.galleryIdentity = galleryIdentity
            restoreHandler = restore
            return
        }
        // A different video takes over cleanly, unless one is already handed off — that one has
        // been promised the floating window until it ends.
        guard !isHandedOff else { return }
        releaseController()

        // Background playback needs a category that survives leaving the app; without it the
        // floating window would appear and immediately go silent.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        let pictureInPicture = AVPictureInPictureController(
            contentSource: AVPictureInPictureController.ContentSource(playerLayer: playerLayer)
        )
        pictureInPicture.canStartPictureInPictureAutomaticallyFromInline = true
        pictureInPicture.delegate = self
        controller = pictureInPicture
        ownerID = identity
        attachedPlayer = playerLayer.player
        self.galleryIdentity = galleryIdentity
        restoreHandler = restore
    }

    /// Releases the binding when a viewer goes away without handing anything off.
    func detach(owner: AnyObject) {
        guard ownerID == ObjectIdentifier(owner), !isHandedOff else { return }
        releaseController()
    }

    // MARK: Handing off

    /// Starts the floating window if the bound video is actually playing. Called from the paths
    /// that take the viewer off screen — the gallery's close button, its swipe-down dismissal —
    /// *before* the dismissal itself, because AVKit will not hand off a layer already torn out of
    /// its window. Backgrounding is covered separately, by AVKit's own automatic start.
    func startIfPlaying() {
        guard let controller,
              !isHandedOff,
              attachedPlayer?.timeControlStatus == .playing,
              controller.isPictureInPicturePossible,
              !controller.isPictureInPictureActive
        else { return }
        startRequested = true
        controller.startPictureInPicture()
    }

    /// Holds a viewer's teardown for as long as the window is keeping its video alive.
    ///
    /// Returns true when the window took responsibility, meaning the caller must NOT tear down —
    /// the closure runs later, on whichever way the window ends. Returns false when there is
    /// nothing to hand off and the caller should clean up now, as it always did.
    func retainTeardown(owner: AnyObject, _ teardown: @escaping () -> Void) -> Bool {
        let shouldRetain = ChatVideoPictureInPictureHandoffPolicy.shouldRetainTeardown(
            ownerMatches: ownerID == ObjectIdentifier(owner),
            hasController: controller != nil,
            startRequested: startRequested,
            isActive: controller?.isPictureInPictureActive == true,
            alreadyRetained: deferredTeardown != nil
        )
        guard shouldRetain else { return false }
        deferredTeardown = teardown
        return true
    }

    // MARK: Ending

    /// The end of the video is the end of the window: nothing is left to watch, so it closes
    /// itself rather than sitting on the user's screen showing a frozen last frame.
    func stopForPlaybackEnd(owner: AnyObject) {
        guard ownerID == ObjectIdentifier(owner), let controller else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else {
            finishDeferredTeardown()
        }
    }

    /// Returning to Kit Pay while the viewer that started the video is still on screen puts
    /// playback back where it came from. A video whose viewer is gone keeps its window.
    func stopForForegroundIfNeeded() {
        guard let controller,
              // No deferred teardown means the gallery is still alive: this is automatic
              // background PiP and playback belongs back in that on-screen viewer. A manual
              // dismissal has a deferred teardown and keeps floating after foregrounding.
              deferredTeardown == nil,
              controller.isPictureInPictureActive
        else { return }
        controller.stopPictureInPicture()
    }

    private func finishDeferredTeardown() {
        let teardown = deferredTeardown
        deferredTeardown = nil
        teardown?()
        releaseController()
    }

    private func releaseController() {
        controller?.delegate = nil
        controller = nil
        ownerID = nil
        attachedPlayer = nil
        galleryIdentity = nil
        restoreHandler = nil
        startRequested = false
    }
}

extension ChatVideoPictureInPicture: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Task { @MainActor [weak self] in
            self?.startRequested = true
        }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Task { @MainActor [weak self] in
            self?.startRequested = false
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        // Picture in Picture is a convenience on top of a video that was already playing. A
        // refusal must never strand the viewer's teardown, or the temporary plaintext file would
        // outlive the session that created it.
        Task { @MainActor [weak self] in
            self?.startRequested = false
            self?.finishDeferredTeardown()
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Task { @MainActor [weak self] in
            self?.startRequested = false
            self?.finishDeferredTeardown()
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let self else {
                completionHandler(false)
                return
            }
            if let galleryIdentity = self.galleryIdentity,
               let restoreHandler = self.restoreHandler {
                restoreHandler(galleryIdentity)
                completionHandler(true)
            } else {
                completionHandler(false)
            }
        }
    }
}
