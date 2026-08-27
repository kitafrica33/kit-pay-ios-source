import CoreFoundation
import CryptoKit
import Foundation
import LibSignalClient

struct SecureMessagingAddress: Codable, Hashable {
    let userID: String
    let serverDeviceID: String
    let signalDeviceID: UInt32

    func validated() throws -> SecureMessagingAddress {
        guard SecureMessagingValidation.isCanonicalUUID(userID),
              SecureMessagingValidation.isCanonicalUUID(serverDeviceID),
              (1...127).contains(signalDeviceID)
        else { throw SecureMessagingCryptoError.invalidAddress }
        return self
    }

    func protocolAddress() throws -> ProtocolAddress {
        _ = try validated()
        return try ProtocolAddress(name: userID, deviceId: signalDeviceID)
    }
}

struct SecureMessagingRosterDevice: Codable, Hashable {
    let address: SecureMessagingAddress
    let registrationID: UInt32
    let identityKeySHA256: String

    func validated() throws -> SecureMessagingRosterDevice {
        _ = try address.validated()
        guard (1...16_380).contains(registrationID),
              SecureMessagingValidation.isSHA256(identityKeySHA256)
        else { throw SecureMessagingCryptoError.staleRoster }
        return self
    }
}

struct SecureMessagingPublicPreKey: Codable, Hashable {
    let id: UInt32
    let publicKey: Data
    let signature: Data?
}

struct SecureMessagingLocalPublicBundle: Codable, Hashable {
    let protocolVersion: String
    let registrationID: UInt32
    let identityKey: Data
    let identityKeyChange: Bool
    let signedPreKey: SecureMessagingPublicPreKey
    let oneTimePreKeys: [SecureMessagingPublicPreKey]
    let pqPreKeys: [SecureMessagingPublicPreKey]
    let pqLastResortPreKey: SecureMessagingPublicPreKey
}

struct SecureMessagingProvisioningResult {
    let state: SecureMessagingPersistentState
    let bundle: SecureMessagingLocalPublicBundle
}

struct SecureMessagingRemoteKeyBundle {
    let device: SecureMessagingRosterDevice
    let identityKey: Data
    let signedPreKey: SecureMessagingPublicPreKey
    let oneTimePreKey: SecureMessagingPublicPreKey?
    let pqPreKey: SecureMessagingPublicPreKey
}

struct SecureMessagingOutboundEnvelope: Codable, Hashable {
    let recipientDeviceID: String
    let envelopeType: String
    let ciphertext: Data
}

/// This exact fanout is persisted before any network send. Retries reuse these bytes and are
/// permitted only while the authoritative roster revision and device bindings remain unchanged.
struct SecureMessagingCommittedFanout: Codable, Hashable {
    let clientMessageID: String
    let conversationID: String
    let rosterRevision: String
    let replyToMessageID: String?
    let rosterDevices: [SecureMessagingRosterDevice]
    let envelopes: [SecureMessagingOutboundEnvelope]
}

struct SecureMessagingEncryptionResult {
    let state: SecureMessagingPersistentState
    let fanout: SecureMessagingCommittedFanout
}

struct SecureMessagingInboundEnvelope {
    let messageID: String
    let clientMessageID: String
    let conversationID: String
    let rosterRevision: String
    let replyToMessageID: String?
    let sender: SecureMessagingRosterDevice
    let localRecipient: SecureMessagingAddress
    let envelopeType: String
    let ciphertext: Data
}

struct SecureMessagingDecryptionResult {
    let state: SecureMessagingPersistentState
    let text: String
}

actor SecureMessagingCryptoEngine {
    static let shared = SecureMessagingCryptoEngine()

    private static let protocolVersion = "v2"
    private static let maximumPreKeyID: UInt32 = 16_777_215
    static let uploadPreKeyCount = 100

    func provision(
        from currentState: SecureMessagingPersistentState,
        identityKeyChange: Bool = false,
        preKeyCount: Int = SecureMessagingCryptoEngine.uploadPreKeyCount
    ) throws -> SecureMessagingProvisioningResult {
        guard (1...SecureMessagingCryptoEngine.uploadPreKeyCount).contains(preKeyCount) else {
            throw SecureMessagingCryptoError.recordLimitExceeded
        }
        guard currentState.pendingPublication == nil else {
            throw SecureMessagingCryptoError.staleState
        }
        var state = currentState
        if identityKeyChange || state.identityKeyPair == nil || state.registrationID == nil {
            let identity = IdentityKeyPair.generate()
            state = .empty
            state.identityKeyPair = identity.serialize()
            state.registrationID = UInt32.random(in: 1...16_380)
        }

        let store = try KitSignalProtocolStore(state: state)
        let identity = try store.identityKeyPair(context: KitSignalProtocolStore.context)
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1_000)

        let signedPreKeyID = try nextMonotonicID(in: store.state.signedPreKeys)
        let signedPrivateKey = PrivateKey.generate()
        let signedPublicKey = signedPrivateKey.publicKey.serialize()
        let signedSignature = identity.privateKey.generateSignature(message: signedPublicKey)
        let signedRecord = try SignedPreKeyRecord(
            id: signedPreKeyID,
            timestamp: timestamp,
            privateKey: signedPrivateKey,
            signature: signedSignature
        )
        try store.storeSignedPreKey(
            signedRecord,
            id: signedPreKeyID,
            context: KitSignalProtocolStore.context
        )

        var oneTimePreKeys: [SecureMessagingPublicPreKey] = []
        oneTimePreKeys.reserveCapacity(preKeyCount)
        for _ in 0..<preKeyCount {
            let id = try nextRandomID(in: store.state.preKeys)
            let privateKey = PrivateKey.generate()
            let record = try PreKeyRecord(id: id, privateKey: privateKey)
            try store.storePreKey(record, id: id, context: KitSignalProtocolStore.context)
            oneTimePreKeys.append(
                SecureMessagingPublicPreKey(
                    id: id,
                    publicKey: privateKey.publicKey.serialize(),
                    signature: nil
                )
            )
        }

        var pqPreKeys: [SecureMessagingPublicPreKey] = []
        pqPreKeys.reserveCapacity(preKeyCount)
        for _ in 0..<preKeyCount {
            let id = try nextRandomID(in: store.state.kyberPreKeys)
            pqPreKeys.append(
                try generateKyberPreKey(
                    id: id,
                    timestamp: timestamp,
                    identity: identity,
                    store: store,
                    lastResort: false
                )
            )
        }

        let lastResortID = try nextMonotonicID(
            in: store.state.kyberPreKeys,
            consideringOnly: store.state.lastResortKyberPreKeyIDs
        )
        let lastResort = try generateKyberPreKey(
            id: lastResortID,
            timestamp: timestamp,
            identity: identity,
            store: store,
            lastResort: true
        )

        let bundle = SecureMessagingLocalPublicBundle(
            protocolVersion: Self.protocolVersion,
            registrationID: try store.localRegistrationId(context: KitSignalProtocolStore.context),
            identityKey: identity.identityKey.serialize(),
            identityKeyChange: identityKeyChange,
            signedPreKey: SecureMessagingPublicPreKey(
                id: signedPreKeyID,
                publicKey: signedPublicKey,
                signature: signedSignature
            ),
            oneTimePreKeys: oneTimePreKeys,
            pqPreKeys: pqPreKeys,
            pqLastResortPreKey: lastResort
        )
        var stateToCommit = store.exportedState()
        // The exact public bytes must be committed atomically with their matching private records
        // before HTTP publication. A crash can then only cause an idempotent republish.
        stateToCommit.pendingPublication = bundle
        return SecureMessagingProvisioningResult(state: stateToCommit, bundle: bundle)
    }

    func bindEnrollment(
        _ binding: SecureMessagingEnrollmentBinding,
        to currentState: SecureMessagingPersistentState
    ) throws -> SecureMessagingPersistentState {
        guard SecureMessagingValidation.isCanonicalUUID(binding.userID),
              SecureMessagingValidation.isCanonicalUUID(binding.serverDeviceID),
              (1...127).contains(binding.signalDeviceID),
              (1...16_380).contains(binding.registrationID),
              binding.enrollmentEpoch > 0,
              binding.bundleVersion > 0,
              SecureMessagingValidation.isSHA256(binding.identityKeySHA256),
              SecureMessagingValidation.isSHA256(binding.signedPreKeySHA256),
              SecureMessagingValidation.isSHA256(binding.pqLastResortPreKeySHA256),
              currentState.registrationID == binding.registrationID,
              let identityBytes = currentState.identityKeyPair
        else { throw SecureMessagingCryptoError.staleRoster }
        let identity = try IdentityKeyPair(bytes: identityBytes).identityKey.serialize()
        guard SecureMessagingValidation.sha256Hex(identity) == binding.identityKeySHA256 else {
            throw SecureMessagingCryptoError.identityChanged
        }

        if let pending = currentState.pendingPublication {
            guard pending.registrationID == binding.registrationID,
                  SecureMessagingValidation.sha256Hex(pending.identityKey)
                    == binding.identityKeySHA256,
                  pending.signedPreKey.id == binding.signedPreKeyID,
                  SecureMessagingValidation.sha256Hex(pending.signedPreKey.publicKey)
                    == binding.signedPreKeySHA256,
                  pending.pqLastResortPreKey.id == binding.pqLastResortPreKeyID,
                  SecureMessagingValidation.sha256Hex(pending.pqLastResortPreKey.publicKey)
                    == binding.pqLastResortPreKeySHA256,
                  currentState.signedPreKeys[
                    KitSignalProtocolStore.recordKey(binding.signedPreKeyID)
                  ] != nil,
                  currentState.kyberPreKeys[
                    KitSignalProtocolStore.recordKey(binding.pqLastResortPreKeyID)
                  ] != nil,
                  currentState.lastResortKyberPreKeyIDs.contains(
                    binding.pqLastResortPreKeyID
                  )
            else { throw SecureMessagingCryptoError.staleState }
        } else if currentState.enrollment == nil {
            // A first enrollment is confirmed only from a locally committed pending bundle.
            throw SecureMessagingCryptoError.notProvisioned
        }
        if let previous = currentState.enrollment {
            guard previous.userID == binding.userID,
                  previous.serverDeviceID == binding.serverDeviceID,
                  previous.signalDeviceID == binding.signalDeviceID,
                  previous.registrationID == binding.registrationID,
                  previous.enrollmentEpoch == binding.enrollmentEpoch,
                  previous.identityKeySHA256 == binding.identityKeySHA256,
                  binding.bundleVersion >= previous.bundleVersion
            else { throw SecureMessagingCryptoError.identityChanged }

            if currentState.pendingPublication == nil {
                if previous.hasCompleteKeyCommitment {
                    guard binding.bundleVersion == previous.bundleVersion,
                          binding.signedPreKeyID == previous.signedPreKeyID,
                          binding.signedPreKeySHA256 == previous.signedPreKeySHA256,
                          binding.pqLastResortPreKeyID == previous.pqLastResortPreKeyID,
                          binding.pqLastResortPreKeySHA256
                            == previous.pqLastResortPreKeySHA256
                    else { throw SecureMessagingCryptoError.identityChanged }
                } else {
                    // Older app builds persisted only the identity commitment. Upgrade that
                    // binding exactly once, but only when the server's current signed/PQ keys
                    // are proven to match private records already stored on this installation.
                    guard binding.bundleVersion == previous.bundleVersion,
                          try localKeyRecordsMatch(binding, in: currentState)
                    else { throw SecureMessagingCryptoError.identityChanged }
                }
            }
        }
        var state = currentState
        state.enrollment = binding
        state.pendingPublication = nil
        return state
    }

    private func localKeyRecordsMatch(
        _ binding: SecureMessagingEnrollmentBinding,
        in state: SecureMessagingPersistentState
    ) throws -> Bool {
        guard binding.hasCompleteKeyCommitment,
              let signedBytes = state.signedPreKeys[
                KitSignalProtocolStore.recordKey(binding.signedPreKeyID)
              ],
              let pqBytes = state.kyberPreKeys[
                KitSignalProtocolStore.recordKey(binding.pqLastResortPreKeyID)
              ],
              state.lastResortKyberPreKeyIDs.contains(binding.pqLastResortPreKeyID)
        else { return false }

        let signed = try SignedPreKeyRecord(bytes: signedBytes)
        let pq = try KyberPreKeyRecord(bytes: pqBytes)
        guard signed.id == binding.signedPreKeyID,
              pq.id == binding.pqLastResortPreKeyID
        else { return false }
        let signedHash = SecureMessagingValidation.sha256Hex(
            try signed.publicKey().serialize()
        )
        let pqHash = SecureMessagingValidation.sha256Hex(
            try pq.publicKey().serialize()
        )
        return signedHash == binding.signedPreKeySHA256
            && pqHash == binding.pqLastResortPreKeySHA256
    }

    func establishSessions(
        currentState: SecureMessagingPersistentState,
        localSender: SecureMessagingAddress,
        bundles: [SecureMessagingRemoteKeyBundle]
    ) throws -> SecureMessagingPersistentState {
        _ = try localSender.validated()
        try requireLocalBinding(localSender, in: currentState)
        guard !bundles.isEmpty, bundles.count <= 99 else {
            throw SecureMessagingCryptoError.staleRoster
        }
        let store = try KitSignalProtocolStore(state: currentState)
        let localAddress = try localSender.protocolAddress()

        for remote in bundles.sorted(by: { lhs, rhs in
            if lhs.device.address.userID == rhs.device.address.userID {
                return lhs.device.address.signalDeviceID < rhs.device.address.signalDeviceID
            }
            return lhs.device.address.userID < rhs.device.address.userID
        }) {
            _ = try remote.device.validated()
            let address = try remote.device.address.protocolAddress()
            let identity = try IdentityKey(bytes: remote.identityKey)
            let signedPublicKey = try PublicKey(remote.signedPreKey.publicKey)
            let pqPublicKey = try KEMPublicKey(remote.pqPreKey.publicKey)
            guard let signedSignature = remote.signedPreKey.signature,
                  let pqSignature = remote.pqPreKey.signature,
                  try identity.publicKey.verifySignature(
                    message: remote.signedPreKey.publicKey,
                    signature: signedSignature
                  ),
                  try identity.publicKey.verifySignature(
                    message: remote.pqPreKey.publicKey,
                    signature: pqSignature
                  )
            else { throw SecureMessagingCryptoError.invalidSignature }
            guard SecureMessagingValidation.sha256Hex(remote.identityKey)
                    == remote.device.identityKeySHA256
            else { throw SecureMessagingCryptoError.identityChanged }
            if let pinned = try store.identity(for: address, context: KitSignalProtocolStore.context) {
                guard pinned.serialize() == remote.identityKey else {
                    throw SecureMessagingCryptoError.identityChanged
                }
            }

            let preKeyBundle: PreKeyBundle
            if let oneTime = remote.oneTimePreKey {
                preKeyBundle = try PreKeyBundle(
                    registrationId: remote.device.registrationID,
                    deviceId: remote.device.address.signalDeviceID,
                    prekeyId: oneTime.id,
                    prekey: PublicKey(oneTime.publicKey),
                    signedPrekeyId: remote.signedPreKey.id,
                    signedPrekey: signedPublicKey,
                    signedPrekeySignature: signedSignature,
                    identity: identity,
                    kyberPrekeyId: remote.pqPreKey.id,
                    kyberPrekey: pqPublicKey,
                    kyberPrekeySignature: pqSignature
                )
            } else {
                preKeyBundle = try PreKeyBundle(
                    registrationId: remote.device.registrationID,
                    deviceId: remote.device.address.signalDeviceID,
                    signedPrekeyId: remote.signedPreKey.id,
                    signedPrekey: signedPublicKey,
                    signedPrekeySignature: signedSignature,
                    identity: identity,
                    kyberPrekeyId: remote.pqPreKey.id,
                    kyberPrekey: pqPublicKey,
                    kyberPrekeySignature: pqSignature
                )
            }
            try processPreKeyBundle(
                preKeyBundle,
                for: address,
                ourAddress: localAddress,
                sessionStore: store,
                identityStore: store,
                context: KitSignalProtocolStore.context
            )
            guard let session = try store.loadSession(
                for: address,
                context: KitSignalProtocolStore.context
            ), session.hasCurrentState(requirePqRatio: 1.0),
                  try session.remoteRegistrationId() == remote.device.registrationID
            else { throw SecureMessagingCryptoError.sessionUnavailable }
            try store.bindRemoteDevice(remote.device.address)
        }
        return store.exportedState()
    }

    /// Returns only recipients that need a fresh prekey bundle. Existing sessions are preserved;
    /// consuming and processing a new prekey bundle for every send would reset healthy ratchets and
    /// needlessly exhaust the peer's one-time keys.
    func recipientsRequiringSession(
        currentState: SecureMessagingPersistentState,
        localSender: SecureMessagingAddress,
        recipients: [SecureMessagingRosterDevice]
    ) throws -> [SecureMessagingRosterDevice] {
        try requireLocalBinding(localSender, in: currentState)
        guard !recipients.isEmpty,
              recipients.count <= SecureMessagingWire.maximumRecipientDevices,
              Set(recipients.map(\.address.serverDeviceID)).count == recipients.count
        else { throw SecureMessagingCryptoError.staleRoster }

        let store = try KitSignalProtocolStore(state: currentState)
        var missing: [SecureMessagingRosterDevice] = []
        for recipient in recipients {
            _ = try recipient.validated()
            let address = try recipient.address.protocolAddress()
            if let pinned = try store.identity(
                for: address,
                context: KitSignalProtocolStore.context
            ), SecureMessagingValidation.sha256Hex(pinned.serialize())
                != recipient.identityKeySHA256 {
                throw SecureMessagingCryptoError.identityChanged
            }

            let bindingMatches = try store.remoteDeviceBindingMatches(recipient.address)
            let session = try store.loadSession(
                for: address,
                context: KitSignalProtocolStore.context
            )
            if bindingMatches,
               let session,
               session.hasCurrentState(requirePqRatio: 1.0),
               try session.remoteRegistrationId() == recipient.registrationID {
                continue
            }
            // A server-device UUID being rebound to another Signal address is an authenticated
            // identity transition, not ordinary first-contact setup. The lifecycle sync processor
            // must handle it explicitly rather than silently trusting a replacement key here.
            if try store.hasConflictingRemoteDeviceBinding(recipient.address) {
                throw SecureMessagingCryptoError.identityChanged
            }
            missing.append(recipient)
        }
        return missing
    }

    func invalidatingRemoteDevice(
        currentState: SecureMessagingPersistentState,
        serverDeviceID: String,
        userID: String,
        previousIdentityKeySHA256: String?
    ) throws -> SecureMessagingPersistentState {
        guard SecureMessagingValidation.isCanonicalUUID(serverDeviceID),
              SecureMessagingValidation.isCanonicalUUID(userID),
              previousIdentityKeySHA256.map(SecureMessagingValidation.isSHA256) ?? true
        else { throw SecureMessagingCryptoError.invalidContent }
        guard currentState.enrollment?.serverDeviceID != serverDeviceID else {
            throw SecureMessagingCryptoError.identityChanged
        }
        var state = currentState
        let keys = state.remoteServerDeviceBindings.compactMap { key, value in
            value == serverDeviceID ? key : nil
        }
        for key in keys {
            guard key.hasPrefix("\(userID):") else {
                throw SecureMessagingCryptoError.identityChanged
            }
            if let expectedHash = previousIdentityKeySHA256,
               let identity = state.remoteIdentities[key],
               SecureMessagingValidation.sha256Hex(identity) != expectedHash {
                throw SecureMessagingCryptoError.identityChanged
            }
            state.remoteServerDeviceBindings.removeValue(forKey: key)
            state.remoteIdentities.removeValue(forKey: key)
            state.sessions.removeValue(forKey: key)
        }
        return state
    }

    func invalidatingRemoteUser(
        currentState: SecureMessagingPersistentState,
        userID: String
    ) throws -> SecureMessagingPersistentState {
        guard SecureMessagingValidation.isCanonicalUUID(userID),
              currentState.enrollment?.userID != userID
        else { throw SecureMessagingCryptoError.identityChanged }
        var state = currentState
        let prefix = "\(userID):"
        state.remoteServerDeviceBindings.keys.filter { $0.hasPrefix(prefix) }.forEach {
            state.remoteServerDeviceBindings.removeValue(forKey: $0)
            state.remoteIdentities.removeValue(forKey: $0)
            state.sessions.removeValue(forKey: $0)
        }
        return state
    }

    func encryptText(
        currentState: SecureMessagingPersistentState,
        sender: SecureMessagingAddress,
        conversationID: String,
        clientMessageID: String,
        rosterRevision: String,
        replyToMessageID: String?,
        text: String,
        recipients: [SecureMessagingRosterDevice],
        maximumTextUnicodeScalars: Int = 8_000
    ) throws -> SecureMessagingEncryptionResult {
        try requireLocalBinding(sender, in: currentState)
        guard SecureMessagingValidation.isCanonicalUUID(conversationID),
              SecureMessagingValidation.isCanonicalUUID(clientMessageID),
              replyToMessageID.map(SecureMessagingValidation.isCanonicalUUID) ?? true,
              SecureMessagingValidation.isRosterRevision(rosterRevision),
              !recipients.isEmpty,
              recipients.count <= 99,
              Set(recipients.map(\.address.serverDeviceID)).count == recipients.count,
              Set(recipients.map { "\($0.address.userID):\($0.address.signalDeviceID)" }).count
                == recipients.count
        else { throw SecureMessagingCryptoError.staleRoster }

        let content = try SecureMessagingTextContent(
            clientMessageID: clientMessageID,
            conversationID: conversationID,
            rosterRevision: rosterRevision,
            sender: sender,
            replyToMessageID: replyToMessageID,
            text: text,
            maximumTextUnicodeScalars: maximumTextUnicodeScalars
        ).encoded()
        let store = try KitSignalProtocolStore(state: currentState)
        let localAddress = try sender.protocolAddress()
        var envelopes: [SecureMessagingOutboundEnvelope] = []
        envelopes.reserveCapacity(recipients.count)

        for recipient in recipients.sorted(by: { lhs, rhs in
            lhs.address.serverDeviceID < rhs.address.serverDeviceID
        }) {
            _ = try recipient.validated()
            try store.requireRemoteDeviceBinding(recipient.address)
            let address = try recipient.address.protocolAddress()
            guard let session = try store.loadSession(
                for: address,
                context: KitSignalProtocolStore.context
            ), session.hasCurrentState(requirePqRatio: 1.0),
                  try session.remoteRegistrationId() == recipient.registrationID,
                  let identity = try store.identity(
                    for: address,
                    context: KitSignalProtocolStore.context
                  ), SecureMessagingValidation.sha256Hex(identity.serialize())
                    == recipient.identityKeySHA256
            else { throw SecureMessagingCryptoError.sessionUnavailable }

            let ciphertext = try signalEncrypt(
                message: content,
                for: address,
                localAddress: localAddress,
                sessionStore: store,
                identityStore: store,
                context: KitSignalProtocolStore.context
            )
            let envelopeType: String
            switch ciphertext.messageType {
            case .preKey: envelopeType = "signal-prekey-v2"
            case .whisper: envelopeType = "signal-message-v2"
            default: throw SecureMessagingCryptoError.unsupportedEnvelope
            }
            let serialized = ciphertext.serialize()
            guard !serialized.isEmpty, serialized.count <= 1_500_000 else {
                throw SecureMessagingCryptoError.recordLimitExceeded
            }
            envelopes.append(
                SecureMessagingOutboundEnvelope(
                    recipientDeviceID: recipient.address.serverDeviceID,
                    envelopeType: envelopeType,
                    ciphertext: serialized
                )
            )
        }

        return SecureMessagingEncryptionResult(
            state: store.exportedState(),
            fanout: SecureMessagingCommittedFanout(
                clientMessageID: clientMessageID,
                conversationID: conversationID,
                rosterRevision: rosterRevision,
                replyToMessageID: replyToMessageID,
                rosterDevices: recipients,
                envelopes: envelopes
            )
        )
    }

    func decryptText(
        currentState: SecureMessagingPersistentState,
        incoming: SecureMessagingInboundEnvelope,
        maximumTextUnicodeScalars: Int = 8_000
    ) throws -> SecureMessagingDecryptionResult {
        try requireLocalBinding(incoming.localRecipient, in: currentState)
        guard SecureMessagingValidation.isCanonicalUUID(incoming.messageID),
              SecureMessagingValidation.isCanonicalUUID(incoming.clientMessageID),
              SecureMessagingValidation.isCanonicalUUID(incoming.conversationID),
              incoming.replyToMessageID.map(SecureMessagingValidation.isCanonicalUUID) ?? true,
              SecureMessagingValidation.isRosterRevision(incoming.rosterRevision),
              !incoming.ciphertext.isEmpty,
              incoming.ciphertext.count <= 1_500_000
        else { throw SecureMessagingCryptoError.invalidContent }
        _ = try incoming.sender.validated()

        let store = try KitSignalProtocolStore(state: currentState)
        let remoteAddress = try incoming.sender.address.protocolAddress()
        let localAddress = try incoming.localRecipient.protocolAddress()
        let plaintext: Data

        switch incoming.envelopeType {
        case "signal-prekey-v2":
            let message = try PreKeySignalMessage(bytes: incoming.ciphertext)
            guard try message.registrationId() == incoming.sender.registrationID,
                  SecureMessagingValidation.sha256Hex(message.identityKey.serialize())
                    == incoming.sender.identityKeySHA256
            else { throw SecureMessagingCryptoError.identityChanged }
            if let pinned = try store.identity(
                for: remoteAddress,
                context: KitSignalProtocolStore.context
            ) {
                guard pinned.serialize() == message.identityKey.serialize() else {
                    throw SecureMessagingCryptoError.identityChanged
                }
            }
            plaintext = try signalDecryptPreKey(
                message: message,
                from: remoteAddress,
                localAddress: localAddress,
                sessionStore: store,
                identityStore: store,
                preKeyStore: store,
                signedPreKeyStore: store,
                kyberPreKeyStore: store,
                context: KitSignalProtocolStore.context
            )
            try store.bindRemoteDevice(incoming.sender.address)
        case "signal-message-v2":
            try store.requireRemoteDeviceBinding(incoming.sender.address)
            try verifySession(incoming.sender, address: remoteAddress, store: store)
            plaintext = try signalDecrypt(
                message: SignalMessage(bytes: incoming.ciphertext),
                from: remoteAddress,
                to: localAddress,
                sessionStore: store,
                identityStore: store,
                context: KitSignalProtocolStore.context
            )
        default:
            throw SecureMessagingCryptoError.unsupportedEnvelope
        }

        try verifySession(incoming.sender, address: remoteAddress, store: store)
        let decoded = try SecureMessagingTextContent.decode(
            plaintext,
            maximumTextUnicodeScalars: maximumTextUnicodeScalars
        )
        guard decoded.clientMessageID == incoming.clientMessageID,
              decoded.conversationID == incoming.conversationID,
              decoded.rosterRevision == incoming.rosterRevision,
              decoded.sender == incoming.sender.address,
              decoded.replyToMessageID == incoming.replyToMessageID
        else { throw SecureMessagingCryptoError.invalidContent }
        return SecureMessagingDecryptionResult(state: store.exportedState(), text: decoded.text)
    }

    private func verifySession(
        _ sender: SecureMessagingRosterDevice,
        address: ProtocolAddress,
        store: KitSignalProtocolStore
    ) throws {
        guard let session = try store.loadSession(
            for: address,
            context: KitSignalProtocolStore.context
        ), session.hasCurrentState(requirePqRatio: 1.0),
              try session.remoteRegistrationId() == sender.registrationID,
              let identity = try store.identity(
                for: address,
                context: KitSignalProtocolStore.context
              ), SecureMessagingValidation.sha256Hex(identity.serialize())
                == sender.identityKeySHA256
        else { throw SecureMessagingCryptoError.identityChanged }
    }

    private func requireLocalBinding(
        _ address: SecureMessagingAddress,
        in state: SecureMessagingPersistentState
    ) throws {
        _ = try address.validated()
        guard let enrollment = state.enrollment,
              enrollment.userID == address.userID,
              enrollment.serverDeviceID == address.serverDeviceID,
              enrollment.signalDeviceID == address.signalDeviceID,
              enrollment.registrationID == state.registrationID
        else { throw SecureMessagingCryptoError.notProvisioned }
    }

    private func generateKyberPreKey(
        id: UInt32,
        timestamp: UInt64,
        identity: IdentityKeyPair,
        store: KitSignalProtocolStore,
        lastResort: Bool
    ) throws -> SecureMessagingPublicPreKey {
        let keyPair = KEMKeyPair.generate()
        let publicKey = keyPair.publicKey.serialize()
        let signature = identity.privateKey.generateSignature(message: publicKey)
        let record = try KyberPreKeyRecord(
            id: id,
            timestamp: timestamp,
            keyPair: keyPair,
            signature: signature
        )
        try store.storeKyberPreKey(record, id: id, context: KitSignalProtocolStore.context)
        if lastResort { try store.markLastResortKyberPreKey(id) }
        return SecureMessagingPublicPreKey(id: id, publicKey: publicKey, signature: signature)
    }

    private func nextRandomID(in records: [String: Data]) throws -> UInt32 {
        for _ in 0...Self.maximumPreKeyID {
            let candidate = UInt32.random(in: 0...Self.maximumPreKeyID)
            if records[KitSignalProtocolStore.recordKey(candidate)] == nil { return candidate }
        }
        throw SecureMessagingCryptoError.recordLimitExceeded
    }

    private func nextMonotonicID(
        in records: [String: Data],
        consideringOnly subset: Set<UInt32>? = nil
    ) throws -> UInt32 {
        let ids = subset ?? Set(records.keys.compactMap(UInt32.init))
        let candidate = ids.max().map { UInt64($0) + 1 } ?? 0
        guard candidate <= UInt64(Self.maximumPreKeyID),
              records[KitSignalProtocolStore.recordKey(UInt32(candidate))] == nil
        else { throw SecureMessagingCryptoError.recordLimitExceeded }
        return UInt32(candidate)
    }
}

private struct SecureMessagingTextContent: Equatable {
    let clientMessageID: String
    let conversationID: String
    let rosterRevision: String
    let sender: SecureMessagingAddress
    let replyToMessageID: String?
    let text: String

    init(
        clientMessageID: String,
        conversationID: String,
        rosterRevision: String,
        sender: SecureMessagingAddress,
        replyToMessageID: String?,
        text: String,
        maximumTextUnicodeScalars: Int = 8_000
    ) throws {
        guard SecureMessagingValidation.isCanonicalUUID(clientMessageID),
              SecureMessagingValidation.isCanonicalUUID(conversationID),
              SecureMessagingValidation.isRosterRevision(rosterRevision),
              replyToMessageID.map(SecureMessagingValidation.isCanonicalUUID) ?? true,
              maximumTextUnicodeScalars > 0,
              !text.unicodeScalars.isEmpty,
              text.unicodeScalars.count <= maximumTextUnicodeScalars,
              !text.unicodeScalars.contains(where: { $0.value == 0 })
        else { throw SecureMessagingCryptoError.invalidContent }
        _ = try sender.validated()
        self.clientMessageID = clientMessageID
        self.conversationID = conversationID
        self.rosterRevision = rosterRevision
        self.sender = sender
        self.replyToMessageID = replyToMessageID
        self.text = text
    }

    func encoded() throws -> Data {
        let object: [String: Any] = [
            "schema": "kit.messaging.content.v1",
            "type": "text",
            "client_message_id": clientMessageID,
            "conversation_id": conversationID,
            "roster_revision": rosterRevision,
            "sender_user_id": sender.userID,
            "sender_device_id": sender.serverDeviceID,
            "sender_signal_device_id": Int(sender.signalDeviceID),
            "reply_to_message_id": replyToMessageID ?? NSNull(),
            "text": text,
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard !data.isEmpty, data.count <= 64 * 1_024 else {
            throw SecureMessagingCryptoError.invalidContent
        }
        return data
    }

    static func decode(
        _ data: Data,
        maximumTextUnicodeScalars: Int = 8_000
    ) throws -> SecureMessagingTextContent {
        guard !data.isEmpty, data.count <= 64 * 1_024,
              String(data: data, encoding: .utf8) != nil,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == SecureMessagingValidation.contentMembers,
              object["schema"] as? String == "kit.messaging.content.v1",
              object["type"] as? String == "text",
              let clientMessageID = object["client_message_id"] as? String,
              let conversationID = object["conversation_id"] as? String,
              let rosterRevision = object["roster_revision"] as? String,
              let senderUserID = object["sender_user_id"] as? String,
              let senderDeviceID = object["sender_device_id"] as? String,
              let signalDeviceNumber = object["sender_signal_device_id"] as? NSNumber,
              CFGetTypeID(signalDeviceNumber) != CFBooleanGetTypeID(),
              signalDeviceNumber.doubleValue == Double(signalDeviceNumber.uint32Value),
              let text = object["text"] as? String
        else { throw SecureMessagingCryptoError.invalidContent }
        let rawReply = object["reply_to_message_id"]
        let reply: String?
        if rawReply is NSNull {
            reply = nil
        } else if let value = rawReply as? String {
            reply = value
        } else {
            throw SecureMessagingCryptoError.invalidContent
        }
        return try SecureMessagingTextContent(
            clientMessageID: clientMessageID,
            conversationID: conversationID,
            rosterRevision: rosterRevision,
            sender: SecureMessagingAddress(
                userID: senderUserID,
                serverDeviceID: senderDeviceID,
                signalDeviceID: signalDeviceNumber.uint32Value
            ),
            replyToMessageID: reply,
            text: text,
            maximumTextUnicodeScalars: maximumTextUnicodeScalars
        )
    }
}

enum SecureMessagingValidation {
    static let contentMembers: Set<String> = [
        "schema", "type", "client_message_id", "conversation_id", "roster_revision",
        "sender_user_id", "sender_device_id", "sender_signal_device_id",
        "reply_to_message_id", "text",
    ]

    static func isCanonicalUUID(_ value: String) -> Bool {
        guard value.count == 36, value == value.lowercased(), let uuid = UUID(uuidString: value) else {
            return false
        }
        return uuid.uuidString.lowercased() == value
    }

    static func isCanonicalPositiveDecimalID(_ value: String) -> Bool {
        guard let first = value.utf8.first, (49...57).contains(first) else {
            return false
        }
        return value.utf8.dropFirst().allSatisfy { (48...57).contains($0) }
    }

    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    static func isRosterRevision(_ value: String) -> Bool {
        let prefix = "v1:sha256:"
        return value.hasPrefix(prefix) && isSHA256(String(value.dropFirst(prefix.count)))
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
