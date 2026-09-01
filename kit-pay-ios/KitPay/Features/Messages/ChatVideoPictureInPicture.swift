import AVFoundation
import AVKit
import Foundation
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

/// Container facts read from the plaintext itself. A remote descriptor is authenticated, but an
/// Android content provider can still describe QuickTime bytes as `video/mp4`; AVFoundation then
/// receives a `.mp4` URL for a `.mov` file. Keep the wire fact for identity checks and use this
/// independently derived fact only at the local playback boundary.
enum ChatVideoContainer: Equatable {
    case isoBaseMedia
    case quickTime
    case webM
    case unknown

    var mediaType: String? {
        switch self {
        case .isoBaseMedia: "video/mp4"
        case .quickTime: "video/quicktime"
        case .webM: "video/webm"
        case .unknown: nil
        }
    }
}

struct ChatVideoPlaybackFileInspection: Equatable {
    let container: ChatVideoContainer
    let playbackMediaType: String
    let requiresCanonicalExtension: Bool
}

enum ChatVideoPlaybackPreparationError: LocalizedError, Equatable {
    case invalidFile
    case unsupportedVideo

    var errorDescription: String? {
        switch self {
        case .invalidFile:
            "This video is incomplete or damaged."
        case .unsupportedVideo:
            "This video's format is not supported on this iPhone."
        }
    }
}

struct ChatVideoPreparedAsset {
    let asset: AVURLAsset
    let playbackURL: URL
    let temporaryAliasURL: URL?
    let duration: Double
}

/// Validates the complete local file before AVPlayer owns it. This closes two production faults:
/// a received file could reach AVPlayer without a playable video track, and a provider-declared
/// MIME could give valid QuickTime/MP4 bytes the wrong extension. The latter is repaired with a
/// same-volume hard link, so existing E2EE media remains playable without another download or a
/// large copy. Unsupported/corrupt bytes fail before player callbacks can enter an unsafe loop.
enum ChatVideoPlaybackAssetPolicy {
    private static let supportedDeclaredMediaTypes: Set<String> = [
        "video/mp4",
        "video/quicktime",
        "video/webm",
    ]

    static func inspect(
        header: Data,
        declaredMediaType rawMediaType: String,
        sourcePathExtension: String
    ) throws -> ChatVideoPlaybackFileInspection {
        let declaredMediaType = rawMediaType.lowercased()
        guard supportedDeclaredMediaTypes.contains(declaredMediaType) else {
            throw ChatVideoPlaybackPreparationError.unsupportedVideo
        }

        let container = container(for: header)
        guard let detectedMediaType = container.mediaType else {
            throw ChatVideoPlaybackPreparationError.invalidFile
        }
        let expectedExtension = SecureMediaLocalFilePolicy.fileExtension(
            for: detectedMediaType
        )
        return ChatVideoPlaybackFileInspection(
            container: container,
            playbackMediaType: detectedMediaType,
            requiresCanonicalExtension:
                sourcePathExtension.lowercased() != expectedExtension
                    || declaredMediaType != detectedMediaType
        )
    }

    static func prepare(
        fileURL: URL,
        declaredMediaType: String,
        expectedByteCount: Int
    ) async throws -> ChatVideoPreparedAsset {
        guard expectedByteCount > 0 else {
            throw ChatVideoPlaybackPreparationError.invalidFile
        }
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, values.fileSize == expectedByteCount else {
            throw ChatVideoPlaybackPreparationError.invalidFile
        }

        let handle = try FileHandle(forReadingFrom: fileURL)
        let header: Data
        do {
            header = try handle.read(upToCount: 64) ?? Data()
            try handle.close()
        } catch {
            try? handle.close()
            throw ChatVideoPlaybackPreparationError.invalidFile
        }
        let inspection = try inspect(
            header: header,
            declaredMediaType: declaredMediaType,
            sourcePathExtension: fileURL.pathExtension
        )

        var temporaryAliasURL: URL?
        let playbackURL: URL
        if inspection.requiresCanonicalExtension {
            do {
                let alias = try ChatMediaTempFiles.linkTemporaryFile(
                    from: fileURL,
                    mediaType: inspection.playbackMediaType
                )
                temporaryAliasURL = alias
                playbackURL = alias
            } catch {
                throw ChatVideoPlaybackPreparationError.invalidFile
            }
        } else {
            playbackURL = fileURL
        }

        do {
            // The canonical local extension already comes from inspected container bytes.
            // AVURLAssetOutOfBandMIMETypeKey is not available in every supported iOS SDK, so
            // relying on it would make the compatibility repair itself fail to compile.
            let asset = AVURLAsset(url: playbackURL)
            async let playableValue = asset.load(.isPlayable)
            async let durationValue = asset.load(.duration)
            async let videoTracksValue = asset.loadTracks(withMediaType: .video)
            let (isPlayable, loadedDuration, videoTracks) = try await (
                playableValue,
                durationValue,
                videoTracksValue
            )
            let seconds = loadedDuration.seconds
            guard isPlayable,
                  !videoTracks.isEmpty,
                  seconds.isFinite,
                  seconds > 0
            else { throw ChatVideoPlaybackPreparationError.unsupportedVideo }
            return ChatVideoPreparedAsset(
                asset: asset,
                playbackURL: playbackURL,
                temporaryAliasURL: temporaryAliasURL,
                duration: seconds
            )
        } catch {
            ChatMediaTempFiles.removeTemporaryFile(temporaryAliasURL)
            if error is CancellationError { throw error }
            if let preparationError = error as? ChatVideoPlaybackPreparationError {
                throw preparationError
            }
            throw ChatVideoPlaybackPreparationError.unsupportedVideo
        }
    }

    private static func container(for header: Data) -> ChatVideoContainer {
        let bytes = [UInt8](header)
        if bytes.starts(with: [0x1a, 0x45, 0xdf, 0xa3]) {
            return .webM
        }
        guard bytes.count >= 12,
              Data(bytes[4 ..< 8]) == Data("ftyp".utf8)
        else { return .unknown }
        let majorBrand = Data(bytes[8 ..< 12])
        return majorBrand == Data("qt  ".utf8) ? .quickTime : .isoBaseMedia
    }
}

/// A complete local file has no network buffer to repair. AVPlayer already owns its ordinary
/// decoder recovery; replacing its current item from stall/failure callbacks races AVKit's own
/// observers and was the crash path seen after the first second of received-video playback.
enum ChatVideoPlaybackFailurePolicy {
    enum Interruption {
        case stalled
        case failed
    }

    enum Action: Equatable {
        case letPlayerRecover
        case stopAndReport
    }

    static let permitsAutomaticPlayerItemReplacement = false

    static func action(for interruption: Interruption) -> Action {
        switch interruption {
        case .stalled: .letPlayerRecover
        case .failed: .stopAndReport
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
/// Leaving Kit Pay while a video is playing lets AVKit move playback into Picture in Picture.
/// Explicitly closing or swiping away the viewer remains a stop intent. The floating window closes
/// itself when playback reaches the natural end.
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

    /// An explicit close, drag-dismiss, or "Show in chat" means stop viewing. It must not be
    /// reinterpreted as a request to keep the same video alive in a floating window. Automatic
    /// system Picture in Picture when the app backgrounds remains owned by AVKit.
    func stopForExplicitViewerDismissal() {
        attachedPlayer?.pause()
        startRequested = false
        guard let controller else {
            finishDeferredTeardown()
            return
        }
        if controller.isPictureInPictureActive {
            // `GalleryVideoController.teardown()` will hand its resources to us while AVKit
            // finishes stopping; the delegate releases them exactly once afterwards.
            controller.stopPictureInPicture()
        } else {
            finishDeferredTeardown()
        }
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
