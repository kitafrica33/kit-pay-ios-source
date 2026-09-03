import CryptoKit
import Foundation

actor SecureLocalStore {
    static let shared = SecureLocalStore()

    typealias StateDataLoad = @Sendable (URL) throws -> Data
    typealias StateDataPersist = @Sendable (Data, URL) throws -> Void
    typealias KeyDataLoad = @Sendable () throws -> Data?

    private enum StateLoadStatus: Equatable {
        case knownEmpty
        case loaded
        case temporarilyUnavailableExistingFile
        case invalidExistingFile
    }

    private struct StateLoadResult {
        let state: PersistedState
        let status: StateLoadStatus
    }

    private let keyAccount: String
    private let injectedKeyData: Data?
    private let stateDataLoad: StateDataLoad
    private let stateDataPersist: StateDataPersist
    private let keyDataLoad: KeyDataLoad
    private let stateURL: URL
    // Every stored property that feeds `snapshot()` bumps the projection revision, so a
    // publisher can reject a projection captured before a newer commit. This is the fix for
    // messages/conversations "disappearing": a snapshot captured, suspended across an await,
    // and then assigned to the UI must never roll back a newer publish.
    private var state: PersistedState {
        didSet { projectionRevision &+= 1 }
    }
    private var stateLoadStatus: StateLoadStatus {
        didSet { projectionRevision &+= 1 }
    }
    private var concealsStateForAcceptedDeletion = false {
        didSet { projectionRevision &+= 1 }
    }
    private var concealsStateForProtectedStateRecovery = false {
        didSet { projectionRevision &+= 1 }
    }
    private var projectionRevision: UInt64 = 0

    init(
        stateURL: URL? = nil,
        keyData: Data? = nil,
        keyAccount: String = "kit-pay-local-state-key-v1",
        stateDataLoad: @escaping StateDataLoad = { try Data(contentsOf: $0) },
        stateDataPersist: @escaping StateDataPersist = { data, url in
            try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        },
        keyDataLoad: KeyDataLoad? = nil
    ) {
        let resolvedKeyDataLoad: KeyDataLoad = keyDataLoad ?? {
            try KeychainStore.data(for: keyAccount)
        }
        self.keyAccount = keyAccount
        injectedKeyData = keyData
        self.stateDataLoad = stateDataLoad
        self.stateDataPersist = stateDataPersist
        self.keyDataLoad = resolvedKeyDataLoad
        let resolvedURL: URL
        if let stateURL {
            resolvedURL = stateURL
        } else {
            resolvedURL = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("KitPay", isDirectory: true)
                .appendingPathComponent("state.secure")
        }
        let root = resolvedURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var protectedRoot = root
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? protectedRoot.setResourceValues(resourceValues)
        self.stateURL = resolvedURL
        let loaded = Self.loadState(
            at: resolvedURL,
            injectedKeyData: keyData,
            stateDataLoad: stateDataLoad,
            keyDataLoad: resolvedKeyDataLoad
        )
        state = loaded.state
        stateLoadStatus = loaded.status
    }

    func snapshot() -> PersistedState {
        guard stateIsReadable,
              !concealsStateForAcceptedDeletion,
              !concealsStateForProtectedStateRecovery
        else { return .empty }
        return state
    }

    /// The snapshot together with a monotonic revision. Publishers must drop projections whose
    /// revision is older than the last one they applied — assigning a stale snapshot to the UI
    /// silently rolls back newer commits (sent bubbles, new conversations, inbound messages).
    func projection() -> SecureLocalStateProjection {
        SecureLocalStateProjection(state: snapshot(), revision: projectionRevision)
    }

    /// Retries only failures that occurred before authenticated ciphertext could be read. File
    /// protection and Keychain availability can change after device unlock; authenticated
    /// decryption/decoding failures remain terminal and are never reinterpreted as empty state.
    func prepareForRestore() -> SecureLocalStateReadiness {
        if stateLoadStatus == .temporarilyUnavailableExistingFile {
            let loaded = Self.loadState(
                at: stateURL,
                injectedKeyData: injectedKeyData,
                stateDataLoad: stateDataLoad,
                keyDataLoad: keyDataLoad
            )
            state = loaded.state
            stateLoadStatus = loaded.status
        }
        switch stateLoadStatus {
        case .knownEmpty, .loaded: return .ready
        case .temporarilyUnavailableExistingFile: return .temporarilyUnavailable
        case .invalidExistingFile: return .invalid
        }
    }

    func update(_ mutation: (inout PersistedState) throws -> Void) throws {
        try requireMutableState()
        var candidate = state
        try mutation(&candidate)
        try persist(candidate)
        state = candidate
    }

    func update(
        admission lease: ProtectedCommunicationAdmissionLease,
        _ mutation: (inout PersistedState) throws -> Void
    ) throws {
        try ProtectedCommunicationAdmissionGate.shared.withAuthorizedCommit(lease) {
            try requireMutableState()
            var candidate = state
            try mutation(&candidate)
            try persist(candidate)
            state = candidate
        }
    }

    /// Atomically compare-and-swaps the complete libsignal state together with any visible
    /// projection/outbox mutation. Detached crypto results can never overwrite a newer ratchet.
    func commitSecureMessaging(
        forUserID expectedUserID: String,
        expectedState: SecureMessagingPersistentState?,
        nextState: SecureMessagingPersistentState,
        admission lease: ProtectedCommunicationAdmissionLease? = nil,
        project: (inout PersistedState) throws -> Void = { _ in }
    ) throws {
        if let lease {
            try ProtectedCommunicationAdmissionGate.shared.withAuthorizedCommit(lease) {
                try commitSecureMessagingCandidate(
                    forUserID: expectedUserID,
                    expectedState: expectedState,
                    nextState: nextState,
                    project: project
                )
            }
            return
        }
        try commitSecureMessagingCandidate(
            forUserID: expectedUserID,
            expectedState: expectedState,
            nextState: nextState,
            project: project
        )
    }

    private func commitSecureMessagingCandidate(
        forUserID expectedUserID: String,
        expectedState: SecureMessagingPersistentState?,
        nextState: SecureMessagingPersistentState,
        project: (inout PersistedState) throws -> Void
    ) throws {
        try requireMutableState()
        var candidate = state
        guard candidate.profile?.id == expectedUserID else { throw StoreError.accountChanged }
        guard candidate.secureMessaging == expectedState else {
            throw SecureMessagingCryptoError.staleState
        }
        try project(&candidate)
        guard candidate.profile?.id == expectedUserID else { throw StoreError.accountChanged }
        guard candidate.secureMessaging == expectedState else {
            throw SecureMessagingCryptoError.staleState
        }
        var committedState = nextState
        try committedState.advanceTransactionRevision(after: expectedState ?? .empty)
        candidate.secureMessaging = committedState
        try persist(candidate)
        state = candidate
    }

    func replace(_ newState: PersistedState) throws {
        try requireMutableState()
        try persist(newState)
        state = newState
    }

    func clearFinancialAndSessionProjections(preserveCommunicationHistory: Bool) throws {
        try requireMutableState()
        let ownerUserID = state.communicationOwnerUserID ?? state.profile?.id
        var history = preserveCommunicationHistory ? state.messages : []
        let conversations = preserveCommunicationHistory ? state.conversations : []
        let groupProjectionUpdatedAt = preserveCommunicationHistory
            ? state.groupProjectionUpdatedAt
            : nil
        let conversationDrafts = preserveCommunicationHistory ? state.conversationDrafts : nil
        var calls = preserveCommunicationHistory ? state.calls : []
        let callHistoryBackfillReceipt = preserveCommunicationHistory
            ? state.callHistoryBackfillReceipt
            : nil
        let pendingTransferChatReceipts = preserveCommunicationHistory
            ? state.pendingTransferChatReceipts
            : nil
        let pendingPaymentRequestChatReceipts = preserveCommunicationHistory
            ? state.pendingPaymentRequestChatReceipts
            : nil
        let pendingPaymentRequestResolutionChatReceipts = preserveCommunicationHistory
            ? state.pendingPaymentRequestResolutionChatReceipts
            : nil
        let pendingGroupPaymentChatReceipts = preserveCommunicationHistory
            ? state.pendingGroupPaymentChatReceipts
            : nil
        let pendingGroupContributionChatReceipts = preserveCommunicationHistory
            ? state.pendingGroupContributionChatReceipts
            : nil
        let signedOutAt = Date()
        for index in history.indices
        where history[index].isOutgoing
            && [.queued, .encrypting, .sending].contains(history[index].state) {
            history[index].state = .failed
            history[index].failureReason =
                CustomerFacingMessagingCopy.deliveryUnconfirmedBeforeSignOut
        }
        for index in calls.indices
        where [.queued, .ringing, .active].contains(calls[index].state) {
            calls[index].state = .failed
            calls[index].endedAt = calls[index].endedAt ?? signedOutAt
        }
        var candidate = PersistedState.empty
        candidate.communicationOwnerUserID = preserveCommunicationHistory ? ownerUserID : nil
        candidate.messages = history
        candidate.conversations = conversations
        candidate.groupProjectionUpdatedAt = groupProjectionUpdatedAt
        candidate.conversationDrafts = conversationDrafts
        candidate.calls = calls
        candidate.callHistoryBackfillReceipt = callHistoryBackfillReceipt
        candidate.pendingTransferChatReceipts = pendingTransferChatReceipts
        candidate.pendingPaymentRequestChatReceipts = pendingPaymentRequestChatReceipts
        candidate.pendingPaymentRequestResolutionChatReceipts =
            pendingPaymentRequestResolutionChatReceipts
        candidate.pendingGroupPaymentChatReceipts = pendingGroupPaymentChatReceipts
        candidate.pendingGroupContributionChatReceipts = pendingGroupContributionChatReceipts
        if preserveCommunicationHistory {
            // Pins, mutes, and backup schedules describe the preserved chats; losing them on a
            // routine session-expiry sign-out would silently stop scheduled iCloud backups.
            candidate.pinnedConversationIds = state.pinnedConversationIds
            candidate.mutedConversationIds = state.mutedConversationIds
            candidate.messageBackupPreferences = state.messageBackupPreferences
            // The starter milestones are facts about this same owner; forgetting them on a
            // routine sign-out would resurrect a completed checklist. A different account
            // never inherits them: bindAuthenticatedProfile wipes the whole state on an owner
            // change, and both markers count as unowned data for ownerless legacy state.
            candidate.starterFirstTransactionAt = state.starterFirstTransactionAt
            candidate.starterFirstMessageAt = state.starterFirstMessageAt
        }
        // Signal identity, prekeys, sessions, and replay markers are account-bound. Never carry
        // them through logout into a later account activation, even though display history stays.
        try persist(candidate)
        state = candidate
    }

    /// Removes the projection owned by an account whose deletion was already accepted remotely.
    /// A marker retry must never erase a replacement account or ambiguous unowned legacy state.
    /// If the protected write fails, this process still exposes only an empty in-memory state;
    /// the independent Keychain marker remains so the next launch retries the durable write.
    func purgeAcceptedAccountDeletion(
        accountID: String
    ) throws -> AcceptedAccountDeletionProjectionPurgeResult {
        switch prepareForRestore() {
        case .ready: break
        case .temporarilyUnavailable: throw StoreError.protectedDataUnavailable
        case .invalid: throw StoreError.invalidCiphertext
        }
        let hasCommunicationData = containsCommunicationData(state)
        let hasProfileProjection = containsProfileProjection(state)

        guard hasCommunicationData || hasProfileProjection else {
            concealsStateForAcceptedDeletion = false
            return .alreadyEmpty
        }
        if hasCommunicationData {
            guard state.communicationOwnerUserID?.caseInsensitiveCompare(accountID)
                    == .orderedSame
            else { return .ownerConflict }
        }
        if hasProfileProjection {
            guard state.profile?.id.caseInsensitiveCompare(accountID) == .orderedSame
            else { return .ownerConflict }
        }

        let candidate = PersistedState.empty
        do {
            try persist(candidate)
            state = candidate
            concealsStateForAcceptedDeletion = false
            return .purged
        } catch {
            // Keep the true owner-bearing state for the next in-process retry, but do not expose
            // it through snapshot(). The durable purge marker drives another atomic rewrite.
            concealsStateForAcceptedDeletion = true
            throw error
        }
    }

    /// A malformed/unreadable accepted-deletion marker cannot safely identify one owner. Keep
    /// the protected file intact for a future support-assisted recovery, but expose none of its
    /// contents in this process.
    func concealStateForUnresolvedAcceptedAccountDeletion() {
        concealsStateForAcceptedDeletion = true
    }

    func concealStateForProtectedStateRecovery() {
        concealsStateForProtectedStateRecovery = true
    }

    func resolveProtectedStateRecoveryConcealment() {
        concealsStateForProtectedStateRecovery = false
    }

    /// Releases an in-process concealment only after the actor proves its readable durable
    /// projection is already empty. This repairs the narrow case where marker removal succeeded
    /// but verification threw; it can never reveal a conflicting or unreadable account state.
    func resolveAcceptedDeletionConcealmentAfterVerifiedEmptyState() throws -> Bool {
        switch prepareForRestore() {
        case .ready: break
        case .temporarilyUnavailable: throw StoreError.protectedDataUnavailable
        case .invalid: throw StoreError.invalidCiphertext
        }
        guard !containsCommunicationData(state),
              !containsProfileProjection(state)
        else { return false }
        concealsStateForAcceptedDeletion = false
        return true
    }

    private func containsCommunicationData(_ candidate: PersistedState) -> Bool {
        candidate.communicationOwnerUserID != nil
            || !candidate.conversations.isEmpty
            || candidate.groupProjectionUpdatedAt?.isEmpty == false
            || candidate.conversationDrafts?.isEmpty == false
            || !candidate.messages.isEmpty
            || !candidate.calls.isEmpty
            || candidate.callHistoryBackfillReceipt != nil
            || !candidate.outbox.isEmpty
            || candidate.pendingTransferChatReceipts?.isEmpty == false
            || candidate.pendingPaymentRequestChatReceipts?.isEmpty == false
            || candidate.pendingPaymentRequestResolutionChatReceipts?.isEmpty == false
            || candidate.pendingGroupPaymentChatReceipts?.isEmpty == false
            || candidate.pendingGroupContributionChatReceipts?.isEmpty == false
            || candidate.secureMessaging != nil
    }

    private func containsProfileProjection(_ candidate: PersistedState) -> Bool {
        candidate.profile != nil
            || candidate.sessionAssurance != nil
            || !candidate.wallets.isEmpty
            || candidate.registeredDevices?.isEmpty == false
            || candidate.registeredDeviceProjectionRevision != nil
            || candidate.selectedWalletId != nil
            || !candidate.transactions.isEmpty
            || candidate.contacts?.isEmpty == false
            || candidate.contactSyncFingerprint != nil
            || candidate.contactSyncSnapshotScope != nil
            || candidate.contactSyncLastCompletedAt != nil
            || candidate.communicationPrivacy != nil
            || candidate.pendingProfileAvatarAttachment != nil
    }

    private func persist(_ candidate: PersistedState) throws {
        let key = try encryptionKey()
        let encoder = JSONEncoder()
        // The encrypted payload does not need a human-readable date representation. Foundation's
        // deferred Date encoding preserves the full retry-clock value, whereas ISO-8601 drops
        // fractional seconds and leaves the live projection different from the durable one.
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.outputFormatting = [.sortedKeys]
        let clear = try encoder.encode(candidate)
        let sealed = try AES.GCM.seal(clear, using: key)
        guard let combined = sealed.combined else { throw StoreError.invalidCiphertext }
        try stateDataPersist(combined, stateURL)
        stateLoadStatus = .loaded
    }

    private func requireMutableState() throws {
        guard !concealsStateForAcceptedDeletion,
              !concealsStateForProtectedStateRecovery,
              stateIsReadable
        else { throw StoreError.acceptedDeletionCleanupPending }
    }

    private var stateIsReadable: Bool {
        stateLoadStatus == .knownEmpty || stateLoadStatus == .loaded
    }

    private static func loadState(
        at url: URL,
        injectedKeyData: Data?,
        stateDataLoad: StateDataLoad,
        keyDataLoad: KeyDataLoad
    ) -> StateLoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return StateLoadResult(state: .empty, status: .knownEmpty)
        }
        let encrypted: Data
        do {
            encrypted = try stateDataLoad(url)
        } catch {
            return StateLoadResult(
                state: .empty,
                status: .temporarilyUnavailableExistingFile
            )
        }
        let decryptionKeyData: Data?
        do {
            decryptionKeyData = try injectedKeyData ?? keyDataLoad()
        } catch {
            return StateLoadResult(
                state: .empty,
                status: .temporarilyUnavailableExistingFile
            )
        }
        guard let decryptionKeyData,
              let box = try? AES.GCM.SealedBox(combined: encrypted),
              let clear = try? AES.GCM.open(
                  box,
                  using: SymmetricKey(data: decryptionKeyData)
              )
        else {
            return StateLoadResult(state: .empty, status: .invalidExistingFile)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        if let decoded = try? decoder.decode(PersistedState.self, from: clear) {
            return StateLoadResult(state: decoded, status: .loaded)
        }
        // Builds through 52 encoded Date values as whole-second ISO-8601 strings. Retain that
        // one-way migration path while every new write uses lossless deferred Date encoding.
        let legacyDecoder = JSONDecoder()
        legacyDecoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? legacyDecoder.decode(PersistedState.self, from: clear) else {
            return StateLoadResult(state: .empty, status: .invalidExistingFile)
        }
        return StateLoadResult(state: decoded, status: .loaded)
    }

    private func encryptionKey() throws -> SymmetricKey {
        if let injectedKeyData {
            return SymmetricKey(data: injectedKeyData)
        }
        if let existing = try keyDataLoad() {
            return SymmetricKey(data: existing)
        }
        let bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        try KeychainStore.set(bytes, for: keyAccount)
        return SymmetricKey(data: bytes)
    }
}

enum SecureLocalStateReadiness: Equatable {
    case ready
    case temporarilyUnavailable
    case invalid
}

enum AcceptedAccountDeletionProjectionPurgeResult: Equatable {
    case purged
    case alreadyEmpty
    case ownerConflict
}

/// A point-in-time view of the store plus the monotonic revision it was taken at.
struct SecureLocalStateProjection {
    let state: PersistedState
    let revision: UInt64
}

enum StoreError: Error, Equatable {
    case invalidCiphertext
    case protectedDataUnavailable
    case accountChanged
    case acceptedDeletionCleanupPending
}
