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
}

extension SecureMessagingExchangeTransport {
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
}

extension APIClient: SecureMessagingExchangeTransport {}

enum SecureMessagingExchangeError: LocalizedError, Equatable {
    case invalidAccount
    case invalidRecipient
    case invalidConversation
    case invalidServerResponse
    case unsupportedEvent(String)
    case staleOutboundFanout
    case retryLimitExceeded

    var errorDescription: String? {
        switch self {
        case .invalidAccount: "Your messaging account changed. Sign in again to continue."
        case .invalidRecipient: "Choose one valid Kit Pay recipient."
        case .invalidConversation: "This conversation is no longer available."
        case .invalidServerResponse: "Kit could not load this conversation. Please try again."
        case .unsupportedEvent: "Kit could not process a message update. Please try again."
        case .staleOutboundFanout: "The recipient's devices changed. Retry the message."
        case .retryLimitExceeded: "Messages changed while syncing. Please try again."
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
    var copy: @Sendable (_ fromKey: String, _ toKey: String, _ userID: String) async throws -> Void
    var remove: @Sendable (_ storageKey: String, _ userID: String) async -> Void

    static let fileCache = SecureMediaBlobStoreAccess(
        read: { key, userID in
            await SecureMediaFileCache.shared.data(forStorageKey: key, userID: userID)
        },
        copy: { fromKey, toKey, userID in
            guard let data = await SecureMediaFileCache.shared.data(
                forStorageKey: fromKey,
                userID: userID
            ) else { throw SecureMediaAttachmentError.invalidMedia }
            try await SecureMediaFileCache.shared.store(
                data,
                forStorageKey: toKey,
                userID: userID
            )
            guard let copied = await SecureMediaFileCache.shared.data(
                forStorageKey: toKey,
                userID: userID
            ), copied == data else {
                await SecureMediaFileCache.shared.remove(
                    forStorageKey: toKey,
                    userID: userID
                )
                throw SecureMediaAttachmentError.invalidMedia
            }
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
            let competingDirectThreads = state.conversations.filter {
                Set($0.participantUserIds.map { $0.lowercased() }) == validated.memberUserIDs
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
                    updatedAt: max(existing.updatedAt, projection.updatedAt)
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
               recipientUserID: recipient,
               conversation: validated.localProjection,
               body: body
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
    func queueDeferredText(
        forUserID userID: String,
        conversationID: String,
        expectedRecipientUserID: String,
        title: String,
        text: String,
        clientMessageID: UUID? = nil,
        submittedDraftBody: String? = nil,
        draftClearVersion: ConversationDraftWriteVersion? = nil,
        commitAdmission: ProtectedCommunicationAdmissionLease? = nil
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
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty,
              body.unicodeScalars.count <= 8_000,
              !body.unicodeScalars.contains(where: { $0.value == 0 }),
              KitMediaMessageDescriptor.parse(body) == nil
        else { throw SecureMessagingCryptoError.invalidContent }
        let snapshot = await store.snapshot()
        guard snapshot.profile?.id == local,
              snapshot.secureMessaging?.enrollment?.userID == local,
              let conversation = snapshot.conversations.first(where: {
                  $0.id == conversationID
              }),
              conversation.participantUserIds.count == 2,
              Set(conversation.participantUserIds) == Set([local, recipient])
        else { throw SecureMessagingExchangeError.invalidConversation }
        if let clientMessageID,
           let existing = try Self.existingDeferredTextResult(
               in: snapshot,
               clientMessageID: clientMessageID,
               localUserID: local,
               recipientUserID: recipient,
               conversation: conversation,
               body: body
           ) {
            return existing
        }

        let messageID = clientMessageID ?? UUID()
        let commandID = UUID()
        let createdAt = Date()
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
            isOutgoing: true
        )
        let command = OfflineCommand(
            id: commandID,
            kind: .secureMessage,
            createdAt: createdAt,
            nextAttemptAt: createdAt,
            attemptCount: 0,
            conversationId: conversationID,
            messageId: messageID,
            recipientUserIds: [recipient],
            recipientName: cleanTitle.isEmpty ? conversation.title : cleanTitle,
            video: nil,
            expiresAt: nil,
            secureMessageFanout: nil
        )
        var updatedConversation = conversation
        updatedConversation.updatedAt = createdAt
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
                      racedConversation.participantUserIds.count == 2,
                      Set(racedConversation.participantUserIds) == Set([local, recipient]),
                      let existing = try Self.existingDeferredTextResult(
                          in: raced,
                          clientMessageID: clientMessageID,
                          localUserID: local,
                          recipientUserID: recipient,
                          conversation: racedConversation,
                          body: body
                      )
                else { throw StoreError.accountChanged }
                return existing
            }
            throw StoreError.accountChanged
        }
        return SecureMessagingQueueResult(
            conversation: queuedConversation,
            clientMessageID: messageID
        )
    }

    private static func existingDeferredTextResult(
        in state: PersistedState,
        clientMessageID: UUID,
        localUserID: String,
        recipientUserID: String,
        conversation: Conversation,
        body: String
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
              message.attachmentData == nil,
              message.pendingAttachment == nil
        else { throw SecureMessagingExchangeError.invalidConversation }

        if let command = commands.first {
            guard command.kind == .secureMessage,
                  command.conversationId == conversation.id,
                  command.recipientUserIds == [recipientUserID]
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
        expectedRecipientUserID: String,
        title: String,
        mediaData: Data,
        mediaType: String,
        caption: String?,
        localStorageKey: String? = nil,
        clientMessageID: UUID? = nil,
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
              conversation.participantUserIds.count == 2,
              Set(conversation.participantUserIds) == Set([local, recipient])
        else { throw SecureMessagingExchangeError.invalidConversation }
        // No network at queue time: the offline path must succeed in airplane mode. The rich-media
        // recipient-capability gate still runs authoritatively at flush (prepareDeferredMessage)
        // and again per-encrypt in queueText before any bytes leave the device.
        _ = enrollment

        if let clientMessageID {
            let canonicalClientID = clientMessageID
            if let existing = snapshot.messages.first(where: { $0.id == canonicalClientID }),
               existing.conversationId == conversationID {
                // A retry of the same queue attempt (double-tap, caller-side retry) reuses the
                // durable message instead of minting a duplicate — including after the flush
                // pipeline already checkpointed it (pendingAttachment cleared).
                return SecureMessagingQueueResult(
                    conversation: conversation,
                    clientMessageID: canonicalClientID
                )
            }
        }

        let messageID = clientMessageID ?? UUID()
        let commandID = UUID()
        let createdAt = Date()
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
            )
        )
        let command = OfflineCommand(
            id: commandID,
            kind: .secureMessage,
            createdAt: createdAt,
            nextAttemptAt: createdAt,
            attemptCount: 0,
            conversationId: conversationID,
            messageId: messageID,
            recipientUserIds: [recipient],
            recipientName: cleanTitle.isEmpty ? conversation.title : cleanTitle,
            video: nil,
            expiresAt: nil,
            secureMessageFanout: nil
        )
        var updatedConversation = conversation
        updatedConversation.updatedAt = createdAt
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
              recipients.count == 1,
              let recipient = recipients.first,
              message.conversationId == conversationID,
              message.senderId == local
        else { throw SecureMessagingExchangeError.invalidConversation }
        var ownedMessage = message
        do {
            let dto = try await transport.messagingConversation(id: conversationID)
            let conversation = try validateConversation(
                dto,
                currentUserID: local,
                expectedRecipientUserID: recipient,
                fallbackTitle: command.recipientName ?? "Kit Pay contact"
            )
            try await requireExactPendingProjection(
                command,
                message: message,
                forUserID: local
            )
            var preparedMessage = message
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
                if KitChatMediaKind(mediaType: pending.mediaType) != .image {
                    guard let enrollment = snapshot.secureMessaging?.enrollment else {
                        throw SecureMessagingExchangeError.invalidAccount
                    }
                    let roster = try await transport.messagingDeviceRoster(
                        conversationId: conversationID
                    )
                    guard MessagingRichMediaCapabilityPolicy.supports(
                        mediaType: pending.mediaType,
                        roster: roster,
                        conversationID: conversationID,
                        currentDeviceID: enrollment.serverDeviceID,
                        recipientUserID: recipient
                    ) else { throw SecureMediaAttachmentError.incompatibleRecipient }
                }
                _ = try await activation.activate(forUserID: local)
                let descriptor = try await uploadMediaDescriptor(
                    mediaData: mediaData,
                    mediaType: pending.mediaType,
                    caption: pending.caption
                )
                if let localKey = pending.localStorageKey {
                    // Copy-then-checkpoint-then-remove: the pending projection stays consistent
                    // at every step, and a failed checkpoint removes the copy again so the only
                    // blob left is the still-referenced parked original.
                    try await mediaBlobs.copy(localKey, descriptor.storageKey, local)
                }
                do {
                    preparedMessage = try await checkpointDeferredImageDescriptor(
                        descriptor,
                        command: command,
                        message: message,
                        forUserID: local
                    )
                } catch {
                    if pending.localStorageKey != nil {
                        await mediaBlobs.remove(descriptor.storageKey, local)
                    }
                    throw error
                }
                if let localKey = pending.localStorageKey {
                    await mediaBlobs.remove(localKey, local)
                }
                ownedMessage = preparedMessage
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
                    ?? KitMediaMessageDescriptor.parse(preparedMessage.body)?.mediaType
            )
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
        if KitChatMediaKind(mediaType: mediaType) != .image {
            let snapshot = await store.snapshot()
            guard snapshot.profile?.id == local,
                  let enrollment = snapshot.secureMessaging?.enrollment,
                  enrollment.userID == local
            else { throw SecureMessagingExchangeError.invalidAccount }
            let roster = try await transport.messagingDeviceRoster(conversationId: conversationID)
            guard MessagingRichMediaCapabilityPolicy.supports(
                mediaType: mediaType,
                roster: roster,
                conversationID: conversationID,
                currentDeviceID: enrollment.serverDeviceID,
                recipientUserID: recipient
            ) else { throw SecureMediaAttachmentError.incompatibleRecipient }
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
            requiredRichMediaType: mediaType
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

    func openImage(
        forUserID userID: String,
        conversationID: String,
        descriptorText: String
    ) async throws -> Data {
        let local = try canonicalUUID(userID, error: .invalidAccount)
        let conversationID = try canonicalUUID(conversationID, error: .invalidConversation)
        let snapshot = await store.snapshot()
        guard snapshot.profile?.id == local,
              snapshot.messages.contains(where: {
                  $0.conversationId == conversationID && $0.body == descriptorText
              }),
              let descriptor = KitMediaMessageDescriptor.parse(descriptorText),
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
        requiredRichMediaType: String? = nil
    ) async throws -> SecureMessagingQueueResult {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw SecureMessagingCryptoError.invalidContent }
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
            if let newClientMessageID,
               let existing = try Self.existingDeferredTextResult(
                   in: snapshot,
                   clientMessageID: newClientMessageID,
                   localUserID: userID,
                   recipientUserID: conversation.recipientUserID,
                   conversation: conversation.localProjection,
                   body: body
               ) {
                return existing
            }

            let rosterDTO = try await transport.messagingDeviceRoster(
                conversationId: conversation.id
            )
            if let requiredRichMediaType,
               KitChatMediaKind(mediaType: requiredRichMediaType) != .image,
               !MessagingRichMediaCapabilityPolicy.supports(
                   mediaType: requiredRichMediaType,
                   roster: rosterDTO,
                   conversationID: conversation.id,
                   currentDeviceID: enrollment.serverDeviceID,
                   recipientUserID: conversation.recipientUserID
               ) {
                throw SecureMediaAttachmentError.incompatibleRecipient
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
                replyToMessageID: nil,
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
                attachmentData: attachmentData
            )
            let command = OfflineCommand(
                id: commandID,
                kind: .secureMessage,
                createdAt: now,
                nextAttemptAt: now,
                attemptCount: existingCommand?.attemptCount ?? 0,
                conversationId: conversation.id,
                messageId: clientMessageID,
                recipientUserIds: [conversation.recipientUserID],
                recipientName: conversation.title,
                video: nil,
                expiresAt: nil,
                secureMessageFanout: encrypted.fanout
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
        let attachments = KitMediaMessageDescriptor.attachments(for: localMessage.body)

        do {
            let response = try await transport.sendEncryptedMessage(
                conversationId: fanout.conversationID,
                request: try SecureMessagingMapper.sendRequest(
                    from: fanout,
                    attachments: attachments
                )
            )
            let outbound = try validateOutboundResponse(
                response,
                fanout: fanout,
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
        } catch let error as APIErrorPayload where [
            "MESSAGING_ROSTER_CHANGED",
            "DEVICE_ENVELOPES_INCOMPLETE",
            "MESSAGING_ROSTER_PROTOCOL_MISMATCH",
        ].contains(error.code) {
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
                       message.state == .received {
                        count += 1
                    }
                }
            }
        }
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
            guard type == SecureMessagingWire.directConversationType else { continue }
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
        let candidates = try rawMessages.compactMap { raw -> ValidatedHistoryCandidate? in
            guard let raw, let rawSentAt = raw.sentAt else {
                throw SecureMessagingExchangeError.invalidServerResponse
            }
            let identity = try SecureMessagingMapper.historyCandidateIdentity(
                from: raw,
                expectedConversationID: conversation.id
            )
            guard conversation.memberUserIDs.contains(identity.senderUserID),
                  seen.insert(identity.messageID).inserted
            else { throw SecureMessagingExchangeError.invalidServerResponse }
            return ValidatedHistoryCandidate(
                dto: raw,
                identity: identity,
                rawSentAt: rawSentAt
            )
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
        guard let metadata = retained.secureMessagingHistory else { return nil }
        let expectedAttachments = KitMediaMessageDescriptor.attachments(for: retained.body)
        let expectedKind: SecureMessagingMessageKind = expectedAttachments.isEmpty
            ? .encrypted
            : .encryptedAttachment
        guard metadata == candidate.identity.retainedMetadata,
              retained.conversationId == candidate.identity.conversationID,
              retained.senderId == candidate.identity.senderUserID,
              retained.isOutgoing == (candidate.identity.senderUserID == currentUserID),
              let sentAt = retained.sentAt,
              SecureMessagingHistoryBackfillCodec.sameMillisecond(
                  sentAt,
                  candidate.identity.sentAt
              ),
              expectedKind == candidate.identity.kind,
              (!retained.body.hasPrefix(KitMediaMessageDescriptor.prefix)
                  || !expectedAttachments.isEmpty),
              KitMediaMessageDescriptor.validates(
                  candidate.dto.attachments,
                  against: expectedAttachments
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
            let descriptor = try SecureMessagingHistoryBackfillCodec.encode(
                transferClientMessageID: transferID,
                targetDeviceID: task.targetDeviceID,
                targetEnrollmentEpoch: task.targetEnrollmentEpoch,
                transferRosterRevision: page.roster.rosterRevision,
                candidate: candidate.identity,
                rawSentAt: candidate.rawSentAt,
                retained: currentRetained
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
            return .authenticated(try SecureMessagingHistoryBackfillCodec.authenticate(
                descriptor,
                incoming: incoming
            ))
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

        let attachments = KitMediaMessageDescriptor.attachments(for: plaintext)
        let isAttachment = !attachments.isEmpty
        guard dto.kind == (isAttachment
                  ? SecureMessagingMessageKind.encryptedAttachment.rawValue
                  : SecureMessagingMessageKind.encrypted.rawValue),
              (!SecureMessageReservedPrefixPolicy.beginsWithReservedPrefix(
                  plaintext,
                  prefix: KitMediaMessageDescriptor.prefix
              ) || isAttachment),
              KitMediaMessageDescriptor.validates(dto.attachments, against: attachments)
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
                senderDeviceID: envelope.sender.address.serverDeviceID,
                senderEnrollmentEpoch: senderEnrollmentEpoch,
                senderSignalDeviceID: envelope.sender.address.signalDeviceID,
                rosterRevision: envelope.rosterRevision,
                kind: isAttachment ? .encryptedAttachment : .encrypted,
                replyToMessageID: envelope.replyToMessageID
            )
        )
    }

    nonisolated static func reconcileRecoveredHistoryMessages(
        _ recovered: [LocalMessage],
        currentDeviceID: String,
        into state: inout PersistedState
    ) {
        guard SecureMessagingValidation.isCanonicalUUID(currentDeviceID) else { return }
        for message in recovered {
            guard let historyMetadata = message.secureMessagingHistory else { continue }
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
                      state.messages[index].secureMessagingHistory.map({
                          $0 == historyMetadata
                      }) ?? true
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
                      state.messages[index].secureMessagingHistory.map({
                          $0 == historyMetadata
                      }) ?? true
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
                if let conversationIndex = state.conversations.firstIndex(where: {
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
            if let index = state.conversations.firstIndex(where: {
                $0.id == message.conversationId
            }) {
                state.conversations[index].updatedAt = max(
                    state.conversations[index].updatedAt,
                    message.createdAt
                )
            }
        }
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
            var acknowledgementIDs: [String] = []
            var transitionCount = 0
            var shouldReconcileHistoryTargets = false

            for event in events {
                let type = try validateEvent(event)
                switch type {
                case "conversation.created":
                    guard let conversationID = event.conversationId else {
                        throw SecureMessagingExchangeError.invalidServerResponse
                    }
                    let validated = try await loadConversation(
                        id: conversationID,
                        currentUserID: userID
                    )
                    conversations.append(validated.localProjection)
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
                    let conversation = try await loadConversation(
                        id: conversationID,
                        currentUserID: userID
                    )
                    conversations.append(conversation.localProjection)
                    if dto.envelope?.isHistoryBackfill == true {
                        guard [
                            SecureMessagingMessageKind.encrypted.rawValue,
                            SecureMessagingMessageKind.encryptedAttachment.rawValue,
                        ].contains(dto.kind),
                              dto.revokedAt == nil,
                              let transferRevision = dto.envelope?.transferRosterRevision
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
                            expectedMemberUserIDs: conversation.memberUserIDs
                        )
                        let historyEnvelope = try SecureMessagingMapper.historyInboundEnvelope(
                            from: dto,
                            localRecipient: enrollment.address,
                            localEnrollment: enrollment,
                            transferRoster: transferRoster
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
                                expectedAttachments: KitMediaMessageDescriptor.attachments(
                                    for: localMessage.body
                                ),
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
                        guard [
                            SecureMessagingMessageKind.encrypted.rawValue,
                            SecureMessagingMessageKind.encryptedAttachment.rawValue,
                        ].contains(dto.kind),
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
                            expectedMemberUserIDs: conversation.memberUserIDs
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

            do {
                try await store.commitSecureMessaging(
                    forUserID: userID,
                    expectedState: initialCrypto,
                    nextState: crypto
                ) { state in
                    conversations.forEach { Self.upsert(conversation: $0, in: &state) }
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
                        state.messages.append(message)
                        if let index = state.conversations.firstIndex(where: {
                            $0.id == message.conversationId
                        }) {
                            if !message.isOutgoing {
                                state.conversations[index].unreadCount += 1
                            }
                            state.conversations[index].updatedAt = max(
                                state.conversations[index].updatedAt,
                                message.createdAt
                            )
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

    private func validateConversation(
        _ dto: MessagingConversationDTO,
        currentUserID: String,
        expectedRecipientUserID: String?,
        fallbackTitle: String
    ) throws -> ValidatedDirectConversation {
        guard dto.type == SecureMessagingWire.directConversationType,
              let rawID = dto.id,
              let members = dto.members,
              members.count == 2,
              members.allSatisfy({ $0 != nil })
        else { throw SecureMessagingExchangeError.invalidConversation }
        let id = try canonicalUUID(rawID, error: .invalidConversation)
        let values = members.compactMap { $0 }
        let memberIDs = try Set(values.map {
            try canonicalUUID($0.userId, error: .invalidConversation)
        })
        guard memberIDs.count == 2,
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
        let updatedAt = (try? parseServerDate(dto.updatedAt)) ?? Date()
        return ValidatedDirectConversation(
            id: id,
            recipientUserID: recipient,
            memberUserIDs: memberIDs,
            title: title,
            updatedAt: updatedAt
        )
    }

    private func validateOutboundResponse(
        _ dto: EncryptedMessageDTO,
        fanout: SecureMessagingCommittedFanout,
        expectedAttachments: [EncryptedAttachmentRequest],
        userID: String,
        enrollment: SecureMessagingEnrollmentBinding?
    ) throws -> OutboundEcho {
        guard let enrollment,
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
              dto.kind == (expectedAttachments.isEmpty
                  ? SecureMessagingMessageKind.encrypted.rawValue
                  : SecureMessagingMessageKind.encryptedAttachment.rawValue),
              dto.replyToMessageId == fanout.replyToMessageID,
              dto.envelope == nil,
              KitMediaMessageDescriptor.validates(
                  dto.attachments,
                  against: expectedAttachments
              ),
              dto.revokedAt == nil
        else { throw SecureMessagingExchangeError.invalidServerResponse }
        return OutboundEcho(
            clientMessageID: fanout.clientMessageID,
            serverMessageID: id,
            sentAt: try parseServerDate(dto.sentAt),
            historyMetadata: SecureMessagingRetainedMessageMetadata(
                clientMessageID: fanout.clientMessageID,
                senderDeviceID: enrollment.serverDeviceID,
                senderEnrollmentEpoch: enrollment.enrollmentEpoch,
                senderSignalDeviceID: enrollment.signalDeviceID,
                rosterRevision: fanout.rosterRevision,
                kind: expectedAttachments.isEmpty ? .encrypted : .encryptedAttachment,
                replyToMessageID: fanout.replyToMessageID
            )
        )
    }

    private func validateOutboundEcho(
        _ dto: EncryptedMessageDTO,
        conversation: ValidatedDirectConversation,
        enrollment: SecureMessagingEnrollmentBinding,
        expectedAttachments: [EncryptedAttachmentRequest],
        userID: String
    ) throws -> OutboundEcho {
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
              dto.kind == (expectedAttachments.isEmpty
                  ? SecureMessagingMessageKind.encrypted.rawValue
                  : SecureMessagingMessageKind.encryptedAttachment.rawValue),
              dto.replyToMessageId.map(SecureMessagingWirePolicy.isCanonicalUUID) ?? true,
              dto.envelope == nil,
              KitMediaMessageDescriptor.validates(
                  dto.attachments,
                  against: expectedAttachments
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
                senderDeviceID: enrollment.serverDeviceID,
                senderEnrollmentEpoch: enrollment.enrollmentEpoch,
                senderSignalDeviceID: enrollment.signalDeviceID,
                rosterRevision: dto.rosterRevision!,
                kind: expectedAttachments.isEmpty ? .encrypted : .encryptedAttachment,
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
              (dto.kind == SecureMessagingMessageKind.encrypted.rawValue
                  && attachments.isEmpty)
                || (dto.kind == SecureMessagingMessageKind.encryptedAttachment.rawValue
                    && attachments.count == 1),
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

    private static func serverDate(_ rawValue: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: rawValue) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: rawValue)
    }

    private static func upsert(conversation: Conversation, in state: inout PersistedState) {
        if let index = state.conversations.firstIndex(where: { $0.id == conversation.id }) {
            state.conversations[index].title = conversation.title
            state.conversations[index].participantUserIds = conversation.participantUserIds
            state.conversations[index].updatedAt = max(
                state.conversations[index].updatedAt,
                conversation.updatedAt
            )
        } else {
            state.conversations.append(conversation)
        }
    }
}

private struct ValidatedDirectConversation {
    let id: String
    let recipientUserID: String
    let memberUserIDs: Set<String>
    let title: String
    let updatedAt: Date

    var localProjection: Conversation {
        Conversation(
            id: id,
            title: title,
            participantUserIds: memberUserIDs.sorted(),
            unreadCount: 0,
            updatedAt: updatedAt
        )
    }
}

private struct ValidatedHistoryCandidate {
    let dto: EncryptedMessageDTO
    let identity: SecureMessagingHistoryMessageIdentity
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
