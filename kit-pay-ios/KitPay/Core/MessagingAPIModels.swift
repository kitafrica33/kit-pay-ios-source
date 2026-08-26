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

    /// User-authored text must never enter a trusted event namespace (payment events, group
    /// system notices, reactions). This check is shared by every composer, forwarding and
    /// notification-reply boundary.
    static func allowsUserAuthoredText(_ text: String) -> Bool {
        !beginsWithReservedPrefix(text, prefix: KitPaymentMessage.prefix)
            && !beginsWithReservedPrefix(text, prefix: KitGroupPaymentMessage.prefix)
            && !beginsWithReservedPrefix(text, prefix: KitSystemMessage.prefix)
            && !beginsWithReservedPrefix(text, prefix: KitMessageReaction.prefix)
    }
}

/// Canonical local system-notice descriptor documenting group lifecycle changes inside a thread
/// (`KITSYS1:v=1&k=member_added&u=<subject>&a=<actor>`). Like `KITPAY1`, the parse is strict:
/// fixed field order, canonical UUIDs, and byte-exact re-encoding; anything else is plain text.
struct KitSystemMessage: Equatable, Sendable {
    static let prefix = "KITSYS1:"
    static let maximumDescriptorLength = 256

    enum Kind: String, Equatable, Sendable, CaseIterable {
        case memberAdded = "member_added"
        case memberRemoved = "member_removed"
        case memberLeft = "member_left"
    }

    let kind: Kind
    let subjectUserID: String
    let actorUserID: String?

    init?(kind: Kind, subjectUserID: String, actorUserID: String?) {
        guard SecureMessagingWirePolicy.isCanonicalUUID(subjectUserID),
              actorUserID.map(SecureMessagingWirePolicy.isCanonicalUUID) ?? true
        else { return nil }
        self.kind = kind
        self.subjectUserID = subjectUserID
        self.actorUserID = actorUserID
    }

    var encoded: String {
        var value = Self.prefix
        value += "v=1"
        value += "&k=\(kind.rawValue)"
        value += "&u=\(subjectUserID)"
        if let actorUserID { value += "&a=\(actorUserID)" }
        return value
    }

    static func isSystemText(_ text: String) -> Bool {
        text.hasPrefix(prefix)
    }

    /// Deterministic local message id for a lifecycle event whose resource id is not itself a
    /// UUID, so a replayed sync page converges on one system notice instead of duplicating it.
    static func deterministicMessageID(namespace: String) -> UUID {
        let digest = SHA256.hash(data: Data(namespace.utf8))
        let bytes = Array(digest.prefix(16))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    static func parse(_ text: String) -> KitSystemMessage? {
        guard text.hasPrefix(prefix), text.utf16.count <= maximumDescriptorLength else {
            return nil
        }
        var fields: [String: String] = [:]
        for pair in text.dropFirst(prefix.count).split(
            separator: "&",
            omittingEmptySubsequences: false
        ) {
            guard let separator = pair.firstIndex(of: "="), separator != pair.startIndex else {
                return nil
            }
            let key = String(pair[..<separator])
            let value = String(pair[pair.index(after: separator)...])
            guard fields[key] == nil else { return nil }
            fields[key] = value
        }
        guard fields["v"] == "1",
              let kind = fields["k"].flatMap(Kind.init(rawValue:)),
              let subjectUserID = fields["u"],
              let descriptor = KitSystemMessage(
                  kind: kind,
                  subjectUserID: subjectUserID,
                  actorUserID: fields["a"]
              ),
              descriptor.encoded == text
        else { return nil }
        return descriptor
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
    static let groupConversationType = "group"
    /// 32 people total, including self. Bounded well under the 99-device fanout cap so every member can
    /// still enroll a companion device without stranding queued group ciphertext.
    static let maximumGroupMembers = 32
    static let maximumKeyBatch = 100
    static let maximumRecipientDevices = 99
    static let maximumAttachments = 20
    static let maximumDeliveryAcknowledgements = 100
    static let maximumSyncPage = 100
    static let maximumHistoryPage = 50
    static let maximumCiphertextBytes = 1_500_000
    static let minimumAttachmentCiphertextBytes: Int64 = 64
    static let maximumAttachmentCiphertextBytes: Int64 = 200 * 1_024 * 1_024 + 64

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
            "Choose a JPEG, PNG, WebP, or GIF image up to 200 MB."
        case .invalidMedia:
            "Choose a supported file up to 200 MB."
        case .invalidDescriptor:
            "This encrypted attachment has invalid authenticated metadata."
        case .invalidCiphertext:
            "This encrypted attachment failed its integrity check."
        case .cryptographyFailed:
            "The attachment could not be encrypted securely."
        case .serverMetadataMismatch:
            "Kit returned attachment metadata that does not match the encrypted message."
        case .incompatibleRecipient:
            "Voice notes, videos, and documents require the recipient to update Kit Pay on every device."
        }
    }
}

/// Signal-compatible encrypted attachment framing shared with the Android client:
/// iv(16) || AES-256-CBC-PKCS7(plaintext) || HMAC-SHA256(iv || ciphertext)(32).
/// The server receives only the framed ciphertext and its digest. The 64-byte key material is
/// carried solely inside the per-device Signal envelope as part of `KitMediaMessageDescriptor`.
enum SecureMediaAttachmentCipher {
    /// The customer-facing media ceiling. Large plaintext never rides in the persisted state
    /// blob — it parks in the encrypted file cache — so the bound is the transport's, and the
    /// backend must advertise the identical value in its rich-media capability.
    static let maximumPlaintextBytes = 200 * 1_024 * 1_024
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
    case encryptedReaction = "encrypted_reaction"
}

/// Binds the authenticated plaintext namespace to the server-visible routing metadata. This is
/// deliberately shared by first-send, sync, history backfill, and backup validation so no path
/// can reinterpret an ordinary message as a reaction (or vice versa).
enum SecureMessagingContentBindingPolicy {
    static func kind(
        for plaintext: String,
        replyToMessageID: String?,
        attachments: [EncryptedAttachmentRequest]
    ) -> SecureMessagingMessageKind? {
        if SecureMessageReservedPrefixPolicy.beginsWithReservedPrefix(
            plaintext,
            prefix: KitMessageReaction.prefix
        ) {
            guard KitMessageReaction.isReactionText(plaintext),
                  let reaction = KitMessageReaction.parse(plaintext),
                  replyToMessageID == reaction.targetServerMessageID,
                  attachments.isEmpty
            else { return nil }
            return .encryptedReaction
        }

        let mediaAttachments = KitMediaMessageDescriptor.attachments(for: plaintext)
        if SecureMessageReservedPrefixPolicy.beginsWithReservedPrefix(
            plaintext,
            prefix: KitMediaMessageDescriptor.prefix
        ) {
            guard !mediaAttachments.isEmpty else { return nil }
        }
        if !mediaAttachments.isEmpty {
            guard attachments == mediaAttachments else { return nil }
            return .encryptedAttachment
        }
        guard attachments.isEmpty else { return nil }
        return .encrypted
    }

    static func validatesOuterEnvelope(
        kind: SecureMessagingMessageKind,
        replyToMessageID: String?,
        attachmentCount: Int
    ) -> Bool {
        switch kind {
        case .encrypted:
            return attachmentCount == 0
        case .encryptedAttachment:
            return attachmentCount > 0
        case .encryptedReaction:
            return attachmentCount == 0 && replyToMessageID != nil
        }
    }
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

enum MessagingGroupRole: String, Codable, CaseIterable, Sendable {
    case owner
    case admin
    case moderator
    case member

    var canManageGroup: Bool { self == .owner || self == .admin }

    func canRemove(_ target: MessagingGroupRole) -> Bool {
        switch self {
        case .owner:
            return true
        case .admin:
            return target == .moderator || target == .member
        case .moderator, .member:
            return false
        }
    }
}

enum MessagingGroupTitlePolicy {
    static let characterRange = 1 ... 64
    static let maximumUTF8Bytes = 120

    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isValid(_ value: String) -> Bool {
        let clean = normalized(value)
        return characterRange.contains(clean.unicodeScalars.count)
            && clean.utf8.count <= maximumUTF8Bytes
            && !clean.unicodeScalars.contains(where: { $0.value == 0 })
    }
}

struct RenameMessagingGroupRequest: Encodable, Equatable, Sendable {
    let title: String

    init(title: String) throws {
        let clean = MessagingGroupTitlePolicy.normalized(title)
        guard MessagingGroupTitlePolicy.isValid(clean) else {
            throw SecureMessagingContractError.invalid("group-conversation title")
        }
        self.title = clean
    }
}

struct AddMessagingGroupMemberRequest: Encodable, Equatable, Sendable {
    let userId: String
    let role: MessagingGroupRole?

    init(userId: String, role: MessagingGroupRole? = nil) throws {
        guard SecureMessagingWirePolicy.isCanonicalUUID(userId) else {
            throw SecureMessagingContractError.invalid("group member ID")
        }
        self.userId = userId
        self.role = role
    }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case role
    }
}

struct CreateDirectMessagingConversationRequest: Encodable, Equatable, Sendable {
    static let maximumGroupTitleUTF8Bytes = MessagingGroupTitlePolicy.maximumUTF8Bytes

    let memberIds: [String]
    let type: String
    /// Present only for group creation. Synthesized `encodeIfPresent` keeps the direct-creation
    /// wire body byte-identical to earlier builds (no `title` key at all).
    let title: String?

    init(memberId: String) throws {
        guard SecureMessagingWirePolicy.isCanonicalUUID(memberId) else {
            throw SecureMessagingContractError.invalid("direct-conversation member ID")
        }
        memberIds = [memberId]
        type = SecureMessagingWire.directConversationType
        title = nil
    }

    /// Group creation lists every OTHER member (the server adds the creator). Bounded to
    /// `maximumGroupMembers` including the creator and requires a canonical unique member set.
    init(groupMemberIds: [String], title: String) throws {
        guard (1 ... SecureMessagingWire.maximumGroupMembers - 1).contains(groupMemberIds.count),
              Set(groupMemberIds).count == groupMemberIds.count,
              groupMemberIds.allSatisfy(SecureMessagingWirePolicy.isCanonicalUUID)
        else { throw SecureMessagingContractError.invalid("group-conversation member IDs") }
        let cleanTitle = MessagingGroupTitlePolicy.normalized(title)
        guard MessagingGroupTitlePolicy.isValid(cleanTitle)
        else { throw SecureMessagingContractError.invalid("group-conversation title") }
        memberIds = groupMemberIds
        type = SecureMessagingWire.groupConversationType
        self.title = cleanTitle
    }

    enum CodingKeys: String, CodingKey {
        case memberIds = "member_ids"
        case type
        case title
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

/// The first iOS release that implements the Build-24 messaging additions. Keep this as one
/// contract so groups, reactions, large attachments and Reverb cannot drift to different floors.
enum MessagingBuild24CompatibilityPolicy {
    static let minimumIOSVersion = [1, 0, 16]
    static let minimumIOSBuild = 24
    static let minimumIOSRelease = "1.0.16-r24"

    static func supportsIOS(version: String?, build: Int?) -> Bool {
        guard let version else { return false }
        return supportsIOS(
            version: version,
            build: build,
            minimumVersion: minimumIOSVersion,
            minimumBuild: minimumIOSBuild
        )
    }

    static func supportsIOS(
        version value: String,
        build: Int?,
        minimumVersion: [Int],
        minimumBuild: Int
    ) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              minimumVersion.count == 3,
              let major = Int(components[0]),
              let minor = Int(components[1]),
              let patch = Int(components[2]),
              [major, minor, patch].allSatisfy({ $0 >= 0 }),
              minimumVersion.allSatisfy({ $0 >= 0 })
        else { return false }
        let version = [major, minor, patch]
        if minimumVersion.lexicographicallyPrecedes(version) { return true }
        return version == minimumVersion && (build ?? -1) >= minimumBuild
    }
}

enum MessagingRichMediaCapabilityPolicy {
    static let profile = "kit-media-v1"
    static let deviceCapabilityKey = "messaging_rich_media_v1"
    static let extendedSizeDeviceCapabilityKey = "messaging_rich_media_200m_v1"
    /// Android's currently shipped decoder cap. Payloads above it require a separate attested
    /// capability on every destination device; the iOS/server 200 MiB cap does not imply support.
    static let broadlyCompatibleMaximumPlaintextBytes = 10 * 1_024 * 1_024
    static let minimumIOSVersion = [0, 2, 5]
    static let minimumIOSBuild = 16
    static let minimumIOSRelease = "0.2.5-r16"
    static let extendedSizeMinimumIOSRelease =
        MessagingBuild24CompatibilityPolicy.minimumIOSRelease

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
                  client.capabilities?[deviceCapabilityKey] == true
            else { return false }
            // The server-attested capability flag is platform-aware (Android carries the
            // profile from 0.2.18, iOS from 0.2.5 build 16). The local iOS version floor is
            // kept as defense in depth for a server that asserts the flag without context.
            if client.platform?.lowercased() == "ios" {
                guard let version = client.version,
                      MessagingBuild24CompatibilityPolicy.supportsIOS(
                          version: version,
                          build: client.build,
                          minimumVersion: minimumIOSVersion,
                          minimumBuild: minimumIOSBuild
                      )
                else { return false }
            }
            return true
        }
    }

    static func supportsPlaintextByteSize(
        _ plaintextByteSize: Int,
        roster: MessagingDeviceRosterDTO,
        conversationID: String,
        currentDeviceID: String,
        memberUserIDs: Set<String>
    ) -> Bool {
        guard (1 ... SecureMediaAttachmentCipher.maximumPlaintextBytes)
            .contains(plaintextByteSize)
        else { return false }
        guard plaintextByteSize > broadlyCompatibleMaximumPlaintextBytes else { return true }
        guard MessagingRosterCapabilityPolicy.supports(
            deviceCapabilityKey: extendedSizeDeviceCapabilityKey,
            roster: roster,
            conversationID: conversationID,
            currentDeviceID: currentDeviceID,
            memberUserIDs: memberUserIDs,
            currentDeviceSelfAttests: false
        ), let devices = roster.devices?.compactMap({ $0 }) else { return false }
        return devices.allSatisfy { device in
            guard device.client?.platform?.lowercased() == "ios" else { return true }
            return MessagingBuild24CompatibilityPolicy.supportsIOS(
                version: device.client?.version,
                build: device.client?.build
            )
        }
    }
}

/// Fail-closed attestation gate for group conversations. Group ciphertext leaves this device
/// only when the server capability is advertised (`featureKey`) AND every enrolled device of
/// every member carries the server-attested per-device capability. A single stale device in the
/// roster blocks the send rather than silently excluding that device from the fanout.
enum MessagingGroupCapabilityPolicy {
    static let featureKey = "messaging_groups"
    static let deviceCapabilityKey = "messaging_groups_v1"
    static let minimumIOSRelease = MessagingBuild24CompatibilityPolicy.minimumIOSRelease

    /// Direct chats are unaffected by the group rollout. Group mutations fail closed whenever
    /// the capability is missing or withdrawn, while their already-decrypted history stays usable.
    static func allowsConversationMutation(
        isGroup: Bool,
        groupCapabilityEnabled: Bool
    ) -> Bool {
        !isGroup || groupCapabilityEnabled
    }

    static func supports(
        roster: MessagingDeviceRosterDTO,
        conversationID: String,
        currentDeviceID: String,
        memberUserIDs: Set<String>
    ) -> Bool {
        guard (1 ... SecureMessagingWire.maximumGroupMembers).contains(memberUserIDs.count),
              MessagingRosterCapabilityPolicy.supports(
                deviceCapabilityKey: deviceCapabilityKey,
                roster: roster,
                conversationID: conversationID,
                currentDeviceID: currentDeviceID,
                memberUserIDs: memberUserIDs
              ),
              let devices = roster.devices?.compactMap({ $0 })
        else { return false }
        return devices.allSatisfy { device in
            guard device.deviceId != currentDeviceID,
                  device.client?.platform?.lowercased() == "ios"
            else { return true }
            return MessagingBuild24CompatibilityPolicy.supportsIOS(
                version: device.client?.version,
                build: device.client?.build
            )
        }
    }
}

/// Exact server-attested roster check shared by independently gated secure-message extensions.
/// The running device is the only allowed exception because this binary itself is its
/// attestation; every other enrolled destination device must advertise the requested capability.
enum MessagingRosterCapabilityPolicy {
    static func supports(
        deviceCapabilityKey: String,
        roster: MessagingDeviceRosterDTO,
        conversationID: String,
        currentDeviceID: String,
        memberUserIDs: Set<String>,
        currentDeviceSelfAttests: Bool = true
    ) -> Bool {
        guard !deviceCapabilityKey.isEmpty,
              roster.conversationId == conversationID,
              SecureMessagingWirePolicy.isCanonicalUUID(conversationID),
              SecureMessagingWirePolicy.isCanonicalUUID(currentDeviceID),
              !memberUserIDs.isEmpty,
              memberUserIDs.count <= SecureMessagingWire.maximumGroupMembers,
              memberUserIDs.allSatisfy(SecureMessagingWirePolicy.isCanonicalUUID),
              let rawDevices = roster.devices,
              !rawDevices.isEmpty,
              rawDevices.count <= SecureMessagingWire.maximumRecipientDevices + 1
        else { return false }
        let devices = rawDevices.compactMap { $0 }
        guard devices.count == rawDevices.count,
              devices.allSatisfy({
                  $0.deviceId.map(SecureMessagingWirePolicy.isCanonicalUUID) == true
                      && $0.userId.map(SecureMessagingWirePolicy.isCanonicalUUID) == true
              }),
              Set(devices.compactMap(\.deviceId)).count == devices.count,
              Set(devices.compactMap(\.userId)) == memberUserIDs,
              devices.filter({ $0.deviceId == currentDeviceID }).count == 1
        else { return false }
        return devices.allSatisfy { device in
            if currentDeviceSelfAttests, device.deviceId == currentDeviceID { return true }
            return device.client?.capabilities?[deviceCapabilityKey] == true
        }
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
              SecureMessagingContentBindingPolicy.validatesOuterEnvelope(
                  kind: kind,
                  replyToMessageID: replyToMessageId,
                  attachmentCount: attachments.count
              )
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
    let role: String?
    /// Reserved for older event families. Build-24 membership events carry only the subject and
    /// optional role; an actor is not part of the authenticated lifecycle contract.
    let actorUserId: String?

    enum CodingKeys: String, CodingKey {
        case id, sender, kind, envelope, attachments, reactions, role
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
        case actorUserId = "actor_user_id"
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
