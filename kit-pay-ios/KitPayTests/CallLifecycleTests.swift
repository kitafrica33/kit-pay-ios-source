import AVFoundation
import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import KitPay

final class CallLifecycleTests: XCTestCase {
    func testForegroundIntentStopsPictureInPictureThatFinishesStartingLate() {
        var intent = CallPictureInPictureLifecycleIntent()

        intent.willStartForBackgrounding()
        XCTAssertFalse(intent.foregroundStopRequested(isPictureInPictureActive: false))
        XCTAssertTrue(intent.shouldStopAfterStart)
        XCTAssertTrue(intent.didStart())
        XCTAssertFalse(intent.shouldStopAfterStart)

        intent.willStartForBackgrounding()
        XCTAssertTrue(intent.foregroundStopRequested(isPictureInPictureActive: true))
        XCTAssertFalse(intent.shouldStopAfterStart)
        XCTAssertFalse(intent.didStart())
    }

    func testMinimizedCallControlsMeetAppleMinimumHitTarget() {
        XCTAssertGreaterThanOrEqual(
            CallFloatingSurfaceLayoutPolicy.minimizedControlDimension,
            44
        )
    }

    func testLandscapeIsAvailableOnlyWhileFullScreenCallInterfaceIsPresented() {
        XCTAssertEqual(
            CallInterfaceOrientationPolicy.mask(isActiveCallPresented: false),
            .portrait
        )

        let activeCallMask = CallInterfaceOrientationPolicy.mask(
            isActiveCallPresented: true
        )
        XCTAssertTrue(activeCallMask.contains(.portrait))
        XCTAssertTrue(activeCallMask.contains(.landscapeLeft))
        XCTAssertTrue(activeCallMask.contains(.landscapeRight))
        XCTAssertFalse(activeCallMask.contains(.portraitUpsideDown))
    }

    func testFloatingVideoSurfaceSnapsInsideSafeAreaAndAboveRootMenu() {
        let container = CGSize(width: 390, height: 844)
        let insets = CallFloatingInsets(top: 47, leading: 0, bottom: 34, trailing: 0)
        let size = CallFloatingSurfaceLayoutPolicy.minimizedSurfaceSize(
            container: container,
            isVideo: true
        )
        let origin = CallFloatingSurfaceLayoutPolicy.origin(
            for: .bottomTrailing,
            surfaceSize: size,
            container: container,
            insets: insets,
            bottomClearance: CallFloatingSurfaceLayoutPolicy.rootMenuClearance
        )

        XCTAssertGreaterThanOrEqual(origin.x, CallFloatingSurfaceLayoutPolicy.outerMargin)
        XCTAssertGreaterThanOrEqual(origin.y, insets.top + CallFloatingSurfaceLayoutPolicy.outerMargin)
        XCTAssertLessThanOrEqual(
            origin.x + size.width,
            container.width - CallFloatingSurfaceLayoutPolicy.outerMargin
        )
        XCTAssertLessThanOrEqual(
            origin.y + size.height,
            container.height
                - insets.bottom
                - CallFloatingSurfaceLayoutPolicy.outerMargin
                - CallFloatingSurfaceLayoutPolicy.rootMenuClearance
        )

        let clamped = CallFloatingSurfaceLayoutPolicy.clampedOrigin(
            CGPoint(x: 10_000, y: -10_000),
            surfaceSize: size,
            container: container,
            insets: insets,
            bottomClearance: CallFloatingSurfaceLayoutPolicy.rootMenuClearance
        )
        XCTAssertEqual(
            CallFloatingSurfaceLayoutPolicy.nearestCorner(
                to: clamped,
                surfaceSize: size,
                container: container,
                insets: insets,
                bottomClearance: CallFloatingSurfaceLayoutPolicy.rootMenuClearance
            ),
            .topTrailing
        )
    }

    func testFloatingCallSurfacesRemainUsableOnCompactWidths() {
        let container = CGSize(width: 104, height: 320)
        let videoSize = CallFloatingSurfaceLayoutPolicy.minimizedSurfaceSize(
            container: container,
            isVideo: true
        )
        let previewSize = CallFloatingSurfaceLayoutPolicy.localPreviewSize(container: container)

        XCTAssertLessThanOrEqual(
            videoSize.width,
            container.width - (CallFloatingSurfaceLayoutPolicy.outerMargin * 2)
        )
        XCTAssertLessThanOrEqual(
            previewSize.width,
            container.width - (CallFloatingSurfaceLayoutPolicy.outerMargin * 2)
        )
        XCTAssertGreaterThanOrEqual(videoSize.width, 72)
        XCTAssertGreaterThanOrEqual(previewSize.width, 72)
    }

    func testVisibleControlsDoNotResizeOrJumpLocalPreview() {
        let container = CGSize(width: 390, height: 844)
        let compact = CallFloatingSurfaceLayoutPolicy.localPreviewSize(container: container)
        let expanded = CallFloatingSurfaceLayoutPolicy.localPreviewSize(
            container: container,
            controlsAreVisible: true
        )

        XCTAssertEqual(expanded, compact)
        XCTAssertEqual(
            expanded.height / expanded.width,
            CallFloatingSurfaceLayoutPolicy.localPreviewHeightToWidth,
            accuracy: 0.001
        )
        XCTAssertLessThanOrEqual(expanded.width, 148)
    }

    func testCompactLandscapePreviewFitsBothAccessibleControls() {
        let container = CGSize(width: 844, height: 320)
        let insets = CallFloatingInsets(top: 0, leading: 47, bottom: 21, trailing: 47)
        let topClearance = CallFloatingSurfaceLayoutPolicy.resolvedActiveCallHeaderClearance(
            container: container
        )
        let bottomClearance = CallFloatingSurfaceLayoutPolicy.resolvedActiveCallControlsClearance(
            container: container
        )
        let size = CallFloatingSurfaceLayoutPolicy.localPreviewSize(
            container: container,
            insets: insets,
            topClearance: topClearance,
            bottomClearance: bottomClearance,
            controlsAreVisible: true
        )

        XCTAssertGreaterThanOrEqual(
            size.height,
            CallFloatingSurfaceLayoutPolicy.previewControlsRequiredHeight
        )
        XCTAssertGreaterThanOrEqual(
            size.width,
            CallFloatingSurfaceLayoutPolicy.previewControlDimension
                + (CallFloatingSurfaceLayoutPolicy.previewControlsPadding * 2)
        )
        XCTAssertEqual(
            CallFloatingSurfaceLayoutPolicy.activeCallHorizontalPadding(
                safeAreaInset: insets.leading
            ),
            insets.leading + CallFloatingSurfaceLayoutPolicy.outerMargin
        )
        let avatarSize = CallFloatingSurfaceLayoutPolicy.activeCallAvatarSize(
            container: container
        )
        XCTAssertLessThanOrEqual(avatarSize, 96)
        XCTAssertGreaterThanOrEqual(
            (container.height - avatarSize) / 2,
            insets.top + CallFloatingSurfaceLayoutPolicy.outerMargin + topClearance
        )
        XCTAssertLessThanOrEqual(
            (container.height + avatarSize) / 2,
            container.height
                - insets.bottom
                - CallFloatingSurfaceLayoutPolicy.outerMargin
                - bottomClearance
        )

        for corner in CallFloatingCorner.allCases {
            let origin = CallFloatingSurfaceLayoutPolicy.origin(
                for: corner,
                surfaceSize: size,
                container: container,
                insets: insets,
                topClearance: topClearance,
                bottomClearance: bottomClearance
            )
            XCTAssertGreaterThanOrEqual(
                origin.y,
                insets.top + CallFloatingSurfaceLayoutPolicy.outerMargin + topClearance
            )
            XCTAssertLessThanOrEqual(
                origin.y + size.height,
                container.height
                    - insets.bottom
                    - CallFloatingSurfaceLayoutPolicy.outerMargin
                    - bottomClearance
            )
        }
    }

    func testLocalPreviewAnchorsAvoidDynamicIslandHeaderAndCallControlsAcrossLayouts() {
        let layouts: [(CGSize, CallFloatingInsets)] = [
            (CGSize(width: 390, height: 844), .init(top: 47, leading: 0, bottom: 34, trailing: 0)),
            (CGSize(width: 430, height: 932), .init(top: 59, leading: 0, bottom: 34, trailing: 0)),
            (CGSize(width: 844, height: 390), .init(top: 0, leading: 47, bottom: 21, trailing: 47)),
        ]

        for (container, insets) in layouts {
            let topClearance = CallFloatingSurfaceLayoutPolicy.resolvedActiveCallHeaderClearance(
                container: container
            )
            let bottomClearance = CallFloatingSurfaceLayoutPolicy.resolvedActiveCallControlsClearance(
                container: container
            )
            let size = CallFloatingSurfaceLayoutPolicy.localPreviewSize(
                container: container,
                insets: insets,
                topClearance: topClearance,
                bottomClearance: bottomClearance
            )
            for anchor in CallFloatingCorner.allCases {
                let origin = CallFloatingSurfaceLayoutPolicy.origin(
                    for: anchor,
                    surfaceSize: size,
                    container: container,
                    insets: insets,
                    topClearance: topClearance,
                    bottomClearance: bottomClearance
                )
                XCTAssertGreaterThanOrEqual(
                    origin.y,
                    insets.top
                        + CallFloatingSurfaceLayoutPolicy.outerMargin
                        + topClearance
                )
                XCTAssertLessThanOrEqual(
                    origin.y + size.height,
                    container.height
                        - insets.bottom
                        - CallFloatingSurfaceLayoutPolicy.outerMargin
                        - bottomClearance
                )
                XCTAssertGreaterThanOrEqual(
                    origin.x,
                    insets.leading + CallFloatingSurfaceLayoutPolicy.outerMargin
                )
                XCTAssertLessThanOrEqual(
                    origin.x + size.width,
                    container.width - insets.trailing - CallFloatingSurfaceLayoutPolicy.outerMargin
                )
            }
        }
    }

    func testFloatingPreviewRubberBandsDuringDragAndClampsOnRelease() {
        let container = CGSize(width: 390, height: 844)
        let insets = CallFloatingInsets(top: 47, leading: 0, bottom: 34, trailing: 0)
        let size = CallFloatingSurfaceLayoutPolicy.localPreviewSize(
            container: container,
            insets: insets,
            topClearance: CallFloatingSurfaceLayoutPolicy.activeCallHeaderClearance,
            bottomClearance: CallFloatingSurfaceLayoutPolicy.activeCallControlsClearance
        )
        let legal = CallFloatingSurfaceLayoutPolicy.origin(
            for: .topLeading,
            surfaceSize: size,
            container: container,
            insets: insets,
            topClearance: CallFloatingSurfaceLayoutPolicy.activeCallHeaderClearance,
            bottomClearance: CallFloatingSurfaceLayoutPolicy.activeCallControlsClearance
        )
        let proposed = CGPoint(x: legal.x - 160, y: legal.y - 160)
        let rubberBanded = CallFloatingSurfaceLayoutPolicy.rubberBandedOrigin(
            proposed,
            surfaceSize: size,
            container: container,
            insets: insets,
            topClearance: CallFloatingSurfaceLayoutPolicy.activeCallHeaderClearance,
            bottomClearance: CallFloatingSurfaceLayoutPolicy.activeCallControlsClearance
        )
        let clamped = CallFloatingSurfaceLayoutPolicy.clampedOrigin(
            proposed,
            surfaceSize: size,
            container: container,
            insets: insets,
            topClearance: CallFloatingSurfaceLayoutPolicy.activeCallHeaderClearance,
            bottomClearance: CallFloatingSurfaceLayoutPolicy.activeCallControlsClearance
        )

        XCTAssertLessThan(rubberBanded.x, legal.x)
        XCTAssertGreaterThan(rubberBanded.x, proposed.x)
        XCTAssertLessThan(rubberBanded.y, legal.y)
        XCTAssertGreaterThan(rubberBanded.y, proposed.y)
        XCTAssertEqual(clamped, legal)
    }

    func testProjectedVelocityIsCappedAndCanSelectAStableEdgeAnchor() {
        let resting = CGPoint(x: 20, y: 300)
        let projected = CallFloatingSurfaceLayoutPolicy.projectedOrigin(
            restingOrigin: resting,
            translation: CGSize(width: 20, height: 0),
            predictedEndTranslation: CGSize(width: 2_000, height: 0)
        )
        XCTAssertEqual(projected.x, 260, accuracy: 0.001)
        XCTAssertEqual(projected.y, 300, accuracy: 0.001)

        let container = CGSize(width: 390, height: 844)
        let insets = CallFloatingInsets(top: 47, leading: 0, bottom: 34, trailing: 0)
        let size = CallFloatingSurfaceLayoutPolicy.localPreviewSize(
            container: container,
            insets: insets,
            topClearance: CallFloatingSurfaceLayoutPolicy.activeCallHeaderClearance,
            bottomClearance: CallFloatingSurfaceLayoutPolicy.activeCallControlsClearance
        )
        let anchor = CallFloatingSurfaceLayoutPolicy.nearestCorner(
            to: CGPoint(x: 1_000, y: container.height / 2),
            surfaceSize: size,
            container: container,
            insets: insets,
            topClearance: CallFloatingSurfaceLayoutPolicy.activeCallHeaderClearance,
            bottomClearance: CallFloatingSurfaceLayoutPolicy.activeCallControlsClearance
        )
        XCTAssertEqual(anchor, .trailingCenter)
    }

    func testEquidistantOrCollapsedFloatingAnchorsResolveDeterministically() {
        let container = CGSize(width: 80, height: 80)
        let oversizedSurface = CGSize(width: 120, height: 120)
        let first = CallFloatingSurfaceLayoutPolicy.nearestCorner(
            to: CGPoint(x: 40, y: 40),
            surfaceSize: oversizedSurface,
            container: container,
            insets: .zero
        )

        XCTAssertEqual(first, .topLeading)
        for _ in 0 ..< 20 {
            XCTAssertEqual(
                CallFloatingSurfaceLayoutPolicy.nearestCorner(
                    to: CGPoint(x: 40, y: 40),
                    surfaceSize: oversizedSurface,
                    container: container,
                    insets: .zero
                ),
                first
            )
        }
    }

    func testReleaseOffsetPreservesTheLastDraggedFrameBeforeSnap() {
        let container = CGSize(width: 390, height: 844)
        let insets = CallFloatingInsets(top: 47, leading: 0, bottom: 34, trailing: 0)
        let size = CallFloatingSurfaceLayoutPolicy.localPreviewSize(
            container: container,
            insets: insets,
            topClearance: CallFloatingSurfaceLayoutPolicy.activeCallHeaderClearance,
            bottomClearance: CallFloatingSurfaceLayoutPolicy.activeCallControlsClearance
        )
        let resting = CallFloatingSurfaceLayoutPolicy.origin(
            for: .bottomTrailing,
            surfaceSize: size,
            container: container,
            insets: insets,
            topClearance: CallFloatingSurfaceLayoutPolicy.activeCallHeaderClearance,
            bottomClearance: CallFloatingSurfaceLayoutPolicy.activeCallControlsClearance
        )
        let translation = CGSize(width: -420, height: -510)
        let rawRelease = CGPoint(
            x: resting.x + translation.width,
            y: resting.y + translation.height
        )
        let current = CallFloatingSurfaceLayoutPolicy.rubberBandedOrigin(
            rawRelease,
            surfaceSize: size,
            container: container,
            insets: insets,
            topClearance: CallFloatingSurfaceLayoutPolicy.activeCallHeaderClearance,
            bottomClearance: CallFloatingSurfaceLayoutPolicy.activeCallControlsClearance
        )
        let next = CallFloatingSurfaceLayoutPolicy.nearestCorner(
            to: current,
            surfaceSize: size,
            container: container,
            insets: insets,
            topClearance: CallFloatingSurfaceLayoutPolicy.activeCallHeaderClearance,
            bottomClearance: CallFloatingSurfaceLayoutPolicy.activeCallControlsClearance
        )
        let target = CallFloatingSurfaceLayoutPolicy.origin(
            for: next,
            surfaceSize: size,
            container: container,
            insets: insets,
            topClearance: CallFloatingSurfaceLayoutPolicy.activeCallHeaderClearance,
            bottomClearance: CallFloatingSurfaceLayoutPolicy.activeCallControlsClearance
        )
        let releaseOffset = CGSize(
            width: rawRelease.x - target.x,
            height: rawRelease.y - target.y
        )
        let reconstructedDisplay = CallFloatingSurfaceLayoutPolicy.rubberBandedOrigin(
            CGPoint(
                x: target.x + releaseOffset.width,
                y: target.y + releaseOffset.height
            ),
            surfaceSize: size,
            container: container,
            insets: insets,
            topClearance: CallFloatingSurfaceLayoutPolicy.activeCallHeaderClearance,
            bottomClearance: CallFloatingSurfaceLayoutPolicy.activeCallControlsClearance
        )

        XCTAssertEqual(reconstructedDisplay.x, current.x, accuracy: 0.001)
        XCTAssertEqual(reconstructedDisplay.y, current.y, accuracy: 0.001)
    }

    func testRemoteVideoVisibilityRejectsMutedOrMissingTracks() {
        XCTAssertTrue(
            RemoteVideoTrackVisibilityPolicy.shouldRender(
                isVideo: true,
                isMuted: false,
                hasRenderableTrack: true
            )
        )
        XCTAssertFalse(
            RemoteVideoTrackVisibilityPolicy.shouldRender(
                isVideo: true,
                isMuted: true,
                hasRenderableTrack: true
            )
        )
        XCTAssertFalse(
            RemoteVideoTrackVisibilityPolicy.shouldRender(
                isVideo: true,
                isMuted: false,
                hasRenderableTrack: false
            )
        )
    }

    func testRemoteParticipantOrderingIsDeterministicAcrossInputPermutations() {
        let candidates = [
            LiveKitRemoteParticipantCandidate(identity: " bravo:device-b ", stableID: "bravo:device-b"),
            LiveKitRemoteParticipantCandidate(identity: "Alpha:device-z", stableID: "Alpha:device-z"),
            LiveKitRemoteParticipantCandidate(identity: "alpha:device-a", stableID: "alpha:device-a"),
            LiveKitRemoteParticipantCandidate(identity: "", stableID: "sid:participant-c"),
        ]
        let expected = [
            "alpha:device-a",
            "Alpha:device-z",
            "bravo:device-b",
            "sid:participant-c",
        ]
        let permutations = [
            candidates,
            Array(candidates.reversed()),
            [candidates[2], candidates[0], candidates[3], candidates[1]],
        ]

        for permutation in permutations {
            XCTAssertEqual(
                LiveKitRemoteParticipantPolicy.orderedParticipants(permutation).map(\.stableID),
                expected
            )
        }
        XCTAssertEqual(
            LiveKitRemoteParticipantPolicy.stableID(
                identity: " user:device ",
                participantSID: "participant-sid"
            ),
            "user:device"
        )
        XCTAssertEqual(
            LiveKitRemoteParticipantPolicy.stableID(identity: "", participantSID: " p-1 "),
            "sid:p-1"
        )
        XCTAssertNil(LiveKitRemoteParticipantPolicy.stableID(identity: "", participantSID: nil))
    }

    func testRemoteVideoSelectionPrioritizesScreenShareAndStablePublicationID() {
        let candidates = [
            LiveKitRemoteVideoCandidate(
                publicationID: "camera-z",
                source: .camera,
                isRenderable: true
            ),
            LiveKitRemoteVideoCandidate(
                publicationID: "other-a",
                source: .other,
                isRenderable: true
            ),
            LiveKitRemoteVideoCandidate(
                publicationID: "screen-b",
                source: .screenShare,
                isRenderable: true
            ),
            LiveKitRemoteVideoCandidate(
                publicationID: "camera-a",
                source: .camera,
                isRenderable: true
            ),
            LiveKitRemoteVideoCandidate(
                publicationID: "screen-muted",
                source: .screenShare,
                isRenderable: false
            ),
        ]
        let expectedIDs = ["screen-b", "camera-a", "camera-z", "other-a"]

        XCTAssertEqual(
            LiveKitRemoteParticipantPolicy
                .orderedRenderableVideoCandidates(candidates)
                .map(\.publicationID),
            expectedIDs
        )
        XCTAssertEqual(
            LiveKitRemoteParticipantPolicy
                .orderedRenderableVideoCandidates(Array(candidates.reversed()))
                .map(\.publicationID),
            expectedIDs
        )
    }

    func testGroupGridSelectionUsesBackendRosterOrMultipleLiveRemotes() {
        XCTAssertFalse(
            ActiveCallParticipantGridPolicy.shouldUseGrid(
                isVideoPresentation: true,
                backendParticipantCount: 2,
                remoteParticipantCount: 1
            )
        )
        XCTAssertTrue(
            ActiveCallParticipantGridPolicy.shouldUseGrid(
                isVideoPresentation: true,
                backendParticipantCount: 3,
                remoteParticipantCount: 1
            )
        )
        XCTAssertTrue(
            ActiveCallParticipantGridPolicy.shouldUseGrid(
                isVideoPresentation: true,
                backendParticipantCount: 0,
                remoteParticipantCount: 2
            )
        )
        XCTAssertFalse(
            ActiveCallParticipantGridPolicy.shouldUseGrid(
                isVideoPresentation: true,
                backendParticipantCount: 0,
                remoteParticipantCount: 1
            )
        )
        XCTAssertFalse(
            ActiveCallParticipantGridPolicy.shouldUseGrid(
                isVideoPresentation: false,
                backendParticipantCount: 4,
                remoteParticipantCount: 3
            )
        )
    }

    func testGroupGridColumnCountsRespondToParticipantCountAndOrientation() {
        let portrait = CGSize(width: 390, height: 620)
        let landscape = CGSize(width: 740, height: 250)

        XCTAssertEqual(
            (0 ... 8).map {
                ActiveCallParticipantGridPolicy.columnCount(
                    participantCount: $0,
                    availableSize: portrait
                )
            },
            [0, 1, 1, 2, 2, 2, 2, 3, 3]
        )
        XCTAssertEqual(
            (0 ... 8).map {
                ActiveCallParticipantGridPolicy.columnCount(
                    participantCount: $0,
                    availableSize: landscape
                )
            },
            [0, 1, 2, 2, 2, 3, 3, 3, 3]
        )
        XCTAssertEqual(
            ActiveCallParticipantGridPolicy.columnCount(
                participantCount: 4,
                availableSize: CGSize(width: 280, height: 700)
            ),
            1
        )

        let columns = ActiveCallParticipantGridPolicy.columnCount(
            participantCount: 6,
            availableSize: portrait
        )
        let tileHeight = ActiveCallParticipantGridPolicy.tileHeight(
            participantCount: 6,
            columnCount: columns,
            availableSize: portrait
        )
        let rows = 3
        XCTAssertGreaterThanOrEqual(
            tileHeight,
            ActiveCallParticipantGridPolicy.minimumTileHeight
        )
        XCTAssertLessThanOrEqual(
            tileHeight * CGFloat(rows)
                + ActiveCallParticipantGridPolicy.spacing * CGFloat(rows - 1),
            portrait.height + 0.001
        )
    }

    func testRoomParticipantPresentationUsesValidatedIdentityAndSafeNames() {
        let userID = "550e8400-e29b-41d4-a716-446655440000"

        XCTAssertEqual(
            RemoteCallParticipantPresentationPolicy.userID(
                fromLiveKitIdentity: "\(userID.uppercased()):server-device-id"
            ),
            userID
        )
        XCTAssertNil(
            RemoteCallParticipantPresentationPolicy.userID(
                fromLiveKitIdentity: "not-a-user:server-device-id"
            )
        )
        XCTAssertEqual(
            RemoteCallParticipantPresentationPolicy.displayName(
                contactName: "  Amina\u{0000} from contacts  ",
                serverName: "Registered Amina"
            ),
            "Amina from contacts"
        )
        XCTAssertEqual(
            RemoteCallParticipantPresentationPolicy.displayName(
                contactName: nil,
                serverName: userID
            ),
            RemoteCallParticipantPresentationPolicy.fallbackName
        )
        XCTAssertEqual(
            RemoteCallParticipantPresentationPolicy.displayName(
                contactName: nil,
                serverName: String(repeating: "n", count: 200)
            ).count,
            RemoteCallParticipantPresentationPolicy.maximumNameLength
        )
    }

    func testMediaReconnectPolicyMapsRemoteRetryableAndTerminalDisconnects() {
        XCTAssertEqual(
            CallMediaReconnectPolicy.action(for: .remoteEnded),
            .reportRemoteEnd
        )
        XCTAssertEqual(
            CallMediaReconnectPolicy.action(for: .retryable),
            .rejoin
        )
        XCTAssertEqual(
            CallMediaReconnectPolicy.action(for: .terminalFailure),
            .fail
        )
    }

    func testMediaReconnectPolicyHasExactBoundedAttemptSchedule() {
        XCTAssertEqual(
            CallMediaReconnectPolicy.retryDelaysNanoseconds,
            [0, 1_000_000_000, 3_000_000_000]
        )
        XCTAssertEqual(CallMediaReconnectPolicy.delayNanoseconds(forAttempt: 1), 0)
        XCTAssertEqual(
            CallMediaReconnectPolicy.delayNanoseconds(forAttempt: 2),
            1_000_000_000
        )
        XCTAssertEqual(
            CallMediaReconnectPolicy.delayNanoseconds(forAttempt: 3),
            3_000_000_000
        )
        XCTAssertNil(CallMediaReconnectPolicy.delayNanoseconds(forAttempt: -1))
        XCTAssertNil(CallMediaReconnectPolicy.delayNanoseconds(forAttempt: 0))
        XCTAssertNil(CallMediaReconnectPolicy.delayNanoseconds(forAttempt: 4))
        XCTAssertEqual(
            CallMediaReconnectPolicy.stableConnectionResetNanoseconds,
            30_000_000_000
        )
    }

    func testVideoControlsAutoHideOnlyForRenderableConnectedVideo() {
        XCTAssertTrue(
            CallControlsVisibilityPolicy.shouldAutoHide(
                isVideoCall: true,
                isConnected: true,
                hasVideoSurface: true,
                isAdditionalControlsPresented: false
            )
        )
        XCTAssertFalse(
            CallControlsVisibilityPolicy.shouldAutoHide(
                isVideoCall: false,
                isConnected: true,
                hasVideoSurface: true,
                isAdditionalControlsPresented: false
            )
        )
        XCTAssertFalse(
            CallControlsVisibilityPolicy.shouldAutoHide(
                isVideoCall: true,
                isConnected: true,
                hasVideoSurface: true,
                isAdditionalControlsPresented: true
            )
        )
        XCTAssertFalse(
            CallControlsVisibilityPolicy.shouldAutoHide(
                isVideoCall: true,
                isConnected: true,
                hasVideoSurface: true,
                isAdditionalControlsPresented: false,
                hasWaitingCall: true
            )
        )
        XCTAssertFalse(
            CallControlsVisibilityPolicy.shouldAutoHide(
                isVideoCall: true,
                isConnected: true,
                hasVideoSurface: true,
                isAdditionalControlsPresented: false,
                isFloatingSurfaceInteracting: true
            )
        )
        XCTAssertFalse(
            CallControlsVisibilityPolicy.shouldAutoHide(
                isVideoCall: true,
                isConnected: true,
                hasVideoSurface: true,
                isAdditionalControlsPresented: false,
                isAssistiveNavigationActive: true
            )
        )
        XCTAssertFalse(
            CallControlsVisibilityPolicy.shouldAutoHide(
                isVideoCall: true,
                isConnected: true,
                hasVideoSurface: true,
                isAdditionalControlsPresented: false,
                areControlsVisible: false
            )
        )
    }

    func testCallSurfaceTapRestoresHiddenControlsAndKeepsAudioControlsVisible() {
        XCTAssertTrue(
            CallControlsVisibilityPolicy.visibilityAfterSurfaceTap(
                isVideoCall: true,
                areControlsVisible: false
            )
        )
        XCTAssertTrue(
            CallControlsVisibilityPolicy.visibilityAfterSurfaceTap(
                isVideoCall: false,
                areControlsVisible: false
            )
        )
        XCTAssertTrue(
            CallControlsVisibilityPolicy.visibilityAfterSurfaceTap(
                isVideoCall: false,
                areControlsVisible: true
            )
        )
        XCTAssertFalse(
            CallControlsVisibilityPolicy.visibilityAfterSurfaceTap(
                isVideoCall: true,
                areControlsVisible: true
            )
        )
        XCTAssertTrue(
            CallControlsVisibilityPolicy.visibilityAfterSurfaceTap(
                isVideoCall: true,
                areControlsVisible: true,
                isAssistiveNavigationActive: true
            )
        )
        XCTAssertTrue(
            CallControlsVisibilityPolicy.visibilityAfterSurfaceTap(
                isVideoCall: true,
                areControlsVisible: true,
                hasWaitingCall: true
            )
        )
    }

    func testCallPresentationUpgradesToVideoForEitherLocalOrRemoteTrack() {
        XCTAssertFalse(
            ActiveCallVideoPresentationPolicy.isVideo(
                callWasVideo: false,
                localCameraEnabled: false,
                hasRemoteVideo: false
            )
        )
        XCTAssertTrue(
            ActiveCallVideoPresentationPolicy.isVideo(
                callWasVideo: false,
                localCameraEnabled: true,
                hasRemoteVideo: false
            )
        )
        XCTAssertTrue(
            ActiveCallVideoPresentationPolicy.isVideo(
                callWasVideo: false,
                localCameraEnabled: false,
                hasRemoteVideo: true
            )
        )
        XCTAssertTrue(
            ActiveCallVideoPresentationPolicy.isVideo(
                callWasVideo: true,
                localCameraEnabled: false,
                hasRemoteVideo: false
            )
        )
    }

    func testEphemeralOutgoingCallGateRetainsStableIdentityAcrossTransientRetries() {
        let attempt = ephemeralAttempt(
            clientCallID: "51000000-0000-4000-8000-000000000001"
        )
        var gate = EphemeralOutgoingCallAttemptGate()

        XCTAssertTrue(gate.begin(attempt))
        let first = gate.beginSubmission()
        XCTAssertNotNil(first)
        XCTAssertEqual(gate.finishRetryableFailure(first!), 1)
        XCTAssertEqual(gate.attempt?.clientCallID, attempt.clientCallID)

        let second = gate.beginSubmission()
        XCTAssertNotNil(second)
        XCTAssertEqual(second?.attempt.clientCallID, attempt.clientCallID)
        XCTAssertEqual(gate.finishRetryableFailure(second!), 2)
        XCTAssertEqual(
            EphemeralOutgoingCallRetryPolicy.delay(failureCount: 2, retryAfter: nil),
            2
        )
        XCTAssertEqual(
            EphemeralOutgoingCallRetryPolicy.delay(failureCount: 8, retryAfter: 45),
            45
        )
    }

    func testVisibleOfflineCallCanSubmitOnReconnectButCannotReplayAfterCancellation() {
        let attempt = ephemeralAttempt(
            clientCallID: "51000000-0000-4000-8000-000000000006"
        )
        var gate = EphemeralOutgoingCallAttemptGate()

        // Starting while offline creates only the visible process-local attempt. Reconnect owns
        // the first submission and must retain the same backend idempotency identity.
        XCTAssertTrue(gate.begin(attempt))
        XCTAssertEqual(gate.attempt, attempt)
        let reconnectSubmission = gate.beginSubmission()
        XCTAssertEqual(reconnectSubmission?.attempt.clientCallID, attempt.clientCallID)

        // Losing connectivity/backgrounding fences the suspended response. A later foreground
        // reconnect may retry this still-visible attempt, but cancelling it retires it forever.
        gate.suspendSubmission()
        let foregroundSubmission = gate.beginSubmission()
        XCTAssertEqual(foregroundSubmission?.attempt.clientCallID, attempt.clientCallID)
        XCTAssertEqual(gate.cancel(clientCallID: attempt.clientCallIDString), attempt)
        XCTAssertNil(gate.beginSubmission())
        XCTAssertNil(gate.attempt)
    }

    func testEphemeralOutgoingCallCancellationFencesLateAcceptanceAndNeverRestores() {
        let attempt = ephemeralAttempt(
            clientCallID: "51000000-0000-4000-8000-000000000002"
        )
        var gate = EphemeralOutgoingCallAttemptGate()
        XCTAssertTrue(gate.begin(attempt))
        let submission = gate.beginSubmission()
        XCTAssertNotNil(submission)

        XCTAssertEqual(
            gate.cancel(clientCallID: attempt.clientCallIDString),
            attempt
        )
        XCTAssertNil(gate.finishAccepted(submission!))
        XCTAssertNil(gate.attempt)
        XCTAssertNil(gate.beginSubmission())
    }

    func testFirstSuccessfulSubmissionWinsAcrossConnectivityReplacementRace() {
        let attempt = ephemeralAttempt(
            clientCallID: "51000000-0000-4000-8000-000000000005"
        )
        var gate = EphemeralOutgoingCallAttemptGate()
        XCTAssertTrue(gate.begin(attempt))
        let suspendedSubmission = gate.beginSubmission()
        XCTAssertNotNil(suspendedSubmission)

        gate.suspendSubmission()
        let replacementSubmission = gate.beginSubmission()
        XCTAssertNotNil(replacementSubmission)

        XCTAssertEqual(gate.finishCurrentAttemptAccepted(attempt), attempt)
        XCTAssertFalse(gate.accepts(replacementSubmission!))
        XCTAssertNil(gate.finishAccepted(replacementSubmission!))
        XCTAssertNil(gate.attempt)
    }

    func testEphemeralOutgoingCallRejectsOverlappingAttemptsAndWrongCancellationID() {
        let first = ephemeralAttempt(
            clientCallID: "51000000-0000-4000-8000-000000000003"
        )
        let second = ephemeralAttempt(
            clientCallID: "51000000-0000-4000-8000-000000000004"
        )
        var gate = EphemeralOutgoingCallAttemptGate()

        XCTAssertTrue(gate.begin(first))
        XCTAssertFalse(gate.begin(second))
        XCTAssertNil(gate.cancel(clientCallID: second.clientCallIDString))
        XCTAssertEqual(gate.attempt, first)
        XCTAssertEqual(gate.cancel(), first)
        XCTAssertNil(gate.attempt)
    }

    func testMicrophoneModesApplyDistinctLiveAudioProcessingProfiles() {
        let automatic = KitMicrophoneMode.automatic.audioProcessingOptions
        XCTAssertTrue(automatic.echoCancellation)
        XCTAssertTrue(automatic.noiseSuppression)

        let standard = KitMicrophoneMode.standard.audioProcessingOptions
        XCTAssertEqual(standard.noiseSuppressionMode, .software)
        XCTAssertFalse(standard.highpassFilter)

        let isolation = KitMicrophoneMode.voiceIsolation.audioProcessingOptions
        XCTAssertTrue(isolation.noiseSuppression)
        XCTAssertTrue(isolation.highpassFilter)

        let wideSpectrum = KitMicrophoneMode.wideSpectrum.audioProcessingOptions
        XCTAssertTrue(wideSpectrum.echoCancellation)
        XCTAssertFalse(wideSpectrum.noiseSuppression)
        XCTAssertFalse(wideSpectrum.autoGainControl)
    }

    @MainActor
    func testMediaSessionDriverUsesOneTransportAndIgnoresMismatchedEndRequests() async throws {
        let transport = FakeCallMediaTransport()
        let driver = CallMediaSessionDriver(transport: transport)
        let first = try mediaHandoff(
            id: "550e8400-e29b-41d4-a716-446655440030",
            direction: "outgoing"
        )
        let second = try mediaHandoff(
            id: "550e8400-e29b-41d4-a716-446655440031",
            direction: "incoming"
        )

        try await driver.connect(first)
        XCTAssertEqual(driver.activeCallId, first.callId)
        XCTAssertEqual(transport.connectedCallIds, [first.callId])

        await driver.disconnect(callId: second.callId)
        XCTAssertEqual(driver.activeCallId, first.callId)
        XCTAssertEqual(transport.disconnectCount, 0)

        try await driver.connect(second)
        XCTAssertEqual(driver.activeCallId, second.callId)
        XCTAssertEqual(transport.connectedCallIds, [first.callId, second.callId])
        XCTAssertEqual(transport.disconnectCount, 1)

        await driver.disconnect(callId: second.callId)
        XCTAssertNil(driver.activeCallId)
        XCTAssertEqual(transport.disconnectCount, 2)
    }

    @MainActor
    func testMediaSessionDriverRejoinsTheSameUnexpectedlyDisconnectedCall() async throws {
        let transport = FakeCallMediaTransport()
        let driver = CallMediaSessionDriver(transport: transport)
        let handoff = try mediaHandoff(
            id: "550e8400-e29b-41d4-a716-446655440033",
            direction: "outgoing"
        )

        try await driver.connect(handoff)
        driver.didDisconnect(callId: "550e8400-e29b-41d4-a716-446655440099")
        XCTAssertEqual(driver.activeCallId, handoff.callId)

        driver.didDisconnect(callId: handoff.callId.uppercased())
        XCTAssertNil(driver.activeCallId)

        try await driver.connect(handoff)
        XCTAssertEqual(driver.activeCallId, handoff.callId)
        XCTAssertEqual(transport.connectedCallIds, [handoff.callId, handoff.callId])
        XCTAssertEqual(transport.disconnectCount, 0)
    }

    @MainActor
    func testMediaSessionDriverCancelsAnInFlightConnectWhenCallEnds() async throws {
        let transport = SuspendingCallMediaTransport()
        let driver = CallMediaSessionDriver(transport: transport)
        let handoff = try mediaHandoff(
            id: "550e8400-e29b-41d4-a716-446655440032",
            direction: "outgoing"
        )

        let connectTask = Task { @MainActor in
            try await driver.connect(handoff)
        }
        await transport.waitUntilConnectStarts()
        await driver.disconnect(callId: handoff.callId)

        do {
            try await connectTask.value
            XCTFail("A locally ended call must not finish connecting")
        } catch is CancellationError {
            // Expected: ending CallKit invalidates the in-flight LiveKit connection.
        } catch {
            XCTFail("Unexpected connect error: \(error)")
        }
        XCTAssertNil(driver.activeCallId)
        XCTAssertEqual(transport.disconnectCount, 1)
    }

    @MainActor
    func testMediaSessionDriverAccountResetInvalidatesSuspendedConnectAndIdleTransport() async throws {
        let transport = SuspendingCallMediaTransport()
        let driver = CallMediaSessionDriver(transport: transport)
        let handoff = try mediaHandoff(
            id: "550e8400-e29b-41d4-a716-446655440034",
            direction: "incoming"
        )

        let connectTask = Task { @MainActor in
            try await driver.connect(handoff)
        }
        await transport.waitUntilConnectStarts()
        await driver.reset()

        do {
            try await connectTask.value
            XCTFail("An account reset must make a suspended media connection stale")
        } catch is CancellationError {
            // Expected: the reset generation dominates the transport's eventual completion.
        } catch {
            XCTFail("Unexpected connect error: \(error)")
        }
        XCTAssertNil(driver.activeCallId)
        XCTAssertEqual(transport.disconnectCount, 1)

        // Reset remains unconditional while idle so partially initialized SDK state is also closed.
        await driver.reset()
        XCTAssertEqual(transport.disconnectCount, 2)
    }

    @MainActor
    func testMediaSessionDriverResetPreventsConnectResumingAfterReplacementTeardown() async throws {
        let transport = SuspendingReplacementDisconnectCallMediaTransport()
        let driver = CallMediaSessionDriver(transport: transport)
        let first = try mediaHandoff(
            id: "550e8400-e29b-41d4-a716-446655440035",
            direction: "outgoing"
        )
        let replacement = try mediaHandoff(
            id: "550e8400-e29b-41d4-a716-446655440036",
            direction: "outgoing"
        )

        try await driver.connect(first)
        let replacementTask = Task { @MainActor in
            try await driver.connect(replacement)
        }
        await transport.waitUntilReplacementDisconnectStarts()
        await driver.reset()
        transport.resumeReplacementDisconnect()

        do {
            try await replacementTask.value
            XCTFail("A reset must fence a connect suspended while replacing an older call")
        } catch is CancellationError {
            // Expected: the reset generation wins before replacement transport setup starts.
        } catch {
            XCTFail("Unexpected connect error: \(error)")
        }
        XCTAssertNil(driver.activeCallId)
        XCTAssertEqual(transport.connectedCallIds, [first.callId])
        XCTAssertEqual(transport.disconnectCount, 2)
    }

    @MainActor
    func testStaleSuccessfulConnectCannotDisconnectReplacementAccountMedia() async throws {
        let staleCallID = "550e8400-e29b-41d4-a716-446655440037"
        let replacementCallID = "550e8400-e29b-41d4-a716-446655440038"
        let transport = OverlappingCallMediaTransport(suspendingCallID: staleCallID)
        let driver = CallMediaSessionDriver(transport: transport)
        let stale = try mediaHandoff(id: staleCallID, direction: "outgoing")
        let replacement = try mediaHandoff(id: replacementCallID, direction: "incoming")

        let staleTask = Task { @MainActor in
            try await driver.connect(stale)
        }
        await transport.waitUntilSuspendedConnectStarts()
        await driver.reset()
        try await driver.connect(replacement)
        transport.resumeSuspendedConnectSuccessfully()

        do {
            try await staleTask.value
            XCTFail("The revoked account's connection must remain stale")
        } catch is CancellationError {
            // Expected: the replacement call remains the sole driver owner.
        } catch {
            XCTFail("Unexpected connect error: \(error)")
        }
        XCTAssertEqual(driver.activeCallId, replacement.callId)
        XCTAssertEqual(transport.connectedCallIds, [stale.callId, replacement.callId])
        XCTAssertEqual(
            transport.disconnectCount,
            1,
            "A stale success must not tear down the replacement account's transport"
        )
    }

    func testMediaAccountLeaseGateRejectsReplacementUntilExplicitRevocation() {
        let first = CallMediaAccountLease(
            accountEpoch: UUID(uuidString: "550e8400-e29b-41d4-a716-446655440040")!,
            userID: "550E8400-E29B-41D4-A716-446655440041",
            sessionID: "session-a"
        )
        let replacement = CallMediaAccountLease(
            accountEpoch: UUID(uuidString: "550e8400-e29b-41d4-a716-446655440042")!,
            userID: "550e8400-e29b-41d4-a716-446655440043",
            sessionID: "session-b"
        )
        var gate = CallMediaAccountLeaseGate()

        XCTAssertTrue(gate.activate(first))
        XCTAssertEqual(first.userID, "550e8400-e29b-41d4-a716-446655440041")
        XCTAssertTrue(gate.accepts(first))
        XCTAssertFalse(gate.activate(replacement))
        XCTAssertFalse(gate.accepts(replacement))

        gate.revoke(replacement)
        XCTAssertTrue(gate.accepts(first), "A mismatched sign-out must not revoke the active account")
        gate.revoke(first)
        XCTAssertFalse(gate.accepts(first))
        XCTAssertTrue(gate.activate(replacement))
        XCTAssertTrue(gate.accepts(replacement))
    }

    func testPushTokenCacheReplaysEachCurrentAppleProviderAndDropsInvalidatedVoIPToken() {
        let cache = PushTokenCache()
        cache.store(PushTokenRegistration(provider: "apns_voip", token: "voip-old"))
        cache.store(PushTokenRegistration(provider: "apns", token: "alerts"))
        cache.store(PushTokenRegistration(provider: "apns_voip", token: "voip-current"))

        XCTAssertEqual(
            cache.registrations(),
            [
                PushTokenRegistration(provider: "apns", token: "alerts"),
                PushTokenRegistration(provider: "apns_voip", token: "voip-current"),
            ]
        )

        cache.remove(provider: "apns_voip")
        XCTAssertEqual(
            cache.registrations(),
            [PushTokenRegistration(provider: "apns", token: "alerts")]
        )
    }

    func testPendingCallEventCacheReplaysInOrderDeduplicatesAndAcknowledges() throws {
        let callId = "550e8400-e29b-41d4-a716-446655440000"
        let push = try XCTUnwrap(IncomingCallPush(payload: [
            "type": "call.ringing",
            "call_id": callId,
            "initiator_name": "Alice",
        ]))
        let verification = CallLifecycleEvent.verificationRequested(
            IncomingCallVerificationRequest(
                eventId: UUID(uuidString: "550e8400-e29b-41d4-a716-446655440009")!,
                push: push,
                admissionGeneration: 7
            )
        )
        let authenticatedCall = AuthenticatedIncomingCall(
            record: record(
                id: callId,
                state: .ringing,
                offset: 1,
                participantUserIds: ["550e8400-e29b-41d4-a716-446655440001"],
                direction: "incoming"
            ),
            callUUID: push.callUUID,
            ringExpiryDate: Date(timeIntervalSince1970: 100),
            initiatorUserID: nil
        )
        let incoming = CallLifecycleEvent.incoming(
            IncomingCallNotice(
                eventId: UUID(uuidString: "550e8400-e29b-41d4-a716-446655440010")!,
                call: authenticatedCall
            )
        )
        let answer = CallLifecycleEvent.systemAction(
            CallSystemAction(
                eventId: UUID(uuidString: "550e8400-e29b-41d4-a716-446655440011")!,
                callId: callId,
                callUUID: push.callUUID,
                kind: .answer
            )
        )
        let cache = PendingCallEventCache()

        cache.store(verification)
        cache.store(verification)
        cache.store(incoming)
        cache.store(incoming)
        cache.store(answer)
        XCTAssertEqual(cache.pendingEvents(), [verification, incoming, answer])

        cache.acknowledge(verification.id)
        cache.acknowledge(incoming.id)
        XCTAssertEqual(cache.pendingEvents(), [answer])
        cache.acknowledge(answer.id)
        XCTAssertTrue(cache.pendingEvents().isEmpty)
    }

    func testCallKitAnswerRoutesDifferentAuthenticatedCallToMergeOnlyDuringLiveMedia() {
        let activeCallID = "550e8400-e29b-41d4-a716-446655440000"
        let waitingCallID = "550e8400-e29b-41d4-a716-446655440001"

        for mediaState in [CallWaitingMediaState.connected, .reconnecting] {
            XCTAssertEqual(
                CallKitAnswerActionPolicy.disposition(
                    actionCallID: waitingCallID.uppercased(),
                    authenticatedIncomingCallID: waitingCallID,
                    activeCallID: activeCallID.uppercased(),
                    mediaState: mediaState
                ),
                .mergeWaiting
            )
            XCTAssertEqual(
                CallKitAnswerActionPolicy.disposition(
                    actionCallID: activeCallID,
                    authenticatedIncomingCallID: activeCallID,
                    activeCallID: activeCallID,
                    mediaState: mediaState
                ),
                .answerPrimary
            )
        }
    }

    func testCallKitAnswerPreservesPrimaryFlowAndRejectsContradictoryOwnership() {
        let activeCallID = "550e8400-e29b-41d4-a716-446655440000"
        let incomingCallID = "550e8400-e29b-41d4-a716-446655440001"

        for mediaState in [
            CallWaitingMediaState.idle,
            .preparing,
            .connecting,
            .ending,
        ] {
            XCTAssertEqual(
                CallKitAnswerActionPolicy.disposition(
                    actionCallID: incomingCallID,
                    authenticatedIncomingCallID: incomingCallID,
                    activeCallID: activeCallID,
                    mediaState: mediaState
                ),
                .answerPrimary
            )
        }
        XCTAssertEqual(
            CallKitAnswerActionPolicy.disposition(
                actionCallID: incomingCallID,
                authenticatedIncomingCallID: activeCallID,
                activeCallID: activeCallID,
                mediaState: .connected
            ),
            .reject
        )
        XCTAssertEqual(
            CallKitAnswerActionPolicy.disposition(
                actionCallID: incomingCallID,
                authenticatedIncomingCallID: incomingCallID,
                activeCallID: nil,
                mediaState: .connected
            ),
            .reject
        )
    }

    func testCallKitEndNeverInfersMergeWithoutAnEarlierExactAnswerIntent() {
        let activeCallUUID = UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!
        let otherCallUUID = UUID(uuidString: "550e8400-e29b-41d4-a716-446655440001")!

        XCTAssertFalse(
            CallKitActiveEndActionPolicy.preservesActiveCall(
                actionCallUUID: activeCallUUID,
                connectedActiveCallUUID: activeCallUUID,
                wasExplicitlyRequestedInApp: false,
                priorAnswerActiveCallUUIDs: []
            )
        )
        XCTAssertFalse(
            CallKitActiveEndActionPolicy.preservesActiveCall(
                actionCallUUID: activeCallUUID,
                connectedActiveCallUUID: activeCallUUID,
                wasExplicitlyRequestedInApp: false,
                priorAnswerActiveCallUUIDs: [otherCallUUID]
            )
        )
        XCTAssertFalse(
            CallKitActiveEndActionPolicy.preservesActiveCall(
                actionCallUUID: activeCallUUID,
                connectedActiveCallUUID: activeCallUUID,
                wasExplicitlyRequestedInApp: true,
                priorAnswerActiveCallUUIDs: [activeCallUUID]
            )
        )
    }

    func testCallKitEndPreservesOnlyOnePriorAnswerBoundToTheSameActiveCall() {
        let activeCallUUID = UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!
        let otherCallUUID = UUID(uuidString: "550e8400-e29b-41d4-a716-446655440001")!

        XCTAssertTrue(
            CallKitActiveEndActionPolicy.preservesActiveCall(
                actionCallUUID: activeCallUUID,
                connectedActiveCallUUID: activeCallUUID,
                wasExplicitlyRequestedInApp: false,
                priorAnswerActiveCallUUIDs: [activeCallUUID]
            )
        )
        XCTAssertFalse(
            CallKitActiveEndActionPolicy.preservesActiveCall(
                actionCallUUID: activeCallUUID,
                connectedActiveCallUUID: otherCallUUID,
                wasExplicitlyRequestedInApp: false,
                priorAnswerActiveCallUUIDs: [activeCallUUID]
            )
        )
        XCTAssertFalse(
            CallKitActiveEndActionPolicy.preservesActiveCall(
                actionCallUUID: activeCallUUID,
                connectedActiveCallUUID: activeCallUUID,
                wasExplicitlyRequestedInApp: false,
                priorAnswerActiveCallUUIDs: [activeCallUUID, activeCallUUID]
            )
        )
        XCTAssertTrue(
            CallKitActiveEndActionPolicy.preservesActiveCall(
                actionCallUUID: activeCallUUID,
                connectedActiveCallUUID: activeCallUUID,
                wasExplicitlyRequestedInApp: false,
                priorAnswerActiveCallUUIDs: [otherCallUUID, activeCallUUID]
            )
        )
    }

    func testIncomingPushAcceptsOnlyTheCallRingingContract() throws {
        let callId = "550e8400-e29b-41d4-a716-446655440000"
        let push = try XCTUnwrap(
            IncomingCallPush(payload: [
                "type": "call.ringing",
                "call_id": callId.uppercased(),
                "initiator_name": "  Alice\nExample  ",
                "initiator_user_id": "550e8400-e29b-41d4-a716-446655440001",
                "call_type": "video",
                "ring_expires_at": "2026-08-18T12:00:45Z",
            ])
        )

        XCTAssertEqual(push.callId, callId)
        XCTAssertEqual(push.callUUID.uuidString.lowercased(), callId)
        XCTAssertEqual(push.callerName, "AliceExample")
        XCTAssertEqual(push.callerUserId, "550e8400-e29b-41d4-a716-446655440001")
        XCTAssertTrue(push.video)
        XCTAssertEqual(push.ringExpiresAt, "2026-08-18T12:00:45Z")

        XCTAssertNil(IncomingCallPush(payload: ["type": "message.created", "call_id": callId]))
        XCTAssertNil(IncomingCallPush(payload: ["type": "call.ringing", "call_id": "not-a-uuid"]))
    }

    func testIncomingPushExpiryReportsKnownStaleDeadlinesAsUnanswered() throws {
        let now = Date(timeIntervalSince1970: 1_787_011_200) // 2026-08-18T00:00:00Z
        let callId = "550e8400-e29b-41d4-a716-446655440000"

        func push(expiry: String?) throws -> IncomingCallPush {
            var payload: [AnyHashable: Any] = [
                "type": "call.ringing",
                "call_id": callId,
            ]
            payload["ring_expires_at"] = expiry
            return try XCTUnwrap(IncomingCallPush(payload: payload))
        }

        XCTAssertTrue(try push(expiry: "2026-08-17T23:59:59Z").isExpired(at: now))
        XCTAssertFalse(try push(expiry: "2026-08-18T00:00:01.250Z").isExpired(at: now))
        XCTAssertEqual(
            try push(expiry: "2026-08-18T00:00:01.250Z").ringExpiryDate,
            Date(timeIntervalSince1970: 1_787_011_201.25)
        )
        XCTAssertFalse(try push(expiry: "not-a-date").isExpired(at: now))
        XCTAssertFalse(try push(expiry: nil).isExpired(at: now))
        XCTAssertEqual(
            try push(expiry: "2026-08-17T23:59:59Z").callKitDisposition(at: now),
            .reportAsUnanswered
        )
        XCTAssertEqual(
            try push(expiry: "not-a-date").callKitDisposition(at: now),
            .ringing
        )
    }

    func testAuthenticatedIncomingCallRequiresExactAccountScopedInvitationContract() throws {
        let now = try XCTUnwrap(
            CallLifecyclePolicy.serverTimestamp("2026-08-18T12:00:10Z")
        )
        let callID = "550e8400-e29b-41d4-a716-446655440000"
        let callerID = "550e8400-e29b-41d4-a716-446655440001"
        let currentUserID = "550e8400-e29b-41d4-a716-446655440002"
        let push = try XCTUnwrap(IncomingCallPush(payload: [
            "type": "call.ringing",
            "call_id": callID,
            "initiator_name": "Spoofed push name",
            "initiator_user_id": callerID,
            "call_type": "voice",
            "ring_expires_at": "2026-08-18T12:00:45Z",
        ]))
        let response = callDTO(
            id: callID,
            name: "\nAuthenticated Alice",
            participantUserIds: [callerID],
            direction: "incoming",
            type: "video",
            video: true,
            state: "ringing",
            startedAt: "2026-08-18T12:00:00Z",
            ringExpiresAt: "2026-08-18T12:00:45Z"
        )

        let authenticated = try XCTUnwrap(
            IncomingCallAuthenticationPolicy.authenticatedCall(
                response: response,
                matching: push,
                currentUserID: currentUserID,
                now: now
            )
        )

        XCTAssertEqual(authenticated.callUUID, push.callUUID)
        XCTAssertEqual(authenticated.record.id, callID)
        XCTAssertEqual(authenticated.record.name, "Authenticated Alice")
        XCTAssertNotEqual(authenticated.record.name, push.callerName)
        XCTAssertEqual(authenticated.record.participantUserIds, [callerID])
        XCTAssertEqual(authenticated.record.direction, "incoming")
        XCTAssertEqual(authenticated.record.state, .ringing)
        XCTAssertTrue(authenticated.record.video)
        XCTAssertEqual(authenticated.initiatorUserID, callerID)

        let activeGroupInvite = callDTO(
            id: callID,
            participantUserIds: [callerID],
            direction: "incoming",
            state: "active",
            startedAt: "2026-08-18T12:00:00Z",
            ringExpiresAt: "2026-08-18T12:00:45Z"
        )
        XCTAssertEqual(
            IncomingCallAuthenticationPolicy.authenticatedCall(
                response: activeGroupInvite,
                matching: push,
                currentUserID: currentUserID,
                now: now
            )?.record.state,
            .ringing
        )
    }

    func testCallWaitingRoutesOnlyDifferentCallsDuringConnectedOrReconnectingMedia() throws {
        let activeCallID = "41000000-0000-4000-8000-000000000001"
        let waitingCallID = "41000000-0000-4000-8000-000000000002"
        let initiatorUserID = "41000000-0000-4000-8000-000000000003"
        let now = Date(timeIntervalSince1970: 1_000)
        let incoming = authenticatedIncomingCall(
            id: waitingCallID,
            initiatorUserID: initiatorUserID,
            ringExpiryDate: now.addingTimeInterval(30)
        )

        for mediaState in [CallWaitingMediaState.connected, .reconnecting] {
            guard case .waiting(let waiting) = CallWaitingRoutingPolicy.route(
                incoming: incoming,
                activeCallID: activeCallID,
                mediaState: mediaState,
                now: now
            ) else {
                XCTFail("Expected call waiting while media is \(mediaState)")
                continue
            }
            XCTAssertEqual(waiting.callID, waitingCallID)
            XCTAssertEqual(waiting.initiatorUserID, initiatorUserID)
            XCTAssertEqual(waiting.ringExpiryDate, now.addingTimeInterval(30))
        }

        for mediaState in [
            CallWaitingMediaState.idle,
            .preparing,
            .connecting,
            .ending,
        ] {
            XCTAssertEqual(
                CallWaitingRoutingPolicy.route(
                    incoming: incoming,
                    activeCallID: activeCallID,
                    mediaState: mediaState,
                    now: now
                ),
                .primary
            )
        }
        XCTAssertEqual(
            CallWaitingRoutingPolicy.route(
                incoming: incoming,
                activeCallID: waitingCallID.uppercased(),
                mediaState: .connected,
                now: now
            ),
            .currentCall
        )
        XCTAssertEqual(
            CallWaitingRoutingPolicy.route(
                incoming: incoming,
                activeCallID: nil,
                mediaState: .connected,
                now: now
            ),
            .decline
        )
        XCTAssertEqual(
            CallWaitingRoutingPolicy.route(
                incoming: incoming,
                activeCallID: "not-a-call-id",
                mediaState: .reconnecting,
                now: now
            ),
            .decline
        )
    }

    func testCallWaitingDeclinesUnsafeDifferentCallDuringConnectedMedia() {
        let activeCallID = "42000000-0000-4000-8000-000000000001"
        let waitingCallID = "42000000-0000-4000-8000-000000000002"
        let initiatorUserID = "42000000-0000-4000-8000-000000000003"
        let anotherUserID = "42000000-0000-4000-8000-000000000004"
        let now = Date(timeIntervalSince1970: 2_000)

        let missingInitiator = authenticatedIncomingCall(
            id: waitingCallID,
            initiatorUserID: nil,
            participantUserIDs: [initiatorUserID],
            ringExpiryDate: now.addingTimeInterval(30)
        )
        XCTAssertEqual(
            CallWaitingRoutingPolicy.route(
                incoming: missingInitiator,
                activeCallID: activeCallID,
                mediaState: .connected,
                now: now
            ),
            .decline
        )

        let contradictoryInitiator = authenticatedIncomingCall(
            id: waitingCallID,
            initiatorUserID: initiatorUserID,
            participantUserIDs: [anotherUserID],
            ringExpiryDate: now.addingTimeInterval(30)
        )
        XCTAssertEqual(
            CallWaitingRoutingPolicy.route(
                incoming: contradictoryInitiator,
                activeCallID: activeCallID,
                mediaState: .reconnecting,
                now: now
            ),
            .decline
        )

        let expired = authenticatedIncomingCall(
            id: waitingCallID,
            initiatorUserID: initiatorUserID,
            ringExpiryDate: now
        )
        XCTAssertEqual(
            CallWaitingRoutingPolicy.route(
                incoming: expired,
                activeCallID: activeCallID,
                mediaState: .connected,
                now: now
            ),
            .decline
        )
    }

    func testCallWaitingStateRetainsOnlyOneAuthenticatedInitiator() throws {
        let now = Date(timeIntervalSince1970: 3_000)
        let first = try authenticatedWaitingCall(
            id: "43000000-0000-4000-8000-000000000001",
            initiatorUserID: "43000000-0000-4000-8000-000000000002",
            ringExpiryDate: now.addingTimeInterval(20),
            routeAt: now
        )
        let refreshed = try authenticatedWaitingCall(
            id: first.callID,
            initiatorUserID: first.initiatorUserID,
            ringExpiryDate: now.addingTimeInterval(30),
            routeAt: now
        )
        let second = try authenticatedWaitingCall(
            id: "43000000-0000-4000-8000-000000000003",
            initiatorUserID: "43000000-0000-4000-8000-000000000004",
            ringExpiryDate: now.addingTimeInterval(30),
            routeAt: now
        )
        var state = CallWaitingState()

        XCTAssertEqual(state.retain(first), .retained)
        XCTAssertEqual(state.retain(refreshed), .refreshed)
        XCTAssertEqual(state.waitingCall, refreshed)
        XCTAssertEqual(state.retain(second), .occupied(second))
        XCTAssertEqual(state.waitingCall, refreshed)
        XCTAssertFalse(state.isMerging)
    }

    func testCallWaitingMergeFailureRetainsAndSuccessClearsExactWaitingCall() throws {
        let currentUserID = "44000000-0000-4000-8000-000000000001"
        let peerUserID = "44000000-0000-4000-8000-000000000002"
        let waitingUserID = "44000000-0000-4000-8000-000000000003"
        let activeCallID = "44000000-0000-4000-8000-000000000004"
        let now = Date(timeIntervalSince1970: 4_000)
        let waiting = try authenticatedWaitingCall(
            id: "44000000-0000-4000-8000-000000000005",
            initiatorUserID: waitingUserID,
            ringExpiryDate: now.addingTimeInterval(30),
            routeAt: now
        )
        let active = record(
            id: activeCallID,
            state: .active,
            offset: 1,
            participantUserIds: [peerUserID]
        )
        var state = CallWaitingState()
        XCTAssertEqual(state.retain(waiting), .retained)

        guard case .begin(let firstAttempt) = state.beginMerge(
            activeCallID: activeCallID.uppercased(),
            mediaState: .connected,
            calls: [active],
            currentUserID: currentUserID,
            now: now
        ) else {
            return XCTFail("Expected an eligible merge")
        }
        XCTAssertEqual(firstAttempt.target, CallWaitingMergeTarget(
            activeCallID: activeCallID,
            waitingCallID: waiting.callID,
            recipientUserID: waitingUserID
        ))
        XCTAssertTrue(state.isMerging)
        XCTAssertEqual(
            state.beginMerge(
                activeCallID: activeCallID,
                mediaState: .connected,
                calls: [active],
                currentUserID: currentUserID,
                now: now
            ),
            .denied(.mergeInProgress)
        )

        XCTAssertEqual(
            state.completeMerge(firstAttempt, result: .failure),
            .retainedForRetry(waiting)
        )
        XCTAssertEqual(state.waitingCall, waiting)
        XCTAssertFalse(state.isMerging)

        guard case .begin(let retryAttempt) = state.beginMerge(
            activeCallID: activeCallID,
            mediaState: .reconnecting,
            calls: [active],
            currentUserID: currentUserID,
            now: now
        ) else {
            return XCTFail("Expected the failed merge to remain retryable")
        }
        XCTAssertNotEqual(retryAttempt, firstAttempt)
        XCTAssertEqual(
            state.completeMerge(retryAttempt, result: .success),
            .merged(waiting)
        )
        XCTAssertNil(state.waitingCall)
        XCTAssertFalse(state.isMerging)
    }

    func testCallWaitingMergeRequiresLiveUnboundCallRosterAndCapacity() throws {
        let currentUserID = "45000000-0000-4000-8000-000000000001"
        let peerUserID = "45000000-0000-4000-8000-000000000002"
        let waitingUserID = "45000000-0000-4000-8000-000000000003"
        let activeCallID = "45000000-0000-4000-8000-000000000004"
        let now = Date(timeIntervalSince1970: 5_000)
        let waiting = try authenticatedWaitingCall(
            id: "45000000-0000-4000-8000-000000000005",
            initiatorUserID: waitingUserID,
            ringExpiryDate: now.addingTimeInterval(30),
            routeAt: now
        )

        func eligibility(
            _ call: CallRecord,
            mediaState: CallWaitingMediaState = .connected,
            participantLimit: Int = CallWaitingMergePolicy.maximumParticipantCount,
            at date: Date? = nil
        ) -> CallWaitingMergeEligibility {
            CallWaitingMergePolicy.eligibility(
                waitingCall: waiting,
                activeCallID: activeCallID,
                mediaState: mediaState,
                calls: [call],
                currentUserID: currentUserID,
                participantLimit: participantLimit,
                now: date ?? now
            )
        }

        let active = record(
            id: activeCallID,
            state: .active,
            offset: 1,
            participantUserIds: [peerUserID]
        )
        XCTAssertEqual(
            eligibility(active),
            .eligible(CallWaitingMergeTarget(
                activeCallID: activeCallID,
                waitingCallID: waiting.callID,
                recipientUserID: waitingUserID
            ))
        )
        XCTAssertEqual(eligibility(active, mediaState: .connecting), .denied(.mediaUnavailable))

        let bound = record(
            id: activeCallID,
            state: .active,
            offset: 1,
            participantUserIds: [peerUserID],
            conversationId: "45000000-0000-4000-8000-000000000006"
        )
        XCTAssertEqual(eligibility(bound), .denied(.conversationBound))

        let callerAlreadyPresent = record(
            id: activeCallID,
            state: .active,
            offset: 1,
            participantUserIds: [peerUserID, waitingUserID]
        )
        XCTAssertEqual(
            eligibility(callerAlreadyPresent),
            .denied(.callerAlreadyParticipant)
        )

        let full = record(
            id: activeCallID,
            state: .active,
            offset: 1,
            participantUserIds: (1 ... 20).map(participantID)
        )
        XCTAssertEqual(eligibility(full), .denied(.participantLimitReached))

        let malformedRoster = record(
            id: activeCallID,
            state: .active,
            offset: 1,
            participantUserIds: [peerUserID, peerUserID.uppercased()]
        )
        XCTAssertEqual(eligibility(malformedRoster), .denied(.invalidRoster))
        XCTAssertEqual(
            eligibility(active, at: waiting.ringExpiryDate),
            .denied(.waitingCallExpired)
        )
    }

    func testCallWaitingDeclineExpiryAndLifecycleClearFenceMergeCompletion() throws {
        let currentUserID = "46000000-0000-4000-8000-000000000001"
        let peerUserID = "46000000-0000-4000-8000-000000000002"
        let waitingUserID = "46000000-0000-4000-8000-000000000003"
        let activeCallID = "46000000-0000-4000-8000-000000000004"
        let now = Date(timeIntervalSince1970: 6_000)
        let waiting = try authenticatedWaitingCall(
            id: "46000000-0000-4000-8000-000000000005",
            initiatorUserID: waitingUserID,
            ringExpiryDate: now.addingTimeInterval(10),
            routeAt: now
        )
        let active = record(
            id: activeCallID,
            state: .active,
            offset: 1,
            participantUserIds: [peerUserID]
        )
        var state = CallWaitingState()
        XCTAssertEqual(state.retain(waiting), .retained)
        guard case .begin(let attempt) = state.beginMerge(
            activeCallID: activeCallID,
            mediaState: .connected,
            calls: [active],
            currentUserID: currentUserID,
            now: now
        ) else {
            return XCTFail("Expected merge attempt")
        }

        XCTAssertEqual(state.decline(), waiting)
        XCTAssertNil(state.waitingCall)
        XCTAssertEqual(state.completeMerge(attempt, result: .success), .stale)

        XCTAssertEqual(state.retain(waiting), .retained)
        XCTAssertNil(state.expire(at: now.addingTimeInterval(9)))
        XCTAssertEqual(state.expire(at: waiting.ringExpiryDate), waiting)
        XCTAssertNil(state.waitingCall)

        XCTAssertEqual(state.retain(waiting), .retained)
        XCTAssertNil(
            state.clearForLifecycle(callID: "46000000-0000-4000-8000-000000000099")
        )
        XCTAssertEqual(state.waitingCall, waiting)
        XCTAssertEqual(state.clearForLifecycle(callID: waiting.callID.uppercased()), waiting)
        XCTAssertNil(state.waitingCall)
    }

    func testAuthenticatedIncomingCallRejectsWrongOwnerIdentityAndStaleContracts() throws {
        let now = try XCTUnwrap(
            CallLifecyclePolicy.serverTimestamp("2026-08-18T12:00:10Z")
        )
        let callID = "550e8400-e29b-41d4-a716-446655440000"
        let callerID = "550e8400-e29b-41d4-a716-446655440001"
        let currentUserID = "550e8400-e29b-41d4-a716-446655440002"
        let otherUserID = "550e8400-e29b-41d4-a716-446655440003"
        let push = try XCTUnwrap(IncomingCallPush(payload: [
            "type": "call.ringing",
            "call_id": callID,
            "initiator_user_id": callerID,
            "ring_expires_at": "2026-08-18T12:00:45Z",
        ]))
        let validParticipants = [callerID]
        let tooManyRemoteParticipants = [callerID] + (1 ... 20).map {
            String(format: "60000000-0000-4000-8000-%012d", $0)
        }
        let rejectedResponses = [
            callDTO(
                id: callID.uppercased(),
                participantUserIds: validParticipants,
                direction: "incoming",
                state: "ringing",
                ringExpiresAt: "2026-08-18T12:00:45Z"
            ),
            callDTO(
                id: callID,
                participantUserIds: validParticipants,
                direction: "outgoing",
                state: "ringing",
                ringExpiresAt: "2026-08-18T12:00:45Z"
            ),
            callDTO(
                id: callID,
                participantUserIds: validParticipants,
                direction: "incoming",
                state: "ended",
                ringExpiresAt: "2026-08-18T12:00:45Z"
            ),
            callDTO(
                id: callID,
                participantUserIds: [],
                direction: "incoming",
                state: "ringing",
                ringExpiresAt: "2026-08-18T12:00:45Z"
            ),
            callDTO(
                id: callID,
                participantUserIds: [callerID, currentUserID],
                direction: "incoming",
                state: "ringing",
                ringExpiresAt: "2026-08-18T12:00:45Z"
            ),
            callDTO(
                id: callID,
                participantUserIds: [otherUserID],
                direction: "incoming",
                state: "ringing",
                ringExpiresAt: "2026-08-18T12:00:45Z"
            ),
            callDTO(
                id: callID,
                participantUserIds: [callerID, callerID.uppercased()],
                direction: "incoming",
                state: "ringing",
                ringExpiresAt: "2026-08-18T12:00:45Z"
            ),
            callDTO(
                id: callID,
                participantUserIds: tooManyRemoteParticipants,
                direction: "incoming",
                state: "ringing",
                ringExpiresAt: "2026-08-18T12:00:45Z"
            ),
            callDTO(
                id: callID,
                participantUserIds: validParticipants,
                direction: "incoming",
                state: "ringing",
                ringExpiresAt: "2026-08-18T12:00:09Z"
            ),
            callDTO(
                id: callID,
                participantUserIds: validParticipants,
                direction: "incoming",
                state: "ringing",
                ringExpiresAt: nil
            ),
        ]

        for response in rejectedResponses {
            XCTAssertNil(
                IncomingCallAuthenticationPolicy.authenticatedCall(
                    response: response,
                    matching: push,
                    currentUserID: currentUserID,
                    now: now
                )
            )
        }
    }

    func testIncomingCallVerificationAdmissionRejectsReplacementAndDuplicateEvents() throws {
        let push = try XCTUnwrap(IncomingCallPush(payload: [
            "type": "call.ringing",
            "call_id": "550e8400-e29b-41d4-a716-446655440000",
        ]))
        let eventID = UUID(uuidString: "550e8400-e29b-41d4-a716-446655440010")!
        let request = IncomingCallVerificationRequest(
            eventId: eventID,
            push: push,
            admissionGeneration: 11
        )

        XCTAssertTrue(IncomingCallVerificationAdmissionPolicy.permits(
            request,
            callUUID: push.callUUID,
            pendingEventID: eventID,
            admissionGeneration: 11,
            currentGeneration: 11
        ))
        XCTAssertFalse(IncomingCallVerificationAdmissionPolicy.permits(
            request,
            callUUID: push.callUUID,
            pendingEventID: UUID(),
            admissionGeneration: 11,
            currentGeneration: 11
        ), "A duplicate delivery must invalidate the older cached verification event")
        XCTAssertFalse(IncomingCallVerificationAdmissionPolicy.permits(
            request,
            callUUID: push.callUUID,
            pendingEventID: eventID,
            admissionGeneration: 11,
            currentGeneration: 12
        ), "Ownership recovery or replacement must reject a suspended old-generation lookup")
        XCTAssertFalse(IncomingCallVerificationAdmissionPolicy.permits(
            request,
            callUUID: UUID(),
            pendingEventID: eventID,
            admissionGeneration: 11,
            currentGeneration: 11
        ))
    }

    func testRetainedAuthenticatedCallsRequireExactRecoveredOwner() {
        XCTAssertTrue(RetainedCallOwnerRecoveryPolicy.mayReuseAuthenticatedCalls(
            previousOwnerFingerprint: "owner-a",
            recoveredOwnerFingerprint: "owner-a"
        ))
        XCTAssertFalse(RetainedCallOwnerRecoveryPolicy.mayReuseAuthenticatedCalls(
            previousOwnerFingerprint: nil,
            recoveredOwnerFingerprint: "owner-a"
        ))
        XCTAssertFalse(RetainedCallOwnerRecoveryPolicy.mayReuseAuthenticatedCalls(
            previousOwnerFingerprint: "owner-a",
            recoveredOwnerFingerprint: "owner-b"
        ))
    }

    func testProtectedCallRecoveryPermitsBiometricLockedColdLaunchOnlyAfterAccountProof() {
        func permits(
            isSignedIn: Bool = true,
            isSigningOut: Bool = false,
            accountSetupComplete: Bool = true,
            sessionGrantsFullAccess: Bool = true,
            hasAuthenticatedCapabilities: Bool = true,
            accountMutationsAllowed: Bool = true,
            callsFeatureEnabled: Bool = true,
            communicationSurfacesConcealed: Bool = false,
            localInterfaceRequiresBiometricUnlock: Bool = true
        ) -> Bool {
            ProtectedCallRecoveryPolicy.permits(
                isSignedIn: isSignedIn,
                isSigningOut: isSigningOut,
                accountSetupComplete: accountSetupComplete,
                sessionGrantsFullAccess: sessionGrantsFullAccess,
                hasAuthenticatedCapabilities: hasAuthenticatedCapabilities,
                accountMutationsAllowed: accountMutationsAllowed,
                callsFeatureEnabled: callsFeatureEnabled,
                communicationSurfacesConcealed: communicationSurfacesConcealed,
                localInterfaceRequiresBiometricUnlock: localInterfaceRequiresBiometricUnlock
            )
        }

        XCTAssertTrue(permits(localInterfaceRequiresBiometricUnlock: true))
        XCTAssertTrue(permits(localInterfaceRequiresBiometricUnlock: false))
        XCTAssertFalse(permits(isSignedIn: false))
        XCTAssertFalse(permits(isSigningOut: true))
        XCTAssertFalse(permits(accountSetupComplete: false))
        XCTAssertFalse(permits(sessionGrantsFullAccess: false))
        XCTAssertFalse(permits(hasAuthenticatedCapabilities: false))
        XCTAssertFalse(permits(accountMutationsAllowed: false))
        XCTAssertFalse(permits(callsFeatureEnabled: false))
        XCTAssertFalse(permits(communicationSurfacesConcealed: true))
    }

    func testProtectedCallRecoveryReleasesQueuedEventBeforeRestoreCompletes() async {
        let latch = ProtectedCallRecoveryLatch()
        let ticket = ProtectedCallRecoveryLatch.Ticket.initial
        let queuedEvent = Task { await latch.wait(for: ticket) }

        for _ in 0..<100 {
            if await latch.pendingWaiterCount() > 0 { break }
            await Task.yield()
        }
        let waitingBeforeRecovery = await latch.pendingWaiterCount()
        XCTAssertEqual(waitingBeforeRecovery, 1)

        // This models the exact account/session lease becoming ready while the separate
        // foreground biometric restore remains suspended.
        let didResolve = await latch.resolve(.ready, for: ticket)
        let resolution = await queuedEvent.value
        let waitingAfterRecovery = await latch.pendingWaiterCount()
        XCTAssertTrue(didResolve)
        XCTAssertEqual(resolution, .ready)
        XCTAssertEqual(waitingAfterRecovery, 0)
    }

    func testProtectedCallRecoveryResetSupersedesOldCycleAndWaitsForNewOne() async {
        let latch = ProtectedCallRecoveryLatch()
        let firstTicket = ProtectedCallRecoveryLatch.Ticket.initial
        let oldQueuedEvent = Task { await latch.wait(for: firstTicket) }

        for _ in 0..<100 {
            if await latch.pendingWaiterCount() > 0 { break }
            await Task.yield()
        }
        let firstCycleWaiterCount = await latch.pendingWaiterCount()
        XCTAssertEqual(firstCycleWaiterCount, 1)

        let secondReset = await latch.reset(requestSequence: 1)
        XCTAssertTrue(secondReset.accepted)
        let secondTicket = secondReset.ticket
        XCTAssertNotEqual(secondTicket, firstTicket)
        let oldResolution = await oldQueuedEvent.value
        let staleResolveSucceeded = await latch.resolve(.ready, for: firstTicket)
        XCTAssertEqual(oldResolution, .superseded)
        XCTAssertFalse(staleResolveSucceeded)

        let newQueuedEvent = Task { await latch.wait(for: secondTicket) }
        for _ in 0..<100 {
            if await latch.pendingWaiterCount() > 0 { break }
            await Task.yield()
        }
        let secondCycleWaiterCount = await latch.pendingWaiterCount()
        let secondResolveSucceeded = await latch.resolve(.ready, for: secondTicket)
        let newResolution = await newQueuedEvent.value
        let finalWaiterCount = await latch.pendingWaiterCount()
        XCTAssertEqual(secondCycleWaiterCount, 1)
        XCTAssertTrue(secondResolveSucceeded)
        XCTAssertEqual(newResolution, .ready)
        XCTAssertEqual(finalWaiterCount, 0)
    }

    func testProtectedCallRecoveryRequiresNewCycleAfterUnavailableResolution() async {
        let latch = ProtectedCallRecoveryLatch()
        let unavailableTicket = ProtectedCallRecoveryLatch.Ticket.initial

        let unavailableSucceeded = await latch.resolve(.unavailable, for: unavailableTicket)
        let unavailable = await latch.wait(for: unavailableTicket)
        let staleReadySucceeded = await latch.resolve(.ready, for: unavailableTicket)
        let readyReset = await latch.reset(requestSequence: 1)
        XCTAssertTrue(readyReset.accepted)
        let readyTicket = readyReset.ticket
        let readySucceeded = await latch.resolve(.ready, for: readyTicket)
        let ready = await latch.wait(for: readyTicket)

        XCTAssertTrue(unavailableSucceeded)
        XCTAssertEqual(unavailable, .unavailable)
        XCTAssertFalse(staleReadySucceeded)
        XCTAssertTrue(readySucceeded)
        XCTAssertEqual(ready, .ready)
    }

    func testProtectedCallRecoveryRejectsResetThatReachesActorOutOfOrder() async {
        let latch = ProtectedCallRecoveryLatch()

        // MainActor callers allocate these sequences synchronously before either actor hop. This
        // deliberately delivers the newer request first, modeling the older task being delayed.
        let newerReset = await latch.reset(requestSequence: 2)
        XCTAssertTrue(newerReset.accepted)
        let queuedEvent = Task { await latch.wait(for: newerReset.ticket) }
        for _ in 0..<100 {
            if await latch.pendingWaiterCount() > 0 { break }
            await Task.yield()
        }
        let waiterCountBeforeDelayedReset = await latch.pendingWaiterCount()
        XCTAssertEqual(waiterCountBeforeDelayedReset, 1)

        let delayedOlderReset = await latch.reset(requestSequence: 1)
        XCTAssertFalse(delayedOlderReset.accepted)
        XCTAssertEqual(delayedOlderReset.ticket, newerReset.ticket)
        let waiterCountAfterDelayedReset = await latch.pendingWaiterCount()
        XCTAssertEqual(waiterCountAfterDelayedReset, 1)

        let didResolve = await latch.resolve(.ready, for: newerReset.ticket)
        let resolution = await queuedEvent.value
        XCTAssertTrue(didResolve)
        XCTAssertEqual(resolution, .ready)

        let followingReset = await latch.reset(requestSequence: 3)
        XCTAssertTrue(followingReset.accepted)
        XCTAssertEqual(
            followingReset.ticket.generation,
            newerReset.ticket.generation + 1,
            "The rejected stale request must not advance the latch generation"
        )
    }

    func testDeferredCallKitAnswerSurvivesOnlyInitialColdLaunchOwnershipRecovery() {
        let callUUID = UUID(uuidString: "550e8400-e29b-41d4-a716-446655440020")!
        let competingCallUUID = UUID(uuidString: "550e8400-e29b-41d4-a716-446655440025")!
        var gate = DeferredCallKitAnswerGate()

        XCTAssertTrue(gate.retain(
            callUUID: callUUID,
            admissionGeneration: 4,
            currentGeneration: 4
        ))
        XCTAssertFalse(gate.retain(
            callUUID: callUUID,
            admissionGeneration: 4,
            currentGeneration: 4
        ), "Only one system Answer action may wait on a generic call")
        XCTAssertFalse(gate.retain(
            callUUID: competingCallUUID,
            admissionGeneration: 4,
            currentGeneration: 4
        ), "A second generic call must not gain a concurrent primary Answer intent")
        XCTAssertEqual(
            gate.rebindForInitialOwnershipRecovery(
                previousOwnerFingerprint: nil,
                quarantinedCallUUIDs: [callUUID],
                newGeneration: 5
            ),
            []
        )
        XCTAssertTrue(gate.consumeAuthenticated(
            callUUID: callUUID,
            admissionGeneration: 5,
            currentGeneration: 5
        ))
        XCTAssertTrue(gate.admissionGenerations.isEmpty)
        XCTAssertTrue(gate.retain(
            callUUID: competingCallUUID,
            admissionGeneration: 5,
            currentGeneration: 5
        ), "The next call may retain Answer after the first intent is consumed")
    }

    func testDeferredCallKitAnswerFailsAcrossReplacementAccountGeneration() {
        let callUUID = UUID(uuidString: "550e8400-e29b-41d4-a716-446655440021")!
        var gate = DeferredCallKitAnswerGate()
        XCTAssertTrue(gate.retain(
            callUUID: callUUID,
            admissionGeneration: 8,
            currentGeneration: 8
        ))

        XCTAssertEqual(
            gate.rebindForInitialOwnershipRecovery(
                previousOwnerFingerprint: "authenticated-owner-a",
                quarantinedCallUUIDs: [callUUID],
                newGeneration: 9
            ),
            [callUUID]
        )
        XCTAssertFalse(gate.consumeAuthenticated(
            callUUID: callUUID,
            admissionGeneration: 9,
            currentGeneration: 9
        ))
        XCTAssertTrue(gate.admissionGenerations.isEmpty)
    }

    func testDeferredCallKitAnswerFailsOnSignOutAndTerminalRetirement() {
        let first = UUID(uuidString: "550e8400-e29b-41d4-a716-446655440022")!
        let second = UUID(uuidString: "550e8400-e29b-41d4-a716-446655440023")!
        var gate = DeferredCallKitAnswerGate()
        XCTAssertTrue(gate.retain(
            callUUID: first,
            admissionGeneration: 12,
            currentGeneration: 12
        ))
        XCTAssertFalse(gate.retain(
            callUUID: second,
            admissionGeneration: 12,
            currentGeneration: 12
        ), "A second Answer intent cannot coexist with the primary one")

        XCTAssertTrue(gate.remove(callUUID: first), "A terminal lookup retires its exact intent")
        XCTAssertTrue(gate.retain(
            callUUID: second,
            admissionGeneration: 12,
            currentGeneration: 12
        ), "The next Answer intent may be retained after terminal retirement")
        XCTAssertEqual(gate.invalidateAll(), [second], "Sign-out retires every remaining intent")
        XCTAssertTrue(gate.admissionGenerations.isEmpty)
    }

    func testDeferredCallKitAnswerRejectsStaleAuthenticationGeneration() {
        let callUUID = UUID(uuidString: "550e8400-e29b-41d4-a716-446655440024")!
        var gate = DeferredCallKitAnswerGate()
        XCTAssertTrue(gate.retain(
            callUUID: callUUID,
            admissionGeneration: 20,
            currentGeneration: 20
        ))
        XCTAssertFalse(gate.consumeAuthenticated(
            callUUID: callUUID,
            admissionGeneration: 20,
            currentGeneration: 21
        ))
        XCTAssertTrue(gate.admissionGenerations.isEmpty)
    }

    func testIncomingCallLookupFailurePolicyRetiresTerminalButRetriesTransientFailures() {
        XCTAssertEqual(
            IncomingCallLookupFailurePolicy.disposition(for: APIErrorPayload(
                code: "CALL_NOT_FOUND",
                message: "Missing",
                httpStatus: 404
            )),
            .terminal
        )
        XCTAssertEqual(
            IncomingCallLookupFailurePolicy.disposition(for: APIClientError.signedOut),
            .terminal
        )
        XCTAssertEqual(
            IncomingCallLookupFailurePolicy.disposition(for: APIErrorPayload(
                code: "SERVICE_UNAVAILABLE",
                message: "Retry",
                httpStatus: 503
            )),
            .transient
        )
        XCTAssertEqual(
            IncomingCallLookupFailurePolicy.disposition(
                for: URLError(.networkConnectionLost)
            ),
            .transient
        )
    }

    func testIncomingCallLookupRetryBacksOffHonorsServerDelayAndStopsAtExpiry() {
        XCTAssertEqual(IncomingCallLookupRetryPolicy.delay(
            failureCount: 1,
            retryAfter: nil,
            remainingLifetime: 45
        ), 1)
        XCTAssertEqual(IncomingCallLookupRetryPolicy.delay(
            failureCount: 2,
            retryAfter: nil,
            remainingLifetime: 45
        ), 2)
        XCTAssertEqual(IncomingCallLookupRetryPolicy.delay(
            failureCount: 3,
            retryAfter: nil,
            remainingLifetime: 45
        ), 4)
        XCTAssertEqual(IncomingCallLookupRetryPolicy.delay(
            failureCount: 20,
            retryAfter: nil,
            remainingLifetime: 45
        ), 8)
        XCTAssertEqual(IncomingCallLookupRetryPolicy.delay(
            failureCount: 2,
            retryAfter: 17,
            remainingLifetime: 45
        ), 17)
        XCTAssertNil(IncomingCallLookupRetryPolicy.delay(
            failureCount: 1,
            retryAfter: 45,
            remainingLifetime: 45
        ))
        XCTAssertNil(IncomingCallLookupRetryPolicy.delay(
            failureCount: 20,
            retryAfter: nil,
            remainingLifetime: 8
        ))

        XCTAssertEqual(
            IncomingCallLookupRetryPolicy.retryAfter(from: APIErrorPayload(
                code: "TOO_MANY_REQUESTS",
                message: "Wait",
                httpStatus: 429,
                retryAfter: 12
            )),
            12
        )
        XCTAssertEqual(
            IncomingCallLookupRetryPolicy.retryAfter(
                from: APIClientError.httpResponse(status: 503, retryAfter: 9)
            ),
            9
        )
    }

    func testIncomingCallQuarantineBoundsUntrustedPushLifetime() {
        let receivedAt = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            IncomingCallQuarantinePolicy.expiry(pushExpiry: nil, receivedAt: receivedAt),
            receivedAt.addingTimeInterval(IncomingCallQuarantinePolicy.defaultLifetime)
        )
        XCTAssertEqual(
            IncomingCallQuarantinePolicy.expiry(
                pushExpiry: receivedAt.addingTimeInterval(30),
                receivedAt: receivedAt
            ),
            receivedAt.addingTimeInterval(30)
        )
        XCTAssertEqual(
            IncomingCallQuarantinePolicy.expiry(
                pushExpiry: receivedAt.addingTimeInterval(24 * 60 * 60),
                receivedAt: receivedAt
            ),
            receivedAt.addingTimeInterval(IncomingCallQuarantinePolicy.maximumLifetime)
        )
        XCTAssertEqual(
            IncomingCallQuarantinePolicy.expiry(
                pushExpiry: receivedAt.addingTimeInterval(-1),
                receivedAt: receivedAt
            ),
            receivedAt.addingTimeInterval(-1)
        )
    }

    func testCallCapabilityFailsClosedOnlineButPreservesOfflineDeferredAttempts() {
        let enabled = capabilities(calls: true)
        let disabled = capabilities(calls: false)
        let unknown = capabilities(calls: nil)

        XCTAssertTrue(CallLifecyclePolicy.mayCreateCall(signedIn: true, online: true, capabilities: enabled))
        XCTAssertFalse(CallLifecyclePolicy.mayCreateCall(signedIn: true, online: true, capabilities: disabled))
        XCTAssertFalse(CallLifecyclePolicy.mayCreateCall(signedIn: true, online: true, capabilities: unknown))
        XCTAssertTrue(CallLifecyclePolicy.mayCreateCall(signedIn: true, online: false, capabilities: nil))
        XCTAssertFalse(CallLifecyclePolicy.mayCreateCall(signedIn: true, online: false, capabilities: disabled))
        XCTAssertFalse(CallLifecyclePolicy.mayCreateCall(signedIn: false, online: false, capabilities: enabled))
    }

    func testServerStatesAndHistoryMergeKeepDurableLocalRecords() {
        XCTAssertEqual(CallLifecyclePolicy.mappedState("ended"), .completed)
        XCTAssertEqual(CallLifecyclePolicy.mappedState("answered"), .active)
        XCTAssertEqual(CallLifecyclePolicy.mappedState("rejected"), .declined)
        XCTAssertEqual(CallLifecyclePolicy.mappedState("timed_out"), .missed)

        let localOnly = record(id: "local", state: .queued, offset: 2)
        let oldVersion = record(id: "shared", state: .ringing, offset: 1)
        let remoteVersion = record(id: "shared", state: .completed, offset: 3)
        let merged = CallLifecyclePolicy.merge(
            remote: [remoteVersion],
            local: [localOnly, oldVersion]
        )

        XCTAssertEqual(merged.map(\.id), ["shared", "local"])
        XCTAssertEqual(merged.first?.state, .completed)

        let conversationID = "20000000-0000-4000-8000-000000000001"
        let answeredAt = Date(timeIntervalSince1970: 10)
        let endedAt = Date(timeIntervalSince1970: 30)
        var contextualLocal = record(
            id: "30000000-0000-4000-8000-000000000001",
            state: .active,
            offset: 10,
            participantUserIds: ["10000000-0000-4000-8000-000000000002"],
            conversationId: conversationID,
            answeredAt: answeredAt,
            endedAt: endedAt
        )
        var contextFreeRemote = contextualLocal
        contextFreeRemote.state = .completed
        contextFreeRemote.participantUserIds = []
        contextFreeRemote.conversationId = "not-a-conversation"
        contextFreeRemote.answeredAt = nil
        contextFreeRemote.endedAt = nil
        contextFreeRemote.startedAt = Date(timeIntervalSince1970: 0)
        contextualLocal.state = .ringing

        let contextualMerge = CallLifecyclePolicy.merge(
            remote: [contextFreeRemote],
            local: [contextualLocal]
        )
        XCTAssertEqual(contextualMerge.first?.conversationId, conversationID)
        XCTAssertEqual(contextualMerge.first?.answeredAt, answeredAt)
        XCTAssertEqual(contextualMerge.first?.endedAt, endedAt)
        XCTAssertEqual(contextualMerge.first?.startedAt, contextualLocal.startedAt)
        XCTAssertEqual(
            contextualMerge.first?.participantUserIds,
            ["10000000-0000-4000-8000-000000000002"]
        )

        var duplicateLocal = contextualLocal
        duplicateLocal.name = "Duplicate projection"
        XCTAssertEqual(
            CallLifecyclePolicy.merge(
                remote: [],
                local: [contextualLocal, duplicateLocal]
            ).count,
            1
        )

        let equalTimeA = record(id: "a-call", state: .completed, offset: 50)
        let equalTimeB = record(id: "b-call", state: .completed, offset: 50)
        XCTAssertEqual(
            CallLifecyclePolicy.merge(
                remote: [],
                local: [equalTimeB, equalTimeA]
            ).map(\.id),
            ["a-call", "b-call"]
        )

        var staleHistory = contextualLocal
        staleHistory.state = .ringing
        staleHistory.direction = "incoming"
        var locallyMissed = contextualLocal
        locallyMissed.state = .missed
        locallyMissed.direction = "missed"
        XCTAssertEqual(
            CallLifecyclePolicy.mergeHistory(
                remote: [staleHistory],
                local: [locallyMissed]
            ).first?.state,
            .missed
        )
        XCTAssertEqual(
            CallLifecyclePolicy.mergeHistory(
                remote: [staleHistory],
                local: [locallyMissed]
            ).first?.direction,
            "missed"
        )

        var locallyFailed = contextualLocal
        locallyFailed.state = .failed
        locallyFailed.endedAt = endedAt
        let failedMerge = CallLifecyclePolicy.mergeHistory(
            remote: [staleHistory],
            local: [locallyFailed]
        )
        XCTAssertEqual(failedMerge.first?.state, .failed)
        XCTAssertEqual(failedMerge.first?.endedAt, endedAt)
    }

    func testNewestCallHistoryPageMergePreservesEveryOlderCachedCall() throws {
        let newestID = "abcdefab-cdef-4abc-8def-abcdefabc003"
        let response = CallPage(
            items: [
                callDTO(id: newestID, name: "Newest"),
                callDTO(id: newestID.uppercased(), name: "Duplicate boundary row"),
            ],
            page: CursorPage(nextCursor: "older-page", hasMore: true, limit: 2)
        )

        let validated = try CallHistoryPageAccumulator.validateNewestPage(
            response,
            requestedLimit: 2
        )
        XCTAssertEqual(validated.map(\.id), [newestID])

        let cachedOlder = [
            record(id: "30000000-0000-4000-8000-000000000001", state: .completed, offset: 10),
            record(id: "30000000-0000-4000-8000-000000000002", state: .missed, offset: 20),
        ]
        let newest = record(id: validated[0].id, state: .completed, offset: 30)
        let merged = CallLifecyclePolicy.mergeHistory(remote: [newest], local: cachedOlder)

        XCTAssertEqual(
            merged.map(\.id),
            [
                newestID,
                "30000000-0000-4000-8000-000000000002",
                "30000000-0000-4000-8000-000000000001",
            ]
        )
        XCTAssertEqual(merged.count, cachedOlder.count + 1)
    }

    func testDuplicateCallResolutionIsInvariantAcrossEveryInputPermutation() throws {
        let callID = "abcdefab-cdef-4abc-8def-abcdefabc010"
        let conversationA = "20000000-0000-4000-8000-000000000001"
        let conversationB = "20000000-0000-4000-8000-000000000002"
        var queued = record(
            id: callID,
            state: .queued,
            offset: 10,
            participantUserIds: ["10000000-0000-4000-8000-000000000001"],
            conversationId: conversationA
        )
        queued.name = "Alice"
        var active = record(
            id: callID,
            state: .active,
            offset: 10,
            participantUserIds: ["10000000-0000-4000-8000-000000000002"],
            conversationId: conversationB,
            answeredAt: Date(timeIntervalSince1970: 20)
        )
        active.name = "Kit Pay user"
        var completedLowercase = record(
            id: callID,
            state: .completed,
            offset: 10,
            endedAt: Date(timeIntervalSince1970: 30)
        )
        completedLowercase.name = "Same server projection"
        var completedUppercase = record(
            id: callID.uppercased(),
            state: .completed,
            offset: 10,
            endedAt: Date(timeIntervalSince1970: 30)
        )
        completedUppercase.name = "Same server projection"

        let permutations = allPermutations([
            queued,
            active,
            completedLowercase,
            completedUppercase,
        ])
        let baseline = try XCTUnwrap(
            CallLifecyclePolicy.merge(remote: [], local: permutations[0]).first
        )
        XCTAssertEqual(baseline.state, .completed)

        for permutation in permutations {
            XCTAssertEqual(
                CallLifecyclePolicy.merge(remote: [], local: permutation),
                [baseline]
            )
            XCTAssertEqual(
                CallLifecyclePolicy.merge(remote: permutation, local: []),
                [baseline]
            )
            XCTAssertEqual(
                CallLifecyclePolicy.mergeHistory(remote: permutation, local: []),
                [baseline]
            )
        }
    }

    func testLargeCallHistoryMergeScalesToThirtyThousandDistinctRows() {
        let local = (0 ..< 20_000).map { index in
            record(
                id: String(format: "call-%08d", index),
                state: .queued,
                offset: TimeInterval(index)
            )
        }
        let remote = (10_000 ..< 30_000).map { index in
            record(
                id: String(format: "call-%08d", index),
                state: .completed,
                offset: TimeInterval(index),
                endedAt: Date(timeIntervalSince1970: TimeInterval(index + 1))
            )
        }

        let merged = CallLifecyclePolicy.mergeHistory(remote: remote, local: local)

        XCTAssertEqual(merged.count, 30_000)
        XCTAssertEqual(Set(merged.map { $0.id.lowercased() }).count, 30_000)
        XCTAssertEqual(merged.filter { $0.state == .completed }.count, 20_000)
        XCTAssertEqual(merged.first?.id, "call-00029999")
        XCTAssertEqual(merged.last?.id, "call-00000000")
    }

    func testReplayResultWithDifferentIDRetainsValidatedOfflineContext() {
        let conversationID = "20000000-0000-4000-8000-000000000001"
        let peerUserID = "10000000-0000-4000-8000-000000000002"
        var placeholder = record(
            id: "30000000-0000-4000-8000-000000000001",
            state: .queued,
            offset: 10,
            participantUserIds: [peerUserID],
            conversationId: conversationID
        )
        placeholder.name = "Alice"
        var partialServerResult = record(
            id: "30000000-0000-4000-8000-000000000002",
            state: .ringing,
            offset: 11
        )
        partialServerResult.name = "Kit Pay user"

        let resolved = CallLifecyclePolicy.preservingDurableContext(
            in: partialServerResult,
            from: placeholder,
            fallbackConversationID: conversationID,
            fallbackParticipantUserIDs: [peerUserID],
            fallbackName: "Alice"
        )

        XCTAssertEqual(resolved.id, partialServerResult.id)
        XCTAssertEqual(resolved.conversationId, conversationID)
        XCTAssertEqual(resolved.participantUserIds, [peerUserID])
        XCTAssertEqual(resolved.name, "Alice")

        var refreshedActive = partialServerResult
        refreshedActive.state = .active
        refreshedActive.answeredAt = Date(timeIntervalSince1970: 12)
        let staleStartResponse = CallLifecyclePolicy.mergingStartResponse(
            partialServerResult,
            with: refreshedActive
        )
        XCTAssertEqual(staleStartResponse.state, .active)
        XCTAssertEqual(staleStartResponse.answeredAt, refreshedActive.answeredAt)
    }

    func testConversationTimelineInterleavesMessagesAndCallsChronologically() {
        let currentUserID = "10000000-0000-4000-8000-000000000001"
        let peerUserID = "10000000-0000-4000-8000-000000000002"
        let conversation = directConversation(
            id: "20000000-0000-4000-8000-000000000001",
            currentUserID: currentUserID,
            peerUserID: peerUserID,
            updatedAt: 100
        )
        let firstMessage = timelineMessage(
            id: "40000000-0000-4000-8000-000000000001",
            conversationID: conversation.id,
            offset: 10
        )
        let secondMessage = timelineMessage(
            id: "40000000-0000-4000-8000-000000000002",
            conversationID: conversation.id,
            offset: 30
        )
        let call = record(
            id: "30000000-0000-4000-8000-000000000001",
            state: .completed,
            offset: 20,
            participantUserIds: [currentUserID, peerUserID],
            conversationId: conversation.id
        )

        let items = ConversationTimelinePolicy.items(
            for: conversation,
            allConversations: [conversation],
            currentUserID: currentUserID,
            messages: [secondMessage, firstMessage].sorted { $0.createdAt < $1.createdAt },
            calls: [call]
        )

        XCTAssertEqual(
            items.map(\.id),
            [
                "message:40000000-0000-4000-8000-000000000001",
                "call:30000000-0000-4000-8000-000000000001",
                "message:40000000-0000-4000-8000-000000000002",
            ]
        )
    }

    func testConversationTimelinePromotesPaymentDescriptorsToFirstClassEvents() throws {
        let currentUserID = "10000000-0000-4000-8000-000000000001"
        let peerUserID = "10000000-0000-4000-8000-000000000002"
        let conversation = directConversation(
            id: "20000000-0000-4000-8000-000000000001",
            currentUserID: currentUserID,
            peerUserID: peerUserID,
            updatedAt: 100
        )
        let descriptor = try XCTUnwrap(KitPaymentMessage(
            action: .request,
            paymentRequestId: "40000000-0000-4000-8000-000000000001",
            amountMinor: 50_000,
            currencyCode: "UGX",
            currencyScale: 0,
            note: "Lunch"
        ))
        let payment = LocalMessage(
            id: UUID(uuidString: "50000000-0000-4000-8000-000000000001")!,
            conversationId: conversation.id,
            senderId: peerUserID,
            body: descriptor.encoded,
            createdAt: Date(timeIntervalSince1970: 20),
            sentAt: Date(timeIntervalSince1970: 20),
            state: .received,
            failureReason: nil,
            isOutgoing: false
        )

        let items = ConversationTimelinePolicy.items(
            for: conversation,
            allConversations: [conversation],
            currentUserID: currentUserID,
            messages: [payment],
            calls: []
        )

        XCTAssertEqual(
            ConversationTimelinePolicy.paymentRecipientUserID(
                for: conversation,
                currentUserID: currentUserID
            ),
            peerUserID
        )
        XCTAssertEqual(items.map(\.id), ["payment:50000000-0000-4000-8000-000000000001"])
        guard case .payment(let projected, let parsed) = try XCTUnwrap(items.first) else {
            return XCTFail("Expected a first-class payment timeline event")
        }
        XCTAssertEqual(projected, payment)
        XCTAssertEqual(parsed, descriptor)
        XCTAssertEqual(items.first?.occurredAt, payment.createdAt)
    }

    func testConversationTimelineKeepsPaymentDescriptorsInertOutsideValidatedDirectChats() throws {
        let currentUserID = "10000000-0000-4000-8000-000000000001"
        let peerUserID = "10000000-0000-4000-8000-000000000002"
        let thirdUserID = "10000000-0000-4000-8000-000000000003"
        let descriptor = try XCTUnwrap(KitPaymentMessage(
            action: .request,
            paymentRequestId: "40000000-0000-4000-8000-000000000001",
            amountMinor: 50_000,
            currencyCode: "UGX",
            currencyScale: 0,
            note: nil
        ))
        let invalidConversations = [
            Conversation(
                id: "direct:legacy-peer",
                title: "Legacy",
                participantUserIds: [currentUserID, peerUserID],
                unreadCount: 0,
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            Conversation(
                id: "20000000-0000-4000-8000-000000000001",
                title: "Group",
                participantUserIds: [currentUserID, peerUserID, thirdUserID],
                unreadCount: 0,
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            Conversation(
                id: "20000000-0000-4000-8000-000000000002",
                title: "Duplicate roster",
                participantUserIds: [currentUserID, currentUserID],
                unreadCount: 0,
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            Conversation(
                id: "20000000-0000-4000-8000-000000000003",
                title: "Unrelated roster",
                participantUserIds: [peerUserID, thirdUserID],
                unreadCount: 0,
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
        ]

        for (index, conversation) in invalidConversations.enumerated() {
            XCTAssertNil(ConversationTimelinePolicy.paymentRecipientUserID(
                for: conversation,
                currentUserID: currentUserID
            ))
            var payment = timelineMessage(
                id: "50000000-0000-4000-8000-00000000000\(index + 1)",
                conversationID: conversation.id,
                offset: 20
            )
            payment.body = descriptor.encoded

            let items = ConversationTimelinePolicy.items(
                for: conversation,
                allConversations: invalidConversations,
                currentUserID: currentUserID,
                messages: [payment],
                calls: []
            )

            XCTAssertEqual(items.count, 1)
            guard case .message(let projected) = try XCTUnwrap(items.first) else {
                return XCTFail("An invalid direct chat must not expose a payment action")
            }
            XCTAssertEqual(projected, payment)
        }
    }

    func testConversationTimelineKeepsPaymentDescriptorInertWhenSenderBindingIsCorrupt() throws {
        let currentUserID = "10000000-0000-4000-8000-000000000001"
        let peerUserID = "10000000-0000-4000-8000-000000000002"
        let conversation = directConversation(
            id: "20000000-0000-4000-8000-000000000001",
            currentUserID: currentUserID,
            peerUserID: peerUserID,
            updatedAt: 100
        )
        let descriptor = try XCTUnwrap(KitPaymentMessage(
            action: .request,
            paymentRequestId: "40000000-0000-4000-8000-000000000001",
            amountMinor: 50_000,
            currencyCode: "UGX",
            currencyScale: 0,
            note: nil
        ))
        let payment = LocalMessage(
            id: UUID(uuidString: "50000000-0000-4000-8000-000000000001")!,
            conversationId: conversation.id,
            senderId: "10000000-0000-4000-8000-000000000003",
            body: descriptor.encoded,
            createdAt: Date(timeIntervalSince1970: 20),
            sentAt: nil,
            state: .received,
            failureReason: nil,
            isOutgoing: false
        )

        let items = ConversationTimelinePolicy.items(
            for: conversation,
            allConversations: [conversation],
            currentUserID: currentUserID,
            messages: [payment],
            calls: []
        )

        guard case .message(let projected) = try XCTUnwrap(items.first) else {
            return XCTFail("A payment event must be authenticated to the direct-chat peer")
        }
        XCTAssertEqual(projected, payment)
    }

    func testTimelineDateHeadingsUseWhatsAppStyleDayBucketsAcrossAllEventTypes() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let locale = Locale(identifier: "en_US_POSIX")
        let reference = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 20,
            hour: 12
        )))
        let currentUserID = "10000000-0000-4000-8000-000000000001"
        let peerUserID = "10000000-0000-4000-8000-000000000002"
        let conversation = directConversation(
            id: "20000000-0000-4000-8000-000000000001",
            currentUserID: currentUserID,
            peerUserID: peerUserID,
            updatedAt: reference.timeIntervalSince1970
        )
        func date(_ day: Int, hour: Int = 9) throws -> Date {
            try XCTUnwrap(calendar.date(from: DateComponents(
                year: 2026,
                month: 8,
                day: day,
                hour: hour
            )))
        }
        func message(_ id: String, at date: Date, body: String = "Hello") -> LocalMessage {
            LocalMessage(
                id: UUID(uuidString: id)!,
                conversationId: conversation.id,
                senderId: currentUserID,
                body: body,
                createdAt: date,
                sentAt: date,
                state: .sent,
                failureReason: nil,
                isOutgoing: true
            )
        }
        let oldMessage = message(
            "50000000-0000-4000-8000-000000000001",
            at: try date(10)
        )
        let paymentDescriptor = try XCTUnwrap(KitPaymentMessage(
            action: .request,
            paymentRequestId: "40000000-0000-4000-8000-000000000001",
            amountMinor: 500,
            currencyCode: "UGX",
            currencyScale: 0,
            note: nil
        ))
        let payment = message(
            "50000000-0000-4000-8000-000000000002",
            at: try date(17),
            body: paymentDescriptor.encoded
        )
        let call = record(
            id: "30000000-0000-4000-8000-000000000001",
            state: .completed,
            offset: try date(19).timeIntervalSince1970,
            participantUserIds: [currentUserID, peerUserID],
            conversationId: conversation.id
        )
        let today = message(
            "50000000-0000-4000-8000-000000000003",
            at: try date(20)
        )

        let items = ConversationTimelinePolicy.items(
            for: conversation,
            allConversations: [conversation],
            currentUserID: currentUserID,
            messages: [today, payment, oldMessage],
            calls: [call],
            dateSeparatorsRelativeTo: reference,
            calendar: calendar,
            locale: locale
        )
        let headings = items.compactMap { item -> ConversationTimelineDateSeparator? in
            guard case .dateSeparator(let separator) = item else { return nil }
            return separator
        }

        XCTAssertEqual(headings.map(\.label), ["Aug 10, 2026", "Monday", "Yesterday", "Today"])
        XCTAssertEqual(
            headings.map(\.accessibilityLabel),
            [
                "Chat events from Aug 10, 2026",
                "Chat events from Monday",
                "Chat events from Yesterday",
                "Chat events from Today",
            ]
        )
        XCTAssertEqual(items.filter {
            if case .payment = $0 { return true }
            return false
        }.count, 1)
        XCTAssertEqual(items.filter {
            if case .call = $0 { return true }
            return false
        }.count, 1)
    }

    func testTimelineDateLabelsHonorTheSuppliedCalendarTimeZone() throws {
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let locale = Locale(identifier: "en_US_POSIX")
        let formatter = ISO8601DateFormatter()
        let reference = try XCTUnwrap(formatter.date(from: "2026-08-20T00:30:00Z"))
        let sameLocalDay = try XCTUnwrap(formatter.date(from: "2026-08-19T08:00:00Z"))

        XCTAssertEqual(
            ConversationTimelineDateLabelPolicy.label(
                for: sameLocalDay,
                relativeTo: reference,
                calendar: losAngeles,
                locale: locale
            ),
            "Today"
        )
    }

    func testConversationTimelineKeepsLegacyMessagesWhenConversationIDIsNotAUUID() {
        let conversation = Conversation(
            id: "direct:legacy-peer",
            title: "Legacy chat",
            participantUserIds: [],
            unreadCount: 0,
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let message = timelineMessage(
            id: "40000000-0000-4000-8000-000000000001",
            conversationID: conversation.id,
            offset: 10
        )
        let unrelatedCall = record(
            id: "30000000-0000-4000-8000-000000000001",
            state: .completed,
            offset: 15,
            participantUserIds: ["10000000-0000-4000-8000-000000000002"]
        )

        XCTAssertEqual(
            ConversationTimelinePolicy.items(
                for: conversation,
                allConversations: [conversation],
                currentUserID: "10000000-0000-4000-8000-000000000001",
                messages: [message],
                calls: [unrelatedCall]
            ).map(\.id),
            ["message:40000000-0000-4000-8000-000000000001"]
        )
    }

    func testExplicitConversationBindingWinsAndNeverLeaksIntoAnotherPeerThread() {
        let currentUserID = "10000000-0000-4000-8000-000000000001"
        let peerUserID = "10000000-0000-4000-8000-000000000002"
        let first = directConversation(
            id: "20000000-0000-4000-8000-000000000001",
            currentUserID: currentUserID,
            peerUserID: peerUserID,
            updatedAt: 10
        )
        let second = directConversation(
            id: "20000000-0000-4000-8000-000000000002",
            currentUserID: currentUserID,
            peerUserID: peerUserID,
            updatedAt: 20
        )
        let call = record(
            id: "30000000-0000-4000-8000-000000000001",
            state: .completed,
            offset: 30,
            participantUserIds: [peerUserID],
            conversationId: first.id.uppercased()
        )

        XCTAssertEqual(
            ConversationTimelinePolicy.items(
                for: first,
                allConversations: [first, second],
                currentUserID: currentUserID,
                messages: [],
                calls: [call]
            ).map(\.id),
            ["call:30000000-0000-4000-8000-000000000001"]
        )
        XCTAssertTrue(
            ConversationTimelinePolicy.items(
                for: second,
                allConversations: [first, second],
                currentUserID: currentUserID,
                messages: [],
                calls: [call]
            ).isEmpty
        )
    }

    func testExplicitConversationBindingRejectsContradictoryParticipantRoster() {
        let currentUserID = "10000000-0000-4000-8000-000000000001"
        let peerUserID = "10000000-0000-4000-8000-000000000002"
        let otherUserID = "10000000-0000-4000-8000-000000000003"
        let conversation = directConversation(
            id: "20000000-0000-4000-8000-000000000001",
            currentUserID: currentUserID,
            peerUserID: peerUserID,
            updatedAt: 10
        )
        let contradictoryCall = record(
            id: "30000000-0000-4000-8000-000000000001",
            state: .completed,
            offset: 30,
            participantUserIds: [currentUserID, otherUserID],
            conversationId: conversation.id
        )

        XCTAssertTrue(
            ConversationTimelinePolicy.items(
                for: conversation,
                allConversations: [conversation],
                currentUserID: currentUserID,
                messages: [],
                calls: [contradictoryCall]
            ).isEmpty
        )
    }

    func testLegacyCallFallbackFailsClosedForDuplicateDirectConversations() {
        let currentUserID = "10000000-0000-4000-8000-000000000001"
        let peerUserID = "10000000-0000-4000-8000-000000000002"
        let otherUserID = "10000000-0000-4000-8000-000000000003"
        let old = directConversation(
            id: "20000000-0000-4000-8000-000000000001",
            currentUserID: currentUserID,
            peerUserID: peerUserID,
            updatedAt: 10
        )
        let newest = directConversation(
            id: "20000000-0000-4000-8000-000000000002",
            currentUserID: currentUserID,
            peerUserID: peerUserID,
            updatedAt: 20
        )
        let group = Conversation(
            id: "20000000-0000-4000-8000-000000000003",
            title: "Group",
            participantUserIds: [currentUserID, peerUserID, otherUserID],
            unreadCount: 0,
            updatedAt: Date(timeIntervalSince1970: 30)
        )
        let legacyCall = record(
            id: "30000000-0000-4000-8000-000000000001",
            state: .missed,
            offset: 15,
            participantUserIds: [peerUserID]
        )
        let conversations = [old, newest, group]

        XCTAssertTrue(
            ConversationTimelinePolicy.items(
                for: old,
                allConversations: conversations,
                currentUserID: currentUserID,
                messages: [],
                calls: [legacyCall]
            ).isEmpty
        )
        XCTAssertTrue(
            ConversationTimelinePolicy.items(
                for: newest,
                allConversations: conversations,
                currentUserID: currentUserID,
                messages: [],
                calls: [legacyCall]
            ).isEmpty
        )
        XCTAssertTrue(
            ConversationTimelinePolicy.items(
                for: group,
                allConversations: conversations,
                currentUserID: currentUserID,
                messages: [],
                calls: [legacyCall]
            ).isEmpty
        )

        XCTAssertEqual(
            ConversationTimelinePolicy.items(
                for: old,
                allConversations: [old, group],
                currentUserID: currentUserID,
                messages: [],
                calls: [legacyCall]
            ).map(\.id),
            ["call:30000000-0000-4000-8000-000000000001"]
        )
    }

    func testLegacyCallFallbackRejectsInvalidOrAmbiguousParticipants() {
        let currentUserID = "10000000-0000-4000-8000-000000000001"
        let peerUserID = "10000000-0000-4000-8000-000000000002"
        let otherUserID = "10000000-0000-4000-8000-000000000003"
        let conversation = directConversation(
            id: "20000000-0000-4000-8000-000000000001",
            currentUserID: currentUserID,
            peerUserID: peerUserID,
            updatedAt: 10
        )
        let ambiguous = record(
            id: "30000000-0000-4000-8000-000000000001",
            state: .completed,
            offset: 10,
            participantUserIds: [peerUserID, otherUserID]
        )
        let malformed = record(
            id: "30000000-0000-4000-8000-000000000002",
            state: .completed,
            offset: 20,
            participantUserIds: [peerUserID, "not-a-user"]
        )

        XCTAssertTrue(
            ConversationTimelinePolicy.items(
                for: conversation,
                allConversations: [conversation],
                currentUserID: currentUserID,
                messages: [],
                calls: [ambiguous, malformed]
            ).isEmpty
        )
    }

    func testTimelineIdentityDeduplicatesCallsAndOrdersEqualDatesDeterministically() {
        let currentUserID = "10000000-0000-4000-8000-000000000001"
        let peerUserID = "10000000-0000-4000-8000-000000000002"
        let conversation = directConversation(
            id: "20000000-0000-4000-8000-000000000001",
            currentUserID: currentUserID,
            peerUserID: peerUserID,
            updatedAt: 10
        )
        let message = timelineMessage(
            id: "30000000-0000-4000-8000-000000000001",
            conversationID: conversation.id,
            offset: 10
        )
        let secondMessage = timelineMessage(
            id: "30000000-0000-4000-8000-000000000002",
            conversationID: conversation.id,
            offset: 10
        )
        let call = record(
            id: "30000000-0000-4000-8000-000000000001",
            state: .completed,
            offset: 10,
            participantUserIds: [peerUserID],
            conversationId: conversation.id
        )
        var duplicate = call
        duplicate.name = "Duplicate"
        duplicate.direction = "incoming"

        let items = ConversationTimelinePolicy.items(
            for: conversation,
            allConversations: [conversation],
            currentUserID: currentUserID,
            messages: [secondMessage, message],
            calls: [call, duplicate]
        )

        XCTAssertEqual(
            items.map(\.id),
            [
                "message:30000000-0000-4000-8000-000000000001",
                "message:30000000-0000-4000-8000-000000000002",
                "call:30000000-0000-4000-8000-000000000001",
            ]
        )
    }

    func testCallPresentationMapsDirectionMediaStateAndConnectedDuration() {
        let answeredAt = Date(timeIntervalSince1970: 10)
        let completed = record(
            id: "30000000-0000-4000-8000-000000000001",
            state: .completed,
            offset: 5,
            direction: "outgoing",
            video: true,
            answeredAt: answeredAt,
            endedAt: answeredAt.addingTimeInterval(65)
        )
        let completedPresentation = ConversationCallPresentationPolicy.presentation(for: completed)
        XCTAssertEqual(completedPresentation.title, "Video call")
        XCTAssertEqual(completedPresentation.symbolName, "phone.arrow.up.right")
        XCTAssertTrue(completedPresentation.isOutgoing)
        XCTAssertEqual(completedPresentation.durationSeconds, 65)
        XCTAssertEqual(ConversationCallPresentationPolicy.durationText(65), "1:05")
        XCTAssertTrue(completedPresentation.callbackEnabled)

        let missed = record(
            id: "30000000-0000-4000-8000-000000000002",
            state: .active,
            offset: 5,
            direction: "missed"
        )
        let missedPresentation = ConversationCallPresentationPolicy.presentation(for: missed)
        XCTAssertEqual(missedPresentation.title, "Missed voice call")
        XCTAssertEqual(missedPresentation.symbolName, "phone.down.fill")
        XCTAssertTrue(missedPresentation.isMissed)
        XCTAssertFalse(missedPresentation.isOutgoing)
        XCTAssertNil(missedPresentation.statusText)
        XCTAssertTrue(missedPresentation.callbackEnabled)

        let outgoingNoAnswer = record(
            id: "30000000-0000-4000-8000-000000000004",
            state: .missed,
            offset: 5,
            direction: "outgoing"
        )
        let outgoingPresentation = ConversationCallPresentationPolicy.presentation(
            for: outgoingNoAnswer
        )
        XCTAssertFalse(outgoingPresentation.isMissed)
        XCTAssertTrue(outgoingPresentation.isOutgoing)
        XCTAssertEqual(outgoingPresentation.title, "Voice call")

        let queued = record(
            id: "30000000-0000-4000-8000-000000000003",
            state: .queued,
            offset: 5
        )
        let queuedPresentation = ConversationCallPresentationPolicy.presentation(for: queued)
        XCTAssertEqual(queuedPresentation.statusText, "Waiting for connection")
        XCTAssertFalse(queuedPresentation.callbackEnabled)
    }

    func testDurationClampsInvalidIntervalsAndServerTimestampAcceptsFractions() throws {
        let answeredAt = Date(timeIntervalSince1970: 20)
        let invalidDuration = record(
            id: "30000000-0000-4000-8000-000000000001",
            state: .completed,
            offset: 10,
            answeredAt: answeredAt,
            endedAt: answeredAt.addingTimeInterval(-5)
        )
        XCTAssertEqual(ConversationCallPresentationPolicy.durationSeconds(for: invalidDuration), 0)
        XCTAssertNil(
            ConversationCallPresentationPolicy.durationSeconds(
                for: record(
                    id: "30000000-0000-4000-8000-000000000002",
                    state: .completed,
                    offset: 10
                )
            )
        )
        XCTAssertEqual(ConversationCallPresentationPolicy.durationText(3_661), "1:01:01")

        let standard = try XCTUnwrap(
            CallLifecyclePolicy.serverTimestamp("2026-08-18T12:00:00Z")
        )
        let fractional = try XCTUnwrap(
            CallLifecyclePolicy.serverTimestamp("2026-08-18T12:00:00.250Z")
        )
        XCTAssertEqual(fractional.timeIntervalSince(standard), 0.25, accuracy: 0.001)
        XCTAssertNil(CallLifecyclePolicy.serverTimestamp("not-a-date"))
    }

    func testLegacyCallRecordJSONDecodesWithoutInlineTimelineFields() throws {
        let json = Data(#"""
        {
          "id": "30000000-0000-4000-8000-000000000001",
          "name": "Alice",
          "participantUserIds": ["10000000-0000-4000-8000-000000000002"],
          "direction": "outgoing",
          "type": "voice",
          "video": false,
          "state": "completed",
          "startedAt": "2026-08-18T12:00:00Z",
          "endedAt": null,
          "isDeferredAttempt": false
        }
        """#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(CallRecord.self, from: json)
        XCTAssertNil(decoded.conversationId)
        XCTAssertNil(decoded.answeredAt)
    }

    func testReplayedIncomingRingDoesNotDowngradeAnAcceptedCall() {
        let id = "550e8400-e29b-41d4-a716-446655440000"
        let active = record(id: id, state: .active, offset: 2)
        let delayedRing = record(id: id, state: .ringing, offset: 1)

        XCTAssertEqual(
            CallLifecyclePolicy.mergingIncomingRing(delayedRing, into: [active]),
            [active]
        )
        XCTAssertEqual(
            CallLifecyclePolicy.mergingIncomingRing(delayedRing, into: []),
            [delayedRing]
        )

        var locallyMissed = active
        locallyMissed.state = .missed
        locallyMissed.direction = "missed"
        XCTAssertEqual(
            CallLifecyclePolicy.mergingVerifiedIncomingLookup(
                delayedRing,
                into: [locallyMissed]
            ),
            [locallyMissed]
        )
        XCTAssertEqual(
            CallLifecyclePolicy.mergingVerifiedIncomingLookup(
                delayedRing,
                into: [active]
            ),
            [active]
        )
    }

    func testTerminationReplayRequiresValidatedBackendIdentity() {
        let command = OfflineCommand(
            id: UUID(),
            kind: .callTermination,
            createdAt: Date(),
            nextAttemptAt: Date(),
            attemptCount: 0,
            conversationId: nil,
            messageId: nil,
            recipientUserIds: nil,
            recipientName: nil,
            video: nil,
            expiresAt: nil,
            callId: "550e8400-e29b-41d4-a716-446655440000",
            terminationKind: .end,
            terminationReason: "network_error"
        )

        XCTAssertEqual(
            OutboxPolicy.terminationReplay(for: command),
            CallTerminationReplay(
                callId: "550e8400-e29b-41d4-a716-446655440000",
                kind: .end,
                reason: "network_error"
            )
        )

        var invalid = command
        invalid.callId = "not-a-call"
        XCTAssertNil(OutboxPolicy.terminationReplay(for: invalid))

        let overlaid = CallLifecyclePolicy.applyingPendingTerminations(
            to: [record(id: command.callId!, state: .ringing, offset: 1)],
            outbox: [command]
        )
        XCTAssertEqual(overlaid.first?.state, .completed)
        XCTAssertNotNil(overlaid.first?.endedAt)
    }

    func testNoLongerDeclinableConflictIsNarrowlyIdempotent() {
        let alreadyTerminal = APIErrorPayload(
            code: "CALL_NOT_DECLINABLE",
            message: "This call can no longer be declined.",
            httpStatus: 409
        )

        XCTAssertTrue(
            CallLifecyclePolicy.isIdempotentTerminationFailure(
                alreadyTerminal,
                kind: .decline
            )
        )
        XCTAssertFalse(
            CallLifecyclePolicy.isIdempotentTerminationFailure(
                alreadyTerminal,
                kind: .end
            )
        )
        XCTAssertFalse(
            CallLifecyclePolicy.isIdempotentTerminationFailure(
                APIErrorPayload(
                    code: "CALL_NOT_ANSWERABLE",
                    message: "This call can no longer be declined.",
                    httpStatus: 409
                ),
                kind: .decline
            )
        )
        XCTAssertFalse(
            CallLifecyclePolicy.isIdempotentTerminationFailure(
                APIClientError.httpStatus(409),
                kind: .decline
            )
        )
        XCTAssertFalse(
            CallLifecyclePolicy.isIdempotentTerminationFailure(
                APIErrorPayload(
                    code: "CALL_NOT_DECLINABLE",
                    message: "Unexpected infrastructure failure.",
                    httpStatus: 500
                ),
                kind: .decline
            )
        )
    }

    func testCallContactsUseSharedPhoneDedupeAndKeepInvitationsLast() {
        let callableId = "550e8400-e29b-41d4-a716-446655440010"
        let options = CallLifecyclePolicy.contactOptions(
            remote: [
                contact(id: "phone-book-row", name: "Local Alice", phone: "0772 123 456", kit: false),
                contact(id: "invite-row", name: "Bob", phone: "0701 555 999", kit: false),
                contact(id: callableId, name: "Alice on Kit", phone: "+256772123456", kit: true),
            ],
            history: []
        )

        XCTAssertEqual(options.map(\.id), [callableId, "invite-row"])
        XCTAssertEqual(options.map(\.isKitUser), [true, false])
        XCTAssertEqual(options.first?.phoneIdentity, "+256772123456")
    }

    func testExampleContactLocalUgandaIdentityIsCallableAndListedBeforeInvites() {
        let exampleContactID = "550e8400-e29b-41d4-a716-446655440015"
        let options = CallLifecyclePolicy.contactOptions(
            remote: [
                contact(
                    id: "invite-row",
                    name: "Amina Invite",
                    phone: "+256701555999",
                    kit: false
                ),
                contact(
                    id: exampleContactID,
                    name: "ExampleContact",
                    phone: "0700000001",
                    kit: true
                ),
            ],
            history: [],
            context: .uganda
        )

        XCTAssertEqual(options.map(\.id), [exampleContactID, "invite-row"])
        XCTAssertEqual(options.first?.name, "ExampleContact")
        XCTAssertEqual(options.first?.phoneIdentity, "+256700000001")
        XCTAssertTrue(options.first?.isKitUser == true)
    }

    func testEndRequestUsesTheAuditedReasonBody() throws {
        let data = try JSONEncoder().encode(EndCallRequest(reason: "cancelled"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(object, ["reason": "cancelled"])
    }

    func testClientAttemptCancellationDecodesTheScopedTombstoneReceipt() throws {
        let response = try JSONDecoder().decode(
            CancelCallAttemptDTO.self,
            from: Data(
                #"{"client_call_id":"550e8400-e29b-41d4-a716-446655440010","cancelled":true}"#
                    .utf8
            )
        )

        XCTAssertEqual(response.clientCallId, "550e8400-e29b-41d4-a716-446655440010")
        XCTAssertTrue(response.cancelled)
    }

    func testCallStartUsesStableClientCallIdentifier() throws {
        let clientCallID = "550e8400-e29b-41d4-a716-446655440010"
        let conversationID = "550e8400-e29b-41d4-a716-446655440099"
        let request = StartCallRequest(
            recipientUserIds: ["550e8400-e29b-41d4-a716-446655440001"],
            type: "video",
            conversationId: conversationID,
            clientCallId: clientCallID
        )
        let firstData = try JSONEncoder().encode(request)
        let secondData = try JSONEncoder().encode(request)
        let first = try XCTUnwrap(
            JSONSerialization.jsonObject(with: firstData) as? [String: Any]
        )
        let second = try XCTUnwrap(
            JSONSerialization.jsonObject(with: secondData) as? [String: Any]
        )

        XCTAssertEqual(first["client_call_id"] as? String, clientCallID)
        XCTAssertEqual(second["client_call_id"] as? String, clientCallID)
        XCTAssertEqual(first["conversation_id"] as? String, conversationID)
        XCTAssertEqual(first["type"] as? String, "video")
        XCTAssertEqual(
            first["recipient_user_ids"] as? [String],
            ["550e8400-e29b-41d4-a716-446655440001"]
        )
        XCTAssertEqual(UUID(uuidString: clientCallID)?.uuidString.lowercased(), clientCallID)
    }

    func testOpaqueCallCursorIsEncodedExactlyOnceInTheFinalURL() throws {
        let url = try XCTUnwrap(
            APIEndpointPolicy.url(
                baseURL: try XCTUnwrap(
                    URL(string: "https://pay.kit.africa/api/kit-wallet/v1/")
                ),
                path: "calls",
                queryItems: [
                    URLQueryItem(name: "limit", value: "100"),
                    URLQueryItem(name: "cursor", value: "abc+/= next"),
                ]
            )
        )

        XCTAssertEqual(
            url.absoluteString,
            "https://pay.kit.africa/api/kit-wallet/v1/calls?limit=100&cursor=abc%2B%2F%3D%20next"
        )
        XCTAssertEqual(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.last?.value,
            "abc+/= next"
        )
    }

    func testCallHistoryAccumulatorFollowsEveryPageAndDeduplicatesBoundaryCalls() throws {
        let newest = callDTO(
            id: "30000000-0000-4000-8000-000000000001",
            name: "Newest"
        )
        let duplicate = callDTO(
            id: newest.id.uppercased(),
            name: "Stale duplicate"
        )
        let oldest = callDTO(
            id: "30000000-0000-4000-8000-000000000002",
            name: "Oldest"
        )
        var accumulator = CallHistoryPageAccumulator(
            requestedLimit: 2,
            maximumPageCount: 4
        )

        XCTAssertFalse(
            try accumulator.append(
                CallPage(
                    items: [newest],
                    page: CursorPage(
                        nextCursor: "abc+/= next",
                        hasMore: true,
                        limit: 2
                    )
                )
            )
        )
        XCTAssertEqual(accumulator.nextCursor, "abc+/= next")
        XCTAssertTrue(
            try accumulator.append(
                CallPage(
                    items: [duplicate, oldest],
                    page: CursorPage(nextCursor: nil, hasMore: false, limit: 2)
                )
            )
        )

        XCTAssertNil(accumulator.nextCursor)
        XCTAssertEqual(accumulator.pageCount, 2)
        XCTAssertEqual(accumulator.calls.map(\.id), [newest.id, oldest.id])
        XCTAssertEqual(accumulator.calls.map(\.name), ["Newest", "Oldest"])
    }

    func testCallHistoryAccumulatorRejectsCursorLoopsWithoutAppendingTheBadPage() throws {
        var accumulator = CallHistoryPageAccumulator(
            requestedLimit: 1,
            maximumPageCount: 3
        )
        XCTAssertFalse(
            try accumulator.append(
                CallPage(
                    items: [callDTO(id: "30000000-0000-4000-8000-000000000001")],
                    page: CursorPage(nextCursor: "repeated", hasMore: true, limit: 1)
                )
            )
        )

        XCTAssertThrowsError(
            try accumulator.append(
                CallPage(
                    items: [callDTO(id: "30000000-0000-4000-8000-000000000002")],
                    page: CursorPage(nextCursor: "repeated", hasMore: true, limit: 1)
                )
            )
        )
        XCTAssertEqual(accumulator.pageCount, 1)
        XCTAssertEqual(
            accumulator.calls.map(\.id),
            ["30000000-0000-4000-8000-000000000001"]
        )
    }

    func testCallHistoryAccumulatorRejectsAnUnboundedOrMalformedContinuation() throws {
        var bounded = CallHistoryPageAccumulator(
            requestedLimit: 1,
            maximumPageCount: 2
        )
        XCTAssertFalse(
            try bounded.append(
                CallPage(
                    items: [callDTO(id: "30000000-0000-4000-8000-000000000001")],
                    page: CursorPage(nextCursor: "page-2", hasMore: true, limit: 1)
                )
            )
        )
        XCTAssertThrowsError(
            try bounded.append(
                CallPage(
                    items: [callDTO(id: "30000000-0000-4000-8000-000000000002")],
                    page: CursorPage(nextCursor: "page-3", hasMore: true, limit: 1)
                )
            )
        )

        var malformed = CallHistoryPageAccumulator(
            requestedLimit: 1,
            maximumPageCount: 2
        )
        XCTAssertThrowsError(
            try malformed.append(
                CallPage(
                    items: [],
                    page: CursorPage(nextCursor: nil, hasMore: true, limit: 1)
                )
            )
        )
        XCTAssertEqual(malformed.pageCount, 0)
    }

    func testCallHistoryBackfillReceiptFreshnessOwnerAndSchemaPolicy() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let owner = "10000000-0000-4000-8000-000000000001"
        let fresh = CallHistoryBackfillReceipt(
            ownerUserID: owner.uppercased(),
            schemaVersion: CallHistoryBackfillPolicy.schemaVersion,
            completedAt: now.addingTimeInterval(-(CallHistoryBackfillPolicy.refreshInterval - 1))
        )

        XCTAssertFalse(CallHistoryBackfillPolicy.isDue(receipt: fresh, userID: owner, now: now))
        XCTAssertTrue(CallHistoryBackfillPolicy.isDue(receipt: nil, userID: owner, now: now))
        XCTAssertTrue(
            CallHistoryBackfillPolicy.isDue(
                receipt: CallHistoryBackfillReceipt(
                    ownerUserID: "10000000-0000-4000-8000-000000000002",
                    schemaVersion: CallHistoryBackfillPolicy.schemaVersion,
                    completedAt: now
                ),
                userID: owner,
                now: now
            )
        )
        XCTAssertTrue(
            CallHistoryBackfillPolicy.isDue(
                receipt: CallHistoryBackfillReceipt(
                    ownerUserID: owner,
                    schemaVersion: CallHistoryBackfillPolicy.schemaVersion + 1,
                    completedAt: now
                ),
                userID: owner,
                now: now
            )
        )
        XCTAssertTrue(
            CallHistoryBackfillPolicy.isDue(
                receipt: CallHistoryBackfillReceipt(
                    ownerUserID: owner,
                    schemaVersion: CallHistoryBackfillPolicy.schemaVersion,
                    completedAt: now.addingTimeInterval(-CallHistoryBackfillPolicy.refreshInterval)
                ),
                userID: owner,
                now: now
            )
        )
        XCTAssertTrue(
            CallHistoryBackfillPolicy.isDue(
                receipt: CallHistoryBackfillReceipt(
                    ownerUserID: owner,
                    schemaVersion: CallHistoryBackfillPolicy.schemaVersion,
                    completedAt: now.addingTimeInterval(1)
                ),
                userID: owner,
                now: now
            )
        )
    }

    func testCallSessionDecodesAuditedCredentialsAndCreatesSecureMediaHandoff() throws {
        let json = """
        {
          "call": {
            "id": "550e8400-e29b-41d4-a716-446655440000",
            "conversation_id": "550e8400-e29b-41d4-a716-446655440099",
            "name": "Alice",
            "participant_user_ids": ["550e8400-e29b-41d4-a716-446655440001"],
            "direction": "incoming",
            "type": "video",
            "video": false,
            "state": "ringing",
            "started_at": "2026-08-18T12:00:00Z",
            "ring_expires_at": "2026-08-18T12:00:45Z"
          },
          "rtc": {
            "provider": "livekit",
            "url": "wss://calls.example.test",
            "token": "room-token",
            "room": "call-room",
            "ice_servers": [{"urls": ["turns:turn.example.test"], "credential_type": "password"}],
            "expires_at": "2026-08-18T12:05:00Z"
          }
        }
        """

        let session = try JSONDecoder().decode(CallSessionDTO.self, from: Data(json.utf8))
        let avatarURL = "https://cdn.example.test/alice.jpg"
        let handoff = try CallMediaHandoff(
            session: session,
            participantAvatarURL: avatarURL
        )
        let presentation = ActiveCallPresentation(handoff)

        XCTAssertEqual(session.call.ringExpiresAt, "2026-08-18T12:00:45Z")
        XCTAssertTrue(session.call.isVideoCall)
        XCTAssertEqual(session.rtc.iceServers?.first?.credentialType, "password")
        XCTAssertEqual(handoff.callId, session.call.id)
        XCTAssertEqual(handoff.conversationId, "550e8400-e29b-41d4-a716-446655440099")
        XCTAssertEqual(handoff.direction, "incoming")
        XCTAssertEqual(handoff.url.absoluteString, "wss://calls.example.test")
        XCTAssertEqual(handoff.token, "room-token")
        XCTAssertEqual(handoff.participantAvatarURL, avatarURL)
        XCTAssertEqual(presentation.participantAvatarURL, avatarURL)
        XCTAssertEqual(presentation.conversationId, handoff.conversationId)
        XCTAssertTrue(handoff.video)
    }

    func testMediaHandoffRefreshesOnlyRTCForTheSameRoom() throws {
        let callId = "550e8400-e29b-41d4-a716-446655440000"
        let conversationId = "550e8400-e29b-41d4-a716-446655440099"
        let avatarURL = "https://cdn.example.test/alice.jpg"
        let original = try CallMediaHandoff(
            call: CallDTO(
                id: callId.uppercased(),
                conversationId: conversationId.uppercased(),
                name: "Alice",
                participantUserIds: ["550e8400-e29b-41d4-a716-446655440001"],
                direction: "INCOMING",
                type: "video",
                video: true,
                state: "active",
                startedAt: "2026-08-18T12:00:00Z",
                answeredAt: "2026-08-18T12:00:01Z",
                endedAt: nil,
                ringExpiresAt: nil
            ),
            rtc: rtcDetails(
                url: "wss://calls-a.example.test",
                token: "original-token",
                room: "call-room",
                expiresAt: "2026-08-18T12:05:00Z"
            ),
            participantAvatarURL: avatarURL
        )

        let refreshed = try original.refreshingRTC(
            rtcDetails(
                url: "wss://calls-b.example.test",
                token: "refreshed-token",
                room: original.room,
                expiresAt: "2026-08-18T12:10:00Z"
            )
        )

        XCTAssertEqual(refreshed.callId, callId)
        XCTAssertEqual(refreshed.conversationId, conversationId)
        XCTAssertEqual(refreshed.participantName, original.participantName)
        XCTAssertEqual(refreshed.participantAvatarURL, avatarURL)
        XCTAssertEqual(refreshed.direction, "incoming")
        XCTAssertEqual(refreshed.video, original.video)
        XCTAssertEqual(refreshed.room, original.room)
        XCTAssertEqual(refreshed.url.absoluteString, "wss://calls-b.example.test")
        XCTAssertEqual(refreshed.token, "refreshed-token")
        XCTAssertEqual(refreshed.expiresAt, "2026-08-18T12:10:00Z")
        XCTAssertEqual(original.token, "original-token")
    }

    func testMediaHandoffRejectsRTCRefreshForAnotherRoom() throws {
        let original = try mediaHandoff(
            id: "550e8400-e29b-41d4-a716-446655440000",
            direction: "outgoing"
        )

        XCTAssertThrowsError(
            try original.refreshingRTC(
                rtcDetails(
                    url: "wss://calls.example.test",
                    token: "other-room-token",
                    room: "another-call-room",
                    expiresAt: "2026-08-18T12:10:00Z"
                )
            )
        ) { error in
            XCTAssertEqual(error.localizedDescription, "Kit returned invalid call credentials.")
        }
    }

    func testConversationCallIndicatorRequiresExactIdentityAndRemoteParticipant() {
        let activeCall = ActiveCallPresentation(
            id: "550e8400-e29b-41d4-a716-446655440000",
            conversationId: "550e8400-e29b-41d4-a716-446655440099",
            participantName: "Shared contact name",
            video: true,
            direction: "outgoing"
        )

        XCTAssertEqual(
            ConversationCallIndicatorPolicy.label(
                for: "550e8400-e29b-41d4-a716-446655440099",
                activeCall: activeCall,
                resolvedConversationId: activeCall.conversationId,
                isConnected: true,
                hasRemoteParticipant: true
            ),
            "Video call • In call"
        )
        XCTAssertEqual(
            ConversationCallIndicatorPolicy.label(
                for: "550e8400-e29b-41d4-a716-446655440099",
                activeCall: activeCall,
                resolvedConversationId: activeCall.conversationId,
                isConnected: true,
                hasRemoteParticipant: true,
                elapsedSeconds: 65
            ),
            "Video call • 1:05"
        )
        XCTAssertEqual(
            ConversationCallIndicatorPolicy.label(
                for: "550e8400-e29b-41d4-a716-446655440099",
                activeCall: ActiveCallPresentation(
                    id: activeCall.id,
                    participantName: activeCall.participantName,
                    video: activeCall.video,
                    direction: activeCall.direction
                ),
                resolvedConversationId: "550e8400-e29b-41d4-a716-446655440099",
                isConnected: true,
                hasRemoteParticipant: true,
                elapsedSeconds: 65
            ),
            "Video call • 1:05"
        )
        XCTAssertNil(
            ConversationCallIndicatorPolicy.label(
                for: "550e8400-e29b-41d4-a716-446655440098",
                activeCall: activeCall,
                resolvedConversationId: activeCall.conversationId,
                isConnected: true,
                hasRemoteParticipant: true
            )
        )
        XCTAssertNil(
            ConversationCallIndicatorPolicy.label(
                for: "550e8400-e29b-41d4-a716-446655440099",
                activeCall: ActiveCallPresentation(
                    id: activeCall.id,
                    participantName: activeCall.participantName,
                    video: activeCall.video,
                    direction: activeCall.direction
                ),
                resolvedConversationId: nil,
                isConnected: true,
                hasRemoteParticipant: true
            )
        )
        XCTAssertNil(
            ConversationCallIndicatorPolicy.label(
                for: "550e8400-e29b-41d4-a716-446655440099",
                activeCall: activeCall,
                resolvedConversationId: activeCall.conversationId,
                isConnected: false,
                hasRemoteParticipant: true
            )
        )
        XCTAssertNil(
            ConversationCallIndicatorPolicy.label(
                for: "550e8400-e29b-41d4-a716-446655440099",
                activeCall: activeCall,
                resolvedConversationId: activeCall.conversationId,
                isConnected: true,
                hasRemoteParticipant: false
            )
        )
    }

    private func capabilities(calls: Bool?) -> CapabilitiesDTO {
        CapabilitiesDTO(
            apiVersion: "1",
            currency: CurrencyDTO(code: "UGX", scale: "2"),
            features: ["calls": calls],
            authentication: nil
        )
    }

    private func mediaHandoff(id: String, direction: String) throws -> CallMediaHandoff {
        try CallMediaHandoff(
            call: CallDTO(
                id: id,
                conversationId: nil,
                name: "Alice",
                participantUserIds: ["550e8400-e29b-41d4-a716-446655440001"],
                direction: direction,
                type: "voice",
                video: false,
                state: "ringing",
                startedAt: "2026-08-18T12:00:00Z",
                answeredAt: nil,
                endedAt: nil,
                ringExpiresAt: "2026-08-18T12:00:45Z"
            ),
            rtc: RTCDetails(
                provider: "livekit",
                url: "wss://calls.example.test",
                token: "room-token",
                room: "call-room",
                iceServers: nil,
                expiresAt: "2026-08-18T12:05:00Z"
            )
        )
    }

    private func rtcDetails(
        url: String,
        token: String,
        room: String,
        expiresAt: String
    ) -> RTCDetails {
        RTCDetails(
            provider: "livekit",
            url: url,
            token: token,
            room: room,
            iceServers: nil,
            expiresAt: expiresAt
        )
    }

    func testActiveCallConversationUsesExactServerBindingAndUnreadCount() {
        let currentUserID = "10000000-0000-4000-8000-000000000001"
        let peerUserID = "30000000-0000-4000-8000-000000000001"
        let conversationID = "20000000-0000-4000-8000-000000000001"
        let callID = "40000000-0000-4000-8000-000000000001"
        let conversation = Conversation(
            id: conversationID,
            title: "Alice",
            participantUserIds: [currentUserID, peerUserID],
            unreadCount: 7,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let call = record(
            id: callID,
            state: .active,
            offset: 1,
            participantUserIds: [peerUserID]
        )

        XCTAssertEqual(
            ActiveCallConversationPolicy.conversation(
                callID: callID,
                explicitConversationID: conversationID.uppercased(),
                calls: [call],
                conversations: [conversation],
                currentUserID: currentUserID
            )?.id,
            conversationID
        )
        XCTAssertEqual(
            ActiveCallConversationPolicy.unreadCount(
                callID: callID,
                explicitConversationID: conversationID,
                calls: [call],
                conversations: [conversation],
                currentUserID: currentUserID
            ),
            7
        )
    }

    func testActiveCallConversationRejectsExplicitBindingWithContradictoryRoster() {
        let currentUserID = "10000000-0000-4000-8000-000000000001"
        let conversationPeerID = "30000000-0000-4000-8000-000000000001"
        let otherPeerID = "30000000-0000-4000-8000-000000000002"
        let conversationID = "20000000-0000-4000-8000-000000000001"
        let callID = "40000000-0000-4000-8000-000000000001"
        let conversation = Conversation(
            id: conversationID,
            title: "Alice",
            participantUserIds: [currentUserID, conversationPeerID],
            unreadCount: 7,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let contradictoryCall = record(
            id: callID,
            state: .active,
            offset: 1,
            participantUserIds: [otherPeerID]
        )

        XCTAssertNil(
            ActiveCallConversationPolicy.conversation(
                callID: callID,
                explicitConversationID: conversationID,
                calls: [contradictoryCall],
                conversations: [conversation],
                currentUserID: currentUserID
            )
        )
        XCTAssertEqual(
            ActiveCallConversationPolicy.unreadCount(
                callID: callID,
                explicitConversationID: conversationID,
                calls: [contradictoryCall],
                conversations: [conversation],
                currentUserID: currentUserID
            ),
            0
        )
    }

    func testActiveCallConversationRejectsExplicitBindingWithAmbiguousCallSnapshot() {
        let currentUserID = "10000000-0000-4000-8000-000000000001"
        let peerUserID = "30000000-0000-4000-8000-000000000001"
        let conversationID = "20000000-0000-4000-8000-000000000001"
        let callID = "40000000-0000-4000-8000-000000000001"
        let conversation = directConversation(
            id: conversationID,
            currentUserID: currentUserID,
            peerUserID: peerUserID,
            updatedAt: 2
        )
        let call = record(
            id: callID,
            state: .active,
            offset: 1,
            participantUserIds: [peerUserID]
        )

        XCTAssertNil(
            ActiveCallConversationPolicy.conversation(
                callID: callID,
                explicitConversationID: conversationID,
                calls: [call, call],
                conversations: [conversation],
                currentUserID: currentUserID
            )
        )
    }

    func testActiveCallConversationFallsBackOnlyToOneUnambiguousDirectThread() {
        let currentUserID = "10000000-0000-4000-8000-000000000001"
        let peerUserID = "30000000-0000-4000-8000-000000000001"
        let callID = "40000000-0000-4000-8000-000000000001"
        let call = record(
            id: callID,
            state: .active,
            offset: 1,
            participantUserIds: [peerUserID]
        )
        let conversation = directConversation(
            id: "20000000-0000-4000-8000-000000000001",
            currentUserID: currentUserID,
            peerUserID: peerUserID,
            updatedAt: 2
        )

        XCTAssertEqual(
            ActiveCallConversationPolicy.conversation(
                callID: callID,
                explicitConversationID: nil,
                calls: [call],
                conversations: [conversation],
                currentUserID: currentUserID
            )?.id,
            conversation.id
        )

        let duplicate = directConversation(
            id: "20000000-0000-4000-8000-000000000002",
            currentUserID: currentUserID,
            peerUserID: peerUserID,
            updatedAt: 3
        )
        XCTAssertNil(
            ActiveCallConversationPolicy.conversation(
                callID: callID,
                explicitConversationID: nil,
                calls: [call],
                conversations: [conversation, duplicate],
                currentUserID: currentUserID
            )
        )
    }

    func testActiveCallConversationRejectsMalformedDuplicateAndGroupContext() {
        let currentUserID = "10000000-0000-4000-8000-000000000001"
        let peerUserID = "30000000-0000-4000-8000-000000000001"
        let callID = "40000000-0000-4000-8000-000000000001"
        let conversation = directConversation(
            id: "20000000-0000-4000-8000-000000000001",
            currentUserID: currentUserID,
            peerUserID: peerUserID,
            updatedAt: 2
        )
        let groupCall = record(
            id: callID,
            state: .active,
            offset: 1,
            participantUserIds: [peerUserID, "30000000-0000-4000-8000-000000000002"]
        )

        XCTAssertNil(
            ActiveCallConversationPolicy.conversation(
                callID: callID,
                explicitConversationID: nil,
                calls: [groupCall],
                conversations: [conversation],
                currentUserID: currentUserID
            )
        )
        XCTAssertNil(
            ActiveCallConversationPolicy.conversation(
                callID: "not-a-call",
                explicitConversationID: conversation.id,
                calls: [],
                conversations: [conversation],
                currentUserID: currentUserID
            )
        )
    }

    func testActiveCallConversationCreationTargetsOnlyTheSoleAuthenticatedPeer() {
        let currentUserID = "10000000-0000-4000-8000-000000000001"
        let peerUserID = "30000000-0000-4000-8000-000000000001"
        let callID = "40000000-0000-4000-8000-000000000001"
        let expectedConversationID = "20000000-0000-4000-8000-000000000001"
        let directCall = record(
            id: callID,
            state: .active,
            offset: 1,
            participantUserIds: [currentUserID, peerUserID, peerUserID.uppercased()]
        )

        XCTAssertEqual(
            ActiveCallConversationPolicy.creationTarget(
                callID: callID,
                explicitConversationID: expectedConversationID.uppercased(),
                calls: [directCall],
                conversations: [],
                currentUserID: currentUserID
            ),
            ActiveCallConversationPolicy.CreationTarget(
                recipientUserID: peerUserID,
                expectedConversationID: expectedConversationID
            )
        )

        let groupCall = record(
            id: callID,
            state: .active,
            offset: 1,
            participantUserIds: [peerUserID, "30000000-0000-4000-8000-000000000002"]
        )
        XCTAssertNil(
            ActiveCallConversationPolicy.creationTarget(
                callID: callID,
                explicitConversationID: nil,
                calls: [groupCall],
                conversations: [],
                currentUserID: currentUserID
            )
        )
        XCTAssertNil(
            ActiveCallConversationPolicy.creationTarget(
                callID: callID,
                explicitConversationID: nil,
                calls: [directCall, directCall],
                conversations: [],
                currentUserID: currentUserID
            )
        )
    }

    func testActiveCallConversationCreationRejectsContradictoryOrDuplicateLocalThreads() {
        let currentUserID = "10000000-0000-4000-8000-000000000001"
        let peerUserID = "30000000-0000-4000-8000-000000000001"
        let otherPeerID = "30000000-0000-4000-8000-000000000002"
        let callID = "40000000-0000-4000-8000-000000000001"
        let explicitConversationID = "20000000-0000-4000-8000-000000000001"
        let call = record(
            id: callID,
            state: .active,
            offset: 1,
            participantUserIds: [peerUserID]
        )
        let contradictory = directConversation(
            id: explicitConversationID,
            currentUserID: currentUserID,
            peerUserID: otherPeerID,
            updatedAt: 2
        )
        XCTAssertNil(
            ActiveCallConversationPolicy.creationTarget(
                callID: callID,
                explicitConversationID: explicitConversationID,
                calls: [call],
                conversations: [contradictory],
                currentUserID: currentUserID
            )
        )

        let first = directConversation(
            id: "20000000-0000-4000-8000-000000000002",
            currentUserID: currentUserID,
            peerUserID: peerUserID,
            updatedAt: 2
        )
        let duplicate = directConversation(
            id: "20000000-0000-4000-8000-000000000003",
            currentUserID: currentUserID,
            peerUserID: peerUserID,
            updatedAt: 3
        )
        XCTAssertNil(
            ActiveCallConversationPolicy.creationTarget(
                callID: callID,
                explicitConversationID: nil,
                calls: [call],
                conversations: [first, duplicate],
                currentUserID: currentUserID
            )
        )
    }

    func testActiveCallInvitationAcceptsExactlyOneActiveUnboundCallRecord() throws {
        let currentUserID = "10000000-0000-4000-8000-000000000001"
        let peerUserID = "20000000-0000-4000-8000-000000000001"
        let callID = "30000000-0000-4000-8000-000000000001"
        let presentation = ActiveCallPresentation(
            id: callID.uppercased(),
            participantName: "Alice",
            video: true,
            direction: "outgoing"
        )
        let call = record(
            id: callID,
            state: .active,
            offset: 1,
            participantUserIds: [peerUserID]
        )

        let context = try XCTUnwrap(
            ActiveCallInvitationPolicy.context(
                for: presentation,
                calls: [call],
                currentUserID: currentUserID.uppercased()
            )
        )

        XCTAssertEqual(context.call, call)
        XCTAssertEqual(context.callID, callID)
        XCTAssertEqual(context.participantUserIDs, Set([currentUserID, peerUserID]))
        XCTAssertTrue(context.canInviteAnotherParticipant)
    }

    func testActiveCallInvitationRejectsMissingDuplicateNonActiveOrBoundRecords() {
        let currentUserID = "10000000-0000-4000-8000-000000000001"
        let peerUserID = "20000000-0000-4000-8000-000000000001"
        let callID = "30000000-0000-4000-8000-000000000001"
        let presentation = ActiveCallPresentation(
            id: callID,
            participantName: "Alice",
            video: false,
            direction: "outgoing"
        )
        let active = record(
            id: callID,
            state: .active,
            offset: 1,
            participantUserIds: [peerUserID]
        )

        XCTAssertNil(
            ActiveCallInvitationPolicy.context(
                for: presentation,
                calls: [],
                currentUserID: currentUserID
            )
        )
        XCTAssertNil(
            ActiveCallInvitationPolicy.context(
                for: presentation,
                calls: [active, active],
                currentUserID: currentUserID
            )
        )
        for state in [CallState.queued, .ringing, .completed, .missed, .declined, .failed] {
            XCTAssertNil(
                ActiveCallInvitationPolicy.context(
                    for: presentation,
                    calls: [
                        record(
                            id: callID,
                            state: state,
                            offset: 1,
                            participantUserIds: [peerUserID]
                        ),
                    ],
                    currentUserID: currentUserID
                ),
                "Unexpectedly accepted \(state.rawValue)"
            )
        }

        let conversationID = "40000000-0000-4000-8000-000000000001"
        XCTAssertNil(
            ActiveCallInvitationPolicy.context(
                for: presentation,
                calls: [
                    record(
                        id: callID,
                        state: .active,
                        offset: 1,
                        participantUserIds: [peerUserID],
                        conversationId: conversationID
                    ),
                ],
                currentUserID: currentUserID
            )
        )
        XCTAssertNil(
            ActiveCallInvitationPolicy.context(
                for: ActiveCallPresentation(
                    id: callID,
                    conversationId: conversationID,
                    participantName: "Alice",
                    video: false,
                    direction: "outgoing"
                ),
                calls: [active],
                currentUserID: currentUserID
            )
        )
    }

    func testActiveCallInvitationEnforcesRosterCapacityAndExcludesParticipants() throws {
        let currentUserID = "10000000-0000-4000-8000-000000000001"
        let callID = "30000000-0000-4000-8000-000000000001"
        let presentation = ActiveCallPresentation(
            id: callID,
            participantName: "Group call",
            video: true,
            direction: "outgoing"
        )
        let remoteParticipantIDs = (1 ... 20).map(participantID)
        let fullContext = try XCTUnwrap(
            ActiveCallInvitationPolicy.context(
                for: presentation,
                calls: [
                    record(
                        id: callID,
                        state: .active,
                        offset: 1,
                        participantUserIds: remoteParticipantIDs
                    ),
                ],
                currentUserID: currentUserID
            )
        )

        XCTAssertEqual(
            fullContext.participantUserIDs.count,
            ActiveCallInvitationPolicy.maximumParticipantCount
        )
        XCTAssertFalse(fullContext.canInviteAnotherParticipant)
        XCTAssertFalse(
            ActiveCallInvitationPolicy.canInvite(
                recipientUserID: participantID(21),
                in: fullContext
            )
        )

        let availableContext = try XCTUnwrap(
            ActiveCallInvitationPolicy.context(
                for: presentation,
                calls: [
                    record(
                        id: callID,
                        state: .active,
                        offset: 1,
                        participantUserIds: Array(remoteParticipantIDs.dropLast())
                    ),
                ],
                currentUserID: currentUserID
            )
        )
        XCTAssertTrue(
            ActiveCallInvitationPolicy.canInvite(
                recipientUserID: participantID(21),
                in: availableContext
            )
        )
        XCTAssertFalse(
            ActiveCallInvitationPolicy.canInvite(
                recipientUserID: remoteParticipantIDs[0].uppercased(),
                in: availableContext
            )
        )
        XCTAssertFalse(
            ActiveCallInvitationPolicy.canInvite(
                recipientUserID: currentUserID,
                in: availableContext
            )
        )
    }

    func testActiveCallInvitationResponseMustRemainLiveUnboundAndContainRecipient() {
        let currentUserID = "10000000-0000-4000-8000-000000000001"
        let peerUserID = "20000000-0000-4000-8000-000000000001"
        let recipientUserID = "20000000-0000-4000-8000-000000000002"
        let callID = "30000000-0000-4000-8000-000000000001"
        let participantUserIDs = [peerUserID, recipientUserID.uppercased()]
        let expectedContext = ActiveCallInvitationContext(
            call: record(
                id: callID,
                state: .active,
                offset: 1,
                participantUserIds: [peerUserID]
            ),
            callID: callID,
            participantUserIDs: Set([currentUserID, peerUserID])
        )

        for state in ["ringing", "active"] {
            XCTAssertTrue(
                ActiveCallInvitationPolicy.accepts(
                    response: callDTO(
                        id: callID.uppercased(),
                        participantUserIds: participantUserIDs,
                        state: state
                    ),
                    expectedContext: expectedContext,
                    invitedRecipientID: recipientUserID,
                    currentUserID: currentUserID
                )
            )
        }

        let rejectedResponses = [
            callDTO(
                id: "30000000-0000-4000-8000-000000000099",
                participantUserIds: participantUserIDs,
                state: "active"
            ),
            callDTO(
                id: "not-a-call",
                participantUserIds: participantUserIDs,
                state: "active"
            ),
            callDTO(
                id: callID,
                participantUserIds: participantUserIDs,
                state: "completed"
            ),
            callDTO(
                id: callID,
                conversationId: "40000000-0000-4000-8000-000000000001",
                participantUserIds: participantUserIDs,
                state: "active"
            ),
            callDTO(
                id: callID,
                participantUserIds: [peerUserID],
                state: "active"
            ),
            callDTO(
                id: callID,
                participantUserIds: [recipientUserID],
                state: "active"
            ),
            callDTO(
                id: callID,
                participantUserIds: [currentUserID, peerUserID, recipientUserID],
                state: "active"
            ),
            callDTO(
                id: callID,
                participantUserIds: (1 ... 20).map(participantID) + [recipientUserID],
                state: "active"
            ),
        ]

        for response in rejectedResponses {
            XCTAssertFalse(
                ActiveCallInvitationPolicy.accepts(
                    response: response,
                    expectedContext: expectedContext,
                    invitedRecipientID: recipientUserID,
                    currentUserID: currentUserID
                )
            )
        }
    }

    func testWaitingMergeReconcilesOnlyAmbiguousInvitationOutcomes() {
        XCTAssertTrue(
            WaitingCallMergeInvitationReconciliationPolicy.shouldReconcile(
                after: APIErrorPayload(
                    code: "CALL_PARTICIPANTS_UNCHANGED",
                    message: "unchanged",
                    httpStatus: 409
                )
            )
        )
        XCTAssertTrue(
            WaitingCallMergeInvitationReconciliationPolicy.shouldReconcile(
                after: URLError(.timedOut)
            )
        )
        XCTAssertTrue(
            WaitingCallMergeInvitationReconciliationPolicy.shouldReconcile(
                after: APIClientError.invalidPayload(status: 200)
            )
        )
        XCTAssertTrue(
            WaitingCallMergeInvitationReconciliationPolicy.shouldReconcile(
                after: APIClientError.httpStatus(503)
            )
        )

        XCTAssertFalse(
            WaitingCallMergeInvitationReconciliationPolicy.shouldReconcile(
                after: APIErrorPayload(
                    code: "CALL_FULL",
                    message: "full",
                    httpStatus: 409
                )
            )
        )
        XCTAssertFalse(
            WaitingCallMergeInvitationReconciliationPolicy.shouldReconcile(
                after: APIClientError.httpStatus(403)
            )
        )
        XCTAssertFalse(
            WaitingCallMergeInvitationReconciliationPolicy.shouldReconcile(
                after: CancellationError()
            )
        )
    }

    func testWaitingMergeReadBackRequiresExactActiveRoster() {
        let currentUserID = "10000000-0000-4000-8000-000000000001"
        let peerUserID = "20000000-0000-4000-8000-000000000001"
        let waitingUserID = "20000000-0000-4000-8000-000000000002"
        let callID = "30000000-0000-4000-8000-000000000001"
        let expectedContext = ActiveCallInvitationContext(
            call: record(
                id: callID,
                state: .active,
                offset: 1,
                participantUserIds: [peerUserID]
            ),
            callID: callID,
            participantUserIDs: Set([currentUserID, peerUserID])
        )

        XCTAssertTrue(
            WaitingCallMergeInvitationReconciliationPolicy.accepts(
                response: callDTO(
                    id: callID.uppercased(),
                    participantUserIds: [peerUserID, waitingUserID.uppercased()],
                    state: "active"
                ),
                expectedContext: expectedContext,
                invitedRecipientID: waitingUserID,
                currentUserID: currentUserID
            )
        )
        XCTAssertFalse(
            WaitingCallMergeInvitationReconciliationPolicy.accepts(
                response: callDTO(
                    id: callID,
                    participantUserIds: [peerUserID, waitingUserID],
                    state: "ringing"
                ),
                expectedContext: expectedContext,
                invitedRecipientID: waitingUserID,
                currentUserID: currentUserID
            )
        )
        XCTAssertFalse(
            WaitingCallMergeInvitationReconciliationPolicy.accepts(
                response: callDTO(
                    id: callID,
                    participantUserIds: [peerUserID],
                    state: "active"
                ),
                expectedContext: expectedContext,
                invitedRecipientID: waitingUserID,
                currentUserID: currentUserID
            )
        )
        XCTAssertFalse(
            WaitingCallMergeInvitationReconciliationPolicy.accepts(
                response: callDTO(
                    id: callID,
                    participantUserIds: [waitingUserID],
                    state: "active"
                ),
                expectedContext: expectedContext,
                invitedRecipientID: waitingUserID,
                currentUserID: currentUserID
            )
        )
    }

    private func authenticatedIncomingCall(
        id: String,
        initiatorUserID: String?,
        participantUserIDs: [String]? = nil,
        ringExpiryDate: Date
    ) -> AuthenticatedIncomingCall {
        let participants = participantUserIDs
            ?? initiatorUserID.map { [$0] }
            ?? []
        return AuthenticatedIncomingCall(
            record: record(
                id: id,
                state: .ringing,
                offset: ringExpiryDate.timeIntervalSince1970 - 45,
                participantUserIds: participants,
                direction: "incoming"
            ),
            callUUID: UUID(uuidString: id)!,
            ringExpiryDate: ringExpiryDate,
            initiatorUserID: initiatorUserID
        )
    }

    private func authenticatedWaitingCall(
        id: String,
        initiatorUserID: String,
        ringExpiryDate: Date,
        routeAt: Date
    ) throws -> AuthenticatedWaitingCall {
        let incoming = authenticatedIncomingCall(
            id: id,
            initiatorUserID: initiatorUserID,
            ringExpiryDate: ringExpiryDate
        )
        let route = CallWaitingRoutingPolicy.route(
            incoming: incoming,
            activeCallID: "49000000-0000-4000-8000-000000000001",
            mediaState: .connected,
            now: routeAt
        )
        let waiting: AuthenticatedWaitingCall?
        if case .waiting(let value) = route {
            waiting = value
        } else {
            waiting = nil
        }
        return try XCTUnwrap(waiting)
    }

    private func callDTO(
        id: String,
        name: String = "Alice",
        conversationId: String? = nil,
        participantUserIds: [String] = ["550e8400-e29b-41d4-a716-446655440001"],
        direction: String = "outgoing",
        type: String = "voice",
        video: Bool = false,
        state: String = "ended",
        startedAt: String = "2026-08-18T12:00:00Z",
        ringExpiresAt: String? = nil
    ) -> CallDTO {
        CallDTO(
            id: id,
            conversationId: conversationId,
            name: name,
            participantUserIds: participantUserIds,
            direction: direction,
            type: type,
            video: video,
            state: state,
            startedAt: startedAt,
            answeredAt: nil,
            endedAt: ["ringing", "active"].contains(state.lowercased())
                ? nil
                : "2026-08-18T12:01:00Z",
            ringExpiresAt: ringExpiresAt
        )
    }

    private func participantID(_ index: Int) -> String {
        String(format: "50000000-0000-4000-8000-%012d", index)
    }

    private func record(
        id: String,
        state: CallState,
        offset: TimeInterval,
        participantUserIds: [String] = [],
        direction: String = "outgoing",
        video: Bool = false,
        conversationId: String? = nil,
        answeredAt: Date? = nil,
        endedAt: Date? = nil
    ) -> CallRecord {
        CallRecord(
            id: id,
            name: id,
            participantUserIds: participantUserIds,
            direction: direction,
            type: video ? "video" : "voice",
            video: video,
            state: state,
            startedAt: Date(timeIntervalSince1970: offset),
            endedAt: endedAt,
            isDeferredAttempt: state == .queued,
            conversationId: conversationId,
            answeredAt: answeredAt
        )
    }

    private func directConversation(
        id: String,
        currentUserID: String,
        peerUserID: String,
        updatedAt: TimeInterval
    ) -> Conversation {
        Conversation(
            id: id,
            title: "Alice",
            participantUserIds: [currentUserID, peerUserID],
            unreadCount: 0,
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }

    private func timelineMessage(
        id: String,
        conversationID: String,
        offset: TimeInterval
    ) -> LocalMessage {
        LocalMessage(
            id: UUID(uuidString: id)!,
            conversationId: conversationID,
            senderId: "10000000-0000-4000-8000-000000000001",
            body: id,
            createdAt: Date(timeIntervalSince1970: offset),
            sentAt: nil,
            state: .sent,
            failureReason: nil,
            isOutgoing: true
        )
    }

    private func contact(
        id: String,
        name: String,
        phone: String,
        kit: Bool
    ) -> WalletContactDTO {
        WalletContactDTO(
            id: id,
            contactId: nil,
            name: name,
            phone: phone,
            isKitUser: kit,
            favorite: false,
            status: nil,
            tag: nil,
            avatarURL: nil,
            receivingWalletId: nil
        )
    }

    private func ephemeralAttempt(clientCallID: String) -> EphemeralOutgoingCallAttempt {
        EphemeralOutgoingCallAttempt(
            clientCallID: UUID(uuidString: clientCallID)!,
            recipientUserID: "52000000-0000-4000-8000-000000000001",
            recipientName: "Alice",
            video: true,
            conversationID: "53000000-0000-4000-8000-000000000001",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            lease: CallMediaAccountLease(
                accountEpoch: UUID(uuidString: "54000000-0000-4000-8000-000000000001")!,
                userID: "55000000-0000-4000-8000-000000000001",
                sessionID: "session-a"
            )
        )
    }

    private func allPermutations<Element>(_ elements: [Element]) -> [[Element]] {
        guard elements.count > 1 else { return [elements] }
        var result: [[Element]] = []
        result.reserveCapacity((1 ... elements.count).reduce(1, *))
        for index in elements.indices {
            var remainder = elements
            let first = remainder.remove(at: index)
            result.append(contentsOf: allPermutations(remainder).map { [first] + $0 })
        }
        return result
    }
}

@MainActor
private final class FakeCallMediaTransport: CallMediaTransport {
    private(set) var connectedCallIds: [String] = []
    private(set) var disconnectCount = 0

    func connect(_ handoff: CallMediaHandoff) async throws {
        connectedCallIds.append(handoff.callId)
    }

    func disconnect() async {
        disconnectCount += 1
    }
}

@MainActor
private final class SuspendingCallMediaTransport: CallMediaTransport {
    private enum SimulatedSDKError: Error { case cancelledConnection }

    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var connectStartWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var disconnectCount = 0

    func connect(_ handoff: CallMediaHandoff) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connectContinuation = continuation
            let waiters = connectStartWaiters
            connectStartWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func disconnect() async {
        disconnectCount += 1
        let continuation = connectContinuation
        connectContinuation = nil
        continuation?.resume(throwing: SimulatedSDKError.cancelledConnection)
    }

    func waitUntilConnectStarts() async {
        guard connectContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            connectStartWaiters.append(continuation)
        }
    }
}

@MainActor
private final class SuspendingReplacementDisconnectCallMediaTransport: CallMediaTransport {
    private var replacementDisconnectContinuation: CheckedContinuation<Void, Never>?
    private var disconnectStartWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var connectedCallIds: [String] = []
    private(set) var disconnectCount = 0

    func connect(_ handoff: CallMediaHandoff) async throws {
        connectedCallIds.append(handoff.callId)
    }

    func disconnect() async {
        disconnectCount += 1
        guard disconnectCount == 1 else { return }
        await withCheckedContinuation { continuation in
            replacementDisconnectContinuation = continuation
            let waiters = disconnectStartWaiters
            disconnectStartWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilReplacementDisconnectStarts() async {
        guard replacementDisconnectContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            disconnectStartWaiters.append(continuation)
        }
    }

    func resumeReplacementDisconnect() {
        let continuation = replacementDisconnectContinuation
        replacementDisconnectContinuation = nil
        continuation?.resume()
    }
}

@MainActor
private final class OverlappingCallMediaTransport: CallMediaTransport {
    private let suspendingCallID: String
    private var connectContinuation: CheckedContinuation<Void, Never>?
    private var connectStartWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var connectedCallIds: [String] = []
    private(set) var disconnectCount = 0

    init(suspendingCallID: String) {
        self.suspendingCallID = suspendingCallID.lowercased()
    }

    func connect(_ handoff: CallMediaHandoff) async throws {
        connectedCallIds.append(handoff.callId)
        guard handoff.callId.caseInsensitiveCompare(suspendingCallID) == .orderedSame else {
            return
        }
        await withCheckedContinuation { continuation in
            connectContinuation = continuation
            let waiters = connectStartWaiters
            connectStartWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func disconnect() async {
        disconnectCount += 1
    }

    func waitUntilSuspendedConnectStarts() async {
        guard connectContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            connectStartWaiters.append(continuation)
        }
    }

    func resumeSuspendedConnectSuccessfully() {
        let continuation = connectContinuation
        connectContinuation = nil
        continuation?.resume()
    }
}

final class CallMediaIntentStateTests: XCTestCase {
    func testReconnectIntentRetainsMuteCameraAndCameraPositionChoices() {
        var intent = CallMediaIntentState(video: true)

        intent.setMicrophoneEnabled(false)
        intent.setCameraEnabled(false)
        intent.setFrontCamera(false)

        XCTAssertFalse(intent.microphoneEnabled)
        XCTAssertFalse(intent.cameraEnabled)
        XCTAssertFalse(intent.frontCamera)
    }

    func testAudioCallCanStageVideoEscalationBeforeReplacementRoomConnects() {
        var intent = CallMediaIntentState(video: false)
        XCTAssertFalse(intent.cameraEnabled)

        intent.setCameraEnabled(true)

        XCTAssertTrue(intent.cameraEnabled)
        XCTAssertTrue(intent.microphoneEnabled)
        XCTAssertTrue(intent.frontCamera)
    }

    func testBackgroundFirstVideoAnswerDefersOnlyTheCamera() {
        XCTAssertEqual(
            InitialCallCameraPolicy.plan(
                requestedVideo: true,
                authorizationStatus: .notDetermined,
                applicationIsActive: false
            ),
            InitialCallCameraPlan(
                enablesCameraImmediately: false,
                defersCameraUntilForeground: true
            )
        )
        XCTAssertEqual(
            InitialCallCameraPolicy.plan(
                requestedVideo: true,
                authorizationStatus: .authorized,
                applicationIsActive: false
            ),
            InitialCallCameraPlan(
                enablesCameraImmediately: false,
                defersCameraUntilForeground: true
            )
        )
    }

    func testForegroundVideoAndAudioCallsNeverUseTheDeferredCameraPath() {
        XCTAssertEqual(
            InitialCallCameraPolicy.plan(
                requestedVideo: true,
                authorizationStatus: .notDetermined,
                applicationIsActive: true
            ),
            InitialCallCameraPlan(
                enablesCameraImmediately: true,
                defersCameraUntilForeground: false
            )
        )
        XCTAssertEqual(
            InitialCallCameraPolicy.plan(
                requestedVideo: false,
                authorizationStatus: .notDetermined,
                applicationIsActive: false
            ),
            InitialCallCameraPlan(
                enablesCameraImmediately: false,
                defersCameraUntilForeground: false
            )
        )
    }

    func testDeniedOrRestrictedCameraStillAllowsAnAudioOnlyVideoCallJoin() {
        for authorizationStatus in [
            AVAuthorizationStatus.denied,
            .restricted,
        ] {
            XCTAssertEqual(
                InitialCallCameraPolicy.plan(
                    requestedVideo: true,
                    authorizationStatus: authorizationStatus,
                    applicationIsActive: true
                ),
                InitialCallCameraPlan(
                    enablesCameraImmediately: false,
                    defersCameraUntilForeground: false
                )
            )
        }
    }
}

final class CallVideoStatePolicyTests: XCTestCase {
    func testOriginallyVideoCallRemainsVideoWhileLocalCameraIsPaused() {
        XCTAssertTrue(
            CallVideoStatePolicy.carriesVideo(
                originalCallWasVideo: true,
                localCameraEnabled: false,
                remoteVideoAvailable: false
            )
        )
    }

    func testAudioCallTracksLocalAndRemoteVideoEscalation() {
        XCTAssertFalse(
            CallVideoStatePolicy.carriesVideo(
                originalCallWasVideo: false,
                localCameraEnabled: false,
                remoteVideoAvailable: false
            )
        )
        XCTAssertTrue(
            CallVideoStatePolicy.carriesVideo(
                originalCallWasVideo: false,
                localCameraEnabled: true,
                remoteVideoAvailable: false
            )
        )
        XCTAssertTrue(
            CallVideoStatePolicy.carriesVideo(
                originalCallWasVideo: false,
                localCameraEnabled: false,
                remoteVideoAvailable: true
            )
        )
    }
}

final class CallAudioRoutePolicyTests: XCTestCase {
    func testExternalOutputsWinOverTheBuiltInSpeakerAndReceiver() {
        XCTAssertEqual(
            CallAudioRoutePolicy.route(forOutputPortTypes: [.builtInSpeaker, .bluetoothHFP]),
            .bluetooth
        )
        XCTAssertEqual(
            CallAudioRoutePolicy.route(forOutputPortTypes: [.builtInReceiver, .headphones]),
            .wired
        )
        XCTAssertEqual(
            CallAudioRoutePolicy.route(forOutputPortTypes: [.builtInSpeaker, .carAudio]),
            .carAudio
        )
    }

    func testBuiltInRoutesAreClassifiedExactly() {
        XCTAssertEqual(
            CallAudioRoutePolicy.route(forOutputPortTypes: [.builtInSpeaker]),
            .speaker
        )
        XCTAssertEqual(
            CallAudioRoutePolicy.route(forOutputPortTypes: [.builtInReceiver]),
            .receiver
        )
        XCTAssertEqual(CallAudioRoutePolicy.route(forOutputPortTypes: []), .unknown)
    }

    func testWiredAndWirelessOutputsAllReportAsExternal() {
        for portType in [
            AVAudioSession.Port.bluetoothA2DP,
            .bluetoothLE,
            .bluetoothHFP,
            .headphones,
            .usbAudio,
            .lineOut,
            .HDMI,
            .displayPort,
            .airPlay,
            .carAudio,
        ] {
            let route = CallAudioRoutePolicy.route(forOutputPortTypes: [portType])
            XCTAssertTrue(
                route.isExternal,
                "\(portType.rawValue) must be treated as an external call route"
            )
            XCTAssertFalse(
                CallAudioRoutePolicy.speakerControlIsAvailable(for: route),
                "\(portType.rawValue) owns the audio, so the speaker override must stay unavailable"
            )
        }
    }

    func testSpeakerOverrideStaysAvailableOnBuiltInRoutes() {
        XCTAssertTrue(CallAudioRoutePolicy.speakerControlIsAvailable(for: .speaker))
        XCTAssertTrue(CallAudioRoutePolicy.speakerControlIsAvailable(for: .receiver))
        XCTAssertTrue(CallAudioRoutePolicy.speakerControlIsAvailable(for: .unknown))
    }

    func testExternalRoutePresentationsDoNotMislabelAirPlayDisplayOrUSBAsHeadphones() {
        XCTAssertEqual(
            CallAudioRoutePolicy.presentation(forOutputPortTypes: [.airPlay]),
            CallAudioRoutePresentation(
                route: .wired,
                symbolName: "airplayaudio",
                controlLabel: "Audio on AirPlay"
            )
        )
        XCTAssertEqual(
            CallAudioRoutePolicy.presentation(forOutputPortTypes: [.HDMI]),
            CallAudioRoutePresentation(
                route: .wired,
                symbolName: "tv",
                controlLabel: "Audio on a connected display"
            )
        )
        XCTAssertEqual(
            CallAudioRoutePolicy.presentation(forOutputPortTypes: [.usbAudio]),
            CallAudioRoutePresentation(
                route: .wired,
                symbolName: "cable.connector",
                controlLabel: "Audio on a USB audio device"
            )
        )
    }

    func testOnlyTheBuiltInSpeakerReportsSpeakerOn() {
        XCTAssertTrue(CallAudioRoute.speaker.isSpeaker)
        for route in [CallAudioRoute.receiver, .wired, .bluetooth, .carAudio, .unknown] {
            XCTAssertFalse(
                route.isSpeaker,
                "\(route) must not be presented as the built-in speaker"
            )
        }
    }
}

final class CallControlAvailabilityPolicyTests: XCTestCase {
    func testMuteAndSpeakerStayUsableWhileMediaReconnects() {
        XCTAssertTrue(
            CallControlAvailabilityPolicy.microphoneControlIsEnabled(
                isConnected: false,
                isReconnecting: true
            )
        )
        XCTAssertTrue(
            CallControlAvailabilityPolicy.speakerControlIsEnabled(
                isConnected: false,
                isReconnecting: true,
                route: .receiver
            )
        )
        XCTAssertTrue(
            CallControlAvailabilityPolicy.cameraControlIsEnabled(
                isConnected: false,
                isReconnecting: true
            )
        )
    }

    func testControlsAreUnavailableBeforeMediaExists() {
        XCTAssertFalse(
            CallControlAvailabilityPolicy.microphoneControlIsEnabled(
                isConnected: false,
                isReconnecting: false
            )
        )
        XCTAssertFalse(
            CallControlAvailabilityPolicy.speakerControlIsEnabled(
                isConnected: false,
                isReconnecting: false,
                route: .receiver
            )
        )
        XCTAssertFalse(
            CallControlAvailabilityPolicy.cameraControlIsEnabled(
                isConnected: false,
                isReconnecting: false
            )
        )
    }

    func testSpeakerControlIsUnavailableWhileAnExternalDeviceOwnsTheAudio() {
        for route in [CallAudioRoute.bluetooth, .wired, .carAudio] {
            XCTAssertFalse(
                CallControlAvailabilityPolicy.speakerControlIsEnabled(
                    isConnected: true,
                    isReconnecting: false,
                    route: route
                ),
                "\(route) must not be overridden by the in-call speaker control"
            )
        }
    }

    func testOptionsSheetStaysAvailableWhileMediaReconnects() {
        // It only records a microphone-mode preference, so it must not grey out exactly when the
        // customer reaches for it.
        XCTAssertTrue(
            CallControlAvailabilityPolicy.moreControlsAreEnabled(
                isConnected: true,
                isReconnecting: false
            )
        )
        XCTAssertTrue(
            CallControlAvailabilityPolicy.moreControlsAreEnabled(
                isConnected: false,
                isReconnecting: true
            )
        )
        XCTAssertFalse(
            CallControlAvailabilityPolicy.moreControlsAreEnabled(
                isConnected: false,
                isReconnecting: false
            )
        )
    }

    func testCallScreenWakePolicyKeepsVideoAwakeAndArmsProximityForAudio() {
        XCTAssertTrue(
            CallScreenWakePolicy.idleTimerDisabled(hasActiveCall: true, carriesVideo: true)
        )
        XCTAssertFalse(
            CallScreenWakePolicy.idleTimerDisabled(hasActiveCall: true, carriesVideo: false)
        )
        XCTAssertFalse(
            CallScreenWakePolicy.idleTimerDisabled(hasActiveCall: false, carriesVideo: true)
        )
        XCTAssertTrue(
            CallScreenWakePolicy.proximityMonitoringEnabled(
                hasActiveCall: true,
                carriesVideo: false,
                audioRoute: .receiver
            )
        )
        XCTAssertFalse(
            CallScreenWakePolicy.proximityMonitoringEnabled(
                hasActiveCall: true,
                carriesVideo: true,
                audioRoute: .receiver
            )
        )
        XCTAssertFalse(
            CallScreenWakePolicy.proximityMonitoringEnabled(
                hasActiveCall: false,
                carriesVideo: false,
                audioRoute: .receiver
            )
        )
        for route in [
            CallAudioRoute.speaker,
            .wired,
            .bluetooth,
            .carAudio,
            .unknown,
        ] {
            XCTAssertFalse(
                CallScreenWakePolicy.proximityMonitoringEnabled(
                    hasActiveCall: true,
                    carriesVideo: false,
                    audioRoute: route
                ),
                "\(route) must keep the screen available"
            )
        }
    }

}

final class TransientTransportErrorPolicyTests: XCTestCase {
    func testConnectivityFailuresAreTransient() {
        for code in [
            URLError.Code.timedOut,
            .cannotConnectToHost,
            .cannotFindHost,
            .dnsLookupFailed,
            .networkConnectionLost,
            .notConnectedToInternet,
            .internationalRoamingOff,
            .dataNotAllowed,
        ] {
            XCTAssertTrue(
                TransientTransportErrorPolicy.isTransient(URLError(code)),
                "\(code) is a connectivity failure the customer cannot act on"
            )
        }
    }

    func testServerAndDecodingFailuresAreNotTransient() {
        XCTAssertFalse(TransientTransportErrorPolicy.isTransient(URLError(.badServerResponse)))
        XCTAssertFalse(TransientTransportErrorPolicy.isTransient(URLError(.userAuthenticationRequired)))
        XCTAssertFalse(TransientTransportErrorPolicy.isTransient(CancellationError()))
        XCTAssertFalse(
            TransientTransportErrorPolicy.isTransient(
                NSError(domain: "africa.kit.pay", code: 500)
            )
        )
    }

    func testTransientFailuresUnwrapThroughAnUnderlyingError() {
        let wrapped = NSError(
            domain: "africa.kit.pay",
            code: 1,
            userInfo: [NSUnderlyingErrorKey: URLError(.timedOut) as NSError]
        )
        XCTAssertTrue(TransientTransportErrorPolicy.isTransient(wrapped))
    }

    func testOnlyAutomaticLoadsStaySilent() {
        // Launch and biometric-resume refreshes must not raise "The request timed out."; a refresh
        // the customer pulled asked a question and still gets an answer.
        XCTAssertTrue(
            TransientTransportErrorPolicy.shouldSuppressAutomatically(
                URLError(.timedOut),
                isUserInitiated: false
            )
        )
        XCTAssertFalse(
            TransientTransportErrorPolicy.shouldSuppressAutomatically(
                URLError(.timedOut),
                isUserInitiated: true
            )
        )
        XCTAssertFalse(
            TransientTransportErrorPolicy.shouldSuppressAutomatically(
                URLError(.badServerResponse),
                isUserInitiated: false
            )
        )
    }

    /// The call screen's backdrop is the caller's own profile photo, blurred. Portrait photos are
    /// much taller than they are wide, so filling a phone screen with one means a drawn width far
    /// greater than the screen's. If that width is ever reported as a layout size, the call screen
    /// takes it: the name, the avatar and the control bar all shift off the right edge — and only
    /// once the photo has finished loading, which is what made it look like a loading bug.
    @MainActor
    func testACallBackdropPhotoCannotWidenTheScreenItFills() {
        let screen = CGSize(width: 320, height: 640)
        let portraitPhoto = solidImage(size: CGSize(width: 1200, height: 1600))

        let backdrop = UIHostingController(
            rootView: KitFillingBackdrop {
                Image(uiImage: portraitPhoto)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 36)
                    .scaleEffect(1.24)
            }
        )
        XCTAssertEqual(backdrop.sizeThatFits(in: screen), screen)

        // And in the shape the call screen actually uses it: a stack takes the size of its largest
        // child, so the backdrop has to stay the size of the stack rather than of the photo.
        let callScreenShape = UIHostingController(
            rootView: ZStack {
                Color.black
                KitFillingBackdrop {
                    Image(uiImage: portraitPhoto)
                        .resizable()
                        .scaledToFill()
                }
                Text("Ringing…")
            }
        )
        XCTAssertEqual(callScreenShape.sizeThatFits(in: screen), screen)
    }

    private func solidImage(size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}
