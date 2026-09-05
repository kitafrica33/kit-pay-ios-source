import Combine
import Foundation
import LiveKit
import UIKit

enum CallScreenSharingPhase: Equatable {
    case idle
    case awaitingApproval
    case awaitingConfirmation
    case starting
    case sharing
    case stopping

    var isActive: Bool { self == .sharing }
    var canStop: Bool { self != .idle && self != .stopping }
}

enum CallScreenSharingError: LocalizedError {
    case unavailable
    case publicationFailed

    var errorDescription: String? {
        switch self {
        case .unavailable: "Connect the call and open Kit Pay to share your screen."
        case .publicationFailed: "Screen sharing could not start. Please try again."
        }
    }
}

@MainActor
protocol CallScreenSharePublishing: AnyObject {
    var isConnected: Bool { get }
    func startScreenSharing() async throws
    func stopScreenSharing() async
}

@MainActor
private final class LiveKitScreenSharePublisher: CallScreenSharePublishing {
    let room: Room
    private var preparedTrack: LocalVideoTrack?

    init(room: Room) { self.room = room }

    var isConnected: Bool { room.connectionState == .connected }

    func startScreenSharing() async throws {
        guard isConnected else { throw CallScreenSharingError.unavailable }
        let track = LocalVideoTrack.createBroadcastScreenCapturerTrack(options: ScreenShareCaptureOptions(
            dimensions: .h1080_169, fps: 15, appAudio: false, useBroadcastExtension: true
        ))
        preparedTrack = track
        // Create the receiver only after both system consent and named-call confirmation.
        // Publishing starts capture; canceled system pickers never allocate an IPC listener.
        let publication = try await room.localParticipant.publish(videoTrack: track)
        guard publication.track != nil, !publication.isMuted
        else { throw CallScreenSharingError.publicationFailed }
    }

    func stopScreenSharing() async {
        // Stop the local IPC capture before waiting for signalling to unpublish it.
        try? await preparedTrack?.stop()
        preparedTrack = nil
        _ = try? await room.localParticipant.setScreenShare(enabled: false)
    }
}

/// ReplayKit's boolean broadcast event carries no request identity. It grants local capture only.
/// The user confirms the named call *after* that event before any track is published, so even a
/// delayed grant from an older system prompt cannot silently publish into a replacement call.
@MainActor
final class CallScreenSharingController: ObservableObject {
    @Published private(set) var phase: CallScreenSharingPhase = .idle
    var onError: ((Error) -> Void)?

    private struct Binding {
        let id = UUID()
        let callID: String
        let publisher: any CallScreenSharePublishing
    }

    private var binding: Binding?
    private var approvedRequestID: UUID?
    private var publicationTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var approvalTimeout: Task<Void, Never>?
    private var observation: AnyCancellable?
    private let isBroadcasting: () -> Bool
    private let requestActivation: () -> Void
    private let requestStop: () -> Void
    private let approvalTimeoutNanoseconds: UInt64
    private let canPresentConsent: () -> Bool

    convenience init() {
        // SDK automatic publication has no authenticated-call lease. Kit owns publication instead.
        let broadcast = BroadcastManager.shared
        broadcast.shouldPublishTrack = false
        self.init(
            events: broadcast.isBroadcastingPublisher,
            isBroadcasting: { broadcast.isBroadcasting },
            requestActivation: { broadcast.requestActivation() },
            requestStop: { broadcast.requestStop() },
            canPresentConsent: { UIApplication.shared.applicationState == .active }
        )
    }

    init(
        events: AnyPublisher<Bool, Never>,
        isBroadcasting: @escaping () -> Bool,
        requestActivation: @escaping () -> Void,
        requestStop: @escaping () -> Void,
        approvalTimeoutNanoseconds: UInt64 = 90_000_000_000,
        canPresentConsent: @escaping () -> Bool = { true }
    ) {
        self.isBroadcasting = isBroadcasting
        self.requestActivation = requestActivation
        self.requestStop = requestStop
        self.approvalTimeoutNanoseconds = approvalTimeoutNanoseconds
        self.canPresentConsent = canPresentConsent
        observation = events.removeDuplicates().sink { [weak self] broadcasting in
            Task { @MainActor [weak self] in self?.broadcastChanged(broadcasting) }
        }
    }

    func bind(room: Room, callID: String) {
        bind(publisher: LiveKitScreenSharePublisher(room: room), callID: callID)
    }

    func bind(publisher: any CallScreenSharePublishing, callID: String) {
        if binding != nil { stop() }
        binding = Binding(callID: callID.lowercased(), publisher: publisher)
    }

    func unbind() {
        stop()
        binding = nil
    }

    func requestStart(callID: String, applicationIsActive: Bool) throws {
        guard phase == .idle, cleanupTask == nil, !isBroadcasting(),
              applicationIsActive, let binding,
              binding.callID == callID.lowercased(), binding.publisher.isConnected
        else { throw CallScreenSharingError.unavailable }
        let requestID = UUID()
        approvedRequestID = requestID
        phase = .awaitingApproval
        requestActivation()
        approvalTimeout = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: approvalTimeoutNanoseconds) }
            catch { return }
            guard approvedRequestID == requestID,
                  phase == .awaitingApproval || phase == .awaitingConfirmation else { return }
            // Expiry cancels intent; it never grants permission or begins publication.
            stop()
        }
    }

    func confirmSharing(callID: String) throws {
        guard phase == .awaitingConfirmation, let requestID = approvedRequestID,
              let binding, binding.callID == callID.lowercased(),
              binding.publisher.isConnected, isBroadcasting(), canPresentConsent()
        else { throw CallScreenSharingError.unavailable }
        approvalTimeout?.cancel()
        approvalTimeout = nil
        phase = .starting
        publicationTask = Task { [weak self] in
            do {
                // This task may first run after a synchronous hang-up or account switch.
                guard let self, approvedRequestID == requestID,
                      self.binding?.id == binding.id else { return }
                guard isBroadcasting(), binding.publisher.isConnected
                else { throw CallScreenSharingError.unavailable }
                try await binding.publisher.startScreenSharing()
                guard approvedRequestID == requestID,
                      self.binding?.id == binding.id, isBroadcasting()
                else { return }
                phase = .sharing
            } catch {
                guard let self, approvedRequestID == requestID,
                      self.binding?.id == binding.id else { return }
                onError?(error)
                stop()
            }
        }
    }

    func stop() {
        approvedRequestID = nil
        approvalTimeout?.cancel()
        approvalTimeout = nil
        if isBroadcasting() || phase != .idle { requestStop() }
        guard cleanupTask == nil else { return }
        guard phase != .idle || publicationTask != nil else { return }
        phase = .stopping
        let pendingPublication = publicationTask
        let publisher = binding?.publisher
        cleanupTask = Task { [weak self] in
            // A stop racing publication must retire that publication before another can start.
            await pendingPublication?.value
            await publisher?.stopScreenSharing()
            guard let self else { return }
            publicationTask = nil
            cleanupTask = nil
            if !isBroadcasting() { phase = .idle }
        }
    }

    private func broadcastChanged(_ broadcasting: Bool) {
        guard broadcasting == isBroadcasting() else { return }
        guard broadcasting else {
            if phase == .awaitingConfirmation || phase == .starting || phase == .sharing { stop() }
            if phase == .stopping, cleanupTask == nil { phase = .idle }
            return
        }
        guard phase == .awaitingApproval, approvedRequestID != nil,
              let binding, binding.publisher.isConnected
        else {
            if phase != .awaitingConfirmation && phase != .starting && phase != .sharing {
                stop()
                requestStop()
            }
            return
        }
        // A system grant alone never publishes: the next explicit action names the live call.
        phase = .awaitingConfirmation
    }
}
