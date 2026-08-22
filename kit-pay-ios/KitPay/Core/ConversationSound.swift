import AVFoundation
import Foundation
import UIKit

/// Decides whether a visible conversation received a genuinely new message.
///
/// The initial snapshot is always a silent baseline. Messages restored after that snapshot are
/// also silent when their server timestamp predates visibility, so opening a chat never replays
/// sounds for local restoration or history backfill.
struct VisibleConversationSoundPolicy {
    private let conversationID: String
    private var visibleSince: Date?
    private var observedMessageIDs: Set<UUID> = []

    init(conversationID: String) {
        self.conversationID = conversationID
    }

    mutating func beginVisibility(with messages: [LocalMessage], at date: Date = Date()) {
        visibleSince = date
        observedMessageIDs = Set(relevantMessages(in: messages).map(\.id))
    }

    mutating func endVisibility() {
        visibleSince = nil
        observedMessageIDs.removeAll(keepingCapacity: true)
    }

    /// Consumes every delta even while the app is inactive. That prevents a message already
    /// announced by APNs from replaying when the user returns to an open conversation.
    mutating func consume(_ messages: [LocalMessage], appIsActive: Bool) -> Bool {
        guard let visibleSince else {
            beginVisibility(with: messages)
            return false
        }

        let relevant = relevantMessages(in: messages)
        let unseen = relevant.filter { !observedMessageIDs.contains($0.id) }
        observedMessageIDs.formUnion(relevant.map(\.id))

        guard appIsActive else { return false }
        return unseen.contains { message in
            !message.isOutgoing
                && message.state == .received
                && message.serverMessageId != nil
                && message.createdAt >= visibleSince
        }
    }

    private func relevantMessages(in messages: [LocalMessage]) -> [LocalMessage] {
        messages.filter { $0.conversationId == conversationID }
    }
}

/// Plays the Android-parity foreground message sound without changing the shared audio session.
/// Leaving the session category untouched avoids overriding silent-mode or CallKit audio policy.
@MainActor
final class IncomingMessageSoundPlayer {
    static let shared = IncomingMessageSoundPlayer()
    static let resourceName = "knock_brush"
    static let resourceExtension = "mp3"

    private var player: AVAudioPlayer?

    private init() {}

    func play() {
        guard let url = Bundle.main.url(
            forResource: Self.resourceName,
            withExtension: Self.resourceExtension,
            subdirectory: "Sounds"
        ) ?? Bundle.main.url(
            forResource: Self.resourceName,
            withExtension: Self.resourceExtension
        ) else { return }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = 0
            player.prepareToPlay()
            player.play()
            self.player = player
        } catch {
            // A missing/unsupported optional sound must never interrupt messaging.
            player = nil
        }
    }
}

/// A nil custom ringtone is intentional: CallKit then uses the user's system ringtone and
/// vibration settings, including the silent switch and Focus rules.
enum CallRingtonePolicy {
    static let customSoundName: String? = nil
}

/// The exact platform tones selected by the Android app's `CallTonePlayer`.
///
/// Android's `TONE_SUP_RINGTONE` resolves to the CEPT cadence on Ugandan devices: a 425 Hz
/// tone for one second followed by four seconds of silence. `TONE_CDMA_CALLDROP_LITE` is a
/// single 125 ms burst of each listed frequency. Keeping the definition separate from playback
/// makes parity auditable without requiring either platform's private system-sound files.
struct AndroidCallToneDefinition {
    struct Segment: Equatable {
        let durationMilliseconds: Int
        let frequenciesHz: [Double]
    }

    static let ringbackVolume: Float = 0.70
    static let callWaitingVolume: Float = 0.85
    static let disconnectVolume: Float = 0.80
    /// Android asks `ToneGenerator` to run `TONE_SUP_CALL_WAITING` for this long. On Ugandan
    /// devices AOSP selects the default CEPT descriptor, whose first 200 ms are audible and whose
    /// following 600 ms are silent; the request ends before its second audible segment begins.
    static let callWaitingRequestDurationMilliseconds = 800
    static let callWaitingAudibleDurationMilliseconds = 200
    static let callWaitingRepeatIntervalMilliseconds = 3_500
    static let ringbackSegments = [
        Segment(durationMilliseconds: 1_000, frequenciesHz: [425]),
        Segment(durationMilliseconds: 4_000, frequenciesHz: []),
    ]
    /// Android invokes the 800 ms CEPT request every 3.5 seconds. Rendering its 200 ms audible
    /// prefix and padding the rest of the full cadence reproduces that schedule without timer drift.
    static let callWaitingSegments = [
        Segment(durationMilliseconds: 200, frequenciesHz: [425]),
        Segment(durationMilliseconds: 3_300, frequenciesHz: []),
    ]
    static let disconnectSegments = [
        Segment(durationMilliseconds: 125, frequenciesHz: [1_480]),
        Segment(durationMilliseconds: 125, frequenciesHz: [1_397]),
        Segment(durationMilliseconds: 125, frequenciesHz: [784]),
    ]
}

/// Owns only the repeating call-waiting alert. It deliberately has no ringback or disconnect
/// actions, so admitting or clearing a waiting call cannot mutate progress-tone ownership.
struct CallWaitingSoundLifecycle {
    enum Event: Equatable {
        case authenticatedWaitingCall(callID: String)
        case clearWaitingCall(callID: String)
        case appBecameActive
        case appEnteredBackground
        case callKitAudioActivated
        case callKitAudioDeactivated
        case resetSession
    }

    enum Action: Equatable {
        case startRepeating(callID: String)
        case stopRepeating(callID: String)
        case stopAll
    }

    private(set) var waitingCallID: String?
    private(set) var repeatingCallID: String?
    private var appIsActive = true
    private var callKitAudioIsActive = false

    mutating func transition(_ event: Event) -> [Action] {
        switch event {
        case .authenticatedWaitingCall(let rawCallID):
            let callID = canonical(rawCallID)
            guard !callID.isEmpty else { return [] }
            guard waitingCallID != callID else { return reconcilePlayback() }

            var actions: [Action] = []
            if let repeatingCallID {
                actions.append(.stopRepeating(callID: repeatingCallID))
                self.repeatingCallID = nil
            }
            waitingCallID = callID
            actions.append(contentsOf: reconcilePlayback())
            return actions

        case .clearWaitingCall(let rawCallID):
            let callID = canonical(rawCallID)
            guard waitingCallID == callID else { return [] }
            waitingCallID = nil
            return reconcilePlayback()

        case .appBecameActive:
            appIsActive = true
            return reconcilePlayback()

        case .appEnteredBackground:
            appIsActive = false
            return reconcilePlayback()

        case .callKitAudioActivated:
            callKitAudioIsActive = true
            return reconcilePlayback()

        case .callKitAudioDeactivated:
            callKitAudioIsActive = false
            return reconcilePlayback()

        case .resetSession:
            waitingCallID = nil
            repeatingCallID = nil
            callKitAudioIsActive = false
            return [.stopAll]
        }
    }

    private mutating func reconcilePlayback() -> [Action] {
        if appIsActive, callKitAudioIsActive, let waitingCallID {
            guard repeatingCallID != waitingCallID else { return [] }
            var actions: [Action] = []
            if let repeatingCallID {
                actions.append(.stopRepeating(callID: repeatingCallID))
            }
            repeatingCallID = waitingCallID
            actions.append(.startRepeating(callID: waitingCallID))
            return actions
        }

        guard let repeatingCallID else { return [] }
        self.repeatingCallID = nil
        return [.stopRepeating(callID: repeatingCallID)]
    }

    private func canonical(_ callID: String) -> String {
        callID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Pure lifecycle policy for call progress audio.
///
/// An offline/provisional attempt is deliberately not an event here. Only the authenticated
/// server response admitted to CallKit can call `serverAcceptedOutgoing`; consequently a call
/// that is still waiting for connectivity can never produce ringback or a disconnect sound.
struct CallProgressSoundLifecycle {
    enum Event: Equatable {
        case serverAcceptedOutgoing(callID: String)
        case incomingAnswered(callID: String)
        case remoteConnected(callID: String)
        case callEnded(callID: String)
        case resetSession
    }

    enum Action: Equatable {
        case startRingback(callID: String)
        case stopRingback(callID: String)
        case playDisconnect(callID: String)
        case stopAll
    }

    private(set) var ringbackCallID: String?
    private var audibleCallIDs: Set<String> = []
    private var connectedCallIDs: Set<String> = []

    mutating func transition(_ event: Event) -> [Action] {
        switch event {
        case .serverAcceptedOutgoing(let rawCallID):
            let callID = canonical(rawCallID)
            guard !callID.isEmpty, !connectedCallIDs.contains(callID) else { return [] }
            if ringbackCallID == callID {
                audibleCallIDs.insert(callID)
                return []
            }
            var actions: [Action] = []
            if let replacedCallID = ringbackCallID {
                actions.append(.stopRingback(callID: replacedCallID))
                audibleCallIDs.remove(replacedCallID)
                connectedCallIDs.remove(replacedCallID)
            }
            audibleCallIDs.insert(callID)
            ringbackCallID = callID
            actions.append(.startRingback(callID: callID))
            return actions

        case .incomingAnswered(let rawCallID):
            let callID = canonical(rawCallID)
            guard !callID.isEmpty else { return [] }
            audibleCallIDs.insert(callID)
            return stopRingbackIfNeeded(callID: callID)

        case .remoteConnected(let rawCallID):
            let callID = canonical(rawCallID)
            guard audibleCallIDs.contains(callID) else { return [] }
            connectedCallIDs.insert(callID)
            return stopRingbackIfNeeded(callID: callID)

        case .callEnded(let rawCallID):
            let callID = canonical(rawCallID)
            guard !callID.isEmpty else { return [] }
            var actions = stopRingbackIfNeeded(callID: callID)
            connectedCallIDs.remove(callID)
            if audibleCallIDs.remove(callID) != nil {
                actions.append(.playDisconnect(callID: callID))
            }
            return actions

        case .resetSession:
            ringbackCallID = nil
            audibleCallIDs.removeAll(keepingCapacity: true)
            connectedCallIDs.removeAll(keepingCapacity: true)
            return [.stopAll]
        }
    }

    private mutating func stopRingbackIfNeeded(callID: String) -> [Action] {
        guard ringbackCallID == callID else { return [] }
        ringbackCallID = nil
        return [.stopRingback(callID: callID)]
    }

    private func canonical(_ callID: String) -> String {
        callID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Plays Android-parity progress tones on the active CallKit/LiveKit route without changing the
/// shared `AVAudioSession`. CallKit therefore remains authoritative for routing, silent mode and
/// the incoming system ringtone.
final class CallProgressSoundPlayer {
    static let shared = CallProgressSoundPlayer()

    private var lifecycle = CallProgressSoundLifecycle()
    private var waitingLifecycle = CallWaitingSoundLifecycle()
    private var ringbackPlayer: AVAudioPlayer?
    private var callWaitingPlayer: AVAudioPlayer?
    private var disconnectPlayer: AVAudioPlayer?
    private var isInBackground = false
    private var isCallKitAudioActive = false
    private var observers: [NSObjectProtocol] = []

    private init(center: NotificationCenter = .default) {
        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.isInBackground = true
            self.applyWaiting(self.waitingLifecycle.transition(.appEnteredBackground))
        })
        observers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.isInBackground = false
            self.applyWaiting(self.waitingLifecycle.transition(.appBecameActive))
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Must only be called for the authenticated call returned by `POST /calls`, never for the
    /// local queued placeholder. This is the sole admission point for caller ringback.
    func beginServerAcceptedOutgoingRinging(callID: String) {
        disconnectPlayer?.stop()
        disconnectPlayer = nil
        let actions = lifecycle.transition(.serverAcceptedOutgoing(callID: callID))
        apply(actions)
    }

    func incomingCallAnswered(callID: String) {
        disconnectPlayer?.stop()
        disconnectPlayer = nil
        applyWaiting(waitingLifecycle.transition(.clearWaitingCall(callID: callID)))
        let actions = lifecycle.transition(.incomingAnswered(callID: callID))
        apply(actions)
    }

    func remoteParticipantConnected(callID: String) {
        applyWaiting(waitingLifecycle.transition(.clearWaitingCall(callID: callID)))
        let actions = lifecycle.transition(.remoteConnected(callID: callID))
        apply(actions)
    }

    func callEnded(callID: String) {
        applyWaiting(waitingLifecycle.transition(.clearWaitingCall(callID: callID)))
        let actions = lifecycle.transition(.callEnded(callID: callID))
        apply(actions)
    }

    /// The caller must authenticate the second call before admitting its alert. Repeated delivery
    /// of the same waiting call is idempotent; a different authenticated call atomically replaces
    /// the prior waiting-tone owner without changing ringback or disconnect state.
    func beginAuthenticatedCallWaiting(callID: String) {
        applyWaiting(waitingLifecycle.transition(.authenticatedWaitingCall(callID: callID)))
    }

    func clearAuthenticatedCallWaiting(callID: String) {
        applyWaiting(waitingLifecycle.transition(.clearWaitingCall(callID: callID)))
    }

    func resetForSessionReplacement() {
        isCallKitAudioActive = false
        applyWaiting(waitingLifecycle.transition(.resetSession))
        let actions = lifecycle.transition(.resetSession)
        apply(actions)
    }

    /// CallKit can activate after the outgoing action has already been fulfilled. Retry the
    /// prepared ringback on that authoritative route, but never invent a ringing call here.
    func callKitAudioDidActivate() {
        isCallKitAudioActive = true
        applyWaiting(waitingLifecycle.transition(.callKitAudioActivated))
        guard let callID = lifecycle.ringbackCallID else { return }
        // Recreate the player after LiveKit configures CallKit's session so it follows the
        // authoritative voice/video route rather than a pre-activation application route.
        stopRingback()
        playRingback(callID: callID)
    }

    /// Deactivation must immediately silence progress audio. A following end event remains able
    /// to play its short one-shot when the app is foregrounded.
    func callKitAudioDidDeactivate() {
        isCallKitAudioActive = false
        applyWaiting(waitingLifecycle.transition(.callKitAudioDeactivated))
        stopRingback()
    }

    private func applyWaiting(_ actions: [CallWaitingSoundLifecycle.Action]) {
        for action in actions {
            switch action {
            case .startRepeating(let callID):
                playCallWaiting(callID: callID)
            case .stopRepeating, .stopAll:
                stopCallWaiting()
            }
        }
    }

    private func apply(_ actions: [CallProgressSoundLifecycle.Action]) {
        for action in actions {
            switch action {
            case .startRingback(let callID):
                playRingback(callID: callID)
            case .stopRingback:
                stopRingback()
            case .playDisconnect:
                playDisconnect()
            case .stopAll:
                stopRingback()
                disconnectPlayer?.stop()
                disconnectPlayer = nil
            }
        }
    }

    private func playRingback(callID: String) {
        guard isCallKitAudioActive,
              lifecycle.ringbackCallID == callID
        else { return }
        do {
            let player = try AVAudioPlayer(data: AndroidCallToneRenderer.ringbackWAV)
            player.numberOfLoops = -1
            player.volume = AndroidCallToneDefinition.ringbackVolume
            player.prepareToPlay()
            guard player.play() else { return }
            ringbackPlayer = player
        } catch {
            ringbackPlayer = nil
        }
    }

    private func stopRingback() {
        ringbackPlayer?.stop()
        ringbackPlayer = nil
    }

    private func playCallWaiting(callID: String) {
        guard waitingLifecycle.repeatingCallID == callID else { return }
        stopCallWaiting()
        do {
            let player = try AVAudioPlayer(data: AndroidCallToneRenderer.callWaitingWAV)
            player.numberOfLoops = -1
            player.volume = AndroidCallToneDefinition.callWaitingVolume
            player.prepareToPlay()
            guard player.play() else { return }
            callWaitingPlayer = player
        } catch {
            callWaitingPlayer = nil
        }
    }

    private func stopCallWaiting() {
        callWaitingPlayer?.stop()
        callWaitingPlayer = nil
    }

    private func playDisconnect() {
        guard !isInBackground else { return }
        disconnectPlayer?.stop()
        do {
            let player = try AVAudioPlayer(data: AndroidCallToneRenderer.disconnectWAV)
            player.numberOfLoops = 0
            player.volume = AndroidCallToneDefinition.disconnectVolume
            player.prepareToPlay()
            guard player.play() else { return }
            disconnectPlayer = player
        } catch {
            disconnectPlayer = nil
        }
    }
}

/// Renders the Android tone descriptors as 16-bit mono WAV data. A short linear edge ramp mirrors
/// Android ToneGenerator's transition smoothing and prevents speaker clicks at segment changes.
enum AndroidCallToneRenderer {
    static let ringbackWAV = render(AndroidCallToneDefinition.ringbackSegments)
    static let callWaitingWAV = render(AndroidCallToneDefinition.callWaitingSegments)
    static let disconnectWAV = render(AndroidCallToneDefinition.disconnectSegments)

    private static let sampleRate = 44_100
    private static let edgeRampMilliseconds = 5

    private static func render(_ segments: [AndroidCallToneDefinition.Segment]) -> Data {
        var samples: [Int16] = []
        for segment in segments {
            let sampleCount = sampleRate * segment.durationMilliseconds / 1_000
            let rampCount = min(
                sampleCount / 2,
                sampleRate * edgeRampMilliseconds / 1_000
            )
            for sampleIndex in 0 ..< sampleCount {
                guard !segment.frequenciesHz.isEmpty else {
                    samples.append(0)
                    continue
                }
                let time = Double(sampleIndex) / Double(sampleRate)
                let combined = segment.frequenciesHz.reduce(0.0) { partial, frequency in
                    partial + sin(2 * .pi * frequency * time)
                } / Double(segment.frequenciesHz.count)
                let edgeGain: Double
                if sampleIndex < rampCount {
                    edgeGain = Double(sampleIndex) / Double(max(1, rampCount))
                } else if sampleIndex >= sampleCount - rampCount {
                    edgeGain = Double(sampleCount - sampleIndex - 1) / Double(max(1, rampCount))
                } else {
                    edgeGain = 1
                }
                let value = max(-1, min(1, combined * edgeGain))
                samples.append(Int16(value * Double(Int16.max)))
            }
        }
        return wavData(samples: samples, sampleRate: sampleRate)
    }

    private static func wavData(samples: [Int16], sampleRate: Int) -> Data {
        let bytesPerSample = MemoryLayout<Int16>.size
        let dataByteCount = samples.count * bytesPerSample
        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + dataByteCount), to: &data)
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data)
        append(UInt16(1), to: &data)
        append(UInt32(sampleRate), to: &data)
        append(UInt32(sampleRate * bytesPerSample), to: &data)
        append(UInt16(bytesPerSample), to: &data)
        append(UInt16(16), to: &data)
        data.append(contentsOf: "data".utf8)
        append(UInt32(dataByteCount), to: &data)
        for sample in samples { append(UInt16(bitPattern: sample), to: &data) }
        return data
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }
}
