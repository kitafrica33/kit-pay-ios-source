import AVFoundation
import CallKit
import Combine
import Foundation
import LiveKit
import UIKit

enum LiveKitCallMediaError: LocalizedError {
    case audioInitializationFailed
    case cameraSwitchUnavailable
    case permissionDenied(String)
    case permissionUnavailableInBackground(String)
    case mediaUnavailable
    case unsupportedDirection
    case speakerRouteUnavailable

    var errorDescription: String? {
        switch self {
        case .audioInitializationFailed:
            "Kit could not prepare call audio."
        case .cameraSwitchUnavailable:
            "Camera switching is unavailable on this device."
        case .permissionDenied(let medium):
            "Allow \(medium) access in Settings to use Kit calls."
        case .permissionUnavailableInBackground(let medium):
            "Open Kit Pay once and allow \(medium) access before answering calls in the background."
        case .mediaUnavailable:
            "Call media is not connected."
        case .unsupportedDirection:
            "Kit returned an unsupported call direction."
        case .speakerRouteUnavailable:
            "Audio is playing through a connected device. Disconnect it to use the speaker."
        }
    }
}

enum CallMediaDisconnectKind: Equatable, Sendable {
    case remoteEnded
    case retryable
    case terminalFailure
}

struct CallMediaReconnectPolicy {
    enum Action: Equatable {
        case reportRemoteEnd
        case rejoin
        case fail
    }

    /// LiveKit first performs its own quick/full reconnect sequence. These are a final,
    /// app-owned rejoin budget after the SDK has exhausted that sequence.
    static let retryDelaysNanoseconds: [UInt64] = [0, 1_000_000_000, 3_000_000_000]
    static let stableConnectionResetNanoseconds: UInt64 = 30_000_000_000

    static func action(for disconnect: CallMediaDisconnectKind) -> Action {
        switch disconnect {
        case .remoteEnded: .reportRemoteEnd
        case .retryable: .rejoin
        case .terminalFailure: .fail
        }
    }

    /// Attempts are one-based so an immediate first rejoin cannot accidentally become
    /// unbounded through an off-by-one error.
    static func delayNanoseconds(forAttempt attempt: Int) -> UInt64? {
        guard attempt > 0,
              retryDelaysNanoseconds.indices.contains(attempt - 1)
        else { return nil }
        return retryDelaysNanoseconds[attempt - 1]
    }
}

struct CallMediaDisconnectEvent: Sendable {
    let kind: CallMediaDisconnectKind
    let error: LiveKitError?
}

/// Typed local wake emitted only after the authenticated media owner reports a remote terminal
/// disconnect. AppModel uses the retained backend id to retire call waiting before refreshing,
/// even though the media presentation has already been cleared.
struct RemoteCallMediaEndedWake: Equatable, Sendable {
    let callId: String
}

enum RemoteVideoTrackVisibilityPolicy {
    static func shouldRender(
        isVideo: Bool,
        isMuted: Bool,
        hasRenderableTrack: Bool
    ) -> Bool {
        isVideo && !isMuted && hasRenderableTrack
    }
}

enum LiveKitRemoteVideoSource: Int, Equatable {
    case screenShare
    case camera
    case other
}

struct LiveKitRemoteVideoCandidate: Equatable {
    let publicationID: String
    let source: LiveKitRemoteVideoSource
    let isRenderable: Bool
}

struct LiveKitRemoteParticipantCandidate: Equatable {
    let identity: String
    let stableID: String
}

/// Pure ordering and selection rules for the dictionary-backed LiveKit participant/track state.
/// Stable ordering prevents tiles from moving whenever LiveKit rebuilds one of its dictionaries.
enum LiveKitRemoteParticipantPolicy {
    static func stableID(identity: String, participantSID: String?) -> String? {
        let identity = identity.trimmingCharacters(in: .whitespacesAndNewlines)
        if !identity.isEmpty { return identity }

        guard let participantSID = participantSID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !participantSID.isEmpty
        else { return nil }
        return "sid:\(participantSID)"
    }

    static func orderedParticipants(
        _ candidates: [LiveKitRemoteParticipantCandidate]
    ) -> [LiveKitRemoteParticipantCandidate] {
        candidates.sorted {
            participantsAreInAscendingOrder(
                lhsIdentity: $0.identity,
                lhsStableID: $0.stableID,
                rhsIdentity: $1.identity,
                rhsStableID: $1.stableID
            )
        }
    }

    static func orderedRenderableVideoCandidates(
        _ candidates: [LiveKitRemoteVideoCandidate]
    ) -> [LiveKitRemoteVideoCandidate] {
        candidates
            .filter(\.isRenderable)
            .sorted {
                videoCandidatesAreInAscendingOrder(
                    lhsSource: $0.source,
                    lhsPublicationID: $0.publicationID,
                    rhsSource: $1.source,
                    rhsPublicationID: $1.publicationID
                )
            }
    }

    static func participantsAreInAscendingOrder(
        lhsIdentity: String,
        lhsStableID: String,
        rhsIdentity: String,
        rhsStableID: String
    ) -> Bool {
        let lhsIdentityKey = canonicalSortKey(lhsIdentity)
        let rhsIdentityKey = canonicalSortKey(rhsIdentity)
        if lhsIdentityKey.isEmpty != rhsIdentityKey.isEmpty {
            return !lhsIdentityKey.isEmpty
        }
        if lhsIdentityKey != rhsIdentityKey {
            return lhsIdentityKey < rhsIdentityKey
        }

        let lhsStableKey = canonicalSortKey(lhsStableID)
        let rhsStableKey = canonicalSortKey(rhsStableID)
        if lhsStableKey != rhsStableKey {
            return lhsStableKey < rhsStableKey
        }
        return lhsStableID < rhsStableID
    }

    static func videoCandidatesAreInAscendingOrder(
        lhsSource: LiveKitRemoteVideoSource,
        lhsPublicationID: String,
        rhsSource: LiveKitRemoteVideoSource,
        rhsPublicationID: String
    ) -> Bool {
        if lhsSource.rawValue != rhsSource.rawValue {
            return lhsSource.rawValue < rhsSource.rawValue
        }
        let lhsID = canonicalSortKey(lhsPublicationID)
        let rhsID = canonicalSortKey(rhsPublicationID)
        if lhsID != rhsID { return lhsID < rhsID }
        return lhsPublicationID < rhsPublicationID
    }

    private static func canonicalSortKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct LiveKitRemoteParticipantSurface: Identifiable {
    let id: String
    let identity: String
    let name: String
    let cameraTrack: VideoTrack?
    let screenShareTrack: VideoTrack?
    let isSpeaking: Bool
    fileprivate let fallbackVideoTrack: VideoTrack?

    var preferredVideoTrack: VideoTrack? {
        screenShareTrack ?? cameraTrack ?? fallbackVideoTrack
    }

    var isScreenSharing: Bool { screenShareTrack != nil }
}

struct InitialCallCameraPlan: Equatable {
    let enablesCameraImmediately: Bool
    let defersCameraUntilForeground: Bool
}

/// Without the multitasking-camera entitlement, iOS cannot begin or continue camera capture while
/// a CallKit answer is handled in the background. A background video answer therefore joins with
/// audio, while retaining a one-shot request to publish the camera once the app becomes active.
enum InitialCallCameraPolicy {
    static func plan(
        requestedVideo: Bool,
        authorizationStatus: AVAuthorizationStatus,
        applicationIsActive: Bool
    ) -> InitialCallCameraPlan {
        guard requestedVideo else {
            return InitialCallCameraPlan(
                enablesCameraImmediately: false,
                defersCameraUntilForeground: false
            )
        }
        switch authorizationStatus {
        case .authorized, .notDetermined:
            return InitialCallCameraPlan(
                enablesCameraImmediately: applicationIsActive,
                defersCameraUntilForeground: !applicationIsActive
            )
        case .denied, .restricted:
            // A camera denial must not reject an otherwise valid audio join. The in-call Video
            // control remains available to explain the Settings requirement if it is tapped.
            return InitialCallCameraPlan(
                enablesCameraImmediately: false,
                defersCameraUntilForeground: false
            )
        @unknown default:
            return InitialCallCameraPlan(
                enablesCameraImmediately: false,
                defersCameraUntilForeground: false
            )
        }
    }
}

/// The user-selected media state that survives an app-owned room reconnect.
///
/// LiveKit tears the old room down before Kit obtains a replacement token. Keeping intent outside
/// that room lets Mute and Camera remain honest, responsive controls during the gap and gives the
/// replacement room one authoritative state to replay.
struct CallMediaIntentState: Equatable, Sendable {
    private(set) var microphoneEnabled: Bool
    private(set) var cameraEnabled: Bool
    private(set) var frontCamera: Bool

    init(video: Bool) {
        microphoneEnabled = true
        cameraEnabled = video
        frontCamera = true
    }

    mutating func setMicrophoneEnabled(_ enabled: Bool) {
        microphoneEnabled = enabled
    }

    mutating func setCameraEnabled(_ enabled: Bool) {
        cameraEnabled = enabled
    }

    mutating func setFrontCamera(_ enabled: Bool) {
        frontCamera = enabled
    }
}

/// A single video definition shared by CallKit and Picture in Picture.
///
/// An originally-video call remains a video call when the local camera is paused. An audio call is
/// promoted while either participant is publishing video and demoted only after both stop.
enum CallVideoStatePolicy {
    static func carriesVideo(
        originalCallWasVideo: Bool,
        localCameraEnabled: Bool,
        remoteVideoAvailable: Bool
    ) -> Bool {
        originalCallWasVideo || localCameraEnabled || remoteVideoAvailable
    }
}

enum KitMicrophoneMode: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case standard
    case voiceIsolation
    case wideSpectrum

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .standard: "Standard"
        case .voiceIsolation: "Voice Isolation"
        case .wideSpectrum: "Wide Spectrum"
        }
    }

    var detail: String {
        switch self {
        case .automatic: "Adapts processing for the current audio route"
        case .standard: "Balanced voice processing"
        case .voiceIsolation: "Prioritizes speech and reduces background noise"
        case .wideSpectrum: "Keeps more of the sound around you"
        }
    }

    var symbolName: String {
        switch self {
        case .automatic: "wand.and.stars"
        case .standard: "mic.fill"
        case .voiceIsolation: "person.wave.2.fill"
        case .wideSpectrum: "waveform"
        }
    }

    fileprivate var captureOptions: AudioCaptureOptions {
        let processing = audioProcessingOptions
        return AudioCaptureOptions(
            echoCancellation: processing.echoCancellation,
            autoGainControl: processing.autoGainControl,
            noiseSuppression: processing.noiseSuppression,
            highpassFilter: processing.highpassFilter,
            typingNoiseDetection: false,
            echoCancellationMode: processing.echoCancellationMode,
            autoGainControlMode: processing.autoGainControlMode,
            noiseSuppressionMode: processing.noiseSuppressionMode,
            highpassFilterMode: processing.highpassFilterMode
        )
    }

    var audioProcessingOptions: AudioProcessingOptions {
        switch self {
        case .automatic:
            AudioProcessingOptions()
        case .standard:
            AudioProcessingOptions(
                echoCancellation: true,
                autoGainControl: true,
                noiseSuppression: true,
                highpassFilter: false,
                echoCancellationMode: .software,
                autoGainControlMode: .software,
                noiseSuppressionMode: .software,
                highpassFilterMode: .software
            )
        case .voiceIsolation:
            AudioProcessingOptions(
                echoCancellation: true,
                autoGainControl: true,
                noiseSuppression: true,
                highpassFilter: true
            )
        case .wideSpectrum:
            AudioProcessingOptions(
                echoCancellation: true,
                autoGainControl: false,
                noiseSuppression: false,
                highpassFilter: false
            )
        }
    }
}

/// The concrete capture, playback, and rendering boundary. Backend call state remains in
/// `AppModel`; this object receives only short-lived LiveKit credentials.
/// The output the call audio is really using.
///
/// WhatsApp reports the live route rather than the last requested override, so a connected headset
/// or car kit is never shown as "speaker" and the speaker control never silently steals the call
/// away from the user's chosen device.
enum CallAudioRoute: Equatable, Sendable {
    case receiver
    case speaker
    case wired
    case bluetooth
    case carAudio
    case unknown

    /// A route the user selected outside the app. The speaker toggle must neither claim these are
    /// the speaker nor be offered as a way to override them.
    var isExternal: Bool {
        switch self {
        case .wired, .bluetooth, .carAudio: true
        case .receiver, .speaker, .unknown: false
        }
    }

    var isSpeaker: Bool { self == .speaker }
}

/// User-facing metadata for the exact active output while retaining the coarse route used to
/// decide whether Kit may safely override it.
struct CallAudioRoutePresentation: Equatable, Sendable {
    let route: CallAudioRoute
    let symbolName: String
    let controlLabel: String
}

/// Maps `AVAudioSession` output ports onto ``CallAudioRoute``. Kept separate from the transport so
/// route classification is unit-testable without an audio session.
enum CallAudioRoutePolicy {
    static func route(forOutputPortTypes portTypes: [AVAudioSession.Port]) -> CallAudioRoute {
        presentation(forOutputPortTypes: portTypes).route
    }

    static func presentation(
        forOutputPortTypes portTypes: [AVAudioSession.Port]
    ) -> CallAudioRoutePresentation {
        // iOS can list several outputs. An externally attached device always owns the call, so it
        // wins over the built-in receiver and speaker regardless of ordering.
        if portTypes.contains(where: {
            $0 == .bluetoothA2DP || $0 == .bluetoothHFP || $0 == .bluetoothLE
        }) {
            return CallAudioRoutePresentation(
                route: .bluetooth,
                symbolName: "headphones",
                controlLabel: "Audio on a connected Bluetooth device"
            )
        }
        if portTypes.contains(.carAudio) {
            return CallAudioRoutePresentation(
                route: .carAudio,
                symbolName: "car.fill",
                controlLabel: "Audio on car audio"
            )
        }
        if portTypes.contains(.airPlay) {
            return CallAudioRoutePresentation(
                route: .wired,
                symbolName: "airplayaudio",
                controlLabel: "Audio on AirPlay"
            )
        }
        if portTypes.contains(where: { $0 == .HDMI || $0 == .displayPort }) {
            return CallAudioRoutePresentation(
                route: .wired,
                symbolName: "tv",
                controlLabel: "Audio on a connected display"
            )
        }
        if portTypes.contains(.usbAudio) {
            return CallAudioRoutePresentation(
                route: .wired,
                symbolName: "cable.connector",
                controlLabel: "Audio on a USB audio device"
            )
        }
        if portTypes.contains(.headphones) {
            return CallAudioRoutePresentation(
                route: .wired,
                symbolName: "headphones",
                controlLabel: "Audio on connected headphones"
            )
        }
        if portTypes.contains(.lineOut) {
            return CallAudioRoutePresentation(
                route: .wired,
                symbolName: "cable.connector",
                controlLabel: "Audio on a connected audio device"
            )
        }
        if portTypes.contains(.builtInSpeaker) {
            return CallAudioRoutePresentation(
                route: .speaker,
                symbolName: "speaker.wave.3.fill",
                controlLabel: "Speaker"
            )
        }
        if portTypes.contains(.builtInReceiver) {
            return CallAudioRoutePresentation(
                route: .receiver,
                symbolName: "speaker.wave.2.fill",
                controlLabel: "Speaker"
            )
        }
        return CallAudioRoutePresentation(
            route: .unknown,
            symbolName: "speaker.wave.2.fill",
            controlLabel: "Speaker"
        )
    }

    static func route(for session: AVAudioSession) -> CallAudioRoute {
        route(forOutputPortTypes: session.currentRoute.outputs.map(\.portType))
    }

    static func presentation(for session: AVAudioSession) -> CallAudioRoutePresentation {
        presentation(forOutputPortTypes: session.currentRoute.outputs.map(\.portType))
    }

    /// Whether the in-call speaker control should be offered. An external route owns the audio, so
    /// the control is shown as unavailable instead of fighting the user's headset.
    static func speakerControlIsAvailable(for route: CallAudioRoute) -> Bool {
        !route.isExternal
    }
}

final class LiveKitCallMediaTransport: NSObject, ObservableObject, CallMediaTransport, RoomDelegate, @unchecked Sendable {
    private struct PendingCallKitMicrophoneIntent {
        let callId: String
        let enabled: Bool

        func belongs(to callId: String) -> Bool {
            self.callId.caseInsensitiveCompare(callId) == .orderedSame
        }
    }

    @Published private(set) var localVideoTrack: VideoTrack?
    @Published private(set) var remoteVideoTrack: VideoTrack?
    @Published private(set) var remoteParticipantSurfaces: [LiveKitRemoteParticipantSurface] = []
    @Published private(set) var isMicrophoneEnabled = false
    @Published private(set) var isCameraEnabled = false
    @Published private(set) var isSpeakerEnabled = false
    /// The route the audio session is really using, refreshed from `AVAudioSession` route changes.
    @Published private(set) var audioRoute: CallAudioRoute = .receiver
    @Published private(set) var audioRouteSymbolName = "speaker.wave.2.fill"
    @Published private(set) var audioRouteControlLabel = "Speaker"
    @Published private(set) var hasRemoteParticipant = false
    @Published private(set) var remoteParticipantConnectedAt: Date?
    @Published private(set) var microphoneMode: KitMicrophoneMode = .automatic
    @Published private(set) var canSwitchCamera = false
    @Published private(set) var isFrontCamera = true
    /// 0…1 voice-activity levels for UI pulse effects, fed by LiveKit's active-speaker updates.
    @Published private(set) var localVoiceLevel: Float = 0
    @Published private(set) var remoteVoiceLevel: Float = 0

    var onUnexpectedDisconnect: (@Sendable (String, CallMediaDisconnectEvent) -> Void)?
    var onSDKReconnectStateChanged: (@Sendable (String, Bool) -> Void)?
    var onRemoteParticipantConnected: (@Sendable (String, Date) -> Void)?

    private var room: Room?
    private var connectedCallId: String?
    private var mediaIntentCallId: String?
    private var mediaIntent = CallMediaIntentState(video: false)
    private var mediaIntentRevision: UInt64 = 0
    private var deferredInitialCameraCallId: String?
    /// CallKit can deliver mute before the authenticated media handoff creates a room. Bind that
    /// intent to its backend call so a canceled call can never mute a later replacement call.
    private var pendingCallKitMicrophoneIntent: PendingCallKitMicrophoneIntent?
    private var localAudioTrack: LocalAudioTrack?
    private var audioInitializationFailed = false
    /// Set while the session is configured for a call, so route changes only publish during one.
    private var audioSessionIsActive = false
    /// The speaker state the customer asked for, and whether they have asked at all. A deliberate
    /// choice must survive the category being rewritten when the camera is toggled mid-call.
    private var wantsSpeaker = false
    private var hasExplicitSpeakerPreference = false
    private var wantsVideoAudioMode = false
    private var routeChangeObserver: NSObjectProtocol?
    /// Fences every suspension inside LiveKit setup. A sign-out disconnect or a replacement call
    /// must prevent the older setup from publishing tracks or clearing the replacement's intent.
    private var connectionGeneration: UInt64 = 0

    private static let microphoneModePreferenceKey = "africa.kit.pay.call-microphone-mode"

    override init() {
        super.init()
        if let rawValue = UserDefaults.standard.string(forKey: Self.microphoneModePreferenceKey),
           let savedMode = KitMicrophoneMode(rawValue: rawValue) {
            microphoneMode = savedMode
        }
        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
        do {
            try AudioManager.shared.setEngineAvailability(.none)
        } catch {
            audioInitializationFailed = true
        }
        // Headsets, car kits, and AirPods arrive and leave mid-call. Without this the speaker
        // control keeps reporting the last requested override instead of the live route.
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAudioRoute() }
        }
    }

    deinit {
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
        }
    }

    @MainActor
    func connect(_ handoff: CallMediaHandoff) async throws {
        if audioInitializationFailed {
            // A one-time transport init failure must not latch every future call into
            // `audioInitializationFailed`; retry before giving up on this connect.
            do {
                try AudioManager.shared.setEngineAvailability(.none)
                audioInitializationFailed = false
            } catch {
                throw LiveKitCallMediaError.audioInitializationFailed
            }
        }
        connectionGeneration &+= 1
        let expectedGeneration = connectionGeneration
        let callId = handoff.callId.lowercased()
        let isRejoiningExistingCall = mediaIntentCallId?
            .caseInsensitiveCompare(callId) == .orderedSame
        if !isRejoiningExistingCall {
            let cameraPlan = InitialCallCameraPolicy.plan(
                requestedVideo: handoff.video,
                authorizationStatus: AVCaptureDevice.authorizationStatus(for: .video),
                applicationIsActive: UIApplication.shared.applicationState == .active
            )
            mediaIntentCallId = callId
            mediaIntent = CallMediaIntentState(video: cameraPlan.enablesCameraImmediately)
            if let pendingCallKitMicrophoneIntent,
               pendingCallKitMicrophoneIntent.belongs(to: callId) {
                mediaIntent.setMicrophoneEnabled(pendingCallKitMicrophoneIntent.enabled)
            }
            deferredInitialCameraCallId = cameraPlan.defersCameraUntilForeground ? callId : nil
            mediaIntentRevision &+= 1
            remoteParticipantConnectedAt = nil
        }
        pendingCallKitMicrophoneIntent = nil
        do {
            try await ensurePermissions(video: mediaIntent.cameraEnabled)
        } catch {
            if connectionGeneration == expectedGeneration,
               !isRejoiningExistingCall {
                resetMediaIntent()
            }
            throw error
        }
        guard connectionGeneration == expectedGeneration else {
            throw CancellationError()
        }
        let connectionRoom = Room(delegate: self)
        room = connectionRoom

        do {
            try await connectionRoom.connect(
                url: handoff.url.absoluteString,
                token: handoff.token
            )
            guard connectionGeneration == expectedGeneration,
                  room === connectionRoom
            else {
                throw LiveKitCallMediaError.mediaUnavailable
            }
            let appliedIntent = try await applyMediaIntent(
                in: connectionRoom,
                expectedGeneration: expectedGeneration
            )
            guard connectionGeneration == expectedGeneration,
                  room === connectionRoom
            else {
                throw LiveKitCallMediaError.mediaUnavailable
            }
            connectedCallId = callId
            updateRemoteParticipantPresence(in: connectionRoom)
            refreshRemoteParticipantSurfaces(in: connectionRoom)
            isMicrophoneEnabled = appliedIntent.microphoneEnabled
            isCameraEnabled = appliedIntent.cameraEnabled
            isFrontCamera = appliedIntent.frontCamera
        } catch {
            connectionRoom.remove(delegate: self)
            if connectionGeneration == expectedGeneration,
               room === connectionRoom {
                room = nil
                connectedCallId = nil
                resetPublishedMedia(preservingCallContinuity: isRejoiningExistingCall)
                if !isRejoiningExistingCall {
                    resetMediaIntent()
                }
            }
            await connectionRoom.disconnect()
            throw error
        }
    }

    /// Replays one stable snapshot of the user's media choices. If a control changes while an SDK
    /// operation is suspended, the revision changes and the replacement room is reconciled again
    /// before it is exposed as connected.
    @MainActor
    private func applyMediaIntent(
        in connectionRoom: Room,
        expectedGeneration: UInt64
    ) async throws -> CallMediaIntentState {
        while true {
            let intended = mediaIntent
            let intendedRevision = mediaIntentRevision
            let microphonePublication = try await connectionRoom.localParticipant.setMicrophone(
                enabled: intended.microphoneEnabled,
                captureOptions: microphoneMode.captureOptions
            )
            guard connectionGeneration == expectedGeneration,
                  room === connectionRoom
            else { throw LiveKitCallMediaError.mediaUnavailable }
            localAudioTrack = microphonePublication?.track as? LocalAudioTrack
            try? applyMicrophoneMode(to: localAudioTrack)

            if intended.cameraEnabled {
                try await ensurePermission(for: .video, label: "camera")
            }
            try await connectionRoom.localParticipant.setCamera(
                enabled: intended.cameraEnabled,
                captureOptions: intended.cameraEnabled
                    ? CameraCaptureOptions(position: intended.frontCamera ? .front : .back)
                    : nil
            )
            guard connectionGeneration == expectedGeneration,
                  room === connectionRoom
            else { throw LiveKitCallMediaError.mediaUnavailable }

            let cameraCanSwitch = intended.cameraEnabled
                ? ((try? await CameraCapturer.canSwitchPosition()) ?? false)
                : false
            guard connectionGeneration == expectedGeneration,
                  room === connectionRoom
            else { throw LiveKitCallMediaError.mediaUnavailable }
            guard intendedRevision == mediaIntentRevision else { continue }
            if !intended.cameraEnabled { localVideoTrack = nil }
            canSwitchCamera = cameraCanSwitch
            return intended
        }
    }

    @MainActor
    func disconnect() async {
        connectionGeneration &+= 1
        let disconnectingRoom = room
        room = nil
        connectedCallId = nil
        resetMediaIntent()
        resetPublishedMedia()
        disconnectingRoom?.remove(delegate: self)
        if let disconnectingRoom {
            await disconnectingRoom.disconnect()
        }
    }

    @MainActor
    func clearDisconnectedCallIntent(callId: String) {
        if pendingCallKitMicrophoneIntent?.belongs(to: callId) == true {
            pendingCallKitMicrophoneIntent = nil
            if mediaIntentCallId == nil {
                isMicrophoneEnabled = false
            }
        }
        guard room == nil,
              mediaIntentCallId?.caseInsensitiveCompare(callId) == .orderedSame
        else { return }
        resetMediaIntent()
        resetPublishedMedia()
    }

    @MainActor
    func preparePermissions(video: Bool) async throws {
        try await ensurePermissions(video: video)
    }

    @MainActor
    func prepareMicrophonePermission() async throws {
        try await ensurePermission(for: .audio, label: "microphone")
    }

    /// Consumes the one-shot camera intent retained by a background CallKit video answer. The
    /// ordinary camera control remains available if the customer declines the foreground prompt.
    @MainActor
    func resumeDeferredInitialCameraIfPossible(callId: String) async throws -> Bool {
        let canonicalCallID = callId.lowercased()
        guard UIApplication.shared.applicationState == .active,
              deferredInitialCameraCallId?.caseInsensitiveCompare(canonicalCallID) == .orderedSame,
              mediaIntentCallId?.caseInsensitiveCompare(canonicalCallID) == .orderedSame
        else { return false }
        // Consume before suspension so repeated foreground notifications cannot present duplicate
        // permission prompts. A denial leaves the normal in-call Video button as the retry path.
        deferredInitialCameraCallId = nil
        try await setCamera(enabled: true)
        return true
    }

    @MainActor
    func setMicrophone(enabled: Bool) async throws {
        guard mediaIntentCallId != nil else { throw LiveKitCallMediaError.mediaUnavailable }
        let previousIntent = mediaIntent.microphoneEnabled
        if mediaIntent.microphoneEnabled != enabled {
            mediaIntent.setMicrophoneEnabled(enabled)
            mediaIntentRevision &+= 1
        }
        guard let liveRoom = room, connectedCallId != nil else {
            // The old room has gone away and the reconnect loop owns replacement. Reflect and retain
            // the requested state now; `applyMediaIntent` publishes it before exposing the new room.
            isMicrophoneEnabled = enabled
            return
        }
        do {
            let publication = try await liveRoom.localParticipant.setMicrophone(enabled: enabled)
            guard room === liveRoom, connectedCallId != nil else {
                isMicrophoneEnabled = enabled
                return
            }
            if let track = publication?.track as? LocalAudioTrack {
                localAudioTrack = track
                try? applyMicrophoneMode(to: track)
            }
            isMicrophoneEnabled = enabled
        } catch {
            guard room === liveRoom, connectedCallId != nil else {
                isMicrophoneEnabled = enabled
                return
            }
            if mediaIntent.microphoneEnabled == enabled,
               previousIntent != enabled {
                mediaIntent.setMicrophoneEnabled(previousIntent)
                mediaIntentRevision &+= 1
            }
            throw error
        }
    }

    /// CallKit mute must never bounce: before the room is connected (pre-connect ring,
    /// mid-connect, app-level rejoin) the intent is recorded and applied by `connect`.
    @MainActor
    func applyCallKitMute(_ muted: Bool, callId: String) async throws {
        let enabled = !muted
        guard let mediaIntentCallId else {
            pendingCallKitMicrophoneIntent = PendingCallKitMicrophoneIntent(
                callId: callId.lowercased(),
                enabled: enabled
            )
            isMicrophoneEnabled = enabled
            return
        }
        guard mediaIntentCallId.caseInsensitiveCompare(callId) == .orderedSame else {
            throw LiveKitCallMediaError.mediaUnavailable
        }
        try await setMicrophone(enabled: enabled)
    }

    @MainActor
    func setMicrophoneMode(_ mode: KitMicrophoneMode) throws {
        // The mode is the customer's preference, not a property of one published track. Recording
        // it unconditionally — even while muted, still connecting, or mid-reconnect — is what keeps
        // the options sheet working; refusing with `mediaUnavailable` made the button look broken.
        // Whatever track the room publishes next picks the preference up.
        microphoneMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.microphoneModePreferenceKey)
        try applyMicrophoneMode(to: localAudioTrack)
    }

    @MainActor
    private func applyMicrophoneMode(to track: LocalAudioTrack?) throws {
        guard let track else { return }
        try track.setAudioProcessingOptions(microphoneMode.audioProcessingOptions)
    }

    @MainActor
    func setCamera(enabled: Bool) async throws {
        guard let expectedCallId = mediaIntentCallId else {
            throw LiveKitCallMediaError.mediaUnavailable
        }
        if enabled {
            try await ensurePermission(for: .video, label: "camera")
        }
        guard mediaIntentCallId?.caseInsensitiveCompare(expectedCallId) == .orderedSame else {
            throw LiveKitCallMediaError.mediaUnavailable
        }
        let previousIntent = mediaIntent.cameraEnabled
        if mediaIntent.cameraEnabled != enabled {
            mediaIntent.setCameraEnabled(enabled)
            mediaIntentRevision &+= 1
        }
        guard let liveRoom = room, connectedCallId != nil else {
            isCameraEnabled = enabled
            canSwitchCamera = false
            return
        }
        let captureOptions: CameraCaptureOptions? = enabled
            ? CameraCaptureOptions(position: mediaIntent.frontCamera ? .front : .back)
            : nil
        do {
            try await liveRoom.localParticipant.setCamera(
                enabled: enabled,
                captureOptions: captureOptions
            )
            guard room === liveRoom, connectedCallId != nil else {
                isCameraEnabled = enabled
                canSwitchCamera = false
                return
            }
            isCameraEnabled = enabled
            if !enabled { localVideoTrack = nil }
            canSwitchCamera = enabled
                ? ((try? await CameraCapturer.canSwitchPosition()) ?? false)
                : false
            updateCameraPosition()
        } catch {
            guard room === liveRoom, connectedCallId != nil else {
                isCameraEnabled = enabled
                canSwitchCamera = false
                return
            }
            if mediaIntent.cameraEnabled == enabled,
               previousIntent != enabled {
                mediaIntent.setCameraEnabled(previousIntent)
                mediaIntentRevision &+= 1
            }
            throw error
        }
    }

    @MainActor
    func switchCamera() async throws {
        guard isCameraEnabled,
              canSwitchCamera,
              let localTrack = localVideoTrack as? LocalVideoTrack,
              let cameraCapturer = localTrack.capturer as? CameraCapturer
        else {
            throw LiveKitCallMediaError.cameraSwitchUnavailable
        }
        _ = try await cameraCapturer.switchCameraPosition()
        isFrontCamera = cameraCapturer.position != .back
        if mediaIntent.frontCamera != isFrontCamera {
            mediaIntent.setFrontCamera(isFrontCamera)
            mediaIntentRevision &+= 1
        }
    }

    @MainActor
    func setSpeaker(enabled: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        // An attached headset, car kit, or AirPods set owns the call. Overriding to the built-in
        // speaker there would yank audio away from the device the user chose.
        guard CallAudioRoutePolicy.speakerControlIsAvailable(
            for: CallAudioRoutePolicy.route(for: session)
        ) else {
            refreshAudioRoute()
            throw LiveKitCallMediaError.speakerRouteUnavailable
        }
        wantsSpeaker = enabled
        hasExplicitSpeakerPreference = true
        // The category has to be rewritten, not just overridden.
        //
        // A video call was configured with `defaultToSpeaker`, which makes the speaker the
        // session's *default* route. `overrideOutputAudioPort(.none)` only clears an override and
        // falls back to that default, so turning the speaker off during a video call did nothing
        // at all. Dropping `defaultToSpeaker` first makes the earpiece the default again.
        try applyAudioCategory(session: session, video: wantsVideoAudioMode, speaker: enabled)
        try session.overrideOutputAudioPort(enabled ? .speaker : .none)
        refreshAudioRoute()
    }

    @MainActor
    func activateAudioSession(_ session: AVAudioSession, video: Bool) throws {
        wantsVideoAudioMode = video
        // A call that starts with video starts on the speaker, as it does everywhere else; the
        // customer can still turn it off, and that choice survives later reconfiguration.
        if !hasExplicitSpeakerPreference {
            wantsSpeaker = video
        }
        try applyAudioCategory(session: session, video: video, speaker: wantsSpeaker)
        try AudioManager.shared.setEngineAvailability(.default)
        audioSessionIsActive = true
        // Report the route the session actually settled on. Assuming "video means speaker" showed
        // speaker-on while the call was really playing through a connected headset.
        refreshAudioRoute()
    }

    @MainActor
    private func applyAudioCategory(
        session: AVAudioSession,
        video: Bool,
        speaker: Bool
    ) throws {
        // `allowBluetoothA2DP` and `allowAirPlay` keep an already-paired speaker, car kit, or
        // AirPlay receiver usable for the call instead of silently dropping to the earpiece.
        var options: AVAudioSession.CategoryOptions = [
            .allowBluetoothHFP,
            .allowBluetoothA2DP,
            .allowAirPlay,
        ]
        if speaker { options.insert(.defaultToSpeaker) }
        try session.setCategory(
            .playAndRecord,
            mode: video ? .videoChat : .voiceChat,
            options: options
        )
    }

    @MainActor
    func deactivateAudioSession() throws {
        audioSessionIsActive = false
        // The next call starts from the platform default again, not this call's speaker choice.
        wantsSpeaker = false
        hasExplicitSpeakerPreference = false
        wantsVideoAudioMode = false
        defer {
            isSpeakerEnabled = false
            audioRoute = .receiver
            audioRouteSymbolName = "speaker.wave.2.fill"
            audioRouteControlLabel = "Speaker"
        }
        try AudioManager.shared.setEngineAvailability(.none)
    }

    /// Publishes the live output route. Called on every `AVAudioSession` route change and after any
    /// deliberate override, so the speaker control always mirrors what the user is hearing.
    @MainActor
    func refreshAudioRoute() {
        guard audioSessionIsActive else { return }
        let presentation = CallAudioRoutePolicy.presentation(
            for: AVAudioSession.sharedInstance()
        )
        audioRoute = presentation.route
        audioRouteSymbolName = presentation.symbolName
        audioRouteControlLabel = presentation.controlLabel
        isSpeakerEnabled = presentation.route.isSpeaker
    }

    @MainActor
    private func ensurePermissions(video: Bool) async throws {
        try await ensurePermission(for: .audio, label: "microphone")
        if video {
            try await ensurePermission(for: .video, label: "camera")
        }
    }

    @MainActor
    private func ensurePermission(for mediaType: AVMediaType, label: String) async throws {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            return
        case .denied, .restricted:
            throw LiveKitCallMediaError.permissionDenied(label)
        case .notDetermined:
            guard UIApplication.shared.applicationState == .active else {
                throw LiveKitCallMediaError.permissionUnavailableInBackground(label)
            }
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: mediaType) { granted in
                    continuation.resume(returning: granted)
                }
            }
            guard granted else { throw LiveKitCallMediaError.permissionDenied(label) }
        @unknown default:
            throw LiveKitCallMediaError.permissionDenied(label)
        }
    }

    @MainActor
    private func resetMediaIntent() {
        mediaIntentCallId = nil
        mediaIntent = CallMediaIntentState(video: false)
        deferredInitialCameraCallId = nil
        pendingCallKitMicrophoneIntent = nil
        mediaIntentRevision &+= 1
    }

    @MainActor
    private func resetPublishedMedia(preservingCallContinuity: Bool = false) {
        localVideoTrack = nil
        remoteVideoTrack = nil
        remoteParticipantSurfaces = []
        localAudioTrack = nil
        if !preservingCallContinuity {
            isMicrophoneEnabled = false
            isCameraEnabled = false
            isSpeakerEnabled = false
            audioRoute = .receiver
            audioRouteSymbolName = "speaker.wave.2.fill"
            audioRouteControlLabel = "Speaker"
            remoteParticipantConnectedAt = nil
            isFrontCamera = true
        }
        hasRemoteParticipant = false
        canSwitchCamera = false
        localVoiceLevel = 0
        remoteVoiceLevel = 0
    }

    @MainActor
    private func updateCameraPosition() {
        guard let localTrack = localVideoTrack as? LocalVideoTrack,
              let cameraCapturer = localTrack.capturer as? CameraCapturer
        else { return }
        isFrontCamera = cameraCapturer.position != .back
    }

    @MainActor
    private func updateRemoteParticipantPresence(
        in observedRoom: Room,
        knownPresent: Bool = false
    ) {
        guard room === observedRoom else { return }
        let isPresent = knownPresent || !observedRoom.remoteParticipants.isEmpty
        hasRemoteParticipant = isPresent
        guard isPresent,
              remoteParticipantConnectedAt == nil,
              let connectedCallId
        else { return }
        let connectedAt = Date()
        remoteParticipantConnectedAt = connectedAt
        onRemoteParticipantConnected?(connectedCallId, connectedAt)
    }

    @MainActor
    private func refreshRemoteParticipantSurfaces(in observedRoom: Room) {
        guard room === observedRoom else { return }

        var surfaces: [LiveKitRemoteParticipantSurface] = []
        for (roomIdentity, participant) in observedRoom.remoteParticipants {
            let identity = roomIdentity.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let id = LiveKitRemoteParticipantPolicy.stableID(
                identity: identity,
                participantSID: participant.sid?.stringValue
            ) else { continue }

            var tracks: [(
                publicationID: String,
                source: LiveKitRemoteVideoSource,
                track: VideoTrack
            )] = []
            for publishedTrack in participant.videoTracks {
                guard let publication = publishedTrack as? RemoteTrackPublication,
                      let track = publication.track as? VideoTrack,
                      RemoteVideoTrackVisibilityPolicy.shouldRender(
                          isVideo: publication.kind == .video,
                          isMuted: publication.isMuted,
                          hasRenderableTrack: true
                      )
                else { continue }
                tracks.append(
                    (
                        publicationID: publication.sid.stringValue,
                        source: Self.videoSource(for: publication.source),
                        track: track
                    )
                )
            }
            tracks.sort { lhs, rhs in
                LiveKitRemoteParticipantPolicy.videoCandidatesAreInAscendingOrder(
                    lhsSource: lhs.source,
                    lhsPublicationID: lhs.publicationID,
                    rhsSource: rhs.source,
                    rhsPublicationID: rhs.publicationID
                )
            }

            var cameraTrack: VideoTrack?
            var screenShareTrack: VideoTrack?
            var fallbackVideoTrack: VideoTrack?
            for candidate in tracks {
                switch candidate.source {
                case .camera where cameraTrack == nil:
                    cameraTrack = candidate.track
                case .screenShare where screenShareTrack == nil:
                    screenShareTrack = candidate.track
                case .other where fallbackVideoTrack == nil:
                    fallbackVideoTrack = candidate.track
                default:
                    break
                }
            }

            surfaces.append(
                LiveKitRemoteParticipantSurface(
                    id: id,
                    identity: identity,
                    name: participant.name ?? "Kit Pay contact",
                    cameraTrack: cameraTrack,
                    screenShareTrack: screenShareTrack,
                    isSpeaking: participant.isSpeaking,
                    fallbackVideoTrack: fallbackVideoTrack
                )
            )
        }
        surfaces.sort { lhs, rhs in
            LiveKitRemoteParticipantPolicy.participantsAreInAscendingOrder(
                lhsIdentity: lhs.identity,
                lhsStableID: lhs.id,
                rhsIdentity: rhs.identity,
                rhsStableID: rhs.id
            )
        }

        remoteParticipantSurfaces = surfaces
        var preferredTrack: VideoTrack?
        for surface in surfaces where preferredTrack == nil {
            preferredTrack = surface.screenShareTrack
        }
        for surface in surfaces where preferredTrack == nil {
            preferredTrack = surface.cameraTrack
        }
        for surface in surfaces where preferredTrack == nil {
            preferredTrack = surface.fallbackVideoTrack
        }
        if remoteVideoTrack !== preferredTrack {
            remoteVideoTrack = preferredTrack
        }
    }

    private static func videoSource(for source: Track.Source) -> LiveKitRemoteVideoSource {
        switch source {
        case .screenShareVideo: .screenShare
        case .camera: .camera
        default: .other
        }
    }

    func room(
        _ room: Room,
        participant: LocalParticipant,
        didPublishTrack publication: LocalTrackPublication
    ) {
        guard let track = publication.track as? VideoTrack else { return }
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            self.localVideoTrack = track
            self.updateCameraPosition()
        }
    }

    func room(
        _ room: Room,
        participant: RemoteParticipant,
        didSubscribeTrack publication: RemoteTrackPublication
    ) {
        guard publication.kind == .video else { return }
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            self.updateRemoteParticipantPresence(in: room, knownPresent: true)
            self.refreshRemoteParticipantSurfaces(in: room)
        }
    }

    func room(
        _ room: Room,
        participant: RemoteParticipant,
        didPublishTrack publication: RemoteTrackPublication
    ) {
        guard publication.kind == .video else { return }
        Task { @MainActor [weak self] in
            self?.refreshRemoteParticipantSurfaces(in: room)
        }
    }

    func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.updateRemoteParticipantPresence(in: room, knownPresent: true)
            self.refreshRemoteParticipantSurfaces(in: room)
        }
    }

    func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            self.hasRemoteParticipant = !room.remoteParticipants.isEmpty
            self.refreshRemoteParticipantSurfaces(in: room)
        }
    }

    func room(
        _ room: Room,
        participant: RemoteParticipant,
        didUnsubscribeTrack publication: RemoteTrackPublication
    ) {
        guard publication.kind == .video else { return }
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            self.refreshRemoteParticipantSurfaces(in: room)
        }
    }

    func room(
        _ room: Room,
        participant: RemoteParticipant,
        didUnpublishTrack publication: RemoteTrackPublication
    ) {
        guard publication.kind == .video else { return }
        Task { @MainActor [weak self] in
            self?.refreshRemoteParticipantSurfaces(in: room)
        }
    }

    func room(
        _ room: Room,
        participant: Participant,
        trackPublication publication: TrackPublication,
        didUpdateIsMuted _: Bool
    ) {
        guard participant is RemoteParticipant,
              publication is RemoteTrackPublication,
              publication.kind == .video
        else { return }
        Task { @MainActor [weak self] in
            self?.refreshRemoteParticipantSurfaces(in: room)
        }
    }

    func room(_ room: Room, didUpdateSpeakingParticipants participants: [Participant]) {
        // Participants absent from the array have stopped speaking, so recomputing from the
        // array alone naturally decays their level back to 0.
        var localLevel: Float = 0
        var remoteLevel: Float = 0
        for participant in participants {
            let level = min(max(participant.audioLevel, 0), 1)
            if participant is LocalParticipant {
                localLevel = max(localLevel, level)
            } else {
                remoteLevel = max(remoteLevel, level)
            }
        }
        let local = localLevel
        let remote = remoteLevel
        Task { @MainActor [weak self] in
            guard let self, self.room === room else { return }
            self.localVoiceLevel = local
            self.remoteVoiceLevel = remote
            self.refreshRemoteParticipantSurfaces(in: room)
        }
    }

    func room(_ room: Room, participant: Participant, didUpdateName _: String) {
        guard participant is RemoteParticipant else { return }
        Task { @MainActor [weak self] in
            self?.refreshRemoteParticipantSurfaces(in: room)
        }
    }

    func room(_ room: Room, didStartReconnectWithMode _: ReconnectMode) {
        Task { @MainActor [weak self] in
            guard let self,
                  self.room === room,
                  let callId = self.connectedCallId
            else { return }
            self.onSDKReconnectStateChanged?(callId, true)
        }
    }

    func room(_ room: Room, didCompleteReconnectWithMode _: ReconnectMode) {
        Task { @MainActor [weak self] in
            guard let self,
                  self.room === room,
                  let callId = self.connectedCallId
            else { return }
            self.updateRemoteParticipantPresence(in: room)
            self.refreshRemoteParticipantSurfaces(in: room)
            self.onSDKReconnectStateChanged?(callId, false)
        }
    }

    func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.room === room else { return }
            self.room = nil
            let callId = connectedCallId
            connectedCallId = nil
            let event = CallMediaDisconnectEvent(
                kind: Self.disconnectKind(for: error),
                error: error
            )
            let preservesContinuity = event.kind == .retryable
            resetPublishedMedia(preservingCallContinuity: preservesContinuity)
            if !preservesContinuity {
                resetMediaIntent()
            }
            guard let callId else { return }
            onUnexpectedDisconnect?(callId, event)
        }
    }

    private static func disconnectKind(for error: LiveKitError?) -> CallMediaDisconnectKind {
        guard let error else { return .remoteEnded }
        switch error.type {
        case .cancelled, .participantRemoved, .roomDeleted:
            return .remoteEnded
        case .network, .timedOut, .webRTC, .serverShutdown, .stateMismatch,
             .joinFailure, .serverPingTimedOut:
            return .retryable
        default:
            return .terminalFailure
        }
    }
}

@MainActor
final class CallMediaCoordinator: ObservableObject {
    enum State: Equatable {
        case idle, preparing, connecting, reconnecting, connected, ending
    }

    static let shared = CallMediaCoordinator()

    /// How long a connected call waits for the remote participant to return before ending
    /// cleanly instead of running forever after a hang-up that never tore down the room.
    static let remoteAbsenceGraceNanoseconds: UInt64 = 20_000_000_000

    @Published private(set) var activeCall: ActiveCallPresentation?
    @Published private(set) var state: State = .idle
    @Published private(set) var controlError: String?

    let media: LiveKitCallMediaTransport

    private let session: CallMediaSessionDriver
    private var activeHandoff: CallMediaHandoff?
    private var pendingOutgoingClientCallID: String?
    private var accountLeaseGate = CallMediaAccountLeaseGate()
    private var activeAccountLease: CallMediaAccountLease?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectStabilityTask: Task<Void, Never>?
    private var reconnectGeneration: UInt64 = 0
    private var reconnectAttemptsRemaining = CallMediaReconnectPolicy.retryDelaysNanoseconds.count
    private var remoteAbsenceTask: Task<Void, Never>?
    private var remotePresenceCancellable: AnyCancellable?

    private init() {
        let media = LiveKitCallMediaTransport()
        self.media = media
        session = CallMediaSessionDriver(transport: media)
        media.onUnexpectedDisconnect = { [weak self] callId, event in
            Task { @MainActor in
                await self?.handleUnexpectedDisconnect(callId: callId, event: event)
            }
        }
        media.onSDKReconnectStateChanged = { [weak self] callId, isReconnecting in
            Task { @MainActor in
                self?.handleSDKReconnectStateChanged(
                    callId: callId,
                    isReconnecting: isReconnecting
                )
            }
        }
        media.onRemoteParticipantConnected = { callId, connectedAt in
            Task { @MainActor in
                NotificationCoordinator.shared.reportOutgoingCallConnected(
                    callId: callId,
                    connectedAt: connectedAt
                )
            }
        }
        remotePresenceCancellable = media.$hasRemoteParticipant
            .removeDuplicates()
            .sink { [weak self] isPresent in
                Task { @MainActor in
                    self?.handleRemotePresenceChanged(isPresent)
                }
            }
    }

    deinit {
        reconnectTask?.cancel()
        reconnectStabilityTask?.cancel()
        remoteAbsenceTask?.cancel()
    }

    var statusText: String {
        switch state {
        case .idle: "Call ended"
        case .preparing: "Preparing secure media…"
        case .connecting: "Connecting…"
        case .reconnecting: "Reconnecting…"
        case .connected: "Connected"
        case .ending: "Ending…"
        }
    }

    @discardableResult
    func activateAccountLease(_ lease: CallMediaAccountLease) -> Bool {
        accountLeaseGate.activate(lease)
    }

    /// Synchronously revokes matching admission before the first suspension, then tears down
    /// capture/playback. A suspended connect becomes stale through the session generation, while
    /// a delayed sign-out from another lease cannot reset replacement-account media.
    func resetForSignOut(revoking lease: CallMediaAccountLease?) async {
        if let authorizedLease = accountLeaseGate.authorizedLease,
           let lease,
           authorizedLease != lease {
            return
        }
        accountLeaseGate.revoke(lease)
        let disconnectedCallID = activeCall?.id ?? session.activeCallId
        activeAccountLease = nil
        activeHandoff = nil
        pendingOutgoingClientCallID = nil
        activeCall = nil
        invalidateReconnect()
        controlError = nil
        state = .idle
        retireCallPresentationSurfaces()
        await session.reset()
        if accountLeaseGate.authorizedLease == nil,
           let disconnectedCallID {
            media.clearDisconnectedCallIntent(callId: disconnectedCallID)
        }
    }

    func consumeAuthenticated(_ request: AuthenticatedCallMediaHandoff) async {
        guard accountLeaseGate.accepts(request.lease) else { return }
        // An authenticated outgoing response may replace a provisional screen only through the
        // exact client-call-ID promotion method below. This prevents a late retry from taking over
        // a newer in-memory attempt.
        guard request.handoff.direction != "outgoing" || pendingOutgoingClientCallID == nil
        else { return }
        activeAccountLease = request.lease
        activeHandoff = request.handoff
        activeCall = ActiveCallPresentation(request.handoff)
        state = .preparing
        switch request.handoff.direction {
        case "outgoing":
            NotificationCoordinator.shared.requestStartOutgoingCall(request)
        case "incoming":
            do {
                try await connectAuthenticated(request)
            } catch {
                // `connectAuthenticated` records current-account failures and ignores revoked ones.
            }
        default:
            await fail(
                callId: request.handoff.callId,
                error: LiveKitCallMediaError.unsupportedDirection,
                lease: request.lease
            )
        }
    }

    func connectAuthenticated(_ request: AuthenticatedCallMediaHandoff) async throws {
        guard accountLeaseGate.accepts(request.lease) else { throw CancellationError() }
        let handoff = request.handoff
        invalidateReconnect()
        resetReconnectBudget()
        activeHandoff = handoff
        activeAccountLease = request.lease
        activeCall = ActiveCallPresentation(handoff)
        state = .connecting
        controlError = nil
        do {
            try await session.connect(handoff)
            guard accountLeaseGate.accepts(request.lease),
                  activeAccountLease == request.lease
            else {
                await session.disconnect(callId: handoff.callId)
                throw CancellationError()
            }
            state = .connected
        } catch is CancellationError {
            clearPresentation(callId: handoff.callId)
            throw CancellationError()
        } catch {
            await fail(callId: handoff.callId, error: error, lease: request.lease)
            throw error
        }
    }

    func preparePermissions(video: Bool) async throws {
        try await media.preparePermissions(video: video)
    }

    func prepareMicrophonePermission() async throws {
        try await media.prepareMicrophonePermission()
    }

    /// Completes a video answer that intentionally joined audio-first while iOS could not show its
    /// initial camera permission prompt in the background.
    func resumeDeferredInitialCameraIfPossible() async {
        guard let activeCall,
              activeCall.video,
              state != .idle,
              state != .ending
        else { return }
        do {
            guard try await media.resumeDeferredInitialCameraIfPossible(callId: activeCall.id)
            else { return }
            try media.activateAudioSession(
                AVAudioSession.sharedInstance(),
                video: callCarriesVideo
            )
            refreshCallKitVideoState()
            CallOverlayWindowController.shared.refreshPictureInPicture()
            controlError = nil
        } catch is CancellationError {
            return
        } catch {
            controlError = error.localizedDescription
        }
    }

    /// Presents a local call immediately without touching CallKit, LiveKit, or persistent state.
    /// CallKit admission (and therefore ringback) occurs only after the server response is promoted.
    @discardableResult
    func presentPendingOutgoing(
        _ presentation: ActiveCallPresentation,
        lease: CallMediaAccountLease
    ) -> Bool {
        guard presentation.direction == "outgoing",
              accountLeaseGate.accepts(lease),
              activeCall == nil,
              activeHandoff == nil,
              session.activeCallId == nil,
              pendingOutgoingClientCallID == nil
        else { return false }
        activeAccountLease = lease
        pendingOutgoingClientCallID = presentation.id.lowercased()
        activeCall = presentation
        state = .connecting
        controlError = nil
        return true
    }

    /// Atomically swaps the provisional client ID for the authenticated backend call. No await
    /// occurs between the identity check and CallKit registration, closing the user-end race.
    @discardableResult
    func promotePendingOutgoing(
        clientCallID: String,
        request: AuthenticatedCallMediaHandoff
    ) -> Bool {
        guard request.handoff.direction == "outgoing",
              accountLeaseGate.accepts(request.lease),
              activeAccountLease == request.lease,
              pendingOutgoingClientCallID?.caseInsensitiveCompare(clientCallID) == .orderedSame,
              activeCall?.id.caseInsensitiveCompare(clientCallID) == .orderedSame,
              activeHandoff == nil,
              session.activeCallId == nil
        else { return false }
        pendingOutgoingClientCallID = nil
        activeHandoff = request.handoff
        activeCall = ActiveCallPresentation(request.handoff)
        state = .preparing
        controlError = nil
        NotificationCoordinator.shared.requestStartOutgoingCall(request)
        return true
    }

    /// Cancels a provisional screen without generating a CallKit action or backend termination.
    /// Only AppModel's exact account-bound attempt may dismiss it.
    func dismissPendingOutgoing(
        clientCallID: String,
        lease: CallMediaAccountLease
    ) {
        guard accountLeaseGate.accepts(lease),
              activeAccountLease == lease,
              pendingOutgoingClientCallID?.caseInsensitiveCompare(clientCallID) == .orderedSame,
              activeCall?.id.caseInsensitiveCompare(clientCallID) == .orderedSame
        else { return }
        pendingOutgoingClientCallID = nil
        activeAccountLease = nil
        activeCall = nil
        state = .idle
        controlError = nil
    }

    /// A cancelled duplicate start request can still deliver the same idempotent server response.
    /// Never terminate that response when it names the authenticated call already admitted here.
    func ownsAuthenticatedCall(callID: String, lease: CallMediaAccountLease) -> Bool {
        guard accountLeaseGate.accepts(lease),
              activeAccountLease == lease,
              pendingOutgoingClientCallID == nil
        else { return false }
        return activeHandoff?.callId.caseInsensitiveCompare(callID) == .orderedSame
            || session.activeCallId?.caseInsensitiveCompare(callID) == .orderedSame
            || activeCall?.id.caseInsensitiveCompare(callID) == .orderedSame
    }

    /// Presents the app's connecting screen as soon as CallKit accepts an incoming answer. The
    /// authenticated accept request can then run without leaving a blank app behind CallKit.
    func presentConnecting(
        _ presentation: ActiveCallPresentation,
        lease: CallMediaAccountLease
    ) {
        guard accountLeaseGate.accepts(lease) else { return }
        guard activeCall == nil
                || activeCall?.id.caseInsensitiveCompare(presentation.id) == .orderedSame
        else { return }
        activeAccountLease = lease
        activeCall = presentation
        state = .connecting
        controlError = nil
    }

    func disconnectFromCallKit(callId: String) async {
        let presentationMatches = activeCall?.id.caseInsensitiveCompare(callId) == .orderedSame
        let sessionMatches = session.activeCallId?.caseInsensitiveCompare(callId) == .orderedSame
        guard presentationMatches || sessionMatches else {
            media.clearDisconnectedCallIntent(callId: callId)
            return
        }
        invalidateReconnect()
        state = .ending
        await session.disconnect(callId: callId)
        media.clearDisconnectedCallIntent(callId: callId)
        clearPresentation(callId: callId)
    }

    func callKitStartFailed(_ request: AuthenticatedCallMediaHandoff, error: Error) async {
        guard accountLeaseGate.accepts(request.lease) else { return }
        await fail(callId: request.handoff.callId, error: error, lease: request.lease)
    }

    func recordControlError(_ error: Error) {
        controlError = error.localizedDescription
    }

    func requestEnd() {
        guard let callId = activeCall?.id else { return }
        if pendingOutgoingClientCallID?.caseInsensitiveCompare(callId) == .orderedSame {
            pendingOutgoingClientCallID = nil
            activeAccountLease = nil
            activeCall = nil
            state = .idle
            controlError = nil
            retireCallPresentationSurfaces()
            NotificationCenter.default.post(
                name: .kitPendingOutgoingCallEnded,
                object: callId
            )
            return
        }
        invalidateReconnect()
        state = .ending
        NotificationCoordinator.shared.requestEndCall(callId: callId)
    }

    func requestMuted(_ muted: Bool) {
        guard let callId = activeCall?.id else { return }
        NotificationCoordinator.shared.requestMuted(muted, callId: callId)
    }

    func setMicrophone(enabled: Bool) async throws {
        do {
            try await media.setMicrophone(enabled: enabled)
            controlError = nil
        } catch {
            controlError = error.localizedDescription
            throw error
        }
    }

    /// System-UI (CallKit) mute: succeeds by buffering the intent while the room is not yet
    /// connected instead of bouncing the toggle back with `.mediaUnavailable`.
    func applyCallKitMute(_ muted: Bool, callId: String) async throws {
        do {
            try await media.applyCallKitMute(muted, callId: callId)
            controlError = nil
        } catch {
            controlError = error.localizedDescription
            throw error
        }
    }

    func toggleCamera() async {
        let enabling = !media.isCameraEnabled
        do {
            try await media.setCamera(enabled: enabling)
            do {
                try media.activateAudioSession(
                    AVAudioSession.sharedInstance(),
                    video: callCarriesVideo
                )
            } catch {
                try? await media.setCamera(enabled: !enabling)
                throw error
            }
            refreshCallKitVideoState()
            // An audio call that escalates to video gains the Picture in Picture hand-off. The same
            // shared policy also removes it if an escalated call no longer has either video track.
            CallOverlayWindowController.shared.refreshPictureInPicture()
            controlError = nil
        } catch {
            controlError = error.localizedDescription
        }
    }

    var callCarriesVideo: Bool {
        CallVideoStatePolicy.carriesVideo(
            originalCallWasVideo: activeCall?.video == true,
            localCameraEnabled: media.isCameraEnabled,
            remoteVideoAvailable: media.remoteVideoTrack != nil
        )
    }

    /// Keeps CallKit's Lock Screen, Dynamic Island, and Recents projection aligned with the same
    /// video definition used for in-app presentation and Picture in Picture.
    func refreshCallKitVideoState() {
        guard let callId = activeCall?.id else { return }
        NotificationCoordinator.shared.reportCallVideoChanged(
            callId: callId,
            hasVideo: callCarriesVideo
        )
    }

    func switchCamera() async {
        do {
            try await media.switchCamera()
            controlError = nil
        } catch {
            controlError = error.localizedDescription
        }
    }

    func toggleSpeaker() {
        do {
            try media.setSpeaker(enabled: !media.isSpeakerEnabled)
            controlError = nil
        } catch {
            controlError = error.localizedDescription
        }
    }

    /// Whether the in-call speaker control can act. An external route owns the audio, so the
    /// control is presented as unavailable rather than fighting the connected device.
    var speakerControlIsAvailable: Bool {
        CallAudioRoutePolicy.speakerControlIsAvailable(for: media.audioRoute)
    }

    func setMicrophoneMode(_ mode: KitMicrophoneMode) {
        do {
            try media.setMicrophoneMode(mode)
            controlError = nil
        } catch {
            controlError = error.localizedDescription
        }
    }

    func activateAudioSession(_ audioSession: AVAudioSession, video: Bool? = nil) throws {
        try media.activateAudioSession(
            audioSession,
            video: video ?? (activeCall?.video == true)
        )
    }

    func deactivateAudioSession() throws {
        try media.deactivateAudioSession()
    }

    private func fail(
        callId: String,
        error: Error,
        lease: CallMediaAccountLease
    ) async {
        guard accountLeaseGate.accepts(lease),
              activeAccountLease == lease
        else { return }
        await session.disconnect(callId: callId)
        guard accountLeaseGate.accepts(lease),
              activeAccountLease == lease
        else { return }
        media.clearDisconnectedCallIntent(callId: callId)
        clearPresentation(callId: callId)
        NotificationCoordinator.shared.reportMediaConnectionFailed(callId: callId)
        NotificationCenter.default.post(
            name: .kitCallMediaFailed,
            object: CallMediaFailure(
                lease: lease,
                callId: callId,
                message: error.localizedDescription
            )
        )
    }

    private func handleUnexpectedDisconnect(
        callId: String,
        event: CallMediaDisconnectEvent
    ) async {
        session.didDisconnect(callId: callId)
        guard let lease = activeAccountLease,
              accountLeaseGate.accepts(lease),
              activeCall?.id.caseInsensitiveCompare(callId) == .orderedSame,
              state != .ending
        else { return }

        switch CallMediaReconnectPolicy.action(for: event.kind) {
        case .reportRemoteEnd:
            clearPresentation(callId: callId)
            NotificationCoordinator.shared.reportRemoteCallEnded(callId: callId)
            NotificationCenter.default.post(
                name: .kitRemoteWakeReceived,
                object: RemoteCallMediaEndedWake(callId: callId)
            )
        case .rejoin:
            await beginReconnect(callId: callId, initialError: event.error)
        case .fail:
            await fail(
                callId: callId,
                error: event.error ?? LiveKitCallMediaError.mediaUnavailable,
                lease: lease
            )
        }
    }

    private func handleSDKReconnectStateChanged(
        callId: String,
        isReconnecting: Bool
    ) {
        guard activeCall?.id.caseInsensitiveCompare(callId) == .orderedSame,
              session.activeCallId?.caseInsensitiveCompare(callId) == .orderedSame,
              state != .ending
        else { return }
        if isReconnecting {
            reconnectStabilityTask?.cancel()
            reconnectStabilityTask = nil
            state = .reconnecting
        } else {
            state = .connected
            if reconnectAttemptsRemaining < CallMediaReconnectPolicy.retryDelaysNanoseconds.count {
                scheduleReconnectBudgetReset(callId: callId)
            }
            // If the remote hung up during the outage, re-arm the empty-room grace timer —
            // the presence publisher won't fire again for a value that never changed.
            handleRemotePresenceChanged(media.hasRemoteParticipant)
        }
    }

    private func beginReconnect(callId: String, initialError: Error?) async {
        guard reconnectTask == nil,
              let handoff = activeHandoff,
              let lease = activeAccountLease,
              accountLeaseGate.accepts(lease),
              handoff.callId.caseInsensitiveCompare(callId) == .orderedSame
        else { return }

        reconnectStabilityTask?.cancel()
        reconnectStabilityTask = nil
        guard reconnectAttemptsRemaining > 0 else {
            await fail(
                callId: callId,
                error: initialError ?? LiveKitCallMediaError.mediaUnavailable,
                lease: lease
            )
            return
        }

        state = .reconnecting
        controlError = nil
        reconnectGeneration &+= 1
        let generation = reconnectGeneration
        reconnectTask = Task { @MainActor [weak self] in
            await self?.runReconnect(
                callId: callId,
                originalHandoff: handoff,
                lease: lease,
                generation: generation,
                initialError: initialError
            )
        }
    }

    private func runReconnect(
        callId: String,
        originalHandoff: CallMediaHandoff,
        lease: CallMediaAccountLease,
        generation: UInt64,
        initialError: Error?
    ) async {
        var lastError = initialError ?? LiveKitCallMediaError.mediaUnavailable

        while reconnectAttemptsRemaining > 0 {
            let attempt = CallMediaReconnectPolicy.retryDelaysNanoseconds.count
                - reconnectAttemptsRemaining
                + 1
            guard reconnectIsCurrent(callId: callId, lease: lease, generation: generation),
                  let delay = CallMediaReconnectPolicy.delayNanoseconds(forAttempt: attempt)
            else { return }

            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
            }

            guard reconnectIsCurrent(callId: callId, lease: lease, generation: generation)
            else { return }
            reconnectAttemptsRemaining -= 1
            do {
                let rtc = try await APIClientSessionBinding.$sessionID.withValue(lease.sessionID) {
                    try await APIClient.shared.callToken(id: callId)
                }
                guard reconnectIsCurrent(callId: callId, lease: lease, generation: generation)
                else { return }
                let refreshedHandoff = try originalHandoff.refreshingRTC(rtc)
                try await session.connect(refreshedHandoff)
                guard reconnectIsCurrent(callId: callId, lease: lease, generation: generation)
                else {
                    await session.disconnect(callId: callId)
                    return
                }
                activeHandoff = refreshedHandoff
                state = .connected
                controlError = nil
                reconnectTask = nil
                scheduleReconnectBudgetReset(callId: callId)
                handleRemotePresenceChanged(media.hasRemoteParticipant)
                return
            } catch is CancellationError {
                return
            } catch {
                lastError = error
            }
        }

        guard reconnectIsCurrent(callId: callId, lease: lease, generation: generation)
        else { return }
        reconnectTask = nil
        await fail(callId: callId, error: lastError, lease: lease)
    }

    private func reconnectIsCurrent(
        callId: String,
        lease: CallMediaAccountLease,
        generation: UInt64
    ) -> Bool {
        !Task.isCancelled
            && reconnectGeneration == generation
            && accountLeaseGate.accepts(lease)
            && activeAccountLease == lease
            && state != .ending
            && activeCall?.id.caseInsensitiveCompare(callId) == .orderedSame
    }

    /// Ends the call after `remoteAbsenceGraceNanoseconds` if the remote participant left a
    /// still-connected room and never returned — a remote hang-up that skipped room teardown
    /// must not leave capture running forever.
    private func handleRemotePresenceChanged(_ isPresent: Bool) {
        if isPresent {
            remoteAbsenceTask?.cancel()
            remoteAbsenceTask = nil
            return
        }
        guard state == .connected,
              let callID = activeCall?.id,
              let lease = activeAccountLease,
              accountLeaseGate.accepts(lease),
              media.remoteParticipantConnectedAt != nil
        else { return }
        remoteAbsenceTask?.cancel()
        remoteAbsenceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.remoteAbsenceGraceNanoseconds)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.state == .connected,
                  self.accountLeaseGate.accepts(lease),
                  self.activeAccountLease == lease,
                  self.activeCall?.id.caseInsensitiveCompare(callID) == .orderedSame,
                  !self.media.hasRemoteParticipant
            else { return }
            self.remoteAbsenceTask = nil
            self.requestEnd()
        }
    }

    private func invalidateReconnect() {
        reconnectGeneration &+= 1
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectStabilityTask?.cancel()
        reconnectStabilityTask = nil
        remoteAbsenceTask?.cancel()
        remoteAbsenceTask = nil
    }

    private func resetReconnectBudget() {
        reconnectAttemptsRemaining = CallMediaReconnectPolicy.retryDelaysNanoseconds.count
    }

    private func scheduleReconnectBudgetReset(callId: String) {
        reconnectStabilityTask?.cancel()
        reconnectStabilityTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: CallMediaReconnectPolicy.stableConnectionResetNanoseconds
                )
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.state == .connected,
                  self.activeCall?.id.caseInsensitiveCompare(callId) == .orderedSame
            else { return }
            self.resetReconnectBudget()
            self.reconnectStabilityTask = nil
        }
    }

    /// Reconciles an already-connected media room with the authoritative backend call state.
    /// A terminal call must not leave capture or playback running while the UI shows it ended.
    func reconcileBackendCalls(_ calls: [CallRecord]) async {
        guard let activeCall,
              let record = calls.first(where: {
                  $0.id.caseInsensitiveCompare(activeCall.id) == .orderedSame
              }),
              [.completed, .missed, .declined, .failed].contains(record.state)
        else { return }

        invalidateReconnect()
        state = .ending
        await session.disconnect(callId: activeCall.id)
        clearPresentation(callId: activeCall.id)
        guard let callUUID = UUID(uuidString: activeCall.id) else { return }
        let reason: CXCallEndedReason = switch record.state {
        case .missed: .unanswered
        case .failed: .failed
        default: .remoteEnded
        }
        NotificationCoordinator.shared.reportCallEnded(callUUID, reason: reason)
    }

    /// Everything that must stop the moment a call stops existing.
    ///
    /// The floating call surface and any Picture in Picture session are driven from `activeCall`
    /// via the app scene. Tearing them down here as well means a call that ends through any path —
    /// remote hang-up, media failure, CallKit reset, sign-out — cannot leave a bubble on screen or
    /// a Picture in Picture window running, which is what made the app look like it was still in a
    /// call after the call was over.
    private func retireCallPresentationSurfaces() {
        guard activeCall == nil else { return }
        CallOverlayWindowController.shared.hide()
        // CallKit normally deactivates the audio session for us, but not on every ending path —
        // a media failure or a provider reset can retire the call without one. Leaving the session
        // in `playAndRecord` keeps the device in call mode: audio stays on the earpiece and other
        // apps stay ducked, long after the call is over. Deactivating is idempotent, and a
        // replacement call re-activates through CallKit as usual.
        try? media.deactivateAudioSession()
    }

    private func clearPresentation(callId: String) {
        guard activeCall?.id.caseInsensitiveCompare(callId) == .orderedSame else { return }
        invalidateReconnect()
        if pendingOutgoingClientCallID?.caseInsensitiveCompare(callId) == .orderedSame {
            pendingOutgoingClientCallID = nil
        }
        if activeHandoff?.callId.caseInsensitiveCompare(callId) == .orderedSame {
            activeHandoff = nil
        }
        activeAccountLease = nil
        activeCall = nil
        state = .idle
        controlError = nil
        retireCallPresentationSurfaces()
    }
}
