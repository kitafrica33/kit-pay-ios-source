import CommonCrypto
import CryptoKit
import Foundation
import Security

enum SecureMessageReservedPrefixPolicy {
    /// Canonical descriptors still parse only at byte zero. This broader check is solely a
    /// fail-closed display/ingestion boundary so whitespace cannot disguise internal wire data.
    static func beginsWithReservedPrefix(_ text: String, prefix: String) -> Bool {
        text.drop(while: { $0.isWhitespace }).hasPrefix(prefix)
    }
}

/// Ciphertext-only wire constants for Kit's reviewed secure-messaging v2 protocol.
///
/// These models deliberately contain no plaintext message property. They define only the HTTP
/// contract; a libsignal engine and durable ratchet store must validate/decrypt their contents
/// before anything is projected into the UI.
enum SecureMessagingWire {
    static let protocolVersion = "v2"
    static let protocolSuite = "signal-pqxdh-kyber1024-double-ratchet-v2"
    static let directConversationType = "direct"
    static let maximumKeyBatch = 100
    static let maximumRecipientDevices = 99
    static let maximumAttachments = 20
    static let maximumDeliveryAcknowledgements = 100
    static let maximumSyncPage = 100
    static let maximumHistoryPage = 50
    static let maximumCiphertextBytes = 1_500_000
    static let minimumAttachmentCiphertextBytes: Int64 = 64
    static let maximumAttachmentCiphertextBytes: Int64 = 10 * 1_024 * 1_024 + 64

    /// Every allowed type must be mirrored by the server's attachment upload validation and by
    /// the Android client before it ships; unknown types fail closed on both ends.
    static let allowedAttachmentMediaTypes: Set<String> = [
        "image/jpeg",
        "image/png",
        "image/webp",
        "image/gif",
        "audio/mp4",
        "audio/aac",
        "audio/mpeg",
        "audio/ogg",
        "video/mp4",
        "video/quicktime",
        "video/webm",
        "application/pdf",
        "application/zip",
        "application/msword",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "application/vnd.ms-excel",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "application/vnd.ms-powerpoint",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "text/plain",
        "text/csv",
        "application/octet-stream",
    ]
}

enum SecureMediaAttachmentError: LocalizedError, Equatable {
    case invalidImage
    case invalidMedia
    case invalidDescriptor
    case invalidCiphertext
    case cryptographyFailed
    case serverMetadataMismatch
    case incompatibleRecipient

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            "Choose a JPEG, PNG, WebP, or GIF image up to 10 MB."
        case .invalidMedia:
            "Choose a supported file up to 10 MB."
        case .invalidDescriptor:
            "This encrypted attachment has invalid authenticated metadata."
        case .invalidCiphertext:
            "This encrypted attachment failed its integrity check."
        case .cryptographyFailed:
            "The attachment could not be encrypted securely."
        case .serverMetadataMismatch:
            "Kit returned attachment metadata that does not match the encrypted message."
        case .incompatibleRecipient:
            "Voice notes, videos, and documents require the recipient to update Kit Pay on every iPhone."
        }
    }
}

/// Signal-compatible encrypted attachment framing shared with the Android client:
/// iv(16) || AES-256-CBC-PKCS7(plaintext) || HMAC-SHA256(iv || ciphertext)(32).
/// The server receives only the framed ciphertext and its digest. The 64-byte key material is
/// carried solely inside the per-device Signal envelope as part of `KitMediaMessageDescriptor`.
enum SecureMediaAttachmentCipher {
    /// The multipart transport currently materializes its body. Keep the bound conservative until
    /// authenticated streaming upload and download are available end to end.
    static let maximumPlaintextBytes = 10 * 1_024 * 1_024
    static let keyMaterialBytes = 64
    private static let aesKeyBytes = 32
    private static let macKeyBytes = 32
    private static let ivBytes = kCCBlockSizeAES128
    private static let macBytes = 32

    struct Encrypted: Equatable, Sendable {
        let ciphertext: Data
        let keyMaterial: Data
        let sha256Hex: String
        let plaintextByteSize: Int
    }

    static func encrypt(
        _ plaintext: Data,
        randomBytes: ((Int) throws -> Data)? = nil
    ) throws -> Encrypted {
        guard !plaintext.isEmpty, plaintext.count <= maximumPlaintextBytes else {
            throw SecureMediaAttachmentError.invalidMedia
        }
        let random = randomBytes ?? secureRandomBytes
        let keyMaterial = try random(keyMaterialBytes)
        let iv = try random(ivBytes)
        guard keyMaterial.count == keyMaterialBytes, iv.count == ivBytes else {
            throw SecureMediaAttachmentError.cryptographyFailed
        }
        let encryptedBody = try aesCrypt(
            operation: CCOperation(kCCEncrypt),
            input: plaintext,
            key: keyMaterial.prefixData(aesKeyBytes),
            iv: iv
        )
        var authenticatedFrame = Data()
        authenticatedFrame.reserveCapacity(iv.count + encryptedBody.count)
        authenticatedFrame.append(iv)
        authenticatedFrame.append(encryptedBody)
        let mac = HMAC<SHA256>.authenticationCode(
            for: authenticatedFrame,
            using: SymmetricKey(data: keyMaterial.suffixData(macKeyBytes))
        )
        var ciphertext = authenticatedFrame
        ciphertext.append(contentsOf: mac)
        guard Int64(ciphertext.count) >= SecureMessagingWire.minimumAttachmentCiphertextBytes,
              Int64(ciphertext.count) <= SecureMessagingWire.maximumAttachmentCiphertextBytes
        else { throw SecureMediaAttachmentError.invalidMedia }
        return Encrypted(
            ciphertext: ciphertext,
            keyMaterial: keyMaterial,
            sha256Hex: SHA256.hash(data: ciphertext).hexString,
            plaintextByteSize: plaintext.count
        )
    }

    static func decrypt(
        _ ciphertext: Data,
        keyMaterial: Data,
        expectedSHA256Hex: String
    ) throws -> Data {
        guard keyMaterial.count == keyMaterialBytes,
              Int64(ciphertext.count) >= SecureMessagingWire.minimumAttachmentCiphertextBytes,
              Int64(ciphertext.count) <= SecureMessagingWire.maximumAttachmentCiphertextBytes,
              SecureMessagingWirePolicy.isLowercaseSHA256(expectedSHA256Hex),
              timingSafeEqual(
                  Data(SHA256.hash(data: ciphertext)),
                  Data(hexString: expectedSHA256Hex)
              )
        else { throw SecureMediaAttachmentError.invalidCiphertext }

        let authenticatedLength = ciphertext.count - macBytes
        guard authenticatedLength > ivBytes else {
            throw SecureMediaAttachmentError.invalidCiphertext
        }
        let authenticatedFrame = ciphertext.prefixData(authenticatedLength)
        let suppliedMAC = ciphertext.suffixData(macBytes)
        let expectedMAC = Data(HMAC<SHA256>.authenticationCode(
            for: authenticatedFrame,
            using: SymmetricKey(data: keyMaterial.suffixData(macKeyBytes))
        ))
        guard timingSafeEqual(suppliedMAC, expectedMAC) else {
            throw SecureMediaAttachmentError.invalidCiphertext
        }
        let iv = authenticatedFrame.prefixData(ivBytes)
        let body = authenticatedFrame.dropFirst(ivBytes)
        do {
            return try aesCrypt(
                operation: CCOperation(kCCDecrypt),
                input: Data(body),
                key: keyMaterial.prefixData(aesKeyBytes),
                iv: iv
            )
        } catch {
            throw SecureMediaAttachmentError.invalidCiphertext
        }
    }

    private static func aesCrypt(
        operation: CCOperation,
        input: Data,
        key: Data,
        iv: Data
    ) throws -> Data {
        var output = Data(count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let outputCapacity = output.count
        let status: CCCryptorStatus = output.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            inputBytes.baseAddress,
                            input.count,
                            outputBytes.baseAddress,
                            outputCapacity,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess, moved <= output.count else {
            throw SecureMediaAttachmentError.cryptographyFailed
        }
        output.removeSubrange(moved..<output.count)
        return output
    }

    private static func secureRandomBytes(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw SecureMediaAttachmentError.cryptographyFailed
        }
        return data
    }

    private static func timingSafeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// Canonical media descriptor encrypted as the Signal message body. Fixed field order and strict
/// re-encoding make first sends, retries, sync events, and Android/iOS parsing byte-identical.
struct KitMediaMessageDescriptor: Equatable, Sendable {
    static let prefix = "KITMEDIA1:"
    private static let maximumDescriptorLength = 4_096
    static let maximumCaptionUTF8Bytes = 2_048
    /// Every non-caption field has a strict fixed upper bound. Reserving 512 encoded bytes for
    /// those fields lets captions use the remaining wire budget without accepting Unicode that
    /// expands past the canonical descriptor limit during percent encoding.
    private static let maximumEncodedCaptionBytes = maximumDescriptorLength - 512

    let attachmentID: String
    let storageKey: String
    let mediaType: String
    let ciphertextByteSize: Int64
    let ciphertextSHA256: String
    let keyMaterialBase64: String
    let plaintextByteSize: Int
    let caption: String?

    init(
        attachmentID: String,
        storageKey: String,
        mediaType: String,
        ciphertextByteSize: Int64,
        ciphertextSHA256: String,
        keyMaterial: Data,
        plaintextByteSize: Int,
        caption: String?
    ) throws {
        let normalizedCaption = caption?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let canonicalKey = keyMaterial.base64EncodedString()
        guard SecureMessagingWirePolicy.isCanonicalUUID(attachmentID),
              SecureMessagingWirePolicy.isCanonicalUUID(storageKey),
              SecureMessagingWire.allowedAttachmentMediaTypes.contains(mediaType),
              (SecureMessagingWire.minimumAttachmentCiphertextBytes
                  ... SecureMessagingWire.maximumAttachmentCiphertextBytes)
                  .contains(ciphertextByteSize),
              SecureMessagingWirePolicy.isLowercaseSHA256(ciphertextSHA256),
              keyMaterial.count == SecureMediaAttachmentCipher.keyMaterialBytes,
              (1 ... SecureMediaAttachmentCipher.maximumPlaintextBytes)
                  .contains(plaintextByteSize),
              Self.canEncodeCaption(normalizedCaption)
        else { throw SecureMediaAttachmentError.invalidDescriptor }
        self.attachmentID = attachmentID
        self.storageKey = storageKey
        self.mediaType = mediaType
        self.ciphertextByteSize = ciphertextByteSize
        self.ciphertextSHA256 = ciphertextSHA256
        keyMaterialBase64 = canonicalKey
        self.plaintextByteSize = plaintextByteSize
        self.caption = normalizedCaption
        guard encoded.count <= Self.maximumDescriptorLength else {
            throw SecureMediaAttachmentError.invalidDescriptor
        }
    }

    static func canEncodeCaption(_ caption: String?) -> Bool {
        guard let caption = caption?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        else { return true }
        return caption.utf8.count <= maximumCaptionUTF8Bytes
            && percentEncode(caption).utf8.count <= maximumEncodedCaptionBytes
    }

    var encoded: String {
        var value = Self.prefix
        value += "v=1"
        value += "&id=\(Self.percentEncode(attachmentID))"
        value += "&sk=\(Self.percentEncode(storageKey))"
        value += "&mt=\(Self.percentEncode(mediaType))"
        value += "&bs=\(ciphertextByteSize)"
        value += "&sha=\(Self.percentEncode(ciphertextSHA256))"
        value += "&key=\(Self.percentEncode(keyMaterialBase64))"
        value += "&ps=\(plaintextByteSize)"
        if let caption { value += "&cap=\(Self.percentEncode(caption))" }
        return value
    }

    var keyMaterial: Data? {
        guard let data = Data(base64Encoded: keyMaterialBase64),
              data.count == SecureMediaAttachmentCipher.keyMaterialBytes,
              data.base64EncodedString() == keyMaterialBase64
        else { return nil }
        return data
    }

    var attachmentRequest: EncryptedAttachmentRequest? {
        try? EncryptedAttachmentRequest(
            id: attachmentID,
            storageKey: storageKey,
            mediaType: mediaType,
            byteSize: ciphertextByteSize,
            ciphertextSha256: ciphertextSHA256
        )
    }

    static func parse(_ text: String) -> KitMediaMessageDescriptor? {
        guard text.hasPrefix(prefix), text.count <= maximumDescriptorLength else { return nil }
        var fields: [String: String] = [:]
        for pair in text.dropFirst(prefix.count).split(separator: "&", omittingEmptySubsequences: false) {
            guard let separator = pair.firstIndex(of: "="), separator != pair.startIndex else {
                return nil
            }
            let key = String(pair[..<separator])
            let encodedValue = String(pair[pair.index(after: separator)...])
            guard fields[key] == nil, let value = encodedValue.removingPercentEncoding else {
                return nil
            }
            fields[key] = value
        }
        guard fields["v"] == "1",
              let attachmentID = fields["id"]?.lowercased(),
              let storageKey = fields["sk"]?.lowercased(),
              let mediaType = fields["mt"]?.lowercased(),
              let size = fields["bs"].flatMap(Int64.init),
              let digest = fields["sha"]?.lowercased(),
              let key = fields["key"],
              let keyMaterial = Data(base64Encoded: key),
              keyMaterial.base64EncodedString() == key,
              let plaintextSize = fields["ps"].flatMap(Int.init)
        else { return nil }
        let expectedFieldCount = fields["cap"] == nil ? 8 : 9
        guard fields.count == expectedFieldCount else { return nil }
        guard let descriptor = try? KitMediaMessageDescriptor(
            attachmentID: attachmentID,
            storageKey: storageKey,
            mediaType: mediaType,
            ciphertextByteSize: size,
            ciphertextSHA256: digest,
            keyMaterial: keyMaterial,
            plaintextByteSize: plaintextSize,
            caption: fields["cap"]
        ), descriptor.encoded == text else { return nil }
        return descriptor
    }

    static func attachments(for text: String) -> [EncryptedAttachmentRequest] {
        guard let request = parse(text)?.attachmentRequest else { return [] }
        return [request]
    }

    static func validates(
        _ descriptors: [EncryptedAttachmentDTO?]?,
        against expected: [EncryptedAttachmentRequest]
    ) -> Bool {
        let received = descriptors?.compactMap { $0 } ?? []
        guard received.count == expected.count else { return false }
        return zip(received, expected).allSatisfy { dto, request in
            dto.id == request.id
                && dto.storageKey == request.storageKey
                && dto.mediaType == request.mediaType
                && dto.byteSize == request.byteSize
                && dto.ciphertextSha256?.lowercased() == request.ciphertextSha256.lowercased()
                && dto.encryptionMetadataCiphertext == nil
        }
    }

    private static func percentEncode(_ value: String) -> String {
        // Match Android's URLEncoder(UTF-8).replace("+", "%20") exactly. Foundation's
        // URL-unreserved set differs for `*`, `~`, and non-ASCII letters, which would make each
        // client reject the other's otherwise valid authenticated descriptor as non-canonical.
        let hex = Array("0123456789ABCDEF".utf8)
        var encoded = String()
        encoded.reserveCapacity(value.utf8.count * 3)
        for byte in value.utf8 {
            switch byte {
            case 0x41 ... 0x5A, 0x61 ... 0x7A, 0x30 ... 0x39,
                 0x2D, 0x2E, 0x2A, 0x5F:
                encoded.unicodeScalars.append(UnicodeScalar(byte))
            case 0x20:
                encoded += "%20"
            default:
                encoded.unicodeScalars.append("%")
                encoded.unicodeScalars.append(UnicodeScalar(hex[Int(byte >> 4)]))
                encoded.unicodeScalars.append(UnicodeScalar(hex[Int(byte & 0x0F)]))
            }
        }
        return encoded
    }
}

private extension Data {
    func prefixData(_ count: Int) -> Data { Data(prefix(count)) }
    func suffixData(_ count: Int) -> Data { Data(suffix(count)) }

    init(hexString: String) {
        self.init()
        reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else {
                removeAll()
                return
            }
            append(byte)
            index = next
        }
    }
}

private extension Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

enum SecureMessagingEnvelopeType: String, Codable, CaseIterable, Sendable {
    case prekey = "signal-prekey-v2"
    case message = "signal-message-v2"
}

enum SecureMessagingMessageKind: String, Codable, Sendable {
    case encrypted
    case encryptedAttachment = "encrypted_attachment"
}

enum SecureMessagingContractError: LocalizedError, Equatable {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let field): "Invalid secure-messaging \(field)."
        }
    }
}

enum SecureMessagingWirePolicy {
    static func isCanonicalUUID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value
    }

    static func isRosterRevision(_ value: String) -> Bool {
        matches(value, pattern: #"^v1:sha256:[a-f0-9]{64}$"#)
    }

    static func isSHA256(_ value: String) -> Bool {
        matches(value, pattern: #"^[a-fA-F0-9]{64}$"#)
    }

    static func isLowercaseSHA256(_ value: String) -> Bool {
        matches(value, pattern: #"^[a-f0-9]{64}$"#)
    }

    static func canonicalBase64(
        _ value: String,
        decodedByteRange: ClosedRange<Int> = 1 ... SecureMessagingWire.maximumCiphertextBytes
    ) -> Bool {
        guard let data = Data(base64Encoded: value),
              decodedByteRange.contains(data.count)
        else { return false }
        return data.base64EncodedString() == value
    }

    static func canonicalBase64(_ value: String, decodedByteCounts: Set<Int>) -> Bool {
        guard let data = Data(base64Encoded: value),
              decodedByteCounts.contains(data.count)
        else { return false }
        return data.base64EncodedString() == value
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}

struct MessagingSignedPrekeyRequest: Encodable, Equatable, Sendable {
    let prekeyId: Int
    let publicKey: String
    let signature: String

    enum CodingKeys: String, CodingKey {
        case prekeyId = "prekey_id"
        case publicKey = "public_key"
        case signature
    }
}

struct MessagingOneTimePrekeyRequest: Encodable, Equatable, Sendable {
    let prekeyId: Int
    let publicKey: String

    enum CodingKeys: String, CodingKey {
        case prekeyId = "prekey_id"
        case publicKey = "public_key"
    }
}

struct MessagingPQPrekeyRequest: Encodable, Equatable, Sendable {
    let prekeyId: Int
    let publicKey: String
    let signature: String

    enum CodingKeys: String, CodingKey {
        case prekeyId = "prekey_id"
        case publicKey = "public_key"
        case signature
    }
}

struct PublishMessagingKeyBundleRequest: Encodable, Equatable, Sendable {
    let protocolVersion: String
    let registrationId: Int
    let identityKey: String
    let identityKeyChange: Bool
    let signedPrekey: MessagingSignedPrekeyRequest
    let oneTimePrekeys: [MessagingOneTimePrekeyRequest]
    let pqPrekeys: [MessagingPQPrekeyRequest]
    let pqLastResortPrekey: MessagingPQPrekeyRequest

    init(
        registrationId: Int,
        identityKey: String,
        identityKeyChange: Bool = false,
        signedPrekey: MessagingSignedPrekeyRequest,
        oneTimePrekeys: [MessagingOneTimePrekeyRequest],
        pqPrekeys: [MessagingPQPrekeyRequest],
        pqLastResortPrekey: MessagingPQPrekeyRequest
    ) throws {
        guard (1 ... 16_380).contains(registrationId) else {
            throw SecureMessagingContractError.invalid("registration ID")
        }
        guard SecureMessagingWirePolicy.canonicalBase64(
            identityKey,
            decodedByteCounts: [5, 33]
        ) else { throw SecureMessagingContractError.invalid("identity key") }
        try Self.validateSignedPrekey(signedPrekey)
        guard oneTimePrekeys.count <= SecureMessagingWire.maximumKeyBatch,
              Set(oneTimePrekeys.map(\.prekeyId)).count == oneTimePrekeys.count
        else { throw SecureMessagingContractError.invalid("one-time prekeys") }
        for prekey in oneTimePrekeys { try Self.validateOneTimePrekey(prekey) }
        guard pqPrekeys.count <= SecureMessagingWire.maximumKeyBatch,
              Set(pqPrekeys.map(\.prekeyId)).count == pqPrekeys.count,
              !pqPrekeys.contains(where: { $0.prekeyId == pqLastResortPrekey.prekeyId })
        else { throw SecureMessagingContractError.invalid("PQ prekeys") }
        for prekey in pqPrekeys { try Self.validatePQPrekey(prekey) }
        try Self.validatePQPrekey(pqLastResortPrekey)

        protocolVersion = SecureMessagingWire.protocolVersion
        self.registrationId = registrationId
        self.identityKey = identityKey
        self.identityKeyChange = identityKeyChange
        self.signedPrekey = signedPrekey
        self.oneTimePrekeys = oneTimePrekeys
        self.pqPrekeys = pqPrekeys
        self.pqLastResortPrekey = pqLastResortPrekey
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case registrationId = "registration_id"
        case identityKey = "identity_key"
        case identityKeyChange = "identity_key_change"
        case signedPrekey = "signed_prekey"
        case oneTimePrekeys = "one_time_prekeys"
        case pqPrekeys = "pq_prekeys"
        case pqLastResortPrekey = "pq_last_resort_prekey"
    }

    private static func validateKeyId(_ value: Int) throws {
        guard (0 ... 16_777_215).contains(value) else {
            throw SecureMessagingContractError.invalid("prekey ID")
        }
    }

    private static func validateSignedPrekey(_ prekey: MessagingSignedPrekeyRequest) throws {
        try validateKeyId(prekey.prekeyId)
        guard SecureMessagingWirePolicy.canonicalBase64(
            prekey.publicKey,
            decodedByteCounts: [5, 33]
        ), SecureMessagingWirePolicy.canonicalBase64(
            prekey.signature,
            decodedByteCounts: [64]
        ) else { throw SecureMessagingContractError.invalid("signed prekey") }
    }

    private static func validateOneTimePrekey(_ prekey: MessagingOneTimePrekeyRequest) throws {
        try validateKeyId(prekey.prekeyId)
        guard SecureMessagingWirePolicy.canonicalBase64(
            prekey.publicKey,
            decodedByteCounts: [5, 33]
        ) else { throw SecureMessagingContractError.invalid("one-time prekey") }
    }

    private static func validatePQPrekey(_ prekey: MessagingPQPrekeyRequest) throws {
        try validateKeyId(prekey.prekeyId)
        guard SecureMessagingWirePolicy.canonicalBase64(
            prekey.publicKey,
            decodedByteCounts: [8, 1_569]
        ), SecureMessagingWirePolicy.canonicalBase64(
            prekey.signature,
            decodedByteCounts: [64]
        ) else { throw SecureMessagingContractError.invalid("PQ prekey") }
    }
}

struct MessagingKeyTransparencyDTO: Decodable, Equatable, Sendable {
    let revision: String?
    let eventType: String?
    let protocolVersion: String?
    let eventHash: String?
    let previousEventHash: String?
    let identityKeySha256: String?
    let previousIdentityKeySha256: String?
    let pqLastResortPrekeyId: Int?
    let pqLastResortPrekeySha256: String?
    let occurredAt: String?

    enum CodingKeys: String, CodingKey {
        case revision
        case eventType = "event_type"
        case protocolVersion = "protocol_version"
        case eventHash = "event_hash"
        case previousEventHash = "previous_event_hash"
        case identityKeySha256 = "identity_key_sha256"
        case previousIdentityKeySha256 = "previous_identity_key_sha256"
        case pqLastResortPrekeyId = "pq_last_resort_prekey_id"
        case pqLastResortPrekeySha256 = "pq_last_resort_prekey_sha256"
        case occurredAt = "occurred_at"
    }
}

struct MessagingKeyStatusDTO: Decodable, Equatable, Sendable {
    let enrolled: Bool?
    let enrollmentEpoch: Int64?
    let deviceId: String?
    let signalDeviceId: Int?
    let protocolVersion: String?
    let registrationId: Int?
    let identityKeySha256: String?
    let signedPrekeyId: Int?
    let signedPrekeySha256: String?
    let pqLastResortPrekeyId: Int?
    let pqLastResortPrekeySha256: String?
    let bundleVersion: Int?
    let availableOneTimePrekeys: Int?
    let availableEcOneTimePrekeys: Int?
    let availablePqOneTimePrekeys: Int?
    let replenishAt: Int?
    let needsReplenishment: Bool?
    let publishedAt: String?
    let rotatedAt: String?
    let transparency: MessagingKeyTransparencyDTO?

    enum CodingKeys: String, CodingKey {
        case enrolled, transparency
        case enrollmentEpoch = "enrollment_epoch"
        case deviceId = "device_id"
        case signalDeviceId = "signal_device_id"
        case protocolVersion = "protocol_version"
        case registrationId = "registration_id"
        case identityKeySha256 = "identity_key_sha256"
        case signedPrekeyId = "signed_prekey_id"
        case signedPrekeySha256 = "signed_prekey_sha256"
        case pqLastResortPrekeyId = "pq_last_resort_prekey_id"
        case pqLastResortPrekeySha256 = "pq_last_resort_prekey_sha256"
        case bundleVersion = "bundle_version"
        case availableOneTimePrekeys = "available_one_time_prekeys"
        case availableEcOneTimePrekeys = "available_ec_one_time_prekeys"
        case availablePqOneTimePrekeys = "available_pq_one_time_prekeys"
        case replenishAt = "replenish_at"
        case needsReplenishment = "needs_replenishment"
        case publishedAt = "published_at"
        case rotatedAt = "rotated_at"
    }
}

struct ResetMessagingEnrollmentRequest: Encodable, Equatable, Sendable {
    let expectedEnrollmentEpoch: Int64
    let expectedRegistrationId: Int
    let expectedIdentityKeySha256: String
    let expectedBundleVersion: Int

    init(
        expectedEnrollmentEpoch: Int64,
        expectedRegistrationId: Int,
        expectedIdentityKeySha256: String,
        expectedBundleVersion: Int
    ) throws {
        guard expectedEnrollmentEpoch > 0,
              (1 ... 16_380).contains(expectedRegistrationId),
              SecureMessagingWirePolicy.isLowercaseSHA256(expectedIdentityKeySha256),
              expectedBundleVersion > 0
        else { throw SecureMessagingContractError.invalid("enrollment reset proof") }
        self.expectedEnrollmentEpoch = expectedEnrollmentEpoch
        self.expectedRegistrationId = expectedRegistrationId
        self.expectedIdentityKeySha256 = expectedIdentityKeySha256
        self.expectedBundleVersion = expectedBundleVersion
    }

    enum CodingKeys: String, CodingKey {
        case expectedEnrollmentEpoch = "expected_enrollment_epoch"
        case expectedRegistrationId = "expected_registration_id"
        case expectedIdentityKeySha256 = "expected_identity_key_sha256"
        case expectedBundleVersion = "expected_bundle_version"
    }
}

struct ResetMessagingEnrollmentDTO: Decodable, Equatable, Sendable {
    let deviceId: String?
    let previousEnrollmentEpoch: Int64?
    let enrollmentEpoch: Int64?
    let enrolled: Bool?
    let resetApplied: Bool?

    enum CodingKeys: String, CodingKey {
        case enrolled
        case deviceId = "device_id"
        case previousEnrollmentEpoch = "previous_enrollment_epoch"
        case enrollmentEpoch = "enrollment_epoch"
        case resetApplied = "reset_applied"
    }
}

struct MessagingConversationMemberDTO: Decodable, Equatable, Sendable {
    let userId: String?
    let name: String?
    let role: String?
    let joinedAt: String?

    enum CodingKeys: String, CodingKey {
        case name, role
        case userId = "user_id"
        case joinedAt = "joined_at"
    }
}

struct MessagingConversationDTO: Decodable, Equatable, Sendable {
    let id: String?
    let type: String?
    let title: String?
    let parentId: String?
    let createdBy: String?
    let role: String?
    let members: [MessagingConversationMemberDTO?]?
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, type, title, role, members
        case parentId = "parent_id"
        case createdBy = "created_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct MessagingConversationListDTO: Decodable, Equatable, Sendable {
    let items: [MessagingConversationDTO?]?
}

struct CreateDirectMessagingConversationRequest: Encodable, Equatable, Sendable {
    let memberIds: [String]
    let type: String

    init(memberId: String) throws {
        guard SecureMessagingWirePolicy.isCanonicalUUID(memberId) else {
            throw SecureMessagingContractError.invalid("direct-conversation member ID")
        }
        memberIds = [memberId]
        type = SecureMessagingWire.directConversationType
    }

    enum CodingKeys: String, CodingKey {
        case memberIds = "member_ids"
        case type
    }
}

struct MessagingSignedPrekeyDTO: Decodable, Equatable, Sendable {
    let prekeyId: Int?
    let publicKey: String?
    let publicKeySha256: String?
    let signature: String?

    enum CodingKeys: String, CodingKey {
        case signature
        case prekeyId = "prekey_id"
        case publicKey = "public_key"
        case publicKeySha256 = "public_key_sha256"
    }
}

struct MessagingDeviceClientDTO: Decodable, Equatable, Sendable {
    let platform: String?
    let version: String?
    let build: Int?
    let capabilities: [String: Bool?]?
}

struct MessagingDeviceRosterEntryDTO: Decodable, Equatable, Sendable {
    let deviceId: String?
    let enrollmentEpoch: Int64?
    let signalDeviceId: Int?
    let userId: String?
    let registrationId: Int?
    let protocolVersion: String?
    let bundleVersion: Int?
    let identityKey: String?
    let identityKeySha256: String?
    let signedPrekey: MessagingSignedPrekeyDTO?
    let publishedAt: String?
    let rotatedAt: String?
    let identityKeyChangedAt: String?
    let bundleVersionChangedAt: String?
    /// Server-attested client metadata is advisory for text/image messages and fail-closed for
    /// richer media that older iOS or Android clients cannot safely render yet.
    let client: MessagingDeviceClientDTO?

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case enrollmentEpoch = "enrollment_epoch"
        case signalDeviceId = "signal_device_id"
        case userId = "user_id"
        case registrationId = "registration_id"
        case protocolVersion = "protocol_version"
        case bundleVersion = "bundle_version"
        case identityKey = "identity_key"
        case identityKeySha256 = "identity_key_sha256"
        case signedPrekey = "signed_prekey"
        case publishedAt = "published_at"
        case rotatedAt = "rotated_at"
        case identityKeyChangedAt = "identity_key_changed_at"
        case bundleVersionChangedAt = "bundle_version_changed_at"
        case client
    }
}

struct MessagingDeviceRosterDTO: Decodable, Equatable, Sendable {
    let conversationId: String?
    let rosterRevision: String?
    let rosterHash: String?
    let hashAlgorithm: String?
    let devices: [MessagingDeviceRosterEntryDTO?]?

    enum CodingKeys: String, CodingKey {
        case devices
        case conversationId = "conversation_id"
        case rosterRevision = "roster_revision"
        case rosterHash = "roster_hash"
        case hashAlgorithm = "hash_algorithm"
    }
}

enum MessagingRichMediaCapabilityPolicy {
    static let profile = "kit-media-v1"
    static let deviceCapabilityKey = "messaging_rich_media_v1"
    static let minimumIOSVersion = [0, 2, 5]
    static let minimumIOSBuild = 16
    static let minimumIOSRelease = "0.2.5-r16"

    static func supports(
        mediaType: String,
        roster: MessagingDeviceRosterDTO,
        conversationID: String,
        currentDeviceID: String,
        recipientUserID: String
    ) -> Bool {
        guard KitChatMediaKind(mediaType: mediaType) != .image else { return true }
        guard roster.conversationId == conversationID,
              SecureMessagingWirePolicy.isCanonicalUUID(conversationID),
              SecureMessagingWirePolicy.isCanonicalUUID(currentDeviceID),
              SecureMessagingWirePolicy.isCanonicalUUID(recipientUserID),
              let devices = roster.devices?.compactMap({ $0 })
        else { return false }
        let recipientDevices = devices.filter { $0.userId == recipientUserID }
        guard !recipientDevices.isEmpty else { return false }
        return recipientDevices.allSatisfy { device in
            guard device.deviceId != currentDeviceID,
                  let client = device.client,
                  client.platform?.lowercased() == "ios",
                  let version = client.version,
                  versionAtLeastMinimum(version, build: client.build),
                  client.capabilities?[deviceCapabilityKey] == true
            else { return false }
            return true
        }
    }

    private static func versionAtLeastMinimum(_ value: String, build: Int?) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              let major = Int(components[0]),
              let minor = Int(components[1]),
              let patch = Int(components[2]),
              [major, minor, patch].allSatisfy({ $0 >= 0 })
        else { return false }
        let version = [major, minor, patch]
        if minimumIOSVersion.lexicographicallyPrecedes(version) { return true }
        guard version == minimumIOSVersion, let build else { return false }
        return build >= minimumIOSBuild
    }
}

struct ConsumeMessagingKeyBundlesRequest: Encodable, Equatable, Sendable {
    let deviceIds: [String]?

    init(deviceIds: [String]? = nil) throws {
        if let deviceIds {
            guard (1 ... SecureMessagingWire.maximumRecipientDevices).contains(deviceIds.count),
                  Set(deviceIds).count == deviceIds.count,
                  deviceIds.allSatisfy(SecureMessagingWirePolicy.isCanonicalUUID)
            else { throw SecureMessagingContractError.invalid("key-bundle device IDs") }
        }
        self.deviceIds = deviceIds
    }

    enum CodingKeys: String, CodingKey {
        case deviceIds = "device_ids"
    }
}

struct MessagingOneTimePrekeyDTO: Decodable, Equatable, Sendable {
    let prekeyId: Int?
    let publicKey: String?

    enum CodingKeys: String, CodingKey {
        case prekeyId = "prekey_id"
        case publicKey = "public_key"
    }
}

struct MessagingPQPrekeyDTO: Decodable, Equatable, Sendable {
    let prekeyId: Int?
    let publicKey: String?
    let signature: String?

    enum CodingKeys: String, CodingKey {
        case signature
        case prekeyId = "prekey_id"
        case publicKey = "public_key"
    }
}

struct ConsumedMessagingKeyBundleDTO: Decodable, Equatable, Sendable {
    let deviceId: String?
    let signalDeviceId: Int?
    let userId: String?
    let protocolVersion: String?
    let registrationId: Int?
    let identityKey: String?
    let identityKeySha256: String?
    let signedPrekey: MessagingSignedPrekeyDTO?
    let oneTimePrekey: MessagingOneTimePrekeyDTO?
    let pqPrekey: MessagingPQPrekeyDTO?
    let bundleVersion: Int?
    let availableOneTimePrekeys: Int?
    let availableEcOneTimePrekeys: Int?
    let availablePqOneTimePrekeys: Int?
    let needsReplenishment: Bool?
    let isCurrentDevice: Bool?
    let publishedAt: String?
    let rotatedAt: String?
    let transparency: MessagingKeyTransparencyDTO?

    enum CodingKeys: String, CodingKey {
        case transparency
        case deviceId = "device_id"
        case signalDeviceId = "signal_device_id"
        case userId = "user_id"
        case protocolVersion = "protocol_version"
        case registrationId = "registration_id"
        case identityKey = "identity_key"
        case identityKeySha256 = "identity_key_sha256"
        case signedPrekey = "signed_prekey"
        case oneTimePrekey = "one_time_prekey"
        case pqPrekey = "pq_prekey"
        case bundleVersion = "bundle_version"
        case availableOneTimePrekeys = "available_one_time_prekeys"
        case availableEcOneTimePrekeys = "available_ec_one_time_prekeys"
        case availablePqOneTimePrekeys = "available_pq_one_time_prekeys"
        case needsReplenishment = "needs_replenishment"
        case isCurrentDevice = "is_current_device"
        case publishedAt = "published_at"
        case rotatedAt = "rotated_at"
    }
}

struct ConsumedMessagingKeyBundlesDTO: Decodable, Equatable, Sendable {
    let bundles: [ConsumedMessagingKeyBundleDTO?]?
}

struct EncryptedDeviceEnvelopeRequest: Encodable, Equatable, Sendable {
    let recipientDeviceId: String
    let envelopeType: SecureMessagingEnvelopeType
    let ciphertext: String

    init(
        recipientDeviceId: String,
        envelopeType: SecureMessagingEnvelopeType,
        ciphertext: String
    ) throws {
        guard SecureMessagingWirePolicy.isCanonicalUUID(recipientDeviceId),
              SecureMessagingWirePolicy.canonicalBase64(ciphertext)
        else { throw SecureMessagingContractError.invalid("device envelope") }
        self.recipientDeviceId = recipientDeviceId
        self.envelopeType = envelopeType
        self.ciphertext = ciphertext
    }

    enum CodingKeys: String, CodingKey {
        case recipientDeviceId = "recipient_device_id"
        case envelopeType = "envelope_type"
        case ciphertext
    }
}

struct EncryptedAttachmentRequest: Encodable, Equatable, Sendable {
    let id: String
    let storageKey: String
    let mediaType: String
    let byteSize: Int64
    let ciphertextSha256: String

    init(
        id: String,
        storageKey: String,
        mediaType: String,
        byteSize: Int64,
        ciphertextSha256: String
    ) throws {
        guard SecureMessagingWirePolicy.isCanonicalUUID(id),
              SecureMessagingWirePolicy.isCanonicalUUID(storageKey),
              SecureMessagingWire.allowedAttachmentMediaTypes.contains(mediaType),
              byteSize >= SecureMessagingWire.minimumAttachmentCiphertextBytes,
              byteSize <= SecureMessagingWire.maximumAttachmentCiphertextBytes,
              SecureMessagingWirePolicy.isSHA256(ciphertextSha256)
        else { throw SecureMessagingContractError.invalid("attachment metadata") }
        self.id = id
        self.storageKey = storageKey
        self.mediaType = mediaType
        self.byteSize = byteSize
        self.ciphertextSha256 = ciphertextSha256
    }

    enum CodingKeys: String, CodingKey {
        case id
        case storageKey = "storage_key"
        case mediaType = "media_type"
        case byteSize = "byte_size"
        case ciphertextSha256 = "ciphertext_sha256"
    }
}

struct SendEncryptedMessageRequest: Encodable, Equatable, Sendable {
    let clientMessageId: String
    let rosterRevision: String
    let kind: SecureMessagingMessageKind
    let replyToMessageId: String?
    let envelopes: [EncryptedDeviceEnvelopeRequest]
    let attachments: [EncryptedAttachmentRequest]

    init(
        clientMessageId: String,
        rosterRevision: String,
        kind: SecureMessagingMessageKind,
        replyToMessageId: String? = nil,
        envelopes: [EncryptedDeviceEnvelopeRequest],
        attachments: [EncryptedAttachmentRequest] = []
    ) throws {
        guard SecureMessagingWirePolicy.isCanonicalUUID(clientMessageId),
              SecureMessagingWirePolicy.isRosterRevision(rosterRevision),
              replyToMessageId.map(SecureMessagingWirePolicy.isCanonicalUUID) ?? true,
              (1 ... SecureMessagingWire.maximumRecipientDevices).contains(envelopes.count),
              Set(envelopes.map(\.recipientDeviceId)).count == envelopes.count,
              attachments.count <= SecureMessagingWire.maximumAttachments,
              Set(attachments.map(\.id)).count == attachments.count,
              Set(attachments.map(\.storageKey)).count == attachments.count,
              (kind == .encryptedAttachment) == !attachments.isEmpty
        else { throw SecureMessagingContractError.invalid("encrypted-message request") }
        self.clientMessageId = clientMessageId
        self.rosterRevision = rosterRevision
        self.kind = kind
        self.replyToMessageId = replyToMessageId
        self.envelopes = envelopes
        self.attachments = attachments
    }

    enum CodingKeys: String, CodingKey {
        case clientMessageId = "client_message_id"
        case rosterRevision = "roster_revision"
        case kind
        case replyToMessageId = "reply_to_message_id"
        case envelopes, attachments
    }
}

struct EncryptedMessageSenderDTO: Decodable, Equatable, Sendable {
    let id: String?
    let name: String?
}

struct EncryptedMessageCryptoSenderDTO: Decodable, Equatable, Sendable {
    let userId: String?
    let deviceId: String?
    let enrollmentEpoch: Int64?
    let signalDeviceId: Int?
    let registrationId: Int?
    let protocolVersion: String?
    let bundleVersion: Int?
    let identityKeySha256: String?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case deviceId = "device_id"
        case enrollmentEpoch = "enrollment_epoch"
        case signalDeviceId = "signal_device_id"
        case registrationId = "registration_id"
        case protocolVersion = "protocol_version"
        case bundleVersion = "bundle_version"
        case identityKeySha256 = "identity_key_sha256"
    }
}

struct EncryptedMessageEnvelopeDTO: Decodable, Equatable, Sendable {
    let recipientDeviceId: String?
    let recipientEnrollmentEpoch: Int64?
    let envelopeType: String?
    let ciphertext: String?
    let ciphertextSha256: String?
    let isHistoryBackfill: Bool?
    let transferClientMessageId: String?
    let transferRosterRevision: String?
    let cryptoSender: EncryptedMessageCryptoSenderDTO?

    enum CodingKeys: String, CodingKey {
        case ciphertext
        case recipientDeviceId = "recipient_device_id"
        case recipientEnrollmentEpoch = "recipient_enrollment_epoch"
        case envelopeType = "envelope_type"
        case ciphertextSha256 = "ciphertext_sha256"
        case isHistoryBackfill = "is_history_backfill"
        case transferClientMessageId = "transfer_client_message_id"
        case transferRosterRevision = "transfer_roster_revision"
        case cryptoSender = "crypto_sender"
    }
}

struct EncryptedAttachmentDTO: Decodable, Equatable, Sendable {
    let id: String?
    let storageKey: String?
    let mediaType: String?
    let byteSize: Int64?
    let ciphertextSha256: String?
    let encryptionMetadataCiphertext: String?

    enum CodingKeys: String, CodingKey {
        case id
        case storageKey = "storage_key"
        case mediaType = "media_type"
        case byteSize = "byte_size"
        case ciphertextSha256 = "ciphertext_sha256"
        case encryptionMetadataCiphertext = "encryption_metadata_ciphertext"
    }
}

struct EncryptedMessageReactionDTO: Decodable, Equatable, Sendable {
    let userId: String?
    let reaction: String?
    let reactedAt: String?

    enum CodingKeys: String, CodingKey {
        case reaction
        case userId = "user_id"
        case reactedAt = "reacted_at"
    }
}

struct EncryptedMessageDTO: Decodable, Equatable, Sendable {
    let id: String?
    let conversationId: String?
    let clientMessageId: String?
    let sender: EncryptedMessageSenderDTO?
    let senderDeviceId: String?
    let senderEnrollmentEpoch: Int64?
    let senderSignalDeviceId: Int?
    let senderRegistrationId: Int?
    let senderProtocolVersion: String?
    let senderBundleVersion: Int?
    let senderIdentityKeySha256: String?
    let rosterRevision: String?
    let kind: String?
    let replyToMessageId: String?
    let envelope: EncryptedMessageEnvelopeDTO?
    let attachments: [EncryptedAttachmentDTO?]?
    let reactions: [EncryptedMessageReactionDTO?]?
    let sentAt: String?
    let revokedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, sender, kind, envelope, attachments, reactions
        case conversationId = "conversation_id"
        case clientMessageId = "client_message_id"
        case senderDeviceId = "sender_device_id"
        case senderEnrollmentEpoch = "sender_enrollment_epoch"
        case senderSignalDeviceId = "sender_signal_device_id"
        case senderRegistrationId = "sender_registration_id"
        case senderProtocolVersion = "sender_protocol_version"
        case senderBundleVersion = "sender_bundle_version"
        case senderIdentityKeySha256 = "sender_identity_key_sha256"
        case rosterRevision = "roster_revision"
        case replyToMessageId = "reply_to_message_id"
        case sentAt = "sent_at"
        case revokedAt = "revoked_at"
    }
}

struct MessagingSyncEventDataDTO: Decodable, Equatable, Sendable {
    let id: String?
    let conversationId: String?
    let clientMessageId: String?
    let sender: EncryptedMessageSenderDTO?
    let senderDeviceId: String?
    let senderEnrollmentEpoch: Int64?
    let senderSignalDeviceId: Int?
    let senderRegistrationId: Int?
    let senderProtocolVersion: String?
    let senderBundleVersion: Int?
    let senderIdentityKeySha256: String?
    let rosterRevision: String?
    let kind: String?
    let replyToMessageId: String?
    let envelope: EncryptedMessageEnvelopeDTO?
    let attachments: [EncryptedAttachmentDTO?]?
    let reactions: [EncryptedMessageReactionDTO?]?
    let sentAt: String?
    let revokedAt: String?
    let deviceId: String?
    let userId: String?
    let enrollmentEpoch: Int64?
    let signalDeviceId: Int?
    let registrationId: Int?
    let previousRegistrationId: Int?
    let protocolVersion: String?
    let previousProtocolVersion: String?
    let bundleVersion: Int?
    let identityKeySha256: String?
    let previousIdentityKeySha256: String?
    let revokedDeviceCount: Int?
    let rosterRefreshRequired: Bool?
    let transitionedAt: String?
    let transitionHash: String?
    let lastReadMessageId: String?
    let readAt: String?
    let messageId: String?
    let deliveryState: String?
    let deliveredAt: String?

    enum CodingKeys: String, CodingKey {
        case id, sender, kind, envelope, attachments, reactions
        case conversationId = "conversation_id"
        case clientMessageId = "client_message_id"
        case senderDeviceId = "sender_device_id"
        case senderEnrollmentEpoch = "sender_enrollment_epoch"
        case senderSignalDeviceId = "sender_signal_device_id"
        case senderRegistrationId = "sender_registration_id"
        case senderProtocolVersion = "sender_protocol_version"
        case senderBundleVersion = "sender_bundle_version"
        case senderIdentityKeySha256 = "sender_identity_key_sha256"
        case rosterRevision = "roster_revision"
        case replyToMessageId = "reply_to_message_id"
        case sentAt = "sent_at"
        case revokedAt = "revoked_at"
        case deviceId = "device_id"
        case userId = "user_id"
        case enrollmentEpoch = "enrollment_epoch"
        case signalDeviceId = "signal_device_id"
        case registrationId = "registration_id"
        case previousRegistrationId = "previous_registration_id"
        case protocolVersion = "protocol_version"
        case previousProtocolVersion = "previous_protocol_version"
        case bundleVersion = "bundle_version"
        case identityKeySha256 = "identity_key_sha256"
        case previousIdentityKeySha256 = "previous_identity_key_sha256"
        case revokedDeviceCount = "revoked_device_count"
        case rosterRefreshRequired = "roster_refresh_required"
        case transitionedAt = "transitioned_at"
        case transitionHash = "transition_hash"
        case lastReadMessageId = "last_read_message_id"
        case readAt = "read_at"
        case messageId = "message_id"
        case deliveryState = "delivery_state"
        case deliveredAt = "delivered_at"
    }
}

struct MessagingSyncEventDTO: Decodable, Equatable, Sendable {
    let id: String?
    let type: String?
    let conversationId: String?
    let resourceType: String?
    let resourceId: String?
    let data: MessagingSyncEventDataDTO?
    let occurredAt: String?

    enum CodingKeys: String, CodingKey {
        case id, type, data
        case conversationId = "conversation_id"
        case resourceType = "resource_type"
        case resourceId = "resource_id"
        case occurredAt = "occurred_at"
    }
}

struct MessagingSyncDTO: Decodable, Equatable, Sendable {
    let events: [MessagingSyncEventDTO?]?
    let page: CursorPage?
}

struct MessagingHistoryTargetCryptoBundleDTO: Decodable, Equatable, Sendable {
    let deviceId: String?
    let userId: String?
    let enrollmentEpoch: Int64?
    let signalDeviceId: Int?
    let registrationId: Int?
    let protocolVersion: String?
    let bundleVersion: Int?
    let identityKeySha256: String?

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case userId = "user_id"
        case enrollmentEpoch = "enrollment_epoch"
        case signalDeviceId = "signal_device_id"
        case registrationId = "registration_id"
        case protocolVersion = "protocol_version"
        case bundleVersion = "bundle_version"
        case identityKeySha256 = "identity_key_sha256"
    }
}

struct MessagingHistoryBackfillCandidatesDTO: Decodable, Equatable, Sendable {
    let conversationId: String?
    let rosterRevision: String?
    let targetCryptoBundle: MessagingHistoryTargetCryptoBundleDTO?
    let messages: [EncryptedMessageDTO?]?
    let page: CursorPage?

    enum CodingKeys: String, CodingKey {
        case messages, page
        case conversationId = "conversation_id"
        case rosterRevision = "roster_revision"
        case targetCryptoBundle = "target_crypto_bundle"
    }
}

struct StoreMessagingHistoryEnvelopeRequest: Encodable, Equatable, Sendable {
    let targetDeviceId: String
    let targetEnrollmentEpoch: Int64
    let transferClientMessageId: String
    let rosterRevision: String
    let envelopeType: SecureMessagingEnvelopeType
    let ciphertext: String

    init(
        targetDeviceId: String,
        targetEnrollmentEpoch: Int64,
        transferClientMessageId: String,
        rosterRevision: String,
        envelopeType: SecureMessagingEnvelopeType,
        ciphertext: String
    ) throws {
        guard SecureMessagingWirePolicy.isCanonicalUUID(targetDeviceId),
              targetEnrollmentEpoch > 0,
              SecureMessagingWirePolicy.isCanonicalUUID(transferClientMessageId),
              SecureMessagingWirePolicy.isRosterRevision(rosterRevision),
              SecureMessagingWirePolicy.canonicalBase64(ciphertext)
        else { throw SecureMessagingContractError.invalid("history envelope") }
        self.targetDeviceId = targetDeviceId
        self.targetEnrollmentEpoch = targetEnrollmentEpoch
        self.transferClientMessageId = transferClientMessageId
        self.rosterRevision = rosterRevision
        self.envelopeType = envelopeType
        self.ciphertext = ciphertext
    }

    enum CodingKeys: String, CodingKey {
        case targetDeviceId = "target_device_id"
        case targetEnrollmentEpoch = "target_enrollment_epoch"
        case transferClientMessageId = "transfer_client_message_id"
        case rosterRevision = "roster_revision"
        case envelopeType = "envelope_type"
        case ciphertext
    }
}

struct MessagingHistoryEnvelopeResultDTO: Decodable, Equatable, Sendable {
    let messageId: String?
    let targetDeviceId: String?
    let targetEnrollmentEpoch: Int64?
    let transferClientMessageId: String?
    let created: Bool?

    enum CodingKeys: String, CodingKey {
        case created
        case messageId = "message_id"
        case targetDeviceId = "target_device_id"
        case targetEnrollmentEpoch = "target_enrollment_epoch"
        case transferClientMessageId = "transfer_client_message_id"
    }
}

struct AcknowledgeMessageDeliveryRequest: Encodable, Equatable, Sendable {
    let messageIds: [String]

    init(messageIds: [String]) throws {
        guard (1 ... SecureMessagingWire.maximumDeliveryAcknowledgements).contains(messageIds.count),
              Set(messageIds).count == messageIds.count,
              messageIds.allSatisfy(SecureMessagingWirePolicy.isCanonicalUUID)
        else { throw SecureMessagingContractError.invalid("delivery acknowledgement IDs") }
        self.messageIds = messageIds
    }

    enum CodingKeys: String, CodingKey {
        case messageIds = "message_ids"
    }
}

struct MessageDeliveryReceiptDTO: Decodable, Equatable, Sendable {
    let messageId: String?
    let deliveredToDeviceAt: String?

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case deliveredToDeviceAt = "delivered_to_device_at"
    }
}

struct MessageDeliveryAcknowledgementDTO: Decodable, Equatable, Sendable {
    let deliveryState: String?
    let deviceId: String?
    let acknowledgedCount: Int?
    let newlyAcknowledgedCount: Int?
    let items: [MessageDeliveryReceiptDTO?]?

    enum CodingKeys: String, CodingKey {
        case items
        case deliveryState = "delivery_state"
        case deviceId = "device_id"
        case acknowledgedCount = "acknowledged_count"
        case newlyAcknowledgedCount = "newly_acknowledged_count"
    }
}

struct MarkMessagingConversationReadRequest: Encodable, Equatable, Sendable {
    let messageId: String

    init(messageId: String) throws {
        guard SecureMessagingWirePolicy.isCanonicalUUID(messageId) else {
            throw SecureMessagingContractError.invalid("read-receipt message ID")
        }
        self.messageId = messageId
    }

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
    }
}

struct MessagingReadReceiptDTO: Decodable, Equatable, Sendable {
    let conversationId: String?
    let userId: String?
    let lastReadMessageId: String?
    let readAt: String?

    enum CodingKeys: String, CodingKey {
        case conversationId = "conversation_id"
        case userId = "user_id"
        case lastReadMessageId = "last_read_message_id"
        case readAt = "read_at"
    }
}

struct MessagingAttachmentUploadDTO: Decodable, Equatable, Sendable {
    let storageKey: String?
    let byteSize: Int64?
    let ciphertextSha256: String?

    enum CodingKeys: String, CodingKey {
        case storageKey = "storage_key"
        case byteSize = "byte_size"
        case ciphertextSha256 = "ciphertext_sha256"
    }
}
