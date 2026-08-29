import Foundation

struct ProtectedCommunicationAdmissionLease: Equatable, Sendable {
    fileprivate let generation: UInt64
    fileprivate let accountID: String
}

/// A process-wide, synchronous fence shared by deletion orchestration and protected-store
/// commits. Holding the lock through a synchronous encrypted-state commit closes the final race
/// where deletion could begin after an async caller's last check but before bytes reached disk.
final class ProtectedCommunicationAdmissionGate: @unchecked Sendable {
    static let shared = ProtectedCommunicationAdmissionGate()

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var enabled = false
    private var accountID: String?

    func quarantine() {
        lock.lock()
        generation &+= 1
        enabled = false
        lock.unlock()
    }

    func restore(forAccountID rawAccountID: String) {
        guard let accountID = Self.canonicalUUID(rawAccountID) else { return }
        lock.lock()
        generation &+= 1
        self.accountID = accountID
        enabled = true
        lock.unlock()
    }

    func lease(forAccountID rawAccountID: String) -> ProtectedCommunicationAdmissionLease? {
        guard let accountID = Self.canonicalUUID(rawAccountID) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard enabled, self.accountID == accountID else { return nil }
        return ProtectedCommunicationAdmissionLease(
            generation: generation,
            accountID: accountID
        )
    }

    func permits(_ lease: ProtectedCommunicationAdmissionLease) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
            && generation == lease.generation
            && accountID == lease.accountID
    }

    func permits(accountID rawAccountID: String) -> Bool {
        guard let accountID = Self.canonicalUUID(rawAccountID) else { return false }
        lock.lock()
        defer { lock.unlock() }
        return enabled && self.accountID == accountID
    }

    func withAuthorizedCommit<T>(
        _ lease: ProtectedCommunicationAdmissionLease,
        _ operation: () throws -> T
    ) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard enabled,
              generation == lease.generation,
              accountID == lease.accountID
        else { throw CancellationError() }
        return try operation()
    }

    private static func canonicalUUID(_ value: String) -> String? {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              let uuid = UUID(uuidString: value)
        else { return nil }
        return uuid.uuidString.lowercased()
    }
}

protocol SecureMessagingActivationTransport: Sendable {
    func messagingKeyStatus() async throws -> MessagingKeyStatusDTO
    func publishMessagingKeyBundle(
        _ request: PublishMessagingKeyBundleRequest
    ) async throws -> MessagingKeyStatusDTO
    func resetMessagingEnrollment(
        _ request: ResetMessagingEnrollmentRequest
    ) async throws -> ResetMessagingEnrollmentDTO
}

extension APIClient: SecureMessagingActivationTransport {}

enum SecureMessagingActivationError: LocalizedError, Equatable {
    case invalidUser
    case missingLocalEnrollment
    case serverEnrollmentChanged
    case incompleteServerStatus
    case replenishmentRejected
    case accountChanged

    var errorDescription: String? {
        switch self {
        case .invalidUser:
            "Your messaging account changed. Sign in again to continue."
        case .missingLocalEnrollment:
            "Messages need to be restored on this device. Sign in again to continue."
        case .serverEnrollmentChanged:
            "Messages need to be restored on this device. Sign in again to continue."
        case .incompleteServerStatus:
            "Kit could not finish preparing messages. Please try again."
        case .replenishmentRejected:
            "Kit could not finish preparing messages. Please try again."
        case .accountChanged:
            "Your messaging account changed. Sign in again to continue."
        }
    }
}

/// Reconciles one authenticated account with its server enrollment. A single-flight task prevents
/// duplicate activation inside this process; SecureLocalStore's complete-state CAS remains the
/// authority across actor reentrancy, logout, restoration, and future messaging workers.
actor SecureMessagingCoordinator {
    static let shared = SecureMessagingCoordinator(
        transport: APIClient.shared,
        store: SecureLocalStore.shared,
        engine: SecureMessagingCryptoEngine.shared
    )

    private let transport: any SecureMessagingActivationTransport
    private let store: SecureLocalStore
    private let engine: SecureMessagingCryptoEngine
    private let provisioningPreKeyCount: Int
    private var activationTask: Task<SecureMessagingPersistentState, Error>?
    private var activationUserID: String?

    init(
        transport: any SecureMessagingActivationTransport,
        store: SecureLocalStore,
        engine: SecureMessagingCryptoEngine,
        provisioningPreKeyCount: Int = SecureMessagingCryptoEngine.uploadPreKeyCount
    ) {
        self.transport = transport
        self.store = store
        self.engine = engine
        self.provisioningPreKeyCount = provisioningPreKeyCount
    }

    func activate(forUserID userID: String) async throws -> SecureMessagingPersistentState {
        guard SecureMessagingValidation.isCanonicalUUID(userID) else {
            throw SecureMessagingActivationError.invalidUser
        }
        if let activationTask {
            guard activationUserID == userID else {
                throw SecureMessagingActivationError.accountChanged
            }
            return try await activationTask.value
        }

        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.reconcileWithCAS(forUserID: userID)
        }
        activationUserID = userID
        activationTask = task
        do {
            let result = try await task.value
            activationTask = nil
            activationUserID = nil
            return result
        } catch {
            activationTask = nil
            activationUserID = nil
            throw error
        }
    }

    private func reconcileWithCAS(
        forUserID userID: String
    ) async throws -> SecureMessagingPersistentState {
        for _ in 0..<3 {
            do {
                return try await reconcileOnce(forUserID: userID)
            } catch SecureMessagingCryptoError.staleState {
                try Task.checkCancellation()
                continue
            }
        }
        throw SecureMessagingCryptoError.staleState
    }

    private func reconcileOnce(
        forUserID userID: String
    ) async throws -> SecureMessagingPersistentState {
        let remote = try await transport.messagingKeyStatus()
        guard let serverEnrolled = remote.enrolled else {
            throw SecureMessagingActivationError.incompleteServerStatus
        }
        let snapshot = await store.snapshot()
        guard snapshot.profile?.id == userID else {
            throw SecureMessagingActivationError.accountChanged
        }

        guard let local = snapshot.secureMessaging else {
            if serverEnrolled {
                // Keychain/local-state loss and an explicit sign-out can leave an authenticated
                // installation enrolled on the server without the corresponding private keys.
                // Reset only the exact status just read; the backend compares every commitment and
                // advances the enrollment epoch atomically before replacement keys are generated.
                try await resetLostLocalEnrollment(remote)
            }
            return try await provisionPublishAndBind(
                forUserID: userID,
                expectedState: nil,
                baseState: .empty
            )
        }

        if local.pendingPublication != nil {
            if serverEnrolled {
                let remoteBinding = try SecureMessagingMapper.enrollmentBinding(
                    from: remote,
                    userID: userID
                )
                if let bound = try? await engine.bindEnrollment(remoteBinding, to: local) {
                    let committed = try await commit(
                        userID: userID,
                        expected: local,
                        next: bound
                    )
                    return try await replenishIfRequired(
                        remote: remote,
                        local: committed,
                        userID: userID
                    )
                }
                guard local.enrollment == remoteBinding else {
                    throw SecureMessagingActivationError.serverEnrollmentChanged
                }
            } else {
                // Never republish an old identity into a reset enrollment epoch.
                guard local.enrollment == nil else {
                    throw SecureMessagingActivationError.serverEnrollmentChanged
                }
            }
            return try await publishPending(local, forUserID: userID)
        }

        if serverEnrolled {
            let binding = try SecureMessagingMapper.enrollmentBinding(
                from: remote,
                userID: userID
            )
            _ = try await engine.bindEnrollment(binding, to: local)
            return try await replenishIfRequired(
                remote: remote,
                local: local,
                userID: userID
            )
        }

        // Private records with neither a confirmed enrollment nor a pending exact publication
        // have unknown provenance. Replacing them silently could strand routed ciphertext.
        guard local.identityKeyPair == nil,
              local.registrationID == nil,
              local.enrollment == nil
        else { throw SecureMessagingActivationError.serverEnrollmentChanged }
        return try await provisionPublishAndBind(
            forUserID: userID,
            expectedState: local,
            baseState: local
        )
    }

    private func resetLostLocalEnrollment(_ remote: MessagingKeyStatusDTO) async throws {
        guard let epoch = remote.enrollmentEpoch,
              let registrationID = remote.registrationId,
              let identityHash = remote.identityKeySha256?.lowercased(),
              let bundleVersion = remote.bundleVersion
        else { throw SecureMessagingActivationError.incompleteServerStatus }
        let request = try ResetMessagingEnrollmentRequest(
            expectedEnrollmentEpoch: epoch,
            expectedRegistrationId: registrationID,
            expectedIdentityKeySha256: identityHash,
            expectedBundleVersion: bundleVersion
        )
        let reset = try await transport.resetMessagingEnrollment(request)
        guard reset.resetApplied == true,
              reset.enrolled == false,
              reset.previousEnrollmentEpoch == epoch,
              reset.enrollmentEpoch.map({ $0 > epoch }) == true,
              reset.deviceId == remote.deviceId
        else { throw SecureMessagingActivationError.serverEnrollmentChanged }
    }

    private func replenishIfRequired(
        remote: MessagingKeyStatusDTO,
        local: SecureMessagingPersistentState,
        userID: String
    ) async throws -> SecureMessagingPersistentState {
        guard let needsReplenishment = remote.needsReplenishment else {
            throw SecureMessagingActivationError.incompleteServerStatus
        }
        if !needsReplenishment { return local }
        return try await provisionPublishAndBind(
            forUserID: userID,
            expectedState: local,
            baseState: local
        )
    }

    private func provisionPublishAndBind(
        forUserID userID: String,
        expectedState: SecureMessagingPersistentState?,
        baseState: SecureMessagingPersistentState
    ) async throws -> SecureMessagingPersistentState {
        let provisioned = try await engine.provision(
            from: baseState,
            preKeyCount: provisioningPreKeyCount
        )
        let committed = try await commit(
            userID: userID,
            expected: expectedState,
            next: provisioned.state
        )
        return try await publishPending(committed, forUserID: userID)
    }

    private func publishPending(
        _ local: SecureMessagingPersistentState,
        forUserID userID: String
    ) async throws -> SecureMessagingPersistentState {
        guard let pending = local.pendingPublication else {
            throw SecureMessagingCryptoError.staleState
        }
        let request = try SecureMessagingMapper.publicationRequest(from: pending)
        let published = try await transport.publishMessagingKeyBundle(request)
        guard published.needsReplenishment == false else {
            throw SecureMessagingActivationError.replenishmentRejected
        }
        let binding = try SecureMessagingMapper.enrollmentBinding(
            from: published,
            userID: userID
        )
        let bound = try await engine.bindEnrollment(binding, to: local)
        return try await commit(userID: userID, expected: local, next: bound)
    }

    private func commit(
        userID: String,
        expected: SecureMessagingPersistentState?,
        next: SecureMessagingPersistentState
    ) async throws -> SecureMessagingPersistentState {
        do {
            try await store.commitSecureMessaging(
                forUserID: userID,
                expectedState: expected,
                nextState: next
            )
        } catch StoreError.accountChanged {
            throw SecureMessagingActivationError.accountChanged
        }
        let committed = await store.snapshot()
        guard committed.profile?.id == userID,
              let state = committed.secureMessaging
        else { throw SecureMessagingActivationError.accountChanged }
        return state
    }
}

protocol SecureMessagingExchangeTransport: SecureMessagingActivationTransport {
    func messagingConversations() async throws -> MessagingConversationListDTO
    func messagingConversation(id: String) async throws -> MessagingConversationDTO
    func createDirectMessagingConversation(
        _ request: CreateDirectMessagingConversationRequest
    ) async throws -> MessagingConversationDTO
    func createGroupMessagingConversation(
        memberIds: [String],
        title: String
    ) async throws -> MessagingConversationDTO
    func renameGroupMessagingConversation(
        conversationId: String,
        title: String
    ) async throws -> MessagingConversationDTO
    func updateGroupMessagingConversationDescription(
        conversationId: String,
        description: String?
    ) async throws -> MessagingConversationDTO
    func attachGroupMessagingConversationPhoto(
        conversationId: String,
        assetId: String
    ) async throws -> MessagingConversationDTO
    func removeGroupMessagingConversationPhoto(
        conversationId: String
    ) async throws -> MessagingConversationDTO
    func addGroupMessagingConversationMember(
        conversationId: String,
        userId: String
    ) async throws -> MessagingConversationDTO
    func removeGroupMessagingConversationMember(
        conversationId: String,
        userId: String
    ) async throws -> MessagingConversationDTO
    func messagingDeviceRoster(conversationId: String) async throws -> MessagingDeviceRosterDTO
    func historicalMessagingDeviceRoster(
        conversationId: String,
        rosterRevision: String
    ) async throws -> MessagingDeviceRosterDTO
    func consumeMessagingKeyBundles(
        conversationId: String,
        request: ConsumeMessagingKeyBundlesRequest
    ) async throws -> ConsumedMessagingKeyBundlesDTO
    func sendEncryptedMessage(
        conversationId: String,
        request: SendEncryptedMessageRequest
    ) async throws -> EncryptedMessageDTO
    func messagingHistoryBackfillCandidates(
        conversationId: String,
        targetDeviceId: String,
        targetEnrollmentEpoch: Int64,
        cursor: String?,
        limit: Int
    ) async throws -> MessagingHistoryBackfillCandidatesDTO
    func storeMessagingHistoryEnvelope(
        conversationId: String,
        messageId: String,
        request: StoreMessagingHistoryEnvelopeRequest
    ) async throws -> MessagingHistoryEnvelopeResultDTO
    func uploadMessagingAttachment(
        mediaType: String,
        ciphertext: Data
    ) async throws -> MessagingAttachmentUploadDTO
    func downloadMessagingAttachment(
        storageKey: String,
        expectedByteSize: Int64
    ) async throws -> Data
    func syncEncryptedMessages(cursor: String?, limit: Int) async throws -> MessagingSyncDTO
    func acknowledgeMessageDelivery(
        _ request: AcknowledgeMessageDeliveryRequest
    ) async throws -> MessageDeliveryAcknowledgementDTO
    func markMessagingConversationRead(
        conversationId: String,
        request: MarkMessagingConversationReadRequest
    ) async throws -> MessagingReadReceiptDTO
    func messagingMessageInfo(
        conversationId: String,
        messageId: String
    ) async throws -> MessagingMessageInfoDTO
    /// Re-read financial authority before projecting a group-request sync hint into chat. The
    /// sync payload is intentionally insufficient to authorize money movement or contributor
    /// attribution by itself.
    func groupPaymentRequest(id: String) async throws -> GroupPaymentRequestDTO
    func groupPaymentRequestContribution(
        requestId: String,
        contributionId: String
    ) async throws -> GroupPaymentRequestContributionDTO
    /// Scheduled group completion is only a sync hint. Re-read both the schedule and the money
    /// object before projecting the ordinary group-payment card into the conversation.
    func scheduledGroupPayment(id: String) async throws -> ScheduledGroupPaymentDTO
    func groupPayment(id: String) async throws -> GroupPaymentDTO
    /// Re-read a scheduled-payment terminal event before projecting it into chat. Completed
    /// recipient reads are deliberately redacted by the server but retain the fields matched by
    /// `ScheduledPaymentSyncEnvelope`.
    func scheduledPayment(id: String) async throws -> ScheduledPaymentDTO
    /// Server + account feature surface. The media-message-v2 admission gate re-reads this at
    /// flush time so a withdrawn rollout fails closed before any upload or ciphertext commit.
    func capabilities() async throws -> CapabilitiesDTO
}

extension SecureMessagingExchangeTransport {
    /// Delivery details fail closed on transports (and test doubles) that predate them, so a
    /// screen asking an older transport is told it cannot know rather than shown nothing at all.
    func messagingMessageInfo(
        conversationId: String,
        messageId: String
    ) async throws -> MessagingMessageInfoDTO {
        throw SecureMessagingExchangeError.invalidServerResponse
    }

    func groupPaymentRequest(id: String) async throws -> GroupPaymentRequestDTO {
        throw SecureMessagingExchangeError.invalidServerResponse
    }

    func groupPaymentRequestContribution(
        requestId: String,
        contributionId: String
    ) async throws -> GroupPaymentRequestContributionDTO {
        throw SecureMessagingExchangeError.invalidServerResponse
    }

    func scheduledGroupPayment(id: String) async throws -> ScheduledGroupPaymentDTO {
        throw SecureMessagingExchangeError.invalidServerResponse
    }

    func groupPayment(id: String) async throws -> GroupPaymentDTO {
        throw SecureMessagingExchangeError.invalidServerResponse
    }

    func scheduledPayment(id: String) async throws -> ScheduledPaymentDTO {
        throw SecureMessagingExchangeError.invalidServerResponse
    }

    /// Group creation fails closed on transports (and test doubles) that predate it.
    func createGroupMessagingConversation(
        memberIds: [String],
        title: String
    ) async throws -> MessagingConversationDTO {
        throw SecureMessagingExchangeError.invalidServerResponse
    }

    func renameGroupMessagingConversation(
        conversationId: String,
        title: String
    ) async throws -> MessagingConversationDTO {
        throw SecureMessagingExchangeError.invalidServerResponse
    }

    func updateGroupMessagingConversationDescription(
        conversationId: String,
        description: String?
    ) async throws -> MessagingConversationDTO {
        throw SecureMessagingExchangeError.invalidServerResponse
    }

    func attachGroupMessagingConversationPhoto(
        conversationId: String,
        assetId: String
    ) async throws -> MessagingConversationDTO {
        throw SecureMessagingExchangeError.invalidServerResponse
    }

    func removeGroupMessagingConversationPhoto(
        conversationId: String
    ) async throws -> MessagingConversationDTO {
        throw SecureMessagingExchangeError.invalidServerResponse
    }

    func addGroupMessagingConversationMember(
        conversationId: String,
        userId: String
    ) async throws -> MessagingConversationDTO {
        throw SecureMessagingExchangeError.invalidServerResponse
    }

    func removeGroupMessagingConversationMember(
        conversationId: String,
        userId: String
    ) async throws -> MessagingConversationDTO {
        throw SecureMessagingExchangeError.invalidServerResponse
    }

    func messagingHistoryBackfillCandidates(
        conversationId: String,
        targetDeviceId: String,
        targetEnrollmentEpoch: Int64,
        cursor: String?,
        limit: Int
    ) async throws -> MessagingHistoryBackfillCandidatesDTO {
        throw SecureMessagingExchangeError.invalidServerResponse
    }

    func storeMessagingHistoryEnvelope(
        conversationId: String,
        messageId: String,
        request: StoreMessagingHistoryEnvelopeRequest
    ) async throws -> MessagingHistoryEnvelopeResultDTO {
        throw SecureMessagingExchangeError.invalidServerResponse
    }

    /// Capability reads fail closed on transports (and test doubles) that predate them: no
    /// advertisement means no multi-attachment admission, never a permissive default.
    func capabilities() async throws -> CapabilitiesDTO {
        throw SecureMessagingExchangeError.invalidServerResponse
    }
}

extension APIClient: SecureMessagingExchangeTransport {}

enum SecureMessagingExchangeError: LocalizedError, Equatable {
    case invalidAccount
    case invalidRecipient
    case invalidConversation
    case messageNotRetryable
    case invalidServerResponse
    case unsupportedEvent(String)
    case staleOutboundFanout
    case retryLimitExceeded
    case groupCapabilityUnavailable
    case reactionCapabilityUnavailable
    case editCapabilityUnavailable
    case mediaMessageCapabilityUnavailable
    case mediaMessageBlobExpired
    case mediaMessageRosterChanged

    var errorDescription: String? {
        switch self {
        case .invalidAccount: "Your messaging account changed. Sign in again to continue."
        case .invalidRecipient: "Choose one valid Kit Pay recipient."
        case .invalidConversation: "This conversation is no longer available."
        case .messageNotRetryable: "This message can no longer be retried."
        case .invalidServerResponse: "Kit could not load this conversation. Please try again."
        case .unsupportedEvent: "Kit could not process a message update. Please try again."
        case .staleOutboundFanout: "The recipient's devices changed. Retry the message."
        case .retryLimitExceeded: "Messages changed while syncing. Please try again."
        case .groupCapabilityUnavailable:
            "Everyone in this group needs the latest Kit Pay to receive messages."
        case .reactionCapabilityUnavailable:
            "Everyone in this conversation needs the latest Kit Pay to use reactions."
        case .editCapabilityUnavailable:
            "Everyone in this conversation needs the latest Kit Pay to see edited messages."
        case .mediaMessageCapabilityUnavailable:
            "Multiple attachments aren't available for this chat right now."
        case .mediaMessageBlobExpired:
            "The attachments expired before sending. Kit Pay is uploading them again."
        case .mediaMessageRosterChanged:
            "The recipient's devices changed. Kit Pay is securing this message again."
        }
    }
}

struct SecureMessagingQueueResult: Equatable {
    let conversation: Conversation
    let clientMessageID: UUID
}

struct SecureMessagingSyncResult: Equatable {
    let pages: Int
    let receivedMessages: Int
    let appliedTransitions: Int
}

enum SecureMessagingHistoryDescriptorDisposition {
    case authenticated(SecureMessagingAuthenticatedHistory)
    case suppressed(acknowledgementMessageID: String)
}

struct SecureMessagingHistoryBackfillTarget: Equatable {
    let conversationID: String
    let deviceID: String
    let enrollmentEpoch: Int64

    var key: String { "\(conversationID):\(deviceID)" }
}

enum SecureMessagingHistoryAttemptDisposition: Equatable {
    case retryLater
    case restartFromFirstPage
    case complete
}

/// Per-run scheduling state. A failed task is skipped for the rest of this drain, while a task
/// that advanced one page is deferred until every other eligible task has had the same chance.
struct SecureMessagingHistoryDrainState {
    let maximumWorkUnits: Int
    let batchSize: Int
    private(set) var workUnits = 0
    private(set) var madeProgress = false
    private(set) var failedTaskKeys: Set<String> = []
    private var deferredTaskKeys: Set<String> = []

    init(maximumWorkUnits: Int, batchSize: Int) {
        precondition(maximumWorkUnits > 0 && batchSize > 0)
        self.maximumWorkUnits = maximumWorkUnits
        self.batchSize = batchSize
    }

    mutating func nextBatch(
        from tasks: [SecureMessagingHistoryBackfillTask]
    ) -> [SecureMessagingHistoryBackfillTask] {
        guard workUnits < maximumWorkUnits else { return [] }
        var available = tasks.filter {
            !failedTaskKeys.contains($0.key) && !deferredTaskKeys.contains($0.key)
        }
        if available.isEmpty,
           !deferredTaskKeys.isEmpty,
           tasks.contains(where: { !failedTaskKeys.contains($0.key) }) {
            deferredTaskKeys.removeAll()
            available = tasks.filter { !failedTaskKeys.contains($0.key) }
        }
        return Array(available.prefix(min(batchSize, maximumWorkUnits - workUnits)))
    }

    mutating func recordAttempt(
        of task: SecureMessagingHistoryBackfillTask,
        madeProgress: Bool
    ) {
        precondition(workUnits < maximumWorkUnits)
        workUnits += 1
        if madeProgress {
            self.madeProgress = true
            deferredTaskKeys.insert(task.key)
        } else {
            failedTaskKeys.insert(task.key)
            deferredTaskKeys.remove(task.key)
        }
    }
}

enum SecureMessagingHistoryContinuationPolicy {
    static let failureRetryNanoseconds: UInt64 = 30_000_000_000

    static func delayNanoseconds(pending: Bool, madeProgress: Bool) -> UInt64? {
        guard pending else { return nil }
        return madeProgress ? 0 : failureRetryNanoseconds
    }
}

/// Owns the network/crypto transaction boundary. The release gate remains in AppModel; this actor
/// is intentionally usable from focused tests before any production UI can enable messaging.
/// Access to the encrypted media file cache for deferred (offline-queued) attachments whose
/// plaintext is too large to live inline in the state file. Injected so unit tests can run the
/// deferred pipeline against in-memory blobs.
struct SecureMediaBlobStoreAccess {
    var read: @Sendable (_ storageKey: String, _ userID: String) async -> Data?
    /// Non-overwriting duplication performed atomically inside the cache actor: existence
    /// check, byte comparison, write, and verification as one uninterrupted step. There is
    /// deliberately no overwriting copy primitive at this boundary.
    var duplicateIfAbsent: @Sendable (
        _ fromKey: String, _ toKey: String, _ userID: String
    ) async -> SecureMediaDuplicateOutcome
    /// Removes `key` only while byte-identical content survives under `keeping`, atomically
    /// inside the cache actor — a delete that can never destroy the last copy.
    var removeDuplicate: @Sendable (
        _ key: String, _ keeping: String, _ userID: String
    ) async -> Bool
    var remove: @Sendable (_ storageKey: String, _ userID: String) async -> Void

    static let fileCache = SecureMediaBlobStoreAccess(
        read: { key, userID in
            await SecureMediaFileCache.shared.data(forStorageKey: key, userID: userID)
        },
        duplicateIfAbsent: { fromKey, toKey, userID in
            await SecureMediaFileCache.shared.duplicate(
                fromStorageKey: fromKey,
                toStorageKey: toKey,
                userID: userID
            )
        },
        removeDuplicate: { key, survivor, userID in
            await SecureMediaFileCache.shared.removeDuplicate(
                forStorageKey: key,
                keeping: survivor,
                userID: userID
            )
        },
        remove: { key, userID in
            await SecureMediaFileCache.shared.remove(forStorageKey: key, userID: userID)
        }
    )
}

actor SecureMessagingExchangeCoordinator {
    static let shared = SecureMessagingExchangeCoordinator(
        transport: APIClient.shared,
        store: SecureLocalStore.shared,
        engine: SecureMessagingCryptoEngine.shared
    )

    private let transport: any SecureMessagingExchangeTransport
    private let store: SecureLocalStore
    private let engine: SecureMessagingCryptoEngine
    private let activation: SecureMessagingCoordinator
    private let mediaBlobs: SecureMediaBlobStoreAccess
    private var syncTask: Task<SecureMessagingSyncResult, Error>?
    private var syncUserID: String?
    private var isFlushingHistory = false
    private var historyReconciledEnrollment: SecureMessagingEnrollmentBinding?
    private var historyContinuationTask: Task<Void, Never>?
    private var historyContinuationUserID: String?
    private var historyContinuationDelayNanoseconds: UInt64?
    private var historyContinuationGeneration: UInt64 = 0

    init(
        transport: any SecureMessagingExchangeTransport,
        store: SecureLocalStore,
        engine: SecureMessagingCryptoEngine,
        provisioningPreKeyCount: Int = SecureMessagingCryptoEngine.uploadPreKeyCount,
        mediaBlobs: SecureMediaBlobStoreAccess = .fileCache
    ) {
        self.transport = transport
        self.store = store
        self.engine = engine
        self.mediaBlobs = mediaBlobs
        activation = SecureMessagingCoordinator(
            transport: transport,
            store: store,
            engine: engine,
            provisioningPreKeyCount: provisioningPreKeyCount
        )
    }

    func activate(forUserID userID: String) async throws {
        _ = try await activation.activate(forUserID: userID)
        try await flushDeliveryAcknowledgements(forUserID: userID)
    }

    /// Creates or reuses the server-authoritative direct thread and persists its validated local
    /// projection before returning. Call surfaces use this instead of inventing a local thread id,
    /// so navigation can occur only after authenticated server and encrypted-store success.
    func ensureDirectConversation(
        forUserID userID: String,
        recipientUserID: String,
        title: String,
        expectedConversationID: String? = nil,
        commitAdmission: ProtectedCommunicationAdmissionLease? = nil
    ) async throws -> Conversation {
        let recipient = try canonicalUUID(recipientUserID, error: .invalidRecipient)
        let local = try canonicalUUID(userID, error: .invalidAccount)
        guard recipient != local else { throw SecureMessagingExchangeError.invalidRecipient }
        let canonicalExpectedConversationID = try expectedConversationID.map {
            try canonicalUUID($0, error: .invalidConversation)
        }
        if let commitAdmission,
           !ProtectedCommunicationAdmissionGate.shared.permits(commitAdmission) {
            throw CancellationError()
        }

        let dto = try await transport.createDirectMessagingConversation(
            try CreateDirectMessagingConversationRequest(memberId: recipient)
        )
        let validated = try validateConversation(
            dto,
            currentUserID: local,
            expectedRecipientUserID: recipient,
            fallbackTitle: title
        )
        guard canonicalExpectedConversationID == nil
                || validated.id == canonicalExpectedConversationID
        else {
            throw SecureMessagingExchangeError.invalidConversation
        }
        if let commitAdmission,
           !ProtectedCommunicationAdmissionGate.shared.permits(commitAdmission) {
            throw CancellationError()
        }

        let projection = validated.localProjection
        let persist: (inout PersistedState) throws -> Void = { state in
            guard state.profile?.id.caseInsensitiveCompare(local) == .orderedSame,
                  state.communicationOwnerUserID?.caseInsensitiveCompare(local) == .orderedSame,
                  state.secureMessaging?.enrollment?.userID == local
            else { throw SecureMessagingExchangeError.invalidAccount }
            let sameID = state.conversations.filter {
                $0.id.caseInsensitiveCompare(validated.id) == .orderedSame
            }
            // A group can legitimately contain exactly these two people; only another DIRECT
            // thread with the same member pair is a competing duplicate.
            let competingDirectThreads = state.conversations.filter {
                !$0.isGroup
                    && Set($0.participantUserIds.map { $0.lowercased() })
                        == validated.memberUserIDs
                    && $0.id.caseInsensitiveCompare(validated.id) != .orderedSame
            }
            guard sameID.count <= 1, competingDirectThreads.isEmpty else {
                throw SecureMessagingExchangeError.invalidConversation
            }
            if let index = state.conversations.firstIndex(where: {
                $0.id.caseInsensitiveCompare(validated.id) == .orderedSame
            }) {
                // Preserve the durable unread projection while refreshing only authenticated
                // server-owned identity and ordering fields.
                let existing = state.conversations[index]
                state.conversations[index] = Conversation(
                    id: projection.id,
                    title: projection.title,
                    participantUserIds: projection.participantUserIds,
                    unreadCount: existing.unreadCount,
                    updatedAt: max(existing.updatedAt, projection.updatedAt),
                    conversationType: projection.conversationType,
                    groupMemberRoles: projection.groupMemberRoles
                )
            } else {
                state.conversations.append(projection)
            }
        }
        if let commitAdmission {
            try await store.update(admission: commitAdmission, persist)
        } else {
            try await store.update(persist)
        }

        let snapshot = await store.snapshot()
        guard commitAdmission.map({
            ProtectedCommunicationAdmissionGate.shared.permits($0)
        }) ?? true,
              snapshot.profile?.id.caseInsensitiveCompare(local) == .orderedSame,
              snapshot.communicationOwnerUserID?.caseInsensitiveCompare(local) == .orderedSame,
              snapshot.secureMessaging?.enrollment?.userID == local
        else { throw CancellationError() }
        let matches = snapshot.conversations.filter {
            $0.id.caseInsensitiveCompare(validated.id) == .orderedSame
                && Set($0.participantUserIds.map { $0.lowercased() })
                    == validated.memberUserIDs
        }
        guard matches.count == 1 else {
            throw SecureMessagingExchangeError.invalidConversation
        }
        return matches[0]
    }

    /// Creates a server-authoritative GROUP thread and persists its validated local projection
    /// before returning its id. Fail-closed: the release gate (`messaging_groups`) lives in
    /// AppModel; this actor still re-validates the returned DTO type, size, and member set, and
    /// every later send re-checks per-device group attestation at flush time.
    func createGroupConversation(
        forUserID userID: String,
        memberUserIDs: [String],
        title: String
    ) async throws -> Conversation {
        let local = try canonicalUUID(userID, error: .invalidAccount)
        let members = try memberUserIDs.map {
            try canonicalUUID($0, error: .invalidRecipient)
        }
        guard Set(members).count == members.count,
              !members.contains(local),
              (1 ... SecureMessagingWire.maximumGroupMembers - 1).contains(members.count)
        else { throw SecureMessagingExchangeError.invalidRecipient }

        let dto = try await transport.createGroupMessagingConversation(
            memberIds: members.sorted(),
            title: title
        )
        let validated = try validateConversation(
            dto,
            currentUserID: local,
            expectedRecipientUserID: nil,
            fallbackTitle: title
        )
        guard validated.isGroup,
              Set(members + [local]) == validated.memberUserIDs
        else { throw SecureMessagingExchangeError.invalidConversation }

        let projection = validated.localProjection
        try await store.update { state in
            guard state.profile?.id.caseInsensitiveCompare(local) == .orderedSame,
                  state.communicationOwnerUserID?.caseInsensitiveCompare(local) == .orderedSame,
                  state.secureMessaging?.enrollment?.userID == local
            else { throw SecureMessagingExchangeError.invalidAccount }
            let sameID = state.conversations.filter {
                $0.id.caseInsensitiveCompare(validated.id) == .orderedSame
            }
            guard sameID.count <= 1 else {
                throw SecureMessagingExchangeError.invalidConversation
            }
            if let index = state.conversations.firstIndex(where: {
                $0.id.caseInsensitiveCompare(validated.id) == .orderedSame
            }) {
                // Preserve the durable unread projection while refreshing only authenticated
                // server-owned identity and ordering fields.
                let existing = state.conversations[index]
                if Self.serverProjectionIsNotOlder(
                    conversationID: projection.id,
                    updatedAt: projection.updatedAt,
                    in: state
                ) {
                    state.conversations[index] = Conversation(
                        id: projection.id,
                        title: projection.title,
                        participantUserIds: projection.participantUserIds,
                        unreadCount: existing.unreadCount,
                        updatedAt: max(existing.updatedAt, projection.updatedAt),
                        conversationType: projection.conversationType,
                        groupMemberRoles: projection.groupMemberRoles
                    )
                    Self.recordServerProjection(
                        conversationID: projection.id,
                        updatedAt: projection.updatedAt,
                        in: &state
                    )
                }
            } else {
                state.conversations.append(projection)
                Self.recordServerProjection(
                    conversationID: projection.id,
                    updatedAt: projection.updatedAt,
                    in: &state
                )
            }
        }

        let snapshot = await store.snapshot()
        guard snapshot.profile?.id.caseInsensitiveCompare(local) == .orderedSame,
              snapshot.communicationOwnerUserID?.caseInsensitiveCompare(local) == .orderedSame,
              snapshot.secureMessaging?.enrollment?.userID == local
        else { throw CancellationError() }
        let matches = snapshot.conversations.filter {
            $0.id.caseInsensitiveCompare(validated.id) == .orderedSame
                && Set($0.participantUserIds.map { $0.lowercased() })
                    == validated.memberUserIDs
                && $0.isGroup
        }
        guard matches.count == 1 else {
            throw SecureMessagingExchangeError.invalidConversation
        }
        return matches[0]
    }

    /// Applies a server-authoritative title response. The global rollout/device-roster admission
    /// for this expansion is enforced by AppModel and the backend; the actor still binds the
    /// response to the exact group, active caller, and requested normalized title.
    func renameGroupConversation(
        forUserID userID: String,
        conversationID rawConversationID: String,
        title: String
    ) async throws -> Conversation {
        let local = try canonicalUUID(userID, error: .invalidAccount)
        let conversationID = try canonicalUUID(
            rawConversationID,
            error: .invalidConversation
        )
        let cleanTitle = MessagingGroupTitlePolicy.normalized(title)
        guard MessagingGroupTitlePolicy.isValid(cleanTitle) else {
            throw SecureMessagingExchangeError.invalidConversation
        }
        let existing = try await localGroup(
            conversationID: conversationID,
            currentUserID: local,
            requiresManagerRole: true
        )
        try await requireCurrentGroupCapability(existing, currentUserID: local)
        let dto = try await transport.renameGroupMessagingConversation(
            conversationId: conversationID,
            title: cleanTitle
        )
        _ = try parseServerDate(dto.updatedAt)
        let validated = try validateConversation(
            dto,
            currentUserID: local,
            expectedRecipientUserID: nil,
            fallbackTitle: cleanTitle
        )
        guard validated.isGroup,
              validated.id == conversationID,
              validated.title == cleanTitle
        else { throw SecureMessagingExchangeError.invalidServerResponse }
        return try await commitGroupProjection(validated.localProjection, currentUserID: local)
    }

    /// Sets or clears the group description. Same admission and binding as a rename: manager
    /// role and device capability up front, then the server's own answer replaces the local
    /// projection — a refusal never leaves a locally invented description behind.
    func updateGroupConversationDescription(
        forUserID userID: String,
        conversationID rawConversationID: String,
        description rawDescription: String?
    ) async throws -> Conversation {
        let local = try canonicalUUID(userID, error: .invalidAccount)
        let conversationID = try canonicalUUID(
            rawConversationID,
            error: .invalidConversation
        )
        let description = rawDescription
            .map(MessagingGroupDescriptionPolicy.normalized)
            .flatMap { $0.isEmpty ? nil : $0 }
        if let description {
            guard MessagingGroupDescriptionPolicy.isValid(description) else {
                throw SecureMessagingExchangeError.invalidConversation
            }
        }
        let existing = try await localGroup(
            conversationID: conversationID,
            currentUserID: local,
            requiresManagerRole: true
        )
        try await requireCurrentGroupCapability(existing, currentUserID: local)
        let dto = try await transport.updateGroupMessagingConversationDescription(
            conversationId: conversationID,
            description: description
        )
        _ = try parseServerDate(dto.updatedAt)
        let validated = try validateConversation(
            dto,
            currentUserID: local,
            expectedRecipientUserID: nil,
            fallbackTitle: existing.title
        )
        guard validated.isGroup,
              validated.id == conversationID,
              validated.groupDescription == description
        else { throw SecureMessagingExchangeError.invalidServerResponse }
        return try await commitGroupProjection(validated.localProjection, currentUserID: local)
    }

    /// Makes an already-uploaded, scanned avatar asset the group's photo. The server re-proves
    /// ownership, sanitation, and management rights; the response must actually carry a photo.
    func attachGroupConversationPhoto(
        forUserID userID: String,
        conversationID rawConversationID: String,
        assetID rawAssetID: String
    ) async throws -> Conversation {
        let local = try canonicalUUID(userID, error: .invalidAccount)
        let conversationID = try canonicalUUID(
            rawConversationID,
            error: .invalidConversation
        )
        let assetID = try canonicalUUID(rawAssetID, error: .invalidServerResponse)
        let existing = try await localGroup(
            conversationID: conversationID,
            currentUserID: local,
            requiresManagerRole: true
        )
        try await requireCurrentGroupCapability(existing, currentUserID: local)
        let dto = try await transport.attachGroupMessagingConversationPhoto(
            conversationId: conversationID,
            assetId: assetID
        )
        _ = try parseServerDate(dto.updatedAt)
        let validated = try validateConversation(
            dto,
            currentUserID: local,
            expectedRecipientUserID: nil,
            fallbackTitle: existing.title
        )
        guard validated.isGroup,
              validated.id == conversationID,
              let photoURL = validated.groupPhotoURL,
              photoURL.localizedCaseInsensitiveContains(assetID)
        else { throw SecureMessagingExchangeError.invalidServerResponse }
        return try await commitGroupProjection(validated.localProjection, currentUserID: local)
    }

    func removeGroupConversationPhoto(
        forUserID userID: String,
        conversationID rawConversationID: String
    ) async throws -> Conversation {
        let local = try canonicalUUID(userID, error: .invalidAccount)
        let conversationID = try canonicalUUID(
            rawConversationID,
            error: .invalidConversation
        )
        let existing = try await localGroup(
            conversationID: conversationID,
            currentUserID: local,
            requiresManagerRole: true
        )
        try await requireCurrentGroupCapability(existing, currentUserID: local)
        let dto = try await transport.removeGroupMessagingConversationPhoto(
            conversationId: conversationID
        )
        _ = try parseServerDate(dto.updatedAt)
        let validated = try validateConversation(
            dto,
            currentUserID: local,
            expectedRecipientUserID: nil,
            fallbackTitle: existing.title
        )
        guard validated.isGroup,
              validated.id == conversationID,
              validated.groupPhotoURL == nil
        else { throw SecureMessagingExchangeError.invalidServerResponse }
        return try await commitGroupProjection(validated.localProjection, currentUserID: local)
    }

    /// Adds exactly one eligible member. A fresh server DTO replaces the entire local roster so
    /// concurrent membership changes cannot be overwritten by a stale client-side union.
    func addGroupConversationMember(
        forUserID userID: String,
        conversationID rawConversationID: String,
        memberUserID rawMemberUserID: String
    ) async throws -> Conversation {
        let local = try canonicalUUID(userID, error: .invalidAccount)
        let conversationID = try canonicalUUID(
            rawConversationID,
            error: .invalidConversation
        )
        let memberUserID = try canonicalUUID(rawMemberUserID, error: .invalidRecipient)
        let existing = try await localGroup(
            conversationID: conversationID,
            currentUserID: local,
            requiresManagerRole: true
        )
        guard memberUserID != local,
              !existing.participantUserIds.contains(memberUserID),
              existing.participantUserIds.count < SecureMessagingWire.maximumGroupMembers
        else { throw SecureMessagingExchangeError.invalidRecipient }
        // The pre-add roster proves every existing device. The backend then performs the same
        // check again while atomically including every device owned by the prospective member.
        try await requireCurrentGroupCapability(existing, currentUserID: local)
        let dto = try await transport.addGroupMessagingConversationMember(
            conversationId: conversationID,
            userId: memberUserID
        )
        _ = try parseServerDate(dto.updatedAt)
        let validated = try validateConversation(
            dto,
            currentUserID: local,
            expectedRecipientUserID: nil,
            fallbackTitle: existing.title
        )
        guard validated.isGroup,
              validated.id == conversationID,
              validated.memberUserIDs.contains(memberUserID)
        else { throw SecureMessagingExchangeError.invalidServerResponse }
        return try await commitGroupProjection(validated.localProjection, currentUserID: local)
    }

    /// Removes a member or leaves the group. Deliberately contains no group feature/device
    /// capability check: DELETE is the backend's safety path when rollout is dark or a device is
    /// incompatible. Server role checks remain authoritative and the response replaces the
    /// complete active roster.
    func removeGroupConversationMember(
        forUserID userID: String,
        conversationID rawConversationID: String,
        memberUserID rawMemberUserID: String
    ) async throws -> Conversation {
        let local = try canonicalUUID(userID, error: .invalidAccount)
        let conversationID = try canonicalUUID(
            rawConversationID,
            error: .invalidConversation
        )
        let memberUserID = try canonicalUUID(rawMemberUserID, error: .invalidRecipient)
        let existing = try await localGroup(
            conversationID: conversationID,
            currentUserID: local,
            requiresManagerRole: memberUserID != local
        )
        guard existing.participantUserIds.contains(memberUserID) else {
            throw SecureMessagingExchangeError.invalidRecipient
        }
        if memberUserID != local {
            guard let actorRole = existing.groupRole(for: local),
                  let targetRole = existing.groupRole(for: memberUserID),
                  actorRole.canRemove(targetRole)
            else { throw SecureMessagingExchangeError.invalidRecipient }
        }

        let dto = try await transport.removeGroupMessagingConversationMember(
            conversationId: conversationID,
            userId: memberUserID
        )
        let responseUpdatedAt = try parseServerDate(dto.updatedAt)
        let projection: Conversation
        if memberUserID == local {
            projection = try validateDepartedGroupConversation(
                dto,
                conversationID: conversationID,
                currentUserID: local,
                updatedAt: responseUpdatedAt
            )
        } else {
            let validated = try validateConversation(
                dto,
                currentUserID: local,
                expectedRecipientUserID: nil,
                fallbackTitle: existing.title
            )
            guard validated.isGroup,
                  validated.id == conversationID,
                  !validated.memberUserIDs.contains(memberUserID)
            else { throw SecureMessagingExchangeError.invalidServerResponse }
            projection = validated.localProjection
        }
        return try await commitGroupProjection(projection, currentUserID: local)
    }

    private func localGroup(
        conversationID: String,
        currentUserID: String,
        requiresManagerRole: Bool
    ) async throws -> Conversation {
        let snapshot = await store.snapshot()
        guard snapshot.profile?.id.caseInsensitiveCompare(currentUserID) == .orderedSame,
              snapshot.communicationOwnerUserID?
                .caseInsensitiveCompare(currentUserID) == .orderedSame,
              snapshot.secureMessaging?.enrollment?.userID == currentUserID
        else { throw SecureMessagingExchangeError.invalidAccount }
        let matches = snapshot.conversations.filter { $0.id == conversationID }
        guard matches.count == 1,
              let conversation = matches.first,
              conversation.isGroup,
              conversation.participantUserIds.contains(currentUserID),
              !requiresManagerRole
                || conversation.groupRole(for: currentUserID)?.canManageGroup == true
        else { throw SecureMessagingExchangeError.invalidConversation }
        return conversation
    }

    private func requireCurrentGroupCapability(
        _ conversation: Conversation,
        currentUserID: String
    ) async throws {
        let snapshot = await store.snapshot()
        guard let enrollment = snapshot.secureMessaging?.enrollment,
              enrollment.userID == currentUserID
        else { throw SecureMessagingExchangeError.invalidAccount }
        let roster = try await transport.messagingDeviceRoster(conversationId: conversation.id)
        guard MessagingGroupCapabilityPolicy.supports(
            roster: roster,
            conversationID: conversation.id,
            currentDeviceID: enrollment.serverDeviceID,
            memberUserIDs: Set(conversation.participantUserIds)
        ) else { throw SecureMessagingExchangeError.groupCapabilityUnavailable }
    }

    private func commitGroupProjection(
        _ projection: Conversation,
        currentUserID: String
    ) async throws -> Conversation {
        try await store.update { state in
            guard state.profile?.id.caseInsensitiveCompare(currentUserID) == .orderedSame,
                  state.communicationOwnerUserID?
                    .caseInsensitiveCompare(currentUserID) == .orderedSame,
                  state.secureMessaging?.enrollment?.userID == currentUserID,
                  state.conversations.filter({ $0.id == projection.id }).count == 1,
                  let index = state.conversations.firstIndex(where: { $0.id == projection.id }),
                  state.conversations[index].isGroup
            else { throw SecureMessagingExchangeError.invalidAccount }
            let existing = state.conversations[index]
            // A mutation response can arrive after realtime sync has already committed a newer
            // full conversation projection. Preserve that newer title, roster, and role map as
            // one unit; combining its timestamp with fields from the older response would create
            // a locally impossible state and could re-add a removed member.
            if Self.serverProjectionIsNotOlder(
                conversationID: projection.id,
                updatedAt: projection.updatedAt,
                in: state
            ) {
                state.conversations[index] = Conversation(
                    id: projection.id,
                    title: projection.title,
                    participantUserIds: projection.participantUserIds,
                    unreadCount: existing.unreadCount,
                    updatedAt: projection.updatedAt,
                    conversationType: SecureMessagingWire.groupConversationType,
                    groupMemberRoles: projection.groupMemberRoles,
                    groupDescription: projection.groupDescription,
                    groupPhotoURL: projection.groupPhotoURL
                )
                Self.recordServerProjection(
                    conversationID: projection.id,
                    updatedAt: projection.updatedAt,
                    in: &state
                )
            }
            if !state.conversations[index].participantUserIds.contains(currentUserID) {
                Self.abandonSecureGroupOutbox(
                    conversationID: projection.id,
                    in: &state
                )
            }
        }
        let snapshot = await store.snapshot()
        guard snapshot.profile?.id.caseInsensitiveCompare(currentUserID) == .orderedSame,
              let committed = snapshot.conversations.first(where: { $0.id == projection.id })
        else { throw CancellationError() }
        return committed
    }

    private nonisolated static func abandonSecureGroupOutbox(
        conversationID: String,
        in state: inout PersistedState
    ) {
        let abandonedMessageIDs = Set(state.outbox.compactMap { command -> UUID? in
            guard command.kind == .secureMessage,
                  command.conversationId == conversationID
            else { return nil }
            return command.messageId
        })
        state.outbox.removeAll {
            $0.kind == .secureMessage && $0.conversationId == conversationID
        }
        for messageIndex in state.messages.indices
            where abandonedMessageIDs.contains(state.messages[messageIndex].id) {
            state.messages[messageIndex].state = .failed
            state.messages[messageIndex].failureReason =
                "You left this group before this message was sent."
        }
    }

    private func validateDepartedGroupConversation(
        _ dto: MessagingConversationDTO,
        conversationID: String,
        currentUserID: String,
        updatedAt: Date
    ) throws -> Conversation {
        guard dto.type == SecureMessagingWire.groupConversationType,
              let rawID = dto.id,
              try canonicalUUID(rawID, error: .invalidConversation) == conversationID,
              let rawTitle = dto.title,
              MessagingGroupTitlePolicy.isValid(rawTitle),
              let rawMembers = dto.members,
              rawMembers.allSatisfy({ $0 != nil })
        else { throw SecureMessagingExchangeError.invalidServerResponse }
        let members = rawMembers.compactMap { $0 }
        guard members.count <= SecureMessagingWire.maximumGroupMembers - 1 else {
            throw SecureMessagingExchangeError.invalidServerResponse
        }
        var memberIDs: [String] = []
        var roles: [String: MessagingGroupRole] = [:]
        for member in members {
            guard let userID = try? canonicalUUID(member.userId, error: .invalidConversation),
                  let rawRole = member.role,
                  let role = MessagingGroupRole(rawValue: rawRole),
                  roles[userID] == nil
            else { throw SecureMessagingExchangeError.invalidServerResponse }
            memberIDs.append(userID)
            roles[userID] = role
        }
        guard !memberIDs.contains(currentUserID),
              let title = dto.title.map(MessagingGroupTitlePolicy.normalized),
              MessagingGroupTitlePolicy.isValid(title)
        else { throw SecureMessagingExchangeError.invalidServerResponse }
        return Conversation(
            id: conversationID,
            title: title,
            participantUserIds: memberIDs.sorted(),
            unreadCount: 0,
            updatedAt: updatedAt,
            conversationType: SecureMessagingWire.groupConversationType,
            groupMemberRoles: roles
        )
    }

    func queueDirectText(
        forUserID userID: String,
        recipientUserID: String,
        title: String,
        text: String,
        clientMessageID: UUID? = nil
    ) async throws -> SecureMessagingQueueResult {
        let recipient = try canonicalUUID(recipientUserID, error: .invalidRecipient)
        let local = try canonicalUUID(userID, error: .invalidAccount)
        guard recipient != local else { throw SecureMessagingExchangeError.invalidRecipient }
        let dto = try await transport.createDirectMessagingConversation(
            try CreateDirectMessagingConversationRequest(memberId: recipient)
        )
        let validated = try validateConversation(
            dto,
            currentUserID: local,
            expectedRecipientUserID: recipient,
            fallbackTitle: title
        )
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let clientMessageID,
           let existing = try Self.existingDeferredTextResult(
               in: await store.snapshot(),
               clientMessageID: clientMessageID,
               localUserID: local,
               recipientUserIDs: [recipient],
               conversation: validated.localProjection,
               body: body,
               scheduledAt: nil
           ) {
            return existing
        }
        return try await queueText(
            forUserID: local,
            conversation: validated,
            text: body,
            newClientMessageID: clientMessageID
        )
    }

    func queueText(
        forUserID userID: String,
        conversationID: String,
        expectedRecipientUserID: String,
        title: String,
        text: String
    ) async throws -> SecureMessagingQueueResult {
        let local = try canonicalUUID(userID, error: .invalidAccount)
        let conversationID = try canonicalUUID(
            conversationID,
            error: .invalidConversation
        )
        let recipient = try canonicalUUID(
            expectedRecipientUserID,
            error: .invalidRecipient
        )
        let dto = try await transport.messagingConversation(id: conversationID)
        let validated = try validateConversation(
            dto,
            currentUserID: local,
            expectedRecipientUserID: recipient,
            fallbackTitle: title
        )
        return try await queueText(
            forUserID: local,
            conversation: validated,
            text: text
        )
    }

    /// Commits a plaintext projection only inside SecureLocalStore while offline. No ciphertext
    /// fanout is guessed from a stale roster; reconnect prepares it against the authoritative
    /// server roster and atomically advances the Signal ratchets before transport replay.
    ///
    /// `expectedRecipientUserID` is nil ONLY for group threads: the direct two-party check runs
    /// unchanged whenever a recipient is pinned, and a nil recipient fails closed unless the
    /// stored conversation is a validated group containing the local user.
    func queueDeferredText(
        forUserID userID: String,
        conversationID: String,
        expectedRecipientUserID: String?,
        title: String,
        text: String,
        clientMessageID: UUID? = nil,
        submittedDraftBody: String? = nil,
        draftClearVersion: ConversationDraftWriteVersion? = nil,
        deliverAt: Date? = nil,
        replyToServerMessageID: String? = nil,
        commitAdmission: ProtectedCommunicationAdmissionLease? = nil
    ) async throws -> SecureMessagingQueueResult {
        guard (submittedDraftBody == nil) == (draftClearVersion == nil) else {
            throw SecureMessagingCryptoError.invalidContent
        }
        let local = try canonicalUUID(userID, error: .invalidAccount)
        let conversationID = try canonicalUUID(conversationID, error: .invalidConversation)
        let recipient = try expectedRecipientUserID.map {
            try canonicalUUID($0, error: .invalidRecipient)
        }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let beginsReaction = SecureMessageReservedPrefixPolicy.beginsWithReservedPrefix(
            body,
            prefix: KitMessageReaction.prefix
        )
        let reaction = KitMessageReaction.parse(body)
        let beginsEdit = SecureMessageReservedPrefixPolicy.beginsWithReservedPrefix(
            body,
            prefix: KitMessageEdit.prefix
        )
        let edit = KitMessageEdit.parse(body)
        guard !body.isEmpty,
              body.unicodeScalars.count <= 8_000,
              !body.unicodeScalars.contains(where: { $0.value == 0 }),
              KitMediaMessageDescriptor.parse(body) == nil,
              // Family-wide, every version: user-authored text may never be KITMEDIA-shaped.
              // Valid v1/v2 media enters only through the dedicated media queue paths; a
              // malformed or future family body must not become durable local "text" that
              // the binding policy would only strand at send time — after the raw
              // maybe-descriptor had already sat in the UI and the outbox.
              !KitMediaMessageFamilyPolicy.blocksUserAuthoredText(body),
              !beginsReaction || reaction != nil,
              reaction == nil || deliverAt == nil,
              // A reaction carries its own pointer inside the descriptor; it is never also an
              // answer to something.
              reaction == nil || replyToServerMessageID == nil,
              !beginsEdit || edit != nil,
              // The same two rules for a correction: it names its own target, and there is
              // nothing to correct about a message that has not been sent yet.
              edit == nil || deliverAt == nil,
              edit == nil || replyToServerMessageID == nil,
              replyToServerMessageID.map(SecureMessagingValidation.isCanonicalUUID) ?? true
        else { throw SecureMessagingCryptoError.invalidContent }
        let replyTarget = replyToServerMessageID?.lowercased()
        let snapshot = await store.snapshot()
        guard snapshot.profile?.id == local,
              snapshot.secureMessaging?.enrollment?.userID == local,
              let conversation = snapshot.conversations.first(where: {
                  $0.id == conversationID
              }),
              Self.permitsDeferredQueue(
                  conversation: conversation,
                  localUserID: local,
                  expectedRecipientUserID: recipient
              )
        else { throw SecureMessagingExchangeError.invalidConversation }
        if let reaction {
            try Self.requireLocalReactionTarget(
                reaction,
                conversationID: conversationID,
                in: snapshot
            )
        }
        if let edit {
            try Self.requireLocalEditTarget(
                edit,
                conversationID: conversationID,
                localUserID: local,
                in: snapshot,
                requiringWindow: true
            )
        }
        if let replyTarget {
            try Self.requireLocalReplyTarget(
                replyTarget,
                conversationID: conversationID,
                in: snapshot
            )
        }
        let commandRecipients = Self.deferredCommandRecipients(
            conversation: conversation,
            localUserID: local,
            expectedRecipientUserID: recipient
        )
        // Stable-id replay compares the originally requested minute before reapplying clock
        // eligibility: that minute may legitimately be in the past after a relaunch or timeout.
        let requestedMinute = deliverAt.map { ScheduledSendPolicy.canonicalMinute($0) }
        if let clientMessageID,
           let existing = try Self.existingDeferredTextResult(
               in: snapshot,
               clientMessageID: clientMessageID,
               localUserID: local,
               recipientUserIDs: commandRecipients,
               conversation: conversation,
               body: body,
               scheduledAt: requestedMinute
           ) {
            try await clearDraftAfterIdempotentQueueIfNeeded(
                clientMessageID: clientMessageID,
                conversationID: conversation.id,
                localUserID: local,
                submittedDraftBody: submittedDraftBody,
                draftClearVersion: draftClearVersion,
                commitAdmission: commitAdmission
            )
            return existing
        }

        let messageID = clientMessageID ?? UUID()
        let commandID = UUID()
        let createdAt = Date()
        // A Send Later item is an ordinary queued command dated forward. It is encrypted at its
        // send time against the roster that is authoritative then, exactly like every other
        // deferred message, so scheduling adds no second delivery path to keep idempotent.
        // A fresh invalid schedule fails closed; silently converting it to an immediate send
        // would violate the sender's explicit instruction.
        let scheduledAt = try deliverAt.map { requested -> Date in
            guard let normalized = ScheduledSendPolicy.normalize(requested, now: createdAt)
            else { throw SecureMessagingCryptoError.invalidContent }
            return normalized
        }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let localMessage = LocalMessage(
            id: messageID,
            conversationId: conversationID,
            senderId: local,
            body: body,
            createdAt: createdAt,
            sentAt: nil,
            state: .queued,
            failureReason: nil,
            isOutgoing: true,
            replyToServerMessageID: replyTarget,
            scheduledAt: scheduledAt
        )
        let command = OfflineCommand(
            id: commandID,
            kind: .secureMessage,
            createdAt: createdAt,
            nextAttemptAt: scheduledAt ?? createdAt,
            attemptCount: 0,
            conversationId: conversationID,
            messageId: messageID,
            recipientUserIds: commandRecipients,
            recipientName: cleanTitle.isEmpty ? conversation.title : cleanTitle,
            video: nil,
            expiresAt: nil,
            secureMessageFanout: nil,
            scheduledAt: scheduledAt
        )
        var updatedConversation = conversation
        // Reactions are timeline metadata, not chat activity. Keep the existing ordering date
        // locally just as the receiving path does after decrypting the descriptor. A correction
        // is the same: rewording something already said is not a new turn in the conversation,
        // so it must not push the thread back to the top of the list.
        // A scheduled item is likewise not activity yet: promoting the thread hours before
        // anything is sent would advertise the surprise the sender is arranging.
        if reaction == nil, edit == nil, scheduledAt == nil {
            updatedConversation.updatedAt = createdAt
        }
        let queuedConversation = updatedConversation
        let commitMutation: (inout PersistedState) throws -> Void = { state in
                guard state.profile?.id == local,
                      state.secureMessaging?.enrollment?.userID == local,
                      !state.messages.contains(where: { $0.id == messageID }),
                      !state.outbox.contains(where: { $0.id == commandID })
                else { throw StoreError.accountChanged }
                Self.upsert(conversation: queuedConversation, in: &state)
                state.messages.append(localMessage)
                state.outbox.append(command)
                if let submittedDraftBody, let draftClearVersion {
                    _ = ConversationDraftPolicy.clearAfterSuccessfulQueue(
                        submittedBody: submittedDraftBody,
                        conversationID: conversationID,
                        ownerUserID: local,
                        writeVersion: draftClearVersion,
                        in: &state
                    )
                }
        }
        do {
            if let commitAdmission {
                try await store.update(admission: commitAdmission, commitMutation)
            } else {
                try await store.update(commitMutation)
            }
        } catch StoreError.accountChanged {
            // A duplicate notification callback can race the first callback at the actor/store
            // suspension boundary. A stable client ID makes the protected projection itself the
            // idempotency receipt; any non-identical collision still fails closed.
            if let clientMessageID {
                let raced = await store.snapshot()
                guard raced.profile?.id == local,
                      raced.secureMessaging?.enrollment?.userID == local,
                      let racedConversation = raced.conversations.first(where: {
                          $0.id == conversationID
                      }),
                      Self.permitsDeferredQueue(
                          conversation: racedConversation,
                          localUserID: local,
                          expectedRecipientUserID: recipient
                      ),
                      let existing = try Self.existingDeferredTextResult(
                          in: raced,
                          clientMessageID: clientMessageID,
                          localUserID: local,
                          recipientUserIDs: Self.deferredCommandRecipients(
                              conversation: racedConversation,
                              localUserID: local,
                              expectedRecipientUserID: recipient
                          ),
                          conversation: racedConversation,
                          body: body,
                          scheduledAt: requestedMinute
                      )
                else { throw StoreError.accountChanged }
                try await clearDraftAfterIdempotentQueueIfNeeded(
                    clientMessageID: clientMessageID,
                    conversationID: racedConversation.id,
                    localUserID: local,
                    submittedDraftBody: submittedDraftBody,
                    draftClearVersion: draftClearVersion,
                    commitAdmission: commitAdmission
                )
                return existing
            }
            throw StoreError.accountChanged
        }
        return SecureMessagingQueueResult(
            conversation: queuedConversation,
            clientMessageID: messageID
        )
    }

    /// Direct queueing keeps its exact two-party rule; a nil pinned recipient is valid only for
    /// a stored, validated group thread that includes the local account. Fail closed otherwise.
    private static func permitsDeferredQueue(
        conversation: Conversation,
        localUserID: String,
        expectedRecipientUserID: String?
    ) -> Bool {
        if let recipient = expectedRecipientUserID {
            // A pinned single peer is exclusively a DIRECT contract — even a two-member group
            // must be addressed as a group so its roster/attestation semantics apply.
            return !conversation.isGroup
                && conversation.participantUserIds.count == 2
                && Set(conversation.participantUserIds) == Set([localUserID, recipient])
        }
        return conversation.isGroup
            && (2 ... SecureMessagingWire.maximumGroupMembers)
                .contains(conversation.participantUserIds.count)
            && Set(conversation.participantUserIds).count
                == conversation.participantUserIds.count
            && conversation.participantUserIds.contains(localUserID)
    }

    /// Rich media requires EVERY receiving member's devices to be attested — one stale member
    /// blocks the send instead of silently degrading or excluding them.
    private static func requireRichMediaRecipientSupport(
        mediaType: String,
        roster: MessagingDeviceRosterDTO,
        conversationID: String,
        currentDeviceID: String,
        recipientUserIDs: [String]
    ) throws {
        guard !recipientUserIDs.isEmpty,
              recipientUserIDs.allSatisfy({ recipient in
                  MessagingRichMediaCapabilityPolicy.supports(
                      mediaType: mediaType,
                      roster: roster,
                      conversationID: conversationID,
                      currentDeviceID: currentDeviceID,
                      recipientUserID: recipient
                  )
              })
        else { throw SecureMediaAttachmentError.incompatibleRecipient }
    }

    private static func requireLargeMediaRecipientSupport(
        plaintextByteSize: Int,
        roster: MessagingDeviceRosterDTO,
        conversationID: String,
        currentDeviceID: String,
        memberUserIDs: Set<String>
    ) throws {
        guard MessagingRichMediaCapabilityPolicy.supportsPlaintextByteSize(
            plaintextByteSize,
            roster: roster,
            conversationID: conversationID,
            currentDeviceID: currentDeviceID,
            memberUserIDs: memberUserIDs
        ) else { throw SecureMediaAttachmentError.incompatibleRecipient }
    }

    /// Sorted members minus self for groups; the single pinned peer for direct threads.
    private static func deferredCommandRecipients(
        conversation: Conversation,
        localUserID: String,
        expectedRecipientUserID: String?
    ) -> [String] {
        if let recipient = expectedRecipientUserID { return [recipient] }
        return conversation.participantUserIds.filter { $0 != localUserID }.sorted()
    }

    private static func requireLocalReactionTarget(
        _ reaction: KitMessageReaction,
        conversationID: String,
        in state: PersistedState
    ) throws {
        let matches = state.messages.filter {
            $0.conversationId == conversationID
                && $0.serverMessageId == reaction.targetServerMessageID
                && $0.secureMessagingHistory?.kind.isTimelineMetadata != true
        }
        guard matches.count == 1 else {
            throw SecureMessagingExchangeError.invalidConversation
        }
    }

    /// A correction may only reword one of this device's own messages, in the same thread, that
    /// the server has already acknowledged.
    ///
    /// `requiringWindow` is true only where the user is acting — the deadline is judged once,
    /// against the clock they can see. The flush pass deliberately does not re-judge it: an
    /// outbox item that waited out a tunnel or a flight would otherwise be discarded here on a
    /// device clock, when the server holds the only authoritative one and answers with
    /// `MESSAGING_EDIT_WINDOW_CLOSED` if the deadline really has passed.
    private static func requireLocalEditTarget(
        _ edit: KitMessageEdit,
        conversationID: String,
        localUserID: String,
        in state: PersistedState,
        requiringWindow: Bool
    ) throws {
        let matches = state.messages.filter { message in
            guard message.conversationId == conversationID,
                  message.serverMessageId?.lowercased() == edit.targetServerMessageID,
                  message.senderId == localUserID
            else { return false }
            return requiringWindow
                ? MessageEditAggregationPolicy.canEdit(message)
                : message.isOutgoing
                    && MessageEditAggregationPolicy.authenticatedEdit(in: message) == nil
                    // Family-wide: no media generation is wording — replacing a sealed
                    // descriptor of any version with a sentence would strand its media.
                    && !KitMediaMessageFamilyPolicy.isReservedFamilyText(message.body)
        }
        guard matches.count == 1 else {
            throw SecureMessagingExchangeError.invalidConversation
        }
    }

    /// An answer may only point at a message this device already holds in the same thread. That
    /// keeps the pointer from becoming a way to name an arbitrary server row from the client,
    /// and it is exactly what the sender saw when they swiped.
    private static func requireLocalReplyTarget(
        _ targetServerMessageID: String,
        conversationID: String,
        in state: PersistedState
    ) throws {
        let matches = state.messages.filter {
            $0.conversationId == conversationID
                && $0.serverMessageId?.lowercased() == targetServerMessageID
                && $0.secureMessagingHistory?.kind.isTimelineMetadata != true
        }
        guard matches.count == 1 else {
            throw SecureMessagingExchangeError.invalidConversation
        }
    }

    /// Restores one commandless failed plaintext message to the encrypted outbox without network
    /// access. This covers failures such as a stale device roster or sign-out cleanup, where the
    /// original command was deliberately discarded but its client message UUID remains the
    /// server idempotency key. Roster validation and fresh Signal fanout construction still occur
    /// through `prepareDeferredMessage` when the outbox is next flushed.
    func retryFailedTextMessage(
        messageID: UUID,
        forUserID userID: String,
        conversationID: String,
        expectedRecipientUserID: String,
        commitAdmission: ProtectedCommunicationAdmissionLease? = nil
    ) async throws -> SecureMessagingQueueResult {
        let local = try canonicalUUID(userID, error: .invalidAccount)
        let conversationID = try canonicalUUID(
            conversationID,
            error: .invalidConversation
        )
        let recipient = try canonicalUUID(
            expectedRecipientUserID,
            error: .invalidRecipient
        )
        guard local != recipient else { throw SecureMessagingExchangeError.invalidRecipient }

        let snapshot = await store.snapshot()
        let candidate = try Self.failedTextRetryCandidate(
            in: snapshot,
            messageID: messageID,
            userID: local,
            conversationID: conversationID,
            recipientUserID: recipient
        )
        if candidate.alreadyQueued {
            return SecureMessagingQueueResult(
                conversation: candidate.conversation,
                clientMessageID: messageID
            )
        }

        var commandID = UUID()
        while commandID == messageID { commandID = UUID() }
        let command = OfflineCommand(
            id: commandID,
            kind: .secureMessage,
            createdAt: candidate.message.createdAt,
            nextAttemptAt: Date(),
            attemptCount: 0,
            conversationId: conversationID,
            messageId: messageID,
            recipientUserIds: [recipient],
            recipientName: candidate.conversation.title,
            video: nil,
            expiresAt: nil,
            secureMessageFanout: nil
        )
        let mutation: (inout PersistedState) throws -> Void = { state in
            let current = try Self.failedTextRetryCandidate(
                in: state,
                messageID: messageID,
                userID: local,
                conversationID: conversationID,
                recipientUserID: recipient
            )
            if current.alreadyQueued { return }
            guard let messageIndex = state.messages.firstIndex(where: {
                $0.id == messageID
            }) else { throw SecureMessagingExchangeError.messageNotRetryable }
            state.messages[messageIndex].state = .queued
            state.messages[messageIndex].failureReason = nil
            state.outbox.append(command)
        }
        if let commitAdmission {
            try await store.update(admission: commitAdmission, mutation)
        } else {
            try await store.update(mutation)
        }

        return SecureMessagingQueueResult(
            conversation: candidate.conversation,
            clientMessageID: messageID
        )
    }

    nonisolated static func canRetryFailedTextMessage(
        in state: PersistedState,
        messageID: UUID,
        userID: String,
        conversationID: String,
        recipientUserID: String
    ) -> Bool {
        guard let candidate = try? failedTextRetryCandidate(
            in: state,
            messageID: messageID,
            userID: userID,
            conversationID: conversationID,
            recipientUserID: recipientUserID
        ) else { return false }
        return candidate.message.state == .failed && !candidate.alreadyQueued
    }

    /// Restores one commandless failed KITMEDIA2 message — pending batch or sealed descriptor
    /// — to the encrypted outbox without network access, exactly like
    /// `retryFailedTextMessage` but media-shaped. Commandless minting is direct-thread only;
    /// a group message retries solely through its retained command's pinned recipient list.
    /// The client message UUID stays the server idempotency key: flush re-gates capability
    /// and roster, resumes any outstanding uploads, and re-encrypts, so the retry can never
    /// split or duplicate the message.
    func retryFailedMediaMessage(
        messageID: UUID,
        forUserID userID: String,
        conversationID: String,
        expectedRecipientUserID: String?,
        commitAdmission: ProtectedCommunicationAdmissionLease? = nil
    ) async throws -> SecureMessagingQueueResult {
        let local = try canonicalUUID(userID, error: .invalidAccount)
        let conversationID = try canonicalUUID(
            conversationID,
            error: .invalidConversation
        )
        let recipient = try expectedRecipientUserID.map {
            try canonicalUUID($0, error: .invalidRecipient)
        }
        guard local != recipient else { throw SecureMessagingExchangeError.invalidRecipient }

        let snapshot = await store.snapshot()
        let candidate = try Self.failedMediaMessageRetryCandidate(
            in: snapshot,
            messageID: messageID,
            userID: local,
            conversationID: conversationID,
            expectedRecipientUserID: recipient
        )
        if candidate.alreadyQueued {
            return SecureMessagingQueueResult(
                conversation: candidate.conversation,
                clientMessageID: messageID
            )
        }

        var commandID = UUID()
        while commandID == messageID { commandID = UUID() }
        let command = OfflineCommand(
            id: commandID,
            kind: .secureMessage,
            createdAt: candidate.message.createdAt,
            nextAttemptAt: Date(),
            attemptCount: 0,
            conversationId: conversationID,
            messageId: messageID,
            recipientUserIds: candidate.recipientUserIDs,
            recipientName: candidate.conversation.title,
            video: nil,
            expiresAt: nil,
            secureMessageFanout: nil
        )
        let mutation: (inout PersistedState) throws -> Void = { state in
            let current = try Self.failedMediaMessageRetryCandidate(
                in: state,
                messageID: messageID,
                userID: local,
                conversationID: conversationID,
                expectedRecipientUserID: recipient
            )
            if current.alreadyQueued { return }
            // The command's recipient set was minted from the snapshot; a membership change
            // since then must fail closed rather than silently widen or narrow the audience.
            guard current.recipientUserIDs == candidate.recipientUserIDs,
                  let messageIndex = state.messages.firstIndex(where: {
                      $0.id == messageID
                  })
            else { throw SecureMessagingExchangeError.messageNotRetryable }
            state.messages[messageIndex].state = .queued
            state.messages[messageIndex].failureReason = nil
            // A user-initiated retry sends now: the promised minute already passed unmet, and
            // the fresh command deliberately carries no schedule, so the projection must not
            // keep claiming one.
            state.messages[messageIndex].scheduledAt = nil
            state.outbox.append(command)
        }
        if let commitAdmission {
            try await store.update(admission: commitAdmission, mutation)
        } else {
            try await store.update(mutation)
        }

        return SecureMessagingQueueResult(
            conversation: candidate.conversation,
            clientMessageID: messageID
        )
    }

    nonisolated static func canRetryFailedMediaMessage(
        in state: PersistedState,
        messageID: UUID,
        userID: String,
        conversationID: String,
        expectedRecipientUserID: String?
    ) -> Bool {
        guard let candidate = try? failedMediaMessageRetryCandidate(
            in: state,
            messageID: messageID,
            userID: userID,
            conversationID: conversationID,
            expectedRecipientUserID: expectedRecipientUserID
        ) else { return false }
        return candidate.message.state == .failed && !candidate.alreadyQueued
    }

    private static func existingDeferredTextResult(
        in state: PersistedState,
        clientMessageID: UUID,
        localUserID: String,
        recipientUserIDs: [String],
        conversation: Conversation,
        body: String,
        scheduledAt: Date?
    ) throws -> SecureMessagingQueueResult? {
        let messages = state.messages.filter { $0.id == clientMessageID }
        let commands = state.outbox.filter { $0.messageId == clientMessageID }
        guard messages.count <= 1, commands.count <= 1 else {
            throw SecureMessagingExchangeError.invalidConversation
        }
        guard let message = messages.first else {
            guard commands.isEmpty else {
                throw SecureMessagingExchangeError.invalidConversation
            }
            return nil
        }
        guard message.conversationId == conversation.id,
              message.senderId == localUserID,
              message.body == body,
              message.isOutgoing,
              message.scheduledAt == scheduledAt,
              message.attachmentData == nil,
              message.pendingAttachment == nil,
              // A pending v2 batch projects its caption (or placeholder) as `body`, so a
              // stable-ID text replay could otherwise "match" a message that is actually a
              // multi-attachment send in flight. Text idempotency may vouch only for text.
              message.pendingMediaBatch == nil
        else { throw SecureMessagingExchangeError.invalidConversation }

        if let command = commands.first {
            guard command.kind == .secureMessage,
                  command.conversationId == conversation.id,
                  command.recipientUserIds == recipientUserIDs,
                  command.scheduledAt == scheduledAt
            else { throw SecureMessagingExchangeError.invalidConversation }
        } else {
            guard [.sent, .delivered, .read, .failed].contains(message.state) else {
                throw SecureMessagingExchangeError.invalidConversation
            }
        }
        return SecureMessagingQueueResult(
            conversation: conversation,
            clientMessageID: clientMessageID
        )
    }

    /// Persists a small attachment and its caption inside SecureLocalStore's account-bound encrypted
    /// state. Reconnect uploads only ciphertext, checkpoints the canonical media descriptor, then
    /// advances the ordinary Signal outbox without exposing the plaintext to another store.
    func queueDeferredImage(
        forUserID userID: String,
        conversationID: String,
        expectedRecipientUserID: String?,
        title: String,
        mediaData: Data,
        mediaType: String,
        caption: String?,
        localStorageKey: String? = nil,
        clientMessageID: UUID? = nil,
        submittedDraftBody: String? = nil,
        draftClearVersion: ConversationDraftWriteVersion? = nil,
        deliverAt: Date? = nil,
        replyToServerMessageID: String? = nil
    ) async throws -> SecureMessagingQueueResult {
        guard (submittedDraftBody == nil) == (draftClearVersion == nil),
              replyToServerMessageID.map(SecureMessagingValidation.isCanonicalUUID) ?? true
        else {
            throw SecureMessagingCryptoError.invalidContent
        }
        let replyTarget = replyToServerMessageID?.lowercased()
        let local = try canonicalUUID(userID, error: .invalidAccount)
        let conversationID = try canonicalUUID(conversationID, error: .invalidConversation)
        let recipient = try expectedRecipientUserID.map {
            try canonicalUUID($0, error: .invalidRecipient)
        }
        let trimmedCaption = caption?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCaption = trimmedCaption?.isEmpty == false ? trimmedCaption : nil
        guard SecureMessagingWire.allowedAttachmentMediaTypes.contains(mediaType),
              !mediaData.isEmpty,
              mediaData.count <= SecureMediaAttachmentCipher.maximumPlaintextBytes,
              KitMediaMessageDescriptor.canEncodeCaption(normalizedCaption)
        else { throw SecureMediaAttachmentError.invalidMedia }
        // Large plaintext never rides inside the encrypted state file — the caller parks it in
        // the media file cache under a locally minted key before queueing.
        let storesInline = mediaData.count <= KitChatMediaLimits.maximumInlineCacheBytes
        let canonicalLocalStorageKey = localStorageKey
            .flatMap { UUID(uuidString: $0)?.uuidString.lowercased() }
        if !storesInline {
            guard canonicalLocalStorageKey != nil else {
                throw SecureMediaAttachmentError.invalidMedia
            }
        }
        let snapshot = await store.snapshot()
        guard snapshot.profile?.id == local,
              let enrollment = snapshot.secureMessaging?.enrollment,
              enrollment.userID == local,
              let conversation = snapshot.conversations.first(where: {
                  $0.id == conversationID
              }),
              Self.permitsDeferredQueue(
                  conversation: conversation,
                  localUserID: local,
                  expectedRecipientUserID: recipient
              )
        else { throw SecureMessagingExchangeError.invalidConversation }
        if let replyTarget {
            try Self.requireLocalReplyTarget(
                replyTarget,
                conversationID: conversationID,
                in: snapshot
            )
        }
        let commandRecipients = Self.deferredCommandRecipients(
            conversation: conversation,
            localUserID: local,
            expectedRecipientUserID: recipient
        )
        // Match the original minute before validating a fresh schedule: an exact retry can arrive
        // after that minute and must resolve to the existing idempotent message, not send another.
        let requestedMinute = deliverAt.map { ScheduledSendPolicy.canonicalMinute($0) }
        // No network at queue time: the offline path must succeed in airplane mode. The rich-media
        // recipient-capability gate still runs authoritatively at flush (prepareDeferredMessage)
        // and again per-encrypt in queueText before any bytes leave the device.
        _ = enrollment

        if let clientMessageID,
           let existing = try await existingDeferredMediaResult(
               in: snapshot,
               clientMessageID: clientMessageID,
               localUserID: local,
               recipientUserIDs: commandRecipients,
               conversation: conversation,
               mediaData: mediaData,
               mediaType: mediaType,
               caption: normalizedCaption,
               scheduledAt: requestedMinute
           ) {
            try await clearDraftAfterIdempotentQueueIfNeeded(
                clientMessageID: clientMessageID,
                conversationID: conversation.id,
                localUserID: local,
                submittedDraftBody: submittedDraftBody,
                draftClearVersion: draftClearVersion,
                commitAdmission: nil
            )
            return existing
        }

        let messageID = clientMessageID ?? UUID()
        let commandID = UUID()
        let createdAt = Date()
        // The photo is already parked in the account-bound encrypted cache; scheduling only moves
        // the upload-and-send attempt to a later minute. A fresh stale/invalid date fails closed;
        // it is never interpreted as permission to send immediately.
        let scheduledAt = try deliverAt.map { requested -> Date in
            guard let normalized = ScheduledSendPolicy.normalize(requested, now: createdAt)
            else { throw SecureMessagingCryptoError.invalidContent }
            return normalized
        }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let localMessage = LocalMessage(
            id: messageID,
            conversationId: conversationID,
            senderId: local,
            body: normalizedCaption ?? KitChatMediaKind(mediaType: mediaType).previewLabel,
            createdAt: createdAt,
            sentAt: nil,
            state: .queued,
            failureReason: nil,
            isOutgoing: true,
            attachmentData: storesInline ? mediaData : nil,
            pendingAttachment: LocalPendingAttachment(
                mediaType: mediaType,
                caption: normalizedCaption,
                localStorageKey: storesInline ? nil : canonicalLocalStorageKey,
                byteCount: mediaData.count
            ),
            replyToServerMessageID: replyTarget,
            scheduledAt: scheduledAt
        )
        let command = OfflineCommand(
            id: commandID,
            kind: .secureMessage,
            createdAt: createdAt,
            nextAttemptAt: scheduledAt ?? createdAt,
            attemptCount: 0,
            conversationId: conversationID,
            messageId: messageID,
            recipientUserIds: commandRecipients,
            recipientName: cleanTitle.isEmpty ? conversation.title : cleanTitle,
            video: nil,
            expiresAt: nil,
            secureMessageFanout: nil,
            scheduledAt: scheduledAt
        )
        var updatedConversation = conversation
        if scheduledAt == nil {
            updatedConversation.updatedAt = createdAt
        }
        let queuedConversation = updatedConversation
        try await store.update { state in
            guard state.profile?.id == local,
                  state.secureMessaging?.enrollment?.userID == local,
                  !state.messages.contains(where: { $0.id == messageID }),
                  !state.outbox.contains(where: { $0.id == commandID })
            else { throw StoreError.accountChanged }
            Self.upsert(conversation: queuedConversation, in: &state)
            state.messages.append(localMessage)
            state.outbox.append(command)
            if let submittedDraftBody, let draftClearVersion {
                _ = ConversationDraftPolicy.clearAfterSuccessfulQueue(
                    submittedBody: submittedDraftBody,
                    conversationID: conversationID,
                    ownerUserID: local,
                    writeVersion: draftClearVersion,
                    in: &state
                )
            }
        }
        return SecureMessagingQueueResult(
            conversation: queuedConversation,
            clientMessageID: messageID
        )
    }

    /// Stable IDs are used by retained share-sheet batches, but an ID alone is not proof that a
    /// previous queue operation is the same attachment. Validate the complete durable projection
    /// before treating a retry as success; collisions fail closed instead of silently discarding
    /// newly shared bytes.
    private func existingDeferredMediaResult(
        in state: PersistedState,
        clientMessageID: UUID,
        localUserID: String,
        recipientUserIDs: [String],
        conversation: Conversation,
        mediaData: Data,
        mediaType: String,
        caption: String?,
        scheduledAt: Date?
    ) async throws -> SecureMessagingQueueResult? {
        let messages = state.messages.filter { $0.id == clientMessageID }
        let commands = state.outbox.filter { $0.messageId == clientMessageID }
        guard messages.count <= 1, commands.count <= 1 else {
            throw SecureMessagingExchangeError.invalidConversation
        }
        guard let message = messages.first else {
            guard commands.isEmpty else {
                throw SecureMessagingExchangeError.invalidConversation
            }
            return nil
        }
        guard message.conversationId == conversation.id,
              message.senderId == localUserID,
              message.isOutgoing,
              message.scheduledAt == scheduledAt,
              message.pendingMediaBatch == nil
        else { throw SecureMessagingExchangeError.invalidConversation }

        if let pending = message.pendingAttachment {
            guard pending.mediaType == mediaType,
                  pending.caption == caption,
                  pending.byteCount == mediaData.count
            else { throw SecureMessagingExchangeError.invalidConversation }
            if let inline = message.attachmentData {
                guard pending.localStorageKey == nil, inline == mediaData else {
                    throw SecureMessagingExchangeError.invalidConversation
                }
            } else {
                guard let localStorageKey = pending.localStorageKey,
                      let parked = await mediaBlobs.read(localStorageKey, localUserID),
                      parked == mediaData
                else { throw SecureMessagingExchangeError.invalidConversation }
            }
        } else if let descriptor = KitMediaMessageDescriptor.parse(message.body) {
            guard descriptor.mediaType == mediaType,
                  descriptor.caption == caption,
                  descriptor.plaintextByteSize == mediaData.count
            else { throw SecureMessagingExchangeError.invalidConversation }
            if let inline = message.attachmentData {
                guard inline == mediaData else {
                    throw SecureMessagingExchangeError.invalidConversation
                }
            } else if let retained = await mediaBlobs.read(
                descriptor.storageKey,
                localUserID
            ) {
                guard retained == mediaData else {
                    throw SecureMessagingExchangeError.invalidConversation
                }
            }
        } else {
            throw SecureMessagingExchangeError.invalidConversation
        }

        if let command = commands.first {
            guard command.kind == .secureMessage,
                  command.conversationId == conversation.id,
                  command.messageId == clientMessageID,
                  command.recipientUserIds == recipientUserIDs,
                  command.scheduledAt == scheduledAt
            else { throw SecureMessagingExchangeError.invalidConversation }
        } else {
            guard [.sent, .delivered, .read, .failed].contains(message.state) else {
                throw SecureMessagingExchangeError.invalidConversation
            }
        }
        return SecureMessagingQueueResult(
            conversation: conversation,
            clientMessageID: clientMessageID
        )
    }

    /// A process can die after the stable message commit but before its caller observes success.
    /// Replaying that exact queue must still perform the versioned draft clear requested by the
    /// send operation; otherwise a media caption can reappear after relaunch even though its
    /// bubble is already durable.
    private func clearDraftAfterIdempotentQueueIfNeeded(
        clientMessageID: UUID,
        conversationID: String,
        localUserID: String,
        submittedDraftBody: String?,
        draftClearVersion: ConversationDraftWriteVersion?,
        commitAdmission: ProtectedCommunicationAdmissionLease?
    ) async throws {
        guard let submittedDraftBody, let draftClearVersion else { return }
        let mutation: (inout PersistedState) throws -> Void = { state in
            guard state.profile?.id == localUserID,
                  state.secureMessaging?.enrollment?.userID == localUserID,
                  state.messages.contains(where: {
                      $0.id == clientMessageID
                          && $0.conversationId == conversationID
                          && $0.senderId == localUserID
                          && $0.isOutgoing
                  })
            else { throw StoreError.accountChanged }
            _ = ConversationDraftPolicy.clearAfterSuccessfulQueue(
                submittedBody: submittedDraftBody,
                conversationID: conversationID,
                ownerUserID: localUserID,
                writeVersion: draftClearVersion,
                in: &state
            )
        }
        if let commitAdmission {
            try await store.update(admission: commitAdmission, mutation)
        } else {
            try await store.update(mutation)
        }
    }

    /// Pre-seal bubble body for a queued multi-attachment message with no caption. Content-free
    /// by design: once sealed the canonical descriptor replaces it, and rendering derives labels
    /// from the durable batch or descriptor, never from this placeholder.
    static func mediaBatchPlaceholderBody(itemCount: Int) -> String {
        "\(max(1, itemCount)) attachments"
    }

    /// Queues one multi-attachment (KITMEDIA2) message as a single durable projection. Every
    /// plaintext is already parked in the account-bound encrypted media cache under the batch's
    /// locally minted keys; reconnect uploads only ciphertext, checkpoints each item durably,
    /// seals the canonical v2 descriptor, then advances the ordinary Signal outbox. The batch is
    /// never split into per-attachment messages, at queue time or any later stage.
    func queueDeferredMediaBatch(
        forUserID userID: String,
        conversationID: String,
        expectedRecipientUserID: String?,
        title: String,
        batch: KitMediaMessageV2OutboundBatch,
        clientMessageID: UUID? = nil,
        submittedDraftBody: String? = nil,
        draftClearVersion: ConversationDraftWriteVersion? = nil,
        deliverAt: Date? = nil,
        replyToServerMessageID: String? = nil
    ) async throws -> SecureMessagingQueueResult {
        guard (submittedDraftBody == nil) == (draftClearVersion == nil),
              replyToServerMessageID.map(SecureMessagingValidation.isCanonicalUUID) ?? true
        else {
            throw SecureMessagingCryptoError.invalidContent
        }
        let replyTarget = replyToServerMessageID?.lowercased()
        let local = try canonicalUUID(userID, error: .invalidAccount)
        let conversationID = try canonicalUUID(conversationID, error: .invalidConversation)
        let recipient = try expectedRecipientUserID.map {
            try canonicalUUID($0, error: .invalidRecipient)
        }
        // The batch arrives fully minted (fresh ids, key material, parked plaintext keys) and
        // not yet uploaded anywhere; a torn or replayed value must never become durable state.
        guard batch.isStructurallyValid,
              batch.items.allSatisfy({ !$0.isUploaded })
        else { throw SecureMediaAttachmentError.invalidMedia }
        let snapshot = await store.snapshot()
        guard snapshot.profile?.id == local,
              let enrollment = snapshot.secureMessaging?.enrollment,
              enrollment.userID == local,
              let conversation = snapshot.conversations.first(where: {
                  $0.id == conversationID
              }),
              Self.permitsDeferredQueue(
                  conversation: conversation,
                  localUserID: local,
                  expectedRecipientUserID: recipient
              )
        else { throw SecureMessagingExchangeError.invalidConversation }
        if let replyTarget {
            try Self.requireLocalReplyTarget(
                replyTarget,
                conversationID: conversationID,
                in: snapshot
            )
        }
        let commandRecipients = Self.deferredCommandRecipients(
            conversation: conversation,
            localUserID: local,
            expectedRecipientUserID: recipient
        )
        // No network at queue time: the offline path must succeed in airplane mode. The v2
        // capability admission gate runs authoritatively at flush (prepareDeferredMessage) and
        // again per-encrypt in queueText before any bytes leave the device.
        _ = enrollment

        // Every parked plaintext must exist with its declared byte count before any durable
        // commit: a torn share hand-off surfaces here, while the draft is still recoverable,
        // instead of as a visible retire at flush time.
        for item in batch.items {
            guard let parked = await mediaBlobs.read(item.localStorageKey, local),
                  parked.count == item.plaintextByteSize
            else { throw SecureMediaAttachmentError.invalidMedia }
        }

        let createdAt = Date()
        // Idempotent recognition compares the canonical requested minute, deliberately without
        // reapplying clock eligibility: the stored instant was admissible when first queued and
        // may since have passed while the retry is still the same send.
        let requestedMinute = deliverAt.map { ScheduledSendPolicy.canonicalMinute($0) }
        let offeredParkKeys = Set(batch.items.map(\.localStorageKey))

        if let clientMessageID,
           let match = try await existingDeferredMediaBatchResult(
               in: snapshot,
               clientMessageID: clientMessageID,
               localUserID: local,
               recipientUserIDs: commandRecipients,
               conversation: conversation,
               offered: batch,
               replyTarget: replyTarget,
               offeredScheduledAt: requestedMinute
           ) {
            // The byte reads above suspend the actor, so state may have moved. Success is
            // claimed only against the exact captured projection — whole message and command
            // values — with offered park keys disjoint from every other message's media keys,
            // and the requested draft clear rides inside the same mutation.
            try await store.update { state in
                guard state.profile?.id == local,
                      state.secureMessaging?.enrollment?.userID == local,
                      state.messages.filter({ $0.id == clientMessageID })
                          == [match.message],
                      state.outbox.filter({ $0.messageId == clientMessageID })
                          == (match.command.map { [$0] } ?? []),
                      state.messages.allSatisfy({
                          $0.id == clientMessageID
                              || Set($0.localMediaStorageKeys)
                                  .isDisjoint(with: offeredParkKeys)
                      })
                else { throw StoreError.accountChanged }
                if let submittedDraftBody, let draftClearVersion {
                    _ = ConversationDraftPolicy.clearAfterSuccessfulQueue(
                        submittedBody: submittedDraftBody,
                        conversationID: conversationID,
                        ownerUserID: local,
                        writeVersion: draftClearVersion,
                        in: &state
                    )
                }
            }
            // The durable projection owns its bytes. Remove only scratch offered park keys:
            // anything referenced by ANY live message stays, or this cleanup could delete
            // another message's blob through a key alias. The snapshot below suspends again
            // after the exact CAS, so the captured target's keys are protected unconditionally
            // and the wider union is trusted only while the state still belongs to this
            // account — on a switch the scratch parks are left behind, because an orphaned
            // scratch blob is recoverable and a deleted parked plaintext is not.
            let latest = await store.snapshot()
            guard latest.profile?.id == local,
                  latest.secureMessaging?.enrollment?.userID == local
            else { return match.result }
            let liveKeys = Set(match.message.localMediaStorageKeys)
                .union(latest.messages.flatMap(\.localMediaStorageKeys))
            for item in batch.items where !liveKeys.contains(item.localStorageKey) {
                await mediaBlobs.remove(item.localStorageKey, local)
            }
            return match.result
        }

        // A fresh queue of a schedule that cannot normalize fails closed: silently sending
        // now is never what "later" meant. Scheduling otherwise only moves the upload-and-send
        // attempt to a later minute — the plaintext is already parked in the encrypted cache.
        let scheduledAt = try deliverAt.map { requested -> Date in
            guard let normalized = ScheduledSendPolicy.normalize(requested, now: createdAt)
            else { throw SecureMessagingCryptoError.invalidContent }
            return normalized
        }
        let messageID = clientMessageID ?? UUID()
        let commandID = UUID()
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let localMessage = LocalMessage(
            id: messageID,
            conversationId: conversationID,
            senderId: local,
            body: batch.caption
                ?? Self.mediaBatchPlaceholderBody(itemCount: batch.items.count),
            createdAt: createdAt,
            sentAt: nil,
            state: .queued,
            failureReason: nil,
            isOutgoing: true,
            attachmentData: nil,
            pendingAttachment: nil,
            pendingMediaBatch: batch,
            replyToServerMessageID: replyTarget,
            scheduledAt: scheduledAt
        )
        let command = OfflineCommand(
            id: commandID,
            kind: .secureMessage,
            createdAt: createdAt,
            nextAttemptAt: scheduledAt ?? createdAt,
            attemptCount: 0,
            conversationId: conversationID,
            messageId: messageID,
            recipientUserIds: commandRecipients,
            recipientName: cleanTitle.isEmpty ? conversation.title : cleanTitle,
            video: nil,
            expiresAt: nil,
            secureMessageFanout: nil,
            scheduledAt: scheduledAt
        )
        // The blob reads above suspended the actor N times, so the opening snapshot is stale
        // by commit time. The mutation re-proves everything it makes durable against live
        // state — account owner, current conversation membership and recipients, the reply
        // target, and park keys unclaimed by any other message — and never upserts the
        // snapshot's conversation back over a newer one.
        try await store.update { state in
            guard state.profile?.id == local,
                  state.secureMessaging?.enrollment?.userID == local,
                  !state.messages.contains(where: { $0.id == messageID }),
                  !state.outbox.contains(where: { $0.id == commandID }),
                  // One message, one command: a torn or orphaned command already claiming this
                  // stable client message id must block the append, not silently coexist.
                  !state.outbox.contains(where: { $0.messageId == messageID }),
                  state.messages.allSatisfy({
                      Set($0.localMediaStorageKeys).isDisjoint(with: offeredParkKeys)
                  }),
                  let liveConversation = state.conversations.first(where: {
                      $0.id == conversationID
                  }),
                  Self.permitsDeferredQueue(
                      conversation: liveConversation,
                      localUserID: local,
                      expectedRecipientUserID: recipient
                  ),
                  Self.deferredCommandRecipients(
                      conversation: liveConversation,
                      localUserID: local,
                      expectedRecipientUserID: recipient
                  ) == commandRecipients
            else { throw StoreError.accountChanged }
            if let replyTarget {
                try Self.requireLocalReplyTarget(
                    replyTarget,
                    conversationID: conversationID,
                    in: state
                )
            }
            var live = liveConversation
            if scheduledAt == nil {
                live.updatedAt = max(live.updatedAt, createdAt)
            }
            Self.upsert(conversation: live, in: &state)
            state.messages.append(localMessage)
            state.outbox.append(command)
            if let submittedDraftBody, let draftClearVersion {
                _ = ConversationDraftPolicy.clearAfterSuccessfulQueue(
                    submittedBody: submittedDraftBody,
                    conversationID: conversationID,
                    ownerUserID: local,
                    writeVersion: draftClearVersion,
                    in: &state
                )
            }
        }
        let latest = await store.snapshot()
        let committedConversation: Conversation
        if latest.profile?.id == local,
           let live = latest.conversations.first(where: { $0.id == conversationID }) {
            committedConversation = live
        } else {
            committedConversation = conversation
        }
        return SecureMessagingQueueResult(
            conversation: committedConversation,
            clientMessageID: messageID
        )
    }

    /// Synchronous projection identity for idempotent batch retries: durable caption, item
    /// metadata, reply pointer, and schedule intent must all match the offered send. Reused as
    /// the final compare-and-set inside the draft-clear mutation because async cache reads make
    /// the actor reentrant — the projection can change between validation and commit.
    private static func batchProjectionMatchesOffered(
        _ message: LocalMessage,
        offered: KitMediaMessageV2OutboundBatch,
        replyTarget: String?,
        offeredScheduledAt: Date?
    ) -> Bool {
        // Idempotent identity is exact: the reply pointer and the canonical requested minute
        // (quantized by the caller, deliberately without clock eligibility) must equal the
        // durable projection precisely — a send-now retry of a scheduled message, or any
        // different scheduled minute, is a different send. A batch message also owns exactly
        // one media projection: coexisting v1 pending or inline payload is never the same send.
        guard message.replyToServerMessageID == replyTarget,
              message.scheduledAt == offeredScheduledAt,
              message.pendingAttachment == nil,
              message.attachmentData == nil
        else { return false }
        if let existing = message.pendingMediaBatch {
            // The pre-seal body is bound byte-for-byte to the batch: a valid batch riding a
            // foreign body could leak that body into display or search before sealing.
            return message.body == (
                existing.caption
                    ?? mediaBatchPlaceholderBody(itemCount: existing.items.count)
            )
                && existing.isStructurallyValid
                && existing.caption == offered.caption
                && existing.items.count == offered.items.count
                && zip(existing.items, offered.items).allSatisfy {
                    $0.mediaType == $1.mediaType
                        && $0.plaintextByteSize == $1.plaintextByteSize
                }
        }
        if let sealed = KitMediaMessageV2Descriptor.parse(message.body) {
            return sealed.caption == offered.caption
                && sealed.items.count == offered.items.count
                && zip(sealed.items, offered.items).allSatisfy {
                    $0.mediaType == $1.mediaType
                        && $0.plaintextByteSize == $1.plaintextByteSize
                }
        }
        return false
    }

    /// Stable IDs are used by retained share-sheet batches, but an ID alone is not proof that a
    /// previous queue operation is the same batch. Validate the complete durable projection —
    /// caption, item count, per-item media type and byte size, reply pointer, schedule intent,
    /// and the exact bytes — before treating a retry as success; collisions fail closed instead
    /// of silently discarding newly shared bytes.
    private func existingDeferredMediaBatchResult(
        in state: PersistedState,
        clientMessageID: UUID,
        localUserID: String,
        recipientUserIDs: [String],
        conversation: Conversation,
        offered: KitMediaMessageV2OutboundBatch,
        replyTarget: String?,
        offeredScheduledAt: Date?
    ) async throws -> (
        result: SecureMessagingQueueResult,
        message: LocalMessage,
        command: OfflineCommand?
    )? {
        let messages = state.messages.filter { $0.id == clientMessageID }
        let commands = state.outbox.filter { $0.messageId == clientMessageID }
        guard messages.count <= 1, commands.count <= 1 else {
            throw SecureMessagingExchangeError.invalidConversation
        }
        guard let message = messages.first else {
            guard commands.isEmpty else {
                throw SecureMessagingExchangeError.invalidConversation
            }
            return nil
        }
        guard message.conversationId == conversation.id,
              message.senderId == localUserID,
              message.isOutgoing,
              Self.batchProjectionMatchesOffered(
                  message,
                  offered: offered,
                  replyTarget: replyTarget,
                  offeredScheduledAt: offeredScheduledAt
              )
        else { throw SecureMessagingExchangeError.invalidConversation }

        if let existing = message.pendingMediaBatch {
            for (existingItem, offeredItem) in zip(existing.items, offered.items) {
                // A checkpointed item's park key may already be removed; its bytes live under
                // the uploaded cache copy. Both sides must be readable and byte-identical.
                let existingKey = existingItem.storageKey ?? existingItem.localStorageKey
                guard let retained = await mediaBlobs.read(existingKey, localUserID),
                      retained.count == existingItem.plaintextByteSize,
                      let offeredBytes = await mediaBlobs.read(
                          offeredItem.localStorageKey,
                          localUserID
                      ),
                      retained == offeredBytes
                else { throw SecureMessagingExchangeError.invalidConversation }
            }
        } else if let sealed = KitMediaMessageV2Descriptor.parse(message.body) {
            for (sealedItem, offeredItem) in zip(sealed.items, offered.items) {
                // Matching metadata is not proof of matching content: a different same-sized
                // retry must never be silently discarded, so the retained copy has to exist
                // and equal the offered bytes exactly, or the retry fails closed.
                guard let offeredBytes = await mediaBlobs.read(
                          offeredItem.localStorageKey,
                          localUserID
                      ),
                      offeredBytes.count == offeredItem.plaintextByteSize,
                      let retained = await mediaBlobs.read(sealedItem.storageKey, localUserID),
                      retained == offeredBytes
                else { throw SecureMessagingExchangeError.invalidConversation }
            }
        } else {
            throw SecureMessagingExchangeError.invalidConversation
        }

        if let command = commands.first {
            guard command.kind == .secureMessage,
                  command.conversationId == conversation.id,
                  command.messageId == clientMessageID,
                  command.recipientUserIds == recipientUserIDs,
                  command.scheduledAt == message.scheduledAt
            else { throw SecureMessagingExchangeError.invalidConversation }
        } else {
            guard [.sent, .delivered, .read, .failed].contains(message.state) else {
                throw SecureMessagingExchangeError.invalidConversation
            }
        }
        // The captured exact values let the caller re-prove this projection at commit time:
        // async byte reads above make the actor reentrant, so success may only be claimed
        // against precisely what was validated here.
        return (
            result: SecureMessagingQueueResult(
                conversation: conversation,
                clientMessageID: clientMessageID
            ),
            message: message,
            command: commands.first
        )
    }

    /// Resolves a queued command whose pinned group audience no longer matches live membership:
    /// the command retires and the message fails visibly, atomically against the exact
    /// projection (a replaced projection aborts as a cancellation and mutates nothing). The
    /// audience is never silently widened or narrowed — a direct thread's failed message can
    /// re-mint commandlessly because its one-peer audience is structural, while a group message
    /// ends here as a deliberate user re-compose against the roster that now exists. The
    /// pending v1/v2 media projection survives on the failed message untouched: retirement is
    /// about audience, and destroying parked plaintext is never its business.
    private func retireStaleAudienceCommand(
        _ command: OfflineCommand,
        message: LocalMessage,
        forUserID userID: String
    ) async throws {
        try await store.update { state in
            guard state.profile?.id == userID,
                  let indices = Self.exactPendingProjectionIndices(
                      in: state,
                      command: command,
                      message: message
                  )
            else { throw CancellationError() }
            state.outbox.remove(at: indices.command)
            state.messages[indices.message].state = .failed
            state.messages[indices.message].failureReason =
                SecureMessagingExchangeError.staleOutboundFanout.localizedDescription
        }
    }

    func prepareDeferredMessage(
        commandID: UUID,
        forUserID userID: String
    ) async throws -> SecureMessagingQueueResult {
        let local = try canonicalUUID(userID, error: .invalidAccount)
        let snapshot = await store.snapshot()
        guard snapshot.profile?.id == local,
              let command = snapshot.outbox.first(where: {
                  $0.id == commandID
                      && $0.kind == .secureMessage
                      && $0.secureMessageFanout == nil
              }),
              let messageID = command.messageId,
              let message = snapshot.messages.first(where: { $0.id == messageID }),
              let conversationID = command.conversationId,
              let recipients = command.recipientUserIds,
              (1 ... SecureMessagingWire.maximumGroupMembers - 1).contains(recipients.count),
              message.conversationId == conversationID,
              message.senderId == local,
              // Only a genuinely unsent outbound projection may reach network or upload work:
              // anything already sent, received, failed, or carrying accepted-history
              // metadata fails closed before the first side effect.
              message.isOutgoing,
              message.state == .queued,
              message.serverMessageId == nil,
              message.sentAt == nil,
              message.failureReason == nil,
              message.secureMessagingHistory == nil
        else { throw SecureMessagingExchangeError.invalidConversation }
        // A stored group thread flushes with no pinned single recipient; every other command
        // keeps the exact direct two-party pin (fail closed on nil).
        let queuedAsGroup = snapshot.conversations.first(where: {
            $0.id == conversationID
        })?.isGroup == true
        let expectedRecipient: String?
        if queuedAsGroup {
            expectedRecipient = nil
        } else {
            guard recipients.count == 1, let recipient = recipients.first else {
                throw SecureMessagingExchangeError.invalidConversation
            }
            expectedRecipient = recipient
        }
        var ownedMessage = message
        do {
            let dto = try await transport.messagingConversation(id: conversationID)
            let conversation = try validateConversation(
                dto,
                currentUserID: local,
                expectedRecipientUserID: expectedRecipient,
                fallbackTitle: command.recipientName ?? "Kit Pay contact"
            )
            guard conversation.isGroup == queuedAsGroup else {
                throw SecureMessagingExchangeError.invalidConversation
            }
            // Never widen an offline message's audience. If group membership changed after the
            // message was queued, the pinned audience is unservable and no fresh one may be
            // minted for the same client message id — so resolve it here, atomically against
            // the exact projection: retire the command and fail the message visibly. Leaving
            // the ready command intact would spin the flush loop forever, because this check
            // throws before any fanout exists for the post-encryption stale handling to clear.
            guard command.recipientUserIds == conversation.outboundRecipientUserIDs(
                excluding: local
            ) else {
                try await retireStaleAudienceCommand(command, message: message, forUserID: local)
                throw SecureMessagingExchangeError.staleOutboundFanout
            }
            try await requireExactPendingProjection(
                command,
                message: message,
                forUserID: local
            )
            var preparedMessage = message
            // A message owns exactly one media projection. A v2 batch or sealed v2 body with
            // leftover v1 pending fields is corrupt: fail visibly here instead of letting the
            // single-attachment branch silently win and overwrite the v2 projection.
            if message.pendingMediaBatch != nil
                || KitMediaMessageV2Descriptor.parse(message.body) != nil {
                guard message.pendingAttachment == nil, message.attachmentData == nil else {
                    throw SecureMediaAttachmentError.invalidMedia
                }
            }
            var mediaMessageV2Items: [MessagingMediaMessageV2CapabilityPolicy.DraftItem]? = nil
            if let pending = message.pendingAttachment {
                // Plaintext lives inline for small attachments; large deferred media was parked
                // in the encrypted media file cache under a locally minted key at queue time.
                let mediaData: Data
                if let inline = message.attachmentData, !inline.isEmpty {
                    mediaData = inline
                } else if let localKey = pending.localStorageKey,
                          let parked = await mediaBlobs.read(localKey, local),
                          !parked.isEmpty {
                    mediaData = parked
                } else {
                    throw SecureMediaAttachmentError.invalidMedia
                }
                guard mediaData.count <= SecureMediaAttachmentCipher.maximumPlaintextBytes
                else { throw SecureMediaAttachmentError.invalidMedia }
                if KitChatMediaKind(mediaType: pending.mediaType) != .image
                    || mediaData.count
                        > MessagingRichMediaCapabilityPolicy
                            .broadlyCompatibleMaximumPlaintextBytes {
                    guard let enrollment = snapshot.secureMessaging?.enrollment else {
                        throw SecureMessagingExchangeError.invalidAccount
                    }
                    let roster = try await transport.messagingDeviceRoster(
                        conversationId: conversationID
                    )
                    if KitChatMediaKind(mediaType: pending.mediaType) != .image {
                        try Self.requireRichMediaRecipientSupport(
                            mediaType: pending.mediaType,
                            roster: roster,
                            conversationID: conversationID,
                            currentDeviceID: enrollment.serverDeviceID,
                            recipientUserIDs: conversation.outboundRecipientUserIDs(
                                excluding: local
                            )
                        )
                    }
                    try Self.requireLargeMediaRecipientSupport(
                        plaintextByteSize: mediaData.count,
                        roster: roster,
                        conversationID: conversationID,
                        currentDeviceID: enrollment.serverDeviceID,
                        memberUserIDs: conversation.memberUserIDs
                    )
                }
                _ = try await activation.activate(forUserID: local)
                let descriptor = try await uploadMediaDescriptor(
                    mediaData: mediaData,
                    mediaType: pending.mediaType,
                    caption: pending.caption
                )
                if let localKey = pending.localStorageKey {
                    // Duplicate-then-checkpoint-then-remove: the cache actor's non-overwriting
                    // duplicate is the only write primitive here. A fresh server-issued key
                    // must land on an ABSENT destination — even byte-identical content means
                    // the key is not exclusively ours (two sends of the same bytes can collide
                    // on a key, and accepting the alias would let this message's unwind delete
                    // the other's checkpointed blob). Only `.stored` proves exclusive
                    // ownership, which is what licenses the unwind below.
                    switch await mediaBlobs.duplicateIfAbsent(
                        localKey,
                        descriptor.storageKey,
                        local
                    ) {
                    case .stored:
                        break
                    case .alreadyIdentical, .conflict, .sourceMissing:
                        throw SecureMediaAttachmentError.invalidMedia
                    }
                }
                do {
                    preparedMessage = try await checkpointDeferredImageDescriptor(
                        descriptor,
                        command: command,
                        message: message,
                        forUserID: local
                    )
                } catch {
                    if let localKey = pending.localStorageKey {
                        _ = await mediaBlobs.removeDuplicate(
                            descriptor.storageKey,
                            localKey,
                            local
                        )
                    }
                    throw error
                }
                if let localKey = pending.localStorageKey {
                    _ = await mediaBlobs.removeDuplicate(
                        localKey,
                        descriptor.storageKey,
                        local
                    )
                }
                ownedMessage = preparedMessage
            } else if message.pendingMediaBatch != nil {
                guard var batch = message.pendingMediaBatch,
                      batch.isStructurallyValid,
                      message.body == (
                          batch.caption
                              ?? Self.mediaBatchPlaceholderBody(itemCount: batch.items.count)
                      )
                else { throw SecureMediaAttachmentError.invalidMedia }
                // Activation precedes the admission gate so a rotated device enrollment is
                // attested first and the gate judges the device that actually uploads.
                let activated = try await activation.activate(forUserID: local)
                guard let enrollment = activated.enrollment, enrollment.userID == local
                else { throw SecureMessagingExchangeError.invalidAccount }
                // §7: a capability withdrawn after queue fails the whole message closed before
                // any upload; a multi-attachment message is never split into fragments.
                let capabilities = try await transport.capabilities()
                let roster = try await transport.messagingDeviceRoster(
                    conversationId: conversationID
                )
                let draftItems = batch.items.map {
                    MessagingMediaMessageV2CapabilityPolicy.DraftItem(
                        mediaType: $0.mediaType,
                        plaintextByteSize: $0.plaintextByteSize
                    )
                }
                guard MessagingMediaMessageV2CapabilityPolicy.admitsComposition(
                    capabilities: capabilities,
                    roster: roster,
                    conversationID: conversationID,
                    currentDeviceID: enrollment.serverDeviceID,
                    currentUserID: local,
                    memberUserIDs: conversation.memberUserIDs,
                    items: draftItems
                ) else {
                    throw SecureMessagingExchangeError.mediaMessageCapabilityUnavailable
                }
                var currentMessage = message
                // §5/§7: ciphertext leaves the device in ascending fresh-random attachment-id
                // order — never display order — and each uploaded item becomes durable in its
                // own checkpoint so a crash resumes exactly where the last checkpoint stopped.
                for index in batch.pendingUploadIndicesInUploadOrder {
                    let item = batch.items[index]
                    guard let keyMaterial = Data(base64Encoded: item.keyMaterialBase64),
                          keyMaterial.count == SecureMediaAttachmentCipher.keyMaterialBytes,
                          let plaintext = await mediaBlobs.read(item.localStorageKey, local),
                          plaintext.count == item.plaintextByteSize
                    else { throw SecureMediaAttachmentError.invalidMedia }
                    let encrypted = try await Task.detached(priority: .userInitiated) {
                        try SecureMediaAttachmentCipher.encrypt(
                            plaintext,
                            keyMaterial: keyMaterial
                        )
                    }.value
                    let upload = try await transport.uploadMessagingAttachment(
                        mediaType: item.mediaType,
                        ciphertext: encrypted.ciphertext
                    )
                    guard let storageKey = upload.storageKey?.lowercased(),
                          let byteSize = upload.byteSize,
                          let digest = upload.ciphertextSha256?.lowercased(),
                          SecureMessagingWirePolicy.isCanonicalUUID(storageKey),
                          byteSize == Int64(encrypted.ciphertext.count),
                          digest == encrypted.sha256Hex,
                          let uploadedItem = item.uploaded(
                              storageKey: storageKey,
                              ciphertextByteSize: byteSize,
                              ciphertextSHA256: digest
                          )
                    else { throw SecureMediaAttachmentError.serverMetadataMismatch }
                    // Stage the checkpoint candidate and prove global key distinctness BEFORE
                    // copying: a colliding server-issued storage key must never overwrite
                    // another item's parked plaintext or retained copy.
                    var stagedBatch = batch
                    stagedBatch.items[index] = uploadedItem
                    guard stagedBatch.isStructurallyValid else {
                        throw SecureMediaAttachmentError.serverMetadataMismatch
                    }
                    // A server-issued key that aliases ANY other live message's blob must
                    // still fail here — the non-overwriting duplicate protects the bytes, but
                    // only this state-level proof keeps a foreign message's key out of our
                    // durable projection; the checkpoint mutation below re-proves the same
                    // distinctness after this read suspends the actor.
                    let liveState = await store.snapshot()
                    guard liveState.profile?.id == local,
                          liveState.messages.allSatisfy({
                              $0.id == messageID
                                  || !$0.localMediaStorageKeys.contains(storageKey)
                          })
                    else { throw SecureMediaAttachmentError.serverMetadataMismatch }
                    // Duplicate-then-checkpoint-then-remove, exactly like single-attachment
                    // media. A fresh, not-yet-checkpointed key must land on an ABSENT
                    // destination: two messages can carry byte-identical plaintext, so
                    // `.alreadyIdentical` here could be the OTHER message's checkpointed blob
                    // — accepting it would let this message's failed-checkpoint unwind delete
                    // that live blob. Only `.stored` proves exclusive ownership, which is what
                    // licenses the unwind; the park delete afterwards is licensed separately
                    // by byte-identical survival under the checkpointed key.
                    switch await mediaBlobs.duplicateIfAbsent(
                        item.localStorageKey,
                        storageKey,
                        local
                    ) {
                    case .stored:
                        break
                    case .alreadyIdentical, .conflict, .sourceMissing:
                        throw SecureMediaAttachmentError.serverMetadataMismatch
                    }
                    var checkpointed = currentMessage
                    checkpointed.pendingMediaBatch = stagedBatch
                    do {
                        currentMessage = try await replaceDeferredMessageProjection(
                            checkpointed,
                            command: command,
                            message: currentMessage,
                            forUserID: local,
                            requiringDistinctCacheKeys: [storageKey]
                        )
                    } catch {
                        _ = await mediaBlobs.removeDuplicate(
                            storageKey,
                            item.localStorageKey,
                            local
                        )
                        throw error
                    }
                    batch = stagedBatch
                    ownedMessage = currentMessage
                    _ = await mediaBlobs.removeDuplicate(
                        item.localStorageKey,
                        storageKey,
                        local
                    )
                }
                // The awaits since the last checkpoint suspended the actor; re-prove the exact
                // projection and account-wide key ownership once more immediately before the
                // destructive reconcile pass below and the seal after it.
                currentMessage = try await replaceDeferredMessageProjection(
                    currentMessage,
                    command: command,
                    message: currentMessage,
                    forUserID: local,
                    requiringDistinctCacheKeys: batch.items.compactMap(\.storageKey)
                )
                // Crash-resume reconciliation: an item checkpointed by an earlier pass may
                // have died before its park blob was removed. Sealing clears the batch, so
                // stale park keys must go now or they orphan in the encrypted cache forever.
                // Every write here is the cache actor's non-overwriting duplicate and every
                // delete is its byte-identical-survivor license, so nothing in this pass can
                // destroy information whatever raced in between; byte-different content under
                // a checkpointed key fails the whole prepare closed instead of being
                // overwritten. When the park is already gone there is nothing to license: the
                // retained copy was written by this pipeline from queue-verified bytes, the
                // frozen descriptor carries no plaintext digest to re-prove it against, and
                // no destructive action rides on trusting it.
                for item in batch.items where item.isUploaded {
                    guard let storageKey = item.storageKey,
                          storageKey != item.localStorageKey,
                          let parked = await mediaBlobs.read(item.localStorageKey, local),
                          parked.count == item.plaintextByteSize
                    else { continue }
                    switch await mediaBlobs.duplicateIfAbsent(
                        item.localStorageKey,
                        storageKey,
                        local
                    ) {
                    case .stored:
                        // The repair may stand only while the projection is still exactly
                        // ours and the key still unaliased — undone on any doubt, and the
                        // undo itself removes only a blob still byte-identical to the park.
                        do {
                            currentMessage = try await replaceDeferredMessageProjection(
                                currentMessage,
                                command: command,
                                message: currentMessage,
                                forUserID: local,
                                requiringDistinctCacheKeys: [storageKey]
                            )
                        } catch {
                            _ = await mediaBlobs.removeDuplicate(
                                storageKey,
                                item.localStorageKey,
                                local
                            )
                            throw error
                        }
                    case .alreadyIdentical:
                        // Safe ONLY in this reconcile pass: the durable projection already
                        // owns this checkpointed key — proven exclusively ours against every
                        // other live message by the projection CAS immediately above this
                        // loop — so identical bytes here are our own earlier copy, and this
                        // branch deletes nothing under the key itself.
                        break
                    case .conflict, .sourceMissing:
                        throw SecureMediaAttachmentError.serverMetadataMismatch
                    }
                    _ = await mediaBlobs.removeDuplicate(
                        item.localStorageKey,
                        storageKey,
                        local
                    )
                }
                // SEALED (§7): the canonical descriptor becomes the durable body before any
                // Signal encryption; from here retries re-derive everything from the body.
                guard let sealed = batch.sealedDescriptor() else {
                    throw SecureMediaAttachmentError.invalidMedia
                }
                var sealedMessage = currentMessage
                sealedMessage.body = sealed.encoded
                sealedMessage.pendingMediaBatch = nil
                preparedMessage = try await replaceDeferredMessageProjection(
                    sealedMessage,
                    command: command,
                    message: currentMessage,
                    forUserID: local,
                    requiringDistinctCacheKeys: batch.items.compactMap(\.storageKey)
                )
                ownedMessage = preparedMessage
                mediaMessageV2Items = draftItems
            } else if let sealed = KitMediaMessageV2Descriptor.parse(message.body) {
                // A sealed v2 message resuming after a crash or a blob-expiry reopen that
                // already re-sealed: the descriptor body alone is sufficient to replay the
                // send. Admission re-runs inside queueText against a capabilities document
                // and roster both fetched fresh on every attempt of its retry loop, so no
                // stale snapshot needs to travel from here.
                mediaMessageV2Items = sealed.items.map {
                    MessagingMediaMessageV2CapabilityPolicy.DraftItem(
                        mediaType: $0.mediaType,
                        plaintextByteSize: $0.plaintextByteSize
                    )
                }
            } else if let descriptor = KitMediaMessageDescriptor.parse(message.body) {
                guard SecureMessagingWire.allowedAttachmentMediaTypes.contains(
                    descriptor.mediaType
                ) else { throw SecureMediaAttachmentError.invalidDescriptor }
                if let mediaData = message.attachmentData {
                    guard descriptor.plaintextByteSize == mediaData.count else {
                        throw SecureMediaAttachmentError.invalidDescriptor
                    }
                } else if let parked = await mediaBlobs.read(descriptor.storageKey, local) {
                    guard descriptor.plaintextByteSize == parked.count else {
                        throw SecureMediaAttachmentError.invalidDescriptor
                    }
                }
                // A checkpointed large attachment already uploaded its ciphertext; the descriptor
                // body alone is sufficient to replay the send even if the local plaintext copy
                // was evicted.
            } else if message.attachmentData != nil {
                throw SecureMediaAttachmentError.invalidDescriptor
            }
            let preparedDescriptor = KitMediaMessageDescriptor.parse(preparedMessage.body)
            return try await queueText(
                forUserID: local,
                conversation: conversation,
                text: preparedMessage.body,
                attachmentData: preparedMessage.attachmentData,
                existingCommandID: commandID,
                existingMessageID: messageID,
                expectedExistingCommand: command,
                expectedExistingMessage: preparedMessage,
                requiredRichMediaType: preparedMessage.pendingAttachment?.mediaType
                    ?? preparedDescriptor?.mediaType,
                requiredPlaintextBytes: preparedMessage.pendingAttachment?.byteCount
                    ?? preparedDescriptor?.plaintextByteSize,
                mediaMessageV2Items: mediaMessageV2Items
            )
        } catch let error as SecureMessagingExchangeError where error == .staleOutboundFanout {
            // The audience-drift retirement above already resolved this projection itself —
            // command retired, message visibly failed — so the liveness re-check below would
            // only masquerade that deliberate transition as a cancellation. The caller's
            // handling of this error is reload-only, which cannot harm a newer command.
            throw error
        } catch {
            // A transport, validation, activation, roster, or crypto failure belongs only to the
            // exact deferred projection that initiated it. If retry/user/session work replaced
            // that projection while an await was suspended, surface cancellation instead of an
            // obsolete error that could schedule or permanently fail the newer command.
            try await requireExactPendingProjection(
                command,
                message: ownedMessage,
                forUserID: local
            )
            throw error
        }
    }

    func queueImage(
        forUserID userID: String,
        conversationID: String,
        expectedRecipientUserID: String,
        title: String,
        imageData: Data,
        mediaType: String,
        caption: String?
    ) async throws -> SecureMessagingQueueResult {
        try await queueMediaAttachment(
            forUserID: userID,
            conversationID: conversationID,
            expectedRecipientUserID: expectedRecipientUserID,
            title: title,
            mediaData: imageData,
            mediaType: mediaType,
            caption: caption,
            storesInlineAttachment: true
        )
    }

    /// Encrypts, uploads, and queues any allowed media kind (image, voice note, video, document).
    /// `storesInlineAttachment` keeps small plaintext blobs in the encrypted state file for
    /// instant offline history; large blobs must be cached by the caller in the media file cache
    /// so routine state writes never rewrite multi-megabyte blobs.
    func queueMediaAttachment(
        forUserID userID: String,
        conversationID: String,
        expectedRecipientUserID: String,
        title: String,
        mediaData: Data,
        mediaType: String,
        caption: String?,
        storesInlineAttachment: Bool,
        submittedDraftBody: String? = nil,
        draftClearVersion: ConversationDraftWriteVersion? = nil
    ) async throws -> SecureMessagingQueueResult {
        guard (submittedDraftBody == nil) == (draftClearVersion == nil) else {
            throw SecureMessagingCryptoError.invalidContent
        }
        let local = try canonicalUUID(userID, error: .invalidAccount)
        let conversationID = try canonicalUUID(conversationID, error: .invalidConversation)
        let recipient = try canonicalUUID(
            expectedRecipientUserID,
            error: .invalidRecipient
        )
        guard SecureMessagingWire.allowedAttachmentMediaTypes.contains(mediaType),
              !mediaData.isEmpty,
              mediaData.count <= SecureMediaAttachmentCipher.maximumPlaintextBytes,
              KitMediaMessageDescriptor.canEncodeCaption(caption)
        else { throw SecureMediaAttachmentError.invalidMedia }
        let dto = try await transport.messagingConversation(id: conversationID)
        let validated = try validateConversation(
            dto,
            currentUserID: local,
            expectedRecipientUserID: recipient,
            fallbackTitle: title
        )
        _ = try await activation.activate(forUserID: local)
        if KitChatMediaKind(mediaType: mediaType) != .image
            || mediaData.count
                > MessagingRichMediaCapabilityPolicy.broadlyCompatibleMaximumPlaintextBytes {
            let snapshot = await store.snapshot()
            guard snapshot.profile?.id == local,
                  let enrollment = snapshot.secureMessaging?.enrollment,
                  enrollment.userID == local
            else { throw SecureMessagingExchangeError.invalidAccount }
            let roster = try await transport.messagingDeviceRoster(conversationId: conversationID)
            if KitChatMediaKind(mediaType: mediaType) != .image {
                guard MessagingRichMediaCapabilityPolicy.supports(
                    mediaType: mediaType,
                    roster: roster,
                    conversationID: conversationID,
                    currentDeviceID: enrollment.serverDeviceID,
                    recipientUserID: recipient
                ) else { throw SecureMediaAttachmentError.incompatibleRecipient }
            }
            try Self.requireLargeMediaRecipientSupport(
                plaintextByteSize: mediaData.count,
                roster: roster,
                conversationID: conversationID,
                currentDeviceID: enrollment.serverDeviceID,
                memberUserIDs: validated.memberUserIDs
            )
        }
        let descriptor = try await uploadMediaDescriptor(
            mediaData: mediaData,
            mediaType: mediaType,
            caption: caption
        )
        return try await queueText(
            forUserID: local,
            conversation: validated,
            text: descriptor.encoded,
            attachmentData: storesInlineAttachment ? mediaData : nil,
            submittedDraftBody: submittedDraftBody,
            draftClearVersion: draftClearVersion,
            requiredRichMediaType: mediaType,
            requiredPlaintextBytes: mediaData.count
        )
    }

    private func uploadMediaDescriptor(
        mediaData: Data,
        mediaType: String,
        caption: String?
    ) async throws -> KitMediaMessageDescriptor {
        guard SecureMessagingWire.allowedAttachmentMediaTypes.contains(mediaType),
              !mediaData.isEmpty,
              mediaData.count <= SecureMediaAttachmentCipher.maximumPlaintextBytes,
              KitMediaMessageDescriptor.canEncodeCaption(caption)
        else { throw SecureMediaAttachmentError.invalidMedia }
        let encrypted = try await Task.detached(priority: .userInitiated) {
            try SecureMediaAttachmentCipher.encrypt(mediaData)
        }.value
        let upload = try await transport.uploadMessagingAttachment(
            mediaType: mediaType,
            ciphertext: encrypted.ciphertext
        )
        guard let storageKey = upload.storageKey?.lowercased(),
              let byteSize = upload.byteSize,
              let digest = upload.ciphertextSha256?.lowercased(),
              SecureMessagingWirePolicy.isCanonicalUUID(storageKey),
              byteSize == Int64(encrypted.ciphertext.count),
              digest == encrypted.sha256Hex
        else { throw SecureMediaAttachmentError.serverMetadataMismatch }
        return try KitMediaMessageDescriptor(
            attachmentID: UUID().uuidString.lowercased(),
            storageKey: storageKey,
            mediaType: mediaType,
            ciphertextByteSize: byteSize,
            ciphertextSHA256: digest,
            keyMaterial: encrypted.keyMaterial,
            plaintextByteSize: encrypted.plaintextByteSize,
            caption: caption
        )
    }

    private func checkpointDeferredImageDescriptor(
        _ descriptor: KitMediaMessageDescriptor,
        command: OfflineCommand,
        message: LocalMessage,
        forUserID userID: String
    ) async throws -> LocalMessage {
        var finalized = message
        finalized.body = descriptor.encoded
        finalized.pendingAttachment = nil
        try await store.update { state in
            guard state.profile?.id == userID,
                  let indices = Self.exactPendingProjectionIndices(
                      in: state,
                      command: command,
                      message: message
                  )
            else { throw CancellationError() }
            state.messages[indices.message] = finalized
        }
        return finalized
    }

    /// Durable checkpoint shared by the multi-attachment upload loop, its reconcile pass, and
    /// its seal step: replace the exact pending message projection or surface cancellation —
    /// if retry, user, or session work already replaced the projection, the caller's work no
    /// longer applies. `requiringDistinctCacheKeys` re-proves, inside the mutation itself,
    /// that copied cache destinations still alias no other live message's blob.
    private func replaceDeferredMessageProjection(
        _ finalized: LocalMessage,
        command: OfflineCommand,
        message: LocalMessage,
        forUserID userID: String,
        requiringDistinctCacheKeys: [String] = []
    ) async throws -> LocalMessage {
        try await store.update { state in
            guard state.profile?.id == userID,
                  let indices = Self.exactPendingProjectionIndices(
                      in: state,
                      command: command,
                      message: message
                  ),
                  requiringDistinctCacheKeys.allSatisfy({ key in
                      state.messages.allSatisfy {
                          $0.id == message.id || !$0.localMediaStorageKeys.contains(key)
                      }
                  })
            else { throw CancellationError() }
            state.messages[indices.message] = finalized
        }
        return finalized
    }

    /// Downloads and decrypts the attachment of a sealed single-attachment (KITMEDIA1) message,
    /// addressed by local message identity — never by caller-supplied descriptor text. Exactly
    /// one current persisted row may match, and every field used here (storage key, expected
    /// sizes, digest, key material) is re-read from that row's body at open time, so a caller
    /// can only ever open exactly what a message it can already see currently declares.
    /// Verification is fail-closed: server byte size, ciphertext digest, plaintext byte count.
    func openImage(
        forUserID userID: String,
        conversationID: String,
        messageID: UUID
    ) async throws -> Data {
        let local = try canonicalUUID(userID, error: .invalidAccount)
        let conversationID = try canonicalUUID(conversationID, error: .invalidConversation)
        let snapshot = await store.snapshot()
        let rows = snapshot.messages.filter {
            $0.id == messageID && $0.conversationId == conversationID
        }
        guard snapshot.profile?.id == local,
              rows.count == 1, let message = rows.first,
              message.pendingAttachment == nil,
              message.pendingMediaBatch == nil,
              let descriptor = KitMediaMessageDescriptor.parse(message.body),
              let keyMaterial = descriptor.keyMaterial
        else { throw SecureMediaAttachmentError.invalidDescriptor }
        let ciphertext = try await transport.downloadMessagingAttachment(
            storageKey: descriptor.storageKey,
            expectedByteSize: descriptor.ciphertextByteSize
        )
        let plaintext = try await Task.detached(priority: .userInitiated) {
            try SecureMediaAttachmentCipher.decrypt(
                ciphertext,
                keyMaterial: keyMaterial,
                expectedSHA256Hex: descriptor.ciphertextSHA256
            )
        }.value
        guard plaintext.count == descriptor.plaintextByteSize else {
            throw SecureMediaAttachmentError.invalidCiphertext
        }
        return plaintext
    }

    /// Downloads and decrypts one attachment of a sealed KITMEDIA2 message, addressed by local
    /// message identity and display index. Addressing by identity — never by caller-supplied
    /// descriptor text — means every field used here (storage key, expected sizes, digest, key
    /// material) is re-read from the persisted row at open time, so a caller can only ever open
    /// exactly what a message it can already see declares. Verification is fail-closed and
    /// mirrors `openImage`: server byte size, ciphertext digest, then plaintext byte count.
    func openMediaBatchItem(
        forUserID userID: String,
        conversationID: String,
        messageID: UUID,
        itemIndex: Int
    ) async throws -> Data {
        let local = try canonicalUUID(userID, error: .invalidAccount)
        let conversationID = try canonicalUUID(conversationID, error: .invalidConversation)
        let snapshot = await store.snapshot()
        let rows = snapshot.messages.filter {
            $0.id == messageID && $0.conversationId == conversationID
        }
        guard snapshot.profile?.id == local,
              rows.count == 1, let message = rows.first,
              message.pendingAttachment == nil,
              message.pendingMediaBatch == nil,
              let descriptor = KitMediaMessageV2Descriptor.parse(message.body),
              descriptor.items.indices.contains(itemIndex)
        else { throw SecureMediaAttachmentError.invalidDescriptor }
        let item = descriptor.items[itemIndex]
        guard let keyMaterial = item.keyMaterial else {
            throw SecureMediaAttachmentError.invalidDescriptor
        }
        let ciphertext = try await transport.downloadMessagingAttachment(
            storageKey: item.storageKey,
            expectedByteSize: item.ciphertextByteSize
        )
        let plaintext = try await Task.detached(priority: .userInitiated) {
            try SecureMediaAttachmentCipher.decrypt(
                ciphertext,
                keyMaterial: keyMaterial,
                expectedSHA256Hex: item.ciphertextSHA256
            )
        }.value
        guard plaintext.count == item.plaintextByteSize else {
            throw SecureMediaAttachmentError.invalidCiphertext
        }
        return plaintext
    }

    private func queueText(
        forUserID userID: String,
        conversation: ValidatedDirectConversation,
        text: String,
        newClientMessageID: UUID? = nil,
        attachmentData: Data? = nil,
        existingCommandID: UUID? = nil,
        existingMessageID: UUID? = nil,
        expectedExistingCommand: OfflineCommand? = nil,
        expectedExistingMessage: LocalMessage? = nil,
        submittedDraftBody: String? = nil,
        draftClearVersion: ConversationDraftWriteVersion? = nil,
        requiredRichMediaType: String? = nil,
        requiredPlaintextBytes: Int? = nil,
        mediaMessageV2Items: [MessagingMediaMessageV2CapabilityPolicy.DraftItem]? = nil,
        replyToServerMessageID: String? = nil
    ) async throws -> SecureMessagingQueueResult {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let beginsReaction = SecureMessageReservedPrefixPolicy.beginsWithReservedPrefix(
            body,
            prefix: KitMessageReaction.prefix
        )
        let reaction = KitMessageReaction.parse(body)
        let beginsEdit = SecureMessageReservedPrefixPolicy.beginsWithReservedPrefix(
            body,
            prefix: KitMessageEdit.prefix
        )
        let edit = KitMessageEdit.parse(body)
        // A reaction already points at its own target, and so does a correction; an answer points
        // at what it answers. No two of them ever coexist on one envelope. On the reconcile pass
        // the answer is already committed locally, so its pointer comes from that projection
        // rather than the argument.
        let replyTarget = reaction == nil && edit == nil
            ? (expectedExistingMessage?.replyToServerMessageID ?? replyToServerMessageID)
            : nil
        guard !body.isEmpty,
              !beginsReaction || reaction != nil,
              reaction == nil || replyToServerMessageID == nil,
              !beginsEdit || edit != nil,
              edit == nil || replyToServerMessageID == nil,
              reaction == nil || edit == nil,
              replyTarget.map(SecureMessagingValidation.isCanonicalUUID) ?? true,
              (requiredRichMediaType == nil) == (requiredPlaintextBytes == nil)
        else { throw SecureMessagingCryptoError.invalidContent }
        guard (existingCommandID == nil) == (existingMessageID == nil),
              newClientMessageID == nil || existingMessageID == nil,
              (expectedExistingCommand == nil) == (existingCommandID == nil),
              (expectedExistingMessage == nil) == (existingMessageID == nil),
              expectedExistingCommand?.id == existingCommandID,
              expectedExistingCommand?.messageId == existingMessageID,
              expectedExistingMessage?.id == existingMessageID,
              (submittedDraftBody == nil) == (draftClearVersion == nil),
              submittedDraftBody == nil || existingMessageID == nil
        else {
            throw SecureMessagingExchangeError.invalidConversation
        }
        // A KITMEDIA2 descriptor rides this path only when the deferred pipeline hands over
        // its own verified projection: the sealed rows must mirror the declared items exactly,
        // and a v2 body arriving without them is a smuggled descriptor, not a text message.
        if let mediaMessageV2Items {
            guard let sealed = KitMediaMessageV2Descriptor.parse(body),
                  requiredRichMediaType == nil,
                  attachmentData == nil,
                  sealed.items.count == mediaMessageV2Items.count,
                  zip(sealed.items, mediaMessageV2Items).allSatisfy({
                      $0.mediaType == $1.mediaType
                          && $0.plaintextByteSize == $1.plaintextByteSize
                  })
            else { throw SecureMessagingExchangeError.invalidConversation }
        } else if KitMediaMessageV2Descriptor.parse(body) != nil {
            throw SecureMessagingExchangeError.invalidConversation
        }
        // Family-wide ingress allowlist, mirroring `queueDeferredText`. A KITMEDIA body may
        // pass only with its own dedicated media-path provenance: sealed v2 was vouched for
        // above by the handover items, and valid v1 must arrive announcing the exact media
        // type and byte size the deferred pipeline derived from its blob — public text
        // callers pass neither, so even a well-formed descriptor pasted as "text" is
        // rejected here. Every other family spelling — malformed v1/v2 or an unknown future
        // version — is a smuggled maybe-descriptor and never becomes durable local "text".
        if mediaMessageV2Items == nil {
            if let v1Descriptor = KitMediaMessageDescriptor.parse(body) {
                guard requiredRichMediaType == v1Descriptor.mediaType,
                      requiredPlaintextBytes == v1Descriptor.plaintextByteSize
                else { throw SecureMessagingCryptoError.invalidContent }
            } else if KitMediaMessageFamilyPolicy.isReservedFamilyText(body) {
                throw SecureMessagingCryptoError.invalidContent
            }
        }
        if let expectedExistingCommand, let expectedExistingMessage {
            try await requireExactPendingProjection(
                expectedExistingCommand,
                message: expectedExistingMessage,
                forUserID: userID
            )
        }
        _ = try await activation.activate(forUserID: userID)
        let clientMessageID = existingMessageID ?? newClientMessageID ?? UUID()
        let commandID = existingCommandID ?? UUID()
        let canonicalClientMessageID = clientMessageID.uuidString.lowercased()

        for _ in 0..<3 {
            let snapshot = await store.snapshot()
            guard snapshot.profile?.id == userID,
                  let initialCrypto = snapshot.secureMessaging,
                  let enrollment = initialCrypto.enrollment,
                  enrollment.userID == userID
            else { throw SecureMessagingExchangeError.invalidAccount }
            let outboundRecipientUserIDs = conversation.outboundRecipientUserIDs(
                excluding: userID
            )
            if let reaction {
                try Self.requireLocalReactionTarget(
                    reaction,
                    conversationID: conversation.id,
                    in: snapshot
                )
            }
            if let edit {
                try Self.requireLocalEditTarget(
                    edit,
                    conversationID: conversation.id,
                    localUserID: userID,
                    in: snapshot,
                    requiringWindow: false
                )
            }
            if let newClientMessageID,
               let existing = try Self.existingDeferredTextResult(
                   in: snapshot,
                   clientMessageID: newClientMessageID,
                   localUserID: userID,
                   recipientUserIDs: outboundRecipientUserIDs,
                   conversation: conversation.localProjection,
                   body: body,
                   scheduledAt: nil
               ) {
                return existing
            }

            let rosterDTO = try await transport.messagingDeviceRoster(
                conversationId: conversation.id
            )
            if conversation.isGroup,
               !MessagingGroupCapabilityPolicy.supports(
                   roster: rosterDTO,
                   conversationID: conversation.id,
                   currentDeviceID: enrollment.serverDeviceID,
                   memberUserIDs: conversation.memberUserIDs
               ) {
                // Fail closed: group ciphertext never leaves this device unless every member
                // device is server-attested for the group protocol.
                throw SecureMessagingExchangeError.groupCapabilityUnavailable
            }
            if reaction != nil,
               !MessagingReactionCapabilityPolicy.supports(
                   roster: rosterDTO,
                   conversationID: conversation.id,
                   currentDeviceID: enrollment.serverDeviceID,
                   memberUserIDs: conversation.memberUserIDs
               ) {
                throw SecureMessagingExchangeError.reactionCapabilityUnavailable
            }
            if edit != nil,
               !MessagingMessageEditCapabilityPolicy.supports(
                   roster: rosterDTO,
                   conversationID: conversation.id,
                   currentDeviceID: enrollment.serverDeviceID,
                   memberUserIDs: conversation.memberUserIDs
               ) {
                // Fail closed rather than let a peer whose client predates the descriptor render
                // a correction as a bubble of raw protocol text.
                throw SecureMessagingExchangeError.editCapabilityUnavailable
            }
            if let mediaMessageV2Items {
                // §7 freshness: the pre-upload capabilities document proved admission when
                // upload work began, but eight 200 MiB uploads can run for minutes. The gate
                // that authorizes Signal encryption therefore fetches its own document on
                // every attempt of this loop — the same liveness as the roster beside it — so
                // a rollout or quota withdrawal during upload fails the whole message closed
                // here, before any ciphertext exists. A stale pre-upload DTO is deliberately
                // not accepted; a multi-attachment message is never split or downgraded.
                let freshCapabilities = try await transport.capabilities()
                guard MessagingMediaMessageV2CapabilityPolicy.admitsComposition(
                    capabilities: freshCapabilities,
                    roster: rosterDTO,
                    conversationID: conversation.id,
                    currentDeviceID: enrollment.serverDeviceID,
                    currentUserID: userID,
                    memberUserIDs: conversation.memberUserIDs,
                    items: mediaMessageV2Items
                ) else {
                    throw SecureMessagingExchangeError.mediaMessageCapabilityUnavailable
                }
            }
            if let requiredRichMediaType,
               KitChatMediaKind(mediaType: requiredRichMediaType) != .image {
                try Self.requireRichMediaRecipientSupport(
                    mediaType: requiredRichMediaType,
                    roster: rosterDTO,
                    conversationID: conversation.id,
                    currentDeviceID: enrollment.serverDeviceID,
                    recipientUserIDs: outboundRecipientUserIDs
                )
            }
            if let requiredPlaintextBytes {
                try Self.requireLargeMediaRecipientSupport(
                    plaintextByteSize: requiredPlaintextBytes,
                    roster: rosterDTO,
                    conversationID: conversation.id,
                    currentDeviceID: enrollment.serverDeviceID,
                    memberUserIDs: conversation.memberUserIDs
                )
            }
            let roster = try SecureMessagingMapper.roster(
                from: rosterDTO,
                use: .current,
                expectedConversationID: conversation.id,
                currentDeviceID: enrollment.serverDeviceID,
                currentUserID: userID,
                expectedMemberUserIDs: conversation.memberUserIDs
            )
            let recipients = try roster.recipients(
                excluding: enrollment.serverDeviceID
            )
            let sender = enrollment.address
            var preparedCrypto = initialCrypto
            let missing = try await engine.recipientsRequiringSession(
                currentState: preparedCrypto,
                localSender: sender,
                recipients: recipients
            )
            if !missing.isEmpty {
                let requestedIDs = Set(missing.map(\.address.serverDeviceID))
                let consumed = try await transport.consumeMessagingKeyBundles(
                    conversationId: conversation.id,
                    request: try ConsumeMessagingKeyBundlesRequest(
                        deviceIds: requestedIDs.sorted()
                    )
                )
                let bundles = try SecureMessagingMapper.remoteBundles(
                    from: consumed,
                    roster: roster,
                    requestedRemoteDeviceIDs: requestedIDs,
                    localDeviceID: enrollment.serverDeviceID
                )
                preparedCrypto = try await engine.establishSessions(
                    currentState: preparedCrypto,
                    localSender: sender,
                    bundles: bundles
                )
            }
            let encrypted = try await engine.encryptText(
                currentState: preparedCrypto,
                sender: sender,
                conversationID: conversation.id,
                clientMessageID: canonicalClientMessageID,
                rosterRevision: roster.rosterRevision,
                replyToMessageID: reaction?.targetServerMessageID
                    ?? edit?.targetServerMessageID
                    ?? replyTarget,
                text: body,
                recipients: recipients
            )
            var nextCrypto = encrypted.state
            nextCrypto.cachedRosters[roster.rosterRevision] = roster
            let existingMessage = existingMessageID.flatMap { messageID in
                snapshot.messages.first(where: { $0.id == messageID })
            }
            let existingCommand = existingCommandID.flatMap { queuedID in
                snapshot.outbox.first(where: { $0.id == queuedID })
            }
            if existingMessageID != nil {
                guard let expectedExistingCommand,
                      let expectedExistingMessage,
                      existingCommand == expectedExistingCommand,
                      existingMessage == expectedExistingMessage,
                      expectedExistingMessage.body == body,
                      expectedExistingMessage.conversationId == conversation.id,
                      expectedExistingMessage.senderId == userID,
                      expectedExistingCommand.kind == .secureMessage,
                      expectedExistingCommand.secureMessageFanout == nil,
                      expectedExistingCommand.messageId == clientMessageID,
                      expectedExistingCommand.conversationId == conversation.id
                else { throw CancellationError() }
            }
            let now = existingMessage?.createdAt ?? Date()
            let localMessage = LocalMessage(
                id: clientMessageID,
                conversationId: conversation.id,
                senderId: userID,
                body: body,
                createdAt: now,
                sentAt: nil,
                state: .queued,
                failureReason: nil,
                isOutgoing: true,
                attachmentData: attachmentData,
                replyToServerMessageID: replyTarget,
                // Sealing and fanout replace the pending projection wholesale; the scheduled
                // instant the user chose must survive both replacements.
                scheduledAt: existingMessage?.scheduledAt
            )
            let command = OfflineCommand(
                id: commandID,
                kind: .secureMessage,
                createdAt: now,
                nextAttemptAt: now,
                attemptCount: existingCommand?.attemptCount ?? 0,
                conversationId: conversation.id,
                messageId: clientMessageID,
                recipientUserIds: outboundRecipientUserIDs,
                recipientName: conversation.title,
                video: nil,
                expiresAt: nil,
                secureMessageFanout: encrypted.fanout,
                scheduledAt: existingCommand?.scheduledAt
            )
            var updatedConversation = conversation.localProjection
            updatedConversation.updatedAt = max(updatedConversation.updatedAt, now)
            let queuedConversation = updatedConversation
            do {
                try await store.commitSecureMessaging(
                    forUserID: userID,
                    expectedState: initialCrypto,
                    nextState: nextCrypto
                ) { state in
                    Self.upsert(conversation: queuedConversation, in: &state)
                    if existingMessageID != nil {
                        guard let expectedExistingCommand,
                              let expectedExistingMessage,
                              let indices = Self.exactPendingProjectionIndices(
                                  in: state,
                                  command: expectedExistingCommand,
                                  message: expectedExistingMessage
                              )
                        else { throw CancellationError() }
                        state.messages[indices.message] = localMessage
                        state.outbox[indices.command] = command
                    } else {
                        guard !state.messages.contains(where: { $0.id == clientMessageID }),
                              !state.outbox.contains(where: { $0.id == command.id })
                        else { throw SecureMessagingCryptoError.staleState }
                        state.messages.append(localMessage)
                        state.outbox.append(command)
                    }
                    if let submittedDraftBody, let draftClearVersion {
                        _ = ConversationDraftPolicy.clearAfterSuccessfulQueue(
                            submittedBody: submittedDraftBody,
                            conversationID: conversation.id,
                            ownerUserID: userID,
                            writeVersion: draftClearVersion,
                            in: &state
                        )
                    }
                }
                return SecureMessagingQueueResult(
                    conversation: queuedConversation,
                    clientMessageID: clientMessageID
                )
            } catch SecureMessagingCryptoError.staleState {
                try Task.checkCancellation()
                continue
            }
        }
        throw SecureMessagingExchangeError.retryLimitExceeded
    }

    func sendQueuedMessage(
        commandID: UUID,
        forUserID userID: String
    ) async throws -> EncryptedMessageDTO {
        let userID = try canonicalUUID(userID, error: .invalidAccount)
        let snapshot = await store.snapshot()
        guard snapshot.profile?.id == userID,
              let command = snapshot.outbox.first(where: {
                  $0.id == commandID && $0.kind == .secureMessage
              }),
              let fanout = command.secureMessageFanout,
              command.conversationId == fanout.conversationID,
              command.messageId?.uuidString.lowercased() == fanout.clientMessageID,
              let localMessage = snapshot.messages.first(where: {
                  $0.id.uuidString.lowercased() == fanout.clientMessageID
              }),
              localMessage.conversationId == fanout.conversationID,
              localMessage.senderId == userID,
              localMessage.isOutgoing
        else { throw SecureMessagingExchangeError.invalidConversation }
        let attachments = KitMediaMessageFamilyPolicy.attachmentRequests(
            for: localMessage.body
        )

        do {
            let response = try await transport.sendEncryptedMessage(
                conversationId: fanout.conversationID,
                request: try SecureMessagingMapper.sendRequest(
                    from: fanout,
                    plaintext: localMessage.body,
                    attachments: attachments
                )
            )
            let outbound = try validateOutboundResponse(
                response,
                fanout: fanout,
                expectedPlaintext: localMessage.body,
                expectedAttachments: attachments,
                userID: userID,
                enrollment: snapshot.secureMessaging?.enrollment
            )
            try await store.update { state in
                guard state.profile?.id == userID,
                      let indices = Self.exactPendingProjectionIndices(
                          in: state,
                          command: command,
                          message: localMessage
                      )
                else { throw CancellationError() }
                state.outbox.remove(at: indices.command)
                state.messages[indices.message].serverMessageId = outbound.serverMessageID
                state.messages[indices.message].sentAt = outbound.sentAt
                state.messages[indices.message].state = .sent
                state.messages[indices.message].failureReason = nil
                state.messages[indices.message].secureMessagingHistory = outbound.historyMetadata
            }
            return response
        } catch let error as APIErrorPayload
            where error.code == "ATTACHMENT_REFERENCE_INVALID"
            && KitMediaMessageV2Descriptor.parse(localMessage.body) != nil {
            // Only the contract's expiry code takes this recovery: ATTACHMENT_ALREADY_ATTACHED
            // signals an attachment-identity conflict — the server already holds one of these
            // uploads bound to a message — and reopening would mint a whole new upload set
            // under the same client message id against blobs the server just said it has. That
            // conflict takes the ordinary visible failure path instead.
            // §7 blob expiry: the sealed descriptor's uploads lapsed server-side. Reopen the
            // batch from the descriptor — same client message id, same key material, retained
            // plaintext as source — and clear the now-unusable fanout so flush re-uploads,
            // re-seals, and re-encrypts. The command survives: this is a transport lapse, not
            // a user-confirmation event, and the message is never split or abandoned.
            try await reopenExpiredMediaBatch(
                command,
                message: localMessage,
                userID: userID
            )
            throw SecureMessagingExchangeError.mediaMessageBlobExpired
        } catch let error as APIErrorPayload where [
            "MESSAGING_ROSTER_CHANGED",
            "DEVICE_ENVELOPES_INCOMPLETE",
            "MESSAGING_ROSTER_PROTOCOL_MISMATCH",
        ].contains(error.code) {
            if KitMediaMessageV2Descriptor.parse(localMessage.body) != nil {
                // A sealed KITMEDIA2 message outlives a roster change as the SAME message and
                // command: only the fanout was encrypted to the vanished device set, so only
                // the fanout clears. The next flush pass re-gates the new roster and
                // re-encrypts the same descriptor under the same client message id. Uploads
                // are untouched — blob references survive roster changes; re-upload rides the
                // expiry path above. v1 keeps its audited visible stop below.
                try await resetStaleFanoutForRetry(
                    command,
                    message: localMessage,
                    userID: userID
                )
                throw SecureMessagingExchangeError.mediaMessageRosterChanged
            }
            try await abandonStaleFanout(
                command,
                message: localMessage,
                userID: userID
            )
            throw SecureMessagingExchangeError.staleOutboundFanout
        } catch {
            try await requireExactPendingProjection(
                command,
                message: localMessage,
                forUserID: userID
            )
            throw error
        }
    }

    func markConversationRead(
        conversationID: String,
        throughServerMessageID messageID: String,
        forUserID userID: String
    ) async throws {
        let userID = try canonicalUUID(userID, error: .invalidAccount)
        let conversationID = try canonicalUUID(
            conversationID,
            error: .invalidConversation
        )
        let messageID = try canonicalUUID(messageID, error: .invalidConversation)
        let snapshot = await store.snapshot()
        let requestedCandidates = snapshot.messages.filter {
            $0.conversationId == conversationID
                && $0.serverMessageId == messageID
                && !$0.isOutgoing
                && $0.state == .received
        }
        guard snapshot.profile?.id == userID,
              requestedCandidates.count == 1,
              let requested = requestedCandidates.first
        else { throw SecureMessagingExchangeError.invalidConversation }
        let receipt = try await transport.markMessagingConversationRead(
            conversationId: conversationID,
            request: try MarkMessagingConversationReadRequest(messageId: messageID)
        )
        try Task.checkCancellation()
        let canonicalMessageID = try canonicalUUID(
            receipt.lastReadMessageId,
            error: .invalidServerResponse
        )
        let readAt = try parseServerDate(receipt.readAt)
        guard receipt.conversationId == conversationID,
              receipt.userId == userID,
              receipt.lastReadMessageId == canonicalMessageID
        else { throw SecureMessagingExchangeError.invalidServerResponse }
        let canonicalCandidates = snapshot.messages.filter {
            $0.conversationId == conversationID
                && $0.serverMessageId == canonicalMessageID
                && !$0.isOutgoing
        }
        // Another enrolled device can advance the server marker beyond this installation's
        // current projection. Preserve durable unread state until sync authenticates that target.
        guard !canonicalCandidates.isEmpty else { return }
        guard canonicalCandidates.count == 1,
              let canonical = canonicalCandidates.first,
              Self.compareServerMessageOrder(canonical, requested) != .orderedAscending,
              readAt >= (canonical.sentAt ?? canonical.createdAt)
        else { throw SecureMessagingExchangeError.invalidServerResponse }
        try await store.update { state in
            guard state.profile?.id == userID else { throw StoreError.accountChanged }
            let currentCanonicalCandidates = state.messages.filter {
                $0.conversationId == conversationID
                    && $0.serverMessageId == canonicalMessageID
                    && !$0.isOutgoing
            }
            guard currentCanonicalCandidates.count == 1,
                  let currentCanonical = currentCanonicalCandidates.first
            else { return }
            for index in state.messages.indices where
                state.messages[index].conversationId == conversationID
                    && !state.messages[index].isOutgoing
                    && state.messages[index].serverMessageId != nil
                    && Self.compareServerMessageOrder(
                        state.messages[index],
                        currentCanonical
                    ) != .orderedDescending {
                state.messages[index].state = .read
            }
            if let index = state.conversations.firstIndex(where: { $0.id == conversationID }) {
                state.conversations[index].unreadCount = state.messages.reduce(into: 0) {
                    count, message in
                    if message.conversationId == conversationID,
                       !message.isOutgoing,
                       message.serverMessageId != nil,
                       message.state == .received,
                       // Reactions and corrections are metadata and never count as unread.
                       message.secureMessagingHistory?.kind.isTimelineMetadata != true {
                        count += 1
                    }
                }
            }
        }
    }

    /// Sent, delivered and read moments for a message this account sent.
    ///
    /// Asked for on demand rather than kept in the projection: these moments keep changing after
    /// the message is out of the composer's hands, and a durable copy would only be stale by the
    /// time somebody opened it. The message must be one this device has authenticated locally and
    /// sent itself, so the screen cannot ask about someone else's words — which the server would
    /// refuse anyway, and this makes the refusal unreachable rather than merely handled.
    func messageDeliveryInfo(
        conversationID: String,
        serverMessageID messageID: String,
        forUserID userID: String
    ) async throws -> MessageDeliveryInfo {
        let userID = try canonicalUUID(userID, error: .invalidAccount)
        let conversationID = try canonicalUUID(conversationID, error: .invalidConversation)
        let messageID = try canonicalUUID(messageID, error: .invalidConversation)
        let snapshot = await store.snapshot()
        let sentFromHere = snapshot.messages.contains {
            $0.conversationId == conversationID
                && $0.serverMessageId?.caseInsensitiveCompare(messageID) == .orderedSame
                && $0.isOutgoing
        }
        // The server answers this to the sender alone. Refusing it here as well means a screen
        // that should never have offered the question gets a local no rather than a 403.
        guard snapshot.profile?.id.caseInsensitiveCompare(userID) == .orderedSame, sentFromHere
        else { throw SecureMessagingExchangeError.invalidConversation }
        // A direct chat has exactly one counterpart, and membership of one cannot change, so the
        // answer is pinned to that person and anybody else named in it was invented. A group's
        // record is historical to the message — people joined and left after it was sent — so
        // today's roster is the wrong yardstick and pinning to it would reject the truthful answer.
        let conversation = snapshot.conversations.first { $0.id == conversationID }
        let expectedRecipientIDs: Set<String>? = {
            guard let conversation, !conversation.isGroup else { return nil }
            let peers = Set(conversation.participantUserIds.filter {
                $0.caseInsensitiveCompare(userID) != .orderedSame
            })
            return peers.isEmpty ? nil : peers
        }()
        let response = try await transport.messagingMessageInfo(
            conversationId: conversationID,
            messageId: messageID
        )
        try Task.checkCancellation()
        guard let info = MessageDeliveryInfoMapper.make(
            response,
            expectedConversationID: conversationID,
            expectedMessageID: messageID,
            expectedRecipientIDs: expectedRecipientIDs
        ) else { throw SecureMessagingExchangeError.invalidServerResponse }
        return info
    }

    /// Matches the backend's monotonic order: `sent_at`, then the canonical message UUID.
    nonisolated static func compareServerMessageOrder(
        _ lhs: LocalMessage,
        _ rhs: LocalMessage
    ) -> ComparisonResult {
        let lhsDate = lhs.sentAt ?? lhs.createdAt
        let rhsDate = rhs.sentAt ?? rhs.createdAt
        if lhsDate < rhsDate { return .orderedAscending }
        if lhsDate > rhsDate { return .orderedDescending }
        return (lhs.serverMessageId ?? "").compare(rhs.serverMessageId ?? "")
    }

    private func abandonStaleFanout(
        _ command: OfflineCommand,
        message: LocalMessage,
        userID: String
    ) async throws {
        try await store.update { state in
            guard state.profile?.id == userID,
                  let indices = Self.exactPendingProjectionIndices(
                      in: state,
                      command: command,
                      message: message
                  )
            else { throw CancellationError() }
            state.outbox.remove(at: indices.command)
            state.messages[indices.message].state = .failed
            state.messages[indices.message].failureReason =
                SecureMessagingExchangeError.staleOutboundFanout.localizedDescription
        }
    }

    /// A sealed KITMEDIA2 send rejected for a roster change keeps its message and command
    /// whole — same ids, same schedule, same descriptor body — and clears only the fanout,
    /// which was encrypted to a device set that no longer exists. Flush re-prepares and
    /// re-encrypts to the new roster under the same client message id.
    private func resetStaleFanoutForRetry(
        _ command: OfflineCommand,
        message: LocalMessage,
        userID: String
    ) async throws {
        try await store.update { state in
            guard state.profile?.id == userID,
                  let indices = Self.exactPendingProjectionIndices(
                      in: state,
                      command: command,
                      message: message
                  )
            else { throw CancellationError() }
            state.outbox[indices.command].secureMessageFanout = nil
        }
    }

    /// §7 blob expiry: rebuild the pending batch from the sealed descriptor under the SAME
    /// client message id — identical ids, key material, media types, sizes, caption, and
    /// display order; each item's lapsed storage key becomes its plaintext pointer so every
    /// item re-uploads fresh. The body returns to its canonical pending form (caption, or the
    /// placeholder when captionless): the deferred pipeline replays this exactly like a first
    /// send, the raw descriptor stops being display text, and message id, command id,
    /// schedule, and reply target all survive untouched. Only the fanout clears.
    private func reopenExpiredMediaBatch(
        _ command: OfflineCommand,
        message: LocalMessage,
        userID: String
    ) async throws {
        guard let descriptor = KitMediaMessageV2Descriptor.parse(message.body) else {
            throw SecureMessagingExchangeError.messageNotRetryable
        }
        let reopened = KitMediaMessageV2OutboundBatch.reopened(from: descriptor)
        guard reopened.isStructurallyValid else {
            throw SecureMessagingExchangeError.messageNotRetryable
        }
        let pendingBody = reopened.caption
            ?? Self.mediaBatchPlaceholderBody(itemCount: reopened.items.count)
        try await store.update { state in
            guard state.profile?.id == userID,
                  let indices = Self.exactPendingProjectionIndices(
                      in: state,
                      command: command,
                      message: message
                  )
            else { throw CancellationError() }
            state.messages[indices.message].body = pendingBody
            state.messages[indices.message].pendingMediaBatch = reopened
            state.outbox[indices.command].secureMessageFanout = nil
        }
    }

    private func requireExactPendingProjection(
        _ command: OfflineCommand,
        message: LocalMessage,
        forUserID userID: String
    ) async throws {
        let snapshot = await store.snapshot()
        guard snapshot.profile?.id == userID,
              Self.exactPendingProjectionIndices(
                  in: snapshot,
                  command: command,
                  message: message
              ) != nil
        else { throw CancellationError() }
    }

    private static func exactPendingProjectionIndices(
        in state: PersistedState,
        command expectedCommand: OfflineCommand,
        message expectedMessage: LocalMessage
    ) -> (command: Int, message: Int)? {
        guard expectedCommand.kind == .secureMessage,
              expectedCommand.messageId == expectedMessage.id,
              expectedCommand.conversationId == expectedMessage.conversationId,
              let commandIndex = state.outbox.firstIndex(where: {
                  $0.id == expectedCommand.id
              }),
              state.outbox.lastIndex(where: {
                  $0.id == expectedCommand.id
              }) == commandIndex,
              state.outbox[commandIndex] == expectedCommand,
              let messageIndex = state.messages.firstIndex(where: {
                  $0.id == expectedMessage.id
              }),
              state.messages.lastIndex(where: {
                  $0.id == expectedMessage.id
              }) == messageIndex,
              state.messages[messageIndex] == expectedMessage
        else { return nil }
        return (commandIndex, messageIndex)
    }

    func sync(forUserID userID: String) async throws -> SecureMessagingSyncResult {
        let userID = try canonicalUUID(userID, error: .invalidAccount)
        if let syncTask {
            guard syncUserID == userID else {
                throw SecureMessagingExchangeError.invalidAccount
            }
            return try await syncTask.value
        }
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.performSync(forUserID: userID)
        }
        syncUserID = userID
        syncTask = task
        do {
            let result = try await task.value
            syncTask = nil
            syncUserID = nil
            return result
        } catch {
            syncTask = nil
            syncUserID = nil
            throw error
        }
    }

    private func performSync(forUserID userID: String) async throws -> SecureMessagingSyncResult {
        _ = try await activation.activate(forUserID: userID)
        var pageCount = 0
        var receivedCount = 0
        var transitionCount = 0

        while pageCount < 100 {
            try Task.checkCancellation()
            let cursor = await store.snapshot().secureMessaging?.syncCursor
            let response = try await transport.syncEncryptedMessages(
                cursor: cursor,
                limit: SecureMessagingWire.maximumSyncPage
            )
            let page = try Self.validateSyncPage(response, after: cursor)

            let applied = try await applySyncPage(
                page.events,
                nextCursor: page.nextCursor,
                forUserID: userID
            )
            receivedCount += applied.receivedMessages
            transitionCount += applied.appliedTransitions
            pageCount += 1
            try await flushDeliveryAcknowledgements(forUserID: userID)
            if !page.hasMore {
                try? await flushHistoryBackfills(forUserID: userID)
                return SecureMessagingSyncResult(
                    pages: pageCount,
                    receivedMessages: receivedCount,
                    appliedTransitions: transitionCount
                )
            }
        }
        throw SecureMessagingExchangeError.retryLimitExceeded
    }

    private func flushHistoryBackfills(forUserID userID: String) async throws {
        guard !isFlushingHistory else { return }
        isFlushingHistory = true
        defer { isFlushingHistory = false }

        var reconciliationNeedsRetry = false
        do {
            try await reconcileHistoryBackfillTargetsIfNeeded(forUserID: userID)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SecureMessagingExchangeError where error == .invalidAccount {
            throw error
        } catch {
            // Roster discovery is repair work. A temporary failure must not prevent already
            // durable tasks for other conversations from receiving a bounded attempt.
            reconciliationNeedsRetry = true
        }

        var drain = SecureMessagingHistoryDrainState(
            maximumWorkUnits: 16,
            batchSize: 4
        )
        while drain.workUnits < drain.maximumWorkUnits {
            try Task.checkCancellation()
            let snapshot = await store.snapshot()
            guard snapshot.profile?.id == userID,
                  let crypto = snapshot.secureMessaging,
                  let enrollment = crypto.enrollment,
                  enrollment.userID == userID
            else { throw SecureMessagingExchangeError.invalidAccount }
            if crypto.historyBackfillTasks.contains(where: {
                $0.targetDeviceID == enrollment.serverDeviceID
            }) || crypto.historyOutboundEnvelopes.values.contains(where: {
                $0.targetDeviceID == enrollment.serverDeviceID
            }) {
                try await discardCurrentDeviceHistoryWork(
                    forUserID: userID,
                    currentDeviceID: enrollment.serverDeviceID
                )
                continue
            }
            guard Set(crypto.historyBackfillTasks.map(\.key)).count
                    == crypto.historyBackfillTasks.count
            else { throw SecureMessagingCryptoError.invalidContent }
            let batch = drain.nextBatch(from: crypto.historyBackfillTasks)
            guard !batch.isEmpty else { break }
            for task in batch {
                try Task.checkCancellation()
                let madeProgress = try await attemptHistoryBackfillTask(
                    task,
                    userID: userID
                )
                drain.recordAttempt(of: task, madeProgress: madeProgress)
            }
        }

        let finalSnapshot = await store.snapshot()
        guard finalSnapshot.profile?.id == userID,
              let finalCrypto = finalSnapshot.secureMessaging,
              finalCrypto.enrollment?.userID == userID
        else { throw SecureMessagingExchangeError.invalidAccount }
        reconcileHistoryContinuation(
            forUserID: userID,
            pending: reconciliationNeedsRetry || !finalCrypto.historyBackfillTasks.isEmpty,
            madeProgress: drain.madeProgress
        )
    }

    private func reconcileHistoryContinuation(
        forUserID userID: String,
        pending: Bool,
        madeProgress: Bool
    ) {
        guard let delayNanoseconds = SecureMessagingHistoryContinuationPolicy.delayNanoseconds(
            pending: pending,
            madeProgress: madeProgress
        ) else {
            cancelHistoryContinuation()
            return
        }
        scheduleHistoryContinuation(
            forUserID: userID,
            delayNanoseconds: delayNanoseconds
        )
    }

    private func scheduleHistoryContinuation(
        forUserID userID: String,
        delayNanoseconds: UInt64
    ) {
        if let existing = historyContinuationTask {
            let replacesAnotherAccount = historyContinuationUserID != userID
            let expeditesRetry = delayNanoseconds == 0
                && (historyContinuationDelayNanoseconds ?? 0) > 0
            guard replacesAnotherAccount || expeditesRetry else { return }
            existing.cancel()
        }

        historyContinuationGeneration &+= 1
        let generation = historyContinuationGeneration
        historyContinuationUserID = userID
        historyContinuationDelayNanoseconds = delayNanoseconds
        historyContinuationTask = Task { [weak self] in
            do {
                if delayNanoseconds == 0 {
                    await Task.yield()
                } else {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                }
                try Task.checkCancellation()
            } catch {
                return
            }
            guard let self else { return }
            await self.runScheduledHistoryContinuation(
                forUserID: userID,
                generation: generation
            )
        }
    }

    private func cancelHistoryContinuation() {
        historyContinuationGeneration &+= 1
        historyContinuationTask?.cancel()
        historyContinuationTask = nil
        historyContinuationUserID = nil
        historyContinuationDelayNanoseconds = nil
    }

    private func runScheduledHistoryContinuation(
        forUserID userID: String,
        generation: UInt64
    ) async {
        guard historyContinuationGeneration == generation,
              historyContinuationUserID == userID
        else { return }
        if isFlushingHistory {
            // A foreground sync can enter the bounded drain while this continuation is sleeping.
            // Keep one delayed fallback until that in-flight drain either cancels it, expedites it
            // after progress, or fails; never spin actor jobs while its network awaits are pending.
            historyContinuationTask = nil
            historyContinuationUserID = nil
            historyContinuationDelayNanoseconds = nil
            scheduleHistoryContinuation(
                forUserID: userID,
                delayNanoseconds:
                    SecureMessagingHistoryContinuationPolicy.failureRetryNanoseconds
            )
            return
        }
        historyContinuationTask = nil
        historyContinuationUserID = nil
        historyContinuationDelayNanoseconds = nil
        do {
            try await flushHistoryBackfills(forUserID: userID)
        } catch is CancellationError {
            return
        } catch let error as SecureMessagingExchangeError where error == .invalidAccount {
            return
        } catch {
            let snapshot = await store.snapshot()
            let stillPending = snapshot.profile?.id == userID
                && snapshot.secureMessaging?.enrollment?.userID == userID
                && !(snapshot.secureMessaging?.historyBackfillTasks.isEmpty ?? true)
            reconcileHistoryContinuation(
                forUserID: userID,
                pending: stillPending,
                madeProgress: false
            )
        }
    }

    private func attemptHistoryBackfillTask(
        _ task: SecureMessagingHistoryBackfillTask,
        userID: String
    ) async throws -> Bool {
        do {
            let snapshot = await store.snapshot()
            guard snapshot.profile?.id == userID,
                  let enrollment = snapshot.secureMessaging?.enrollment,
                  enrollment.userID == userID
            else { throw SecureMessagingExchangeError.invalidAccount }
            let page = try await loadHistoryBackfillPage(
                task: task,
                userID: userID,
                enrollment: enrollment
            )
            for candidate in page.candidates {
                try Task.checkCancellation()
                let current = await store.snapshot()
                guard current.profile?.id == userID else {
                    throw SecureMessagingExchangeError.invalidAccount
                }
                guard let retained = try Self.validatedHistorySource(
                    candidate,
                    in: current,
                    currentUserID: userID
                ) else { continue }
                let outbound = try await prepareHistoryOutboundEnvelope(
                    task: task,
                    page: page,
                    candidate: candidate,
                    retained: retained,
                    userID: userID
                )
                try await storeHistoryOutboundEnvelope(
                    outbound,
                    task: task,
                    candidate: candidate
                )
            }
            try await advanceHistoryBackfillTask(
                task,
                nextCursor: page.nextCursor,
                hasMore: page.hasMore,
                completedMessageIDs: Set(page.candidates.map(\.identity.messageID)),
                userID: userID
            )
            return true
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SecureMessagingExchangeError where error == .invalidAccount {
            throw error
        } catch {
            let disposition = Self.historyAttemptDisposition(for: error, task: task)
            switch disposition {
            case .retryLater:
                return false
            case .restartFromFirstPage, .complete:
                try await resolveHistoryBackfillTask(
                    task,
                    disposition: disposition,
                    userID: userID
                )
                return true
            }
        }
    }

    nonisolated static func historyAttemptDisposition(
        for error: Error,
        task: SecureMessagingHistoryBackfillTask
    ) -> SecureMessagingHistoryAttemptDisposition {
        guard let payload = error as? APIErrorPayload else { return .retryLater }
        if [
            "MESSAGING_HISTORY_TARGET_INVALID",
            "MESSAGING_HISTORY_TARGET_STALE",
        ].contains(payload.code) {
            return .complete
        }
        if payload.code == "MESSAGING_HISTORY_CURSOR_INVALID", task.nextCursor != nil {
            return .restartFromFirstPage
        }
        return .retryLater
    }

    private func resolveHistoryBackfillTask(
        _ task: SecureMessagingHistoryBackfillTask,
        disposition: SecureMessagingHistoryAttemptDisposition,
        userID: String
    ) async throws {
        for _ in 0..<3 {
            let snapshot = await store.snapshot()
            guard snapshot.profile?.id == userID,
                  let initial = snapshot.secureMessaging,
                  initial.enrollment?.userID == userID
            else { throw SecureMessagingExchangeError.invalidAccount }
            guard initial.historyBackfillTasks.contains(task) else { return }
            let next = try Self.historyStateByResolvingTask(
                initial,
                task: task,
                disposition: disposition
            )
            if next == initial { return }
            do {
                try await store.commitSecureMessaging(
                    forUserID: userID,
                    expectedState: initial,
                    nextState: next
                )
                return
            } catch SecureMessagingCryptoError.staleState {
                continue
            }
        }
        throw SecureMessagingExchangeError.retryLimitExceeded
    }

    nonisolated static func historyStateByResolvingTask(
        _ initial: SecureMessagingPersistentState,
        task: SecureMessagingHistoryBackfillTask,
        disposition: SecureMessagingHistoryAttemptDisposition
    ) throws -> SecureMessagingPersistentState {
        guard SecureMessagingValidation.isCanonicalUUID(task.conversationID),
              SecureMessagingValidation.isCanonicalUUID(task.targetDeviceID),
              task.targetEnrollmentEpoch > 0,
              task.nextCursor.map(validHistoryCursor) ?? true,
              initial.historyBackfillTasks.filter({ $0 == task }).count == 1
        else { throw SecureMessagingCryptoError.invalidContent }
        var next = initial
        switch disposition {
        case .retryLater:
            return initial
        case .restartFromFirstPage:
            guard let index = next.historyBackfillTasks.firstIndex(of: task),
                  task.nextCursor != nil
            else { return initial }
            next.historyBackfillTasks[index].nextCursor = nil
        case .complete:
            next.historyBackfillTasks.removeAll { $0 == task }
            next.historyOutboundEnvelopes = next.historyOutboundEnvelopes.filter { _, outbound in
                outbound.fanout.conversationID != task.conversationID
                    || outbound.targetDeviceID != task.targetDeviceID
                    || outbound.targetEnrollmentEpoch != task.targetEnrollmentEpoch
            }
        }
        return next
    }

    private func reconcileHistoryBackfillTargetsIfNeeded(
        forUserID userID: String
    ) async throws {
        let snapshot = await store.snapshot()
        guard snapshot.profile?.id == userID,
              let initial = snapshot.secureMessaging,
              let enrollment = initial.enrollment,
              enrollment.userID == userID
        else { throw SecureMessagingExchangeError.invalidAccount }
        if historyReconciledEnrollment == enrollment { return }

        let response = try await transport.messagingConversations()
        guard let rawItems = response.items,
              rawItems.count <= 10_000,
              rawItems.allSatisfy({ $0 != nil })
        else { throw SecureMessagingExchangeError.invalidServerResponse }
        var seenConversationIDs: Set<String> = []
        var conversations: [ValidatedDirectConversation] = []
        for raw in rawItems {
            guard let dto = raw,
                  let type = dto.type,
                  let rawID = dto.id
            else { throw SecureMessagingExchangeError.invalidServerResponse }
            let conversationID = try canonicalUUID(
                rawID,
                error: .invalidServerResponse
            )
            guard seenConversationIDs.insert(conversationID).inserted else {
                throw SecureMessagingExchangeError.invalidServerResponse
            }
            // Direct and group threads are protocol-known; anything else is skipped silently so
            // a server-side conversation-type rollout cannot break same-account history repair.
            guard type == SecureMessagingWire.directConversationType
                    || type == SecureMessagingWire.groupConversationType
            else { continue }
            conversations.append(try validateConversation(
                dto,
                currentUserID: userID,
                expectedRecipientUserID: nil,
                fallbackTitle: "Kit Pay contact"
            ))
        }

        var targets: [SecureMessagingHistoryBackfillTarget] = []
        for conversation in conversations {
            try Task.checkCancellation()
            let rosterDTO = try await transport.messagingDeviceRoster(
                conversationId: conversation.id
            )
            let roster = try SecureMessagingMapper.roster(
                from: rosterDTO,
                use: .current,
                expectedConversationID: conversation.id,
                currentDeviceID: enrollment.serverDeviceID,
                currentUserID: userID,
                expectedMemberUserIDs: conversation.memberUserIDs
            )
            targets.append(contentsOf: try Self.historyBackfillTargets(
                in: roster,
                currentUserID: userID,
                currentDeviceID: enrollment.serverDeviceID
            ))
        }

        let activeConversationIDs = Set(conversations.map(\.id))
        for _ in 0..<3 {
            let current = await store.snapshot()
            guard current.profile?.id == userID,
                  let currentCrypto = current.secureMessaging,
                  currentCrypto.enrollment == enrollment
            else { throw SecureMessagingExchangeError.invalidAccount }
            let next = try Self.historyStateByReconcilingCurrentTargets(
                currentCrypto,
                activeConversationIDs: activeConversationIDs,
                targets: targets,
                currentDeviceID: enrollment.serverDeviceID
            )
            if next == currentCrypto {
                historyReconciledEnrollment = enrollment
                return
            }
            do {
                try await store.commitSecureMessaging(
                    forUserID: userID,
                    expectedState: currentCrypto,
                    nextState: next
                )
                historyReconciledEnrollment = enrollment
                return
            } catch SecureMessagingCryptoError.staleState {
                continue
            }
        }
        throw SecureMessagingExchangeError.retryLimitExceeded
    }

    nonisolated static func historyBackfillTargets(
        in roster: SecureMessagingRosterSnapshot,
        currentUserID: String,
        currentDeviceID: String
    ) throws -> [SecureMessagingHistoryBackfillTarget] {
        guard roster.use == .current,
              SecureMessagingValidation.isCanonicalUUID(roster.conversationID),
              SecureMessagingValidation.isCanonicalUUID(currentUserID),
              SecureMessagingValidation.isCanonicalUUID(currentDeviceID),
              roster.devices.filter({
                  $0.address.serverDeviceID == currentDeviceID
                      && $0.address.userID == currentUserID
              }).count == 1
        else { throw SecureMessagingCryptoError.staleRoster }
        let targets = try roster.devices.compactMap {
            device -> SecureMessagingHistoryBackfillTarget? in
            guard device.address.userID == currentUserID,
                  device.address.serverDeviceID != currentDeviceID
            else { return nil }
            guard let epoch = roster.frozenDevice(
                device.address.serverDeviceID
            )?.enrollmentEpoch, epoch > 0 else {
                throw SecureMessagingCryptoError.staleRoster
            }
            return SecureMessagingHistoryBackfillTarget(
                conversationID: roster.conversationID,
                deviceID: device.address.serverDeviceID,
                enrollmentEpoch: epoch
            )
        }
        guard Set(targets.map(\.key)).count == targets.count else {
            throw SecureMessagingCryptoError.staleRoster
        }
        return targets
    }

    nonisolated static func historyStateByReconcilingCurrentTargets(
        _ initial: SecureMessagingPersistentState,
        activeConversationIDs: Set<String>,
        targets: [SecureMessagingHistoryBackfillTarget],
        currentDeviceID: String
    ) throws -> SecureMessagingPersistentState {
        guard activeConversationIDs.count <= 10_000,
              activeConversationIDs.allSatisfy(SecureMessagingValidation.isCanonicalUUID),
              targets.count <= 10_000,
              SecureMessagingValidation.isCanonicalUUID(currentDeviceID),
              targets.allSatisfy({
                  activeConversationIDs.contains($0.conversationID)
                      && SecureMessagingValidation.isCanonicalUUID($0.deviceID)
                      && $0.deviceID != currentDeviceID
                      && $0.enrollmentEpoch > 0
              }),
              Set(targets.map(\.key)).count == targets.count
        else { throw SecureMessagingCryptoError.invalidContent }

        let targetsByKey = Dictionary(uniqueKeysWithValues: targets.map { ($0.key, $0) })
        var seenTaskKeys: Set<String> = []
        var tasks = initial.historyBackfillTasks.filter { task in
            let target = targetsByKey["\(task.conversationID):\(task.targetDeviceID)"]
            return target?.enrollmentEpoch == task.targetEnrollmentEpoch
                && seenTaskKeys.insert(task.key).inserted
        }
        for target in targets.sorted(by: {
            $0.conversationID == $1.conversationID
                ? $0.deviceID < $1.deviceID
                : $0.conversationID < $1.conversationID
        }) where !seenTaskKeys.contains(
            "\(target.conversationID):\(target.deviceID):\(target.enrollmentEpoch)"
        ) {
            let task = SecureMessagingHistoryBackfillTask(
                conversationID: target.conversationID,
                targetDeviceID: target.deviceID,
                targetEnrollmentEpoch: target.enrollmentEpoch,
                nextCursor: nil
            )
            tasks.append(task)
            seenTaskKeys.insert(task.key)
        }
        guard tasks.count <= 10_000 else {
            throw SecureMessagingCryptoError.recordLimitExceeded
        }

        var next = initial
        next.historyBackfillTasks = tasks
        next.historyOutboundEnvelopes = next.historyOutboundEnvelopes.filter { _, outbound in
            seenTaskKeys.contains(
                "\(outbound.fanout.conversationID):\(outbound.targetDeviceID):"
                    + "\(outbound.targetEnrollmentEpoch)"
            )
        }
        return next
    }

    private func loadHistoricalRoster(
        revision: String,
        conversation: ValidatedDirectConversation,
        enrollment: SecureMessagingEnrollmentBinding,
        allowMissingCurrentDevice: Bool
    ) async throws -> SecureMessagingRosterSnapshot {
        guard SecureMessagingValidation.isRosterRevision(revision) else {
            throw SecureMessagingCryptoError.invalidContent
        }
        let dto = try await transport.historicalMessagingDeviceRoster(
            conversationId: conversation.id,
            rosterRevision: revision
        )
        return try SecureMessagingMapper.roster(
            from: dto,
            use: .historical,
            expectedConversationID: conversation.id,
            currentDeviceID: enrollment.serverDeviceID,
            currentUserID: enrollment.userID,
            expectedMemberUserIDs: conversation.memberUserIDs,
            allowHistoricalGroupMembershipChurn: conversation.isGroup,
            allowMissingCurrentDeviceInHistoricalRoster: allowMissingCurrentDevice
        )
    }

    private func loadHistoryBackfillPage(
        task: SecureMessagingHistoryBackfillTask,
        userID: String,
        enrollment: SecureMessagingEnrollmentBinding
    ) async throws -> ValidatedHistoryBackfillPage {
        guard SecureMessagingValidation.isCanonicalUUID(task.conversationID),
              SecureMessagingValidation.isCanonicalUUID(task.targetDeviceID),
              task.targetDeviceID != enrollment.serverDeviceID,
              task.targetEnrollmentEpoch > 0,
              task.nextCursor.map(Self.validHistoryCursor) ?? true
        else { throw SecureMessagingCryptoError.invalidContent }
        let conversation = try await loadConversation(
            id: task.conversationID,
            currentUserID: userID
        )
        let rosterDTO = try await transport.messagingDeviceRoster(
            conversationId: conversation.id
        )
        let roster = try SecureMessagingMapper.roster(
            from: rosterDTO,
            use: .current,
            expectedConversationID: conversation.id,
            currentDeviceID: enrollment.serverDeviceID,
            currentUserID: userID,
            expectedMemberUserIDs: conversation.memberUserIDs
        )
        guard let target = roster.devices.first(where: {
            $0.address.serverDeviceID == task.targetDeviceID
        }),
              target.address.userID == userID,
              roster.frozenDevice(task.targetDeviceID)?.enrollmentEpoch
                == task.targetEnrollmentEpoch,
              let targetFrozen = roster.frozenDevice(task.targetDeviceID)
        else { throw SecureMessagingCryptoError.staleRoster }

        let limit = SecureMessagingWire.maximumHistoryPage
        let response = try await transport.messagingHistoryBackfillCandidates(
            conversationId: conversation.id,
            targetDeviceId: task.targetDeviceID,
            targetEnrollmentEpoch: task.targetEnrollmentEpoch,
            cursor: task.nextCursor,
            limit: limit
        )
        guard response.conversationId == conversation.id,
              response.rosterRevision == roster.rosterRevision,
              let bundle = response.targetCryptoBundle,
              bundle.deviceId == task.targetDeviceID,
              bundle.userId == userID,
              bundle.enrollmentEpoch == task.targetEnrollmentEpoch,
              bundle.signalDeviceId == Int(target.address.signalDeviceID),
              bundle.registrationId == Int(target.registrationID),
              bundle.protocolVersion == SecureMessagingWire.protocolVersion,
              bundle.bundleVersion == targetFrozen.bundleVersion,
              bundle.identityKeySha256 == target.identityKeySHA256,
              let rawMessages = response.messages,
              rawMessages.count <= limit,
              rawMessages.allSatisfy({ $0 != nil }),
              let cursorPage = response.page,
              cursorPage.limit == limit,
              let hasMore = cursorPage.hasMore,
              cursorPage.nextCursor.map(Self.validHistoryCursor) ?? true,
              !hasMore || cursorPage.nextCursor != nil,
              !hasMore || cursorPage.nextCursor != task.nextCursor
        else { throw SecureMessagingExchangeError.invalidServerResponse }

        var seen: Set<String> = []
        var originalRostersByRevision: [String: SecureMessagingRosterSnapshot] = [:]
        var candidates: [ValidatedHistoryCandidate] = []
        for rawValue in rawMessages {
            try Task.checkCancellation()
            guard let raw = rawValue, let rawSentAt = raw.sentAt else {
                throw SecureMessagingExchangeError.invalidServerResponse
            }
            let identity = try SecureMessagingMapper.historyCandidateIdentity(
                from: raw,
                expectedConversationID: conversation.id
            )
            guard seen.insert(identity.messageID).inserted else {
                throw SecureMessagingExchangeError.invalidServerResponse
            }
            let originalRoster: SecureMessagingRosterSnapshot
            if let cached = originalRostersByRevision[identity.rosterRevision] {
                originalRoster = cached
            } else {
                let loaded = try await loadHistoricalRoster(
                    revision: identity.rosterRevision,
                    conversation: conversation,
                    enrollment: enrollment,
                    allowMissingCurrentDevice: true
                )
                originalRostersByRevision[identity.rosterRevision] = loaded
                originalRoster = loaded
            }
            let validatedSender = try SecureMessagingMapper.validatedHistoricalSender(
                from: raw,
                identity: identity,
                roster: originalRoster
            )
            candidates.append(ValidatedHistoryCandidate(
                dto: raw,
                identity: identity,
                validatedSender: validatedSender,
                rawSentAt: rawSentAt
            ))
        }
        return ValidatedHistoryBackfillPage(
            conversation: conversation,
            roster: roster,
            target: target,
            candidates: candidates,
            nextCursor: cursorPage.nextCursor,
            hasMore: hasMore
        )
    }

    private nonisolated static func validatedHistorySource(
        _ candidate: ValidatedHistoryCandidate,
        in snapshot: PersistedState,
        currentUserID: String
    ) throws -> LocalMessage? {
        let matches = snapshot.messages.filter {
            $0.serverMessageId == candidate.identity.messageID
        }
        guard matches.count <= 1 else { throw SecureMessagingCryptoError.invalidContent }
        guard let retained = matches.first else { return nil }
        // A family-unparseable body is a placeholder row, never donatable evidence: omit the
        // candidate (nil skips it at every call site) instead of failing validation. Placeholder
        // projections already carry no history metadata, but this must hold even for a corrupt
        // or migrated row that somehow does — a throw here is mapped to `.retryLater` by
        // `historyAttemptDisposition`, so one such body would otherwise pin its backfill task
        // to the same page forever.
        if KitMediaMessageFamilyPolicy.isReservedFamilyText(retained.body),
           KitMediaMessageDescriptor.parse(retained.body) == nil,
           KitMediaMessageV2Descriptor.parse(retained.body) == nil {
            return nil
        }
        guard let metadata = retained.secureMessagingHistory else { return nil }
        let expectedAttachments = KitMediaMessageFamilyPolicy.attachmentRequests(
            for: retained.body
        )
        guard SecureMessagingMapper.retainedMetadataMatches(
                  metadata,
                  identity: candidate.identity,
                  validatedSender: candidate.validatedSender
              ),
              retained.conversationId == candidate.identity.conversationID,
              retained.senderId == candidate.identity.senderUserID,
              retained.isOutgoing == (candidate.identity.senderUserID == currentUserID),
              let sentAt = retained.sentAt,
              SecureMessagingHistoryBackfillCodec.sameMillisecond(
                  sentAt,
                  candidate.identity.sentAt
              ),
              SecureMessagingContentBindingPolicy.kind(
                  for: retained.body,
                  replyToMessageID: candidate.identity.replyToMessageID,
                  attachments: expectedAttachments
              ) == candidate.identity.kind,
              KitMediaMessageFamilyPolicy.validatesWireRows(
                  candidate.dto.attachments,
                  forBody: retained.body
              )
        else { throw SecureMessagingCryptoError.invalidContent }
        return retained
    }

    private func prepareHistoryOutboundEnvelope(
        task: SecureMessagingHistoryBackfillTask,
        page: ValidatedHistoryBackfillPage,
        candidate: ValidatedHistoryCandidate,
        retained: LocalMessage,
        userID: String
    ) async throws -> SecureMessagingHistoryOutboundEnvelope {
        for _ in 0..<3 {
            try Task.checkCancellation()
            let snapshot = await store.snapshot()
            guard snapshot.profile?.id == userID,
                  let initialCrypto = snapshot.secureMessaging,
                  let enrollment = initialCrypto.enrollment,
                  enrollment.userID == userID,
                  initialCrypto.historyBackfillTasks.contains(where: {
                      $0 == task
                  })
            else { throw SecureMessagingExchangeError.invalidAccount }
            guard let currentRetained = try Self.validatedHistorySource(
                candidate,
                in: snapshot,
                currentUserID: userID
            ), currentRetained == retained else {
                throw SecureMessagingCryptoError.invalidContent
            }
            let transferID = try SecureMessagingHistoryBackfillCodec.deterministicTransferID(
                messageID: candidate.identity.messageID,
                targetDeviceID: task.targetDeviceID,
                targetEnrollmentEpoch: task.targetEnrollmentEpoch,
                donorDeviceID: enrollment.serverDeviceID,
                donorEnrollmentEpoch: enrollment.enrollmentEpoch,
                transferRosterRevision: page.roster.rosterRevision
            )
            if let existing = initialCrypto.historyOutboundEnvelopes[transferID] {
                try validateHistoryOutboundEnvelope(
                    existing,
                    transferID: transferID,
                    task: task,
                    page: page,
                    candidate: candidate
                )
                return existing
            }
            guard initialCrypto.historyOutboundEnvelopes.count < 10_000 else {
                throw SecureMessagingCryptoError.recordLimitExceeded
            }
            // Upgrade legacy in-memory metadata only for descriptor validation. The stored
            // record remains untouched; `validatedHistorySource` already bound its omitted
            // sender to the original historical roster through `candidate.validatedSender`.
            var retainedForEncoding = currentRetained
            retainedForEncoding.secureMessagingHistory = candidate.identity.retainedMetadata
            let descriptor = try SecureMessagingHistoryBackfillCodec.encode(
                transferClientMessageID: transferID,
                targetDeviceID: task.targetDeviceID,
                targetEnrollmentEpoch: task.targetEnrollmentEpoch,
                transferRosterRevision: page.roster.rosterRevision,
                candidate: candidate.identity,
                rawSentAt: candidate.rawSentAt,
                retained: retainedForEncoding
            )
            var preparedCrypto = initialCrypto
            let missing = try await engine.recipientsRequiringSession(
                currentState: preparedCrypto,
                localSender: enrollment.address,
                recipients: [page.target]
            )
            if !missing.isEmpty {
                let requestedIDs = Set(missing.map(\.address.serverDeviceID))
                let consumed = try await transport.consumeMessagingKeyBundles(
                    conversationId: page.conversation.id,
                    request: try ConsumeMessagingKeyBundlesRequest(
                        deviceIds: requestedIDs.sorted()
                    )
                )
                let bundles = try SecureMessagingMapper.remoteBundles(
                    from: consumed,
                    roster: page.roster,
                    requestedRemoteDeviceIDs: requestedIDs,
                    localDeviceID: enrollment.serverDeviceID
                )
                preparedCrypto = try await engine.establishSessions(
                    currentState: preparedCrypto,
                    localSender: enrollment.address,
                    bundles: bundles
                )
            }
            let encrypted = try await engine.encryptText(
                currentState: preparedCrypto,
                sender: enrollment.address,
                conversationID: page.conversation.id,
                clientMessageID: transferID,
                rosterRevision: page.roster.rosterRevision,
                replyToMessageID: nil,
                text: descriptor,
                recipients: [page.target],
                maximumTextUnicodeScalars:
                    SecureMessagingHistoryBackfillCodec.maximumDescriptorUnicodeScalars
            )
            let outbound = SecureMessagingHistoryOutboundEnvelope(
                originalMessageID: candidate.identity.messageID,
                targetDeviceID: task.targetDeviceID,
                targetEnrollmentEpoch: task.targetEnrollmentEpoch,
                fanout: encrypted.fanout
            )
            try validateHistoryOutboundEnvelope(
                outbound,
                transferID: transferID,
                task: task,
                page: page,
                candidate: candidate
            )
            var nextCrypto = encrypted.state
            nextCrypto.cachedRosters[page.roster.rosterRevision] = page.roster
            nextCrypto.historyOutboundEnvelopes[transferID] = outbound
            do {
                try await store.commitSecureMessaging(
                    forUserID: userID,
                    expectedState: initialCrypto,
                    nextState: nextCrypto
                ) { state in
                    guard try Self.validatedHistorySource(
                        candidate,
                        in: state,
                        currentUserID: userID
                    ) == currentRetained else {
                        throw SecureMessagingCryptoError.invalidContent
                    }
                }
                return outbound
            } catch SecureMessagingCryptoError.staleState {
                continue
            }
        }
        throw SecureMessagingExchangeError.retryLimitExceeded
    }

    private func validateHistoryOutboundEnvelope(
        _ outbound: SecureMessagingHistoryOutboundEnvelope,
        transferID: String,
        task: SecureMessagingHistoryBackfillTask,
        page: ValidatedHistoryBackfillPage,
        candidate: ValidatedHistoryCandidate
    ) throws {
        let fanout = outbound.fanout
        guard outbound.originalMessageID == candidate.identity.messageID,
              outbound.targetDeviceID == task.targetDeviceID,
              outbound.targetEnrollmentEpoch == task.targetEnrollmentEpoch,
              fanout.clientMessageID == transferID,
              fanout.conversationID == task.conversationID,
              fanout.rosterRevision == page.roster.rosterRevision,
              fanout.replyToMessageID == nil,
              fanout.rosterDevices == [page.target],
              fanout.envelopes.count == 1,
              fanout.envelopes[0].recipientDeviceID == task.targetDeviceID
        else { throw SecureMessagingCryptoError.invalidContent }
    }

    private func storeHistoryOutboundEnvelope(
        _ outbound: SecureMessagingHistoryOutboundEnvelope,
        task: SecureMessagingHistoryBackfillTask,
        candidate: ValidatedHistoryCandidate
    ) async throws {
        guard let envelope = outbound.fanout.envelopes.first,
              outbound.fanout.envelopes.count == 1,
              let envelopeType = SecureMessagingEnvelopeType(rawValue: envelope.envelopeType)
        else { throw SecureMessagingCryptoError.invalidContent }
        let request = try StoreMessagingHistoryEnvelopeRequest(
            targetDeviceId: task.targetDeviceID,
            targetEnrollmentEpoch: task.targetEnrollmentEpoch,
            transferClientMessageId: outbound.fanout.clientMessageID,
            rosterRevision: outbound.fanout.rosterRevision,
            envelopeType: envelopeType,
            ciphertext: envelope.ciphertext.base64EncodedString()
        )
        let result = try await transport.storeMessagingHistoryEnvelope(
            conversationId: task.conversationID,
            messageId: candidate.identity.messageID,
            request: request
        )
        guard result.messageId == candidate.identity.messageID,
              result.targetDeviceId == task.targetDeviceID,
              result.targetEnrollmentEpoch == task.targetEnrollmentEpoch,
              result.transferClientMessageId == outbound.fanout.clientMessageID,
              result.created != nil
        else { throw SecureMessagingExchangeError.invalidServerResponse }
    }

    private func advanceHistoryBackfillTask(
        _ task: SecureMessagingHistoryBackfillTask,
        nextCursor: String?,
        hasMore: Bool,
        completedMessageIDs: Set<String>,
        userID: String
    ) async throws {
        guard !hasMore || nextCursor.map(Self.validHistoryCursor) == true,
              !hasMore || nextCursor != task.nextCursor,
              completedMessageIDs.allSatisfy(SecureMessagingValidation.isCanonicalUUID)
        else { throw SecureMessagingExchangeError.invalidServerResponse }
        for _ in 0..<3 {
            let snapshot = await store.snapshot()
            guard snapshot.profile?.id == userID,
                  let initialCrypto = snapshot.secureMessaging
            else { throw SecureMessagingExchangeError.invalidAccount }
            guard let index = initialCrypto.historyBackfillTasks.firstIndex(of: task) else {
                return
            }
            let nextCrypto = try Self.historyStateByAdvancingCommittedPage(
                initialCrypto,
                taskIndex: index,
                task: task,
                nextCursor: nextCursor,
                hasMore: hasMore,
                completedMessageIDs: completedMessageIDs
            )
            do {
                try await store.commitSecureMessaging(
                    forUserID: userID,
                    expectedState: initialCrypto,
                    nextState: nextCrypto
                )
                return
            } catch SecureMessagingCryptoError.staleState {
                continue
            }
        }
        throw SecureMessagingExchangeError.retryLimitExceeded
    }

    nonisolated static func historyStateByAdvancingCommittedPage(
        _ initial: SecureMessagingPersistentState,
        taskIndex: Int,
        task: SecureMessagingHistoryBackfillTask,
        nextCursor: String?,
        hasMore: Bool,
        completedMessageIDs: Set<String>
    ) throws -> SecureMessagingPersistentState {
        guard initial.historyBackfillTasks.indices.contains(taskIndex),
              initial.historyBackfillTasks[taskIndex] == task,
              initial.historyBackfillTasks.filter({ $0 == task }).count == 1,
              !hasMore || nextCursor.map(validHistoryCursor) == true,
              !hasMore || nextCursor != task.nextCursor,
              completedMessageIDs.allSatisfy(SecureMessagingValidation.isCanonicalUUID)
        else { throw SecureMessagingCryptoError.invalidContent }

        var next = initial
        if hasMore {
            next.historyBackfillTasks[taskIndex].nextCursor = nextCursor
        } else {
            next.historyBackfillTasks.remove(at: taskIndex)
        }
        // Ciphertext remains durable through every ambiguous HTTP result. It is retired in the
        // same store transaction that advances/removes the page task, eliminating the crash window
        // in which a replay could encrypt the deterministic transfer ID with different bytes. A
        // final page also retires any exact-task ciphertext stranded by an earlier cursor restart.
        next.historyOutboundEnvelopes = next.historyOutboundEnvelopes.filter { _, outbound in
            let belongsToTask = outbound.fanout.conversationID == task.conversationID
                && outbound.targetDeviceID == task.targetDeviceID
                && outbound.targetEnrollmentEpoch == task.targetEnrollmentEpoch
            guard belongsToTask else { return true }
            return hasMore && !completedMessageIDs.contains(outbound.originalMessageID)
        }
        return next
    }

    private func discardCurrentDeviceHistoryWork(
        forUserID userID: String,
        currentDeviceID: String
    ) async throws {
        for _ in 0..<3 {
            let snapshot = await store.snapshot()
            guard snapshot.profile?.id == userID,
                  let initialCrypto = snapshot.secureMessaging,
                  initialCrypto.enrollment?.userID == userID,
                  initialCrypto.enrollment?.serverDeviceID == currentDeviceID
            else { throw SecureMessagingExchangeError.invalidAccount }
            let nextCrypto = Self.historyStateDiscardingCurrentDeviceWork(
                initialCrypto,
                currentDeviceID: currentDeviceID
            )
            guard nextCrypto != initialCrypto else { return }
            do {
                try await store.commitSecureMessaging(
                    forUserID: userID,
                    expectedState: initialCrypto,
                    nextState: nextCrypto
                )
                return
            } catch SecureMessagingCryptoError.staleState {
                continue
            }
        }
        throw SecureMessagingExchangeError.retryLimitExceeded
    }

    nonisolated static func historyStateDiscardingCurrentDeviceWork(
        _ initial: SecureMessagingPersistentState,
        currentDeviceID: String
    ) -> SecureMessagingPersistentState {
        guard SecureMessagingValidation.isCanonicalUUID(currentDeviceID) else { return initial }
        var next = initial
        next.historyBackfillTasks.removeAll { $0.targetDeviceID == currentDeviceID }
        next.historyOutboundEnvelopes = next.historyOutboundEnvelopes.filter { _, outbound in
            outbound.targetDeviceID != currentDeviceID
        }
        return next
    }

    nonisolated static func historyDescriptorDisposition(
        _ descriptor: String,
        incoming: SecureMessagingHistoryInboundEnvelope
    ) throws -> SecureMessagingHistoryDescriptorDisposition {
        do {
            let authenticated = try SecureMessagingHistoryBackfillCodec.authenticate(
                descriptor,
                incoming: incoming
            )
            guard !SecureMessageReservedPrefixPolicy.beginsWithReservedPrefix(
                authenticated.text,
                prefix: KitSystemMessage.prefix
            ) else {
                return .suppressed(acknowledgementMessageID: incoming.original.messageID)
            }
            return .authenticated(authenticated)
        } catch let error as SecureMessagingCryptoError where error == .invalidContent {
            return .suppressed(acknowledgementMessageID: incoming.original.messageID)
        } catch let error as SecureMessagingCryptoError {
            throw error
        } catch {
            // Foundation's JSON parser reports malformed escape sequences as Cocoa errors. The
            // Signal wrapper is already authenticated/decrypted at this boundary, so normalize
            // parser-shape failures to the same suppress-and-acknowledge disposition.
            return .suppressed(acknowledgementMessageID: incoming.original.messageID)
        }
    }

    /// Builds a visible projection only after the decrypted body agrees with the authenticated
    /// outer kind/attachment list. `nil` is a message-local suppression decision: the caller must
    /// still commit the Signal state and acknowledge the server envelope.
    nonisolated static func projectedInboundMessage(
        dto: EncryptedMessageDTO,
        envelope: SecureMessagingInboundEnvelope,
        plaintext: String,
        sentAt: Date,
        currentUserID: String
    ) throws -> LocalMessage? {
        guard dto.id == envelope.messageID,
              dto.conversationId == envelope.conversationID,
              dto.clientMessageId == envelope.clientMessageID,
              let senderEnrollmentEpoch = dto.senderEnrollmentEpoch,
              senderEnrollmentEpoch > 0,
              SecureMessagingValidation.isCanonicalUUID(envelope.messageID),
              SecureMessagingValidation.isCanonicalUUID(envelope.conversationID),
              SecureMessagingValidation.isCanonicalUUID(envelope.sender.address.userID),
              SecureMessagingValidation.isCanonicalUUID(currentUserID),
              let messageID = UUID(uuidString: envelope.messageID)
        else { throw SecureMessagingCryptoError.invalidContent }

        // §4 rule 6, receive confinement: a v2-family body that fails the strict parse — an
        // unknown future version included — is authenticated peer content this build cannot
        // confine as media, and must not render as text either (the raw body is a
        // maybe-descriptor, possibly carrying key material). It lands as ONE visible
        // generic-placeholder row: the raw body persists for a future build that can parse
        // it, every presentation/copy/search/forward/report surface renders it only through
        // the family-safe "Attachment" placeholder, and it carries no history metadata — a
        // body that binds to no kind is not donatable, not restorable, and never quotable
        // evidence. Reactions and edits keep their strict handling: an annotation kind never
        // becomes a placeholder bubble.
        //
        // Malformed vector 12 takes the same exit: a descriptor that parses cleanly but whose
        // authenticated outer rows do not set-match it — or whose declared kind does not
        // bind — is rejected as media yet still shows the one generic placeholder, never a
        // usable v2 bubble. Its persisted body is the canonical empty-descriptor spelling
        // rather than the raw text: the outer rows are consumed at receive, so no future
        // build could ever re-validate the pairing, and a raw valid-parse body would read as
        // a working v2 message to every body-driven surface while carrying key material the
        // server never tied to this message. The strictly-unparseable spelling routes the row
        // through the identical family-confined placeholder machinery everywhere. Both legs
        // are flag-independent; a v2 body that completes binding and row set-match continues
        // below into ordered-media rendering through the ordinary kind binding.
        let strictV2 = KitMediaMessageV2Descriptor.parse(plaintext)
        if strictV2 != nil
            || KitMediaMessageFamilyPolicy.requiresGenericAttachmentPlaceholder(plaintext) {
            guard let rawKind = dto.kind,
                  let kind = SecureMessagingMessageKind(rawValue: rawKind),
                  !kind.isTimelineMetadata
            else { return nil }
            let completesMediaBinding = strictV2 != nil
                && SecureMessagingContentBindingPolicy.kind(
                    for: plaintext,
                    replyToMessageID: envelope.replyToMessageID,
                    attachments: KitMediaMessageFamilyPolicy.attachmentRequests(for: plaintext)
                ) == kind
                && KitMediaMessageFamilyPolicy.validatesWireRows(
                    dto.attachments,
                    forBody: plaintext
                )
            if !completesMediaBinding {
                let authoredOnCurrentAccount = envelope.sender.address.userID == currentUserID
                return LocalMessage(
                    id: messageID,
                    serverMessageId: envelope.messageID,
                    conversationId: envelope.conversationID,
                    senderId: envelope.sender.address.userID,
                    body: strictV2 == nil
                        ? plaintext
                        : KitMediaMessageFamilyPolicy.confinedPlaceholderBody,
                    createdAt: sentAt,
                    sentAt: sentAt,
                    state: authoredOnCurrentAccount ? .sent : .received,
                    failureReason: nil,
                    isOutgoing: authoredOnCurrentAccount,
                    secureMessagingHistory: nil,
                    replyToServerMessageID: nil
                )
            }
        }
        let attachments = KitMediaMessageFamilyPolicy.attachmentRequests(for: plaintext)
        guard let rawKind = dto.kind,
              let kind = SecureMessagingMessageKind(rawValue: rawKind),
              SecureMessagingContentBindingPolicy.kind(
                  for: plaintext,
                  replyToMessageID: envelope.replyToMessageID,
                  attachments: attachments
              ) == kind,
              // Lifecycle notices are server-authored local projections. No encrypted
              // user-authored payload may enter their trusted display namespace.
              !SecureMessageReservedPrefixPolicy.beginsWithReservedPrefix(
                  plaintext,
                  prefix: KitSystemMessage.prefix
              ),
              KitMediaMessageFamilyPolicy.validatesWireRows(dto.attachments, forBody: plaintext)
        else { return nil }

        let authoredOnCurrentAccount = envelope.sender.address.userID == currentUserID
        return LocalMessage(
            id: messageID,
            serverMessageId: envelope.messageID,
            conversationId: envelope.conversationID,
            senderId: envelope.sender.address.userID,
            body: plaintext,
            createdAt: sentAt,
            sentAt: sentAt,
            state: authoredOnCurrentAccount ? .sent : .received,
            failureReason: nil,
            isOutgoing: authoredOnCurrentAccount,
            secureMessagingHistory: SecureMessagingRetainedMessageMetadata(
                clientMessageID: envelope.clientMessageID,
                senderUserID: envelope.sender.address.userID,
                senderDeviceID: envelope.sender.address.serverDeviceID,
                senderEnrollmentEpoch: senderEnrollmentEpoch,
                senderSignalDeviceID: envelope.sender.address.signalDeviceID,
                rosterRevision: envelope.rosterRevision,
                kind: kind,
                replyToMessageID: envelope.replyToMessageID
            ),
            // A reaction points at a target too, and so does a correction, but neither is an
            // answer to it and neither draws a quote. Only ordinary messages carry the pointer
            // into the visible projection.
            replyToServerMessageID: kind.isTimelineMetadata
                ? nil
                : envelope.replyToMessageID?.lowercased()
        )
    }

    nonisolated static func reconcileRecoveredHistoryMessages(
        _ recovered: [LocalMessage],
        currentDeviceID: String,
        into state: inout PersistedState
    ) {
        guard SecureMessagingValidation.isCanonicalUUID(currentDeviceID) else { return }
        for message in recovered {
            guard let historyMetadata = message.secureMessagingHistory,
                  historyMetadata.senderUserID == message.senderId
            else { continue }
            let serverMatches = state.messages.indices.filter {
                state.messages[$0].serverMessageId == message.serverMessageId
            }
            guard serverMatches.count <= 1 else { continue }
            if let index = serverMatches.first {
                guard state.messages[index].conversationId == message.conversationId,
                      state.messages[index].senderId == message.senderId,
                      state.messages[index].body == message.body,
                      state.messages[index].isOutgoing == message.isOutgoing,
                      SecureMessagingHistoryBackfillCodec.sameMillisecond(
                          state.messages[index].sentAt ?? state.messages[index].createdAt,
                          message.sentAt ?? message.createdAt
                      ),
                      Self.recoveredHistoryMetadataIsCompatible(
                          state.messages[index].secureMessagingHistory,
                          authenticated: historyMetadata,
                          senderUserID: message.senderId
                      )
                else { continue }
                state.messages[index].secureMessagingHistory = historyMetadata
                continue
            }

            let clientMatches = state.messages.indices.filter {
                state.messages[$0].id == message.id
            }
            if message.isOutgoing,
               historyMetadata.senderDeviceID == currentDeviceID,
               historyMetadata.clientMessageID == message.id.uuidString.lowercased(),
               clientMatches.count == 1,
               let index = clientMatches.first {
                guard state.messages[index].serverMessageId == nil,
                      state.messages[index].conversationId == message.conversationId,
                      state.messages[index].senderId == message.senderId,
                      state.messages[index].body == message.body,
                      state.messages[index].isOutgoing,
                      state.messages[index].sentAt.map({
                          SecureMessagingHistoryBackfillCodec.sameMillisecond(
                              $0,
                              message.sentAt ?? message.createdAt
                          )
                      }) ?? true,
                      Self.recoveredHistoryMetadataIsCompatible(
                          state.messages[index].secureMessagingHistory,
                          authenticated: historyMetadata,
                          senderUserID: message.senderId
                      )
                else { continue }
                state.messages[index].serverMessageId = message.serverMessageId
                state.messages[index].sentAt = message.sentAt
                if state.messages[index].state != .read,
                   state.messages[index].state != .delivered {
                    state.messages[index].state = .sent
                }
                state.messages[index].failureReason = nil
                state.messages[index].secureMessagingHistory = historyMetadata
                state.outbox.removeAll {
                    $0.kind == .secureMessage
                        && $0.conversationId == message.conversationId
                        && ($0.messageId == message.id
                            || $0.secureMessageFanout?.clientMessageID
                                == message.id.uuidString.lowercased())
                }
                if !historyMetadata.kind.isTimelineMetadata,
                   let conversationIndex = state.conversations.firstIndex(where: {
                       $0.id == message.conversationId
                   }) {
                    state.conversations[conversationIndex].updatedAt = max(
                        state.conversations[conversationIndex].updatedAt,
                        message.createdAt
                    )
                }
                continue
            }

            guard clientMatches.isEmpty else { continue }
            state.messages.append(message)
            if !historyMetadata.kind.isTimelineMetadata,
               let index = state.conversations.firstIndex(where: {
                   $0.id == message.conversationId
               }) {
                state.conversations[index].updatedAt = max(
                    state.conversations[index].updatedAt,
                    message.createdAt
                )
            }
        }
    }

    /// `authenticated` is produced only after the receiver has bound the original sender to its
    /// historical roster. A stored pre-field metadata record may omit that sender, but every
    /// legacy field must still match and an explicitly persisted sender may never be replaced.
    nonisolated static func recoveredHistoryMetadataIsCompatible(
        _ stored: SecureMessagingRetainedMessageMetadata?,
        authenticated: SecureMessagingRetainedMessageMetadata,
        senderUserID: String
    ) -> Bool {
        guard SecureMessagingValidation.isCanonicalUUID(senderUserID),
              authenticated.senderUserID == senderUserID
        else { return false }
        guard let stored else { return true }
        return stored.clientMessageID == authenticated.clientMessageID
            && (stored.senderUserID == nil || stored.senderUserID == senderUserID)
            && stored.senderDeviceID == authenticated.senderDeviceID
            && stored.senderEnrollmentEpoch == authenticated.senderEnrollmentEpoch
            && stored.senderSignalDeviceID == authenticated.senderSignalDeviceID
            && stored.rosterRevision == authenticated.rosterRevision
            && stored.kind == authenticated.kind
            && stored.replyToMessageID == authenticated.replyToMessageID
    }

    private nonisolated static func validHistoryCursor(_ cursor: String) -> Bool {
        !cursor.isEmpty
            && cursor.utf8.count <= 2_048
            && cursor.utf8.allSatisfy {
                (48...57).contains($0)
                    || (65...90).contains($0)
                    || (97...122).contains($0)
                    || $0 == 45 || $0 == 46 || $0 == 95
            }
    }

    nonisolated static func validateSyncPage(
        _ response: MessagingSyncDTO,
        after cursor: String?
    ) throws -> (events: [MessagingSyncEventDTO], nextCursor: String, hasMore: Bool) {
        guard let rawEvents = response.events,
              rawEvents.allSatisfy({ $0 != nil }),
              let page = response.page,
              let hasMore = page.hasMore,
              page.limit.map({ (1...SecureMessagingWire.maximumSyncPage).contains($0) })
                ?? true,
              let nextCursor = page.nextCursor,
              !nextCursor.isEmpty,
              nextCursor.count <= 2_048,
              nextCursor != cursor || (rawEvents.isEmpty && !hasMore)
        else { throw SecureMessagingExchangeError.invalidServerResponse }
        return (rawEvents.compactMap { $0 }, nextCursor, hasMore)
    }

    private func applySyncPage(
        _ events: [MessagingSyncEventDTO],
        nextCursor: String,
        forUserID userID: String
    ) async throws -> SecureMessagingSyncResult {
        for _ in 0..<3 {
            let snapshot = await store.snapshot()
            guard snapshot.profile?.id == userID,
                  let initialCrypto = snapshot.secureMessaging,
                  let enrollment = initialCrypto.enrollment,
                  enrollment.userID == userID
            else { throw SecureMessagingExchangeError.invalidAccount }

            var crypto = initialCrypto
            var conversations: [Conversation] = []
            var incomingMessages: [LocalMessage] = []
            var recoveredHistoryMessages: [LocalMessage] = []
            var outboundEchoes: [OutboundEcho] = []
            var deliveryTransitions: [DeliveryTransition] = []
            var readTransitions: [ReadTransition] = []
            var groupMemberTransitions: [GroupMemberTransition] = []
            var groupPaymentRequestTransitions: [GroupPaymentRequestSyncTransition] = []
            var groupPaymentRequestAuthority: [String: GroupPaymentRequestDTO] = [:]
            var groupPaymentRequestContributionAuthority:
                [String: GroupPaymentRequestContributionDTO] = [:]
            var scheduledPaymentTransitions: [ScheduledPaymentSyncTransition] = []
            var scheduledPaymentAuthority: [String: ScheduledPaymentDTO] = [:]
            var scheduledGroupPaymentTransitions: [ScheduledGroupPaymentSyncTransition] = []
            var scheduledGroupPaymentAuthority: [String: ScheduledGroupPaymentDTO] = [:]
            var groupPaymentAuthority: [String: GroupPaymentDTO] = [:]
            var acknowledgementIDs: [String] = []
            var transitionCount = 0
            var shouldReconcileHistoryTargets = false
            var originalHistoryRosters: [String: SecureMessagingRosterSnapshot] = [:]

            for event in events {
                let type = try validateEvent(event)
                switch type {
                case "conversation.created", "conversation.updated":
                    guard let conversationID = event.conversationId,
                          event.resourceType == "conversation",
                          event.resourceId == conversationID
                    else {
                        throw SecureMessagingExchangeError.invalidServerResponse
                    }
                    if let validated = try await loadSyncConversationIfAvailable(
                        id: conversationID,
                        currentUserID: userID
                    ) {
                        conversations.append(validated.localProjection)
                    }
                    transitionCount += 1

                case "membership.added", "membership.removed":
                    let transition = try validatedGroupMemberTransition(
                        event,
                        type: type,
                        currentUserID: userID
                    )
                    if transition.kind == .memberAdded,
                       transition.subjectUserID == userID {
                        // Being added to a group this device has never seen must materialize
                        // the thread itself — the membership commit below needs a target even
                        // when the server sends no separate conversation.created. If this account
                        // has already been removed again, skip the stale add transition as well.
                        if let validated = try await loadSyncConversationIfAvailable(
                            id: transition.conversationID,
                            currentUserID: userID
                        ) {
                            conversations.append(validated.localProjection)
                            groupMemberTransitions.append(transition)
                        }
                    } else {
                        // Another member's transition mutates only a locally known group. It must
                        // not resurrect a thread that this user deleted from this installation.
                        groupMemberTransitions.append(transition)
                    }
                    transitionCount += 1

                case "membership.role_changed":
                    let roleChange = try validatedGroupRoleChange(event, type: type)
                    // Role changes do not create timeline notices, but they must replace the
                    // authenticated role map (and any concurrent title/roster changes) before
                    // advancing the cursor. Never resurrect a thread deleted from this device.
                    if snapshot.conversations.contains(where: {
                        $0.id == roleChange.conversationID && $0.isGroup
                    }), let validated = try await loadSyncConversationIfAvailable(
                        id: roleChange.conversationID,
                        currentUserID: userID
                    ) {
                        conversations.append(validated.localProjection)
                    }
                    transitionCount += 1

                case "message.created":
                    guard event.resourceType == "message",
                          event.resourceId == event.data?.id,
                          let data = event.data
                    else { throw SecureMessagingExchangeError.invalidServerResponse }
                    let dto = EncryptedMessageDTO(syncData: data)
                    guard let conversationID = dto.conversationId,
                          event.conversationId == conversationID
                    else { throw SecureMessagingExchangeError.invalidServerResponse }
                    guard let conversation = try await loadSyncConversationIfAvailable(
                        id: conversationID,
                        currentUserID: userID
                    ) else { continue }
                    conversations.append(conversation.localProjection)
                    if dto.envelope?.isHistoryBackfill == true {
                        guard dto.kind.flatMap(SecureMessagingMessageKind.init(rawValue:)) != nil,
                              dto.revokedAt == nil,
                              let transferRevision = dto.envelope?.transferRosterRevision,
                              let originalRevision = dto.rosterRevision
                        else { throw SecureMessagingCryptoError.invalidContent }
                        let rosterDTO = try await transport.historicalMessagingDeviceRoster(
                            conversationId: conversation.id,
                            rosterRevision: transferRevision
                        )
                        let transferRoster = try SecureMessagingMapper.roster(
                            from: rosterDTO,
                            use: .historical,
                            expectedConversationID: conversation.id,
                            currentDeviceID: enrollment.serverDeviceID,
                            currentUserID: userID,
                            expectedMemberUserIDs: conversation.memberUserIDs,
                            allowHistoricalGroupMembershipChurn: conversation.isGroup
                        )
                        let originalRoster: SecureMessagingRosterSnapshot
                        if originalRevision == transferRoster.rosterRevision {
                            originalRoster = transferRoster
                        } else {
                            let cacheKey = "\(conversation.id):\(originalRevision)"
                            if let cached = originalHistoryRosters[cacheKey] {
                                originalRoster = cached
                            } else {
                                let loaded = try await loadHistoricalRoster(
                                    revision: originalRevision,
                                    conversation: conversation,
                                    enrollment: enrollment,
                                    allowMissingCurrentDevice: true
                                )
                                originalHistoryRosters[cacheKey] = loaded
                                originalRoster = loaded
                            }
                        }
                        let historyEnvelope = try SecureMessagingMapper.historyInboundEnvelope(
                            from: dto,
                            localRecipient: enrollment.address,
                            localEnrollment: enrollment,
                            transferRoster: transferRoster,
                            originalMessageRoster: originalRoster
                        )
                        let decrypted = try await engine.decryptText(
                            currentState: crypto,
                            incoming: historyEnvelope.cryptoEnvelope,
                            maximumTextUnicodeScalars:
                                SecureMessagingHistoryBackfillCodec.maximumDescriptorUnicodeScalars
                        )
                        crypto = decrypted.state
                        crypto.cachedRosters[transferRoster.rosterRevision] = transferRoster
                        let authenticated: SecureMessagingAuthenticatedHistory
                        switch try Self.historyDescriptorDisposition(
                            decrypted.text,
                            incoming: historyEnvelope
                        ) {
                        case .authenticated(let value):
                            authenticated = value
                        case .suppressed(let acknowledgementMessageID):
                            // The Signal wrapper was authentic, so commit its ratchet and retire the
                            // server event even when the donor's inner descriptor is malformed. A
                            // message-local donor bug must not pin the ordinary sync cursor forever.
                            acknowledgementIDs.append(acknowledgementMessageID)
                            continue
                        }
                        let original = authenticated.original
                        let outgoing = original.senderUserID == userID
                        let localID = outgoing ? original.clientMessageID : original.messageID
                        guard let messageUUID = UUID(uuidString: localID) else {
                            throw SecureMessagingCryptoError.invalidContent
                        }
                        recoveredHistoryMessages.append(LocalMessage(
                            id: messageUUID,
                            serverMessageId: original.messageID,
                            conversationId: conversation.id,
                            senderId: original.senderUserID,
                            body: authenticated.text,
                            createdAt: original.sentAt,
                            sentAt: original.sentAt,
                            state: outgoing ? .sent : .received,
                            failureReason: nil,
                            isOutgoing: outgoing,
                            secureMessagingHistory: original.retainedMetadata
                        ))
                        acknowledgementIDs.append(original.messageID)
                    } else if dto.senderDeviceId == enrollment.serverDeviceID {
                        let clientID = dto.clientMessageId
                        let localMessage = clientID.flatMap { clientID in
                            snapshot.messages.first(where: {
                                $0.id.uuidString.lowercased() == clientID
                            })
                        }
                        if let localMessage {
                            guard localMessage.conversationId == conversation.id,
                                  localMessage.senderId == userID,
                                  localMessage.isOutgoing,
                                  localMessage.serverMessageId.map({ $0 == dto.id }) ?? true
                            else { throw SecureMessagingExchangeError.invalidServerResponse }
                            let echo = try validateOutboundEcho(
                                dto,
                                conversation: conversation,
                                enrollment: enrollment,
                                expectedPlaintext: localMessage.body,
                                expectedAttachments: KitMediaMessageFamilyPolicy
                                    .attachmentRequests(for: localMessage.body),
                                userID: userID
                            )
                            outboundEchoes.append(echo)
                        } else {
                            // The server can replay this installation's already-accepted event
                            // after local message history was pruned or restored incompletely.
                            // Authenticate its exact sender/enrollment and outer wire shape, then
                            // advance only the cursor: never recreate plaintext, mutate a ratchet,
                            // acknowledge delivery, or increment unread state from an orphan echo.
                            try validateDetachedOutboundEcho(
                                dto,
                                conversation: conversation,
                                enrollment: enrollment,
                                userID: userID
                            )
                        }
                    } else {
                        guard dto.kind.flatMap(SecureMessagingMessageKind.init(rawValue:)) != nil,
                              dto.revokedAt == nil,
                              let revision = dto.rosterRevision
                        else { throw SecureMessagingCryptoError.invalidContent }
                        let rosterDTO = try await transport.historicalMessagingDeviceRoster(
                            conversationId: conversation.id,
                            rosterRevision: revision
                        )
                        let roster = try SecureMessagingMapper.roster(
                            from: rosterDTO,
                            use: .historical,
                            expectedConversationID: conversation.id,
                            currentDeviceID: enrollment.serverDeviceID,
                            currentUserID: userID,
                            expectedMemberUserIDs: conversation.memberUserIDs,
                            allowHistoricalGroupMembershipChurn: conversation.isGroup
                        )
                        let envelope = try SecureMessagingMapper.inboundEnvelope(
                            from: dto,
                            localRecipient: enrollment.address,
                            localEnrollment: enrollment,
                            roster: roster
                        )
                        let decrypted = try await engine.decryptText(
                            currentState: crypto,
                            incoming: envelope
                        )
                        // Signal authentication and ratchet advancement have succeeded. Keep that
                        // state even when the sender supplied an attachment/content mismatch: the
                        // malformed message is suppressed and acknowledged so one hostile event
                        // cannot pin this conversation's append-only sync cursor forever.
                        crypto = decrypted.state
                        crypto.cachedRosters[roster.rosterRevision] = roster
                        let sentAt = try parseServerDate(dto.sentAt)
                        guard let projected = try Self.projectedInboundMessage(
                            dto: dto,
                            envelope: envelope,
                            plaintext: decrypted.text,
                            sentAt: sentAt,
                            currentUserID: userID
                        ) else {
                            acknowledgementIDs.append(envelope.messageID)
                            continue
                        }
                        incomingMessages.append(projected)
                        acknowledgementIDs.append(envelope.messageID)
                    }

                case "message.delivery.updated":
                    guard event.resourceType == "message_delivery",
                          let data = event.data,
                          data.deliveryState == "delivered_to_peer",
                          data.messageId == event.resourceId,
                          let messageID = data.messageId,
                          SecureMessagingValidation.isCanonicalUUID(messageID),
                          let deliveredAt = try? parseServerDate(data.deliveredAt)
                    else { throw SecureMessagingExchangeError.invalidServerResponse }
                    deliveryTransitions.append(
                        DeliveryTransition(messageID: messageID, deliveredAt: deliveredAt)
                    )
                    transitionCount += 1

                case "read_receipt.updated":
                    guard event.resourceType == "read_receipt",
                          let conversationID = event.conversationId,
                          let data = event.data,
                          let readerID = data.userId,
                          readerID != userID,
                          SecureMessagingValidation.isCanonicalUUID(readerID),
                          let messageID = data.lastReadMessageId,
                          SecureMessagingValidation.isCanonicalUUID(messageID),
                          let readAt = try? parseServerDate(data.readAt)
                    else { throw SecureMessagingExchangeError.invalidServerResponse }
                    readTransitions.append(ReadTransition(
                        conversationID: conversationID,
                        messageID: messageID,
                        readAt: readAt
                    ))
                    transitionCount += 1

                case "device.enrolled", "bundle.rotated":
                    let lifecycle = try validateDeviceLifecycle(event)
                    shouldReconcileHistoryTargets = true
                    crypto.cachedRosters.removeAll()
                    if type == "device.enrolled",
                       lifecycle.userID == userID,
                       lifecycle.deviceID != enrollment.serverDeviceID {
                        guard let conversationID = event.conversationId,
                              SecureMessagingValidation.isCanonicalUUID(conversationID)
                        else { throw SecureMessagingExchangeError.invalidServerResponse }
                        crypto.historyBackfillTasks.removeAll {
                            $0.conversationID == conversationID
                                && $0.targetDeviceID == lifecycle.deviceID
                        }
                        crypto.historyOutboundEnvelopes =
                            crypto.historyOutboundEnvelopes.filter { _, outbound in
                                outbound.targetDeviceID != lifecycle.deviceID
                                    || outbound.targetEnrollmentEpoch
                                        == lifecycle.enrollmentEpoch
                            }
                        guard crypto.historyBackfillTasks.count < 10_000 else {
                            throw SecureMessagingCryptoError.recordLimitExceeded
                        }
                        crypto.historyBackfillTasks.append(SecureMessagingHistoryBackfillTask(
                            conversationID: conversationID,
                            targetDeviceID: lifecycle.deviceID,
                            targetEnrollmentEpoch: lifecycle.enrollmentEpoch,
                            nextCursor: nil
                        ))
                    }
                    transitionCount += 1

                case "identity.changed", "protocol.upgraded", "device.revoked":
                    let lifecycle = try validateDeviceLifecycle(event)
                    // These events can legitimately identify this installation, but treating the
                    // local Signal identity as a remote session would corrupt trust state. Keep
                    // activation-changing self events fail-closed until authoritative rebind.
                    guard lifecycle.deviceID != enrollment.serverDeviceID else {
                        throw SecureMessagingCryptoError.identityChanged
                    }
                    shouldReconcileHistoryTargets = true
                    crypto = try await engine.invalidatingRemoteDevice(
                        currentState: crypto,
                        serverDeviceID: lifecycle.deviceID,
                        userID: lifecycle.userID,
                        previousIdentityKeySHA256: lifecycle.previousIdentityKeySHA256
                    )
                    crypto.historyBackfillTasks.removeAll {
                        $0.targetDeviceID == lifecycle.deviceID
                    }
                    crypto.historyOutboundEnvelopes =
                        crypto.historyOutboundEnvelopes.filter { _, outbound in
                            outbound.targetDeviceID != lifecycle.deviceID
                        }
                    crypto.cachedRosters.removeAll()
                    transitionCount += 1

                case "devices.revoked":
                    let revokedUserID = try validateAllDevicesRevoked(
                        event,
                        currentUserID: userID
                    )
                    crypto = try await engine.invalidatingRemoteUser(
                        currentState: crypto,
                        userID: revokedUserID
                    )
                    crypto.cachedRosters.removeAll()
                    transitionCount += 1

                case "group_payment_request.created",
                     "group_payment_request.contributed",
                     "group_payment_request.completed",
                     "group_payment_request.cancelled",
                     "group_payment_request.expired":
                    let envelope = try validatedGroupPaymentRequestSyncEnvelope(
                        event,
                        type: type
                    )
                    guard let conversation = try await loadSyncConversationIfAvailable(
                        id: envelope.conversationID,
                        currentUserID: userID
                    ) else {
                        // A durable event can outlive this account's membership. The same opaque
                        // 404 rule used for ordinary conversation events lets the cursor advance
                        // without recreating a locally unavailable group.
                        continue
                    }
                    guard conversation.isGroup else {
                        throw SecureMessagingExchangeError.invalidServerResponse
                    }
                    conversations.append(conversation.localProjection)
                    let request: GroupPaymentRequestDTO
                    if let cached = groupPaymentRequestAuthority[envelope.requestID] {
                        request = cached
                    } else {
                        request = try await transport.groupPaymentRequest(id: envelope.requestID)
                        groupPaymentRequestAuthority[envelope.requestID] = request
                    }
                    let exactContribution: GroupPaymentRequestContributionDTO?
                    let contributionIsEmbedded = envelope.contributionID.map { contributionID in
                        request.contributions.contains {
                            $0.id.caseInsensitiveCompare(contributionID) == .orderedSame
                        }
                    } ?? false
                    if let contributionID = envelope.contributionID,
                       (envelope.action == .completed
                        || (envelope.action == .contributed && !contributionIsEmbedded)) {
                        let cacheKey = "\(envelope.requestID):\(contributionID)"
                        if let cached = groupPaymentRequestContributionAuthority[cacheKey] {
                            exactContribution = cached
                        } else {
                            let contribution = try await transport
                                .groupPaymentRequestContribution(
                                    requestId: envelope.requestID,
                                    contributionId: contributionID
                                )
                            groupPaymentRequestContributionAuthority[cacheKey] = contribution
                            exactContribution = contribution
                        }
                    } else {
                        exactContribution = nil
                    }
                    groupPaymentRequestTransitions.append(
                        try verifiedGroupPaymentRequestSyncTransition(
                            envelope,
                            authoritativeRequest: request,
                            authoritativeContribution: exactContribution,
                            currentUserID: userID
                        )
                    )
                    transitionCount += 1

                case "scheduled_payment.completed",
                     "scheduled_payment.failed",
                     "scheduled_payment.cancelled":
                    guard let envelope = ScheduledPaymentSyncEnvelope(
                        event: event,
                        currentUserID: userID
                    ) else { throw SecureMessagingExchangeError.invalidServerResponse }
                    guard let conversation = try await loadSyncConversationIfAvailable(
                        id: envelope.conversationID,
                        currentUserID: userID
                    ) else {
                        // A sender may have deleted the direct thread locally after arranging the
                        // payment. The financial instruction remains visible in wallet history;
                        // do not resurrect a deliberately removed conversation.
                        continue
                    }
                    guard !conversation.isGroup,
                          envelope.matchesDirectConversation(
                              memberUserIDs: conversation.memberUserIDs
                          )
                    else { throw SecureMessagingExchangeError.invalidServerResponse }
                    let authoritative: ScheduledPaymentDTO
                    if let cached = scheduledPaymentAuthority[envelope.scheduledPaymentID] {
                        authoritative = cached
                    } else {
                        authoritative = try await transport.scheduledPayment(
                            id: envelope.scheduledPaymentID
                        )
                        scheduledPaymentAuthority[envelope.scheduledPaymentID] = authoritative
                    }
                    guard envelope.matchesAuthoritative(authoritative) else {
                        throw SecureMessagingExchangeError.invalidServerResponse
                    }
                    conversations.append(conversation.localProjection)
                    let outgoing = envelope.senderUserID == userID
                    let message = LocalMessage(
                        id: envelope.descriptor.deterministicMessageID,
                        conversationId: envelope.conversationID,
                        senderId: envelope.senderUserID,
                        body: envelope.descriptor.encoded,
                        createdAt: envelope.occurredAt,
                        sentAt: envelope.occurredAt,
                        state: outgoing ? .sent : .received,
                        failureReason: nil,
                        isOutgoing: outgoing
                    )
                    scheduledPaymentTransitions.append(
                        ScheduledPaymentSyncTransition(
                            conversationID: envelope.conversationID,
                            message: message
                        )
                    )
                    transitionCount += 1

                case "scheduled_group_payment.completed",
                     "scheduled_group_payment.failed",
                     "scheduled_group_payment.cancelled":
                    guard let envelope = ScheduledGroupPaymentSyncEnvelope(event: event)
                    else { throw SecureMessagingExchangeError.invalidServerResponse }
                    guard let conversation = try await loadSyncConversationIfAvailable(
                        id: envelope.conversationID,
                        currentUserID: userID
                    ) else {
                        continue
                    }
                    guard conversation.isGroup else {
                        throw SecureMessagingExchangeError.invalidServerResponse
                    }
                    let schedule: ScheduledGroupPaymentDTO
                    if let cached = scheduledGroupPaymentAuthority[
                        envelope.scheduledGroupPaymentID
                    ] {
                        schedule = cached
                    } else {
                        schedule = try await transport.scheduledGroupPayment(
                            id: envelope.scheduledGroupPaymentID
                        )
                        scheduledGroupPaymentAuthority[envelope.scheduledGroupPaymentID] = schedule
                    }
                    guard envelope.matchesAuthoritative(schedule) else {
                        throw SecureMessagingExchangeError.invalidServerResponse
                    }
                    conversations.append(conversation.localProjection)
                    if envelope.action == .completed {
                        guard let groupPaymentID = envelope.groupPaymentID else {
                            throw SecureMessagingExchangeError.invalidServerResponse
                        }
                        let payment: GroupPaymentDTO
                        if let cached = groupPaymentAuthority[groupPaymentID] {
                            payment = cached
                        } else {
                            payment = try await transport.groupPayment(id: groupPaymentID)
                            groupPaymentAuthority[groupPaymentID] = payment
                        }
                        guard let completion = ScheduledGroupPaymentProjectionPolicy.completion(
                            envelope: envelope,
                            schedule: schedule,
                            payment: payment,
                            memberUserIDs: conversation.memberUserIDs
                        ) else { throw SecureMessagingExchangeError.invalidServerResponse }
                        let outgoing = completion.senderUserID == userID
                        scheduledGroupPaymentTransitions.append(
                            ScheduledGroupPaymentSyncTransition(
                                conversationID: envelope.conversationID,
                                message: LocalMessage(
                                    id: ScheduledGroupPaymentProjectionPolicy
                                        .deterministicMessageID(
                                            scheduledGroupPaymentID:
                                                envelope.scheduledGroupPaymentID,
                                            groupPaymentID: groupPaymentID
                                        ),
                                    conversationId: envelope.conversationID,
                                    senderId: completion.senderUserID,
                                    body: completion.descriptor.encoded,
                                    createdAt: envelope.occurredAt,
                                    sentAt: envelope.occurredAt,
                                    state: outgoing ? .sent : .received,
                                    failureReason: nil,
                                    isOutgoing: outgoing
                                )
                            )
                        )
                    } else {
                        let outcomeAction: KitScheduledGroupPaymentOutcomeAction =
                            envelope.action == .failed ? .failed : .cancelled
                        guard let descriptor = KitScheduledGroupPaymentOutcomeMessage(
                            action: outcomeAction,
                            scheduledGroupPaymentID: envelope.scheduledGroupPaymentID,
                            scheduledAt: envelope.scheduledAt
                        ) else { throw SecureMessagingExchangeError.invalidServerResponse }
                        scheduledGroupPaymentTransitions.append(
                            ScheduledGroupPaymentSyncTransition(
                                conversationID: envelope.conversationID,
                                message: LocalMessage(
                                    id: descriptor.deterministicMessageID,
                                    conversationId: envelope.conversationID,
                                    senderId: userID,
                                    body: descriptor.encoded,
                                    createdAt: envelope.occurredAt,
                                    sentAt: envelope.occurredAt,
                                    state: .sent,
                                    failureReason: nil,
                                    isOutgoing: true
                                )
                            )
                        )
                    }
                    transitionCount += 1

                default:
                    throw SecureMessagingExchangeError.unsupportedEvent(type)
                }
            }

            guard Set(acknowledgementIDs).count == acknowledgementIDs.count,
                  crypto.pendingDeliveryAcknowledgementIDs.count
                    + acknowledgementIDs.count <= 10_000
            else { throw SecureMessagingCryptoError.recordLimitExceeded }
            for id in acknowledgementIDs
                where !crypto.pendingDeliveryAcknowledgementIDs.contains(id) {
                crypto.pendingDeliveryAcknowledgementIDs.append(id)
            }
            crypto.syncCursor = nextCursor

            // Reactions are metadata for an ordinary message, never independent timeline rows.
            // Authenticate/decrypt first so their server events can be acknowledged, then retain
            // only targets visible in the same conversation across existing and this-page state.
            let reactionTargetCorpus = snapshot.messages
                + incomingMessages
                + recoveredHistoryMessages
            incomingMessages = MessageReactionAggregationPolicy.retainingValidReactionTargets(
                incomingMessages,
                among: reactionTargetCorpus
            )
            recoveredHistoryMessages =
                MessageReactionAggregationPolicy.retainingValidReactionTargets(
                    recoveredHistoryMessages,
                    among: reactionTargetCorpus
                )
            // Corrections are filtered the same way and against the same corpus: one only counts
            // if its author's own message is visible here to be reworded.
            incomingMessages = MessageEditAggregationPolicy.retainingValidEditTargets(
                incomingMessages,
                among: reactionTargetCorpus
            )
            recoveredHistoryMessages = MessageEditAggregationPolicy.retainingValidEditTargets(
                recoveredHistoryMessages,
                among: reactionTargetCorpus
            )

            do {
                try await store.commitSecureMessaging(
                    forUserID: userID,
                    expectedState: initialCrypto,
                    nextState: crypto
                ) { state in
                    // Server conversation timestamps can advance for reaction-only events. Sync
                    // the title/roster here, then derive visible activity exclusively from the
                    // decrypted non-reaction messages and lifecycle events below.
                    conversations.forEach {
                        Self.upsert(conversation: $0, in: &state, advancesActivity: false)
                    }
                    for echo in outboundEchoes {
                        if let index = state.messages.firstIndex(where: {
                            $0.id.uuidString.lowercased() == echo.clientMessageID
                        }) {
                            state.messages[index].serverMessageId = echo.serverMessageID
                            state.messages[index].sentAt = echo.sentAt
                            state.messages[index].secureMessagingHistory = echo.historyMetadata
                            if state.messages[index].state != .read,
                               state.messages[index].state != .delivered {
                                state.messages[index].state = .sent
                            }
                            state.messages[index].failureReason = nil
                        }
                        state.outbox.removeAll {
                            $0.secureMessageFanout?.clientMessageID == echo.clientMessageID
                        }
                    }
                    for message in incomingMessages where !state.messages.contains(where: {
                        $0.serverMessageId == message.serverMessageId
                    }) {
                        if let syntheticIndex = state.messages.firstIndex(where: {
                            $0.serverMessageId == nil
                                && Self.sameGroupPaymentRequestEvent($0, message)
                        }) {
                            // The financial sync row can beat its optional encrypted descriptor.
                            // Replace that local projection with the authenticated E2EE message
                            // without counting the same event as unread twice.
                            state.messages[syntheticIndex] = message
                            continue
                        }
                        state.messages.append(message)
                        if let index = state.conversations.firstIndex(where: {
                            $0.id == message.conversationId
                        }) {
                            // Reactions and corrections are metadata, not messages: they must
                            // never bump the unread badge or resort the chat list.
                            let isMetadataEvent = message.secureMessagingHistory?.kind
                                .isTimelineMetadata == true
                            if !message.isOutgoing, !isMetadataEvent {
                                state.conversations[index].unreadCount += 1
                            }
                            if !isMetadataEvent {
                                state.conversations[index].updatedAt = max(
                                    state.conversations[index].updatedAt,
                                    message.createdAt
                                )
                            }
                        }
                    }
                    Self.reconcileRecoveredHistoryMessages(
                        recoveredHistoryMessages,
                        currentDeviceID: enrollment.serverDeviceID,
                        into: &state
                    )
                    for transition in deliveryTransitions {
                        guard let index = state.messages.firstIndex(where: {
                            $0.serverMessageId == transition.messageID && $0.isOutgoing
                        }) else { continue }
                        if state.messages[index].state != .read {
                            state.messages[index].state = .delivered
                        }
                    }
                    for transition in readTransitions {
                        guard let boundary = state.messages.first(where: {
                            $0.serverMessageId == transition.messageID
                        }) else { continue }
                        for index in state.messages.indices where
                            state.messages[index].conversationId == transition.conversationID
                            && state.messages[index].isOutgoing
                            && state.messages[index].createdAt <= boundary.createdAt {
                            state.messages[index].state = .read
                        }
                    }
                    for transition in groupMemberTransitions {
                        // Membership is mutable only on a locally known GROUP thread. A locally
                        // deleted thread or a direct thread ignores the event (cursor still
                        // advances); direct participant pairs must never be rewritten by sync.
                        guard let index = state.conversations.firstIndex(where: {
                            $0.id == transition.conversationID
                        }), state.conversations[index].isGroup else { continue }
                        let transitionDate = transition.systemMessage.createdAt
                        if Self.serverProjectionIsNotOlder(
                            conversationID: transition.conversationID,
                            updatedAt: transitionDate,
                            in: state
                        ) {
                            var participants = state.conversations[index].participantUserIds
                            switch transition.kind {
                            case .memberAdded:
                                if !participants.contains(transition.subjectUserID) {
                                    guard participants.count
                                        < SecureMessagingWire.maximumGroupMembers
                                    else {
                                        throw SecureMessagingExchangeError.invalidServerResponse
                                    }
                                    participants.append(transition.subjectUserID)
                                    participants.sort()
                                    if var roles = state.conversations[index].groupMemberRoles,
                                       let role = transition.role {
                                        roles[transition.subjectUserID] = role
                                        state.conversations[index].groupMemberRoles = roles
                                    }
                                }
                            case .memberRemoved, .memberLeft:
                                participants.removeAll { $0 == transition.subjectUserID }
                                state.conversations[index].groupMemberRoles?
                                    .removeValue(forKey: transition.subjectUserID)
                            }
                            state.conversations[index].participantUserIds = participants
                            state.conversations[index].updatedAt = max(
                                state.conversations[index].updatedAt,
                                transitionDate
                            )
                            Self.recordServerProjection(
                                conversationID: transition.conversationID,
                                updatedAt: transitionDate,
                                in: &state
                            )
                        }
                        // The deterministic/resource-derived id makes a replayed page converge
                        // on one system notice.
                        if !state.messages.contains(where: {
                            $0.id == transition.systemMessage.id
                        }) {
                            state.messages.append(transition.systemMessage)
                        }
                    }
                    for transition in groupPaymentRequestTransitions {
                        let message = transition.message
                        guard !state.messages.contains(where: {
                            $0.id == message.id || Self.sameGroupPaymentRequestEvent($0, message)
                        }) else { continue }
                        state.messages.append(message)
                        if let index = state.conversations.firstIndex(where: {
                            $0.id == transition.conversationID
                        }) {
                            state.conversations[index].updatedAt = max(
                                state.conversations[index].updatedAt,
                                message.createdAt
                            )
                            if !message.isOutgoing {
                                state.conversations[index].unreadCount += 1
                            }
                        }
                    }
                    for transition in scheduledPaymentTransitions {
                        let message = transition.message
                        if let existing = state.messages.firstIndex(where: {
                            $0.id == message.id
                        }) {
                            // The server projection owns this deterministic namespace. Replace a
                            // colliding untrusted E2EE row; otherwise a peer could suppress the
                            // real financial outcome by predicting its local identifier.
                            if let existingDescriptor = KitScheduledPaymentMessage.parse(
                                state.messages[existing].body
                            ), existingDescriptor.isTrustedProjection(state.messages[existing]) {
                                continue
                            }
                            state.messages[existing] = message
                        } else {
                            state.messages.append(message)
                        }
                        if let index = state.conversations.firstIndex(where: {
                            $0.id == transition.conversationID
                        }) {
                            state.conversations[index].updatedAt = max(
                                state.conversations[index].updatedAt,
                                message.createdAt
                            )
                            if !message.isOutgoing {
                                state.conversations[index].unreadCount += 1
                            }
                        }
                    }
                    for transition in scheduledGroupPaymentTransitions {
                        let message = transition.message
                        if let existing = state.messages.firstIndex(where: {
                            $0.id == message.id
                        }) {
                            // This deterministic row is an authenticated server projection. A
                            // replay is a no-op; any colliding local/E2EE row is replaced by the
                            // exact schedule + group-payment projection verified above.
                            if state.messages[existing] == message { continue }
                            state.messages[existing] = message
                        } else {
                            state.messages.append(message)
                        }
                        if let index = state.conversations.firstIndex(where: {
                            $0.id == transition.conversationID
                        }) {
                            state.conversations[index].updatedAt = max(
                                state.conversations[index].updatedAt,
                                message.createdAt
                            )
                            if !message.isOutgoing {
                                state.conversations[index].unreadCount += 1
                            }
                        }
                    }
                    // Lifecycle pages can be delayed. Replay their ordered notices/transitions,
                    // then let the current server projection win for title, roster and roles.
                    conversations.forEach {
                        Self.upsert(conversation: $0, in: &state, advancesActivity: false)
                    }
                    for conversationID in Set(groupMemberTransitions.map(\.conversationID)) {
                        guard let conversation = state.conversations.first(where: {
                            $0.id == conversationID && $0.isGroup
                        }), !conversation.participantUserIds.contains(userID)
                        else { continue }
                        Self.abandonSecureGroupOutbox(
                            conversationID: conversationID,
                            in: &state
                        )
                    }
                }
                // A history wrapper can reveal plaintext after an earlier donor pass skipped it.
                // Reconcile current same-account targets again before this sync finishes so the
                // newly retained message can continue to every enrolled device.
                if shouldReconcileHistoryTargets || !recoveredHistoryMessages.isEmpty {
                    historyReconciledEnrollment = nil
                }
                return SecureMessagingSyncResult(
                    pages: 1,
                    receivedMessages: incomingMessages.count,
                    appliedTransitions: transitionCount
                )
            } catch SecureMessagingCryptoError.staleState {
                try Task.checkCancellation()
                continue
            }
        }
        throw SecureMessagingExchangeError.retryLimitExceeded
    }

    private func flushDeliveryAcknowledgements(forUserID userID: String) async throws {
        while true {
            let snapshot = await store.snapshot()
            guard snapshot.profile?.id == userID,
                  let initialCrypto = snapshot.secureMessaging,
                  let enrollment = initialCrypto.enrollment
            else { throw SecureMessagingExchangeError.invalidAccount }
            let ids = Array(initialCrypto.pendingDeliveryAcknowledgementIDs.prefix(
                SecureMessagingWire.maximumDeliveryAcknowledgements
            ))
            if ids.isEmpty { return }
            let result = try await transport.acknowledgeMessageDelivery(
                try AcknowledgeMessageDeliveryRequest(messageIds: ids)
            )
            guard result.deliveryState == "delivered_to_device",
                  result.deviceId == enrollment.serverDeviceID,
                  result.acknowledgedCount == ids.count,
                  let items = result.items,
                  items.count == ids.count,
                  Set(items.compactMap { $0?.messageId }) == Set(ids),
                  items.allSatisfy({ item in
                      guard let item,
                            let messageID = item.messageId,
                            let timestamp = item.deliveredToDeviceAt
                      else { return false }
                      return ids.contains(messageID) && parseServerDateIfValid(timestamp)
                  })
            else { throw SecureMessagingExchangeError.invalidServerResponse }

            var nextCrypto = initialCrypto
            nextCrypto.pendingDeliveryAcknowledgementIDs.removeAll { ids.contains($0) }
            do {
                try await store.commitSecureMessaging(
                    forUserID: userID,
                    expectedState: initialCrypto,
                    nextState: nextCrypto
                )
            } catch SecureMessagingCryptoError.staleState {
                continue
            }
        }
    }

    private func loadConversation(
        id: String,
        currentUserID: String
    ) async throws -> ValidatedDirectConversation {
        let id = try canonicalUUID(id, error: .invalidConversation)
        let dto = try await transport.messagingConversation(id: id)
        return try validateConversation(
            dto,
            currentUserID: currentUserID,
            expectedRecipientUserID: nil,
            fallbackTitle: "Kit Pay contact"
        )
    }

    /// Sync rows can outlive this account's active membership. The authenticated conversation
    /// endpoint deliberately hides both missing threads and inactive membership behind one exact
    /// structured 404. Only that documented response is skippable; malformed DTOs, unstructured
    /// 404s, authentication failures, and transient transport failures must retain the cursor.
    private func loadSyncConversationIfAvailable(
        id: String,
        currentUserID: String
    ) async throws -> ValidatedDirectConversation? {
        do {
            return try await loadConversation(id: id, currentUserID: currentUserID)
        } catch {
            guard Self.isUnavailableConversationError(error) else { throw error }
            return nil
        }
    }

    private nonisolated static func isUnavailableConversationError(_ error: Error) -> Bool {
        guard let payload = error as? APIErrorPayload else { return false }
        return payload.httpStatus == 404 && payload.code == "CONVERSATION_NOT_FOUND"
    }

    private func validateConversation(
        _ dto: MessagingConversationDTO,
        currentUserID: String,
        expectedRecipientUserID: String?,
        fallbackTitle: String
    ) throws -> ValidatedDirectConversation {
        guard let type = dto.type,
              let rawID = dto.id,
              let members = dto.members,
              members.allSatisfy({ $0 != nil })
        else { throw SecureMessagingExchangeError.invalidConversation }
        let id = try canonicalUUID(rawID, error: .invalidConversation)
        let values = members.compactMap { $0 }
        let memberIDs = try Set(values.map {
            try canonicalUUID($0.userId, error: .invalidConversation)
        })
        let parsedUpdatedAt = try? parseServerDate(dto.updatedAt)

        switch type {
        case SecureMessagingWire.directConversationType:
            guard members.count == 2,
                  memberIDs.count == 2,
                  memberIDs.contains(currentUserID),
                  let recipient = memberIDs.first(where: { $0 != currentUserID }),
                  expectedRecipientUserID.map({ $0 == recipient }) ?? true
            else { throw SecureMessagingExchangeError.invalidConversation }
            let serverTitle = dto.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            // Direct titles are server-null by contract; prefer the viewer-scoped peer alias.
            let peerName = values.first(where: { $0.userId == recipient })?.name?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = fallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = [peerName, serverTitle, fallback, "Kit Pay contact"]
                .compactMap { $0 }
                .first(where: { !$0.isEmpty })!
            // Identity fields belong to groups alone. A direct conversation carrying either is
            // not describing a thread this client knows how to trust.
            guard dto.description == nil, dto.photoUrl == nil else {
                throw SecureMessagingExchangeError.invalidConversation
            }
            return ValidatedDirectConversation(
                id: id,
                recipientUserID: recipient,
                memberUserIDs: memberIDs,
                title: title,
                updatedAt: parsedUpdatedAt ?? Date(),
                conversationType: type,
                groupMemberRoles: nil,
                groupDescription: nil,
                groupPhotoURL: nil
            )

        case SecureMessagingWire.groupConversationType:
            // A group has no single peer; any caller pinning an expected direct recipient must
            // fail closed rather than address one member of a wider roster.
            guard expectedRecipientUserID == nil,
                  memberIDs.count == values.count,
                  (1 ... SecureMessagingWire.maximumGroupMembers).contains(memberIDs.count),
                  memberIDs.contains(currentUserID),
                  let updatedAt = parsedUpdatedAt
            else { throw SecureMessagingExchangeError.invalidConversation }
            // Group titles are server-owned: the server title wins for every member; the
            // neutral fallback never leaks a per-viewer alias into a shared thread name.
            guard let title = dto.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                  MessagingGroupTitlePolicy.isValid(title)
            else { throw SecureMessagingExchangeError.invalidConversation }
            let rawRoles = values.map(\.role)
            let memberRoles: [String: MessagingGroupRole]?
            if rawRoles.allSatisfy({ $0 == nil }) {
                memberRoles = nil
            } else {
                guard rawRoles.allSatisfy({ $0 != nil }) else {
                    throw SecureMessagingExchangeError.invalidConversation
                }
                var roles: [String: MessagingGroupRole] = [:]
                for member in values {
                    guard let rawUserID = member.userId,
                          let userID = try? canonicalUUID(
                              rawUserID,
                              error: .invalidConversation
                          ),
                          let rawRole = member.role,
                          let role = MessagingGroupRole(rawValue: rawRole),
                          roles[userID] == nil
                    else { throw SecureMessagingExchangeError.invalidConversation }
                    roles[userID] = role
                }
                memberRoles = roles
            }
            if let rawViewerRole = dto.role {
                guard let viewerRole = MessagingGroupRole(rawValue: rawViewerRole),
                      memberRoles?[currentUserID] == viewerRole
                else { throw SecureMessagingExchangeError.invalidConversation }
            }
            // Group identity is optional but never malformed: a description is canonicalized
            // the way the server stores it, and a photo address must be structurally sane.
            let description = dto.description
                .map(MessagingGroupDescriptionPolicy.normalized)
                .flatMap { $0.isEmpty ? nil : $0 }
            if let description {
                guard MessagingGroupDescriptionPolicy.isValid(description) else {
                    throw SecureMessagingExchangeError.invalidConversation
                }
            }
            let photoURL = dto.photoUrl
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .flatMap { $0.isEmpty ? nil : $0 }
            if let photoURL {
                guard MessagingGroupPhotoURLPolicy.isValid(photoURL) else {
                    throw SecureMessagingExchangeError.invalidConversation
                }
            }
            return ValidatedDirectConversation(
                id: id,
                recipientUserID: nil,
                memberUserIDs: memberIDs,
                title: title,
                updatedAt: updatedAt,
                conversationType: type,
                groupMemberRoles: memberRoles,
                groupDescription: description,
                groupPhotoURL: photoURL
            )

        default:
            throw SecureMessagingExchangeError.invalidConversation
        }
    }

    private func validateOutboundResponse(
        _ dto: EncryptedMessageDTO,
        fanout: SecureMessagingCommittedFanout,
        expectedPlaintext: String,
        expectedAttachments: [EncryptedAttachmentRequest],
        userID: String,
        enrollment: SecureMessagingEnrollmentBinding?
    ) throws -> OutboundEcho {
        guard let expectedKind = SecureMessagingContentBindingPolicy.kind(
                  for: expectedPlaintext,
                  replyToMessageID: fanout.replyToMessageID,
                  attachments: expectedAttachments
              ),
              let enrollment,
              let id = dto.id,
              SecureMessagingValidation.isCanonicalUUID(id),
              dto.clientMessageId == fanout.clientMessageID,
              dto.conversationId == fanout.conversationID,
              dto.rosterRevision == fanout.rosterRevision,
              dto.sender?.id == userID,
              dto.senderDeviceId == enrollment.serverDeviceID,
              dto.senderEnrollmentEpoch == enrollment.enrollmentEpoch,
              dto.senderSignalDeviceId == Int(enrollment.signalDeviceID),
              dto.senderRegistrationId == Int(enrollment.registrationID),
              dto.senderProtocolVersion == SecureMessagingWire.protocolVersion,
              dto.senderBundleVersion == enrollment.bundleVersion,
              dto.senderIdentityKeySha256 == enrollment.identityKeySHA256,
              dto.kind == expectedKind.rawValue,
              dto.replyToMessageId == fanout.replyToMessageID,
              dto.envelope == nil,
              let rawAttachments = dto.attachments,
              rawAttachments.allSatisfy({ $0 != nil }),
              KitMediaMessageFamilyPolicy.validatesWireRows(
                  rawAttachments,
                  forBody: expectedPlaintext
              ),
              dto.reactions?.isEmpty == true,
              dto.revokedAt == nil
        else { throw SecureMessagingExchangeError.invalidServerResponse }
        return OutboundEcho(
            clientMessageID: fanout.clientMessageID,
            serverMessageID: id,
            sentAt: try parseServerDate(dto.sentAt),
            historyMetadata: SecureMessagingRetainedMessageMetadata(
                clientMessageID: fanout.clientMessageID,
                senderUserID: userID,
                senderDeviceID: enrollment.serverDeviceID,
                senderEnrollmentEpoch: enrollment.enrollmentEpoch,
                senderSignalDeviceID: enrollment.signalDeviceID,
                rosterRevision: fanout.rosterRevision,
                kind: expectedKind,
                replyToMessageID: fanout.replyToMessageID
            )
        )
    }

    private func validateOutboundEcho(
        _ dto: EncryptedMessageDTO,
        conversation: ValidatedDirectConversation,
        enrollment: SecureMessagingEnrollmentBinding,
        expectedPlaintext: String,
        expectedAttachments: [EncryptedAttachmentRequest],
        userID: String
    ) throws -> OutboundEcho {
        guard let expectedKind = SecureMessagingContentBindingPolicy.kind(
                  for: expectedPlaintext,
                  replyToMessageID: dto.replyToMessageId,
                  attachments: expectedAttachments
              ),
              let serverID = dto.id,
              SecureMessagingValidation.isCanonicalUUID(serverID),
              let clientID = dto.clientMessageId,
              SecureMessagingValidation.isCanonicalUUID(clientID),
              dto.conversationId == conversation.id,
              dto.sender?.id == userID,
              dto.senderDeviceId == enrollment.serverDeviceID,
              dto.senderEnrollmentEpoch == enrollment.enrollmentEpoch,
              dto.senderSignalDeviceId == Int(enrollment.signalDeviceID),
              dto.senderRegistrationId == Int(enrollment.registrationID),
              dto.senderProtocolVersion == SecureMessagingWire.protocolVersion,
              dto.senderBundleVersion == enrollment.bundleVersion,
              dto.senderIdentityKeySha256 == enrollment.identityKeySHA256,
              dto.rosterRevision.map(SecureMessagingWirePolicy.isRosterRevision) == true,
              dto.kind == expectedKind.rawValue,
              dto.replyToMessageId.map(SecureMessagingWirePolicy.isCanonicalUUID) ?? true,
              dto.envelope == nil,
              let rawAttachments = dto.attachments,
              rawAttachments.allSatisfy({ $0 != nil }),
              KitMediaMessageFamilyPolicy.validatesWireRows(
                  rawAttachments,
                  forBody: expectedPlaintext
              ),
              dto.reactions?.isEmpty == true,
              dto.revokedAt == nil
        else { throw SecureMessagingExchangeError.invalidServerResponse }
        return OutboundEcho(
            clientMessageID: clientID,
            serverMessageID: serverID,
            sentAt: try parseServerDate(dto.sentAt),
            historyMetadata: SecureMessagingRetainedMessageMetadata(
                clientMessageID: clientID,
                senderUserID: userID,
                senderDeviceID: enrollment.serverDeviceID,
                senderEnrollmentEpoch: enrollment.enrollmentEpoch,
                senderSignalDeviceID: enrollment.signalDeviceID,
                rosterRevision: dto.rosterRevision!,
                kind: expectedKind,
                replyToMessageID: dto.replyToMessageId
            )
        )
    }

    /// A cursor replay can outlive the local projection that originated it. With no retained
    /// plaintext there is nothing to reconcile, but a structurally invalid self echo must still
    /// fail closed instead of becoming a general-purpose server-controlled cursor skip.
    private func validateDetachedOutboundEcho(
        _ dto: EncryptedMessageDTO,
        conversation: ValidatedDirectConversation,
        enrollment: SecureMessagingEnrollmentBinding,
        userID: String
    ) throws {
        guard let serverID = dto.id,
              SecureMessagingValidation.isCanonicalUUID(serverID),
              let clientID = dto.clientMessageId,
              SecureMessagingValidation.isCanonicalUUID(clientID),
              dto.conversationId == conversation.id,
              dto.sender?.id == userID,
              dto.senderDeviceId == enrollment.serverDeviceID,
              dto.senderEnrollmentEpoch == enrollment.enrollmentEpoch,
              dto.senderSignalDeviceId == Int(enrollment.signalDeviceID),
              dto.senderRegistrationId == Int(enrollment.registrationID),
              dto.senderProtocolVersion == SecureMessagingWire.protocolVersion,
              dto.senderBundleVersion == enrollment.bundleVersion,
              dto.senderIdentityKeySha256 == enrollment.identityKeySHA256,
              dto.rosterRevision.map(SecureMessagingWirePolicy.isRosterRevision) == true,
              dto.replyToMessageId.map(SecureMessagingWirePolicy.isCanonicalUUID) ?? true,
              dto.envelope == nil,
              dto.reactions?.isEmpty == true,
              dto.revokedAt == nil,
              let rawAttachments = dto.attachments,
              rawAttachments.count <= SecureMessagingWire.maximumAttachments,
              rawAttachments.allSatisfy({ $0 != nil })
        else { throw SecureMessagingExchangeError.invalidServerResponse }

        let attachments = try rawAttachments.map { raw -> (id: String, storageKey: String) in
            guard let raw,
                  let id = raw.id,
                  SecureMessagingWirePolicy.isCanonicalUUID(id),
                  let storageKey = raw.storageKey,
                  SecureMessagingWirePolicy.isCanonicalUUID(storageKey),
                  let mediaType = raw.mediaType,
                  SecureMessagingWire.allowedAttachmentMediaTypes.contains(mediaType),
                  let byteSize = raw.byteSize,
                  (SecureMessagingWire.minimumAttachmentCiphertextBytes
                    ... SecureMessagingWire.maximumAttachmentCiphertextBytes).contains(byteSize),
                  let digest = raw.ciphertextSha256,
                  SecureMessagingWirePolicy.isLowercaseSHA256(digest),
                  raw.encryptionMetadataCiphertext == nil
            else { throw SecureMessagingExchangeError.invalidServerResponse }
            return (id, storageKey)
        }
        guard Set(attachments.map { $0.id }).count == attachments.count,
              Set(attachments.map { $0.storageKey }).count == attachments.count,
              let rawKind = dto.kind,
              let kind = SecureMessagingMessageKind(rawValue: rawKind),
              SecureMessagingContentBindingPolicy.validatesOuterEnvelope(
                  kind: kind,
                  replyToMessageID: dto.replyToMessageId,
                  attachmentCount: attachments.count
              ),
              parseServerDateIfValid(dto.sentAt)
        else { throw SecureMessagingExchangeError.invalidServerResponse }
    }

    private func validateEvent(_ event: MessagingSyncEventDTO) throws -> String {
        guard let id = event.id,
              SecureMessagingValidation.isCanonicalPositiveDecimalID(id),
              let type = event.type,
              !type.isEmpty,
              type.count <= 120,
              let resourceType = event.resourceType,
              !resourceType.isEmpty,
              resourceType.count <= 120,
              let resourceID = event.resourceId,
              !resourceID.isEmpty,
              resourceID.count <= 120,
              parseServerDateIfValid(event.occurredAt),
              event.conversationId.map(SecureMessagingValidation.isCanonicalUUID) ?? true
        else { throw SecureMessagingExchangeError.invalidServerResponse }
        return type
    }

    /// Validates the self-contained financial snapshot before any network authority is consulted.
    /// Unknown, contradictory, or partially populated rows retain the cursor so a corrupt event
    /// can never be presented as money history.
    private func validatedGroupPaymentRequestSyncEnvelope(
        _ event: MessagingSyncEventDTO,
        type: String
    ) throws -> GroupPaymentRequestSyncEnvelope {
        guard let action = GroupPaymentRequestSyncAction(eventType: type),
              let data = event.data,
              data.schema == "kit.group-payment-request.v1",
              let rawConversationID = data.conversationId,
              let conversationID = GroupPaymentRequestValidation.canonicalUUID(rawConversationID),
              rawConversationID == conversationID,
              event.conversationId == conversationID,
              let rawRequestID = data.groupPaymentRequestId,
              let requestID = GroupPaymentRequestValidation.canonicalUUID(rawRequestID),
              rawRequestID == requestID,
              let rawRequesterID = data.requesterUserId,
              let requesterUserID = GroupPaymentRequestValidation.canonicalUUID(rawRequesterID),
              rawRequesterID == requesterUserID,
              let status = data.status.flatMap(GroupPaymentRequestStatus.init(rawValue:)),
              let target = data.targetAmountMinor.flatMap(
                  GroupPaymentRequestValidation.canonicalMinorUnits
              ),
              let contributed = data.contributedAmountMinor.flatMap(
                  GroupPaymentRequestValidation.canonicalMinorUnits
              ),
              let remaining = data.remainingAmountMinor.flatMap(
                  GroupPaymentRequestValidation.canonicalMinorUnits
              ),
              target > 0,
              target <= KitGroupPaymentMessage.maximumAmountMinor,
              contributed >= 0,
              contributed <= target,
              remaining == target - contributed,
              let currency = data.currency,
              GroupPaymentRequestValidation.isCurrencyCode(currency),
              let currencyScale = data.currencyScale,
              (0 ... 6).contains(currencyScale),
              let progress = data.progressBasisPoints,
              progress == GroupPaymentRequestValidation.progressBasisPoints(
                  contributed: contributed,
                  target: target
              )
        else { throw SecureMessagingExchangeError.invalidServerResponse }

        let contributionID: String?
        let contributorUserID: String?
        let contributionAmount: Int64?
        switch action {
        case .created:
            guard event.resourceType == "group_payment_request",
                  event.resourceId == requestID,
                  status == .open,
                  contributed == 0,
                  remaining == target,
                  progress == 0,
                  data.contributionId == nil,
                  data.contributorUserId == nil,
                  data.contributionAmountMinor == nil
            else { throw SecureMessagingExchangeError.invalidServerResponse }
            contributionID = nil
            contributorUserID = nil
            contributionAmount = nil

        case .contributed:
            guard event.resourceType == "group_payment_request_contribution",
                  let rawContributionID = data.contributionId,
                  let canonicalContributionID = GroupPaymentRequestValidation.canonicalUUID(
                      rawContributionID
                  ),
                  rawContributionID == canonicalContributionID,
                  event.resourceId == canonicalContributionID,
                  let rawContributorID = data.contributorUserId,
                  let canonicalContributorID = GroupPaymentRequestValidation.canonicalUUID(
                      rawContributorID
                  ),
                  rawContributorID == canonicalContributorID,
                  canonicalContributorID != requesterUserID,
                  let canonicalContributionAmount = data.contributionAmountMinor.flatMap(
                      GroupPaymentRequestValidation.canonicalMinorUnits
                  ),
                  canonicalContributionAmount > 0,
                  canonicalContributionAmount <= contributed,
                  status == .open || status == .completed
            else { throw SecureMessagingExchangeError.invalidServerResponse }
            contributionID = canonicalContributionID
            contributorUserID = canonicalContributorID
            contributionAmount = canonicalContributionAmount

        case .completed:
            guard event.resourceType == "group_payment_request",
                  event.resourceId == requestID,
                  status == .completed,
                  remaining == 0,
                  let rawContributionID = data.contributionId,
                  let canonicalContributionID = GroupPaymentRequestValidation.canonicalUUID(
                      rawContributionID
                  ),
                  rawContributionID == canonicalContributionID,
                  let rawContributorID = data.contributorUserId,
                  let canonicalContributorID = GroupPaymentRequestValidation.canonicalUUID(
                      rawContributorID
                  ),
                  rawContributorID == canonicalContributorID,
                  canonicalContributorID != requesterUserID,
                  let canonicalContributionAmount = data.contributionAmountMinor.flatMap(
                      GroupPaymentRequestValidation.canonicalMinorUnits
                  ),
                  canonicalContributionAmount > 0,
                  canonicalContributionAmount <= contributed
            else { throw SecureMessagingExchangeError.invalidServerResponse }
            contributionID = canonicalContributionID
            contributorUserID = canonicalContributorID
            contributionAmount = canonicalContributionAmount

        case .cancelled, .expired:
            let expectedStatus: GroupPaymentRequestStatus = switch action {
            case .cancelled: .cancelled
            case .expired: .expired
            case .created, .contributed, .completed: .open
            }
            guard event.resourceType == "group_payment_request",
                  event.resourceId == requestID,
                  status == expectedStatus,
                  data.contributionId == nil,
                  data.contributorUserId == nil,
                  data.contributionAmountMinor == nil
            else { throw SecureMessagingExchangeError.invalidServerResponse }
            contributionID = nil
            contributorUserID = nil
            contributionAmount = nil
        }

        return GroupPaymentRequestSyncEnvelope(
            action: action,
            requestID: requestID,
            conversationID: conversationID,
            requesterUserID: requesterUserID,
            status: status,
            targetAmountMinor: target,
            contributedAmountMinor: contributed,
            remainingAmountMinor: remaining,
            currencyCode: currency,
            currencyScale: currencyScale,
            progressBasisPoints: progress,
            contributionID: contributionID,
            contributorUserID: contributorUserID,
            contributionAmountMinor: contributionAmount,
            occurredAt: try parseServerDate(event.occurredAt)
        )
    }

    /// Converts a validated sync snapshot into a deterministic local chat projection only after
    /// the authenticated resource endpoint confirms immutable context and actor attribution.
    private func verifiedGroupPaymentRequestSyncTransition(
        _ envelope: GroupPaymentRequestSyncEnvelope,
        authoritativeRequest request: GroupPaymentRequestDTO,
        authoritativeContribution exactContribution: GroupPaymentRequestContributionDTO?,
        currentUserID: String
    ) throws -> GroupPaymentRequestSyncTransition {
        guard request.isStructurallyValid,
              request.id.caseInsensitiveCompare(envelope.requestID) == .orderedSame,
              request.conversationId.caseInsensitiveCompare(envelope.conversationID) == .orderedSame,
              request.requesterUserId.caseInsensitiveCompare(envelope.requesterUserID) == .orderedSame,
              request.targetMinorUnits == envelope.targetAmountMinor,
              request.currency.code == envelope.currencyCode,
              request.currencyScale == envelope.currencyScale,
              let currentContributed = request.contributedMinorUnits,
              currentContributed >= envelope.contributedAmountMinor,
              request.progressBasisPoints >= envelope.progressBasisPoints
        else { throw SecureMessagingExchangeError.invalidServerResponse }

        let descriptor: KitGroupPaymentRequestMessage
        let actorUserID: String
        switch envelope.action {
        case .created:
            guard let value = KitGroupPaymentRequestMessage(requesting: request) else {
                throw SecureMessagingExchangeError.invalidServerResponse
            }
            descriptor = value
            actorUserID = envelope.requesterUserID

        case .contributed:
            guard let contributionID = envelope.contributionID,
                  let contributorUserID = envelope.contributorUserID,
                  let contributionAmount = envelope.contributionAmountMinor,
                  let contribution = request.contributions.first(where: {
                      $0.id.caseInsensitiveCompare(contributionID) == .orderedSame
                  }) ?? exactContribution,
                  contribution.id.caseInsensitiveCompare(contributionID) == .orderedSame,
                  contribution.isStructurallyValid(currencyScale: request.currencyScale),
                  contribution.contributorUserId.caseInsensitiveCompare(contributorUserID)
                    == .orderedSame,
                  contribution.minorUnits == contributionAmount,
                  let value = KitGroupPaymentRequestMessage(
                      contributing: contribution,
                      requestID: request.id
                  )
            else { throw SecureMessagingExchangeError.invalidServerResponse }
            descriptor = value
            actorUserID = contributorUserID

        case .completed:
            guard request.knownStatus == .completed,
                  request.remainingMinorUnits == 0,
                  let contributionID = envelope.contributionID,
                  let contributorUserID = envelope.contributorUserID,
                  let contributionAmount = envelope.contributionAmountMinor,
                  let finalContribution = exactContribution,
                  finalContribution.id.caseInsensitiveCompare(contributionID) == .orderedSame,
                  finalContribution.isStructurallyValid(currencyScale: request.currencyScale),
                  finalContribution.contributorUserId.caseInsensitiveCompare(contributorUserID)
                    == .orderedSame,
                  finalContribution.minorUnits == contributionAmount,
                  let value = KitGroupPaymentRequestMessage(
                      completing: finalContribution,
                      requestID: request.id
                  )
            else { throw SecureMessagingExchangeError.invalidServerResponse }
            descriptor = value
            actorUserID = contributorUserID

        case .cancelled:
            guard request.knownStatus == .cancelled,
                  let value = KitGroupPaymentRequestMessage(
                      terminal: .cancelled,
                      requestID: request.id
                  )
            else { throw SecureMessagingExchangeError.invalidServerResponse }
            descriptor = value
            actorUserID = envelope.requesterUserID

        case .expired:
            guard request.knownStatus == .expired,
                  let value = KitGroupPaymentRequestMessage(
                      terminal: .expired,
                      requestID: request.id
                  )
            else { throw SecureMessagingExchangeError.invalidServerResponse }
            descriptor = value
            actorUserID = envelope.requesterUserID
        }

        let canonicalCurrentUserID = currentUserID.lowercased()
        let message = LocalMessage(
            id: KitGroupPaymentRequestMessage.deterministicMessageID(
                requestID: envelope.requestID,
                action: descriptor.action,
                contributionID: descriptor.contributionID,
                actorUserID: actorUserID
            ),
            conversationId: envelope.conversationID,
            senderId: actorUserID,
            body: descriptor.encoded,
            createdAt: envelope.occurredAt,
            sentAt: envelope.occurredAt,
            state: actorUserID == canonicalCurrentUserID ? .sent : .received,
            failureReason: nil,
            isOutgoing: actorUserID == canonicalCurrentUserID
        )
        return GroupPaymentRequestSyncTransition(
            conversationID: envelope.conversationID,
            message: message
        )
    }

    private nonisolated static func sameGroupPaymentRequestEvent(
        _ lhs: LocalMessage,
        _ rhs: LocalMessage
    ) -> Bool {
        guard lhs.conversationId == rhs.conversationId,
              lhs.senderId == rhs.senderId,
              let left = KitGroupPaymentRequestMessage.parse(lhs.body),
              let right = KitGroupPaymentRequestMessage.parse(rhs.body)
        else { return false }
        return left.action == right.action
            && left.requestID == right.requestID
            && left.contributionID == right.contributionID
    }

    /// Validates a group membership lifecycle event and pre-builds its thread-documenting system
    /// notice. The notice id derives from the full event identity so server replays deduplicate
    /// without colliding with another lifecycle event for the same membership resource.
    private func validatedGroupMemberTransition(
        _ event: MessagingSyncEventDTO,
        type: String,
        currentUserID: String
    ) throws -> GroupMemberTransition {
        guard let conversationID = event.conversationId,
              event.resourceType == "conversation_member",
              let resourceID = event.resourceId,
              let eventID = event.id,
              let data = event.data,
              let subjectUserID = data.userId,
              SecureMessagingValidation.isCanonicalUUID(subjectUserID),
              data.actorUserId == nil
        else { throw SecureMessagingExchangeError.invalidServerResponse }
        let occurredAt = try parseServerDate(event.occurredAt)
        let kind: KitSystemMessage.Kind
        switch type {
        case "membership.added": kind = .memberAdded
        case "membership.removed": kind = .memberRemoved
        default: throw SecureMessagingExchangeError.invalidServerResponse
        }
        let role: MessagingGroupRole?
        if kind == .memberAdded {
            guard let rawRole = data.role,
                  let parsedRole = MessagingGroupRole(rawValue: rawRole)
            else { throw SecureMessagingExchangeError.invalidServerResponse }
            role = parsedRole
        } else {
            guard data.role == nil else {
                throw SecureMessagingExchangeError.invalidServerResponse
            }
            role = nil
        }
        let actorUserID = data.actorUserId?.lowercased()
        guard let descriptor = KitSystemMessage(
            kind: kind,
            subjectUserID: subjectUserID.lowercased(),
            actorUserID: actorUserID
        ) else { throw SecureMessagingExchangeError.invalidServerResponse }
        // ALWAYS derive the notice id from the full event identity. Using the raw resource
        // UUID would collide when the server reuses one conversation_member resource across
        // lifecycle events (added then removed) — the second notice would silently dedup away
        // — and could even collide with a real message id.
        let messageID = KitSystemMessage.deterministicMessageID(
            namespace: "kit-group-member-event:\(conversationID):\(type):\(resourceID):\(eventID)"
        )
        // The backup contract requires isOutgoing to agree with local authorship, so a change
        // performed by this account (possibly from a companion device) is projected as outgoing.
        let senderID = actorUserID ?? subjectUserID.lowercased()
        let authoredOnCurrentAccount = senderID == currentUserID
        let systemMessage = LocalMessage(
            id: messageID,
            conversationId: conversationID,
            senderId: senderID,
            body: descriptor.encoded,
            createdAt: occurredAt,
            sentAt: occurredAt,
            state: authoredOnCurrentAccount ? .sent : .received,
            failureReason: nil,
            isOutgoing: authoredOnCurrentAccount
        )
        return GroupMemberTransition(
            conversationID: conversationID,
            subjectUserID: subjectUserID.lowercased(),
            role: role,
            kind: kind,
            systemMessage: systemMessage
        )
    }

    private func validatedGroupRoleChange(
        _ event: MessagingSyncEventDTO,
        type: String
    ) throws -> (
        conversationID: String,
        subjectUserID: String,
        role: MessagingGroupRole
    ) {
        guard type == "membership.role_changed",
              let conversationID = event.conversationId,
              event.resourceType == "conversation_member",
              event.resourceId?.isEmpty == false,
              let data = event.data,
              let userID = data.userId,
              SecureMessagingValidation.isCanonicalUUID(userID),
              let role = data.role.flatMap(MessagingGroupRole.init(rawValue:)),
              data.actorUserId == nil
        else { throw SecureMessagingExchangeError.invalidServerResponse }
        return (conversationID, userID.lowercased(), role)
    }

    private func validateDeviceLifecycle(
        _ event: MessagingSyncEventDTO
    ) throws -> ValidatedDeviceLifecycle {
        guard event.resourceType == "messaging_device",
              let data = event.data,
              let deviceID = data.deviceId,
              event.resourceId == deviceID,
              SecureMessagingValidation.isCanonicalUUID(deviceID),
              let userID = data.userId,
              SecureMessagingValidation.isCanonicalUUID(userID),
              let signalDeviceID = data.signalDeviceId,
              (1...127).contains(signalDeviceID),
              let enrollmentEpoch = data.enrollmentEpoch,
              enrollmentEpoch > 0,
              let registrationID = data.registrationId,
              (1...16_380).contains(registrationID),
              data.protocolVersion == SecureMessagingWire.protocolVersion,
              let bundleVersion = data.bundleVersion,
              bundleVersion > 0,
              let identityHash = data.identityKeySha256,
              SecureMessagingValidation.isSHA256(identityHash),
              data.rosterRefreshRequired == true,
              let transitionHash = data.transitionHash,
              SecureMessagingValidation.isSHA256(transitionHash),
              parseServerDateIfValid(data.transitionedAt)
        else { throw SecureMessagingExchangeError.invalidServerResponse }
        if event.type == "identity.changed" {
            guard let previous = data.previousIdentityKeySha256,
                  SecureMessagingValidation.isSHA256(previous),
                  previous != identityHash
            else { throw SecureMessagingExchangeError.invalidServerResponse }
        }
        return ValidatedDeviceLifecycle(
            deviceID: deviceID,
            userID: userID,
            enrollmentEpoch: enrollmentEpoch,
            previousIdentityKeySHA256: data.previousIdentityKeySha256
        )
    }

    private func validateAllDevicesRevoked(
        _ event: MessagingSyncEventDTO,
        currentUserID: String
    ) throws -> String {
        guard event.resourceType == "messaging_user",
              let data = event.data,
              let userID = data.userId,
              event.resourceId == userID,
              SecureMessagingValidation.isCanonicalUUID(userID),
              userID != currentUserID,
              let count = data.revokedDeviceCount,
              count > 0,
              data.rosterRefreshRequired == true,
              let hash = data.transitionHash,
              SecureMessagingValidation.isSHA256(hash),
              parseServerDateIfValid(data.transitionedAt)
        else { throw SecureMessagingExchangeError.invalidServerResponse }
        return userID
    }

    private func canonicalUUID(
        _ rawValue: String?,
        error: SecureMessagingExchangeError
    ) throws -> String {
        guard let rawValue,
              let uuid = UUID(uuidString: rawValue.trimmingCharacters(in: .whitespacesAndNewlines))
        else { throw error }
        let value = uuid.uuidString.lowercased()
        guard SecureMessagingValidation.isCanonicalUUID(value) else { throw error }
        return value
    }

    private func parseServerDate(_ rawValue: String?) throws -> Date {
        guard let rawValue, let value = Self.serverDate(rawValue) else {
            throw SecureMessagingExchangeError.invalidServerResponse
        }
        return value
    }

    private func parseServerDateIfValid(_ rawValue: String?) -> Bool {
        rawValue.flatMap(Self.serverDate) != nil
    }

    private nonisolated static func failedTextRetryCandidate(
        in state: PersistedState,
        messageID: UUID,
        userID: String,
        conversationID: String,
        recipientUserID: String
    ) throws -> FailedTextRetryCandidate {
        guard SecureMessagingValidation.isCanonicalUUID(userID),
              SecureMessagingValidation.isCanonicalUUID(conversationID),
              SecureMessagingValidation.isCanonicalUUID(recipientUserID),
              state.profile?.id == userID,
              state.communicationOwnerUserID == userID,
              state.secureMessaging?.enrollment?.userID == userID,
              userID != recipientUserID
        else { throw SecureMessagingExchangeError.messageNotRetryable }

        let conversations = state.conversations.filter { $0.id == conversationID }
        guard conversations.count == 1,
              let conversation = conversations.first,
              conversation.participantUserIds.count == 2,
              conversation.participantUserIds.allSatisfy(
                  SecureMessagingValidation.isCanonicalUUID
              ),
              Set(conversation.participantUserIds) == Set([userID, recipientUserID])
        else { throw SecureMessagingExchangeError.messageNotRetryable }

        let messages = state.messages.filter { $0.id == messageID }
        guard messages.count == 1,
              let message = messages.first,
              message.conversationId == conversationID,
              message.senderId == userID,
              message.isOutgoing,
              message.serverMessageId == nil,
              message.sentAt == nil,
              message.attachmentData == nil,
              message.pendingAttachment == nil,
              // A pending v2 batch shows its caption as body text; retrying it HERE would
              // send the caption alone and split the message. Media retries have their own
              // path that carries the whole batch.
              message.pendingMediaBatch == nil,
              message.secureMessagingHistory == nil
        else { throw SecureMessagingExchangeError.messageNotRetryable }
        let body = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty,
              body == message.body,
              body.unicodeScalars.count <= 8_000,
              !body.unicodeScalars.contains(where: { $0.value == 0 }),
              !body.hasPrefix(KitMediaMessageDescriptor.prefix),
              KitMediaMessageDescriptor.parse(body) == nil,
              // Family-wide, every version: a failed sealed KITMEDIA body — key material —
              // must never retry as plain text. `allowsUserAuthoredText` below now refuses
              // the family too; this line stays as the explicit media boundary so the intent
              // survives any future loosening of that shared policy. Media retries ride
              // `retryFailedMediaMessage` under the same client id.
              !KitMediaMessageFamilyPolicy.isReservedFamilyText(body),
              SecureMessageReservedPrefixPolicy.allowsUserAuthoredText(body)
        else { throw SecureMessagingExchangeError.messageNotRetryable }

        let relatedCommands = state.outbox.filter {
            $0.id == messageID || $0.messageId == messageID
        }
        if relatedCommands.isEmpty {
            guard message.state == .failed else {
                throw SecureMessagingExchangeError.messageNotRetryable
            }
            return FailedTextRetryCandidate(
                conversation: conversation,
                message: message,
                alreadyQueued: false
            )
        }

        guard relatedCommands.count == 1,
              let command = relatedCommands.first,
              state.outbox.filter({ $0.id == command.id }).count == 1,
              message.state == .queued,
              message.failureReason == nil,
              command.kind == .secureMessage,
              command.createdAt == message.createdAt,
              command.attemptCount >= 0,
              command.conversationId == conversationID,
              command.messageId == messageID,
              command.recipientUserIds == [recipientUserID],
              command.video == nil,
              command.expiresAt == nil,
              command.callId == nil,
              command.terminationKind == nil,
              command.terminationReason == nil,
              command.failureDisposition == nil,
              command.lastFailureReason == nil,
              command.secureMessageFanout.map({
                  $0.clientMessageID == messageID.uuidString.lowercased()
                      && $0.conversationID == conversationID
              }) ?? true
        else { throw SecureMessagingExchangeError.messageNotRetryable }
        return FailedTextRetryCandidate(
            conversation: conversation,
            message: message,
            alreadyQueued: true
        )
    }

    private nonisolated static func failedMediaMessageRetryCandidate(
        in state: PersistedState,
        messageID: UUID,
        userID: String,
        conversationID: String,
        expectedRecipientUserID: String?
    ) throws -> FailedMediaMessageRetryCandidate {
        guard SecureMessagingValidation.isCanonicalUUID(userID),
              SecureMessagingValidation.isCanonicalUUID(conversationID),
              expectedRecipientUserID.map(SecureMessagingValidation.isCanonicalUUID) ?? true,
              expectedRecipientUserID != userID,
              state.profile?.id == userID,
              state.communicationOwnerUserID == userID,
              state.secureMessaging?.enrollment?.userID == userID
        else { throw SecureMessagingExchangeError.messageNotRetryable }

        let conversations = state.conversations.filter { $0.id == conversationID }
        guard conversations.count == 1,
              let conversation = conversations.first,
              conversation.participantUserIds.allSatisfy(
                  SecureMessagingValidation.isCanonicalUUID
              ),
              permitsDeferredQueue(
                  conversation: conversation,
                  localUserID: userID,
                  expectedRecipientUserID: expectedRecipientUserID
              )
        else { throw SecureMessagingExchangeError.messageNotRetryable }
        let recipientUserIDs = deferredCommandRecipients(
            conversation: conversation,
            localUserID: userID,
            expectedRecipientUserID: expectedRecipientUserID
        )

        let messages = state.messages.filter { $0.id == messageID }
        guard messages.count == 1,
              let message = messages.first,
              message.conversationId == conversationID,
              message.senderId == userID,
              message.isOutgoing,
              message.serverMessageId == nil,
              message.sentAt == nil,
              message.attachmentData == nil,
              message.pendingAttachment == nil,
              message.secureMessagingHistory == nil
        else { throw SecureMessagingExchangeError.messageNotRetryable }
        // The projection must be one whole v2 message: a structurally valid pending batch
        // bound to its canonical caption-or-placeholder body, or a sealed descriptor body
        // with no leftover pending state. Anything else is not this path's to retry.
        if let batch = message.pendingMediaBatch {
            guard batch.isStructurallyValid,
                  message.body == (batch.caption
                      ?? mediaBatchPlaceholderBody(itemCount: batch.items.count))
            else { throw SecureMessagingExchangeError.messageNotRetryable }
        } else {
            guard KitMediaMessageV2Descriptor.parse(message.body) != nil else {
                throw SecureMessagingExchangeError.messageNotRetryable
            }
        }

        let relatedCommands = state.outbox.filter {
            $0.id == messageID || $0.messageId == messageID
        }
        if relatedCommands.isEmpty {
            // Without a retained command the original audience is not durably known: a group
            // roster may have changed since the failed attempt, so minting a fresh command
            // from current membership could silently widen or narrow who receives this client
            // message ID. A direct thread's audience is structural — the one pinned peer — so
            // only it may mint here; a group message retries solely through its retained
            // command and that command's pinned recipient list.
            guard message.state == .failed, !conversation.isGroup else {
                throw SecureMessagingExchangeError.messageNotRetryable
            }
            return FailedMediaMessageRetryCandidate(
                conversation: conversation,
                message: message,
                recipientUserIDs: recipientUserIDs,
                alreadyQueued: false
            )
        }

        guard relatedCommands.count == 1,
              let command = relatedCommands.first,
              state.outbox.filter({ $0.id == command.id }).count == 1,
              message.state == .queued,
              message.failureReason == nil,
              command.kind == .secureMessage,
              command.createdAt == message.createdAt,
              command.attemptCount >= 0,
              command.conversationId == conversationID,
              command.messageId == messageID,
              command.recipientUserIds == recipientUserIDs,
              command.video == nil,
              command.expiresAt == nil,
              command.callId == nil,
              command.terminationKind == nil,
              command.terminationReason == nil,
              command.failureDisposition == nil,
              command.lastFailureReason == nil,
              // A live scheduled command still carries the message's promised minute; a
              // user-retried one sends immediately and carries none.
              command.scheduledAt.map({ $0 == message.scheduledAt }) ?? true,
              command.secureMessageFanout.map({
                  $0.clientMessageID == messageID.uuidString.lowercased()
                      && $0.conversationID == conversationID
              }) ?? true
        else { throw SecureMessagingExchangeError.messageNotRetryable }
        return FailedMediaMessageRetryCandidate(
            conversation: conversation,
            message: message,
            recipientUserIDs: recipientUserIDs,
            alreadyQueued: true
        )
    }

    private static func serverDate(_ rawValue: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: rawValue) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: rawValue)
    }

    private static func upsert(
        conversation: Conversation,
        in state: inout PersistedState,
        advancesActivity: Bool = true
    ) {
        if conversation.isGroup {
            guard serverProjectionIsNotOlder(
                conversationID: conversation.id,
                updatedAt: conversation.updatedAt,
                in: state
            ) else { return }
        }
        if let index = state.conversations.firstIndex(where: { $0.id == conversation.id }) {
            state.conversations[index].title = conversation.title
            state.conversations[index].participantUserIds = conversation.participantUserIds
            if let conversationType = conversation.conversationType {
                state.conversations[index].conversationType = conversationType
            }
            state.conversations[index].groupMemberRoles = conversation.groupMemberRoles
            if advancesActivity {
                state.conversations[index].updatedAt = max(
                    state.conversations[index].updatedAt,
                    conversation.updatedAt
                )
            }
        } else {
            state.conversations.append(conversation)
        }
        if conversation.isGroup {
            recordServerProjection(
                conversationID: conversation.id,
                updatedAt: conversation.updatedAt,
                in: &state
            )
        }
    }

    /// `Conversation.updatedAt` is visible activity and deliberately does not advance for
    /// reaction-only sync. This separate group clock makes title/roster replacement monotonic
    /// without moving a quiet thread in the chat list. A missing clock is a pre-Build-24 state and
    /// accepts its first authenticated projection; every later writer compares atomically inside
    /// the same encrypted-store transaction.
    private static func serverProjectionIsNotOlder(
        conversationID: String,
        updatedAt: Date,
        in state: PersistedState
    ) -> Bool {
        guard let current = state.groupProjectionUpdatedAt?[conversationID] else {
            return true
        }
        return updatedAt >= current
    }

    private static func recordServerProjection(
        conversationID: String,
        updatedAt: Date,
        in state: inout PersistedState
    ) {
        var timestamps = state.groupProjectionUpdatedAt ?? [:]
        timestamps[conversationID] = max(timestamps[conversationID] ?? updatedAt, updatedAt)
        state.groupProjectionUpdatedAt = timestamps
    }
}

private struct FailedTextRetryCandidate {
    let conversation: Conversation
    let message: LocalMessage
    let alreadyQueued: Bool
}

private struct FailedMediaMessageRetryCandidate {
    let conversation: Conversation
    let message: LocalMessage
    let recipientUserIDs: [String]
    let alreadyQueued: Bool
}

/// Validated projection of a direct OR group conversation DTO. Minimal-ripple design: the struct
/// keeps its historical name and shape; `recipientUserID` became Optional and is nil ONLY for
/// groups, so every direct-only consumer must `guard let` it (fail closed) while group-capable
/// paths address the full `memberUserIDs` set instead.
private struct ValidatedDirectConversation {
    let id: String
    /// The single peer of a direct thread. Always nil for groups — a group has no "the" recipient.
    let recipientUserID: String?
    let memberUserIDs: Set<String>
    let title: String
    let updatedAt: Date
    let conversationType: String
    let groupMemberRoles: [String: MessagingGroupRole]?
    /// Server-visible group identity; always nil for a direct thread, which discloses nothing.
    let groupDescription: String?
    let groupPhotoURL: String?

    var isGroup: Bool { conversationType == SecureMessagingWire.groupConversationType }

    /// Canonical outbox recipient list: the single direct peer, or every group member but self.
    func outboundRecipientUserIDs(excluding localUserID: String) -> [String] {
        if let recipientUserID { return [recipientUserID] }
        return memberUserIDs.filter { $0 != localUserID }.sorted()
    }

    var localProjection: Conversation {
        Conversation(
            id: id,
            title: title,
            participantUserIds: memberUserIDs.sorted(),
            unreadCount: 0,
            updatedAt: updatedAt,
            conversationType: conversationType,
            groupMemberRoles: groupMemberRoles,
            groupDescription: groupDescription,
            groupPhotoURL: groupPhotoURL
        )
    }
}

private struct ValidatedHistoryCandidate {
    let dto: EncryptedMessageDTO
    let identity: SecureMessagingHistoryMessageIdentity
    let validatedSender: SecureMessagingValidatedHistoricalSender
    let rawSentAt: String
}

private struct ValidatedHistoryBackfillPage {
    let conversation: ValidatedDirectConversation
    let roster: SecureMessagingRosterSnapshot
    let target: SecureMessagingRosterDevice
    let candidates: [ValidatedHistoryCandidate]
    let nextCursor: String?
    let hasMore: Bool
}

private struct OutboundEcho {
    let clientMessageID: String
    let serverMessageID: String
    let sentAt: Date
    let historyMetadata: SecureMessagingRetainedMessageMetadata
}

private struct DeliveryTransition {
    let messageID: String
    let deliveredAt: Date
}

private struct ReadTransition {
    let conversationID: String
    let messageID: String
    let readAt: Date
}

private struct GroupMemberTransition {
    let conversationID: String
    let subjectUserID: String
    let role: MessagingGroupRole?
    let kind: KitSystemMessage.Kind
    let systemMessage: LocalMessage
}

private enum GroupPaymentRequestSyncAction {
    case created
    case contributed
    case completed
    case cancelled
    case expired

    init?(eventType: String) {
        switch eventType {
        case "group_payment_request.created": self = .created
        case "group_payment_request.contributed": self = .contributed
        case "group_payment_request.completed": self = .completed
        case "group_payment_request.cancelled": self = .cancelled
        case "group_payment_request.expired": self = .expired
        default: return nil
        }
    }
}

private struct GroupPaymentRequestSyncEnvelope {
    let action: GroupPaymentRequestSyncAction
    let requestID: String
    let conversationID: String
    let requesterUserID: String
    let status: GroupPaymentRequestStatus
    let targetAmountMinor: Int64
    let contributedAmountMinor: Int64
    let remainingAmountMinor: Int64
    let currencyCode: String
    let currencyScale: Int
    let progressBasisPoints: Int
    let contributionID: String?
    let contributorUserID: String?
    let contributionAmountMinor: Int64?
    let occurredAt: Date
}

private struct GroupPaymentRequestSyncTransition {
    let conversationID: String
    let message: LocalMessage
}

private struct ScheduledPaymentSyncTransition {
    let conversationID: String
    let message: LocalMessage
}

private struct ScheduledGroupPaymentSyncTransition {
    let conversationID: String
    let message: LocalMessage
}

private struct ValidatedDeviceLifecycle {
    let deviceID: String
    let userID: String
    let enrollmentEpoch: Int64
    let previousIdentityKeySHA256: String?
}

private extension SecureMessagingEnrollmentBinding {
    var address: SecureMessagingAddress {
        SecureMessagingAddress(
            userID: userID,
            serverDeviceID: serverDeviceID,
            signalDeviceID: signalDeviceID
        )
    }
}

private extension EncryptedMessageDTO {
    init(syncData data: MessagingSyncEventDataDTO) {
        self.init(
            id: data.id,
            conversationId: data.conversationId,
            clientMessageId: data.clientMessageId,
            sender: data.sender,
            senderDeviceId: data.senderDeviceId,
            senderEnrollmentEpoch: data.senderEnrollmentEpoch,
            senderSignalDeviceId: data.senderSignalDeviceId,
            senderRegistrationId: data.senderRegistrationId,
            senderProtocolVersion: data.senderProtocolVersion,
            senderBundleVersion: data.senderBundleVersion,
            senderIdentityKeySha256: data.senderIdentityKeySha256,
            rosterRevision: data.rosterRevision,
            kind: data.kind,
            replyToMessageId: data.replyToMessageId,
            envelope: data.envelope,
            attachments: data.attachments,
            reactions: data.reactions,
            sentAt: data.sentAt,
            revokedAt: data.revokedAt
        )
    }
}
