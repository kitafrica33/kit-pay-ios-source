import AVFoundation
import AVKit
import Darwin
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

/// Immutable filesystem identity captured before AVFoundation sees a received-video artifact.
/// Size alone is not identity: a stale view can otherwise validate one inode and open a different,
/// equal-sized replacement after an account/cache transition.
struct ChatVideoPlaybackFileIdentity: Equatable, Sendable {
    let deviceID: UInt64
    let fileID: UInt64
    let byteCount: Int
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
}

enum ChatVideoPlaybackArtifactPolicy {
    struct SourceSnapshot: Equatable, Sendable {
        let identity: ChatVideoPlaybackFileIdentity
        let header: Data
    }

    /// Reads the sniffing header and filesystem identity through the same open descriptor. The
    /// path is checked again when the private playback link is made, closing path-replacement
    /// races without hashing a potentially 200 MiB authenticated file on the main actor.
    static func sourceSnapshot(
        at fileURL: URL,
        expectedByteCount: Int
    ) throws -> SourceSnapshot {
        guard expectedByteCount > 0 else {
            throw ChatVideoPlaybackPreparationError.invalidFile
        }
        let values = try fileURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ChatVideoPlaybackPreparationError.invalidFile
        }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let snapshotIdentity = try identity(
            of: handle,
            expectedByteCount: expectedByteCount
        )
        let header: Data
        do {
            header = try handle.read(upToCount: 64) ?? Data()
        } catch {
            throw ChatVideoPlaybackPreparationError.invalidFile
        }
        guard try identity(of: handle, expectedByteCount: expectedByteCount) == snapshotIdentity else {
            throw ChatVideoPlaybackPreparationError.invalidFile
        }
        return SourceSnapshot(identity: snapshotIdentity, header: header)
    }

    static func identity(
        at fileURL: URL,
        expectedByteCount: Int
    ) throws -> ChatVideoPlaybackFileIdentity {
        let values = try fileURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ChatVideoPlaybackPreparationError.invalidFile
        }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        return try identity(of: handle, expectedByteCount: expectedByteCount)
    }

    static func identity(
        of handle: FileHandle,
        expectedByteCount: Int
    ) throws -> ChatVideoPlaybackFileIdentity {
        var status = stat()
        guard expectedByteCount > 0,
              fstat(handle.fileDescriptor, &status) == 0,
              (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              status.st_size > 0,
              Int(status.st_size) == expectedByteCount
        else { throw ChatVideoPlaybackPreparationError.invalidFile }
        return ChatVideoPlaybackFileIdentity(
            deviceID: UInt64(bitPattern: Int64(status.st_dev)),
            fileID: UInt64(status.st_ino),
            byteCount: expectedByteCount,
            modificationSeconds: Int64(status.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(status.st_mtimespec.tv_nsec)
        )
    }

    static func matches(
        fileURL: URL,
        expectedIdentity: ChatVideoPlaybackFileIdentity
    ) -> Bool {
        (try? identity(
            at: fileURL,
            expectedByteCount: expectedIdentity.byteCount
        )) == expectedIdentity
    }
}

/// The decoder receives only this private, canonical hard link. Its open descriptor and URL stay
/// alive until the owning controller has detached AVPlayer/AVPlayerItem, so an enclosing SwiftUI
/// presentation may remove its own temporary source first without invalidating live playback.
final class ChatVideoPlaybackFileLease: @unchecked Sendable {
    let fileURL: URL
    let identity: ChatVideoPlaybackFileIdentity

    private let lock = NSLock()
    private var fileHandle: FileHandle?

    init(
        sourceURL: URL,
        playbackMediaType: String,
        expectedIdentity: ChatVideoPlaybackFileIdentity
    ) throws {
        let aliasURL = try ChatMediaTempFiles.linkTemporaryFile(
            from: sourceURL,
            mediaType: playbackMediaType
        )
        do {
            let handle = try FileHandle(forReadingFrom: aliasURL)
            guard try ChatVideoPlaybackArtifactPolicy.identity(
                of: handle,
                expectedByteCount: expectedIdentity.byteCount
            ) == expectedIdentity,
                  ChatVideoPlaybackArtifactPolicy.matches(
                      fileURL: aliasURL,
                      expectedIdentity: expectedIdentity
                  )
            else {
                try? handle.close()
                throw ChatVideoPlaybackPreparationError.invalidFile
            }
            fileURL = aliasURL
            identity = expectedIdentity
            fileHandle = handle
        } catch {
            ChatMediaTempFiles.removeTemporaryFile(aliasURL)
            throw error
        }
    }

    func isValid() -> Bool {
        lock.lock()
        guard let fileHandle else {
            lock.unlock()
            return false
        }
        let descriptorIdentity = try? ChatVideoPlaybackArtifactPolicy.identity(
            of: fileHandle,
            expectedByteCount: identity.byteCount
        )
        lock.unlock()
        return descriptorIdentity == identity
            && ChatVideoPlaybackArtifactPolicy.matches(
                fileURL: fileURL,
                expectedIdentity: identity
            )
    }

    func release() {
        lock.lock()
        let handle = fileHandle
        fileHandle = nil
        lock.unlock()
        try? handle?.close()
        ChatMediaTempFiles.removeTemporaryFile(fileURL)
    }

    deinit {
        release()
    }
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
    let playbackFileLease: ChatVideoPlaybackFileLease
    let duration: Double

    var playbackURL: URL { playbackFileLease.fileURL }
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
        let source = try ChatVideoPlaybackArtifactPolicy.sourceSnapshot(
            at: fileURL,
            expectedByteCount: expectedByteCount
        )
        let inspection = try inspect(
            header: source.header,
            declaredMediaType: declaredMediaType,
            sourcePathExtension: fileURL.pathExtension
        )
        let playbackFileLease: ChatVideoPlaybackFileLease
        do {
            // Always isolate AVFoundation behind a presentation-owned alias, even when the
            // extension already matches. Parent presentation cleanup can then unlink its own
            // source before SwiftUI delivers child onDisappear without touching the live item.
            playbackFileLease = try ChatVideoPlaybackFileLease(
                sourceURL: fileURL,
                playbackMediaType: inspection.playbackMediaType,
                expectedIdentity: source.identity
            )
        } catch {
            throw ChatVideoPlaybackPreparationError.invalidFile
        }

        do {
            // The canonical local extension already comes from inspected container bytes.
            // AVURLAssetOutOfBandMIMETypeKey is not available in every supported iOS SDK, so
            // relying on it would make the compatibility repair itself fail to compile.
            let asset = AVURLAsset(url: playbackFileLease.fileURL)
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
            guard playbackFileLease.isValid() else {
                throw ChatVideoPlaybackPreparationError.invalidFile
            }
            return ChatVideoPreparedAsset(
                asset: asset,
                playbackFileLease: playbackFileLease,
                duration: seconds
            )
        } catch {
            playbackFileLease.release()
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

/// Reduces AVFoundation diagnostics to fixed categories and bounded numeric facts. In
/// particular, AVPlayerItemErrorLogEvent URI, server address, playback session ID and free-form
/// comment are never copied into app state or logs.
enum ChatVideoPlayerDiagnosticPolicy {
    static func snapshot(
        failureSource: LocalMediaPlaybackFailureSource,
        item: AVPlayerItem?,
        notificationError: Error? = nil
    ) -> LocalMediaPlaybackDiagnostic {
        let rawError: Error? = notificationError ?? item?.error
        let error = rawError.map { $0 as NSError }
        let errorEvents = item?.errorLog()?.events ?? []
        let lastErrorEvent = errorEvents.last
        return LocalMediaPlaybackDiagnostic.sanitized(
            failureSource: failureSource,
            itemStatus: item.map { status($0.status) },
            errorDomain: error?.domain,
            errorCode: error?.code,
            errorLogDomain: lastErrorEvent?.errorDomain,
            errorLogStatusCode: lastErrorEvent?.errorStatusCode,
            errorLogEventCount: errorEvents.count
        )
    }

    private static func status(_ status: AVPlayerItem.Status) -> LocalMediaPlaybackItemStatus {
        switch status {
        case .unknown: .unknown
        case .readyToPlay: .readyToPlay
        case .failed: .failed
        @unknown default: .unknown
        }
    }
}

enum ChatVideoPictureInPictureHandoffPolicy {
    static func shouldRetainTeardown(
        ownerMatches: Bool,
        hasController: Bool,
        startRequested: Bool,
        stopRequested: Bool,
        isActive: Bool,
        alreadyRetained: Bool
    ) -> Bool {
        ownerMatches
            && hasController
            && (alreadyRetained || startRequested || stopRequested || isActive)
    }
}

enum ChatVideoPictureInPictureCallbackPolicy {
    static func accepts(currentController: AnyObject?, callbackController: AnyObject) -> Bool {
        currentController === callbackController
    }
}

/// Restores the delegate's invocation order after callbacks cross independent actor hops.
/// Sequence numbers are assigned synchronously at the protocol boundary; an early-arriving task
/// waits for any lower-numbered callback instead of applying AVKit lifecycle events out of order.
struct ChatVideoPictureInPictureCallbackOrder<Event> {
    private var nextSequence: UInt64 = 0
    private var pending: [UInt64: Event] = [:]

    mutating func insert(_ event: Event, sequence: UInt64) -> [Event] {
        guard sequence >= nextSequence else { return [] }
        pending[sequence] = event

        var ready: [Event] = []
        while let event = pending.removeValue(forKey: nextSequence) {
            ready.append(event)
            nextSequence &+= 1
        }
        return ready
    }
}

private enum ChatVideoPictureInPictureCallbackEvent {
    case willStart
    case didStart
    case willStop
    case failedToStart
    case didStop
    case restore
}

private enum ChatVideoPictureInPictureReportedTransition: Equatable {
    case starting
    case stopping
}

private final class ChatVideoPictureInPictureCallbackSequencer: @unchecked Sendable {
    private let lock = NSLock()
    private var nextSequence: UInt64 = 0
    private var reportedTransitions: [ObjectIdentifier: ChatVideoPictureInPictureReportedTransition] = [:]

    func takeNext(
        for controller: AnyObject,
        event: ChatVideoPictureInPictureCallbackEvent
    ) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let controllerID = ObjectIdentifier(controller)
        switch event {
        case .willStart:
            reportedTransitions[controllerID] = .starting
        case .willStop:
            reportedTransitions[controllerID] = .stopping
        case .didStart:
            if reportedTransitions[controllerID] == .starting {
                reportedTransitions[controllerID] = nil
            }
        case .failedToStart, .didStop:
            reportedTransitions[controllerID] = nil
        case .restore:
            break
        }
        let sequence = nextSequence
        nextSequence &+= 1
        return sequence
    }

    func reportedTransition(
        for controller: AnyObject
    ) -> ChatVideoPictureInPictureReportedTransition? {
        lock.lock()
        defer { lock.unlock() }
        return reportedTransitions[ObjectIdentifier(controller)]
    }

    func clearReportedTransition(for controller: AnyObject) {
        lock.lock()
        defer { lock.unlock() }
        reportedTransitions[ObjectIdentifier(controller)] = nil
    }
}

private let chatVideoPictureInPictureCallbackSequencer =
    ChatVideoPictureInPictureCallbackSequencer()

/// Records stop intent across AVKit's asynchronous Picture-in-Picture transitions.
///
/// `isPictureInPictureActive` can still be false after a start callback and can become false
/// before the matching stop callback. The controller and player must stay alive throughout both
/// gaps, and a foreground or terminal stop requested during a pending start must be honored as
/// soon as AVKit reports success.
struct ChatVideoPictureInPictureLifecycleIntent {
    enum TerminalStopAction: Equatable {
        case releaseNow
        case waitForTransition
        case stopPictureInPicture
    }

    private(set) var startRequested = false
    private(set) var stopRequested = false
    private(set) var shouldStopAfterStart = false
    private(set) var shouldReleaseAfterTransition = false

    var transitionInFlight: Bool {
        startRequested || stopRequested
    }

    mutating func willStart() {
        startRequested = true
    }

    /// Clears a foreground stop left by a transition whose start callback never arrived. This is
    /// called at the next scene deactivation before AVKit can begin another automatic handoff.
    mutating func prepareForBackgrounding() {
        guard !shouldReleaseAfterTransition else { return }
        shouldStopAfterStart = false
    }

    mutating func willStop() {
        startRequested = false
        stopRequested = true
        shouldStopAfterStart = false
    }

    /// Returns true when PiP is already active and can be stopped immediately. A pending start is
    /// stopped from `didStart`, after AVKit is ready to accept the request.
    mutating func foregroundStopRequested(isPictureInPictureActive: Bool) -> Bool {
        guard !stopRequested else { return false }
        if isPictureInPictureActive {
            startRequested = false
            stopRequested = true
            shouldStopAfterStart = false
            return true
        }
        shouldStopAfterStart = true
        return false
    }

    /// A close, drag-dismiss, "Show in chat", or playback end also releases the binding, but only
    /// once AVKit no longer owns it.
    mutating func terminalStopRequested(
        isPictureInPictureActive: Bool
    ) -> TerminalStopAction {
        shouldReleaseAfterTransition = true
        if stopRequested { return .waitForTransition }
        if isPictureInPictureActive {
            startRequested = false
            stopRequested = true
            shouldStopAfterStart = false
            return .stopPictureInPicture
        }
        if startRequested {
            shouldStopAfterStart = true
            return .waitForTransition
        }
        return .releaseNow
    }

    /// Returns true when a stop was requested while the start was still pending.
    mutating func didStart() -> Bool {
        startRequested = false
        defer { shouldStopAfterStart = false }
        if shouldStopAfterStart { stopRequested = true }
        return shouldStopAfterStart
    }

    /// Completes either a failed start or a finished stop and reports whether the controller was
    /// terminally dismissed rather than merely returned to its still-visible inline viewer.
    mutating func transitionFinished() -> Bool {
        let shouldRelease = shouldReleaseAfterTransition
        startRequested = false
        stopRequested = false
        shouldStopAfterStart = false
        shouldReleaseAfterTransition = false
        return shouldRelease
    }

    mutating func reset() {
        startRequested = false
        stopRequested = false
        shouldStopAfterStart = false
        shouldReleaseAfterTransition = false
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
    /// Keeps asynchronous start/stop intent independent of AVKit's lagging synchronous flags.
    private var lifecycleIntent = ChatVideoPictureInPictureLifecycleIntent()
    private var delegateCallbackOrder =
        ChatVideoPictureInPictureCallbackOrder<() -> Void>()
    /// The owning viewer's teardown, held for as long as the window keeps the video alive.
    private var deferredTeardown: (() -> Void)?

    private override init() {
        super.init()
    }

    /// True while the floating window is up (or on its way up) for a handed-off video.
    var isHandedOff: Bool {
        lifecycleIntent.transitionInFlight
            || reportedTransitionInFlight
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

    /// Marks the boundary before AVKit may automatically start PiP. A later foreground event is
    /// then preserved even if its main-actor work runs before AVKit's will-start callback hop.
    func prepareForBackgrounding() {
        lifecycleIntent.prepareForBackgrounding()
    }

    /// An explicit close, drag-dismiss, or "Show in chat" means stop viewing. It must not be
    /// reinterpreted as a request to keep the same video alive in a floating window. Automatic
    /// system Picture in Picture when the app backgrounds remains owned by AVKit.
    func stopForExplicitViewerDismissal() {
        attachedPlayer?.pause()
        guard let controller else {
            finishDeferredTeardown()
            return
        }
        synchronizeReportedTransition(for: controller)
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        switch lifecycleIntent.terminalStopRequested(
            isPictureInPictureActive: controller.isPictureInPictureActive
        ) {
        case .stopPictureInPicture:
            // `GalleryVideoController.teardown()` will hand its resources to us while AVKit
            // finishes stopping; the delegate releases them exactly once afterwards.
            controller.stopPictureInPicture()
        case .waitForTransition:
            // AVKit ignores a stop until start completes. `didStart` delivers this intent.
            break
        case .releaseNow:
            finishDeferredTeardown()
        }
    }

    /// Holds a viewer's teardown for as long as the window is keeping its video alive.
    ///
    /// Returns true when the window took responsibility, meaning the caller must NOT tear down —
    /// the closure runs later, on whichever way the window ends. Returns false when there is
    /// nothing to hand off and the caller should clean up now, as it always did.
    func retainTeardown(owner: AnyObject, _ teardown: @escaping () -> Void) -> Bool {
        let reportedTransition = controller.flatMap {
            chatVideoPictureInPictureCallbackSequencer.reportedTransition(for: $0)
        }
        let shouldRetain = ChatVideoPictureInPictureHandoffPolicy.shouldRetainTeardown(
            ownerMatches: ownerID == ObjectIdentifier(owner),
            hasController: controller != nil,
            startRequested:
                lifecycleIntent.startRequested || reportedTransition == .starting,
            stopRequested:
                lifecycleIntent.stopRequested || reportedTransition == .stopping,
            isActive: controller?.isPictureInPictureActive == true,
            alreadyRetained: deferredTeardown != nil
        )
        guard shouldRetain else { return false }
        // `teardown()` can be delivered more than once by SwiftUI. The first closure already owns
        // the same viewer resources; replacing it is unnecessary, while returning false would
        // tell the duplicate caller to delete a file AVKit still owns.
        if deferredTeardown == nil { deferredTeardown = teardown }
        return true
    }

    // MARK: Ending

    /// The end of the video is the end of the window: nothing is left to watch, so it closes
    /// itself rather than sitting on the user's screen showing a frozen last frame.
    func stopForPlaybackEnd(owner: AnyObject) {
        guard ownerID == ObjectIdentifier(owner), let controller else { return }
        synchronizeReportedTransition(for: controller)
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        switch lifecycleIntent.terminalStopRequested(
            isPictureInPictureActive: controller.isPictureInPictureActive
        ) {
        case .stopPictureInPicture:
            controller.stopPictureInPicture()
        case .waitForTransition:
            break
        case .releaseNow:
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
              deferredTeardown == nil
        else { return }
        synchronizeReportedTransition(for: controller)
        guard lifecycleIntent.foregroundStopRequested(
            isPictureInPictureActive: controller.isPictureInPictureActive
        ) else { return }
        controller.stopPictureInPicture()
    }

    private func finishDeferredTeardown() {
        let teardown = deferredTeardown
        deferredTeardown = nil
        teardown?()
        releaseController()
    }

    private func releaseController() {
        if let controller {
            chatVideoPictureInPictureCallbackSequencer.clearReportedTransition(for: controller)
        }
        controller?.delegate = nil
        controller = nil
        ownerID = nil
        attachedPlayer = nil
        galleryIdentity = nil
        restoreHandler = nil
        lifecycleIntent.reset()
    }

    private func enqueueDelegateCallback(
        sequence: UInt64,
        _ callback: @escaping () -> Void
    ) {
        for readyCallback in delegateCallbackOrder.insert(callback, sequence: sequence) {
            readyCallback()
        }
    }

    private func acceptsCallback(from callbackController: AVPictureInPictureController) -> Bool {
        let accepted = ChatVideoPictureInPictureCallbackPolicy.accepts(
            currentController: controller,
            callbackController: callbackController
        )
        if !accepted {
            chatVideoPictureInPictureCallbackSequencer.clearReportedTransition(
                for: callbackController
            )
        }
        return accepted
    }

    private var reportedTransitionInFlight: Bool {
        guard let controller else { return false }
        return chatVideoPictureInPictureCallbackSequencer.reportedTransition(
            for: controller
        ) != nil
    }

    private func synchronizeReportedTransition(
        for controller: AVPictureInPictureController
    ) {
        switch chatVideoPictureInPictureCallbackSequencer.reportedTransition(for: controller) {
        case .starting:
            if !lifecycleIntent.transitionInFlight { lifecycleIntent.willStart() }
        case .stopping:
            if !lifecycleIntent.stopRequested { lifecycleIntent.willStop() }
        case nil:
            break
        }
    }
}

extension ChatVideoPictureInPicture: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        let sequence = chatVideoPictureInPictureCallbackSequencer.takeNext(
            for: pictureInPictureController,
            event: .willStart
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.enqueueDelegateCallback(sequence: sequence) { [weak self] in
                guard let self, self.acceptsCallback(from: pictureInPictureController) else {
                    return
                }
                self.lifecycleIntent.willStart()
            }
        }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        let sequence = chatVideoPictureInPictureCallbackSequencer.takeNext(
            for: pictureInPictureController,
            event: .didStart
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.enqueueDelegateCallback(sequence: sequence) { [weak self] in
                guard let self, self.acceptsCallback(from: pictureInPictureController) else {
                    return
                }
                if self.lifecycleIntent.didStart() {
                    pictureInPictureController.stopPictureInPicture()
                }
            }
        }
    }

    nonisolated func pictureInPictureControllerWillStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        let sequence = chatVideoPictureInPictureCallbackSequencer.takeNext(
            for: pictureInPictureController,
            event: .willStop
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.enqueueDelegateCallback(sequence: sequence) { [weak self] in
                guard let self, self.acceptsCallback(from: pictureInPictureController) else {
                    return
                }
                self.lifecycleIntent.willStop()
            }
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        // Picture in Picture is a convenience on top of a video that was already playing. A
        // refusal must never strand the viewer's teardown, or the temporary plaintext file would
        // outlive the session that created it.
        let sequence = chatVideoPictureInPictureCallbackSequencer.takeNext(
            for: pictureInPictureController,
            event: .failedToStart
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.enqueueDelegateCallback(sequence: sequence) { [weak self] in
                guard let self, self.acceptsCallback(from: pictureInPictureController) else {
                    return
                }
                let shouldRelease = self.lifecycleIntent.transitionFinished()
                if shouldRelease || self.deferredTeardown != nil {
                    self.finishDeferredTeardown()
                }
            }
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        let sequence = chatVideoPictureInPictureCallbackSequencer.takeNext(
            for: pictureInPictureController,
            event: .didStop
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.enqueueDelegateCallback(sequence: sequence) { [weak self] in
                guard let self, self.acceptsCallback(from: pictureInPictureController) else {
                    return
                }
                let shouldRelease = self.lifecycleIntent.transitionFinished()
                if shouldRelease || self.deferredTeardown != nil {
                    self.finishDeferredTeardown()
                }
            }
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        let sequence = chatVideoPictureInPictureCallbackSequencer.takeNext(
            for: pictureInPictureController,
            event: .restore
        )
        Task { @MainActor [weak self] in
            guard let self else {
                completionHandler(false)
                return
            }
            self.enqueueDelegateCallback(sequence: sequence) { [weak self] in
                guard let self, self.acceptsCallback(from: pictureInPictureController) else {
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
}
