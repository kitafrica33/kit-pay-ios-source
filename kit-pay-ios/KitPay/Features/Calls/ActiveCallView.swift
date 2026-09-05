import Foundation
import LiveKit
import SwiftUI
import UIKit

enum CallFloatingCorner: CaseIterable, Equatable {
    case topLeading
    case topCenter
    case topTrailing
    case trailingCenter
    case bottomTrailing
    case bottomCenter
    case bottomLeading
    case leadingCenter
}

struct CallFloatingInsets: Equatable {
    var top: CGFloat
    var leading: CGFloat
    var bottom: CGFloat
    var trailing: CGFloat

    static let zero = CallFloatingInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
}

/// Geometry shared by the full-call self preview and the minimized in-app video surface.
/// Keeping the snapping math independent from SwiftUI makes rotations and compact screens
/// deterministic and lets us verify that the root menu never covers an ongoing call.
struct CallFloatingSurfaceLayoutPolicy {
    static let outerMargin: CGFloat = 12
    static let rootMenuClearance: CGFloat = 104
    static let activeCallHeaderClearance: CGFloat = 116
    static let activeCallControlsClearance: CGFloat = 108
    static let compactLandscapeHeaderClearance: CGFloat = 68
    static let compactLandscapeControlsClearance: CGFloat = 88
    static let maximumProjectedTravel: CGFloat = 220
    static let rubberBandCoefficient: CGFloat = 0.16
    static let localPreviewHeightToWidth: CGFloat = 14.0 / 9.0
    static let audioSurfaceMaximumWidth: CGFloat = 330
    static let minimizedControlDimension: CGFloat = 44
    static let previewControlDimension: CGFloat = 44
    static let previewControlsSpacing: CGFloat = 4
    static let previewControlsPadding: CGFloat = 6

    static var previewControlsRequiredHeight: CGFloat {
        (previewControlDimension * 2)
            + previewControlsSpacing
            + (previewControlsPadding * 2)
    }

    static func usesCompactLandscape(container: CGSize) -> Bool {
        container.width > container.height && container.height < 500
    }

    static func resolvedActiveCallHeaderClearance(container: CGSize) -> CGFloat {
        usesCompactLandscape(container: container)
            ? compactLandscapeHeaderClearance
            : activeCallHeaderClearance
    }

    static func resolvedActiveCallControlsClearance(container: CGSize) -> CGFloat {
        usesCompactLandscape(container: container)
            ? compactLandscapeControlsClearance
            : activeCallControlsClearance
    }

    static func activeCallAvatarSize(container: CGSize) -> CGFloat {
        if usesCompactLandscape(container: container) {
            return min(96, max(72, container.height * 0.24))
        }
        return min(container.width * 0.46, 210)
    }

    static func activeCallHorizontalPadding(safeAreaInset: CGFloat) -> CGFloat {
        max(18, safeAreaInset + outerMargin)
    }

    static func minimizedSurfaceSize(container: CGSize, isVideo: Bool) -> CGSize {
        let availableWidth = max(72, container.width - (outerMargin * 2))
        if isVideo {
            let preferredWidth = max(112, container.width * 0.34)
            let width = min(148, min(availableWidth, preferredWidth))
            return CGSize(width: width, height: width * (16.0 / 9.0))
        }
        // Wide enough for the avatar, the name and status, and the inline mute and hang-up
        // controls without truncating the contact's name on a compact iPhone.
        return CGSize(width: min(audioSurfaceMaximumWidth, availableWidth), height: 72)
    }

    static func localPreviewSize(
        container: CGSize,
        insets: CallFloatingInsets = .zero,
        topClearance: CGFloat = 0,
        bottomClearance: CGFloat = 0,
        controlsAreVisible: Bool = false
    ) -> CGSize {
        let availableWidth = max(
            72,
            container.width - insets.leading - insets.trailing - (outerMargin * 2)
        )
        let availableHeight = max(
            72 * localPreviewHeightToWidth,
            container.height
                - insets.top
                - insets.bottom
                - (outerMargin * 2)
                - max(0, topClearance)
                - max(0, bottomClearance)
        )
        // Controls fade in over the preview instead of resizing it. Keep the established portrait
        // self-view silhouette while constraining its width on compact landscape screens.
        let preferredWidth = max(104, container.width * 0.30)
        let heightConstrainedWidth = availableHeight / localPreviewHeightToWidth
        let width = min(132, min(availableWidth, min(heightConstrainedWidth, preferredWidth)))
        return CGSize(width: width, height: width * localPreviewHeightToWidth)
    }

    static func origin(
        for corner: CallFloatingCorner,
        surfaceSize: CGSize,
        container: CGSize,
        insets: CallFloatingInsets,
        topClearance: CGFloat = 0,
        bottomClearance: CGFloat = 0
    ) -> CGPoint {
        let ranges = originRanges(
            surfaceSize: surfaceSize,
            container: container,
            insets: insets,
            topClearance: topClearance,
            bottomClearance: bottomClearance
        )
        let x = switch corner {
        case .topLeading, .bottomLeading, .leadingCenter: ranges.x.lowerBound
        case .topCenter, .bottomCenter: ranges.x.center
        case .topTrailing, .bottomTrailing, .trailingCenter: ranges.x.upperBound
        }
        let y = switch corner {
        case .topLeading, .topCenter, .topTrailing: ranges.y.lowerBound
        case .leadingCenter, .trailingCenter: ranges.y.center
        case .bottomLeading, .bottomCenter, .bottomTrailing: ranges.y.upperBound
        }
        return CGPoint(x: x, y: y)
    }

    static func clampedOrigin(
        _ proposed: CGPoint,
        surfaceSize: CGSize,
        container: CGSize,
        insets: CallFloatingInsets,
        topClearance: CGFloat = 0,
        bottomClearance: CGFloat = 0
    ) -> CGPoint {
        let ranges = originRanges(
            surfaceSize: surfaceSize,
            container: container,
            insets: insets,
            topClearance: topClearance,
            bottomClearance: bottomClearance
        )
        return CGPoint(
            x: min(max(proposed.x, ranges.x.lowerBound), ranges.x.upperBound),
            y: min(max(proposed.y, ranges.y.lowerBound), ranges.y.upperBound)
        )
    }

    static func nearestCorner(
        to proposed: CGPoint,
        surfaceSize: CGSize,
        container: CGSize,
        insets: CallFloatingInsets,
        topClearance: CGFloat = 0,
        bottomClearance: CGFloat = 0
    ) -> CallFloatingCorner {
        let clamped = clampedOrigin(
            proposed,
            surfaceSize: surfaceSize,
            container: container,
            insets: insets,
            topClearance: topClearance,
            bottomClearance: bottomClearance
        )
        let candidates = CallFloatingCorner.allCases.enumerated().map { index, anchor in
            (
                index: index,
                anchor: anchor,
                distance: squaredDistance(
                    clamped,
                    origin(
                        for: anchor,
                        surfaceSize: surfaceSize,
                        container: container,
                        insets: insets,
                        topClearance: topClearance,
                        bottomClearance: bottomClearance
                    )
                )
            )
        }
        return candidates.min { lhs, rhs in
            if abs(lhs.distance - rhs.distance) > 0.0001 {
                return lhs.distance < rhs.distance
            }
            return lhs.index < rhs.index
        }?.anchor ?? .bottomTrailing
    }

    /// Tracks the finger directly while preserving a small, decelerating overscroll response at
    /// the safe boundary. Release always resolves to a legal anchor through `nearestCorner`.
    static func rubberBandedOrigin(
        _ proposed: CGPoint,
        surfaceSize: CGSize,
        container: CGSize,
        insets: CallFloatingInsets,
        topClearance: CGFloat = 0,
        bottomClearance: CGFloat = 0
    ) -> CGPoint {
        let ranges = originRanges(
            surfaceSize: surfaceSize,
            container: container,
            insets: insets,
            topClearance: topClearance,
            bottomClearance: bottomClearance
        )
        return CGPoint(
            x: rubberBanded(proposed.x, within: ranges.x),
            y: rubberBanded(proposed.y, within: ranges.y)
        )
    }

    /// Caps SwiftUI's predicted end translation before selecting an edge/corner. Fast flicks feel
    /// directional without allowing an extreme velocity estimate to jump across the whole call.
    static func projectedOrigin(
        restingOrigin: CGPoint,
        translation: CGSize,
        predictedEndTranslation: CGSize
    ) -> CGPoint {
        let current = CGPoint(
            x: restingOrigin.x + translation.width,
            y: restingOrigin.y + translation.height
        )
        let projection = CGVector(
            dx: predictedEndTranslation.width - translation.width,
            dy: predictedEndTranslation.height - translation.height
        )
        let magnitude = hypot(projection.dx, projection.dy)
        let scale = magnitude > maximumProjectedTravel && magnitude > 0
            ? maximumProjectedTravel / magnitude
            : 1
        return CGPoint(
            x: current.x + projection.dx * scale,
            y: current.y + projection.dy * scale
        )
    }

    private static func originRanges(
        surfaceSize: CGSize,
        container: CGSize,
        insets: CallFloatingInsets,
        topClearance: CGFloat,
        bottomClearance: CGFloat
    ) -> (x: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>) {
        let minimumX = insets.leading + outerMargin
        let maximumX = max(
            minimumX,
            container.width - insets.trailing - outerMargin - surfaceSize.width
        )
        let minimumY = insets.top + outerMargin + max(0, topClearance)
        let maximumY = max(
            minimumY,
            container.height
                - insets.bottom
                - outerMargin
                - max(0, bottomClearance)
                - surfaceSize.height
        )
        return (minimumX ... maximumX, minimumY ... maximumY)
    }

    private static func rubberBanded(_ value: CGFloat, within range: ClosedRange<CGFloat>) -> CGFloat {
        if value < range.lowerBound {
            return range.lowerBound - rubberBandDistance(range.lowerBound - value)
        }
        if value > range.upperBound {
            return range.upperBound + rubberBandDistance(value - range.upperBound)
        }
        return value
    }

    private static func rubberBandDistance(_ distance: CGFloat) -> CGFloat {
        let positive = max(0, distance)
        return (positive * rubberBandCoefficient * 120) / (120 + positive)
    }

    private static func squaredDistance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }
}

private extension ClosedRange where Bound == CGFloat {
    var center: CGFloat { (lowerBound + upperBound) / 2 }
}

/// Shared geometry of the full-width audio call strip. `MinimizedCallView` draws the strip with
/// this height below the top safe-area inset, and `AppWindowTopStripReservation` reserves it — plus
/// its own `contentGap` — as a top safe-area inset, so app content is pushed clear of the strip
/// instead of covered by it or crowded against it.
enum CallBannerMetrics {
    /// Height of the strip's content below the top safe-area inset.
    static let contentHeight: CGFloat = 56

    static func contentFrame(container: CGRect, topInset: CGFloat) -> CGRect {
        CGRect(x: container.minX, y: container.minY + max(0, topInset),
               width: container.width, height: contentHeight)
    }
}

/// Which screen edge the minimized video tile is tucked behind.
enum CallFloatingTuckEdge: Equatable {
    case leading
    case trailing
}

/// Free placement and edge-tuck geometry for the minimized in-app video tile.
///
/// Deliberately separate from `CallFloatingSurfaceLayoutPolicy`: those corner-snapping statics are
/// pinned by `CallLifecycleTests` and continue to serve the in-call self-preview, while the
/// minimized tile now rests wherever the user leaves it and can be tucked off either side edge.
enum CallFloatingTilePlacementPolicy {
    /// Clamping margin against the screen bounds on the sides and bottom.
    static let screenMargin: CGFloat = 8
    /// Interactive width of the tucked-tile handle (44pt minimum touch target).
    static let tuckHandleWidth: CGFloat = 44
    /// Width of the visible glass capsule inside the handle's interactive frame.
    static let tuckHandleVisibleWidth: CGFloat = 30
    static let tuckHandleHeight: CGFloat = 64
    /// Horizontal projection (predicted end minus current translation) treated as a strong
    /// outward flick near an edge.
    static let tuckProjectionThreshold: CGFloat = 180
    /// How close the projected tile must already be to an edge for a flick to tuck it.
    static let tuckEdgeProximity: CGFloat = 24

    /// Clamps a proposed resting origin to the screen with `screenMargin` on the sides and
    /// bottom; the only top clearance is the status-bar safe-area inset.
    static func clampedOrigin(
        _ proposed: CGPoint,
        surfaceSize: CGSize,
        container: CGSize,
        topInset: CGFloat
    ) -> CGPoint {
        let minimumX = screenMargin
        let maximumX = max(minimumX, container.width - screenMargin - surfaceSize.width)
        let minimumY = max(screenMargin, topInset)
        let maximumY = max(minimumY, container.height - screenMargin - surfaceSize.height)
        return CGPoint(
            x: min(max(proposed.x, minimumX), maximumX),
            y: min(max(proposed.y, minimumY), maximumY)
        )
    }

    /// Whether a drag release should tuck the tile: its projected center has crossed a side edge,
    /// or the flick is strongly outward while the tile is already hugging that edge.
    static func tuckedEdge(
        forProjectedOrigin projected: CGPoint,
        surfaceSize: CGSize,
        container: CGSize,
        horizontalProjection: CGFloat
    ) -> CallFloatingTuckEdge? {
        let centerX = projected.x + surfaceSize.width / 2
        if centerX <= 0 { return .leading }
        if centerX >= container.width { return .trailing }
        if horizontalProjection <= -tuckProjectionThreshold,
           projected.x <= tuckEdgeProximity {
            return .leading
        }
        if horizontalProjection >= tuckProjectionThreshold,
           projected.x + surfaceSize.width >= container.width - tuckEdgeProximity {
            return .trailing
        }
        return nil
    }

    /// Where the tile parks while tucked: fully off-screen at its last vertical position, so the
    /// video view stays mounted and playing.
    static func tuckedTileOrigin(
        edge: CallFloatingTuckEdge,
        surfaceSize: CGSize,
        restingOrigin: CGPoint,
        container: CGSize,
        topInset: CGFloat
    ) -> CGPoint {
        let clamped = clampedOrigin(
            restingOrigin,
            surfaceSize: surfaceSize,
            container: container,
            topInset: topInset
        )
        let x: CGFloat = switch edge {
        case .leading: -surfaceSize.width - screenMargin
        case .trailing: container.width + screenMargin
        }
        return CGPoint(x: x, y: clamped.y)
    }

    /// Interactive frame of the restore handle, flush against the tucked edge, vertically at the
    /// tile's last center and clamped on screen.
    static func handleFrame(
        edge: CallFloatingTuckEdge,
        tileCenterY: CGFloat,
        container: CGSize,
        topInset: CGFloat
    ) -> CGRect {
        let minimumY = max(screenMargin, topInset)
        let maximumY = max(minimumY, container.height - screenMargin - tuckHandleHeight)
        let y = min(max(tileCenterY - tuckHandleHeight / 2, minimumY), maximumY)
        let x: CGFloat = switch edge {
        case .leading: 0
        case .trailing: container.width - tuckHandleWidth
        }
        return CGRect(x: x, y: y, width: tuckHandleWidth, height: tuckHandleHeight)
    }
}

enum CallControlsVisibilityPolicy {
    static let autoHideDelayNanoseconds: UInt64 = 4_000_000_000

    static func shouldAutoHide(
        isVideoCall: Bool,
        isConnected: Bool,
        hasVideoSurface: Bool,
        isAdditionalControlsPresented: Bool,
        hasWaitingCall: Bool = false,
        isFloatingSurfaceInteracting: Bool = false,
        isAssistiveNavigationActive: Bool = false,
        areControlsVisible: Bool = true
    ) -> Bool {
        isVideoCall
            && isConnected
            && hasVideoSurface
            && !isAdditionalControlsPresented
            && !hasWaitingCall
            && !isFloatingSurfaceInteracting
            && !isAssistiveNavigationActive
            && areControlsVisible
    }

    static func visibilityAfterSurfaceTap(
        isVideoCall: Bool,
        areControlsVisible: Bool,
        hasWaitingCall: Bool = false,
        isAssistiveNavigationActive: Bool = false
    ) -> Bool {
        guard !hasWaitingCall else { return true }
        guard isVideoCall, !isAssistiveNavigationActive else { return true }
        return !areControlsVisible
    }
}

/// Which in-call controls may act in a given media state, and which glyph the audio-route control
/// shows.
///
/// Kit connects the caller's LiveKit room while the callee is still ringing, so `connected` already
/// covers WhatsApp's "usable while ringing" behaviour. The gap this closes is reconnection: muting
/// runs through CallKit and switching the speaker is a pure `AVAudioSession` override, so both stay
/// usable while media re-establishes, exactly as they do in WhatsApp.
enum CallControlAvailabilityPolicy {
    static func microphoneControlIsEnabled(isConnected: Bool, isReconnecting: Bool) -> Bool {
        isConnected || isReconnecting
    }

    static func speakerControlIsEnabled(
        isConnected: Bool,
        isReconnecting: Bool,
        route: CallAudioRoute
    ) -> Bool {
        (isConnected || isReconnecting)
            && CallAudioRoutePolicy.speakerControlIsAvailable(for: route)
    }

    static func cameraControlIsEnabled(isConnected: Bool, isReconnecting: Bool) -> Bool {
        isConnected || isReconnecting
    }

    /// The microphone-mode sheet only records a preference, so it stays available while media
    /// re-establishes rather than greying out exactly when the customer wants to change it.
    static func moreControlsAreEnabled(isConnected: Bool, isReconnecting: Bool = false) -> Bool {
        isConnected || isReconnecting
    }
}

enum ActiveCallVideoPresentationPolicy {
    static func isVideo(
        callWasVideo: Bool,
        localCameraEnabled: Bool,
        hasRemoteVideo: Bool
    ) -> Bool {
        CallVideoStatePolicy.carriesVideo(
            originalCallWasVideo: callWasVideo,
            localCameraEnabled: localCameraEnabled,
            remoteVideoAvailable: hasRemoteVideo
        )
    }
}

enum ActiveCallParticipantGridPolicy {
    static let spacing: CGFloat = 6
    static let minimumTileHeight: CGFloat = 96

    static func shouldUseGrid(
        isVideoPresentation: Bool,
        backendParticipantCount: Int,
        remoteParticipantCount: Int
    ) -> Bool {
        isVideoPresentation && (backendParticipantCount > 2 || remoteParticipantCount > 1)
    }

    static func columnCount(participantCount: Int, availableSize: CGSize) -> Int {
        guard participantCount > 0 else { return 0 }
        if participantCount == 1 { return 1 }
        if availableSize.width < 300 { return 1 }
        let isLandscape = availableSize.width >= availableSize.height
        switch participantCount {
        case 2:
            return isLandscape ? 2 : 1
        case 3 ... 4:
            return 2
        case 5 ... 6:
            return isLandscape ? 3 : 2
        default:
            return 3
        }
    }

    static func tileHeight(
        participantCount: Int,
        columnCount: Int,
        availableSize: CGSize
    ) -> CGFloat {
        guard participantCount > 0, columnCount > 0 else { return 0 }
        let columns = min(participantCount, columnCount)
        let rows = Int(ceil(Double(participantCount) / Double(columns)))
        let horizontalSpacing = spacing * CGFloat(max(0, columns - 1))
        let verticalSpacing = spacing * CGFloat(max(0, rows - 1))
        let tileWidth = max(0, (availableSize.width - horizontalSpacing) / CGFloat(columns))
        let fittedHeight = max(0, (availableSize.height - verticalSpacing) / CGFloat(rows))
        return max(minimumTileHeight, min(tileWidth * 1.32, fittedHeight))
    }
}

enum RemoteCallParticipantPresentationPolicy {
    static let fallbackName = "Kit Pay contact"
    static let maximumNameLength = 160

    static func userID(fromLiveKitIdentity identity: String) -> String? {
        let prefix = identity
            .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let prefix,
              let id = UUID(uuidString: prefix)
        else { return nil }
        return id.uuidString.lowercased()
    }

    static func displayName(contactName: String?, serverName: String?) -> String {
        safeDisplayText(contactName) ?? safeDisplayText(serverName) ?? fallbackName
    }

    private static func safeDisplayText(_ value: String?) -> String? {
        guard let value else { return nil }
        let withoutControls = value.components(separatedBy: .controlCharacters).joined()
        let trimmed = withoutControls.trimmingCharacters(in: .whitespacesAndNewlines)
        let capped = String(trimmed.prefix(maximumNameLength))
        guard !capped.isEmpty,
              UUID(uuidString: capped) == nil
        else { return nil }
        return capped
    }
}

struct ActiveCallView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var coordinator: CallMediaCoordinator
    @ObservedObject private var media: LiveKitCallMediaTransport
    @ObservedObject private var screenSharing: CallScreenSharingController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControlEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsMoreControls = false
    @State private var confirmsScreenSharing = false
    @State private var controlsAreVisible = true
    @State private var autoHideGeneration = 0
    @State private var localPreviewCorner: CallFloatingCorner = .bottomTrailing
    @State private var localPreviewIsDragging = false
    @State private var showsAddParticipant = false
    @State private var isOpeningConversation = false
    private let onMinimize: () -> Void

    init(coordinator: CallMediaCoordinator, onMinimize: @escaping () -> Void = {}) {
        _coordinator = ObservedObject(wrappedValue: coordinator)
        _media = ObservedObject(wrappedValue: coordinator.media)
        _screenSharing = ObservedObject(wrappedValue: coordinator.media.screenSharing)
        self.onMinimize = onMinimize
    }

    var body: some View {
        GeometryReader { geometry in
            let compactLandscape = CallFloatingSurfaceLayoutPolicy.usesCompactLandscape(
                container: geometry.size
            )
            let headerClearance = CallFloatingSurfaceLayoutPolicy.resolvedActiveCallHeaderClearance(
                container: geometry.size
            )
            let controlsClearance = CallFloatingSurfaceLayoutPolicy.resolvedActiveCallControlsClearance(
                container: geometry.size
            )
            ZStack {
                callBackground(in: geometry)

                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: toggleControls)
                    .allowsHitTesting(!hasRemoteParticipantGrid)

                if media.remoteVideoTrack == nil,
                   !hasRemoteParticipantGrid,
                   let call = coordinator.activeCall {
                    let avatarSize = CallFloatingSurfaceLayoutPolicy.activeCallAvatarSize(
                        container: geometry.size
                    )
                    VStack(spacing: compactLandscape ? 0 : 16) {
                        ZStack {
                            KitVoicePulseRings(
                                avatarSize: avatarSize,
                                remoteLevel: media.remoteVoiceLevel,
                                localLevel: media.localVoiceLevel,
                                isConnected: coordinator.state == .connected,
                                reduceMotion: reduceMotion
                            )
                            CallParticipantAvatarView(
                                name: call.participantName,
                                avatarURL: call.participantAvatarURL,
                                size: avatarSize
                            )
                        }
                        if !compactLandscape {
                            VerifiedAccountNameLabel(
                                designation: call.participantVerification
                            ) {
                                Text(call.participantName)
                                    .font(.title2.bold())
                                    .foregroundStyle(callForeground)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.76)
                            }
                            .padding(.horizontal, 28)
                        }
                    }
                    .shadow(color: .black.opacity(0.34), radius: 28, y: 14)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }

                if controlsAreVisible {
                    VStack(spacing: 12) {
                        if let waitingCall = model.waitingCall {
                            CallWaitingGlassBanner(
                                callerName: waitingCall.name,
                                isVideo: waitingCall.video,
                                isMerging: model.isMergingWaitingCall,
                                decline: {
                                    revealControls()
                                    model.declineWaitingCall()
                                },
                                merge: {
                                    guard !model.isMergingWaitingCall else { return }
                                    revealControls()
                                    Task { await model.mergeWaitingCall() }
                                }
                            )
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                        callHeader(compactLandscape: compactLandscape)
                        Spacer(minLength: 24)
                        if screenSharing.phase != .idle {
                            screenSharingStatus
                        }
                        controlsPanel
                    }
                    .padding(
                        .leading,
                        CallFloatingSurfaceLayoutPolicy.activeCallHorizontalPadding(
                            safeAreaInset: geometry.safeAreaInsets.leading
                        )
                    )
                    .padding(
                        .trailing,
                        CallFloatingSurfaceLayoutPolicy.activeCallHorizontalPadding(
                            safeAreaInset: geometry.safeAreaInsets.trailing
                        )
                    )
                    .padding(.top, max(12, geometry.safeAreaInsets.top + 4))
                    .padding(.bottom, max(14, geometry.safeAreaInsets.bottom + 8))
                    .transition(.opacity)
                    .zIndex(3)
                }

                if media.isCameraEnabled,
                   let localTrack = media.localVideoTrack {
                    DraggableLocalVideoPreview(
                        track: localTrack,
                        isFrontCamera: media.isFrontCamera,
                        canSwitchCamera: media.canSwitchCamera,
                        controlsAreVisible: controlsAreVisible,
                        activeHeaderClearance: headerClearance,
                        activeControlsClearance: controlsClearance,
                        corner: $localPreviewCorner,
                        isDragging: $localPreviewIsDragging,
                        onTap: toggleControls,
                        switchCamera: { await coordinator.switchCamera() }
                    )
                    .zIndex(model.waitingCall == nil ? 4 : 2)
                }

                if showsMoreControls {
                    MoreCallControlsOverlay(
                        selectedMode: media.microphoneMode,
                        screenSharingPhase: screenSharing.phase,
                        canStartScreenSharing: coordinator.state == .connected,
                        shareScreen: {
                            dismissMoreControls()
                            coordinator.requestScreenSharing()
                        },
                        stopScreenSharing: coordinator.stopScreenSharing,
                        selectMode: { mode in
                            coordinator.setMicrophoneMode(mode)
                            dismissMoreControls()
                        },
                        dismiss: dismissMoreControls
                    )
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .zIndex(10)
                }
            }
            // The backdrop deliberately extends beneath the status area, Dynamic Island/notch,
            // rounded screen corners, and home indicator. Clipping here would trim every
            // `ignoresSafeArea` background back to the modal's safe content rectangle.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                revealControls()
                if screenSharing.phase == .awaitingConfirmation { confirmsScreenSharing = true }
            }
            .onChange(of: coordinator.state) { _, _ in revealControls() }
            .onChange(of: media.isCameraEnabled) { _, _ in revealControls() }
            .onChange(of: screenSharing.phase) { _, phase in
                revealControls()
                confirmsScreenSharing = phase == .awaitingConfirmation && scenePhase == .active
            }
            .onChange(of: media.localVideoTrack != nil) { _, _ in revealControls() }
            .onChange(of: media.remoteVideoTrack != nil) { _, _ in revealControls() }
            .onChange(of: media.remoteParticipantSurfaces.count) { _, _ in revealControls() }
            // Plugging in headphones or connecting a car kit changes what the audio control means.
            // Surface the chrome so the new route is visible instead of changing under hidden UI.
            .onChange(of: media.audioRoute) { _, _ in revealControls() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    revealControls()
                    if screenSharing.phase == .awaitingConfirmation { confirmsScreenSharing = true }
                }
            }
            .onChange(of: voiceOverEnabled) { _, _ in revealControls() }
            .onChange(of: switchControlEnabled) { _, _ in revealControls() }
            .onChange(of: model.waitingCall?.callID) { _, waitingCallID in
                if waitingCallID != nil {
                    showsAddParticipant = false
                    withAnimation(reduceMotion ? nil : .snappy) {
                        showsMoreControls = false
                    }
                }
                revealControls()
            }
            .onChange(of: model.isMergingWaitingCall) { _, _ in revealControls() }
            .onChange(of: showsAddParticipant) { _, isPresented in
                if isPresented {
                    autoHideGeneration &+= 1
                } else {
                    revealControls()
                }
            }
            .onChange(of: localPreviewIsDragging) { _, dragging in
                if dragging {
                    // Cancel the pending auto-hide without relocating a hidden-chrome preview
                    // underneath the user's finger. Chrome returns after the snap completes.
                    autoHideGeneration &+= 1
                } else {
                    revealControls()
                }
            }
            .task(id: autoHideGeneration) {
                guard shouldAutoHideControls else { return }
                do {
                    try await Task.sleep(
                        nanoseconds: CallControlsVisibilityPolicy.autoHideDelayNanoseconds
                    )
                } catch {
                    return
                }
                guard !Task.isCancelled, shouldAutoHideControls else { return }
                updateControlsVisibility(false)
            }
            .sheet(isPresented: $showsAddParticipant) {
                if let activeCall = coordinator.activeCall {
                    ActiveCallParticipantSheet(activeCall: activeCall)
                        .environmentObject(model)
                }
            }
        }
        .preferredColorScheme(hasVideoBackdrop ? .dark : nil)
        .alert("Share your screen with \(coordinator.activeCall?.participantName ?? "this call")?", isPresented: $confirmsScreenSharing) {
            Button("Share screen") { coordinator.confirmScreenSharing() }
            Button("Cancel", role: .cancel) { coordinator.stopScreenSharing() }
        } message: {
            Text("Everyone in this call can see your screen, including notifications. Your microphone still follows the call’s Mute control.")
        }
    }

    @ViewBuilder
    private func callBackground(in geometry: GeometryProxy) -> some View {
        if hasRemoteParticipantGrid {
            let compactLandscape = CallFloatingSurfaceLayoutPolicy.usesCompactLandscape(
                container: geometry.size
            )
            GroupCallParticipantGrid(
                participants: groupParticipantTiles,
                contentInsets: EdgeInsets(
                    top: max(
                        compactLandscape ? 72 : 104,
                        geometry.safeAreaInsets.top + (compactLandscape ? 56 : 72)
                    ),
                    leading: max(6, geometry.safeAreaInsets.leading + 6),
                    bottom: max(
                        compactLandscape ? 92 : 112,
                        geometry.safeAreaInsets.bottom + (compactLandscape ? 68 : 82)
                    ),
                    trailing: max(6, geometry.safeAreaInsets.trailing + 6)
                ),
                onTap: toggleControls
            )
            .ignoresSafeArea()
            .overlay {
                if controlsAreVisible {
                    LinearGradient(
                        colors: [.black.opacity(0.32), .clear, .black.opacity(0.42)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
        } else if let remoteTrack = media.remoteVideoTrack {
            SwiftUIVideoView(remoteTrack, layoutMode: media.remoteVideoIsScreenShare ? .fit : .fill, mirrorMode: .off)
                .ignoresSafeArea()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Video from \(coordinator.activeCall?.participantName ?? "caller")")
                .overlay {
                    if controlsAreVisible {
                        LinearGradient(
                            colors: [.black.opacity(0.46), .clear, .black.opacity(0.52)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .ignoresSafeArea()
                        .transition(.opacity)
                    }
                }
        } else {
            LiquidCallBackdrop(
                name: coordinator.activeCall?.participantName ?? "Kit Pay contact",
                avatarURL: coordinator.activeCall?.participantAvatarURL
            )
                .ignoresSafeArea()
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func callHeader(compactLandscape: Bool) -> some View {
        if let call = coordinator.activeCall {
            ZStack(alignment: .top) {
                callIdentity(call, compactLandscape: compactLandscape)
                    .padding(.horizontal, compactLandscape ? 126 : 62)

                HStack(alignment: .top) {
                    minimizeCallButton

                    Spacer()

                    if compactLandscape {
                        HStack(spacing: 10) {
                            participantAndMessageButtons(for: call)
                        }
                    } else {
                        VStack(spacing: 10) {
                            participantAndMessageButtons(for: call)
                        }
                    }
                }
            }
        } else {
            ProgressView()
                .tint(.white)
                .controlSize(.large)
        }
    }

    private func callIdentity(
        _ call: ActiveCallPresentation,
        compactLandscape: Bool
    ) -> some View {
        VStack(spacing: compactLandscape ? 1 : 3) {
            VerifiedAccountNameLabel(designation: call.participantVerification) {
                Text(call.participantName)
                    .font(compactLandscape ? .headline.bold() : .title2.bold())
                    .foregroundStyle(callForeground)
                    .lineLimit(compactLandscape ? 1 : 2)
                    .minimumScaleFactor(0.72)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
            }

            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let status = callStatus(at: timeline.date)
                Text(status)
                    .font(compactLandscape ? .subheadline : .title3)
                    .foregroundStyle(callSecondaryForeground)
                    .monospacedDigit()
                    .accessibilityLabel("Call status")
                    .accessibilityValue(status)
            }

            if let error = coordinator.controlError {
                Text(error)
                    .font(compactLandscape ? .caption2 : .caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.orange)
                    .lineLimit(compactLandscape ? 1 : 2)
            }
        }
    }

    private var minimizeCallButton: some View {
        callHeaderButton(
            icon: "arrow.down.right.and.arrow.up.left",
            label: "Minimize call"
        ) {
            onMinimize()
        }
    }

    @ViewBuilder
    private func participantAndMessageButtons(
        for call: ActiveCallPresentation
    ) -> some View {
        callHeaderButton(
            icon: "person.badge.plus",
            label: "Add participant",
            enabled: model.canInviteParticipant(to: call)
        ) {
            showsAddParticipant = true
            revealControls()
        }
        let unreadMessageCount = model.unreadMessageCount(for: call)
        callHeaderButton(
            icon: "message.fill",
            label: unreadMessageCount > 0
                ? "Open chat, \(unreadMessageCount) unread \(unreadMessageCount == 1 ? "message" : "messages")"
                : "Open chat",
            enabled: !isOpeningConversation && model.canOpenConversation(for: call),
            badgeCount: unreadMessageCount
        ) {
            guard !isOpeningConversation else { return }
            isOpeningConversation = true
            Task { @MainActor in
                defer { isOpeningConversation = false }
                guard await model.openConversation(for: call) else { return }
                onMinimize()
            }
        }
    }

    private var screenSharingStatus: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.on.rectangle")
            Text(screenSharing.phase == .sharing ? "You’re sharing your screen"
                 : screenSharing.phase == .awaitingApproval ? "Waiting for screen sharing approval"
                 : screenSharing.phase == .awaitingConfirmation ? "Confirm sharing with this call"
                 : screenSharing.phase == .stopping ? "Stopping screen sharing…" : "Starting screen sharing…")
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 4)
            if screenSharing.phase.canStop {
                Button(screenSharing.phase == .awaitingApproval ? "Cancel" : "Stop") {
                    coordinator.stopScreenSharing()
                }
                .font(.subheadline.bold())
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Stop screen sharing")
            }
        }
        .padding(.horizontal, 14)
        .foregroundStyle(callForeground)
        .kitGlass(cornerRadius: 22, tint: panelTint, tintStrength: 1)
        .accessibilityIdentifier("call.screen-sharing.status")
    }

    private var controlsPanel: some View {
        HStack(spacing: 3) {
            callControl(
                icon: "ellipsis",
                label: "More",
                selected: showsMoreControls,
                enabled: CallControlAvailabilityPolicy.moreControlsAreEnabled(
                    isConnected: isConnected,
                    isReconnecting: isReconnecting
                )
            ) {
                revealControls()
                withAnimation(reduceMotion ? nil : .snappy) { showsMoreControls = true }
            }

            callControl(
                icon: media.isCameraEnabled ? "video.fill" : "video.slash.fill",
                label: "Video",
                selected: media.isCameraEnabled,
                isToggle: true,
                enabled: CallControlAvailabilityPolicy.cameraControlIsEnabled(
                    isConnected: isConnected,
                    isReconnecting: isReconnecting
                )
            ) {
                Task { await coordinator.toggleCamera() }
            }

            callControl(
                icon: media.audioRouteSymbolName,
                label: media.audioRouteControlLabel,
                selected: media.isSpeakerEnabled,
                isToggle: true,
                enabled: CallControlAvailabilityPolicy.speakerControlIsEnabled(
                    isConnected: isConnected,
                    isReconnecting: isReconnecting,
                    route: media.audioRoute
                )
            ) {
                coordinator.toggleSpeaker()
            }

            callControl(
                icon: media.isMicrophoneEnabled ? "mic.fill" : "mic.slash.fill",
                label: media.isMicrophoneEnabled ? "Mute" : "Unmute",
                selected: !media.isMicrophoneEnabled,
                isToggle: true,
                enabled: CallControlAvailabilityPolicy.microphoneControlIsEnabled(
                    isConnected: isConnected,
                    isReconnecting: isReconnecting
                )
            ) {
                coordinator.requestMuted(media.isMicrophoneEnabled)
            }

            callControl(
                icon: "phone.down.fill",
                label: "End",
                destructive: true,
                enabled: coordinator.state != .ending
            ) {
                coordinator.requestEnd()
            }
        }
        .padding(8)
        .kitGlass(cornerRadius: 38, tint: panelTint, tintStrength: 1)
    }

    private func callHeaderButton(
        icon: String,
        label: String,
        enabled: Bool = true,
        badgeCount: Int = 0,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            revealControls()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(callForeground)
                .frame(width: 48, height: 48)
                .background(
                    reduceTransparency ? opaqueControlColor : glassControlColor,
                    in: Circle()
                )
                .overlay {
                    Circle()
                        .stroke(glassBorderColor, lineWidth: 0.8)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .topTrailing) {
                    if badgeCount > 0 {
                        Text(badgeCount > 99 ? "99+" : "\(badgeCount)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .padding(.horizontal, badgeCount > 9 ? 5 : 4)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(.red, in: Capsule())
                            .overlay {
                                Capsule().stroke(.white.opacity(0.9), lineWidth: 1)
                            }
                            .offset(x: 5, y: -5)
                            .accessibilityHidden(true)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel(label)
        .accessibilityValue(enabled ? "" : "Unavailable")
    }

    private func callControl(
        icon: String,
        label: String,
        selected: Bool = false,
        isToggle: Bool = false,
        destructive: Bool = false,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            revealControls()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(
                    destructive
                        ? .white
                        : selected ? selectedControlForeground : callForeground
                )
                .frame(width: 48, height: 48)
                .background(
                    destructive
                        ? Color(red: 0.98, green: 0.02, blue: 0.25)
                        : selected ? selectedControlColor : glassControlColor,
                    in: Circle()
                )
                .opacity(enabled ? 1 : 0.38)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .accessibilityValue(
            enabled
                ? (isToggle ? (selected ? "On" : "Off") : "")
                : "Unavailable"
        )
    }

    private var isConnected: Bool { coordinator.state == .connected }

    private var isReconnecting: Bool { coordinator.state == .reconnecting }

    private var shouldAutoHideControls: Bool {
        CallControlsVisibilityPolicy.shouldAutoHide(
            isVideoCall: isVideoPresentation,
            isConnected: coordinator.state == .connected,
            hasVideoSurface: hasRemoteParticipantGrid
                || media.remoteVideoTrack != nil
                || (media.isCameraEnabled && media.localVideoTrack != nil),
            isAdditionalControlsPresented: showsMoreControls || showsAddParticipant
                || confirmsScreenSharing || screenSharing.phase != .idle,
            hasWaitingCall: model.waitingCall != nil,
            isFloatingSurfaceInteracting: localPreviewIsDragging,
            isAssistiveNavigationActive: assistiveNavigationEnabled,
            areControlsVisible: controlsAreVisible
        )
    }

    private var usesRemoteParticipantGrid: Bool {
        ActiveCallParticipantGridPolicy.shouldUseGrid(
            isVideoPresentation: isVideoPresentation,
            backendParticipantCount: model.participantUserIDs(for: coordinator.activeCall).count,
            remoteParticipantCount: media.remoteParticipantSurfaces.count
        )
    }

    private var isVideoPresentation: Bool {
        ActiveCallVideoPresentationPolicy.isVideo(
            callWasVideo: coordinator.activeCall?.video == true,
            localCameraEnabled: media.isCameraEnabled,
            hasRemoteVideo: media.remoteVideoTrack != nil
        )
    }

    private var hasRemoteParticipantGrid: Bool {
        usesRemoteParticipantGrid && !media.remoteParticipantSurfaces.isEmpty
    }

    private var groupParticipantTiles: [GroupCallParticipantTileModel] {
        var contactsByUserID: [String: WalletContactDTO] = [:]
        for contact in model.contactDirectory where contact.isKitUser == true {
            guard let rawID = ContactRecipientDirectory.recipientUserId(for: contact),
                  let id = UUID(uuidString: rawID)?.uuidString.lowercased(),
                  contactsByUserID[id] == nil
            else { continue }
            contactsByUserID[id] = contact
        }

        return media.remoteParticipantSurfaces.map { participant in
            let userID = RemoteCallParticipantPresentationPolicy.userID(
                fromLiveKitIdentity: participant.identity
            )
            let contact = userID.flatMap { contactsByUserID[$0] }
            return GroupCallParticipantTileModel(
                id: participant.id,
                name: RemoteCallParticipantPresentationPolicy.displayName(
                    contactName: contact?.name,
                    serverName: participant.name
                ),
                avatarURL: userID.flatMap { model.contactAvatarURL(forUserID: $0) },
                verification: userID.flatMap { model.contactVerification(forUserID: $0) },
                videoTrack: participant.preferredVideoTrack,
                isScreenSharing: participant.isScreenSharing,
                isSpeaking: participant.isSpeaking
            )
        }
    }

    private func revealControls() {
        updateControlsVisibility(true)
        autoHideGeneration &+= 1
    }

    private func toggleControls() {
        let shouldShowControls = CallControlsVisibilityPolicy.visibilityAfterSurfaceTap(
            isVideoCall: isVideoPresentation,
            areControlsVisible: controlsAreVisible,
            hasWaitingCall: model.waitingCall != nil,
            isAssistiveNavigationActive: assistiveNavigationEnabled
        )
        if shouldShowControls {
            revealControls()
        } else {
            updateControlsVisibility(false)
        }
    }

    private func dismissMoreControls() {
        withAnimation(reduceMotion ? nil : .snappy) { showsMoreControls = false }
        revealControls()
    }

    private var assistiveNavigationEnabled: Bool {
        voiceOverEnabled || switchControlEnabled
    }

    private func updateControlsVisibility(_ visible: Bool) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            controlsAreVisible = visible || model.waitingCall != nil
        }
    }

    private func callStatus(at date: Date) -> String {
        switch coordinator.state {
        case .idle:
            "Call ended"
        case .preparing:
            coordinator.activeCall?.direction == "outgoing" && !coordinator.presentedCallWasAnswered
                ? "Ringing…"
                : "Preparing…"
        case .connecting:
            "Connecting…"
        case .reconnecting:
            "Reconnecting…"
        case .connected:
            if media.hasRemoteParticipant {
                // Derived from the answer anchor when one exists, so both sides count from
                // the same server instant instead of from whenever each side's media landed.
                CallDurationFormatter.string(
                    from: coordinator.presentedCallDurationSeconds()
                        .map { date.addingTimeInterval(TimeInterval(-$0)) }
                        ?? media.remoteParticipantConnectedAt
                        ?? date,
                    to: date
                )
            } else if media.remoteParticipantConnectedAt != nil {
                // The other side was connected before; don't regress to "Ringing…" while the
                // remote-absence grace period waits for them to come back.
                "Waiting for them to reconnect…"
            } else {
                CallAwaitingRemoteStatusPolicy.label(
                    isOutgoing: coordinator.activeCall?.direction == "outgoing",
                    answered: coordinator.presentedCallWasAnswered
                )
            }
        case .ending:
            "Ending…"
        }
    }

    private var hasVideoBackdrop: Bool {
        media.remoteVideoTrack != nil || hasRemoteParticipantGrid
    }

    private var callForeground: Color {
        hasVideoBackdrop || colorScheme == .dark ? .white : KitColor.navy
    }

    private var callSecondaryForeground: Color {
        callForeground.opacity(colorScheme == .dark || hasVideoBackdrop ? 0.66 : 0.62)
    }

    private var panelTint: Color {
        if hasVideoBackdrop { return .black.opacity(0.34) }
        return colorScheme == .dark ? .black.opacity(0.28) : .white.opacity(0.24)
    }

    private var opaqueControlColor: Color {
        colorScheme == .dark ? Color(white: 0.22) : Color(white: 0.84)
    }

    private var glassControlColor: Color {
        if hasVideoBackdrop || colorScheme == .dark { return .white.opacity(0.17) }
        return .white.opacity(0.52)
    }

    private var selectedControlColor: Color {
        colorScheme == .dark || hasVideoBackdrop ? .white : .white.opacity(0.92)
    }

    private var selectedControlForeground: Color {
        colorScheme == .dark || hasVideoBackdrop ? .black : KitColor.navy
    }

    private var glassBorderColor: Color {
        colorScheme == .dark || hasVideoBackdrop ? .white.opacity(0.10) : .white.opacity(0.72)
    }
}

private struct CallWaitingGlassBanner: View {
    let callerName: String
    let isVideo: Bool
    let isMerging: Bool
    let decline: () -> Void
    let merge: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                callIdentity
                Spacer(minLength: 8)
                actionButtons(useFlexibleWidth: false)
            }

            VStack(alignment: .leading, spacing: 12) {
                callIdentity
                actionButtons(useFlexibleWidth: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .kitGlass(
            cornerRadius: 26,
            tint: bannerTint,
            tintStrength: 1
        )
        .accessibilityElement(children: .contain)
    }

    private var callIdentity: some View {
        HStack(spacing: 11) {
            Image(systemName: isVideo ? "video.fill" : "phone.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(primaryForeground)
                .frame(width: 42, height: 42)
                .background(controlBackground, in: Circle())
                .overlay {
                    Circle()
                        .stroke(.white.opacity(0.18), lineWidth: 0.8)
                        .allowsHitTesting(false)
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Call waiting")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(secondaryForeground)

                Text(callerName)
                    .font(.headline)
                    .foregroundStyle(primaryForeground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Text(isVideo ? "Incoming video call" : "Incoming voice call")
                    .font(.caption)
                    .foregroundStyle(secondaryForeground)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Call waiting from \(callerName)")
        .accessibilityValue(isVideo ? "Incoming video call" : "Incoming voice call")
    }

    private func actionButtons(useFlexibleWidth: Bool) -> some View {
        HStack(spacing: 10) {
            waitingActionButton(
                title: "Decline",
                systemImage: "phone.down.fill",
                color: Color(red: 0.91, green: 0.17, blue: 0.22),
                foreground: .white,
                useFlexibleWidth: useFlexibleWidth,
                enabled: !isMerging,
                disabledAccessibilityValue: "Unavailable while merging",
                action: decline
            )

            waitingActionButton(
                title: isMerging ? "Merging…" : "Merge",
                systemImage: "person.2.fill",
                color: KitColor.green,
                foreground: KitColor.deepNavy,
                useFlexibleWidth: useFlexibleWidth,
                showsProgress: isMerging,
                enabled: !isMerging,
                disabledAccessibilityValue: "In progress",
                action: merge
            )
        }
    }

    private func waitingActionButton(
        title: String,
        systemImage: String,
        color: Color,
        foreground: Color,
        useFlexibleWidth: Bool,
        showsProgress: Bool = false,
        enabled: Bool = true,
        disabledAccessibilityValue: String = "Unavailable",
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if showsProgress {
                    ProgressView()
                        .controlSize(.small)
                        .tint(foreground)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 14, weight: .bold))
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: useFlexibleWidth ? .infinity : nil)
            .frame(minWidth: useFlexibleWidth ? 0 : 104, minHeight: 44)
            .padding(.horizontal, useFlexibleWidth ? 10 : 14)
            .background(color.gradient, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(.white.opacity(0.28), lineWidth: 0.8)
                    .allowsHitTesting(false)
            }
            .shadow(color: color.opacity(0.24), radius: 8, y: 4)
            .saturation(enabled ? 1 : 0.35)
            .opacity(enabled ? 1 : 0.52)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(title)
        .accessibilityValue(enabled ? "" : disabledAccessibilityValue)
    }

    private var bannerTint: Color {
        if reduceTransparency {
            return colorScheme == .dark ? KitColor.deepNavy : .white
        }
        return colorScheme == .dark
            ? KitColor.deepNavy.opacity(0.68)
            : .white.opacity(0.38)
    }

    private var controlBackground: Color {
        if reduceTransparency {
            return colorScheme == .dark ? .white.opacity(0.14) : KitColor.navy.opacity(0.09)
        }
        return colorScheme == .dark ? .white.opacity(0.14) : .white.opacity(0.56)
    }

    private var primaryForeground: Color {
        colorScheme == .dark ? .white : KitColor.navy
    }

    private var secondaryForeground: Color {
        primaryForeground.opacity(0.68)
    }
}

private struct GroupCallParticipantTileModel: Identifiable {
    let id: String
    let name: String
    let avatarURL: String?
    let verification: AccountVerificationDesignation?
    let videoTrack: VideoTrack?
    let isScreenSharing: Bool
    let isSpeaking: Bool
}

private struct GroupCallParticipantGrid: View {
    let participants: [GroupCallParticipantTileModel]
    let contentInsets: EdgeInsets
    let onTap: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let availableSize = CGSize(
                width: max(
                    1,
                    geometry.size.width - contentInsets.leading - contentInsets.trailing
                ),
                height: max(
                    1,
                    geometry.size.height - contentInsets.top - contentInsets.bottom
                )
            )
            let columnCount = ActiveCallParticipantGridPolicy.columnCount(
                participantCount: participants.count,
                availableSize: availableSize
            )
            let tileHeight = ActiveCallParticipantGridPolicy.tileHeight(
                participantCount: participants.count,
                columnCount: columnCount,
                availableSize: availableSize
            )
            let columns = Array(
                repeating: GridItem(
                    .flexible(minimum: 0, maximum: .infinity),
                    spacing: ActiveCallParticipantGridPolicy.spacing
                ),
                count: max(1, columnCount)
            )

            ScrollView(.vertical) {
                LazyVGrid(
                    columns: columns,
                    alignment: .leading,
                    spacing: ActiveCallParticipantGridPolicy.spacing
                ) {
                    ForEach(participants) { participant in
                        GroupCallParticipantTile(participant: participant)
                            .frame(height: tileHeight)
                    }
                }
                .frame(minHeight: availableSize.height, alignment: .center)
                .padding(.top, contentInsets.top)
                .padding(.leading, contentInsets.leading)
                .padding(.bottom, contentInsets.bottom)
                .padding(.trailing, contentInsets.trailing)
            }
            .scrollIndicators(.hidden)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
        }
        .background(Color(red: 0.035, green: 0.09, blue: 0.14))
    }
}

private struct GroupCallParticipantTile: View {
    let participant: GroupCallParticipantTileModel

    var body: some View {
        GeometryReader { geometry in
            let avatarSize = min(96, max(52, min(geometry.size.width, geometry.size.height) * 0.38))

            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.12, green: 0.25, blue: 0.34),
                        Color(red: 0.04, green: 0.11, blue: 0.18),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                if let videoTrack = participant.videoTrack {
                    SwiftUIVideoView(
                        videoTrack,
                        layoutMode: participant.isScreenSharing ? .fit : .fill,
                        mirrorMode: .off
                    )
                    .allowsHitTesting(false)
                } else {
                    CallParticipantAvatarView(
                        name: participant.name,
                        avatarURL: participant.avatarURL,
                        size: avatarSize
                    )
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 6) {
                    if participant.isScreenSharing {
                        Image(systemName: "rectangle.on.rectangle.fill")
                            .font(.caption2.weight(.semibold))
                            .accessibilityHidden(true)
                    }
                    VerifiedAccountNameLabel(
                        designation: participant.verification,
                        badgeDiameter: 12
                    ) {
                        Text(participant.name)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.top, 24)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.72)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(
                        participant.isSpeaking ? KitColor.green : .white.opacity(0.16),
                        lineWidth: participant.isSpeaking ? 3 : 0.8
                    )
                    .allowsHitTesting(false)
            }
            .shadow(
                color: participant.isSpeaking ? KitColor.green.opacity(0.28) : .black.opacity(0.24),
                radius: participant.isSpeaking ? 9 : 6,
                y: 3
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(participant.name)
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        if participant.isScreenSharing && participant.isSpeaking {
            return "Sharing screen, speaking"
        }
        if participant.isScreenSharing { return "Sharing screen" }
        if participant.isSpeaking { return "Speaking" }
        return participant.videoTrack == nil ? "Camera off" : "Video"
    }
}

private struct ActiveCallParticipantSearchTaskKey: Hashable {
    let query: String
    let isOnline: Bool
    let participantIDs: Set<String>
}

/// Matches Android's connected-call people picker while retaining iOS contact ordering and tag
/// discovery. Only callable Kit Pay users are shown; invite-only address-book rows never reach the
/// authenticated call-invite endpoint.
private struct ActiveCallParticipantSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let activeCall: ActiveCallPresentation

    @State private var query = ""
    @State private var directoryResults: [KitUserSearchResultDTO] = []
    @State private var directoryResultQuery: String?
    @State private var directorySearchID: UUID?
    @State private var directorySearchQuery: String?
    @State private var invitingRecipientID: String?
    @State private var inlineError: String?

    var body: some View {
        let participants = model.participantUserIDs(for: activeCall)
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = trimmedQuery.isEmpty
            ? model.callContacts
            : model.callContacts.filter { model.callContactMatches($0, query: trimmedQuery) }
        let savedKitContacts = matches.filter {
            $0.isKitUser
                && !participants.contains($0.id.lowercased())
                && model.communicationPrivacyAllowsOutbound(to: $0.id)
        }
        let remoteQuery = KitUserDirectorySearch.remoteQuery(from: query)
        let currentDirectoryResults = directoryResultQuery == remoteQuery
            ? directoryResults
            : []
        let excludedIDs = participants.union(savedKitContacts.map { $0.id.lowercased() })
        let remoteContacts = remoteQuery == nil ? [] : KitUserDirectorySearch.addressableContacts(
            from: currentDirectoryResults,
            excludingUserID: model.profile?.id,
            excludingRecipientIDs: excludedIDs
        )
        let remoteCallContacts = CallLifecyclePolicy.contactOptions(
            remote: remoteContacts,
            history: [],
            context: model.phoneIdentityContext,
            excludingUserId: model.profile?.id,
            remoteAlreadyOrdered: true
        ).filter {
            $0.isKitUser && model.communicationPrivacyAllowsOutbound(to: $0.id)
        }
        let contacts = savedKitContacts + remoteCallContacts
        let isSearching = directorySearchID != nil && directorySearchQuery == remoteQuery

        NavigationStack {
            Form {
                Section {
                    TextField("Search contacts or @tag", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                ContactSyncRecoveryView()

                if isSearching && contacts.isEmpty {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Searching Kit Pay…")
                                .foregroundStyle(KitColor.secondaryText)
                        }
                    }
                } else if contacts.isEmpty {
                    Section {
                        ContentUnavailableView(
                            trimmedQuery.isEmpty ? "No one else to add" : "No Kit Pay user found",
                            systemImage: "person.crop.circle.badge.questionmark",
                            description: Text(
                                trimmedQuery.isEmpty
                                    ? "Your Kit Pay contacts who are not already in this call will appear here."
                                    : "Try another saved name, phone number, or @tag."
                            )
                        )
                    }
                } else {
                    Section("Add to call") {
                        ForEach(contacts) { contact in
                            Button {
                                invite(contact)
                            } label: {
                                HStack(spacing: 12) {
                                    RemoteAvatarView(
                                        name: contact.name,
                                        avatarURL: contact.source?.avatarURL,
                                        size: 42
                                    )
                                    VStack(alignment: .leading, spacing: 3) {
                                        VerifiedAccountNameLabel(
                                            designation: contact.source?.verification?.designation
                                        ) {
                                            Text(contact.name)
                                                .font(.headline)
                                                .foregroundStyle(KitColor.primaryText)
                                        }
                                        Text(contact.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(KitColor.secondaryText)
                                    }
                                    Spacer()
                                    if invitingRecipientID?.caseInsensitiveCompare(contact.id)
                                        == .orderedSame {
                                        ProgressView()
                                    } else {
                                        Image(systemName: "person.badge.plus")
                                            .foregroundStyle(KitColor.green)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(invitingRecipientID != nil || !model.canInviteParticipant(to: activeCall))
                            .accessibilityLabel("Add \(contact.name) to call")
                        }
                    }
                }

                if let inlineError {
                    Section {
                        Label(inlineError, systemImage: "exclamationmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add to call")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await model.loadCallContacts() }
            .task(
                id: ActiveCallParticipantSearchTaskKey(
                    query: query,
                    isOnline: model.isOnline,
                    participantIDs: participants
                )
            ) {
                await searchDirectory(excluding: participants)
            }
        }
    }

    private func invite(_ contact: CallableContact) {
        guard invitingRecipientID == nil else { return }
        invitingRecipientID = contact.id
        inlineError = nil
        Task { @MainActor in
            let invited = await model.inviteParticipant(contact.id, to: activeCall)
            guard invitingRecipientID?.caseInsensitiveCompare(contact.id) == .orderedSame else {
                return
            }
            invitingRecipientID = nil
            if invited {
                dismiss()
            } else {
                inlineError = model.lastError
                    ?? "This person could not be added to the call. Please try again."
            }
        }
    }

    @MainActor
    private func searchDirectory(excluding participantIDs: Set<String>) async {
        guard let requestedQuery = KitUserDirectorySearch.remoteQuery(from: query) else {
            directorySearchID = nil
            directorySearchQuery = nil
            directoryResultQuery = nil
            directoryResults = []
            return
        }

        let requestID = UUID()
        directorySearchID = requestID
        directorySearchQuery = requestedQuery
        directoryResultQuery = nil
        directoryResults = []
        defer {
            if directorySearchID == requestID {
                directorySearchID = nil
                directorySearchQuery = nil
            }
        }
        guard model.isSignedIn, model.isOnline else { return }

        do {
            try await Task.sleep(nanoseconds: 350_000_000)
            let results = try await model.searchKitUsers(query: requestedQuery)
            try Task.checkCancellation()
            guard directorySearchID == requestID,
                  KitUserDirectorySearch.remoteQuery(from: query) == requestedQuery,
                  model.participantUserIDs(for: activeCall) == participantIDs
            else { return }
            directoryResults = results
            directoryResultQuery = requestedQuery
        } catch is CancellationError {
            return
        } catch {
            guard directorySearchID == requestID,
                  KitUserDirectorySearch.remoteQuery(from: query) == requestedQuery
            else { return }
            directoryResults = []
            directoryResultQuery = requestedQuery
        }
    }
}

struct MinimizedCallView: View {
    @ObservedObject private var coordinator: CallMediaCoordinator
    @ObservedObject private var media: LiveKitCallMediaTransport
    @ObservedObject private var screenSharing: CallScreenSharingController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// Free resting origin of the video tile (window coordinates); `nil` means the default
    /// bottom-trailing parking spot. Owned by the presenter so it survives presentation changes.
    @Binding private var position: CGPoint?
    /// Which side edge the tile is tucked behind, or `nil` when fully on screen.
    @Binding private var tuckedEdge: CallFloatingTuckEdge?
    @State private var dragTranslation: CGSize = .zero
    @State private var isDragging = false
    /// VoiceOver's adjustable action still moves the tile between the well-known anchors.
    @State private var accessibilityAnchor: CallFloatingCorner = .bottomTrailing
    let windowSafeAreaInsets: EdgeInsets
    let reopen: () -> Void
    /// Reports where the surface is drawn, in window coordinates, so the host window can forward
    /// only the touches that land on it and let everything else reach the app underneath.
    let onSurfaceFrameChange: ((CGRect) -> Void)?

    init(
        coordinator: CallMediaCoordinator,
        position: Binding<CGPoint?>,
        tuckedEdge: Binding<CallFloatingTuckEdge?>,
        windowSafeAreaInsets: EdgeInsets,
        reopen: @escaping () -> Void,
        onSurfaceFrameChange: ((CGRect) -> Void)? = nil
    ) {
        _coordinator = ObservedObject(wrappedValue: coordinator)
        _media = ObservedObject(wrappedValue: coordinator.media)
        _screenSharing = ObservedObject(wrappedValue: coordinator.media.screenSharing)
        _position = position
        _tuckedEdge = tuckedEdge
        self.windowSafeAreaInsets = windowSafeAreaInsets
        self.reopen = reopen
        self.onSurfaceFrameChange = onSurfaceFrameChange
    }

    var body: some View {
        GeometryReader { geometry in
            if let call = coordinator.activeCall {
                if isVideoPresentation(for: call) {
                    draggableVideoSurface(for: call, in: geometry)
                } else {
                    // An audio call presents as a static, full-width banner that extends behind
                    // the status area and Dynamic Island — the system-call-strip pattern —
                    // instead of a movable bubble fighting the notch.
                    staticAudioCallBar(for: call, in: geometry)
                }
            }
        }
        // The hit region is zeroed only here, from the one stable ancestor. Zeroing inside each
        // presentation branch raced the audio↔video swap: the incoming branch's onAppear reported
        // its frame first and the outgoing branch's onDisappear then wiped it, leaving the new
        // surface untappable through the pass-through window.
        .onDisappear { onSurfaceFrameChange?(.zero) }
    }

    @ViewBuilder
    private func draggableVideoSurface(
        for call: ActiveCallPresentation,
        in geometry: GeometryProxy
    ) -> some View {
        let insets = CallFloatingInsets(windowSafeAreaInsets)
        let container = geometry.size
        // The overlay window ignores safe areas, so the status-bar clearance is read from the
        // window rather than from this (zeroed) geometry.
        let topInset = insets.top
        let surfaceSize = CallFloatingSurfaceLayoutPolicy.minimizedSurfaceSize(
            container: container,
            isVideo: true
        )
        let defaultOrigin = CallFloatingSurfaceLayoutPolicy.origin(
            for: .bottomTrailing,
            surfaceSize: surfaceSize,
            container: container,
            insets: insets,
            bottomClearance: CallFloatingSurfaceLayoutPolicy.rootMenuClearance
        )
        // Free placement: the tile rests wherever the user left it, re-clamped for the current
        // screen so rotations and size changes cannot strand it off screen.
        let restingOrigin = CallFloatingTilePlacementPolicy.clampedOrigin(
            position ?? defaultOrigin,
            surfaceSize: surfaceSize,
            container: container,
            topInset: topInset
        )
        let baseOrigin = tuckedEdge.map { edge in
            CallFloatingTilePlacementPolicy.tuckedTileOrigin(
                edge: edge,
                surfaceSize: surfaceSize,
                restingOrigin: restingOrigin,
                container: container,
                topInset: topInset
            )
        } ?? restingOrigin
        // The tile follows the finger exactly — including past the side edges, so a tuck reads as
        // pushing it off the screen. Release clamps back on screen or tucks.
        let displayedOrigin = CGPoint(
            x: baseOrigin.x + dragTranslation.width,
            y: baseOrigin.y + dragTranslation.height
        )
        let globalOrigin = geometry.frame(in: .global).origin
        let tileWindowFrame = CGRect(
            origin: CGPoint(
                x: displayedOrigin.x + globalOrigin.x,
                y: displayedOrigin.y + globalOrigin.y
            ),
            size: surfaceSize
        )
        let handleFrame = tuckedEdge.map { edge in
            CallFloatingTilePlacementPolicy.handleFrame(
                edge: edge,
                tileCenterY: restingOrigin.y + surfaceSize.height / 2,
                container: container,
                topInset: topInset
            )
        }
        // While tucked, the pass-through window must forward exactly the handle's touches and
        // nothing else; the off-screen tile stays mounted so the video keeps playing.
        let interactiveWindowFrame = handleFrame?
            .offsetBy(dx: globalOrigin.x, dy: globalOrigin.y)
            ?? tileWindowFrame

        ZStack(alignment: .topLeading) {
            minimizedSurface(for: call, size: surfaceSize)
                .frame(width: surfaceSize.width, height: surfaceSize.height)
                .scaleEffect(isDragging && !reduceMotion ? 1.025 : 1)
                .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .highPriorityGesture(
                    minimizedDragGesture(
                        restingOrigin: restingOrigin,
                        surfaceSize: surfaceSize,
                        container: container,
                        topInset: topInset
                    )
                )
                .position(
                    x: displayedOrigin.x + surfaceSize.width / 2,
                    y: displayedOrigin.y + surfaceSize.height / 2
                )
                .allowsHitTesting(tuckedEdge == nil)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Active call with \(call.participantName)")
                .accessibilityValue(compactStatus(for: call))
                .accessibilityAdjustableAction { direction in
                    moveAnchor(
                        direction,
                        surfaceSize: surfaceSize,
                        container: container,
                        insets: insets
                    )
                }
                .accessibilityHidden(tuckedEdge != nil)

            if let edge = tuckedEdge, let handleFrame {
                tuckHandle(edge: edge, for: call)
                    .frame(width: handleFrame.width, height: handleFrame.height)
                    .position(x: handleFrame.midX, y: handleFrame.midY)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { onSurfaceFrameChange?(interactiveWindowFrame) }
        .onChange(of: interactiveWindowFrame) { _, frame in onSurfaceFrameChange?(frame) }
        .onDisappear {
            dragTranslation = .zero
            isDragging = false
        }
    }

    /// The restore handle left on screen while the tile is tucked: a glass capsule hugging the
    /// edge with a chevron pointing the way the tile will return. The interactive frame is
    /// 44pt wide even though only 30pt are drawn.
    private func tuckHandle(
        edge: CallFloatingTuckEdge,
        for call: ActiveCallPresentation
    ) -> some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(reduceMotion ? nil : .spring(duration: 0.32, bounce: 0.12)) {
                tuckedEdge = nil
            }
        } label: {
            let radii = edge == .leading
                ? RectangleCornerRadii(bottomTrailing: 16, topTrailing: 16)
                : RectangleCornerRadii(topLeading: 16, bottomLeading: 16)
            let shape = UnevenRoundedRectangle(cornerRadii: radii, style: .continuous)
            ZStack {
                ZStack {
                    if reduceTransparency {
                        shape.fill(Color(UIColor.secondarySystemBackground))
                    } else {
                        shape.fill(.regularMaterial)
                        shape.fill(KitColor.green.opacity(0.10))
                    }
                }
                .overlay {
                    shape
                        .strokeBorder(.white.opacity(0.38), lineWidth: 0.8)
                        .allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(0.22), radius: 9, y: 4)

                Image(systemName: edge == .leading ? "chevron.right" : "chevron.left")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(KitColor.primaryText)
            }
            .frame(width: CallFloatingTilePlacementPolicy.tuckHandleVisibleWidth)
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: edge == .leading ? .leading : .trailing
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show call video")
        .accessibilityValue("Call with \(call.participantName)")
        .accessibilityHint("Brings the minimized call video back on screen")
    }

    /// Full-width in-app call strip for audio calls: static, integrated with the status area and
    /// Dynamic Island, with a live voice wave, duration, and inline mute/hang-up.
    private func staticAudioCallBar(
        for call: ActiveCallPresentation,
        in geometry: GeometryProxy
    ) -> some View {
        let topInset = max(0, windowSafeAreaInsets.top)
        let barContentHeight = CallBannerMetrics.contentHeight
        let barFrame = CallBannerMetrics.contentFrame(
            container: geometry.frame(in: .global), topInset: topInset
        )
        return ZStack(alignment: .bottom) {
            Button(action: reopen) {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: barContentHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Return to call with \(call.participantName)")
            .accessibilityValue(compactStatus(for: call))

            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    CallParticipantAvatarView(
                        name: call.participantName,
                        avatarURL: call.participantAvatarURL,
                        size: 38
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        VerifiedAccountNameLabel(
                            designation: call.participantVerification,
                            badgeDiameter: 13
                        ) {
                            Text(call.participantName)
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                        HStack(spacing: 5) {
                            Circle()
                                .fill(KitColor.green)
                                .frame(width: 7, height: 7)
                            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                                Text(compactStatus(for: call, at: timeline.date))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                    .lineLimit(1)
                            }
                        }
                    }
                    Spacer(minLength: 6)
                    CallBannerVoiceWave(
                        level: max(media.localVoiceLevel, media.remoteVoiceLevel),
                        isConnected: coordinator.state == .connected,
                        animated: !reduceMotion
                    )
                    .frame(width: 52, height: 22)
                }
                .contentShape(Rectangle())
                .allowsHitTesting(false)

                minimizedControl(
                    icon: media.isMicrophoneEnabled ? "mic.fill" : "mic.slash.fill",
                    label: media.isMicrophoneEnabled ? "Mute" : "Unmute",
                    foreground: media.isMicrophoneEnabled ? KitColor.primaryText : .white,
                    background: media.isMicrophoneEnabled
                        ? AnyShapeStyle(.thinMaterial)
                        : AnyShapeStyle(KitColor.navy),
                    enabled: CallControlAvailabilityPolicy.microphoneControlIsEnabled(
                        isConnected: coordinator.state == .connected,
                        isReconnecting: coordinator.state == .reconnecting
                    )
                ) {
                    coordinator.requestMuted(media.isMicrophoneEnabled)
                }
                .accessibilityIdentifier("call.banner.mute")
                minimizedControl(
                    icon: "phone.down.fill",
                    label: "End call",
                    foreground: .white,
                    background: AnyShapeStyle(Color(red: 0.98, green: 0.02, blue: 0.25)),
                    enabled: coordinator.state != .ending
                ) {
                    coordinator.requestEnd()
                }
                .accessibilityIdentifier("call.banner.end")
            }
            .padding(.leading, max(14, windowSafeAreaInsets.leading + 8))
            .padding(.trailing, max(14, windowSafeAreaInsets.trailing + 8))
            .frame(height: barContentHeight)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("call.banner.row")
        }
        .frame(height: topInset + barContentHeight, alignment: .bottom)
        .frame(maxWidth: .infinity)
        .background {
            // The material runs edge to edge and up behind the island, so the strip reads as one
            // piece with the system status area rather than a floating chip beside the notch.
            let shape = UnevenRoundedRectangle(
                cornerRadii: RectangleCornerRadii(bottomLeading: 22, bottomTrailing: 22),
                style: .continuous
            )
            ZStack {
                if reduceTransparency {
                    shape.fill(Color(UIColor.secondarySystemBackground))
                } else {
                    shape.fill(.regularMaterial)
                    shape.fill(KitColor.green.opacity(0.10))
                }
            }
            .overlay {
                shape
                    .strokeBorder(.white.opacity(0.42), lineWidth: 0.8)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
            .ignoresSafeArea(edges: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Active call with \(call.participantName)")
        .accessibilityValue(compactStatus(for: call))
        .onAppear { onSurfaceFrameChange?(barFrame) }
        .onChange(of: barFrame) { _, frame in onSurfaceFrameChange?(frame) }
    }

    private func minimizedDragGesture(
        restingOrigin: CGPoint,
        surfaceSize: CGSize,
        container: CGSize,
        topInset: CGFloat
    ) -> AnyGesture<DragGesture.Value> {
        AnyGesture(
            DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                if !isDragging {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                        isDragging = true
                    }
                }
                dragTranslation = value.translation
            }
            .onEnded { value in
                // Gentle momentum: the same capped projection as before, but the tile now settles
                // wherever the projection lands (clamped to the screen) instead of snapping to
                // the nearest corner — unless the release pushes it off a side edge, which tucks.
                let projected = CallFloatingSurfaceLayoutPolicy.projectedOrigin(
                    restingOrigin: restingOrigin,
                    translation: value.translation,
                    predictedEndTranslation: value.predictedEndTranslation
                )
                let rawReleaseOrigin = CGPoint(
                    x: restingOrigin.x + value.translation.width,
                    y: restingOrigin.y + value.translation.height
                )
                let horizontalProjection =
                    value.predictedEndTranslation.width - value.translation.width
                if let edge = CallFloatingTilePlacementPolicy.tuckedEdge(
                    forProjectedOrigin: projected,
                    surfaceSize: surfaceSize,
                    container: container,
                    horizontalProjection: horizontalProjection
                ) {
                    // Remember the on-screen spot the tile left from, so the handle restores it.
                    let preTuckOrigin = CallFloatingTilePlacementPolicy.clampedOrigin(
                        rawReleaseOrigin,
                        surfaceSize: surfaceSize,
                        container: container,
                        topInset: topInset
                    )
                    let tuckOrigin = CallFloatingTilePlacementPolicy.tuckedTileOrigin(
                        edge: edge,
                        surfaceSize: surfaceSize,
                        restingOrigin: preTuckOrigin,
                        container: container,
                        topInset: topInset
                    )
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        position = preTuckOrigin
                        tuckedEdge = edge
                        dragTranslation = CGSize(
                            width: rawReleaseOrigin.x - tuckOrigin.x,
                            height: rawReleaseOrigin.y - tuckOrigin.y
                        )
                    }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0)) {
                        dragTranslation = .zero
                        isDragging = false
                    }
                } else {
                    let targetOrigin = CallFloatingTilePlacementPolicy.clampedOrigin(
                        projected,
                        surfaceSize: surfaceSize,
                        container: container,
                        topInset: topInset
                    )
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        position = targetOrigin
                        dragTranslation = CGSize(
                            width: rawReleaseOrigin.x - targetOrigin.x,
                            height: rawReleaseOrigin.y - targetOrigin.y
                        )
                    }
                    withAnimation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0)) {
                        dragTranslation = .zero
                        isDragging = false
                    }
                }
            }
        )
    }

    /// VoiceOver's adjustable action keeps a deterministic tour of the well-known anchors, writing
    /// each anchor's origin into the free-placement position (and un-tucking first).
    private func moveAnchor(
        _ direction: AccessibilityAdjustmentDirection,
        surfaceSize: CGSize,
        container: CGSize,
        insets: CallFloatingInsets
    ) {
        let anchors = CallFloatingCorner.allCases
        guard let index = anchors.firstIndex(of: accessibilityAnchor) else { return }
        let delta: Int
        switch direction {
        case .increment: delta = 1
        case .decrement: delta = -1
        @unknown default: return
        }
        let next = anchors[(index + delta + anchors.count) % anchors.count]
        let origin = CallFloatingSurfaceLayoutPolicy.origin(
            for: next,
            surfaceSize: surfaceSize,
            container: container,
            insets: insets,
            bottomClearance: CallFloatingSurfaceLayoutPolicy.rootMenuClearance
        )
        withAnimation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0)) {
            accessibilityAnchor = next
            tuckedEdge = nil
            position = origin
            dragTranslation = .zero
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func minimizedSurface(
        for call: ActiveCallPresentation,
        size: CGSize
    ) -> some View {
            Button(action: reopen) {
                ZStack(alignment: .bottomLeading) {
                    minimizedVideo(for: call, size: size)

                    LinearGradient(
                        colors: [.clear, .black.opacity(0.72)],
                        startPoint: .center,
                        endPoint: .bottom
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        VerifiedAccountNameLabel(
                            designation: call.participantVerification,
                            badgeDiameter: 12
                        ) {
                            Text(call.participantName)
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }
                        HStack(spacing: 5) {
                            Circle()
                                .fill(KitColor.green)
                                .frame(width: 7, height: 7)
                            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                                Text(compactStatus(for: call, at: timeline.date))
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.white.opacity(0.88))
                                    .monospacedDigit()
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(12)
                }
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(.white.opacity(0.42), lineWidth: 0.8)
                        .allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(0.34), radius: 18, y: 9)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Return to call with \(call.participantName)")
            .accessibilityValue(compactStatus(for: call))
    }

    private func isVideoPresentation(for call: ActiveCallPresentation) -> Bool {
        ActiveCallVideoPresentationPolicy.isVideo(
            callWasVideo: call.video,
            localCameraEnabled: media.isCameraEnabled,
            hasRemoteVideo: media.remoteVideoTrack != nil
        )
    }

    private func minimizedControl(
        icon: String,
        label: String,
        foreground: Color,
        background: AnyShapeStyle,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(
                    width: CallFloatingSurfaceLayoutPolicy.minimizedControlDimension,
                    height: CallFloatingSurfaceLayoutPolicy.minimizedControlDimension
                )
                .background(background, in: Circle())
                .overlay {
                    Circle()
                        .stroke(.white.opacity(0.34), lineWidth: 0.7)
                        .allowsHitTesting(false)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel(label)
        .accessibilityValue(enabled ? "" : "Unavailable")
    }

    @ViewBuilder
    private func minimizedVideo(
        for call: ActiveCallPresentation,
        size: CGSize
    ) -> some View {
        ZStack {
            if let remoteTrack = media.remoteVideoTrack {
                SwiftUIVideoView(remoteTrack, layoutMode: media.remoteVideoIsScreenShare ? .fit : .fill, mirrorMode: .off)
            } else {
                ZStack {
                    LiquidCallBackdrop(
                        name: call.participantName,
                        avatarURL: call.participantAvatarURL
                    )
                    CallParticipantAvatarView(
                        name: call.participantName,
                        avatarURL: call.participantAvatarURL,
                        size: min(size.width * 0.58, 82)
                    )
                }
            }
        }
        .overlay(alignment: .topLeading) {
            if media.isCameraEnabled,
               let localTrack = media.localVideoTrack {
                let insetWidth = min(44, max(30, size.width * 0.28))
                SwiftUIVideoView(
                    localTrack,
                    layoutMode: .fill,
                    mirrorMode: media.isFrontCamera ? .mirror : .off
                )
                .frame(width: insetWidth, height: insetWidth * (16.0 / 9.0))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(.white.opacity(0.72), lineWidth: 0.7)
                        .allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(0.34), radius: 5, y: 2)
                .padding(7)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }

    private func compactStatus(
        for call: ActiveCallPresentation,
        at date: Date = Date()
    ) -> String {
        if screenSharing.phase.isActive { return "Sharing screen" }
        if media.hasRemoteParticipant {
            // The same anchor the full-screen header uses, so minimizing the call never
            // changes what the timer says.
            return CallDurationFormatter.string(
                from: coordinator.presentedCallDurationSeconds()
                    .map { date.addingTimeInterval(TimeInterval(-$0)) }
                    ?? media.remoteParticipantConnectedAt
                    ?? date,
                to: date
            )
        }
        if media.remoteParticipantConnectedAt != nil { return "Waiting to reconnect" }
        return call.direction == "outgoing" && !coordinator.presentedCallWasAnswered
            ? "Ringing"
            : "Connecting"
    }
}

/// Shared by the full-call header and the minimized surface so both render the same duration.
private enum CallDurationFormatter {
    static func string(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }
}

/// Voice-weighted wave inside the full-width call strip: bar heights follow the live audio
/// level and settle into a soft heart-pulse when the line is quiet. Static under Reduce Motion.
private struct CallBannerVoiceWave: View {
    let level: Float
    let isConnected: Bool
    let animated: Bool

    private static let barShape: [CGFloat] = [0.4, 0.7, 1.0, 0.72, 0.5, 0.86, 0.42]

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12, paused: !animated || !isConnected)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.6) {
                ForEach(Self.barShape.indices, id: \.self) { index in
                    Capsule()
                        .fill(KitColor.green.opacity(0.55 + 0.45 * Double(min(1, max(0, level)))))
                        .frame(width: 3, height: barHeight(index: index, phase: phase))
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func barHeight(index: Int, phase: TimeInterval) -> CGFloat {
        let base: CGFloat = 5
        guard isConnected else { return base }
        let shape = Self.barShape[index]
        if level > 0.02 {
            return base + shape * CGFloat(min(1, max(0, level))) * 15
        }
        guard animated else { return base + shape * 3 }
        let beat = pow(max(0, sin(phase * 2.2 + Double(index) * 0.7)), 6)
        return base + shape * CGFloat(beat) * 7
    }
}

/// Kit-branded voice pulse around the audio-call avatar: two outer rings breathe with the
/// remote voice level, one inner ring with the local level, and a gentle heartbeat idles when
/// the call is connected but silent. Static when not connected or when Reduce Motion is on.
private struct KitVoicePulseRings: View {
    let avatarSize: CGFloat
    let remoteLevel: Float
    let localLevel: Float
    let isConnected: Bool
    let reduceMotion: Bool

    @State private var idleBeat = false

    var body: some View {
        ZStack {
            ring(
                level: remoteLevel,
                diameter: avatarSize * 1.24,
                lineWidth: 1.2,
                baseOpacity: 0.20,
                levelBoost: 0.11
            )
            ring(
                level: remoteLevel,
                diameter: avatarSize * 1.13,
                lineWidth: 1.6,
                baseOpacity: 0.30,
                levelBoost: 0.06
            )
            ring(
                level: localLevel,
                diameter: avatarSize * 1.05,
                lineWidth: 1,
                baseOpacity: 0.16,
                levelBoost: 0.04
            )
        }
        .scaleEffect(heartbeatScale)
        .onAppear(perform: updateIdleBeat)
        .onChange(of: isConnected) { _, _ in updateIdleBeat() }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var heartbeatScale: CGFloat {
        guard isConnected, !reduceMotion else { return 1 }
        return idleBeat ? 1.015 : 0.995
    }

    private func ring(
        level: Float,
        diameter: CGFloat,
        lineWidth: CGFloat,
        baseOpacity: Double,
        levelBoost: CGFloat
    ) -> some View {
        let clamped = Double(min(max(level, 0), 1))
        let opacity = isConnected ? baseOpacity + clamped * 0.26 : baseOpacity * 0.55
        let scale = isConnected && !reduceMotion ? 1 + CGFloat(clamped) * levelBoost : 1
        return Circle()
            .stroke(KitColor.green.opacity(opacity), lineWidth: lineWidth)
            .frame(width: diameter, height: diameter)
            .scaleEffect(scale)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: clamped)
    }

    private func updateIdleBeat() {
        guard isConnected, !reduceMotion else {
            idleBeat = false
            return
        }
        guard !idleBeat else { return }
        withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
            idleBeat = true
        }
    }
}

private extension CallFloatingInsets {
    init(_ insets: EdgeInsets) {
        self.init(
            top: insets.top,
            leading: insets.leading,
            bottom: insets.bottom,
            trailing: insets.trailing
        )
    }
}

private struct DraggableLocalVideoPreview: View {
    let track: VideoTrack
    let isFrontCamera: Bool
    let canSwitchCamera: Bool
    let controlsAreVisible: Bool
    let activeHeaderClearance: CGFloat
    let activeControlsClearance: CGFloat
    @Binding var corner: CallFloatingCorner
    @Binding var isDragging: Bool
    let onTap: () -> Void
    let switchCamera: () async -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragTranslation: CGSize = .zero
    @State private var isLifted = false
    @State private var settleGeneration: UInt64 = 0
    @State private var isSwitchingCamera = false

    var body: some View {
        GeometryReader { geometry in
            let insets = CallFloatingInsets(geometry.safeAreaInsets)
            let topClearance = controlsAreVisible
                ? activeHeaderClearance
                : 0
            let bottomClearance = controlsAreVisible
                ? activeControlsClearance
                : 0
            let surfaceSize = CallFloatingSurfaceLayoutPolicy.localPreviewSize(
                container: geometry.size,
                insets: insets,
                topClearance: activeHeaderClearance,
                bottomClearance: activeControlsClearance,
                controlsAreVisible: controlsAreVisible
            )
            let restingOrigin = CallFloatingSurfaceLayoutPolicy.origin(
                for: corner,
                surfaceSize: surfaceSize,
                container: geometry.size,
                insets: insets,
                topClearance: topClearance,
                bottomClearance: bottomClearance
            )
            let displayedOrigin = CallFloatingSurfaceLayoutPolicy.rubberBandedOrigin(
                CGPoint(
                    x: restingOrigin.x + dragTranslation.width,
                    y: restingOrigin.y + dragTranslation.height
                ),
                surfaceSize: surfaceSize,
                container: geometry.size,
                insets: insets,
                topClearance: topClearance,
                bottomClearance: bottomClearance
            )

            ZStack(alignment: .topTrailing) {
                SwiftUIVideoView(
                    track,
                    layoutMode: .fill,
                    mirrorMode: isFrontCamera ? .mirror : .off
                )

                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onTap)
                    .accessibilityHidden(true)

                if controlsAreVisible {
                    VStack(spacing: CallFloatingSurfaceLayoutPolicy.previewControlsSpacing) {
                        previewControl(
                            icon: "camera.rotate.fill",
                            label: "Switch camera",
                            enabled: canSwitchCamera && !isSwitchingCamera
                        ) {
                            isSwitchingCamera = true
                            await switchCamera()
                            isSwitchingCamera = false
                        }

                        previewControl(
                            icon: "wand.and.stars",
                            label: "Video effects unavailable",
                            enabled: false,
                            action: {}
                        )
                    }
                    .padding(CallFloatingSurfaceLayoutPolicy.previewControlsPadding)
                    .transition(.opacity)
                }
            }
            .frame(width: surfaceSize.width, height: surfaceSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(.white.opacity(0.42), lineWidth: 0.9)
                    .allowsHitTesting(false)
            }
            .scaleEffect(isLifted && !reduceMotion ? 1.025 : 1)
            .shadow(
                color: .black.opacity(isLifted ? 0.46 : 0.38),
                radius: isLifted ? 21 : 16,
                y: isLifted ? 12 : 9
            )
            // The hit-test shape and the drag gesture must attach to the tile itself, BEFORE
            // `.position` expands the layout to the full screen. Applied after `.position`, the
            // content shape turned the entire call screen into this preview's hit region at
            // `zIndex(4)` — above the controls panel — so the moment the camera came on (an
            // audio→video escalation) every tap on Mute/Speaker/Video/More and on the
            // tap-to-reveal backdrop was silently swallowed.
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .simultaneousGesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .global)
                    .onChanged { value in
                        if !isLifted {
                            settleGeneration &+= 1
                            isDragging = true
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                                isLifted = true
                            }
                        }
                        dragTranslation = value.translation
                    }
                    .onEnded { value in
                        let proposed = CallFloatingSurfaceLayoutPolicy.projectedOrigin(
                            restingOrigin: restingOrigin,
                            translation: value.translation,
                            predictedEndTranslation: value.predictedEndTranslation
                        )
                        let nextCorner = CallFloatingSurfaceLayoutPolicy.nearestCorner(
                            to: proposed,
                            surfaceSize: surfaceSize,
                            container: geometry.size,
                            insets: insets,
                            topClearance: topClearance,
                            bottomClearance: bottomClearance
                        )
                        let rawReleaseOrigin = CGPoint(
                            x: restingOrigin.x + value.translation.width,
                            y: restingOrigin.y + value.translation.height
                        )
                        let targetOrigin = CallFloatingSurfaceLayoutPolicy.origin(
                            for: nextCorner,
                            surfaceSize: surfaceSize,
                            container: geometry.size,
                            insets: insets,
                            topClearance: topClearance,
                            bottomClearance: bottomClearance
                        )
                        let previousCorner = corner
                        var transaction = Transaction(animation: nil)
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            corner = nextCorner
                            dragTranslation = CGSize(
                                width: rawReleaseOrigin.x - targetOrigin.x,
                                height: rawReleaseOrigin.y - targetOrigin.y
                            )
                        }
                        if previousCorner != nextCorner {
                            UISelectionFeedbackGenerator().selectionChanged()
                        }
                        withAnimation(
                            reduceMotion ? nil : .spring(duration: 0.28, bounce: 0)
                        ) {
                            dragTranslation = .zero
                            isLifted = false
                        }
                        finishDragInteractionAfterSettle()
                    }
            )
            .position(
                x: displayedOrigin.x + surfaceSize.width / 2,
                y: displayedOrigin.y + surfaceSize.height / 2
            )
            .animation(
                reduceMotion ? nil : .spring(duration: 0.28, bounce: 0),
                value: controlsAreVisible
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Your camera preview")
            .accessibilityAdjustableAction { direction in
                moveAnchor(direction)
            }
            .onDisappear {
                settleGeneration &+= 1
                dragTranslation = .zero
                isLifted = false
                isDragging = false
            }
        }
    }

    private func finishDragInteractionAfterSettle() {
        settleGeneration &+= 1
        let generation = settleGeneration
        guard !reduceMotion else {
            isDragging = false
            return
        }
        Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(280))
            } catch {
                return
            }
            guard settleGeneration == generation, !isLifted else { return }
            isDragging = false
        }
    }

    private func moveAnchor(_ direction: AccessibilityAdjustmentDirection) {
        let anchors = CallFloatingCorner.allCases
        guard let index = anchors.firstIndex(of: corner) else { return }
        let delta: Int
        switch direction {
        case .increment: delta = 1
        case .decrement: delta = -1
        @unknown default: return
        }
        let next = anchors[(index + delta + anchors.count) % anchors.count]
        withAnimation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0)) {
            corner = next
            dragTranslation = .zero
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func previewControl(
        icon: String,
        label: String,
        enabled: Bool,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(
                    width: CallFloatingSurfaceLayoutPolicy.previewControlDimension,
                    height: CallFloatingSurfaceLayoutPolicy.previewControlDimension
                )
                .background(.black.opacity(0.52), in: Circle())
                .overlay {
                    Circle()
                        .stroke(.white.opacity(0.18), lineWidth: 0.7)
                        .allowsHitTesting(false)
                }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.44)
        .accessibilityLabel(label)
        .accessibilityValue(enabled ? "" : "Unavailable")
    }
}

/// A participant's photo over the call's dark backdrop, where a full-strength white ring would
/// glare, so the outline is dialled down to a hairline.
private struct CallParticipantAvatarView: View {
    let name: String
    let avatarURL: String?
    let size: CGFloat

    var body: some View {
        RemoteAvatarView(
            name: name,
            avatarURL: avatarURL,
            size: size,
            ringOpacity: 0.22
        )
    }
}

private struct MoreCallControlsOverlay: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    let selectedMode: KitMicrophoneMode
    let screenSharingPhase: CallScreenSharingPhase
    let canStartScreenSharing: Bool
    let shareScreen: () -> Void
    let stopScreenSharing: () -> Void
    let selectMode: (KitMicrophoneMode) -> Void
    let dismiss: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let maximumPanelHeight = min(620, max(180, geometry.size.height - 36))
            ZStack(alignment: .bottom) {
                Color.black
                    .opacity(colorScheme == .dark ? 0.22 : 0.08)
                    .background {
                        if !reduceTransparency {
                            Rectangle()
                                .fill(.ultraThinMaterial)
                                .opacity(0.34)
                        }
                    }
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: dismiss)

                ViewThatFits(in: .vertical) {
                    microphoneModeContent
                        .fixedSize(horizontal: false, vertical: true)

                    ScrollView {
                        microphoneModeContent
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
                .frame(maxHeight: maximumPanelHeight)
                .kitGlass(cornerRadius: 30)
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            }
        }
    }

    private var microphoneModeContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(.thinMaterial, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mic Mode")
                        .font(.headline)
                    Text(selectedMode.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.bold())
                        .frame(width: 44, height: 44)
                        .background(.thinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close microphone modes")
            }

            Button(action: screenSharingPhase == .idle ? shareScreen : stopScreenSharing) {
                Label(screenSharingPhase == .idle ? "Share screen" : "Stop screen sharing",
                      systemImage: "rectangle.on.rectangle")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(screenSharingPhase == .idle ? !canStartScreenSharing : !screenSharingPhase.canStop)
            .accessibilityIdentifier("call.screen-sharing.control")
            Divider()

            ForEach(KitMicrophoneMode.allCases) { mode in
                Button {
                    selectMode(mode)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: mode.symbolName)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(
                                mode == selectedMode ? KitColor.green : Color.primary
                            )
                            .frame(width: 44, height: 44)
                            .background(.thinMaterial, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.title)
                                .font(.subheadline.bold())
                            Text(mode.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 8)
                        if mode == selectedMode {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(KitColor.green)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(mode == selectedMode ? "Selected" : "")
            }

            Text("Changes Kit Pay call processing. Apple’s system Mic Mode remains available in Control Center.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LiquidCallBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    let name: String
    let avatarURL: String?

    /// Shares `ProfileAvatarCache` with the avatar in the foreground, so the backdrop costs no
    /// second download and is already there when a call starts with no network.
    @State private var backdropImage: UIImage?

    private var accent: Color {
        let scalarTotal = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return Color(
            hue: Double(scalarTotal % 360) / 360,
            saturation: colorScheme == .dark ? 0.52 : 0.34,
            brightness: colorScheme == .dark ? 0.44 : 0.92
        )
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color(white: 0.06), accent.opacity(0.58), Color(white: 0.12)]
                    : [Color(white: 0.98), accent.opacity(0.72), Color(white: 0.91)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if !reduceTransparency, let backdropImage {
                // Through ``KitFillingBackdrop``, never placed in the stack directly: a photo
                // asked to fill reports a size wider than the screen, and this stack would hand
                // that size to the whole call screen.
                KitFillingBackdrop {
                    Image(uiImage: backdropImage)
                        .resizable()
                        .scaledToFill()
                        .saturation(0.88)
                        .blur(radius: 36)
                        .scaleEffect(1.24)
                }
            }

            if !reduceTransparency {
                Rectangle()
                    .fill(.ultraThinMaterial)
                Circle()
                    .fill(.white.opacity(colorScheme == .dark ? 0.11 : 0.34))
                    .frame(width: 310, height: 310)
                    .blur(radius: 28)
                    .offset(x: -150, y: -250)
                Circle()
                    .fill(accent.opacity(colorScheme == .dark ? 0.25 : 0.18))
                    .frame(width: 360, height: 360)
                    .blur(radius: 42)
                    .offset(x: 170, y: 270)
            }

            LinearGradient(
                colors: colorScheme == .dark
                    ? [.black.opacity(0.28), .clear, .black.opacity(0.24)]
                    : [.white.opacity(0.24), .clear, .white.opacity(0.18)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .clipped()
        .task(id: avatarURL) {
            backdropImage = ProfileAvatarCache.cachedImage(for: avatarURL)
            guard backdropImage == nil, let avatarURL else { return }
            let loaded = await ProfileAvatarCache.shared.image(for: avatarURL)
            guard !Task.isCancelled else { return }
            backdropImage = loaded
        }
    }
}
