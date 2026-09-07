import Foundation

protocol MessagingMediaCompositionCapabilities {
    var enablesMessagingMediaMessageV2: Bool { get }
}

enum SecureMessagingReservedNamespace {
    static let payment = "KITPAY1:"
    static let scheduledPayment = "KITSCHPAY1:"
    static let scheduledGroupPayment = "KITSGRP1:"
    static let groupPayment = "KITGRP1:"
    static let groupPaymentRequest = "KITGREQ1:"
}

/// The extension decodes only the messaging capability it uses. Readiness and all media limits
/// still come from the same reviewed DTO/policies as the app.
struct DirectShareCapabilitiesDTO: Decodable, MessagingMediaCompositionCapabilities {
    struct Protocols: Decodable { let messaging: MessagingProtocolCapabilityDTO? }
    let features: [String: Bool?]?
    let protocols: Protocols?

    func supportsFeature(_ key: String) -> Bool { features?[key] == true }
    var enablesMessagingRichMedia: Bool { protocols?.messaging?.richMedia?.supportsIOSV1 == true }
    var enablesMessagingMediaMessageV2: Bool {
        supportsFeature(MessagingMediaMessageV2CapabilityPolicy.featureKey)
            && protocols?.messaging?.mediaMessage?.supportsIOSV2 == true
    }
}

struct DirectShareRefreshResult: Decodable { let session: SessionTokens? }

struct APIEnvelope<Value: Decodable>: Decodable {
    let ok: Bool
    let data: Value?
    let error: APIErrorPayload?
    let meta: APIMeta?

    private enum CodingKeys: String, CodingKey {
        case ok, data, error, meta
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        ok = try values.decode(Bool.self, forKey: .ok)
        error = try values.decodeIfPresent(APIErrorPayload.self, forKey: .error)
        meta = try values.decodeIfPresent(APIMeta.self, forKey: .meta)

        if ok {
            // Successful envelopes remain strict: a malformed success payload must never be
            // mistaken for a valid endpoint response.
            data = try values.decodeIfPresent(Value.self, forKey: .data)
        } else {
            // Error envelopes occasionally carry endpoint-specific or empty data. Decode the
            // structured error independently so challenge retry metadata is not discarded merely
            // because that irrelevant data does not match `Value`.
            do {
                data = try values.decodeIfPresent(Value.self, forKey: .data)
            } catch {
                data = nil
            }
        }
    }
}

struct APIErrorPayload: Decodable, Error {
    let code: String
    let message: String

    /// Transport metadata is attached by `APIClient` after decoding the JSON envelope. Keeping
    /// it on the error lets endpoint retry policies honor rate-limit guidance without discarding
    /// the backend's stable error code and human-readable message.
    let httpStatus: Int?
    let retryAfter: TimeInterval?
    /// Authentication challenges expose only this bounded, non-secret detail so the client can
    /// retire a challenge immediately after the server consumes its final attempt.
    let remainingAttempts: Int?

    init(
        code: String,
        message: String,
        httpStatus: Int? = nil,
        retryAfter: TimeInterval? = nil,
        remainingAttempts: Int? = nil
    ) {
        self.code = code
        self.message = message
        self.httpStatus = httpStatus
        self.retryAfter = retryAfter
        self.remainingAttempts = remainingAttempts
    }

    private enum CodingKeys: String, CodingKey {
        case code, message, details
    }

    private struct Details: Decodable {
        let remainingAttempts: Int?

        enum CodingKeys: String, CodingKey {
            case remainingAttempts = "remaining_attempts"
        }
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        code = try values.decode(String.self, forKey: .code)
        message = try values.decode(String.self, forKey: .message)
        httpStatus = nil
        retryAfter = nil
        let details: Details?
        do {
            details = try values.decodeIfPresent(Details.self, forKey: .details)
        } catch {
            // Error details vary across endpoints and are optional metadata. Preserve the stable
            // code/message even when an older or unrelated endpoint returns another JSON shape.
            details = nil
        }
        if let attempts = details?.remainingAttempts, attempts >= 0, attempts <= 100 {
            remainingAttempts = attempts
        } else {
            remainingAttempts = nil
        }
    }

    func attachingHTTP(status: Int, retryAfter: TimeInterval?) -> APIErrorPayload {
        APIErrorPayload(
            code: code,
            message: message,
            httpStatus: status,
            retryAfter: retryAfter,
            remainingAttempts: remainingAttempts
        )
    }
}

struct APIMeta: Decodable {
    let requestId: String?
    let serverTime: String?
    /// Cursor-pagination and idempotency metadata (`ApiResponse::success(..., meta:)`). Strictly
    /// optional: an absent key or JSON null decodes as nil, but a present key of the wrong type
    /// fails the whole envelope decode — endpoints that require these fields must fail closed on
    /// a malformed advertisement, never guess.
    let nextCursor: String?
    let hasMore: Bool?
    let idempotentReplay: Bool?

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case serverTime = "server_time"
        case nextCursor = "next_cursor"
        case hasMore = "has_more"
        case idempotentReplay = "idempotent_replay"
    }
}

struct SessionTokens: Codable, Hashable, Sendable {
    let accessToken: String
    let refreshToken: String
    let tokenType: String
    let accessExpiresAt: String?
    let refreshExpiresAt: String?
    let sessionId: String
    /// Local account binding written only after an authentication response pairs these
    /// credentials with a verified user. Older Keychain records and wire responses omit it.
    let accountId: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case accessExpiresAt = "access_expires_at"
        case refreshExpiresAt = "refresh_expires_at"
        case sessionId = "session_id"
        case accountId = "account_id"
    }

    init(
        accessToken: String,
        refreshToken: String,
        tokenType: String,
        accessExpiresAt: String?,
        refreshExpiresAt: String?,
        sessionId: String,
        accountId: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenType = tokenType
        self.accessExpiresAt = accessExpiresAt
        self.refreshExpiresAt = refreshExpiresAt
        self.sessionId = sessionId
        self.accountId = accountId
    }

    func bound(to userID: String) -> SessionTokens? {
        let normalizedUserID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SessionCredentialContractPolicy.isValid(self),
              !normalizedUserID.isEmpty,
              normalizedUserID.unicodeScalars.count <= 256,
              accountId.map({
                  $0.caseInsensitiveCompare(normalizedUserID) == .orderedSame
              }) != false
        else { return nil }
        return SessionTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            tokenType: tokenType,
            accessExpiresAt: accessExpiresAt,
            refreshExpiresAt: refreshExpiresAt,
            sessionId: sessionId,
            accountId: normalizedUserID
        )
    }
}

enum SessionCredentialContractPolicy {
    private static let maximumCredentialLength = 16_384

    static func isValid(_ session: SessionTokens) -> Bool {
        guard session.tokenType.caseInsensitiveCompare("Bearer") == .orderedSame,
              UUID(uuidString: session.sessionId) != nil,
              isValidCredential(session.accessToken),
              isValidCredential(session.refreshToken)
        else { return false }
        guard let accountID = session.accountId else { return true }
        let normalized = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized == accountID
            && !normalized.isEmpty
            && normalized.unicodeScalars.count <= 256
    }

    private static func isValidCredential(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumCredentialLength
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.whitespacesAndNewlines.contains($0)
                    && !CharacterSet.controlCharacters.contains($0)
            }
    }
}

struct MessagingProtocolCapabilityDTO: Decodable {
    let ready: Bool?
    let version: String?
    let suite: String?
    let postQuantum: Bool?
    var richMedia: MessagingRichMediaProtocolCapabilityDTO? = nil
    /// Media-message v2 is an additive block. A malformed advertisement must disable only the
    /// multi-attachment path — never the messaging protocol block it rides in.
    var mediaMessage: MessagingMediaMessageProtocolCapabilityDTO? = nil
    /// Chunked attachment transport is additive. Its decoder is intentionally isolated so a
    /// malformed rollout block disables resume without taking ordinary encrypted messaging down.
    var resumableAttachments: MessagingResumableAttachmentsCapabilityDTO? = nil
    /// Additive contract for idempotently promoting a locally-created direct thread. Decode
    /// failures are confined to this feature so a malformed rollout cannot disable messaging.
    var offlineDirectCreation: MessagingOfflineDirectCreationCapabilityDTO? = nil

    enum CodingKeys: String, CodingKey {
        case ready, version, suite
        case postQuantum = "post_quantum"
        case richMedia = "rich_media"
        case mediaMessage = "media_message"
        case resumableAttachments = "resumable_attachments"
        case offlineDirectCreation = "offline_direct_creation"
    }

    init(
        ready: Bool?,
        version: String?,
        suite: String?,
        postQuantum: Bool?,
        richMedia: MessagingRichMediaProtocolCapabilityDTO? = nil,
        mediaMessage: MessagingMediaMessageProtocolCapabilityDTO? = nil,
        resumableAttachments: MessagingResumableAttachmentsCapabilityDTO? = nil,
        offlineDirectCreation: MessagingOfflineDirectCreationCapabilityDTO? = nil
    ) {
        self.ready = ready
        self.version = version
        self.suite = suite
        self.postQuantum = postQuantum
        self.richMedia = richMedia
        self.mediaMessage = mediaMessage
        self.resumableAttachments = resumableAttachments
        self.offlineDirectCreation = offlineDirectCreation
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        ready = try values.decodeIfPresent(Bool.self, forKey: .ready)
        version = try values.decodeIfPresent(String.self, forKey: .version)
        suite = try values.decodeIfPresent(String.self, forKey: .suite)
        postQuantum = try values.decodeIfPresent(Bool.self, forKey: .postQuantum)
        richMedia = try values.decodeIfPresent(
            MessagingRichMediaProtocolCapabilityDTO.self,
            forKey: .richMedia
        )
        mediaMessage = try? values.decodeIfPresent(
            MessagingMediaMessageProtocolCapabilityDTO.self,
            forKey: .mediaMessage
        )
        resumableAttachments = try? values.decodeIfPresent(
            MessagingResumableAttachmentsCapabilityDTO.self,
            forKey: .resumableAttachments
        )
        offlineDirectCreation = try? values.decodeIfPresent(
            MessagingOfflineDirectCreationCapabilityDTO.self,
            forKey: .offlineDirectCreation
        )
    }

    var supportsReviewedV2: Bool {
        ready == true
            && version == SecureMessagingWire.protocolVersion
            && suite == SecureMessagingWire.protocolSuite
            && postQuantum == true
    }
}

struct MessagingOfflineDirectCreationCapabilityDTO: Decodable, Equatable {
    static let reviewedProfile = "kit-direct-conversation-v1"
    static let reviewedRequestField = "client_conversation_id"

    let profile: String?
    let ready: Bool?
    let requestField: String?
    let canonicalIDOnCreate: Bool?
    let existingPairWins: Bool?

    enum CodingKeys: String, CodingKey {
        case profile, ready
        case requestField = "request_field"
        case canonicalIDOnCreate = "canonical_id_on_create"
        case existingPairWins = "existing_pair_wins"
    }

    var supportsReviewedV1: Bool {
        profile == Self.reviewedProfile
            && ready == true
            && requestField == Self.reviewedRequestField
            && canonicalIDOnCreate == true
            && existingPairWins == true
    }
}

struct MessagingResumableAttachmentsCapabilityDTO: Decodable, Equatable, Sendable {
    let ready: Bool?
    let profile: String?
    let maxChunkBytes: Int?
    let offsetUnit: String?
    let chunkDigest: String?
    let fullDigest: String?

    enum CodingKeys: String, CodingKey {
        case ready, profile
        case maxChunkBytes = "max_chunk_bytes"
        case offsetUnit = "offset_unit"
        case chunkDigest = "chunk_digest"
        case fullDigest = "full_digest"
    }

    var validatedMaximumChunkBytes: Int? {
        guard ready == true,
              profile == MessagingResumableAttachmentPolicy.profile,
              maxChunkBytes == MessagingResumableAttachmentPolicy.maximumChunkBytes,
              offsetUnit == "ciphertext_byte",
              chunkDigest == "sha256",
              fullDigest == "sha256"
        else { return nil }
        return maxChunkBytes
    }
}

struct MessagingRichMediaProtocolCapabilityDTO: Decodable {
    let ready: Bool?
    let profile: String?
    let supportedPlatforms: [String?]?
    let minimumIOSVersion: String?
    let minimumCiphertextBytes: Int64?
    let maximumPlaintextBytes: Int?
    let maximumCiphertextBytes: Int64?
    let largeAttachmentCapability: String?
    let largeAttachmentSupportedPlatforms: [String?]?
    let largeAttachmentMinimumIOSVersion: String?
    let mediaTypes: [String?]?

    enum CodingKeys: String, CodingKey {
        case ready, profile
        case supportedPlatforms = "supported_platforms"
        case minimumIOSVersion = "minimum_ios_version"
        case minimumCiphertextBytes = "minimum_ciphertext_bytes"
        case maximumPlaintextBytes = "maximum_plaintext_bytes"
        case maximumCiphertextBytes = "maximum_ciphertext_bytes"
        case largeAttachmentCapability = "large_attachment_capability"
        case largeAttachmentSupportedPlatforms = "large_attachment_supported_platforms"
        case largeAttachmentMinimumIOSVersion = "large_attachment_minimum_ios_version"
        case mediaTypes = "media_types"
    }

    var supportsIOSV1: Bool {
        guard ready == true,
              profile == MessagingRichMediaCapabilityPolicy.profile,
              supportedPlatforms?.compactMap({ $0 }).contains("ios") == true,
              minimumIOSVersion == MessagingRichMediaCapabilityPolicy.minimumIOSRelease,
              minimumCiphertextBytes == SecureMessagingWire.minimumAttachmentCiphertextBytes,
              maximumPlaintextBytes == SecureMediaAttachmentCipher.maximumPlaintextBytes,
              maximumCiphertextBytes == SecureMessagingWire.maximumAttachmentCiphertextBytes,
              largeAttachmentCapability
                == MessagingRichMediaCapabilityPolicy.extendedSizeDeviceCapabilityKey,
              largeAttachmentSupportedPlatforms?.compactMap({ $0 }) == ["ios"],
              largeAttachmentMinimumIOSVersion
                == MessagingRichMediaCapabilityPolicy.extendedSizeMinimumIOSRelease,
              let advertisedMediaTypes = mediaTypes?.compactMap({ $0 })
        else { return false }
        return Set(advertisedMediaTypes).isSuperset(
            of: SecureMessagingWire.allowedAttachmentMediaTypes
        )
    }
}

enum AccountVerificationDesignation: String, Codable, Hashable, Sendable {
    case verified
    case official
    case officialSupport = "official_support"

    var accessibilityLabel: String {
        switch self {
        case .verified:
            return "Verified account"
        case .official:
            return "Official account"
        case .officialSupport:
            return "Official Kit Pay support"
        }
    }
}

struct AccountVerificationDTO: Codable, Hashable, Sendable {
    let designation: AccountVerificationDesignation?
    let since: String?

    init(designation: AccountVerificationDesignation?, since: String? = nil) {
        self.designation = designation
        self.since = since
    }

    private enum CodingKeys: String, CodingKey {
        case designation, since
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawDesignation = try container.decodeIfPresent(String.self, forKey: .designation)
        designation = rawDesignation.flatMap(AccountVerificationDesignation.init(rawValue:))
        since = try container.decodeIfPresent(String.self, forKey: .since)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(designation?.rawValue, forKey: .designation)
        try container.encodeIfPresent(since, forKey: .since)
    }
}

struct AccountIdentityProjection: Codable, Hashable, Sendable {
    let displayName: String?
    let avatarURL: String?
    let verification: AccountVerificationDTO?

    init?(
        displayName: String?,
        avatarURL: String?,
        verification: AccountVerificationDTO?
    ) {
        let cleanName = Self.validatedDisplayName(displayName)
        let cleanAvatarURL = Self.validatedAvatarURL(avatarURL)
        let cleanVerification = verification?.designation == nil ? nil : verification
        guard cleanName != nil || cleanAvatarURL != nil || cleanVerification != nil else {
            return nil
        }
        self.displayName = cleanName
        self.avatarURL = cleanAvatarURL
        self.verification = cleanVerification
    }

    static func validatedDisplayName(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= 512,
              !value.unicodeScalars.contains(where: { $0.value == 0 })
        else { return nil }
        return value
    }

    static func validatedAvatarURL(_ rawValue: String?) -> String? {
        MessagingAccountAvatarURLPolicy.validatedURL(rawValue)?.absoluteString
    }

    var isValid: Bool {
        displayName == Self.validatedDisplayName(displayName)
            && avatarURL == Self.validatedAvatarURL(avatarURL)
            && (verification.map({ $0.designation != nil }) ?? true)
            && (displayName != nil || avatarURL != nil || verification != nil)
    }
}

struct SecureMessagingRetainedMessageMetadata: Codable, Hashable, Sendable {
    let clientMessageID: String
    /// Authenticated sender bound to this metadata when the envelope was decrypted. Optional so
    /// pre-field local state remains decodable; security-sensitive departed-member recovery must
    /// require it rather than inferring attribution from the surrounding mutable projection.
    let senderUserID: String?
    let senderDeviceID: String
    let senderEnrollmentEpoch: Int64
    let senderSignalDeviceID: UInt32
    let rosterRevision: String
    let kind: SecureMessagingMessageKind
    let replyToMessageID: String?
}

enum MessagingAccountAvatarURLPolicy {
    static func validatedURL(_ avatarURL: String?) -> URL? {
        guard let avatarURL,
              let url = URL(string: avatarURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.caseInsensitiveCompare("https") == .orderedSame,
              url.host?.isEmpty == false
        else { return nil }
        return url
    }
}

enum KitMessageReactionOperation: String, Equatable, Sendable, CaseIterable {
    case add
    case remove
}

struct KitMessageReaction: Equatable, Sendable {
    static let prefix = "KITRXN1:"
    static let maximumDescriptorLength = 256
    static let maximumEmojiUTF8Bytes = 32

    let operation: KitMessageReactionOperation
    /// Canonical lowercase server message UUID of the message being reacted to. The server id
    /// (not the client idempotency id) is the only identifier both participants share.
    let targetServerMessageID: String
    /// The reacted emoji, bounded but deliberately not validated as "is an emoji": ZWJ
    /// sequences, skin-tone modifiers, and variation selectors evolve faster than any local
    /// allowlist, so the contract only caps size and refuses whitespace.
    let emoji: String

    init?(
        operation: KitMessageReactionOperation,
        targetServerMessageID: String,
        emoji: String
    ) {
        let canonicalEmoji = emoji.precomposedStringWithCanonicalMapping
        guard Self.isCanonicalUUID(targetServerMessageID),
              Self.isValidEmojiToken(canonicalEmoji)
        else { return nil }
        self.operation = operation
        self.targetServerMessageID = targetServerMessageID
        self.emoji = canonicalEmoji
        guard encoded.utf16.count <= Self.maximumDescriptorLength else { return nil }
    }

    var encoded: String {
        var value = Self.prefix
        value += "v=1"
        value += "&a=\(operation.rawValue)"
        value += "&t=\(Self.percentEncode(targetServerMessageID))"
        value += "&e=\(Self.percentEncode(emoji))"
        return value
    }

    static func isReactionText(_ text: String) -> Bool {
        text.hasPrefix(prefix)
    }

    static func parse(_ text: String) -> KitMessageReaction? {
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
            let encodedValue = String(pair[pair.index(after: separator)...])
            guard fields[key] == nil, let value = percentDecode(encodedValue) else { return nil }
            fields[key] = value
        }

        // Exactly {v, a, t, e}: an unknown key is a newer or foreign descriptor and must fail
        // closed instead of being partially honored.
        guard fields.count == 4,
              fields["v"] == "1",
              let operation = fields["a"].flatMap(KitMessageReactionOperation.init(rawValue:)),
              let targetServerMessageID = fields["t"],
              let emoji = fields["e"],
              let descriptor = KitMessageReaction(
                  operation: operation,
                  targetServerMessageID: targetServerMessageID,
                  emoji: emoji
              ),
              descriptor.encoded == text
        else { return nil }
        return descriptor
    }

    /// A UTF-16 whitespace check is insufficient here; scalar-level filtering also refuses
    /// separators that could visually pad a reaction chip.
    private static func isValidEmojiToken(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumEmojiUTF8Bytes
            && value.unicodeScalars.count <= 4
            && !value.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.contains($0)
                    || $0.value == 0x0085
            })
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        value.range(
            of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,
            options: .regularExpression
        ) != nil
    }

    /// Java `URLEncoder`'s safe byte set, with its `+` spaces canonicalized to `%20`.
    private static func percentEncode(_ value: String) -> String {
        let hex = Array("0123456789ABCDEF".utf8)
        var encoded = ""
        encoded.reserveCapacity(value.utf8.count * 3)
        for byte in value.utf8 {
            switch byte {
            case 48 ... 57, 65 ... 90, 97 ... 122, 45, 46, 95, 42:
                encoded.unicodeScalars.append(UnicodeScalar(byte))
            default:
                encoded.unicodeScalars.append("%")
                encoded.unicodeScalars.append(UnicodeScalar(hex[Int(byte >> 4)]))
                encoded.unicodeScalars.append(UnicodeScalar(hex[Int(byte & 0x0F)]))
            }
        }
        return encoded
    }

    private static func percentDecode(_ value: String) -> String? {
        value.replacingOccurrences(of: "+", with: "%20").removingPercentEncoding
    }
}

struct KitMessageEdit: Equatable, Sendable {
    static let prefix = "KITEDIT1:"
    private static let header = prefix + "v=1&t="
    private static let bodySeparator = "&b="
    /// The same ceiling the ordinary text profile enforces, so a correction can be as long as the
    /// message it replaces was allowed to be.
    static let maximumDescriptorLength = 8_000
    /// How long after sending its author may still replace the wording. The same figure the
    /// server enforces, so "fifteen minutes to edit" means one thing on screen and another
    /// nowhere.
    static let editWindow: TimeInterval = 15 * 60

    /// Canonical lowercase server message UUID of the message whose wording this replaces.
    let targetServerMessageID: String
    /// The replacement wording, already trimmed to what the composer would have sent.
    let body: String

    init?(targetServerMessageID: String, body: String) {
        guard SecureMessagingWirePolicy.isCanonicalUUID(targetServerMessageID),
              Self.isAcceptableBody(body)
        else { return nil }
        self.targetServerMessageID = targetServerMessageID
        self.body = body
        guard encoded.utf16.count <= Self.maximumDescriptorLength else { return nil }
    }

    var encoded: String {
        Self.header + targetServerMessageID + Self.bodySeparator + body
    }

    static func isEditText(_ text: String) -> Bool {
        text.hasPrefix(prefix)
    }

    /// Whether `body` is wording a correction may carry.
    ///
    /// It has to be something the composer could have sent in the first place: present, already
    /// trimmed, within the text profile, and not itself a descriptor in one of Kit Pay's reserved
    /// namespaces — otherwise editing would become a way to author content the composer refuses.
    static func isAcceptableBody(_ body: String) -> Bool {
        guard !body.isEmpty,
              body == body.trimmingCharacters(in: .whitespacesAndNewlines),
              header.utf16.count + 36 + bodySeparator.utf16.count + body.utf16.count
                  <= maximumDescriptorLength,
              // `allowsUserAuthoredText` already refuses this namespace along with every
              // other reserved one, so a correction cannot smuggle in a descriptor either.
              SecureMessageReservedPrefixPolicy.allowsUserAuthoredText(body)
        else { return false }
        return true
    }

    static func parse(_ text: String) -> KitMessageEdit? {
        guard text.hasPrefix(header), text.utf16.count <= maximumDescriptorLength else {
            return nil
        }
        let afterHeader = text.dropFirst(header.count)
        guard afterHeader.count > 36 + bodySeparator.count else { return nil }
        let targetServerMessageID = String(afterHeader.prefix(36))
        let remainder = afterHeader.dropFirst(36)
        guard remainder.hasPrefix(bodySeparator) else { return nil }
        let body = String(remainder.dropFirst(bodySeparator.count))
        guard let descriptor = KitMessageEdit(
            targetServerMessageID: targetServerMessageID,
            body: body
        ),
        // The authenticated descriptor has one canonical spelling, so a future parser cannot
        // assign a second meaning to already-authenticated content.
        descriptor.encoded == text
        else { return nil }
        return descriptor
    }
}

enum KitChatMediaKind: String, Codable, CaseIterable, Sendable {
    case image
    case voice
    case audio
    case video
    case document

    init(mediaType: String) {
        let normalized = mediaType.lowercased()
        if normalized.hasPrefix("image/") {
            self = .image
        } else if normalized == "audio/mp4" {
            // Kit voice notes are recorded and assembled as canonical M4A. Other supported audio
            // MIME types are imported files and must not be presented as microphone recordings.
            self = .voice
        } else if normalized.hasPrefix("audio/") {
            self = .audio
        } else if normalized.hasPrefix("video/") {
            self = .video
        } else {
            self = .document
        }
    }

    var symbolName: String {
        switch self {
        case .image: "photo.fill"
        case .voice: "mic.fill"
        case .audio: "music.note"
        case .video: "video.fill"
        case .document: "doc.fill"
        }
    }

    var previewLabel: String {
        switch self {
        case .image: "Photo"
        case .voice: "Voice note"
        case .audio: "Audio"
        case .video: "Video"
        case .document: "Document"
        }
    }
}

enum StoreError: Error, Equatable {
    case invalidCiphertext
    case protectedDataUnavailable
    case accountChanged
    case acceptedDeletionCleanupPending
}

struct CursorPage: Codable, Hashable, Sendable {
    let nextCursor: String?
    let hasMore: Bool?
    let limit: Int?

    enum CodingKeys: String, CodingKey {
        case nextCursor = "next_cursor"
        case hasMore = "has_more"
        case limit
    }
}
