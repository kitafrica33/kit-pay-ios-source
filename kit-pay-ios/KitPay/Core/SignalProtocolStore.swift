import Foundation
import LibSignalClient

struct SecureMessagingHistoryBackfillTask: Codable, Equatable, Sendable {
    let conversationID: String
    let targetDeviceID: String
    let targetEnrollmentEpoch: Int64
    var nextCursor: String?

    var key: String {
        "\(conversationID):\(targetDeviceID):\(targetEnrollmentEpoch)"
    }
}

/// Exact history ciphertext committed with its Signal ratchet update. A retry after an ambiguous
/// HTTP result must reuse these bytes for the deterministic transfer ID instead of encrypting the
/// same descriptor a second time.
struct SecureMessagingHistoryOutboundEnvelope: Codable, Equatable {
    let originalMessageID: String
    let targetDeviceID: String
    let targetEnrollmentEpoch: Int64
    let fanout: SecureMessagingCommittedFanout
}

enum SecureMessagingSyncFailureCategory: String, Codable, Equatable, Sendable {
    case eventValidation
    case conversation
    case roster
    case envelope
    case decryption
    case projection
}

/// An exact encrypted sync event retained after it repeatedly fails ahead of authenticated
/// projection. This value lives inside `SecureLocalStore`, so ciphertext and diagnostics remain
/// encrypted at rest and account-bound while the ordinary server cursor is allowed to progress.
struct SecureMessagingQuarantinedSyncEvent: Codable, Equatable, Sendable {
    let eventID: String
    let ownerUserID: String
    let localDeviceID: String
    let localEnrollmentEpoch: Int64
    let sourceCursor: String?
    let event: MessagingSyncEventDTO
    let firstFailedAt: Date
    var lastFailedAt: Date
    var nextAttemptAt: Date
    var attemptCount: Int
    var failureCategory: SecureMessagingSyncFailureCategory

    var isStructurallyValid: Bool {
        SecureMessagingValidation.isCanonicalPositiveDecimalID(eventID)
            && event.id == eventID
            && event.type == "message.created"
            && event.data?.envelope?.ciphertext?.isEmpty == false
            && SecureMessagingValidation.isCanonicalUUID(ownerUserID)
            && SecureMessagingValidation.isCanonicalUUID(localDeviceID)
            && localEnrollmentEpoch > 0
            && sourceCursor.map({ !$0.isEmpty && $0.utf8.count <= 2_048 }) ?? true
            && firstFailedAt.timeIntervalSinceReferenceDate.isFinite
            && lastFailedAt.timeIntervalSinceReferenceDate.isFinite
            && nextAttemptAt.timeIntervalSinceReferenceDate.isFinite
            && lastFailedAt >= firstFailedAt
            && attemptCount > 0
            && attemptCount <= SecureMessagingSyncQuarantinePolicy.maximumRecordedAttempts
    }
}

enum SecureMessagingSyncQuarantinePolicy {
    /// The server cursor gets three normal opportunities to apply an encrypted event. On the next
    /// replay the exact event is already durable, so normal sync may step over it and the separate
    /// retry lane owns recovery.
    static let attemptsBeforeCursorRelease = 3
    static let maximumRecords = 32
    static let maximumRecordedAttempts = 1_000_000
    static let maximumEncodedEventBytes = 2 * 1_024 * 1_024
    static let maximumEncodedCollectionBytes = 8 * 1_024 * 1_024
    static let maximumAttemptsPerDrain = 4
    static let maximumRetryDelay: TimeInterval = 6 * 60 * 60

    static func retryDelay(afterAttempt attemptCount: Int) -> TimeInterval {
        let exponent = min(max(0, attemptCount - attemptsBeforeCursorRelease), 10)
        return min(30 * pow(2, Double(exponent)), maximumRetryDelay)
    }

    static func canPersist(_ records: [SecureMessagingQuarantinedSyncEvent]) -> Bool {
        guard records.count <= maximumRecords,
              Set(records.map(\.eventID)).count == records.count,
              records.allSatisfy(\.isStructurallyValid)
        else { return false }
        let encoder = JSONEncoder()
        var aggregateBytes = 0
        for record in records {
            guard let encoded = try? encoder.encode(record),
                  encoded.count <= maximumEncodedEventBytes,
                  aggregateBytes <= maximumEncodedCollectionBytes - encoded.count
            else { return false }
            aggregateBytes += encoded.count
        }
        return true
    }
}

/// Codable libsignal state. `SecureLocalStore` encrypts this value with the same atomic AES-GCM
/// transaction as the visible message projection and ciphertext outbox.
struct SecureMessagingPersistentState: Codable, Equatable {
    /// Monotonic compare-and-swap token advanced by every durable crypto commit. Optional keeps
    /// any state written by an earlier secure-messaging build decodable as revision zero.
    var transactionRevision: UInt64? = nil
    var identityKeyPair: Data? = nil
    var registrationID: UInt32? = nil
    var enrollment: SecureMessagingEnrollmentBinding? = nil
    var pendingPublication: SecureMessagingLocalPublicBundle? = nil
    var remoteIdentities: [String: Data] = [:]
    var preKeys: [String: Data] = [:]
    var signedPreKeys: [String: Data] = [:]
    var kyberPreKeys: [String: Data] = [:]
    var lastResortKyberPreKeyIDs: Set<UInt32> = []
    var usedLastResortBaseKeys: Set<SecureMessagingKyberReplayMarker> = []
    var sessions: [String: Data] = [:]
    var remoteServerDeviceBindings: [String: String] = [:]
    var cachedRosters: [String: SecureMessagingRosterSnapshot] = [:]
    var syncCursor: String? = nil
    /// Poisoned encrypted message events are retried independently after their exact bytes and
    /// failure metadata have been durably preserved. This collection is bounded before commit.
    var quarantinedSyncEvents: [SecureMessagingQuarantinedSyncEvent] = []
    /// Delivery acknowledgement is attempted only after ciphertext, ratchet state and the visible
    /// projection commit atomically. Failed/replayed HTTP attempts remain safe and durable here.
    var pendingDeliveryAcknowledgementIDs: [String] = []
    /// Durable, cursor-based work is independent from the ordinary sync cursor: a transient donor
    /// failure can never stop later incoming messages from being applied.
    var historyBackfillTasks: [SecureMessagingHistoryBackfillTask] = []
    var historyOutboundEnvelopes: [String: SecureMessagingHistoryOutboundEnvelope] = [:]

    static let empty = SecureMessagingPersistentState()

    init() {}

    private enum CodingKeys: String, CodingKey {
        case transactionRevision
        case identityKeyPair
        case registrationID
        case enrollment
        case pendingPublication
        case remoteIdentities
        case preKeys
        case signedPreKeys
        case kyberPreKeys
        case lastResortKyberPreKeyIDs
        case usedLastResortBaseKeys
        case sessions
        case remoteServerDeviceBindings
        case cachedRosters
        case syncCursor
        case quarantinedSyncEvents
        case pendingDeliveryAcknowledgementIDs
        case historyBackfillTasks
        case historyOutboundEnvelopes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transactionRevision = try container.decodeIfPresent(UInt64.self, forKey: .transactionRevision)
        identityKeyPair = try container.decodeIfPresent(Data.self, forKey: .identityKeyPair)
        registrationID = try container.decodeIfPresent(UInt32.self, forKey: .registrationID)
        enrollment = try container.decodeIfPresent(
            SecureMessagingEnrollmentBinding.self,
            forKey: .enrollment
        )
        pendingPublication = try container.decodeIfPresent(
            SecureMessagingLocalPublicBundle.self,
            forKey: .pendingPublication
        )
        remoteIdentities = try container.decodeIfPresent(
            [String: Data].self,
            forKey: .remoteIdentities
        ) ?? [:]
        preKeys = try container.decodeIfPresent([String: Data].self, forKey: .preKeys) ?? [:]
        signedPreKeys = try container.decodeIfPresent(
            [String: Data].self,
            forKey: .signedPreKeys
        ) ?? [:]
        kyberPreKeys = try container.decodeIfPresent(
            [String: Data].self,
            forKey: .kyberPreKeys
        ) ?? [:]
        lastResortKyberPreKeyIDs = try container.decodeIfPresent(
            Set<UInt32>.self,
            forKey: .lastResortKyberPreKeyIDs
        ) ?? []
        usedLastResortBaseKeys = try container.decodeIfPresent(
            Set<SecureMessagingKyberReplayMarker>.self,
            forKey: .usedLastResortBaseKeys
        ) ?? []
        sessions = try container.decodeIfPresent([String: Data].self, forKey: .sessions) ?? [:]
        remoteServerDeviceBindings = try container.decodeIfPresent(
            [String: String].self,
            forKey: .remoteServerDeviceBindings
        ) ?? [:]
        if container.contains(.cachedRosters) {
            let rostersDecoder = try container.superDecoder(forKey: .cachedRosters)
            cachedRosters = (try? LossySecureMessagingRosterCache(from: rostersDecoder).values)
                ?? [:]
        } else {
            cachedRosters = [:]
        }
        syncCursor = try container.decodeIfPresent(String.self, forKey: .syncCursor)
        quarantinedSyncEvents = try container.decodeIfPresent(
            [SecureMessagingQuarantinedSyncEvent].self,
            forKey: .quarantinedSyncEvents
        ) ?? []
        pendingDeliveryAcknowledgementIDs = try container.decodeIfPresent(
            [String].self,
            forKey: .pendingDeliveryAcknowledgementIDs
        ) ?? []
        historyBackfillTasks = try container.decodeIfPresent(
            [SecureMessagingHistoryBackfillTask].self,
            forKey: .historyBackfillTasks
        ) ?? []
        historyOutboundEnvelopes = try container.decodeIfPresent(
            [String: SecureMessagingHistoryOutboundEnvelope].self,
            forKey: .historyOutboundEnvelopes
        ) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(transactionRevision, forKey: .transactionRevision)
        try container.encodeIfPresent(identityKeyPair, forKey: .identityKeyPair)
        try container.encodeIfPresent(registrationID, forKey: .registrationID)
        try container.encodeIfPresent(enrollment, forKey: .enrollment)
        try container.encodeIfPresent(pendingPublication, forKey: .pendingPublication)
        try container.encode(remoteIdentities, forKey: .remoteIdentities)
        try container.encode(preKeys, forKey: .preKeys)
        try container.encode(signedPreKeys, forKey: .signedPreKeys)
        try container.encode(kyberPreKeys, forKey: .kyberPreKeys)
        try container.encode(lastResortKyberPreKeyIDs, forKey: .lastResortKyberPreKeyIDs)
        try container.encode(usedLastResortBaseKeys, forKey: .usedLastResortBaseKeys)
        try container.encode(sessions, forKey: .sessions)
        try container.encode(remoteServerDeviceBindings, forKey: .remoteServerDeviceBindings)
        try container.encode(cachedRosters, forKey: .cachedRosters)
        try container.encodeIfPresent(syncCursor, forKey: .syncCursor)
        try container.encode(quarantinedSyncEvents, forKey: .quarantinedSyncEvents)
        try container.encode(
            pendingDeliveryAcknowledgementIDs,
            forKey: .pendingDeliveryAcknowledgementIDs
        )
        try container.encode(historyBackfillTasks, forKey: .historyBackfillTasks)
        try container.encode(historyOutboundEnvelopes, forKey: .historyOutboundEnvelopes)
    }

    var effectiveTransactionRevision: UInt64 { transactionRevision ?? 0 }

    mutating func advanceTransactionRevision(after previous: SecureMessagingPersistentState) throws {
        let revision = previous.effectiveTransactionRevision
        guard revision < UInt64.max else { throw SecureMessagingCryptoError.recordLimitExceeded }
        transactionRevision = revision + 1
    }
}

struct SecureMessagingEnrollmentBinding: Codable, Equatable {
    let userID: String
    let serverDeviceID: String
    let signalDeviceID: UInt32
    let registrationID: UInt32
    let enrollmentEpoch: Int64
    let identityKeySHA256: String
    let bundleVersion: Int
    let signedPreKeyID: UInt32
    let signedPreKeySHA256: String
    let pqLastResortPreKeyID: UInt32
    let pqLastResortPreKeySHA256: String

    private static let legacyMissingPreKeyID = UInt32.max

    var hasCompleteKeyCommitment: Bool {
        signedPreKeyID <= 16_777_215
            && pqLastResortPreKeyID <= 16_777_215
            && SecureMessagingValidation.isSHA256(signedPreKeySHA256)
            && SecureMessagingValidation.isSHA256(pqLastResortPreKeySHA256)
    }

    init(
        userID: String,
        serverDeviceID: String,
        signalDeviceID: UInt32,
        registrationID: UInt32,
        enrollmentEpoch: Int64,
        identityKeySHA256: String,
        bundleVersion: Int,
        signedPreKeyID: UInt32,
        signedPreKeySHA256: String,
        pqLastResortPreKeyID: UInt32,
        pqLastResortPreKeySHA256: String
    ) {
        self.userID = userID
        self.serverDeviceID = serverDeviceID
        self.signalDeviceID = signalDeviceID
        self.registrationID = registrationID
        self.enrollmentEpoch = enrollmentEpoch
        self.identityKeySHA256 = identityKeySHA256
        self.bundleVersion = bundleVersion
        self.signedPreKeyID = signedPreKeyID
        self.signedPreKeySHA256 = signedPreKeySHA256
        self.pqLastResortPreKeyID = pqLastResortPreKeyID
        self.pqLastResortPreKeySHA256 = pqLastResortPreKeySHA256
    }

    private enum CodingKeys: String, CodingKey {
        case userID
        case serverDeviceID
        case signalDeviceID
        case registrationID
        case enrollmentEpoch
        case identityKeySHA256
        case bundleVersion
        case signedPreKeyID
        case signedPreKeySHA256
        case pqLastResortPreKeyID
        case pqLastResortPreKeySHA256
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userID = try container.decode(String.self, forKey: .userID)
        serverDeviceID = try container.decode(String.self, forKey: .serverDeviceID)
        signalDeviceID = try container.decode(UInt32.self, forKey: .signalDeviceID)
        registrationID = try container.decode(UInt32.self, forKey: .registrationID)
        enrollmentEpoch = try container.decode(Int64.self, forKey: .enrollmentEpoch)
        identityKeySHA256 = try container.decode(String.self, forKey: .identityKeySHA256)
        bundleVersion = try container.decode(Int.self, forKey: .bundleVersion)
        signedPreKeyID = try container.decodeIfPresent(UInt32.self, forKey: .signedPreKeyID)
            ?? Self.legacyMissingPreKeyID
        signedPreKeySHA256 = try container.decodeIfPresent(
            String.self,
            forKey: .signedPreKeySHA256
        ) ?? ""
        pqLastResortPreKeyID = try container.decodeIfPresent(
            UInt32.self,
            forKey: .pqLastResortPreKeyID
        ) ?? Self.legacyMissingPreKeyID
        pqLastResortPreKeySHA256 = try container.decodeIfPresent(
            String.self,
            forKey: .pqLastResortPreKeySHA256
        ) ?? ""
    }
}

private struct LossySecureMessagingRosterCache: Decodable {
    let values: [String: SecureMessagingRosterSnapshot]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: SecureMessagingDynamicCodingKey.self)
        var decoded: [String: SecureMessagingRosterSnapshot] = [:]
        for key in container.allKeys {
            if let roster = try? container.decode(
                SecureMessagingRosterSnapshot.self,
                forKey: key
            ) {
                decoded[key.stringValue] = roster
            }
        }
        values = decoded
    }
}

private struct SecureMessagingDynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

struct SecureMessagingKyberReplayMarker: Codable, Hashable {
    let kyberPreKeyID: UInt32
    let signedPreKeyID: UInt32
    let baseKey: Data
}

enum SecureMessagingCryptoError: LocalizedError, Equatable {
    case notProvisioned
    case invalidAddress
    case invalidRegistrationID
    case invalidPreKeyID
    case recordLimitExceeded
    case missingRecord(String)
    case identityChanged
    case invalidSignature
    case staleRoster
    case sessionUnavailable
    case invalidContent
    case unsupportedEnvelope
    case replayedKyberBaseKey
    case staleState

    var errorDescription: String? {
        switch self {
        case .notProvisioned: "Messages need to be restored on this device. Sign in again to continue."
        case .invalidAddress: "Kit could not prepare this recipient. Please try again."
        case .invalidRegistrationID: "Kit could not prepare messages on this device. Please try again."
        case .invalidPreKeyID: "Kit could not prepare messages on this device. Please try again."
        case .recordLimitExceeded: "This device could not store more message keys. Sign in again to recover."
        case .missingRecord: "Messages need to be restored on this device. Sign in again to continue."
        case .identityChanged: "This contact's identity changed. Verify the contact before trying again."
        case .invalidSignature: "Kit could not verify this contact's identity. Please try again."
        case .staleRoster: "The conversation device roster changed; refresh before sending."
        case .sessionUnavailable: "Messages need to reconnect to this contact. Please try again."
        case .invalidContent: "This message could not be processed."
        case .unsupportedEnvelope: "This message format is not supported."
        case .replayedKyberBaseKey: "Kit could not verify a message key. Sign in again to recover."
        case .staleState: "Messages changed while syncing. Please try again."
        }
    }
}

private struct KitSignalStoreContext: StoreContext {}

/// Synchronous adapter required by libsignal's FFI callbacks. Callers construct it from an
/// isolated value snapshot and only persist `exportedState()` after the complete crypto operation
/// succeeds, so partial ratchet advancement never reaches disk.
final class KitSignalProtocolStore: IdentityKeyStore, PreKeyStore, SignedPreKeyStore,
    KyberPreKeyStore, LibSignalClient.SessionStore
{
    static let context: StoreContext = KitSignalStoreContext()

    private(set) var state: SecureMessagingPersistentState

    init(state: SecureMessagingPersistentState) throws {
        guard let identity = state.identityKeyPair, !identity.isEmpty,
              let registrationID = state.registrationID
        else { throw SecureMessagingCryptoError.notProvisioned }
        guard (1...16_380).contains(registrationID) else {
            throw SecureMessagingCryptoError.invalidRegistrationID
        }
        _ = try IdentityKeyPair(bytes: identity)
        self.state = state
    }

    func exportedState() -> SecureMessagingPersistentState { state }

    func identityKeyPair(context: StoreContext) throws -> IdentityKeyPair {
        guard let bytes = state.identityKeyPair else {
            throw SecureMessagingCryptoError.notProvisioned
        }
        return try IdentityKeyPair(bytes: bytes)
    }

    func localRegistrationId(context: StoreContext) throws -> UInt32 {
        guard let value = state.registrationID else {
            throw SecureMessagingCryptoError.notProvisioned
        }
        return value
    }

    func saveIdentity(
        _ identity: IdentityKey,
        for address: ProtocolAddress,
        context: StoreContext
    ) throws -> IdentityChange {
        let key = try Self.addressKey(address)
        let serialized = identity.serialize()
        if let current = state.remoteIdentities[key] {
            guard current == serialized else { throw SecureMessagingCryptoError.identityChanged }
            return .newOrUnchanged
        }
        guard state.remoteIdentities.count < 10_000 else {
            throw SecureMessagingCryptoError.recordLimitExceeded
        }
        state.remoteIdentities[key] = serialized
        return .newOrUnchanged
    }

    func isTrustedIdentity(
        _ identity: IdentityKey,
        for address: ProtocolAddress,
        direction: Direction,
        context: StoreContext
    ) throws -> Bool {
        guard let current = state.remoteIdentities[try Self.addressKey(address)] else { return true }
        return current == identity.serialize()
    }

    func identity(for address: ProtocolAddress, context: StoreContext) throws -> IdentityKey? {
        guard let bytes = state.remoteIdentities[try Self.addressKey(address)] else { return nil }
        return try IdentityKey(bytes: bytes)
    }

    func loadPreKey(id: UInt32, context: StoreContext) throws -> PreKeyRecord {
        try Self.requirePreKeyID(id)
        guard let bytes = state.preKeys[Self.recordKey(id)] else {
            throw SignalError.invalidKeyIdentifier("No EC prekey for ID \(id)")
        }
        return try PreKeyRecord(bytes: bytes)
    }

    func storePreKey(_ record: PreKeyRecord, id: UInt32, context: StoreContext) throws {
        try Self.requirePreKeyID(id)
        guard record.id == id else { throw SecureMessagingCryptoError.invalidPreKeyID }
        try Self.put(record.serialize(), id: id, in: &state.preKeys, maximumCount: 2_000)
    }

    func removePreKey(id: UInt32, context: StoreContext) throws {
        try Self.requirePreKeyID(id)
        state.preKeys.removeValue(forKey: Self.recordKey(id))
    }

    func loadSignedPreKey(id: UInt32, context: StoreContext) throws -> SignedPreKeyRecord {
        try Self.requirePreKeyID(id)
        guard let bytes = state.signedPreKeys[Self.recordKey(id)] else {
            throw SignalError.invalidKeyIdentifier("No signed prekey for ID \(id)")
        }
        return try SignedPreKeyRecord(bytes: bytes)
    }

    func storeSignedPreKey(
        _ record: SignedPreKeyRecord,
        id: UInt32,
        context: StoreContext
    ) throws {
        try Self.requirePreKeyID(id)
        guard record.id == id else { throw SecureMessagingCryptoError.invalidPreKeyID }
        try Self.put(record.serialize(), id: id, in: &state.signedPreKeys, maximumCount: 64)
    }

    func loadKyberPreKey(id: UInt32, context: StoreContext) throws -> KyberPreKeyRecord {
        try Self.requirePreKeyID(id)
        guard let bytes = state.kyberPreKeys[Self.recordKey(id)] else {
            throw SignalError.invalidKeyIdentifier("No PQ prekey for ID \(id)")
        }
        return try KyberPreKeyRecord(bytes: bytes)
    }

    func storeKyberPreKey(
        _ record: KyberPreKeyRecord,
        id: UInt32,
        context: StoreContext
    ) throws {
        try Self.requirePreKeyID(id)
        guard record.id == id else { throw SecureMessagingCryptoError.invalidPreKeyID }
        try Self.put(record.serialize(), id: id, in: &state.kyberPreKeys, maximumCount: 2_000)
    }

    func markKyberPreKeyUsed(
        id: UInt32,
        signedPreKeyId: UInt32,
        baseKey: PublicKey,
        context: StoreContext
    ) throws {
        guard state.kyberPreKeys[Self.recordKey(id)] != nil,
              state.signedPreKeys[Self.recordKey(signedPreKeyId)] != nil
        else { throw SignalError.invalidKeyIdentifier("Missing PQ or signed prekey") }

        guard state.lastResortKyberPreKeyIDs.contains(id) else {
            state.kyberPreKeys.removeValue(forKey: Self.recordKey(id))
            return
        }
        let marker = SecureMessagingKyberReplayMarker(
            kyberPreKeyID: id,
            signedPreKeyID: signedPreKeyId,
            baseKey: baseKey.serialize()
        )
        guard !state.usedLastResortBaseKeys.contains(marker) else {
            throw SecureMessagingCryptoError.replayedKyberBaseKey
        }
        guard state.usedLastResortBaseKeys.count < 20_000 else {
            throw SecureMessagingCryptoError.recordLimitExceeded
        }
        state.usedLastResortBaseKeys.insert(marker)
    }

    func loadSession(for address: ProtocolAddress, context: StoreContext) throws -> SessionRecord? {
        guard let bytes = state.sessions[try Self.addressKey(address)] else { return nil }
        return try SessionRecord(bytes: bytes)
    }

    func loadExistingSessions(
        for addresses: [ProtocolAddress],
        context: StoreContext
    ) throws -> [SessionRecord] {
        try addresses.map { address in
            guard let record = try loadSession(for: address, context: context) else {
                throw SignalError.sessionNotFound(address.debugDescription)
            }
            return record
        }
    }

    func storeSession(
        _ record: SessionRecord,
        for address: ProtocolAddress,
        context: StoreContext
    ) throws {
        let key = try Self.addressKey(address)
        guard state.sessions[key] != nil || state.sessions.count < 10_000 else {
            throw SecureMessagingCryptoError.recordLimitExceeded
        }
        let bytes = record.serialize()
        guard !bytes.isEmpty, bytes.count <= 2 * 1_024 * 1_024 else {
            throw SecureMessagingCryptoError.recordLimitExceeded
        }
        state.sessions[key] = bytes
    }

    func bindRemoteDevice(_ address: SecureMessagingAddress) throws {
        let protocolAddress = try address.protocolAddress()
        let key = try Self.addressKey(protocolAddress)
        if let existing = state.remoteServerDeviceBindings[key] {
            guard existing == address.serverDeviceID else {
                throw SecureMessagingCryptoError.identityChanged
            }
            return
        }
        guard state.remoteServerDeviceBindings.count < 10_000 else {
            throw SecureMessagingCryptoError.recordLimitExceeded
        }
        state.remoteServerDeviceBindings[key] = address.serverDeviceID
    }

    func requireRemoteDeviceBinding(_ address: SecureMessagingAddress) throws {
        let key = try Self.addressKey(address.protocolAddress())
        guard state.remoteServerDeviceBindings[key] == address.serverDeviceID else {
            throw SecureMessagingCryptoError.staleRoster
        }
    }

    func remoteDeviceBindingMatches(_ address: SecureMessagingAddress) throws -> Bool {
        state.remoteServerDeviceBindings[try Self.addressKey(address.protocolAddress())]
            == address.serverDeviceID
    }

    func hasConflictingRemoteDeviceBinding(_ address: SecureMessagingAddress) throws -> Bool {
        let expectedKey = try Self.addressKey(address.protocolAddress())
        if let bound = state.remoteServerDeviceBindings[expectedKey] {
            return bound != address.serverDeviceID
        }
        return state.remoteServerDeviceBindings.contains { key, serverDeviceID in
            serverDeviceID == address.serverDeviceID && key != expectedKey
        }
    }

    func markLastResortKyberPreKey(_ id: UInt32) throws {
        guard state.kyberPreKeys[Self.recordKey(id)] != nil else {
            throw SecureMessagingCryptoError.missingRecord("last-resort PQ prekey")
        }
        guard state.lastResortKyberPreKeyIDs.contains(id)
                || state.lastResortKyberPreKeyIDs.count < 16
        else { throw SecureMessagingCryptoError.recordLimitExceeded }
        state.lastResortKyberPreKeyIDs.insert(id)
    }

    private static func put(
        _ bytes: Data,
        id: UInt32,
        in records: inout [String: Data],
        maximumCount: Int
    ) throws {
        guard !bytes.isEmpty, bytes.count <= 2 * 1_024 * 1_024 else {
            throw SecureMessagingCryptoError.recordLimitExceeded
        }
        let key = recordKey(id)
        guard records[key] != nil || records.count < maximumCount else {
            throw SecureMessagingCryptoError.recordLimitExceeded
        }
        records[key] = bytes
    }

    static func recordKey(_ id: UInt32) -> String { String(id) }

    static func addressKey(_ address: ProtocolAddress) throws -> String {
        let canonicalName = address.name.lowercased()
        guard SecureMessagingValidation.isCanonicalUUID(canonicalName),
              (1...127).contains(address.deviceId)
        else { throw SecureMessagingCryptoError.invalidAddress }
        return "\(canonicalName):\(address.deviceId)"
    }

    static func requirePreKeyID(_ id: UInt32) throws {
        guard id <= 16_777_215 else { throw SecureMessagingCryptoError.invalidPreKeyID }
    }
}
