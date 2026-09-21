import CryptoKit
import Darwin
import Foundation
import Security

/// RunningBoard terminates a *suspended* process that still holds a file lock on a file in a
/// shared app-group container. The report is `EXC_CRASH (SIGKILL)` with termination reason
/// `RUNNINGBOARD 0xdead10cc`, and no thread is faulted: the crashed thread is the idle main
/// run loop. TestFlight 1.0.17 (102) died exactly that way after eight minutes, with a
/// background outbox flush (`AppModel.scheduleOutboxWake` -> `flushOutbox` ->
/// `SecureLocalStore.persist`) encoding the persisted state inside
/// `MessagingProcessBroker.withLock`, which holds `flock(LOCK_EX)` on
/// `<app group>/MessagingBroker/transaction.lock`.
///
/// Every locked section therefore runs inside a host activity assertion, so the process cannot
/// be suspended between `flock(LOCK_EX)` and `flock(LOCK_UN)`. The app target installs a
/// provider backed by a UIKit background task; app extensions keep the no-op default, which
/// also keeps this file free of UIKit and usable from `APPLICATION_EXTENSION_API_ONLY` targets.
enum SharedLockActivity {

    /// Begins one assertion and returns the handler that ends it. Never nil, always balanced.
    static func begin() -> () -> Void { storage.begin() }

    /// Installed once by the app, before any shared-store work. Passing nil restores the
    /// no-op default, which only tests do.
    static func install(_ provider: (() -> () -> Void)?) { storage.install(provider) }

    private static let storage = Storage()

    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var provider: (() -> () -> Void)?

        func install(_ new: (() -> () -> Void)?) {
            lock.lock()
            defer { lock.unlock() }
            provider = new
        }

        func begin() -> () -> Void {
            lock.lock()
            let provider = self.provider
            lock.unlock()
            return provider?() ?? {}
        }
    }
}

extension SharedLockActivity {

    /// The reason RunningBoard records against the share extension's assertion.
    static let expiringActivityReason = "africa.kit.pay.shared-store-lock"

    /// The extension-safe provider. `KitPayShare` compiles this file and takes the same
    /// `flock(LOCK_EX)` on the app-group lock, but `APPLICATION_EXTENSION_API_ONLY` removes
    /// `UIApplication.shared`, so it cannot install the app's background-task provider and the
    /// no-op default leaves it with no cover at all. That is the worse of the two processes to
    /// leave uncovered: a share sheet is torn down the instant the customer taps Send, while
    /// `DirectShareSendCoordinator.enqueue` is still journalling the message inside `withLock`.
    ///
    /// `ProcessInfo.performExpiringActivity` asserts only for as long as its block runs, so the
    /// block waits to be released rather than returning; one background thread parked for a
    /// bounded local write is the price of not being SIGKILLed mid-send.
    ///
    /// `perform` and `grantTimeout` exist for `SharedLockActivityTests`, which needs to drive
    /// the grant, the refusal and the never-scheduled cases deterministically.
    static func installExpiringActivityProvider(
        perform: @escaping (String, @escaping (Bool) -> Void) -> Void = { reason, body in
            ProcessInfo.processInfo.performExpiringActivity(withReason: reason, using: body)
        },
        grantTimeout: TimeInterval = 0.1
    ) {
        install {
            let granted = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            perform(expiringActivityReason) { expired in
                // `expired` means the assertion was refused, or has just been revoked. There is
                // nothing left to hold open, and blocking here would only pin a worker thread.
                granted.signal()
                guard !expired else { return }
                release.wait()
            }
            // Returning before the activity exists would leave open the very window this
            // closes. A refusal signals immediately, so only a block the system never schedules
            // can reach the timeout — and then the locked section proceeds exactly as it did
            // before this provider existed, which is no worse than the default.
            _ = granted.wait(timeout: .now() + grantTimeout)
            return { release.signal() }
        }
    }
}

/// The app and share extension have one Signal store. The wallet store and its key never leave
/// the application container. No caller may keep this lock while awaiting network or crypto work.
final class MessagingProcessBroker: @unchecked Sendable {
    static let shared = MessagingProcessBroker()

    struct Authority: Codable, Equatable {
        var generation: UUID
        var session: SessionTokens?
        var refreshAttempt: SessionRefreshAttempt?
        var sharingEnabled: Bool
        var sharingGeneration: UUID = UUID()
        var requiresBiometricUnlock: Bool?
        /// Legacy build-92 metadata. Opaque LA domain values are never compared across processes.
        var biometricDomainState: Data?
        var biometricCredential: MessagingBiometricCredential?
        /// Set only by the locked migration of matching pre-broker session credentials. A new
        /// login must never treat unbound legacy private ratchets as its own initial state.
        var allowsLegacyMessagingImport: Bool?

        static var revoked: Authority {
            Authority(generation: UUID(), session: nil, refreshAttempt: nil, sharingEnabled: false)
        }
    }

    struct Record: Codable {
        var version = 1
        var generation: UUID
        var accountID: String
        var crypto: SecureMessagingPersistentState?
        /// The referenced journal is encrypted with the PRIVATE wallet-store key and lives in
        /// the PRIVATE application container. Only its opaque commit ID crosses the boundary.
        var privateTransactionID: UUID?
        var outgoing: [DirectShareSendRecord] = []
        var retiredStagingBatchIDs: [UUID]?
        var completionReceipts: [DirectShareSendRecord.CompletionReceipt]?

        init(
            generation: UUID, accountID: String, crypto: SecureMessagingPersistentState?,
            privateTransactionID: UUID? = nil, outgoing: [DirectShareSendRecord] = [],
            retiredStagingBatchIDs: [UUID]? = nil,
            completionReceipts: [DirectShareSendRecord.CompletionReceipt]? = nil
        ) {
            self.generation = generation
            self.accountID = accountID
            self.crypto = crypto
            self.privateTransactionID = privateTransactionID
            self.outgoing = outgoing
            self.retiredStagingBatchIDs = retiredStagingBatchIDs
            self.completionReceipts = completionReceipts
        }

        private enum CodingKeys: String, CodingKey {
            case version, generation, accountID, crypto, privateTransactionID, outgoing
            case retiredStagingBatchIDs, completionReceipts
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            generation = try values.decode(UUID.self, forKey: .generation)
            accountID = try values.decode(String.self, forKey: .accountID)
            crypto = try values.decodeIfPresent(SecureMessagingPersistentState.self, forKey: .crypto)
            privateTransactionID = try values.decodeIfPresent(UUID.self, forKey: .privateTransactionID)
            outgoing = try values.decode([DirectShareSendRecord].self, forKey: .outgoing)
            retiredStagingBatchIDs = try values.decodeIfPresent([UUID].self, forKey: .retiredStagingBatchIDs)
            if values.contains(.completionReceipts), try !values.decodeNil(forKey: .completionReceipts) {
                var receipts = try values.nestedUnkeyedContainer(forKey: .completionReceipts)
                if let count = receipts.count, count > DirectShareSendRecord.maximumCompletionReceipts {
                    throw Failure.corrupt
                }
                var decoded: [DirectShareSendRecord.CompletionReceipt] = []
                while !receipts.isAtEnd {
                    guard decoded.count < DirectShareSendRecord.maximumCompletionReceipts else { throw Failure.corrupt }
                    decoded.append(try receipts.decode(DirectShareSendRecord.CompletionReceipt.self))
                }
                completionReceipts = decoded
            }
            guard isStructurallyValid else { throw Failure.corrupt }
        }

        var isStructurallyValid: Bool {
            let receipts = completionReceipts ?? []
            return version == 1 && SharedInboxPolicy.canonicalAccountID(accountID) == accountID
                && outgoing.count <= DirectShareSendRecord.maximumPendingSends
                && Set(outgoing.map(\.id)).count == outgoing.count
                && receipts.count <= DirectShareSendRecord.maximumCompletionReceipts
                && Set(receipts.map(\.id)).count == receipts.count
                && Set(receipts.map(\.id)).isDisjoint(with: outgoing.map(\.id))
                && receipts.allSatisfy {
                    $0.generation == generation && $0.accountID == accountID
                        && SharedInboxPolicy.canonicalAccountID($0.sessionID) == $0.sessionID
                        && $0.inputSHA256.count == 32
                }
        }

        func containsEnqueued(
            id: UUID, inputSHA256: Data, scope: Scope
        ) throws -> Bool {
            if let receipt = completionReceipts?.first(where: { $0.id == id }) {
                guard receipt.matches(scope), receipt.inputSHA256 == inputSHA256 else { throw Failure.staleState }
                return true
            }
            if let pending = outgoing.first(where: { $0.id == id }) {
                guard pending.generation == scope.generation, pending.accountID == scope.accountID,
                      pending.sessionID == scope.sessionID, try pending.inputFingerprint() == inputSHA256
                else { throw Failure.staleState }
                return true
            }
            return false
        }

        func isConfirmed(id: UUID, scope: Scope) -> Bool {
            outgoing.contains { $0.id == id && $0.generation == scope.generation
                && $0.accountID == scope.accountID && $0.sessionID == scope.sessionID && $0.isComplete }
                || completionReceipts?.contains { $0.id == id && $0.matches(scope) } == true
        }
    }

    struct Scope: Codable, Hashable, Sendable {
        let generation: UUID
        let accountID: String
        let sessionID: String
        let sharingGeneration: UUID
    }

    struct ApprovedDirectory: Codable, Sendable {
        let generation: UUID
        let accountID: String
        let sessionID: String
        let destinations: [SharedInboxDestination]
    }

    private struct SharingDenial: Codable, Equatable {
        enum Reason: String, Codable { case hard, biometric }
        let reason: Reason
        let id: UUID
    }

    private struct SessionRevocation: Codable {
        let generation: UUID
    }

    private struct PrivateCommitReceipt: Codable {
        let accountID: String
        let transactionID: UUID
    }

    enum Failure: LocalizedError {
        case unavailable, corrupt, accountChanged, staleState, queueFull
        case authenticationRequired, biometricApprovalRequired
        /// One case per `ShareAuthorizationPolicy.Refusal`, so a refusal the customer reads is
        /// the refusal the container actually produced. Build 105 collapsed all of these into
        /// `.accountChanged` ("Sharing is locked or your account changed"), which is why a
        /// signed-in handset could not be told apart from a signed-out one.
        case shareRefused(ShareAuthorizationPolicy.Refusal)

        var errorDescription: String? {
            switch self {
            case let .shareRefused(refusal):
                ShareAuthorizationPolicy.message(for: refusal)
            case .authenticationRequired:
                "Authenticate with Face ID or Touch ID to share securely."
            case .biometricApprovalRequired:
                "Unlock Kit Pay with Face ID or Touch ID once to approve secure sharing, then share again."
            case .accountChanged:
                "This share belongs to a different Kit Pay account. Close this and share again."
            default:
                "Kit Pay could not prepare the secure share. Please try again."
            }
        }

        /// The refusal reason the share sheet should act on, if this failure is one.
        var shareRefusal: ShareAuthorizationPolicy.Refusal? {
            switch self {
            case let .shareRefused(refusal): refusal
            case .accountChanged: .sessionReplaced
            default: nil
            }
        }
    }

    private let processLock = NSRecursiveLock()
    private let injectedRoot: URL?
    private let injectedKey: Data?
    private let isTestStore: Bool
    private var cachedAuthority: (stamp: String, value: Authority)?
    private var cachedRecord: (stamp: String, value: Record)?
    private var cachedKey: SymmetricKey?
    private let biometrics: any MessagingBiometricAuthenticating
    /// Unused since the share lease was removed; retained so existing test fixtures that
    /// inject a fake clock keep compiling.
    private let uptime: @Sendable () -> TimeInterval
    private let authorityWriteCheck: ((Authority) throws -> Void)?
    private let recordCommitCheck: (() throws -> Void)?
    private let fileRemovalCheck: ((String) throws -> Void)?

    init(
        rootURL: URL? = nil, key: Data? = nil,
        biometrics: any MessagingBiometricAuthenticating = SystemMessagingBiometricAuthenticator(),
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        authorityWriteCheck: ((Authority) throws -> Void)? = nil,
        recordCommitCheck: (() throws -> Void)? = nil,
        fileRemovalCheck: ((String) throws -> Void)? = nil
    ) {
        injectedRoot = rootURL
        injectedKey = key
        isTestStore = rootURL != nil || key != nil
        self.biometrics = biometrics
        self.uptime = uptime
        self.authorityWriteCheck = authorityWriteCheck
        self.recordCommitCheck = recordCommitCheck
        self.fileRemovalCheck = fileRemovalCheck
    }

    var rootURL: URL? {
        injectedRoot ?? FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: KitAppGroup.identifier
        )?.appendingPathComponent("MessagingBroker", isDirectory: true)
    }

    /// This lock covers only bounded local reads/CAS/atomic writes. flock also excludes the
    /// other process; the recursive lock prevents two independent descriptors in this process
    /// from racing each other. The stable lock inode is never replaced or removed.
    func withLock<T>(_ body: (MessagingProcessBroker) throws -> T) throws -> T {
        processLock.lock()
        defer { processLock.unlock() }
        // Suspension while this flock is held is fatal (0xdead10cc); see SharedLockActivity.
        // The assertion is taken before the descriptor is opened and released after the
        // unlock, so it covers acquisition, the body, and every throwing path out of them.
        let endSharedLockActivity = SharedLockActivity.begin()
        defer { endSharedLockActivity() }
        guard let rootURL else { throw Failure.unavailable }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: rootURL.path
        )
        var root = rootURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        let fd = Darwin.open(
            rootURL.appendingPathComponent("transaction.lock").path,
            O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard fd >= 0 else { throw Failure.unavailable }
        defer { Darwin.close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw Failure.unavailable }
        }
        defer { flock(fd, LOCK_UN) }
        return try body(self)
    }

    // All Locked-suffixed methods require withLock. They are internal for SecureLocalStore's
    // private journal transaction; feature code uses scope/snapshot/updateOutgoing below.
    func authorityLocked() throws -> Authority? {
        let authority = try rawAuthorityLocked()
        guard let authority, let rootURL else { return authority }
        let marker = rootURL.appendingPathComponent("session.revoked")
        guard FileManager.default.fileExists(atPath: marker.path) else { return authority }
        let revoked = try JSONDecoder().decode(SessionRevocation.self, from: Data(contentsOf: marker))
        // A failed Keychain tombstone must not resurrect the revoked session on a later read.
        if revoked.generation == authority.generation {
            var fenced = authority
            // Keep the raw generation: a second failed clear/replacement must keep fencing
            // these exact stored credentials, never overwrite the marker with a synthetic ID.
            fenced.session = nil
            fenced.refreshAttempt = nil
            fenced.sharingEnabled = false
            return fenced
        }
        return authority
    }

    private func rawAuthorityLocked() throws -> Authority? {
        if isTestStore { return try loadEncryptedLocked(Authority.self, name: "test-authority.secure") }
        let stamp = try fileStamp("authority.version")
        if let stamp, cachedAuthority?.stamp == stamp { return cachedAuthority?.value }
        guard let data = try sharedKeychainData(account: "messaging-authority-v1") else { return nil }
        let authority = try JSONDecoder().decode(Authority.self, from: data)
        if let stamp { cachedAuthority = (stamp, authority) }
        return authority
    }

    func saveAuthorityLocked(_ authority: Authority) throws {
        try authorityWriteCheck?(authority)
        if isTestStore { try saveEncryptedLocked(authority, name: "test-authority.secure"); return }
        guard let rootURL else { throw Failure.unavailable }
        // Invalidate caches before changing the Keychain while holding the same process lock.
        // Another process cannot observe the new marker until this write finishes or dies.
        cachedAuthority = nil
        try Self.durableWrite(Data(UUID().uuidString.utf8), to: rootURL.appendingPathComponent("authority.version"))
        try setSharedKeychainData(JSONEncoder().encode(authority), account: "messaging-authority-v1")
        if let stamp = try fileStamp("authority.version") { cachedAuthority = (stamp, authority) }
    }

    func recordLocked() throws -> Record? {
        guard let url = rootURL?.appendingPathComponent("messaging.secure") else {
            throw Failure.unavailable
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let stamp = try fileStamp("messaging.secure")
        if let stamp, cachedRecord?.stamp == stamp { return cachedRecord?.value }
        let bytes = try Data(contentsOf: url)
        let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: keyLocked())
        let result = try JSONDecoder().decode(Record.self, from: clear)
        guard result.isStructurallyValid else { throw Failure.corrupt }
        if let stamp { cachedRecord = (stamp, result) }
        return result
    }

    func saveRecordLocked(_ record: Record) throws {
        guard let url = rootURL?.appendingPathComponent("messaging.secure"),
              record.outgoing.count <= DirectShareSendRecord.maximumPendingSends
        else { throw Failure.queueFull }
        guard record.isStructurallyValid else { throw Failure.corrupt }
        let clear = try JSONEncoder().encode(record)
        guard let sealed = try AES.GCM.seal(clear, using: keyLocked()).combined else {
            throw Failure.corrupt
        }
        try Self.durableWrite(sealed, to: url)
        try recordCommitCheck?()
        if let stamp = try fileStamp("messaging.secure") { cachedRecord = (stamp, record) }
    }

    private func scopeLocked(_ authority: Authority) throws -> Scope {
        guard let session = authority.session,
              let accountID = SharedInboxPolicy.canonicalAccountID(session.accountId),
              let sessionID = SharedInboxPolicy.canonicalAccountID(session.sessionId)
        else { throw Failure.accountChanged }
        return Scope(generation: authority.generation, accountID: accountID,
                     sessionID: sessionID, sharingGeneration: authority.sharingGeneration)
    }

    func scope() throws -> Scope {
        try withLock { broker in
            guard let authority = try broker.authorityLocked() else { throw Failure.accountChanged }
            let scope = try broker.scopeLocked(authority)
            _ = try broker.requireScopeLocked(scope)
            return scope
        }
    }

    /// The single sharing gate, for the app and the extension alike.
    ///
    /// It asks `ShareAuthorizationPolicy` and nothing else. In particular it no longer consults
    /// `requiresBiometricUnlock`, a biometric credential or a process-local unlock lease: those
    /// three inputs are what made a signed-in handset refuse every share in build 105, and the
    /// owner's directive is that biometrics guard payments, never chats.
    ///
    /// A *published recipient directory for this exact scope* is the app's standing permission.
    /// `denySharingLocked` deletes that directory in the same locked section that writes the
    /// hard denial, so "directory present and not hard-denied" means precisely "the app
    /// published this session's recipients and has not revoked them since".
    func requireScopeLocked(_ scope: Scope, requiresSharing: Bool = true) throws -> Authority {
        guard let authority = try authorityLocked() else {
            throw Failure.shareRefused(.signedOut)
        }
        guard try scopeLocked(authority) == scope else { throw Failure.accountChanged }
        guard requiresSharing else { return authority }
        let denial = try sharingDenialLocked()
        if let refusal = ShareAuthorizationPolicy.decide(
            ShareAuthorizationPolicy.Input(
                hasAuthority: true,
                hasSession: true,
                // A legacy `.biometric` marker is no longer a denial at all: it was only ever
                // the app's UI lock, and it never removed the directory.
                isHardDenied: denial?.reason == .hard,
                // `sharingEnabled` is only ever set true against a matching directory, so the
                // common path answers without decrypting `destinations.secure` again.
                hasMatchingDirectory: authority.sharingEnabled
                    || (try? requireDirectoryLocked(scope)) != nil
            )
        ) {
            throw Failure.shareRefused(refusal)
        }
        return authority
    }

    func snapshot(scope: Scope) throws -> Record {
        try withLock { broker in
            _ = try broker.requireScopeLocked(scope)
            guard let record = try broker.recordLocked(),
                  record.accountID == scope.accountID, record.generation == scope.generation
            else { throw Failure.accountChanged }
            return record
        }
    }

    /// Resolves uncertain enqueue ownership only for the exact input and original scope. An
    /// unreadable store or a mismatched intent remains an error, never proof of publication.
    func containsEnqueued(id: UUID, inputSHA256: Data, scope: Scope) throws -> Bool {
        try snapshot(scope: scope).containsEnqueued(id: id, inputSHA256: inputSHA256, scope: scope)
    }

    func isConfirmed(id: UUID, scope: Scope) throws -> Bool {
        try snapshot(scope: scope).isConfirmed(id: id, scope: scope)
    }

    private func biometricBindingLocked(_ authority: Authority) throws -> MessagingBiometricBinding {
        let scope = try scopeLocked(authority)
        return MessagingBiometricBinding(
            generation: scope.generation, accountID: scope.accountID, sessionID: scope.sessionID
        )
    }

    /// Capture before the main app's biometric operation. A proof from a replaced login may
    /// never create a sharing credential for its successor, even for the same account.
    func biometricBinding(accountID: String, sessionID: String) throws -> MessagingBiometricBinding {
        try withLock { broker in
            guard let authority = try broker.authorityLocked() else { throw Failure.accountChanged }
            let binding = try broker.biometricBindingLocked(authority)
            guard binding.accountID == SharedInboxPolicy.canonicalAccountID(accountID),
                  binding.sessionID == SharedInboxPolicy.canonicalAccountID(sessionID)
            else { throw Failure.accountChanged }
            return binding
        }
    }

    /// Always `false` now. Sharing no longer has a biometric prerequisite of any kind, so
    /// there is nothing for the caller to go and approve. Retained (rather than deleted) so
    /// the settings flow that asks "does sharing still need Face ID?" keeps compiling and
    /// simply learns that it does not.
    func biometricSharingRequired(accountID: String, sessionID: String) throws -> Bool {
        try withLock { broker in
            guard let authority = try broker.authorityLocked() else { throw Failure.accountChanged }
            let binding = try broker.biometricBindingLocked(authority)
            guard binding.accountID == SharedInboxPolicy.canonicalAccountID(accountID),
                  binding.sessionID == SharedInboxPolicy.canonicalAccountID(sessionID)
            else { throw Failure.accountChanged }
            return false
        }
    }

    /// Turning the biometric app lock off used to hard-deny sharing and delete the published
    /// recipients — which is precisely the deadlock build 105 shipped, because the only way
    /// back was a successful approval that could no longer happen. It now clears the retired
    /// credential and leaves sharing exactly as it was: the customer is still signed in.
    func disableBiometricSharing(binding: MessagingBiometricBinding) throws {
#if KIT_SHARE_EXTENSION
        throw Failure.biometricApprovalRequired
#else
        let retired = try withLock { broker -> MessagingBiometricCredential? in
            guard var authority = try broker.authorityLocked(),
                  try broker.biometricBindingLocked(authority) == binding
            else { throw Failure.accountChanged }
            let retired = authority.biometricCredential
            guard authority.requiresBiometricUnlock != nil || retired != nil
                || authority.biometricDomainState != nil else { return nil }
            authority.requiresBiometricUnlock = nil
            authority.biometricCredential = nil
            authority.biometricDomainState = nil
            authority.sharingGeneration = UUID()
            try broker.saveAuthorityLocked(authority)
            return retired
        }
        if let retired {
            let biometrics = self.biometrics
            Task.detached(priority: .utility) { try? biometrics.removeCredential(retired) }
        }
#endif
    }

    /// Keeps the caller's fresh-proof contract (the private current-set key must still work)
    /// but stores nothing and denies nothing. There is no sharing credential to create any
    /// more: the share sheet authorises on the published directory alone, so an approval that
    /// fails — a re-enrolment, a Keychain hiccup, a cancelled prompt — can no longer take a
    /// signed-in customer's share sheet away. Any legacy credential is retired here.
    func approveBiometricSharing(
        binding: MessagingBiometricBinding, enrollmentKeyID: String,
        confirmPrivateKey: () throws -> Void
    ) throws {
#if KIT_SHARE_EXTENSION
        throw Failure.biometricApprovalRequired
#else
        guard binding.isStructurallyValid,
              MessagingBiometricCredential.isValidEnrollmentKeyID(enrollmentKeyID)
        else { throw Failure.corrupt }
        try Task.checkCancellation()
        try withLock { broker in
            guard let authority = try broker.authorityLocked(),
                  try broker.biometricBindingLocked(authority) == binding
            else { throw Failure.accountChanged }
        }
        try confirmPrivateKey()
        try Task.checkCancellation()
        try disableBiometricSharing(binding: binding)
#endif
    }

    /// Called only by the main app after its account, device, privacy and biometric gates pass.
    /// Names are encrypted independently of the large ratchet file so UI refreshes stay cheap.
    func publishApprovedDestinations(
        _ destinations: [SharedInboxDestination], accountID: String,
        requiresBiometricUnlock: Bool
    ) throws {
        guard destinations.count <= SharedInboxPolicy.maximumDestinations,
              Set(destinations.map(\.id)).count == destinations.count,
              destinations.allSatisfy(SharedInboxPolicy.isValidDestination)
        else { throw Failure.corrupt }
        try withLock { broker in
            guard var authority = try broker.authorityLocked(),
                  authority.session?.accountId?.lowercased() == accountID
            else { throw Failure.accountChanged }
            // `requiresBiometricUnlock` is accepted and ignored. Publishing used to demand a
            // live `.biometryCurrentSet` Keychain credential whenever the customer had the
            // app's Face ID unlock switched on; a re-enrolment, a new session id or a first
            // launch after a token refresh left no such credential, publication threw, the
            // caller revoked sharing, and the extension answered "Sharing is locked or your
            // account changed" until something re-approved it. Chats are not a money action:
            // there is nothing here to approve. Clearing the legacy fields is the migration.
            _ = requiresBiometricUnlock
            if authority.requiresBiometricUnlock != nil || authority.biometricDomainState != nil
                || authority.biometricCredential != nil {
                let retired = authority.biometricCredential
                authority.requiresBiometricUnlock = nil
                authority.biometricDomainState = nil
                authority.biometricCredential = nil
                authority.sharingGeneration = UUID()
                try broker.saveAuthorityLocked(authority)
                if let retired {
                    let biometrics = broker.biometrics
                    Task.detached(priority: .utility) { try? biometrics.removeCredential(retired) }
                }
            }
            let scope = try broker.scopeLocked(authority)
            let directory = ApprovedDirectory(
                generation: scope.generation, accountID: scope.accountID,
                sessionID: scope.sessionID, destinations: destinations
            )
            if let existing = try broker.directoryLocked(),
               existing.generation == directory.generation,
               existing.accountID == directory.accountID, existing.sessionID == directory.sessionID,
               existing.destinations == directory.destinations { return }
            try broker.saveEncryptedLocked(directory, name: "destinations.secure")
        }
    }

    func approvedDestinations(scope: Scope) throws -> [SharedInboxDestination] {
        try withLock { broker in
            _ = try broker.requireScopeLocked(scope)
            return try broker.requireDirectoryLocked(scope).destinations
        }
    }

    /// What the share sheet calls before it renders a single recipient.
    ///
    /// It is deliberately synchronous work behind an `async` face: there is no authentication
    /// to await any more. Biometrics are a payment control (owner directive, 2026-09-21), and
    /// an extension that waited on Face ID could not share while the phone was in a pocket,
    /// while the app was locked, or at all once the `.biometryCurrentSet` credential had been
    /// invalidated by a re-enrolment or a session-id change — which is how build 105 came to
    /// refuse every share on a signed-in handset.
    ///
    /// The decision is `ShareAuthorizationPolicy`'s, evaluated once inside the lock so the
    /// directory the caller receives is the one the decision was made against.
    func authorizeShare() async throws -> ApprovedDirectory {
        try Task.checkCancellation()
        return try withLock { broker in
            guard let authority = try broker.authorityLocked() else {
                throw Failure.shareRefused(.signedOut)
            }
            let scope: Scope
            do {
                scope = try broker.scopeLocked(authority)
            } catch {
                // No canonical account/session on the authority: nobody is signed in here.
                throw Failure.shareRefused(.signedOut)
            }
            let denial = try broker.sharingDenialLocked()
            let directory = try? broker.requireDirectoryLocked(scope)
            if let refusal = ShareAuthorizationPolicy.decide(
                ShareAuthorizationPolicy.Input(
                    hasAuthority: true,
                    hasSession: true,
                    isHardDenied: denial?.reason == .hard,
                    hasMatchingDirectory: directory != nil
                )
            ) {
                throw Failure.shareRefused(refusal)
            }
            guard let directory else { throw Failure.shareRefused(.notPrepared) }
            return directory
        }
    }

    /// Kept only so the app's lock-state observer keeps its shape. Locking Kit Pay behind
    /// Face ID is a *screen* control: it must not take the share sheet away from a signed-in
    /// account (owner directive, 2026-09-21 — biometrics are a payment control). Instead of
    /// writing a `.biometric` denial this now *clears* a legacy one, which is what un-bricks a
    /// handset that upgraded from build 105 while suspended.
    func suspendSharingForBiometricLock(accountID: String) throws {
        try withLock { broker in
            try broker.clearBiometricDenialLocked()
        }
    }

    /// Now exactly the same job as ``publishApprovedDestinations(_:accountID:requiresBiometricUnlock:)``
    /// followed by an enable. It used to be the "app is locked" variant: it published the
    /// recipients but deliberately left sharing disabled behind a `.biometric` denial and
    /// demanded a live biometric credential first. Both are gone — a locked app must still be
    /// able to hand the share sheet its chats. Retained as a name so the caller and its
    /// regression tests keep their shape.
    func restoreBiometricSharingDestinations(
        _ destinations: [SharedInboxDestination], accountID: String
    ) throws {
        try publishApprovedDestinations(
            destinations, accountID: accountID, requiresBiometricUnlock: false
        )
        try setSharingEnabled(true, accountID: accountID)
    }

    func setSharingEnabled(_ enabled: Bool, accountID: String?) throws {
        try withLock { broker in
            if !enabled { try broker.denySharingLocked() }
            guard var authority = try broker.authorityLocked() else { return }
            if enabled {
                guard let accountID,
                      authority.session?.accountId?.lowercased() == accountID,
                      let directory = try broker.directoryLocked(),
                      directory.generation == authority.generation, directory.accountID == accountID,
                      directory.sessionID == authority.session?.sessionId.lowercased()
                else { throw Failure.accountChanged }
                // No biometric credential check: sharing is not gated on the app's lock state.
            }
            let denied = try broker.sharingDenialLocked() != nil
            guard authority.sharingEnabled != enabled || (enabled && denied) else { return }
            authority.sharingEnabled = enabled
            authority.sharingGeneration = UUID()
            try broker.saveAuthorityLocked(authority)
            if enabled { try broker.removeFileLocked("sharing.denied") }
        }
    }

    /// Written first: a failed Keychain mutation cannot turn a privacy/logout denial into an
    /// extension-authenticable biometric lock or leave an existing process-local lease usable.
    func denySharingLocked() throws {
        guard let rootURL else { throw Failure.unavailable }
        // Even repeated privacy denials must invalidate an in-flight biometric approval.
        try Self.durableWrite(
            try JSONEncoder().encode(SharingDenial(reason: .hard, id: UUID())),
            to: rootURL.appendingPathComponent("sharing.denied")
        )
        try removeFileLocked("destinations.secure")
    }

    func revokeSessionLocked(generation: UUID) throws {
        guard let rootURL else { throw Failure.unavailable }
        try Self.durableWrite(try JSONEncoder().encode(SessionRevocation(generation: generation)),
                              to: rootURL.appendingPathComponent("session.revoked"))
        try denySharingLocked()
    }

    /// Preserve only the opaque private-WAL receipt before removing a revoked Signal store.
    /// This lets the main app finish a committed transaction before its history-preserving clear.
    func preservePrivateReceiptLocked(_ record: Record) throws {
        guard let transactionID = record.privateTransactionID else { return }
        try saveEncryptedLocked(
            PrivateCommitReceipt(accountID: record.accountID, transactionID: transactionID),
            name: "private-commit-\(record.accountID).secure"
        )
    }

    func privateReceiptLocked(accountID: String) throws -> UUID? {
        guard SharedInboxPolicy.canonicalAccountID(accountID) == accountID else { throw Failure.corrupt }
        let receipt = try loadEncryptedLocked(
            PrivateCommitReceipt.self, name: "private-commit-\(accountID).secure"
        )
        guard receipt?.accountID == accountID else { return nil }
        return receipt?.transactionID
    }

    func consumePrivateReceiptLocked(accountID: String) throws {
        guard SharedInboxPolicy.canonicalAccountID(accountID) == accountID else { throw Failure.corrupt }
        try removeFileLocked("private-commit-\(accountID).secure")
    }

    func retiredHistoryLocked(accountID: String) throws -> [DirectShareSendRecord] {
        guard SharedInboxPolicy.canonicalAccountID(accountID) == accountID else { throw Failure.corrupt }
        let records = try loadEncryptedLocked([DirectShareSendRecord].self,
                                              name: "confirmed-history-\(accountID).secure") ?? []
        guard records.allSatisfy({ $0.accountID == accountID && $0.isComplete
            && $0.fanout == nil && $0.wireRequest == nil && $0.enrollment == nil && $0.media.isEmpty })
        else { throw Failure.corrupt }
        return records
    }

    func consumeRetiredHistoryLocked(accountID: String) throws {
        guard SharedInboxPolicy.canonicalAccountID(accountID) == accountID else { throw Failure.corrupt }
        try removeFileLocked("confirmed-history-\(accountID).secure")
    }

    func purgeRevokedGenerationLocked(_ generation: UUID, preserveConfirmedHistory: Bool = true) throws {
        guard let record = try recordLocked(), record.generation == generation else { return }
        if preserveConfirmedHistory {
            try preservePrivateReceiptLocked(record)
            var confirmed = try retiredHistoryLocked(accountID: record.accountID)
            for var send in record.outgoing where send.isComplete {
                // Preserve only the authenticated display projection. No ratchet, network
                // request or uploader can be revived from this retired history receipt.
                send.fanout = nil
                send.wireRequest = nil
                send.enrollment = nil
                send.media = []
                send.localMediaImported = false
                if !confirmed.contains(where: { $0.id == send.id }) { confirmed.append(send) }
            }
            if !confirmed.isEmpty {
                try saveEncryptedLocked(confirmed, name: "confirmed-history-\(record.accountID).secure")
            }
        }
        for send in record.outgoing where send.generation == generation && send.accountID == record.accountID {
            DirectShareSendRecord.stagingStore.remove(batchID: send.id)
        }
        for id in record.retiredStagingBatchIDs ?? [] { DirectShareSendRecord.stagingStore.remove(batchID: id) }
        try removeFileLocked("messaging.secure")
        cachedRecord = nil
    }

    /// A `.biometric` marker was never a security decision — it was the app's screen lock
    /// leaking into the share sheet. Build 105 handsets can still carry one, so every entry
    /// point that used to write one now removes it instead. A `hard` denial is untouched.
    private func clearBiometricDenialLocked() throws {
        guard try sharingDenialLocked()?.reason == .biometric else { return }
        try removeFileLocked("sharing.denied")
    }

    private func sharingDenialLocked() throws -> SharingDenial? {
        guard let rootURL else { throw Failure.unavailable }
        let marker = rootURL.appendingPathComponent("sharing.denied")
        guard FileManager.default.fileExists(atPath: marker.path) else { return nil }
        let bytes = try Data(contentsOf: marker)
        // A malformed/legacy denial stays a hard denial; it can never authorize biometric access.
        return (try? JSONDecoder().decode(SharingDenial.self, from: bytes))
            ?? SharingDenial(reason: .hard, id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
    }

    private func directoryLocked() throws -> ApprovedDirectory? {
        try loadEncryptedLocked(ApprovedDirectory.self, name: "destinations.secure")
    }

    private func requireDirectoryLocked(_ scope: Scope) throws -> ApprovedDirectory {
        guard let directory = try directoryLocked(), directory.generation == scope.generation,
              directory.accountID == scope.accountID, directory.sessionID == scope.sessionID
        else { throw Failure.accountChanged }
        return directory
    }

    private func loadEncryptedLocked<T: Decodable>(_ type: T.Type, name: String) throws -> T? {
        guard let rootURL else { throw Failure.unavailable }
        let url = rootURL.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let bytes = try Data(contentsOf: url)
        let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: keyLocked())
        return try JSONDecoder().decode(type, from: clear)
    }

    private func saveEncryptedLocked<T: Encodable>(_ value: T, name: String) throws {
        guard let rootURL,
              let bytes = try AES.GCM.seal(JSONEncoder().encode(value), using: keyLocked()).combined
        else { throw Failure.unavailable }
        try Self.durableWrite(bytes, to: rootURL.appendingPathComponent(name))
    }

    private func removeFileLocked(_ name: String) throws {
        try fileRemovalCheck?(name)
        guard let rootURL else { throw Failure.unavailable }
        let url = rootURL.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
        try Self.synchronizeFile(rootURL)
    }

    private func fileStamp(_ name: String) throws -> String? {
        guard let rootURL else { throw Failure.unavailable }
        var info = stat()
        let result = lstat(rootURL.appendingPathComponent(name).path, &info)
        if result != 0, errno == ENOENT { return nil }
        guard result == 0, info.st_mode & S_IFMT == S_IFREG else { throw Failure.corrupt }
        return "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_nsec)"
    }

    @discardableResult
    func updateOutgoing<T>(
        scope: Scope,
        _ mutate: (inout Record) throws -> T
    ) throws -> T {
        try withLock { broker in
            _ = try broker.requireScopeLocked(scope)
            guard var record = try broker.recordLocked(),
                  record.generation == scope.generation, record.accountID == scope.accountID
            else { throw Failure.accountChanged }
            let result = try mutate(&record)
            try broker.saveRecordLocked(record)
            return result
        }
    }

    private func keyLocked() throws -> SymmetricKey {
        if let injectedKey { return SymmetricKey(data: injectedKey) }
        if let cachedKey { return cachedKey }
        if let key = try sharedKeychainData(account: "messaging-store-key-v1") {
            guard key.count == 32 else { throw Failure.corrupt }
            let value = SymmetricKey(data: key)
            cachedKey = value
            return value
        }
        // A missing key with existing ciphertext is a recovery error, never a fresh identity.
        guard let rootURL,
              !FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("messaging.secure").path)
        else { throw Failure.corrupt }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try setSharedKeychainData(data, account: "messaging-store-key-v1")
        cachedKey = key
        return key
    }

    private var keychainGroup: String? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "KitMessagingKeychainGroup") as? String,
              !group.isEmpty, !group.contains("$(")
        else { return nil }
        return group
    }

    private func keychainQuery(account: String) throws -> [String: Any] {
        guard let keychainGroup else { throw Failure.unavailable }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "africa.kit.pay.messaging-shared",
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: keychainGroup,
        ]
    }

    private func sharedKeychainData(account: String) throws -> Data? {
        var query = try keychainQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError(status: status)
        }
        return data
    }

    private func setSharedKeychainData(_ data: Data, account: String) throws {
        let query = try keychainQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecItemNotFound {
            var inserted = query
            attributes.forEach { inserted[$0.key] = $0.value }
            let status = SecItemAdd(inserted as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError(status: status) }
        } else if updated != errSecSuccess {
            throw KeychainError(status: updated)
        }
    }

    static func synchronizeFile(_ url: URL) throws {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.unavailable }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw Failure.unavailable }
    }

    static func durableWrite(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(UUID().uuidString.lowercased()).pending"
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
        try synchronizeFile(temporary)
        try durableMove(temporary, to: destination)
    }

    static func durableMove(_ source: URL, to destination: URL) throws {
        guard Darwin.rename(source.path, destination.path) == 0 else { throw Failure.unavailable }
        try synchronizeFile(destination.deletingLastPathComponent())
    }
}
