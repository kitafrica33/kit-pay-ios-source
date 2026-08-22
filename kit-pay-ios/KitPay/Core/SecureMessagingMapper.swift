import CoreFoundation
import CryptoKit
import Foundation

enum SecureMessagingRosterUse: String, Codable, Equatable {
    case current
    case historical
}

struct SecureMessagingFrozenRosterDevice: Codable, Equatable {
    let enrollmentEpoch: Int64?
    let bundleVersion: Int
    let signedPreKeyID: UInt32
    let signedPreKeyPublicKey: Data
    let signedPreKeySHA256: String
    let signedPreKeySignature: Data
}

struct SecureMessagingRosterSnapshot: Codable, Equatable {
    let use: SecureMessagingRosterUse
    let conversationID: String
    let rosterRevision: String
    let devices: [SecureMessagingRosterDevice]
    let frozenDevices: [String: SecureMessagingFrozenRosterDevice]

    func recipients(excluding currentDeviceID: String) throws -> [SecureMessagingRosterDevice] {
        _ = try SecureMessagingMapper.validatedRosterDevices(in: self)
        guard use == .current,
              SecureMessagingValidation.isCanonicalUUID(currentDeviceID),
              devices.contains(where: { $0.address.serverDeviceID == currentDeviceID })
        else {
            throw SecureMessagingCryptoError.staleRoster
        }
        let recipients = devices.filter { $0.address.serverDeviceID != currentDeviceID }
        guard !recipients.isEmpty, recipients.count <= SecureMessagingWire.maximumRecipientDevices
        else { throw SecureMessagingCryptoError.staleRoster }
        return recipients
    }

    func frozenDevice(_ deviceID: String) -> SecureMessagingFrozenRosterDevice? {
        frozenDevices[deviceID]
    }
}

struct SecureMessagingHistoryMessageIdentity: Equatable, Sendable {
    let messageID: String
    let clientMessageID: String
    let conversationID: String
    let senderUserID: String
    let senderDeviceID: String
    let senderEnrollmentEpoch: Int64
    let senderSignalDeviceID: UInt32
    let rosterRevision: String
    let kind: SecureMessagingMessageKind
    let replyToMessageID: String?
    let sentAt: Date

    var retainedMetadata: SecureMessagingRetainedMessageMetadata {
        SecureMessagingRetainedMessageMetadata(
            clientMessageID: clientMessageID,
            senderDeviceID: senderDeviceID,
            senderEnrollmentEpoch: senderEnrollmentEpoch,
            senderSignalDeviceID: senderSignalDeviceID,
            rosterRevision: rosterRevision,
            kind: kind,
            replyToMessageID: replyToMessageID
        )
    }
}

struct SecureMessagingHistoryInboundEnvelope {
    let cryptoEnvelope: SecureMessagingInboundEnvelope
    let original: SecureMessagingHistoryMessageIdentity
    let targetDeviceID: String
    let targetEnrollmentEpoch: Int64
    let transferClientMessageID: String
    let transferRosterRevision: String
    let rawAttachments: [EncryptedAttachmentDTO?]?
}

struct SecureMessagingAuthenticatedHistory {
    let original: SecureMessagingHistoryMessageIdentity
    let text: String
}

/// Cross-platform authenticated wrapper used by Android and iOS history donors. The server can
/// route and store this ciphertext but cannot alter any original-message field without making the
/// descriptor comparison fail after Signal decryption.
enum SecureMessagingHistoryBackfillCodec {
    static let maximumDescriptorBytes = 48 * 1_024
    static let maximumDescriptorUnicodeScalars = 48 * 1_024

    private static let schema = "kit.messaging.history.v1"
    private static let type = "history_backfill"
    private static let members: Set<String> = [
        "schema", "type", "transfer_client_message_id", "target_device_id",
        "target_enrollment_epoch", "transfer_roster_revision", "message_id",
        "client_message_id", "conversation_id", "sender_user_id", "sender_device_id",
        "sender_enrollment_epoch", "sender_signal_device_id", "original_roster_revision",
        "kind", "reply_to_message_id", "sent_at", "text",
    ]
    private static let integerMembers: Set<String> = [
        "target_enrollment_epoch", "sender_enrollment_epoch", "sender_signal_device_id",
    ]

    static func deterministicTransferID(
        messageID: String,
        targetDeviceID: String,
        targetEnrollmentEpoch: Int64,
        donorDeviceID: String,
        donorEnrollmentEpoch: Int64,
        transferRosterRevision: String
    ) throws -> String {
        guard SecureMessagingValidation.isCanonicalUUID(messageID),
              SecureMessagingValidation.isCanonicalUUID(targetDeviceID),
              SecureMessagingValidation.isCanonicalUUID(donorDeviceID),
              targetEnrollmentEpoch > 0,
              donorEnrollmentEpoch > 0,
              SecureMessagingValidation.isRosterRevision(transferRosterRevision)
        else { throw SecureMessagingCryptoError.invalidContent }
        let material = [
            schema,
            messageID,
            targetDeviceID,
            String(targetEnrollmentEpoch),
            donorDeviceID,
            String(donorEnrollmentEpoch),
            transferRosterRevision,
        ].joined(separator: "\0")
        var digest = Array(SHA256.hash(data: Data(material.utf8)))
        digest[6] = (digest[6] & 0x0f) | 0x50
        digest[8] = (digest[8] & 0x3f) | 0x80
        let uuid = UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        ))
        return uuid.uuidString.lowercased()
    }

    static func encode(
        transferClientMessageID: String,
        targetDeviceID: String,
        targetEnrollmentEpoch: Int64,
        transferRosterRevision: String,
        candidate: SecureMessagingHistoryMessageIdentity,
        rawSentAt: String,
        retained: LocalMessage
    ) throws -> String {
        guard SecureMessagingValidation.isCanonicalUUID(transferClientMessageID),
              SecureMessagingValidation.isCanonicalUUID(targetDeviceID),
              targetEnrollmentEpoch > 0,
              SecureMessagingValidation.isRosterRevision(transferRosterRevision),
              retained.serverMessageId == candidate.messageID,
              retained.conversationId == candidate.conversationID,
              retained.senderId == candidate.senderUserID,
              retained.secureMessagingHistory == candidate.retainedMetadata,
              let retainedSentAt = retained.sentAt,
              sameMillisecond(retainedSentAt, candidate.sentAt),
              parseDate(rawSentAt) == candidate.sentAt,
              !retained.body.isEmpty,
              !retained.body.unicodeScalars.contains(where: { $0.value == 0 })
        else { throw SecureMessagingCryptoError.invalidContent }
        let authenticatedKind: SecureMessagingMessageKind =
            KitMediaMessageDescriptor.attachments(for: retained.body).isEmpty
                ? .encrypted
                : .encryptedAttachment
        guard authenticatedKind == candidate.kind else {
            throw SecureMessagingCryptoError.invalidContent
        }

        let object: [String: Any] = [
            "schema": schema,
            "type": type,
            "transfer_client_message_id": transferClientMessageID,
            "target_device_id": targetDeviceID,
            "target_enrollment_epoch": targetEnrollmentEpoch,
            "transfer_roster_revision": transferRosterRevision,
            "message_id": candidate.messageID,
            "client_message_id": candidate.clientMessageID,
            "conversation_id": candidate.conversationID,
            "sender_user_id": candidate.senderUserID,
            "sender_device_id": candidate.senderDeviceID,
            "sender_enrollment_epoch": candidate.senderEnrollmentEpoch,
            "sender_signal_device_id": Int(candidate.senderSignalDeviceID),
            "original_roster_revision": candidate.rosterRevision,
            "kind": candidate.kind.rawValue,
            "reply_to_message_id": candidate.replyToMessageID ?? NSNull(),
            "sent_at": rawSentAt,
            "text": retained.body,
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard !data.isEmpty,
              data.count <= maximumDescriptorBytes,
              let encoded = String(data: data, encoding: .utf8)
        else { throw SecureMessagingCryptoError.invalidContent }
        return encoded
    }

    static func authenticate(
        _ descriptor: String,
        incoming: SecureMessagingHistoryInboundEnvelope
    ) throws -> SecureMessagingAuthenticatedHistory {
        let data = Data(descriptor.utf8)
        guard !data.isEmpty,
              data.count <= maximumDescriptorBytes,
              String(data: data, encoding: .utf8) == descriptor,
              strictTopLevelMembers(in: data) == members
        else { throw SecureMessagingCryptoError.invalidContent }
        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SecureMessagingCryptoError.invalidContent
            }
            object = decoded
        } catch {
            throw SecureMessagingCryptoError.invalidContent
        }
        guard Set(object.keys) == members,
              object["schema"] as? String == schema,
              object["type"] as? String == type,
              let transferClientMessageID = object["transfer_client_message_id"] as? String,
              let targetDeviceID = object["target_device_id"] as? String,
              let targetEnrollmentEpoch = positiveInt64(object["target_enrollment_epoch"]),
              let transferRosterRevision = object["transfer_roster_revision"] as? String,
              let messageID = object["message_id"] as? String,
              let clientMessageID = object["client_message_id"] as? String,
              let conversationID = object["conversation_id"] as? String,
              let senderUserID = object["sender_user_id"] as? String,
              let senderDeviceID = object["sender_device_id"] as? String,
              let senderEnrollmentEpoch = positiveInt64(object["sender_enrollment_epoch"]),
              let rawSenderSignalDeviceID = positiveInt64(object["sender_signal_device_id"]),
              let senderSignalDeviceID = UInt32(exactly: rawSenderSignalDeviceID),
              (1...127).contains(senderSignalDeviceID),
              let originalRosterRevision = object["original_roster_revision"] as? String,
              let rawKind = object["kind"] as? String,
              let kind = SecureMessagingMessageKind(rawValue: rawKind),
              let rawSentAt = object["sent_at"] as? String,
              let sentAt = parseDate(rawSentAt),
              let text = object["text"] as? String,
              !text.isEmpty,
              !text.unicodeScalars.contains(where: { $0.value == 0 })
        else { throw SecureMessagingCryptoError.invalidContent }
        let replyToMessageID: String?
        if object["reply_to_message_id"] is NSNull {
            replyToMessageID = nil
        } else if let value = object["reply_to_message_id"] as? String {
            replyToMessageID = value
        } else {
            throw SecureMessagingCryptoError.invalidContent
        }
        let decoded = SecureMessagingHistoryMessageIdentity(
            messageID: messageID,
            clientMessageID: clientMessageID,
            conversationID: conversationID,
            senderUserID: senderUserID,
            senderDeviceID: senderDeviceID,
            senderEnrollmentEpoch: senderEnrollmentEpoch,
            senderSignalDeviceID: senderSignalDeviceID,
            rosterRevision: originalRosterRevision,
            kind: kind,
            replyToMessageID: replyToMessageID,
            sentAt: sentAt
        )
        try validate(decoded)
        guard transferClientMessageID == incoming.transferClientMessageID,
              targetDeviceID == incoming.targetDeviceID,
              targetEnrollmentEpoch == incoming.targetEnrollmentEpoch,
              transferRosterRevision == incoming.transferRosterRevision,
              decoded == incoming.original
        else { throw SecureMessagingCryptoError.invalidContent }
        let authenticatedAttachments = KitMediaMessageDescriptor.attachments(for: text)
        let authenticatedKind: SecureMessagingMessageKind = authenticatedAttachments.isEmpty
            ? .encrypted
            : .encryptedAttachment
        guard authenticatedKind == decoded.kind,
              (!text.hasPrefix(KitMediaMessageDescriptor.prefix)
                  || !authenticatedAttachments.isEmpty),
              KitMediaMessageDescriptor.validates(
                  incoming.rawAttachments,
                  against: authenticatedAttachments
              )
        else { throw SecureMessagingCryptoError.invalidContent }
        return SecureMessagingAuthenticatedHistory(original: decoded, text: text)
    }

    static func validate(_ identity: SecureMessagingHistoryMessageIdentity) throws {
        guard SecureMessagingValidation.isCanonicalUUID(identity.messageID),
              SecureMessagingValidation.isCanonicalUUID(identity.clientMessageID),
              SecureMessagingValidation.isCanonicalUUID(identity.conversationID),
              SecureMessagingValidation.isCanonicalUUID(identity.senderUserID),
              SecureMessagingValidation.isCanonicalUUID(identity.senderDeviceID),
              identity.senderEnrollmentEpoch > 0,
              (1...127).contains(identity.senderSignalDeviceID),
              SecureMessagingValidation.isRosterRevision(identity.rosterRevision),
              identity.replyToMessageID.map(SecureMessagingValidation.isCanonicalUUID) ?? true
        else { throw SecureMessagingCryptoError.invalidContent }
    }

    static func parseDate(_ rawValue: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: rawValue) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: rawValue)
    }

    static func sameMillisecond(_ lhs: Date, _ rhs: Date) -> Bool {
        Int64((lhs.timeIntervalSince1970 * 1_000).rounded(.towardZero))
            == Int64((rhs.timeIntervalSince1970 * 1_000).rounded(.towardZero))
    }

    private static func positiveInt64(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue == Double(number.int64Value),
              number.int64Value > 0
        else { return nil }
        return number.int64Value
    }

    /// `JSONSerialization` keeps only one value when an object repeats a member. Scan the bounded,
    /// already UTF-8 descriptor first so escaped spellings of the same member cannot bypass the
    /// exact-member check. Full JSON structure and value types remain owned by `JSONSerialization`.
    private static func strictTopLevelMembers(in data: Data) -> Set<String>? {
        let bytes = Array(data)
        var index = 0

        func skipWhitespace() {
            while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) {
                index += 1
            }
        }

        func consumeString() -> Range<Int>? {
            guard index < bytes.count, bytes[index] == 34 else { return nil }
            let start = index
            index += 1
            while index < bytes.count {
                switch bytes[index] {
                case 34:
                    index += 1
                    return start..<index
                case 92:
                    index += 2
                default:
                    index += 1
                }
            }
            return nil
        }

        func consumeValue() -> Bool {
            skipWhitespace()
            guard index < bytes.count else { return false }
            if bytes[index] == 34 {
                return consumeString() != nil
            }
            if bytes[index] == 123 || bytes[index] == 91 {
                var closing: [UInt8] = [bytes[index] == 123 ? 125 : 93]
                index += 1
                while index < bytes.count, let expected = closing.last {
                    switch bytes[index] {
                    case 34:
                        guard consumeString() != nil else { return false }
                    case 123:
                        closing.append(125)
                        index += 1
                    case 91:
                        closing.append(93)
                        index += 1
                    default:
                        if bytes[index] == expected {
                            closing.removeLast()
                            index += 1
                        } else {
                            index += 1
                        }
                    }
                }
                return closing.isEmpty
            }
            let start = index
            while index < bytes.count,
                  ![9, 10, 13, 32, 44, 125].contains(bytes[index]) {
                index += 1
            }
            return index > start
        }

        skipWhitespace()
        guard index < bytes.count, bytes[index] == 123 else { return nil }
        index += 1
        skipWhitespace()
        var result: Set<String> = []
        if index < bytes.count, bytes[index] == 125 {
            index += 1
        } else {
            while true {
                guard let range = consumeString(),
                      let value = try? JSONSerialization.jsonObject(
                          with: Data(bytes[range]),
                          options: [.fragmentsAllowed]
                      ),
                      let name = value as? String,
                      result.insert(name).inserted
                else { return nil }
                skipWhitespace()
                guard index < bytes.count, bytes[index] == 58 else { return nil }
                index += 1
                skipWhitespace()
                let valueStart = index
                guard consumeValue() else { return nil }
                if integerMembers.contains(name) {
                    let encoded = bytes[valueStart..<index]
                    guard let first = encoded.first,
                          (49...57).contains(first),
                          encoded.dropFirst().allSatisfy({ (48...57).contains($0) })
                    else { return nil }
                }
                skipWhitespace()
                guard index < bytes.count else { return nil }
                if bytes[index] == 125 {
                    index += 1
                    break
                }
                guard bytes[index] == 44 else { return nil }
                index += 1
                skipWhitespace()
            }
        }
        skipWhitespace()
        return index == bytes.count ? result : nil
    }
}

enum SecureMessagingMapper {
    static func publicationRequest(
        from bundle: SecureMessagingLocalPublicBundle
    ) throws -> PublishMessagingKeyBundleRequest {
        guard bundle.protocolVersion == SecureMessagingWire.protocolVersion,
              let signedSignature = bundle.signedPreKey.signature,
              let lastResortSignature = bundle.pqLastResortPreKey.signature
        else { throw SecureMessagingCryptoError.invalidContent }
        return try PublishMessagingKeyBundleRequest(
            registrationId: Int(bundle.registrationID),
            identityKey: bundle.identityKey.base64EncodedString(),
            identityKeyChange: bundle.identityKeyChange,
            signedPrekey: MessagingSignedPrekeyRequest(
                prekeyId: Int(bundle.signedPreKey.id),
                publicKey: bundle.signedPreKey.publicKey.base64EncodedString(),
                signature: signedSignature.base64EncodedString()
            ),
            oneTimePrekeys: bundle.oneTimePreKeys.map {
                MessagingOneTimePrekeyRequest(
                    prekeyId: Int($0.id),
                    publicKey: $0.publicKey.base64EncodedString()
                )
            },
            pqPrekeys: try bundle.pqPreKeys.map { preKey in
                guard let signature = preKey.signature else {
                    throw SecureMessagingCryptoError.invalidSignature
                }
                return MessagingPQPrekeyRequest(
                    prekeyId: Int(preKey.id),
                    publicKey: preKey.publicKey.base64EncodedString(),
                    signature: signature.base64EncodedString()
                )
            },
            pqLastResortPrekey: MessagingPQPrekeyRequest(
                prekeyId: Int(bundle.pqLastResortPreKey.id),
                publicKey: bundle.pqLastResortPreKey.publicKey.base64EncodedString(),
                signature: lastResortSignature.base64EncodedString()
            )
        )
    }

    static func enrollmentBinding(
        from status: MessagingKeyStatusDTO,
        userID: String
    ) throws -> SecureMessagingEnrollmentBinding {
        guard status.enrolled == true,
              status.protocolVersion == SecureMessagingWire.protocolVersion,
              let deviceID = status.deviceId,
              let rawSignalDeviceID = status.signalDeviceId,
              let rawRegistrationID = status.registrationId,
              let enrollmentEpoch = status.enrollmentEpoch,
              let identityKeySHA256 = status.identityKeySha256?.lowercased(),
              let bundleVersion = status.bundleVersion,
              let rawSignedPreKeyID = status.signedPrekeyId,
              let signedPreKeySHA256 = status.signedPrekeySha256?.lowercased(),
              let rawPQLastResortPreKeyID = status.pqLastResortPrekeyId,
              let pqLastResortPreKeySHA256 = status.pqLastResortPrekeySha256?.lowercased(),
              let signalDeviceID = UInt32(exactly: rawSignalDeviceID),
              let registrationID = UInt32(exactly: rawRegistrationID),
              let signedPreKeyID = UInt32(exactly: rawSignedPreKeyID),
              let pqLastResortPreKeyID = UInt32(exactly: rawPQLastResortPreKeyID),
              SecureMessagingValidation.isSHA256(identityKeySHA256),
              SecureMessagingValidation.isSHA256(signedPreKeySHA256),
              SecureMessagingValidation.isSHA256(pqLastResortPreKeySHA256)
        else { throw SecureMessagingCryptoError.notProvisioned }
        return SecureMessagingEnrollmentBinding(
            userID: userID,
            serverDeviceID: deviceID,
            signalDeviceID: signalDeviceID,
            registrationID: registrationID,
            enrollmentEpoch: enrollmentEpoch,
            identityKeySHA256: identityKeySHA256,
            bundleVersion: bundleVersion,
            signedPreKeyID: signedPreKeyID,
            signedPreKeySHA256: signedPreKeySHA256,
            pqLastResortPreKeyID: pqLastResortPreKeyID,
            pqLastResortPreKeySHA256: pqLastResortPreKeySHA256
        )
    }

    static func roster(
        from dto: MessagingDeviceRosterDTO,
        use: SecureMessagingRosterUse,
        expectedConversationID: String,
        currentDeviceID: String,
        currentUserID: String,
        expectedMemberUserIDs: Set<String>
    ) throws -> SecureMessagingRosterSnapshot {
        guard dto.conversationId == expectedConversationID,
              SecureMessagingValidation.isCanonicalUUID(expectedConversationID),
              SecureMessagingValidation.isCanonicalUUID(currentDeviceID),
              SecureMessagingValidation.isCanonicalUUID(currentUserID),
              expectedMemberUserIDs.count == 2,
              expectedMemberUserIDs.contains(currentUserID),
              expectedMemberUserIDs.allSatisfy(SecureMessagingValidation.isCanonicalUUID),
              let revision = dto.rosterRevision,
              SecureMessagingValidation.isRosterRevision(revision),
              dto.hashAlgorithm == "sha256",
              let rosterHash = dto.rosterHash?.lowercased(),
              SecureMessagingValidation.isSHA256(rosterHash),
              revision == "v1:sha256:\(rosterHash)",
              let rawDevices = dto.devices,
              rawDevices.count >= 2,
              rawDevices.count <= 100
        else { throw SecureMessagingCryptoError.staleRoster }
        var canonicalDeviceRows: [CanonicalRosterDevice] = []
        var frozenDevices: [String: SecureMessagingFrozenRosterDevice] = [:]
        let devices = try rawDevices.map { raw -> SecureMessagingRosterDevice in
            guard let raw,
                  let deviceID = raw.deviceId,
                  let userID = raw.userId,
                  let rawSignalDeviceID = raw.signalDeviceId,
                  let rawRegistrationID = raw.registrationId,
                  raw.protocolVersion == SecureMessagingWire.protocolVersion,
                  let bundleVersion = raw.bundleVersion,
                  bundleVersion > 0,
                  let identityKey = decodeSignalValue(raw.identityKey, count: 33, type: 5),
                  let identityKeySHA256 = raw.identityKeySha256?.lowercased(),
                  SecureMessagingValidation.sha256Hex(identityKey) == identityKeySHA256,
                  let signed = raw.signedPrekey,
                  let signedID = uint32(signed.prekeyId),
                  let signedPublicKey = decodeSignalValue(signed.publicKey, count: 33, type: 5),
                  let signedHash = signed.publicKeySha256?.lowercased(),
                  SecureMessagingValidation.sha256Hex(signedPublicKey) == signedHash,
                  let signedSignature = decodeSignalValue(signed.signature, count: 64),
                  let publishedAt = raw.publishedAt,
                  let publishedDate = parseTimestamp(publishedAt),
                  validRotation(raw.rotatedAt, publishedAt: publishedDate),
                  let identityKeyChangedAt = raw.identityKeyChangedAt,
                  parseTimestamp(identityKeyChangedAt) != nil,
                  let bundleVersionChangedAt = raw.bundleVersionChangedAt,
                  parseTimestamp(bundleVersionChangedAt) != nil,
                  let signalDeviceID = UInt32(exactly: rawSignalDeviceID),
                  let registrationID = UInt32(exactly: rawRegistrationID)
            else { throw SecureMessagingCryptoError.staleRoster }
            let enrollmentEpoch: Int64?
            switch use {
            case .current:
                guard let value = raw.enrollmentEpoch, value > 0 else {
                    throw SecureMessagingCryptoError.staleRoster
                }
                enrollmentEpoch = value
            case .historical:
                guard raw.enrollmentEpoch == nil else {
                    throw SecureMessagingCryptoError.staleRoster
                }
                enrollmentEpoch = nil
            }
            canonicalDeviceRows.append(
                CanonicalRosterDevice(
                    deviceID: deviceID,
                    userID: userID,
                    signalDeviceID: rawSignalDeviceID,
                    registrationID: rawRegistrationID,
                    protocolVersion: SecureMessagingWire.protocolVersion,
                    bundleVersion: bundleVersion,
                    identityKey: identityKey.base64EncodedString(),
                    identityKeySHA256: identityKeySHA256,
                    signedPreKeyID: Int(signedID),
                    signedPreKey: signedPublicKey.base64EncodedString(),
                    signedPreKeySHA256: signedHash,
                    signedPreKeySignature: signedSignature.base64EncodedString(),
                    publishedAt: publishedAt,
                    rotatedAt: raw.rotatedAt,
                    identityKeyChangedAt: identityKeyChangedAt,
                    bundleVersionChangedAt: bundleVersionChangedAt
                )
            )
            frozenDevices[deviceID] = SecureMessagingFrozenRosterDevice(
                enrollmentEpoch: enrollmentEpoch,
                bundleVersion: bundleVersion,
                signedPreKeyID: signedID,
                signedPreKeyPublicKey: signedPublicKey,
                signedPreKeySHA256: signedHash,
                signedPreKeySignature: signedSignature
            )
            return try SecureMessagingRosterDevice(
                address: SecureMessagingAddress(
                    userID: userID,
                    serverDeviceID: deviceID,
                    signalDeviceID: signalDeviceID
                ),
                registrationID: registrationID,
                identityKeySHA256: identityKeySHA256
            ).validated()
        }
        guard Set(devices.map(\.address.serverDeviceID)).count == devices.count,
              Set(devices.map { "\($0.address.userID):\($0.address.signalDeviceID)" }).count
                == devices.count,
              Set(devices.map(\.address.userID)) == expectedMemberUserIDs,
              devices.filter({ $0.address.serverDeviceID == currentDeviceID }).count == 1,
              devices.first(where: { $0.address.serverDeviceID == currentDeviceID })?.address.userID
                == currentUserID,
              frozenDevices.count == devices.count,
              Set(frozenDevices.keys) == Set(devices.map(\.address.serverDeviceID)),
              devices == devices.sorted(by: canonicalRosterOrder),
              SecureMessagingValidation.sha256Hex(
                canonicalRosterBytes(
                    conversationID: expectedConversationID,
                    devices: canonicalDeviceRows
                )
              ) == rosterHash
        else { throw SecureMessagingCryptoError.staleRoster }
        return SecureMessagingRosterSnapshot(
            use: use,
            conversationID: expectedConversationID,
            rosterRevision: revision,
            devices: devices,
            frozenDevices: frozenDevices
        )
    }

    static func remoteBundles(
        from dto: ConsumedMessagingKeyBundlesDTO,
        roster: SecureMessagingRosterSnapshot,
        requestedRemoteDeviceIDs: Set<String>,
        localDeviceID: String
    ) throws -> [SecureMessagingRemoteKeyBundle] {
        let devicesByID = try validatedRosterDevices(in: roster)
        guard roster.use == .current,
              SecureMessagingValidation.isCanonicalUUID(localDeviceID),
              devicesByID[localDeviceID] != nil,
              !requestedRemoteDeviceIDs.isEmpty,
              requestedRemoteDeviceIDs.count <= SecureMessagingWire.maximumRecipientDevices,
              !requestedRemoteDeviceIDs.contains(localDeviceID),
              requestedRemoteDeviceIDs.allSatisfy(SecureMessagingValidation.isCanonicalUUID),
              requestedRemoteDeviceIDs.isSubset(of: Set(devicesByID.keys)),
              let rawBundles = dto.bundles,
              rawBundles.count == requestedRemoteDeviceIDs.count
        else { throw SecureMessagingCryptoError.staleRoster }

        let responseDeviceIDs = try rawBundles.map { raw -> String in
            guard let raw,
                  let deviceID = raw.deviceId,
                  SecureMessagingValidation.isCanonicalUUID(deviceID)
            else { throw SecureMessagingCryptoError.staleRoster }
            return deviceID
        }
        guard Set(responseDeviceIDs) == requestedRemoteDeviceIDs,
              Set(responseDeviceIDs).count == responseDeviceIDs.count,
              !responseDeviceIDs.contains(localDeviceID)
        else { throw SecureMessagingCryptoError.staleRoster }

        let bundles = try rawBundles.map { raw -> SecureMessagingRemoteKeyBundle in
            guard let raw,
                  raw.protocolVersion == SecureMessagingWire.protocolVersion,
                  raw.isCurrentDevice == false,
                  let deviceID = raw.deviceId,
                  let rosterDevice = devicesByID[deviceID],
                  let frozenDevice = roster.frozenDevice(deviceID),
                  raw.userId == rosterDevice.address.userID,
                  raw.signalDeviceId == Int(rosterDevice.address.signalDeviceID),
                  raw.registrationId == Int(rosterDevice.registrationID),
                  raw.bundleVersion == frozenDevice.bundleVersion,
                  raw.identityKeySha256 == rosterDevice.identityKeySHA256,
                  let identityKey = decodeSignalValue(raw.identityKey, count: 33, type: 5),
                  SecureMessagingValidation.sha256Hex(identityKey)
                    == rosterDevice.identityKeySHA256,
                  let signed = raw.signedPrekey,
                  let signedID = uint32(signed.prekeyId),
                  signedID == frozenDevice.signedPreKeyID,
                  let signedPublicKey = decodeSignalValue(
                    signed.publicKey,
                    count: 33,
                    type: 5
                  ),
                  signedPublicKey == frozenDevice.signedPreKeyPublicKey,
                  SecureMessagingValidation.sha256Hex(signedPublicKey)
                    == frozenDevice.signedPreKeySHA256,
                  signed.publicKeySha256.map({ $0 == frozenDevice.signedPreKeySHA256 }) ?? true,
                  let signedSignature = decodeSignalValue(signed.signature, count: 64),
                  signedSignature == frozenDevice.signedPreKeySignature,
                  let pq = raw.pqPrekey,
                  let pqID = uint32(pq.prekeyId),
                  let pqPublicKey = decodeSignalValue(pq.publicKey, count: 1_569, type: 8),
                  let pqSignature = decodeSignalValue(pq.signature, count: 64)
            else { throw SecureMessagingCryptoError.staleRoster }
            let oneTime: SecureMessagingPublicPreKey?
            if let rawOneTime = raw.oneTimePrekey {
                guard let id = uint32(rawOneTime.prekeyId),
                      let publicKey = decodeSignalValue(
                        rawOneTime.publicKey,
                        count: 33,
                        type: 5
                      )
                else { throw SecureMessagingCryptoError.staleRoster }
                oneTime = SecureMessagingPublicPreKey(
                    id: id,
                    publicKey: publicKey,
                    signature: nil
                )
            } else {
                oneTime = nil
            }
            return SecureMessagingRemoteKeyBundle(
                device: rosterDevice,
                identityKey: identityKey,
                signedPreKey: SecureMessagingPublicPreKey(
                    id: signedID,
                    publicKey: signedPublicKey,
                    signature: signedSignature
                ),
                oneTimePreKey: oneTime,
                pqPreKey: SecureMessagingPublicPreKey(
                    id: pqID,
                    publicKey: pqPublicKey,
                    signature: pqSignature
                )
            )
        }
        guard Set(bundles.map(\.device.address.serverDeviceID)) == requestedRemoteDeviceIDs else {
            throw SecureMessagingCryptoError.staleRoster
        }
        return bundles
    }

    static func sendRequest(
        from fanout: SecureMessagingCommittedFanout,
        attachments: [EncryptedAttachmentRequest] = []
    ) throws -> SendEncryptedMessageRequest {
        try SendEncryptedMessageRequest(
            clientMessageId: fanout.clientMessageID,
            rosterRevision: fanout.rosterRevision,
            kind: attachments.isEmpty ? .encrypted : .encryptedAttachment,
            replyToMessageId: fanout.replyToMessageID,
            envelopes: try fanout.envelopes.map { envelope in
                guard let type = SecureMessagingEnvelopeType(rawValue: envelope.envelopeType) else {
                    throw SecureMessagingCryptoError.unsupportedEnvelope
                }
                return try EncryptedDeviceEnvelopeRequest(
                    recipientDeviceId: envelope.recipientDeviceID,
                    envelopeType: type,
                    ciphertext: envelope.ciphertext.base64EncodedString()
                )
            },
            attachments: attachments
        )
    }

    static func inboundEnvelope(
        from dto: EncryptedMessageDTO,
        localRecipient: SecureMessagingAddress,
        localEnrollment: SecureMessagingEnrollmentBinding,
        roster: SecureMessagingRosterSnapshot
    ) throws -> SecureMessagingInboundEnvelope {
        let devicesByID = try validatedRosterDevices(in: roster)
        try validate(localEnrollment: localEnrollment)
        let enrollmentAddress = SecureMessagingAddress(
            userID: localEnrollment.userID,
            serverDeviceID: localEnrollment.serverDeviceID,
            signalDeviceID: localEnrollment.signalDeviceID
        )
        guard localRecipient == enrollmentAddress,
              let localRosterDevice = devicesByID[localRecipient.serverDeviceID],
              localRosterDevice.address == localRecipient,
              localRosterDevice.registrationID == localEnrollment.registrationID,
              localRosterDevice.identityKeySHA256 == localEnrollment.identityKeySHA256,
              let localFrozenDevice = roster.frozenDevice(localRecipient.serverDeviceID)
        else { throw SecureMessagingCryptoError.staleRoster }
        if roster.use == .current {
            guard localFrozenDevice.enrollmentEpoch == localEnrollment.enrollmentEpoch,
                  localFrozenDevice.bundleVersion == localEnrollment.bundleVersion,
                  localFrozenDevice.signedPreKeyID == localEnrollment.signedPreKeyID,
                  localFrozenDevice.signedPreKeySHA256 == localEnrollment.signedPreKeySHA256
            else { throw SecureMessagingCryptoError.staleRoster }
        }

        guard let messageID = dto.id,
              let clientMessageID = dto.clientMessageId,
              let conversationID = dto.conversationId,
              let rosterRevision = dto.rosterRevision,
              conversationID == roster.conversationID,
              rosterRevision == roster.rosterRevision,
              [
                  SecureMessagingMessageKind.encrypted.rawValue,
                  SecureMessagingMessageKind.encryptedAttachment.rawValue,
              ].contains(dto.kind),
              let senderDeviceID = dto.senderDeviceId,
              senderDeviceID != localRecipient.serverDeviceID,
              let senderEnrollmentEpoch = dto.senderEnrollmentEpoch,
              senderEnrollmentEpoch > 0,
              let rawSignalDeviceID = dto.senderSignalDeviceId,
              let rawRegistrationID = dto.senderRegistrationId,
              dto.senderProtocolVersion == SecureMessagingWire.protocolVersion,
              let senderBundleVersion = dto.senderBundleVersion,
              senderBundleVersion > 0,
              let identityKeySHA256 = dto.senderIdentityKeySha256,
              let senderUserID = dto.sender?.id,
              let rosterSender = devicesByID[senderDeviceID],
              let frozenSender = roster.frozenDevice(senderDeviceID),
              let envelope = dto.envelope,
              envelope.recipientDeviceId == localRecipient.serverDeviceID,
              envelope.recipientEnrollmentEpoch == localEnrollment.enrollmentEpoch,
              envelope.isHistoryBackfill == false,
              envelope.transferClientMessageId == nil,
              envelope.transferRosterRevision == nil,
              let cryptoSender = envelope.cryptoSender,
              let envelopeType = envelope.envelopeType,
              SecureMessagingEnvelopeType(rawValue: envelopeType) != nil,
              let ciphertext = decodeCanonicalBase64(envelope.ciphertext),
              let signalDeviceID = UInt32(exactly: rawSignalDeviceID),
              let registrationID = UInt32(exactly: rawRegistrationID),
              SecureMessagingValidation.isCanonicalUUID(messageID),
              SecureMessagingValidation.isCanonicalUUID(clientMessageID),
              SecureMessagingValidation.isCanonicalUUID(conversationID),
              SecureMessagingValidation.isRosterRevision(rosterRevision),
              SecureMessagingValidation.isSHA256(identityKeySHA256),
              dto.replyToMessageId.map(SecureMessagingValidation.isCanonicalUUID) ?? true,
              envelope.ciphertextSha256?.lowercased()
                == SecureMessagingValidation.sha256Hex(ciphertext)
        else { throw SecureMessagingCryptoError.invalidContent }

        guard cryptoSender.userId == senderUserID,
              cryptoSender.deviceId == senderDeviceID,
              cryptoSender.enrollmentEpoch == senderEnrollmentEpoch,
              cryptoSender.signalDeviceId == rawSignalDeviceID,
              cryptoSender.registrationId == rawRegistrationID,
              cryptoSender.protocolVersion == SecureMessagingWire.protocolVersion,
              cryptoSender.bundleVersion == senderBundleVersion,
              cryptoSender.identityKeySha256 == identityKeySHA256,
              rosterSender.address.userID == senderUserID,
              rosterSender.address.signalDeviceID == signalDeviceID,
              rosterSender.registrationID == registrationID,
              rosterSender.identityKeySHA256 == identityKeySHA256,
              frozenSender.bundleVersion == senderBundleVersion
        else { throw SecureMessagingCryptoError.identityChanged }
        switch roster.use {
        case .current:
            guard frozenSender.enrollmentEpoch == senderEnrollmentEpoch else {
                throw SecureMessagingCryptoError.identityChanged
            }
        case .historical:
            guard frozenSender.enrollmentEpoch == nil else {
                throw SecureMessagingCryptoError.staleRoster
            }
        }
        return SecureMessagingInboundEnvelope(
            messageID: messageID,
            clientMessageID: clientMessageID,
            conversationID: conversationID,
            rosterRevision: rosterRevision,
            replyToMessageID: dto.replyToMessageId,
            sender: try SecureMessagingRosterDevice(
                address: SecureMessagingAddress(
                    userID: senderUserID,
                    serverDeviceID: senderDeviceID,
                    signalDeviceID: signalDeviceID
                ),
                registrationID: registrationID,
                identityKeySHA256: identityKeySHA256
            ).validated(),
            localRecipient: localRecipient,
            envelopeType: envelopeType,
            ciphertext: ciphertext
        )
    }

    static func historyInboundEnvelope(
        from dto: EncryptedMessageDTO,
        localRecipient: SecureMessagingAddress,
        localEnrollment: SecureMessagingEnrollmentBinding,
        transferRoster: SecureMessagingRosterSnapshot
    ) throws -> SecureMessagingHistoryInboundEnvelope {
        let devicesByID = try validatedRosterDevices(in: transferRoster)
        try validate(localEnrollment: localEnrollment)
        let enrollmentAddress = SecureMessagingAddress(
            userID: localEnrollment.userID,
            serverDeviceID: localEnrollment.serverDeviceID,
            signalDeviceID: localEnrollment.signalDeviceID
        )
        let senderEnrollmentEpoch = dto.senderEnrollmentEpoch ?? 1
        guard transferRoster.use == .historical,
              localRecipient == enrollmentAddress,
              let localRosterDevice = devicesByID[localRecipient.serverDeviceID],
              localRosterDevice.address == localRecipient,
              localRosterDevice.registrationID == localEnrollment.registrationID,
              localRosterDevice.identityKeySHA256 == localEnrollment.identityKeySHA256,
              let messageID = dto.id,
              let clientMessageID = dto.clientMessageId,
              let conversationID = dto.conversationId,
              conversationID == transferRoster.conversationID,
              let originalRosterRevision = dto.rosterRevision,
              let kindRaw = dto.kind,
              let kind = SecureMessagingMessageKind(rawValue: kindRaw),
              let senderUserID = dto.sender?.id,
              let senderDeviceID = dto.senderDeviceId,
              senderEnrollmentEpoch > 0,
              let rawSenderSignalDeviceID = dto.senderSignalDeviceId,
              let senderSignalDeviceID = UInt32(exactly: rawSenderSignalDeviceID),
              (1...127).contains(senderSignalDeviceID),
              let senderRegistrationID = dto.senderRegistrationId,
              (1...16_380).contains(senderRegistrationID),
              dto.senderProtocolVersion == SecureMessagingWire.protocolVersion,
              let senderBundleVersion = dto.senderBundleVersion,
              senderBundleVersion > 0,
              let senderIdentityKeySHA256 = dto.senderIdentityKeySha256,
              SecureMessagingValidation.isSHA256(senderIdentityKeySHA256),
              let rawSentAt = dto.sentAt,
              let sentAt = SecureMessagingHistoryBackfillCodec.parseDate(rawSentAt),
              dto.revokedAt == nil,
              dto.reactions?.isEmpty == true,
              let rawAttachments = dto.attachments,
              rawAttachments.count <= SecureMessagingWire.maximumAttachments,
              rawAttachments.allSatisfy({ $0 != nil }),
              let envelope = dto.envelope,
              envelope.recipientDeviceId == localRecipient.serverDeviceID,
              envelope.recipientEnrollmentEpoch == localEnrollment.enrollmentEpoch,
              envelope.isHistoryBackfill == true,
              let transferClientMessageID = envelope.transferClientMessageId,
              let transferRosterRevision = envelope.transferRosterRevision,
              transferRosterRevision == transferRoster.rosterRevision,
              let cryptoSender = envelope.cryptoSender,
              cryptoSender.userId == localEnrollment.userID,
              let donorDeviceID = cryptoSender.deviceId,
              donorDeviceID != localRecipient.serverDeviceID,
              let donorEnrollmentEpoch = cryptoSender.enrollmentEpoch,
              donorEnrollmentEpoch > 0,
              let rawDonorSignalDeviceID = cryptoSender.signalDeviceId,
              let donorSignalDeviceID = UInt32(exactly: rawDonorSignalDeviceID),
              let rawDonorRegistrationID = cryptoSender.registrationId,
              let donorRegistrationID = UInt32(exactly: rawDonorRegistrationID),
              cryptoSender.protocolVersion == SecureMessagingWire.protocolVersion,
              let donorBundleVersion = cryptoSender.bundleVersion,
              donorBundleVersion > 0,
              let donorIdentityKeySHA256 = cryptoSender.identityKeySha256,
              SecureMessagingValidation.isSHA256(donorIdentityKeySHA256),
              let rosterDonor = devicesByID[donorDeviceID],
              rosterDonor.address.userID == localEnrollment.userID,
              rosterDonor.address.signalDeviceID == donorSignalDeviceID,
              rosterDonor.registrationID == donorRegistrationID,
              rosterDonor.identityKeySHA256 == donorIdentityKeySHA256,
              transferRoster.frozenDevice(donorDeviceID)?.bundleVersion == donorBundleVersion,
              let envelopeType = envelope.envelopeType,
              SecureMessagingEnvelopeType(rawValue: envelopeType) != nil,
              let ciphertext = decodeCanonicalBase64(envelope.ciphertext),
              envelope.ciphertextSha256?.lowercased()
                == SecureMessagingValidation.sha256Hex(ciphertext),
              SecureMessagingValidation.isCanonicalUUID(transferClientMessageID),
              SecureMessagingValidation.isRosterRevision(transferRosterRevision),
              SecureMessagingValidation.isRosterRevision(originalRosterRevision),
              Set(transferRoster.devices.map(\.address.userID)).contains(senderUserID)
        else { throw SecureMessagingCryptoError.invalidContent }

        let original = SecureMessagingHistoryMessageIdentity(
            messageID: messageID,
            clientMessageID: clientMessageID,
            conversationID: conversationID,
            senderUserID: senderUserID,
            senderDeviceID: senderDeviceID,
            senderEnrollmentEpoch: senderEnrollmentEpoch,
            senderSignalDeviceID: senderSignalDeviceID,
            rosterRevision: originalRosterRevision,
            kind: kind,
            replyToMessageID: dto.replyToMessageId,
            sentAt: sentAt
        )
        try SecureMessagingHistoryBackfillCodec.validate(original)
        let donor = try SecureMessagingRosterDevice(
            address: SecureMessagingAddress(
                userID: localEnrollment.userID,
                serverDeviceID: donorDeviceID,
                signalDeviceID: donorSignalDeviceID
            ),
            registrationID: donorRegistrationID,
            identityKeySHA256: donorIdentityKeySHA256
        ).validated()
        return SecureMessagingHistoryInboundEnvelope(
            cryptoEnvelope: SecureMessagingInboundEnvelope(
                messageID: messageID,
                clientMessageID: transferClientMessageID,
                conversationID: conversationID,
                rosterRevision: transferRosterRevision,
                replyToMessageID: nil,
                sender: donor,
                localRecipient: localRecipient,
                envelopeType: envelopeType,
                ciphertext: ciphertext
            ),
            original: original,
            targetDeviceID: localRecipient.serverDeviceID,
            targetEnrollmentEpoch: localEnrollment.enrollmentEpoch,
            transferClientMessageID: transferClientMessageID,
            transferRosterRevision: transferRosterRevision,
            rawAttachments: rawAttachments
        )
    }

    static func historyCandidateIdentity(
        from dto: EncryptedMessageDTO,
        expectedConversationID: String
    ) throws -> SecureMessagingHistoryMessageIdentity {
        let senderEnrollmentEpoch = dto.senderEnrollmentEpoch ?? 1
        guard let messageID = dto.id,
              let clientMessageID = dto.clientMessageId,
              dto.conversationId == expectedConversationID,
              let senderUserID = dto.sender?.id,
              let senderDeviceID = dto.senderDeviceId,
              senderEnrollmentEpoch > 0,
              let rawSenderSignalDeviceID = dto.senderSignalDeviceId,
              let senderSignalDeviceID = UInt32(exactly: rawSenderSignalDeviceID),
              (1...127).contains(senderSignalDeviceID),
              let senderRegistrationID = dto.senderRegistrationId,
              (1...16_380).contains(senderRegistrationID),
              dto.senderProtocolVersion == SecureMessagingWire.protocolVersion,
              let senderBundleVersion = dto.senderBundleVersion,
              senderBundleVersion > 0,
              let senderIdentityKeySHA256 = dto.senderIdentityKeySha256,
              SecureMessagingValidation.isSHA256(senderIdentityKeySHA256),
              let rosterRevision = dto.rosterRevision,
              let rawKind = dto.kind,
              let kind = SecureMessagingMessageKind(rawValue: rawKind),
              let sentAtRaw = dto.sentAt,
              let sentAt = SecureMessagingHistoryBackfillCodec.parseDate(sentAtRaw),
              dto.revokedAt == nil,
              dto.reactions?.isEmpty == true,
              let rawAttachments = dto.attachments,
              rawAttachments.count <= SecureMessagingWire.maximumAttachments,
              rawAttachments.allSatisfy({ $0 != nil })
        else { throw SecureMessagingCryptoError.invalidContent }
        let identity = SecureMessagingHistoryMessageIdentity(
            messageID: messageID,
            clientMessageID: clientMessageID,
            conversationID: expectedConversationID,
            senderUserID: senderUserID,
            senderDeviceID: senderDeviceID,
            senderEnrollmentEpoch: senderEnrollmentEpoch,
            senderSignalDeviceID: senderSignalDeviceID,
            rosterRevision: rosterRevision,
            kind: kind,
            replyToMessageID: dto.replyToMessageId,
            sentAt: sentAt
        )
        try SecureMessagingHistoryBackfillCodec.validate(identity)
        return identity
    }

    fileprivate static func validatedRosterDevices(
        in roster: SecureMessagingRosterSnapshot
    ) throws -> [String: SecureMessagingRosterDevice] {
        guard SecureMessagingValidation.isCanonicalUUID(roster.conversationID),
              SecureMessagingValidation.isRosterRevision(roster.rosterRevision),
              (2...100).contains(roster.devices.count),
              roster.frozenDevices.count == roster.devices.count,
              Set(roster.frozenDevices.keys)
                == Set(roster.devices.map(\.address.serverDeviceID)),
              roster.devices == roster.devices.sorted(by: canonicalRosterOrder)
        else { throw SecureMessagingCryptoError.staleRoster }

        var devicesByID: [String: SecureMessagingRosterDevice] = [:]
        var protocolAddresses: Set<String> = []
        for device in roster.devices {
            _ = try device.validated()
            let deviceID = device.address.serverDeviceID
            let protocolAddress = "\(device.address.userID):\(device.address.signalDeviceID)"
            guard devicesByID[deviceID] == nil,
                  protocolAddresses.insert(protocolAddress).inserted,
                  let frozen = roster.frozenDevice(deviceID),
                  frozen.bundleVersion > 0,
                  frozen.signedPreKeyID <= 16_777_215,
                  frozen.signedPreKeyPublicKey.count == 33,
                  frozen.signedPreKeyPublicKey.first == 5,
                  SecureMessagingValidation.isSHA256(frozen.signedPreKeySHA256),
                  SecureMessagingValidation.sha256Hex(frozen.signedPreKeyPublicKey)
                    == frozen.signedPreKeySHA256,
                  frozen.signedPreKeySignature.count == 64
            else { throw SecureMessagingCryptoError.staleRoster }
            switch roster.use {
            case .current:
                guard let epoch = frozen.enrollmentEpoch, epoch > 0 else {
                    throw SecureMessagingCryptoError.staleRoster
                }
            case .historical:
                guard frozen.enrollmentEpoch == nil else {
                    throw SecureMessagingCryptoError.staleRoster
                }
            }
            devicesByID[deviceID] = device
        }
        return devicesByID
    }

    private static func validate(
        localEnrollment: SecureMessagingEnrollmentBinding
    ) throws {
        guard SecureMessagingValidation.isCanonicalUUID(localEnrollment.userID),
              SecureMessagingValidation.isCanonicalUUID(localEnrollment.serverDeviceID),
              (1...127).contains(localEnrollment.signalDeviceID),
              (1...16_380).contains(localEnrollment.registrationID),
              localEnrollment.enrollmentEpoch > 0,
              localEnrollment.bundleVersion > 0,
              localEnrollment.signedPreKeyID <= 16_777_215,
              localEnrollment.pqLastResortPreKeyID <= 16_777_215,
              SecureMessagingValidation.isSHA256(localEnrollment.identityKeySHA256),
              SecureMessagingValidation.isSHA256(localEnrollment.signedPreKeySHA256),
              SecureMessagingValidation.isSHA256(localEnrollment.pqLastResortPreKeySHA256)
        else { throw SecureMessagingCryptoError.staleRoster }
    }

    private static func uint32(_ value: Int?) -> UInt32? {
        guard let value, (0...16_777_215).contains(value) else { return nil }
        return UInt32(value)
    }

    private static func decodeCanonicalBase64(_ value: String?) -> Data? {
        guard let value,
              let data = Data(base64Encoded: value),
              !data.isEmpty,
              data.count <= SecureMessagingWire.maximumCiphertextBytes,
              data.base64EncodedString() == value
        else { return nil }
        return data
    }

    private static func decodeSignalValue(
        _ value: String?,
        count: Int,
        type: UInt8? = nil
    ) -> Data? {
        guard let data = decodeCanonicalBase64(value), data.count == count else { return nil }
        if let type, data.first != type { return nil }
        return data
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func validRotation(_ value: String?, publishedAt: Date) -> Bool {
        guard let value else { return true }
        guard let rotation = parseTimestamp(value) else { return false }
        return rotation >= publishedAt
    }

    private static func canonicalRosterOrder(
        _ lhs: SecureMessagingRosterDevice,
        _ rhs: SecureMessagingRosterDevice
    ) -> Bool {
        if lhs.address.userID != rhs.address.userID {
            return lhs.address.userID < rhs.address.userID
        }
        if lhs.address.signalDeviceID != rhs.address.signalDeviceID {
            return lhs.address.signalDeviceID < rhs.address.signalDeviceID
        }
        return lhs.address.serverDeviceID < rhs.address.serverDeviceID
    }

    private struct CanonicalRosterDevice {
        let deviceID: String
        let userID: String
        let signalDeviceID: Int
        let registrationID: Int
        let protocolVersion: String
        let bundleVersion: Int
        let identityKey: String
        let identityKeySHA256: String
        let signedPreKeyID: Int
        let signedPreKey: String
        let signedPreKeySHA256: String
        let signedPreKeySignature: String
        let publishedAt: String
        let rotatedAt: String?
        let identityKeyChangedAt: String
        let bundleVersionChangedAt: String
    }

    private static func canonicalRosterBytes(
        conversationID: String,
        devices: [CanonicalRosterDevice]
    ) -> Data {
        var json = "{\"schema\":\"kit.messaging.device-roster.v1\",\"conversation_id\":"
        json += jsonString(conversationID)
        json += ",\"devices\":["
        for (index, device) in devices.enumerated() {
            if index > 0 { json.append(",") }
            json += "{\"device_id\":\(jsonString(device.deviceID))"
            json += ",\"user_id\":\(jsonString(device.userID))"
            json += ",\"signal_device_id\":\(device.signalDeviceID)"
            json += ",\"registration_id\":\(device.registrationID)"
            json += ",\"protocol_version\":\(jsonString(device.protocolVersion))"
            json += ",\"bundle_version\":\(device.bundleVersion)"
            json += ",\"identity_key\":\(jsonString(device.identityKey))"
            json += ",\"identity_key_sha256\":\(jsonString(device.identityKeySHA256))"
            json += ",\"signed_prekey\":{\"prekey_id\":\(device.signedPreKeyID)"
            json += ",\"public_key\":\(jsonString(device.signedPreKey))"
            json += ",\"public_key_sha256\":\(jsonString(device.signedPreKeySHA256))"
            json += ",\"signature\":\(jsonString(device.signedPreKeySignature))}"
            json += ",\"published_at\":\(jsonString(device.publishedAt))"
            json += ",\"rotated_at\":"
            json += device.rotatedAt.map(jsonString) ?? "null"
            json += ",\"identity_key_changed_at\":\(jsonString(device.identityKeyChangedAt))"
            json += ",\"bundle_version_changed_at\":\(jsonString(device.bundleVersionChangedAt))}"
        }
        json += "]}"
        return Data(json.utf8)
    }

    private static func jsonString(_ value: String) -> String {
        var encoded = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: encoded += "\\\""
            case 0x5c: encoded += "\\\\"
            case 0x08: encoded += "\\b"
            case 0x0c: encoded += "\\f"
            case 0x0a: encoded += "\\n"
            case 0x0d: encoded += "\\r"
            case 0x09: encoded += "\\t"
            case 0..<0x20:
                encoded += String(format: "\\u%04x", scalar.value)
            default:
                encoded.unicodeScalars.append(scalar)
            }
        }
        encoded += "\""
        return encoded
    }
}
