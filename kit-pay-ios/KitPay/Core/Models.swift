import Foundation

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

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case serverTime = "server_time"
    }
}

struct CurrencyDTO: Codable, Hashable {
    let code: String
    let scale: String
}

struct CapabilitiesDTO: Decodable {
    let apiVersion: String?
    let currency: CurrencyDTO
    let features: [String: Bool?]?
    let authentication: [String: Bool?]?
    var protocols: CapabilityProtocolsDTO? = nil

    enum CodingKeys: String, CodingKey {
        case apiVersion = "api_version"
        case currency, features, authentication, protocols
    }

    /// Authentication and account-access capabilities fail closed when the server omits a key,
    /// returns null, or has not supplied capabilities yet.
    var supportsPhoneOTP: Bool { authentication?["phone_otp"] == true }
    var supportsEmailPassword: Bool { authentication?["email_password"] == true }
    var supportsMFA: Bool { authentication?["mfa"] == true }
    var supportsEmailRegistration: Bool { supportsFeature("email_registration") }
    var supportsEmailRecovery: Bool { supportsFeature("email_recovery") }

    /// Feature flags fail closed identically: a missing key, an explicit null and `false` all mean
    /// off. Reading through here also keeps call sites out of the three-deep optional comparison
    /// (`capabilities?.features?[key] == true`) that the type checker struggles with.
    func supportsFeature(_ key: String) -> Bool {
        guard let features, let value = features[key] else { return false }
        return value == true
    }

    /// Distinguishes "the server says no" from "the server has not said". Used by surfaces that
    /// stay available until they are explicitly withdrawn.
    func featureIsWithdrawn(_ key: String) -> Bool {
        guard let features, let value = features[key] else { return false }
        return value == false
    }
}

enum EmailAccountScreen: Equatable {
    case signIn
    case registration
    case verification
    case forgotPassword
    case resetPassword
}

/// Capability policy for email-account navigation. Verification and reset are completion routes:
/// once a user has received a token, a later rollout change must not strand that flow.
struct EmailAccountNavigationPolicy: Equatable {
    let emailPasswordEnabled: Bool
    let registrationEnabled: Bool
    let recoveryEnabled: Bool

    init(
        emailPasswordEnabled: Bool,
        registrationEnabled: Bool,
        recoveryEnabled: Bool
    ) {
        self.emailPasswordEnabled = emailPasswordEnabled
        self.registrationEnabled = registrationEnabled
        self.recoveryEnabled = recoveryEnabled
    }

    init(capabilities: CapabilitiesDTO?) {
        self.init(
            emailPasswordEnabled: capabilities?.supportsEmailPassword == true,
            registrationEnabled: capabilities?.supportsEmailRegistration == true,
            recoveryEnabled: capabilities?.supportsEmailRecovery == true
        )
    }

    func allows(_ screen: EmailAccountScreen) -> Bool {
        switch screen {
        case .signIn:
            emailPasswordEnabled
        case .registration:
            registrationEnabled
        case .verification:
            true
        case .forgotPassword:
            recoveryEnabled
        case .resetPassword:
            true
        }
    }
}

/// The inbound links Kit Pay is willing to act on.
///
/// `CFBundleURLTypes` has always registered `kitwallet://`, but nothing in the app handled an
/// inbound URL — no `onOpenURL`, no `application(_:open:options:)`, no user activity — so a link
/// from a verification or recovery email opened the app to whatever screen it happened to be on
/// and left the customer to copy the token across by hand.
///
/// Only the two pre-authentication completion routes are accepted, and only far enough to put the
/// customer on the right screen with the token filled in. Nothing is ever submitted on a link's
/// behalf: an inbound URL is untrusted input that any other app on the device can send, so it may
/// choose a screen, never an action.
enum KitDeepLink: Equatable {
    case verifyEmail(token: String)
    case resetPassword(token: String)

    static let scheme = "kitwallet"

    private static let verifyEmailHosts: Set<String> = ["verify-email", "verify"]
    private static let resetPasswordHosts: Set<String> = ["reset-password", "reset"]
    private static let tokenQueryName = "token"

    static func parse(_ url: URL) -> KitDeepLink? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == scheme,
              components.user == nil,
              components.password == nil,
              let host = components.host?.lowercased(),
              let token = token(in: components)
        else { return nil }

        if verifyEmailHosts.contains(host) { return .verifyEmail(token: token) }
        if resetPasswordHosts.contains(host) { return .resetPassword(token: token) }
        return nil
    }

    /// The screen this link completes. Both are unconditional completion routes in
    /// ``EmailAccountNavigationPolicy``, so a capability rollout cannot strand a token already
    /// sitting in somebody's inbox.
    var screen: EmailAccountScreen {
        switch self {
        case .verifyEmail: .verification
        case .resetPassword: .resetPassword
        }
    }

    private static func token(in components: URLComponents) -> String? {
        // Exactly one `token`. A repeated parameter is ambiguous about which one the customer is
        // about to submit, so it is refused rather than resolved by picking one.
        let candidates = (components.queryItems ?? []).filter { $0.name == tokenQueryName }
        guard candidates.count == 1,
              let raw = candidates[0].value
        else { return nil }
        let normalized = EmailAccountValidation.normalizeOpaqueToken(raw)
        guard EmailAccountValidation.isValidOpaqueToken(normalized),
              normalized.unicodeScalars.allSatisfy(isSafeTokenScalar)
        else { return nil }
        return normalized
    }

    /// Opaque tokens are transport-safe text. Anything outside printable ASCII — control
    /// characters, bidirectional overrides, look-alike scripts — is refused so nothing that
    /// renders deceptively can reach the field.
    private static func isSafeTokenScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value > 0x20 && scalar.value < 0x7F
    }
}

enum EmailAccountValidationError: Equatable {
    case invalidNameLength
    case placeholderName
    case invalidTagLength
    case provisionalTag
    case reservedTag
    case invalidTagCharacters
    case invalidEmail
    case weakPassword
    case passwordMismatch
    case invalidToken
}

/// Pure validation shared by account-access UI and request construction. This type never owns or
/// stores passwords or identity tokens; callers retain those values only for the current action.
enum EmailAccountValidation {
    static let passwordLengthRange = 12 ... 1_024
    static let opaqueTokenLengthRange = 64 ... 256

    private static let reservedTags: Set<String> = [
        "admin",
        "administrator",
        "api",
        "help",
        "kit",
        "kit_africa",
        "kit_pay",
        "kitafrica",
        "kitpay",
        "moderator",
        "official",
        "pay",
        "root",
        "security",
        "staff",
        "support",
        "system",
    ]

    static func normalizeEmail(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizeOpaqueToken(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizeName(_ value: String) -> String {
        var normalized = ""
        var separatorPending = false
        for scalar in value.unicodeScalars {
            if isProfileWhitespace(scalar) {
                separatorPending = !normalized.isEmpty
            } else {
                if separatorPending { normalized.append(" ") }
                normalized.unicodeScalars.append(scalar)
                separatorPending = false
            }
        }
        return normalized
    }

    static func normalizeTag(_ value: String) -> String {
        var normalized = trimProfileWhitespace(value).lowercased()
        if normalized.hasPrefix("@") { normalized.removeFirst() }
        return normalized
    }

    static func isValidEmail(_ value: String) -> Bool {
        let normalized = normalizeEmail(value)
        guard normalized.unicodeScalars.count <= 254 else { return false }
        return normalized.range(
            of: "^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$",
            options: .regularExpression
        ) != nil
    }

    static func isStrongPassword(_ value: String) -> Bool {
        let length = value.unicodeScalars.count
        guard passwordLengthRange.contains(length) else { return false }
        return value.unicodeScalars.contains { CharacterSet.uppercaseLetters.contains($0) }
            && value.unicodeScalars.contains { CharacterSet.lowercaseLetters.contains($0) }
            && value.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
    }

    static func isValidName(_ value: String) -> Bool {
        let normalized = normalizeName(value)
        return (2 ... 120).contains(normalized.unicodeScalars.count)
            && !["kit pay user", "kit wallet user"].contains(normalized.lowercased())
    }

    static func isValidTag(_ value: String) -> Bool {
        profileIdentityError(name: "Valid Name", tag: value) == nil
    }

    static func isValidOpaqueToken(_ value: String) -> Bool {
        opaqueTokenLengthRange.contains(normalizeOpaqueToken(value).unicodeScalars.count)
    }

    static func profileIdentityError(name: String, tag: String) -> EmailAccountValidationError? {
        let normalizedName = normalizeName(name)
        let normalizedTag = normalizeTag(tag)
        guard (2 ... 120).contains(normalizedName.unicodeScalars.count) else {
            return .invalidNameLength
        }
        if ["kit pay user", "kit wallet user"].contains(normalizedName.lowercased()) {
            return .placeholderName
        }
        guard (3 ... 32).contains(normalizedTag.unicodeScalars.count) else {
            return .invalidTagLength
        }
        if isProvisionalTag(normalizedTag) { return .provisionalTag }
        if normalizedTag.hasPrefix("deleted_") || reservedTags.contains(normalizedTag) {
            return .reservedTag
        }
        guard normalizedTag.unicodeScalars.allSatisfy(isAllowedTagScalar) else {
            return .invalidTagCharacters
        }
        return nil
    }

    static func registrationError(
        name: String,
        tag: String,
        email: String,
        password: String,
        passwordConfirmation: String
    ) -> EmailAccountValidationError? {
        if let identityError = profileIdentityError(name: name, tag: tag) {
            return identityError
        }
        guard isValidEmail(email) else { return .invalidEmail }
        guard isStrongPassword(password) else { return .weakPassword }
        guard password == passwordConfirmation else { return .passwordMismatch }
        return nil
    }

    static func passwordResetError(
        token: String,
        password: String,
        passwordConfirmation: String
    ) -> EmailAccountValidationError? {
        guard isValidOpaqueToken(token) else { return .invalidToken }
        guard isStrongPassword(password) else { return .weakPassword }
        guard password == passwordConfirmation else { return .passwordMismatch }
        return nil
    }

    private static func trimProfileWhitespace(_ value: String) -> String {
        let scalars = Array(value.unicodeScalars)
        guard let first = scalars.firstIndex(where: { !isProfileWhitespace($0) }),
              let last = scalars.lastIndex(where: { !isProfileWhitespace($0) })
        else { return "" }
        return scalars[first ... last].reduce(into: "") { result, scalar in
            result.unicodeScalars.append(scalar)
        }
    }

    private static func isProfileWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        if (0x0009 ... 0x000D).contains(scalar.value)
            || scalar.value == 0x0020
            || scalar.value == 0x0085 {
            return true
        }
        switch scalar.properties.generalCategory {
        case .spaceSeparator, .lineSeparator, .paragraphSeparator:
            return true
        default:
            return false
        }
    }

    private static func isAllowedTagScalar(_ scalar: Unicode.Scalar) -> Bool {
        (0x61 ... 0x7A).contains(scalar.value)
            || (0x30 ... 0x39).contains(scalar.value)
            || scalar.value == 0x5F
    }

    private static func isProvisionalTag(_ tag: String) -> Bool {
        guard tag.hasPrefix("kit_") else { return false }
        let suffix = tag.dropFirst(4)
        return suffix.count == 10 && suffix.unicodeScalars.allSatisfy {
            (0x61 ... 0x7A).contains($0.value) || (0x30 ... 0x39).contains($0.value)
        }
    }
}

extension CapabilitiesDTO {
    /// Profile photos have a narrower image-sanitization path than general chat media. Prefer
    /// the dedicated capability when the server advertises it, while remaining compatible with
    /// older deployments that exposed profile photos through the broader media flag.
    var enablesProfileAvatars: Bool {
        guard let features else { return false }
        if features.keys.contains("profile_avatars") {
            return supportsFeature("profile_avatars")
        }
        return supportsFeature("media")
    }

    /// Rich chat media is independently deployable from the reviewed Signal text/image wire.
    /// Missing and null values fail closed until the attachment service and peer-roster metadata
    /// are available together.
    var enablesMessagingRichMedia: Bool {
        protocols?.messaging?.richMedia?.supportsIOSV1 == true
    }
}

struct CapabilityProtocolsDTO: Decodable {
    let messaging: MessagingProtocolCapabilityDTO?
    /// Realtime is an additive transport hint. A malformed advertisement must disable only the
    /// socket path rather than making the entire capabilities response unusable.
    var realtime: RealtimeProtocolCapabilityDTO? = nil

    private enum CodingKeys: String, CodingKey {
        case messaging, realtime
    }

    init(
        messaging: MessagingProtocolCapabilityDTO?,
        realtime: RealtimeProtocolCapabilityDTO? = nil
    ) {
        self.messaging = messaging
        self.realtime = realtime
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        messaging = try values.decodeIfPresent(
            MessagingProtocolCapabilityDTO.self,
            forKey: .messaging
        )
        realtime = try? values.decodeIfPresent(
            RealtimeProtocolCapabilityDTO.self,
            forKey: .realtime
        )
    }
}

struct RealtimeProtocolCapabilityDTO: Decodable {
    let version: Int?
    let scheme: String?
    let host: String?
    let port: Int?
    let path: String?
    let key: String?
    let protocolVersion: Int?
    let authPath: String?
    let activityTimeout: Int?
    let maximumConnectionSeconds: Int?
    let channels: RealtimeChannelTemplatesDTO?
    let presence: Bool?
    let typing: Bool?

    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case scheme, host, port, path, key, channels, presence, typing
        case protocolVersion = "protocol"
        case authPath = "auth_path"
        case activityTimeout = "activity_timeout"
        case maximumConnectionSeconds = "max_connection_seconds"
    }

    var validatedConfiguration: KitRealtimeConfiguration? {
        KitRealtimeConfiguration(capability: self)
    }
}

struct RealtimeChannelTemplatesDTO: Decodable {
    let user: String?
    let conversation: String?
}

/// A completely validated protocol-v1 advertisement. No network code consumes the permissive
/// wire DTO directly, so an omitted, mistyped, downgraded, or redirected member fails closed.
struct KitRealtimeConfiguration: Equatable, Hashable, Sendable {
    static let expectedUserChannelTemplate = "private-kit.user.{user}"
    static let expectedConversationChannelTemplate = "presence-kit.conv.{conversation}"
    static let expectedAuthPath = "/api/kit-wallet/v1/messaging/realtime/auth"
    /// The backend withholds this protocol block from older sessions.
    static let minimumIOSRelease = MessagingBuild24CompatibilityPolicy.minimumIOSRelease

    let host: String
    let port: Int
    let path: String
    let key: String
    let authPath: String
    let activityTimeout: TimeInterval
    let maximumConnectionSeconds: TimeInterval
    let userChannelTemplate: String
    let conversationChannelTemplate: String
    let presenceEnabled: Bool
    let typingEnabled: Bool

    init?(capability: RealtimeProtocolCapabilityDTO) {
        guard capability.version == 1,
              capability.protocolVersion == 7,
              capability.scheme?.lowercased() == "wss",
              let rawHost = capability.host?.lowercased(),
              rawHost == "pay.kit.africa",
              capability.port == 443,
              let path = capability.path,
              let key = capability.key,
              (1 ... 128).contains(key.utf8.count),
              key.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0)
                      || $0.value == 0x2D
                      || $0.value == 0x5F
              }),
              path == "/app/\(key)",
              capability.authPath == Self.expectedAuthPath,
              let activityTimeout = capability.activityTimeout,
              (10 ... 120).contains(activityTimeout),
              let maximumConnectionSeconds = capability.maximumConnectionSeconds,
              (60 ... 1_800).contains(maximumConnectionSeconds),
              capability.channels?.user == Self.expectedUserChannelTemplate,
              capability.channels?.conversation == Self.expectedConversationChannelTemplate,
              let presenceEnabled = capability.presence,
              let typingEnabled = capability.typing,
              !typingEnabled || presenceEnabled
        else { return nil }

        host = rawHost
        port = 443
        self.path = path
        self.key = key
        authPath = Self.expectedAuthPath
        self.activityTimeout = TimeInterval(activityTimeout)
        self.maximumConnectionSeconds = TimeInterval(maximumConnectionSeconds)
        userChannelTemplate = Self.expectedUserChannelTemplate
        conversationChannelTemplate = Self.expectedConversationChannelTemplate
        self.presenceEnabled = presenceEnabled
        self.typingEnabled = typingEnabled
    }

    var socketURL: URL? {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = host
        components.port = port
        components.path = path
        components.queryItems = [
            URLQueryItem(name: "protocol", value: "7"),
            URLQueryItem(name: "client", value: "kit-ios"),
            URLQueryItem(name: "version", value: "1"),
            URLQueryItem(name: "flash", value: "false"),
        ]
        return components.url
    }

    var relativeAuthPath: String {
        String(authPath.dropFirst("/api/kit-wallet/v1/".count))
    }

    func userChannel(userID: String) -> String {
        userChannelTemplate.replacingOccurrences(of: "{user}", with: userID)
    }

    func conversationChannel(conversationID: String) -> String {
        conversationChannelTemplate.replacingOccurrences(
            of: "{conversation}",
            with: conversationID
        )
    }

    /// Stable identity for SwiftUI task invalidation. It contains no credential material.
    var lifecycleIdentity: String {
        [
            host, String(port), path, key, String(Int(activityTimeout)),
            String(Int(maximumConnectionSeconds)), String(presenceEnabled), String(typingEnabled),
        ].joined(separator: "|")
    }
}

struct MessagingProtocolCapabilityDTO: Decodable {
    let ready: Bool?
    let version: String?
    let suite: String?
    let postQuantum: Bool?
    var richMedia: MessagingRichMediaProtocolCapabilityDTO? = nil

    enum CodingKeys: String, CodingKey {
        case ready, version, suite
        case postQuantum = "post_quantum"
        case richMedia = "rich_media"
    }

    var supportsReviewedV2: Bool {
        ready == true
            && version == SecureMessagingWire.protocolVersion
            && suite == SecureMessagingWire.protocolSuite
            && postQuantum == true
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

struct DeviceRegistration: Encodable {
    let installationId: String
    let name: String
    let platform = "ios"
    let appVersion: String
    let osVersion: String
    let model: String

    enum CodingKeys: String, CodingKey {
        case installationId = "installation_id"
        case name, platform
        case appVersion = "app_version"
        case osVersion = "os_version"
        case model
    }
}

struct AuthChallenge: Codable, Hashable {
    let id: String
    let type: String
    let method: String?
    let destination: String?
    let expiresAt: String?
    let resendAfterSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case id, type, method, destination
        case expiresAt = "expires_at"
        case resendAfterSeconds = "resend_after_seconds"
    }

    init(
        id: String,
        type: String,
        method: String? = nil,
        destination: String? = nil,
        expiresAt: String? = nil,
        resendAfterSeconds: Double? = nil
    ) {
        self.id = id
        self.type = type
        self.method = method
        self.destination = destination
        self.expiresAt = expiresAt
        self.resendAfterSeconds = resendAfterSeconds
    }

    var kind: AuthChallengeKind? {
        switch type.lowercased() {
        case "otp", "phone_otp":
            .phoneOTP
        case "two_factor":
            .twoFactor
        default:
            nil
        }
    }
}

enum AuthChallengeKind: Equatable {
    case phoneOTP
    case twoFactor
}

/// Normalizes only the proof formats supported by the authentication backend. TOTP challenges may
/// also consume a saved 20-character hexadecimal recovery code; phone, SMS, and email challenges
/// remain strictly six ASCII digits.
enum AuthenticationCodePolicy {
    static func normalizedCode(_ value: String, for challenge: AuthChallenge) -> String? {
        if let digits = normalizedSixDigitCode(value) { return digits }
        guard challenge.kind == .twoFactor,
              challenge.method?.caseInsensitiveCompare("totp") == .orderedSame
        else { return nil }
        return MFAFactorCodePolicy.normalizedRecoveryCode(value)
    }

    private static func normalizedSixDigitCode(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.unicodeScalars.count == 6,
              trimmed.unicodeScalars.allSatisfy({ (0x30 ... 0x39).contains($0.value) })
        else { return nil }
        return trimmed
    }
}

enum AuthenticationChallengeTimingPolicy {
    static let maximumResendDelaySeconds: TimeInterval = 3_600

    static func expirationDate(for challenge: AuthChallenge) -> Date? {
        guard let rawValue = challenge.expiresAt else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: rawValue) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: rawValue)
    }

    static func isExpired(_ challenge: AuthChallenge, at date: Date = Date()) -> Bool {
        // Expiry is part of the authentication contract. Missing or malformed server time must
        // fail closed instead of leaving a challenge usable forever on the client.
        guard let expiration = expirationDate(for: challenge) else { return true }
        return date >= expiration
    }

    static func resendAvailableAt(
        for challenge: AuthChallenge,
        receivedAt: Date
    ) -> Date? {
        guard let delay = challenge.resendAfterSeconds,
              delay.isFinite,
              delay >= 0,
              delay <= maximumResendDelaySeconds,
              let expiration = expirationDate(for: challenge)
        else { return nil }
        let candidate = receivedAt.addingTimeInterval(delay)
        guard candidate.timeIntervalSinceReferenceDate.isFinite else { return nil }
        return min(candidate, expiration)
    }

    static func secondsUntilResend(
        for challenge: AuthChallenge,
        receivedAt: Date,
        now: Date = Date()
    ) -> Int? {
        guard let availableAt = resendAvailableAt(for: challenge, receivedAt: receivedAt) else {
            return nil
        }
        let remaining = max(0, availableAt.timeIntervalSince(now))
        guard remaining.isFinite, remaining <= maximumResendDelaySeconds else { return nil }
        return Int(ceil(remaining))
    }
}

/// Validates the fields the production identity service binds to an authentication challenge.
/// A resend must preserve the exact challenge ID: the backend re-sends the same code while that
/// request remains active, so accepting a replacement ID could pair an earlier SMS with a newer
/// server-side challenge.
enum AuthenticationChallengeContractPolicy {
    static func isValid(
        _ challenge: AuthChallenge,
        expectedKind: AuthChallengeKind,
        at date: Date = Date()
    ) -> Bool {
        guard challenge.kind == expectedKind,
              UUID(uuidString: challenge.id) != nil,
              !AuthenticationChallengeTimingPolicy.isExpired(challenge, at: date)
        else { return false }

        if let destination = challenge.destination {
            let normalized = destination.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, normalized.unicodeScalars.count <= 256 else {
                return false
            }
        }
        if challenge.resendAfterSeconds != nil,
           AuthenticationChallengeTimingPolicy.resendAvailableAt(
            for: challenge,
            receivedAt: date
           ) == nil {
            return false
        }

        switch expectedKind {
        case .phoneOTP:
            guard challenge.method?.caseInsensitiveCompare("sms") == .orderedSame else {
                return false
            }
        case .twoFactor:
            guard let method = challenge.method?.lowercased(),
                  ["totp", "sms", "email"].contains(method)
            else { return false }
        }
        return true
    }

    static func acceptsPhoneRenewal(
        from previous: AuthChallenge,
        to renewed: AuthChallenge,
        at date: Date = Date()
    ) -> Bool {
        guard previous.kind == .phoneOTP,
              previous.method?.caseInsensitiveCompare("sms") == .orderedSame,
              previous.id.caseInsensitiveCompare(renewed.id) == .orderedSame,
              destinationsDoNotConflict(previous.destination, renewed.destination)
        else { return false }
        return isValid(renewed, expectedKind: .phoneOTP, at: date)
    }

    private static func destinationsDoNotConflict(_ first: String?, _ second: String?) -> Bool {
        guard let first, let second else { return true }
        let normalizedFirst = first.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSecond = second.trimmingCharacters(in: .whitespacesAndNewlines)
        return !normalizedFirst.isEmpty
            && normalizedFirst.caseInsensitiveCompare(normalizedSecond) == .orderedSame
    }
}

enum AuthenticationChallengeErrorPolicy {
    static func isTerminal(_ error: Error) -> Bool {
        guard let payload = error as? APIErrorPayload else { return false }
        if payload.code == "CHALLENGE_CODE_INVALID", payload.remainingAttempts == 0 {
            return true
        }
        return [
            "CHALLENGE_ALREADY_USED",
            "CHALLENGE_DEVICE_MISMATCH",
            "CHALLENGE_EXPIRED",
            "CHALLENGE_INVALID",
            "CHALLENGE_LOCKED",
        ].contains(payload.code)
    }
}

struct TOTPEnrollmentDTO: Decodable, Equatable, Sendable {
    let enrollmentId: String
    let secret: String
    let provisioningURI: String
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case enrollmentId = "enrollment_id"
        case secret
        case provisioningURI = "provisioning_uri"
        case expiresAt = "expires_at"
    }
}

struct MFAStatusDTO: Decodable, Equatable, Sendable {
    let enabled: Bool?
    let recoveryCodes: [String]?

    enum CodingKeys: String, CodingKey {
        case enabled
        case recoveryCodes = "recovery_codes"
    }
}

struct MFARecoveryCodesDTO: Decodable, Equatable, Sendable {
    let recoveryCodes: [String]?

    enum CodingKeys: String, CodingKey {
        case recoveryCodes = "recovery_codes"
    }
}

struct MFAFactorRequest: Encodable, Equatable, Sendable {
    let code: String
}

enum MFAFactorCodePolicy {
    static let requiredRecoveryCodeCount = 10

    static func normalizedSixDigitCode(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.unicodeScalars.count == 6,
              trimmed.unicodeScalars.allSatisfy({ (0x30 ... 0x39).contains($0.value) })
        else { return nil }
        return trimmed
    }

    static func normalizedFactorCode(_ value: String) -> String? {
        if let code = normalizedSixDigitCode(value) { return code }
        return normalizedRecoveryCode(value)
    }

    /// Recovery codes are returned only once. Normalize and validate the complete collection
    /// before presenting any of it so a partial or malformed response never looks safely saved.
    static func validatedRecoveryCodes(_ values: [String]?) -> [String]? {
        guard let values, values.count == requiredRecoveryCodeCount else { return nil }
        var seen: Set<String> = []
        var formatted: [String] = []
        formatted.reserveCapacity(values.count)
        for value in values {
            guard let normalized = normalizedRecoveryCode(value),
                  seen.insert(normalized).inserted
            else { return nil }
            formatted.append(
                stride(from: 0, to: normalized.count, by: 4)
                    .map { offset in
                        let start = normalized.index(normalized.startIndex, offsetBy: offset)
                        let end = normalized.index(start, offsetBy: 4)
                        return String(normalized[start ..< end])
                    }
                    .joined(separator: "-")
            )
        }
        return formatted
    }

    static func normalizedRecoveryCode(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard normalized.unicodeScalars.allSatisfy({ scalar in
            (0x30 ... 0x39).contains(scalar.value)
                || (0x41 ... 0x46).contains(scalar.value)
                || scalar.value == 0x2D
                || CharacterSet.whitespacesAndNewlines.contains(scalar)
        }) else { return nil }
        let compact = String(normalized.filter { $0 != "-" && !$0.isWhitespace })
        guard compact.unicodeScalars.count == 20,
              compact.unicodeScalars.allSatisfy({ scalar in
                  (0x30 ... 0x39).contains(scalar.value)
                      || (0x41 ... 0x46).contains(scalar.value)
              })
        else { return nil }
        return compact
    }
}

struct MFARecoveryCodePresentationItem: Identifiable, Equatable {
    let number: Int
    let code: String

    var id: Int { number }
    var accessibilityLabel: String { "Recovery code \(number)" }
    var accessibilityValue: String { code.replacingOccurrences(of: "-", with: " ") }
}

enum MFARecoveryCodePresentationPolicy {
    static func items(for codes: [String]) -> [MFARecoveryCodePresentationItem] {
        codes.enumerated().map { offset, code in
            MFARecoveryCodePresentationItem(number: offset + 1, code: code)
        }
    }

    static func exportText(for codes: [String]) -> String {
        let body = items(for: codes)
            .map { "\($0.number). \($0.code)" }
            .joined(separator: "\n")
        return "Kit Pay recovery codes\n\n\(body)\n\nEach code works once. Store them privately."
    }
}

enum TOTPEnrollmentPolicy {
    static func expirationDate(for enrollment: TOTPEnrollmentDTO) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: enrollment.expiresAt) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: enrollment.expiresAt)
    }

    static func isExpired(_ enrollment: TOTPEnrollmentDTO, at date: Date = Date()) -> Bool {
        guard let expiration = expirationDate(for: enrollment) else { return true }
        return date >= expiration
    }

    static func validatedProvisioningURL(
        for enrollment: TOTPEnrollmentDTO,
        at date: Date = Date()
    ) -> URL? {
        guard UUID(uuidString: enrollment.enrollmentId) != nil,
              !isExpired(enrollment, at: date),
              isValidBase32Secret(enrollment.secret),
              let components = URLComponents(string: enrollment.provisioningURI),
              components.scheme?.caseInsensitiveCompare("otpauth") == .orderedSame,
              components.host?.caseInsensitiveCompare("totp") == .orderedSame,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.fragment == nil,
              let queryItems = components.queryItems,
              queryItems.count == 5
        else { return nil }

        var parameters: [String: String] = [:]
        for item in queryItems {
            guard let value = item.value,
                  parameters.updateValue(value, forKey: item.name) == nil
            else { return nil }
        }
        guard Set(parameters.keys) == ["secret", "issuer", "algorithm", "digits", "period"],
              parameters["secret"] == enrollment.secret,
              parameters["issuer"] == "Kit Pay",
              parameters["algorithm"] == "SHA1",
              parameters["digits"] == "6",
              parameters["period"] == "30",
              labelIsBoundToIssuer(components.percentEncodedPath, issuer: "Kit Pay"),
              let url = components.url
        else { return nil }
        return url
    }

    static func isValid(_ enrollment: TOTPEnrollmentDTO, at date: Date = Date()) -> Bool {
        validatedProvisioningURL(for: enrollment, at: date) != nil
    }

    /// Grouping makes the manual secret easier to transcribe at large text sizes without
    /// changing the exact value copied to the pasteboard or sent back to the server.
    static func displaySecret(_ value: String) -> String? {
        guard isValidBase32Secret(value) else { return nil }
        return stride(from: 0, to: value.count, by: 4)
            .map { offset in
                let start = value.index(value.startIndex, offsetBy: offset)
                let end = value.index(start, offsetBy: 4)
                return String(value[start ..< end])
            }
            .joined(separator: " ")
    }

    static func accessibilityValue(forSecret value: String) -> String? {
        guard isValidBase32Secret(value) else { return nil }
        return value.map(String.init).joined(separator: " ")
    }

    private static func isValidBase32Secret(_ value: String) -> Bool {
        value.unicodeScalars.count == 32
            && value.unicodeScalars.allSatisfy({ scalar in
                (0x41 ... 0x5A).contains(scalar.value)
                    || (0x32 ... 0x37).contains(scalar.value)
            })
    }

    private static func labelIsBoundToIssuer(_ encodedPath: String, issuer: String) -> Bool {
        guard encodedPath.hasPrefix("/"),
              let label = String(encodedPath.dropFirst()).removingPercentEncoding,
              !label.contains("/"),
              let separator = label.firstIndex(of: ":")
        else { return false }
        let labelIssuer = String(label[..<separator])
        let account = String(label[label.index(after: separator)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return labelIssuer == issuer
            && !account.isEmpty
            && account.unicodeScalars.count <= 254
    }
}

enum TOTPEnrollmentErrorPolicy {
    static func isTerminal(_ error: Error) -> Bool {
        guard let payload = error as? APIErrorPayload else { return false }
        return [
            "MFA_ALREADY_ENABLED",
            "MFA_ENROLLMENT_EXPIRED",
            "MFA_ENROLLMENT_NOT_FOUND",
        ].contains(payload.code)
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

enum SessionAccountBindingPolicy {
    static func matches(_ session: SessionTokens, profile: UserProfile?) -> Bool {
        guard SessionCredentialContractPolicy.isValid(session),
              let accountID = session.accountId,
              let profileID = profile?.id
        else { return false }
        return accountID.caseInsensitiveCompare(profileID) == .orderedSame
    }

    /// A legacy Keychain record may be bound only to the profile returned by an authenticated
    /// request made with those exact credentials. A cached local profile is never proof of account
    /// ownership and must not be passed to this migration helper.
    static func bindLegacySession(
        _ session: SessionTokens,
        authenticatedProfile: UserProfile
    ) -> SessionTokens? {
        guard session.accountId == nil else { return nil }
        return session.bound(to: authenticatedProfile.id)
    }

    static func identifiesSameAccountSession(
        _ first: SessionTokens,
        _ second: SessionTokens
    ) -> Bool {
        SessionCredentialContractPolicy.isValid(first)
            && SessionCredentialContractPolicy.isValid(second)
            && sameServerSession(first, second)
            && sameOptionalIdentifier(first.accountId, second.accountId)
    }

    static func sameServerSession(_ first: SessionTokens, _ second: SessionTokens) -> Bool {
        first.sessionId.caseInsensitiveCompare(second.sessionId) == .orderedSame
    }

    static func restorationProjectionMatches(
        _ state: PersistedState,
        expectedProfileID: String?,
        expectedOwnerID: String?
    ) -> Bool {
        sameOptionalIdentifier(state.profile?.id, expectedProfileID)
            && sameOptionalIdentifier(state.communicationOwnerUserID, expectedOwnerID)
    }

    private static func sameOptionalIdentifier(_ first: String?, _ second: String?) -> Bool {
        switch (first, second) {
        case (nil, nil):
            return true
        case (.some(let first), .some(let second)):
            return first.caseInsensitiveCompare(second) == .orderedSame
        default:
            return false
        }
    }
}

struct AuthResult: Decodable {
    let state: String
    let challenge: AuthChallenge?
    let session: SessionTokens?
    let user: UserProfile?
    let sessionAssurance: SessionAssuranceDTO?

    enum CodingKeys: String, CodingKey {
        case state, challenge, session, user
        case sessionAssurance = "session_assurance"
    }
}

enum AuthResultDisposition: Equatable {
    case authenticated
    case challengeRequired(AuthChallengeKind)
    case invalid
}

/// Shape-based authentication state machine. It refuses unsupported challenge types and mixed
/// session/challenge responses so callers never route a two-factor code through phone OTP.
enum AuthResultPolicy {
    static func disposition(for result: AuthResult) -> AuthResultDisposition {
        switch result.state.lowercased() {
        case "authenticated":
            guard result.challenge == nil,
                  let session = result.session,
                  let user = result.user,
                  session.bound(to: user.id) != nil
            else {
                return .invalid
            }
            return .authenticated
        case "challenge_required":
            guard result.session == nil,
                  result.user == nil,
                  let kind = result.challenge?.kind
            else { return .invalid }
            return .challengeRequired(kind)
        default:
            return .invalid
        }
    }
}

struct EmailVerificationChallenge: Decodable, Equatable {
    let type: String
    let method: String
    let destination: String
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case type, method, destination
        case expiresAt = "expires_at"
    }
}

enum EmailVerificationChallengeTimingPolicy {
    /// The production resend endpoint permits three attempts per minute. A one-minute local
    /// cooldown is deliberately conservative and avoids presenting backend throttling as an error.
    static let resendCooldownSeconds: TimeInterval = 60

    static func expirationDate(for challenge: EmailVerificationChallenge) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: challenge.expiresAt) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: challenge.expiresAt)
    }

    static func isValid(_ challenge: EmailVerificationChallenge, at date: Date = Date()) -> Bool {
        challenge.type.caseInsensitiveCompare("email_verification") == .orderedSame
            && challenge.method.caseInsensitiveCompare("email") == .orderedSame
            && !challenge.destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && challenge.destination.unicodeScalars.count <= 254
            && expirationDate(for: challenge).map { $0 > date } == true
    }

    static func resendAvailableAt(from date: Date) -> Date {
        date.addingTimeInterval(resendCooldownSeconds)
    }

    static func secondsUntilResend(availableAt: Date?, now: Date = Date()) -> Int {
        guard let availableAt else { return 0 }
        let remaining = max(0, availableAt.timeIntervalSince(now))
        guard remaining.isFinite else { return 0 }
        return Int(ceil(min(remaining, resendCooldownSeconds)))
    }
}

enum AuthenticationSecretLifecyclePolicy {
    static func shouldClear(afterSuccessfulRequest succeeded: Bool) -> Bool { succeeded }

    static func shouldConceal(sceneIsActive: Bool) -> Bool { !sceneIsActive }
}

struct EmailRegistrationResult: Decodable {
    let state: String
    let challenge: EmailVerificationChallenge
    let session: SessionTokens?
    let user: UserProfile
}

struct EmailVerificationResult: Decodable {
    let verified: Bool?
    let user: UserProfile
}

enum EmailAccountResponsePolicy {
    static func acceptsRegistration(
        _ result: EmailRegistrationResult,
        requestedEmail: String,
        at date: Date = Date()
    ) -> Bool {
        let expectedEmail = EmailAccountValidation.normalizeEmail(requestedEmail)
        guard result.state.caseInsensitiveCompare("verification_required") == .orderedSame,
              result.session == nil,
              EmailVerificationChallengeTimingPolicy.isValid(result.challenge, at: date),
              let returnedEmail = result.user.email.map(EmailAccountValidation.normalizeEmail),
              EmailAccountValidation.isValidEmail(expectedEmail),
              EmailAccountValidation.isValidEmail(returnedEmail)
        else { return false }
        return returnedEmail.caseInsensitiveCompare(expectedEmail) == .orderedSame
    }

    static func verifiedEmail(from result: EmailVerificationResult) -> String? {
        guard result.verified == true,
              let email = result.user.email.map(EmailAccountValidation.normalizeEmail),
              EmailAccountValidation.isValidEmail(email)
        else { return nil }
        return email
    }
}

struct EmailMessageResult: Decodable, Equatable {
    let message: String?
}

/// Exact wire challenge returned by the authenticated profile-email endpoint. This is deliberately
/// separate from sign-in challenges: a profile proof must never be routed through an authentication
/// completion endpoint or acquire session credentials from a mixed response.
struct ProfileEmailChallengeDTO: Decodable, Equatable, Sendable {
    let id: String
    let type: String
    let method: String
    let destination: String
    let expiresAt: String?
    let resendAfterSeconds: Double?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, type, method, destination
        case expiresAt = "expires_at"
        case resendAfterSeconds = "resend_after_seconds"
    }

    init(from decoder: Decoder) throws {
        try ProfileEmailDecoding.rejectUnknownKeys(
            from: decoder,
            allowed: CodingKeys.allCases.map(\.stringValue)
        )
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        type = try values.decode(String.self, forKey: .type)
        method = try values.decode(String.self, forKey: .method)
        destination = try values.decode(String.self, forKey: .destination)
        expiresAt = try values.decodeIfPresent(String.self, forKey: .expiresAt)
        resendAfterSeconds = try values.decodeIfPresent(
            Double.self,
            forKey: .resendAfterSeconds
        )
    }
}

/// The backend uses the authentication-shaped envelope for this endpoint. Requiring an absent
/// session and user projection below prevents a malformed profile challenge from changing login
/// authority before the six-digit proof has been verified.
struct ProfileEmailRequestResultDTO: Decodable, Sendable {
    let state: String
    let challenge: ProfileEmailChallengeDTO?
    let session: SessionTokens?
    let user: UserProfile?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case state, challenge, session, user
    }

    init(from decoder: Decoder) throws {
        try ProfileEmailDecoding.rejectUnknownKeys(
            from: decoder,
            allowed: CodingKeys.allCases.map(\.stringValue)
        )
        let values = try decoder.container(keyedBy: CodingKeys.self)
        state = try values.decode(String.self, forKey: .state)
        challenge = try values.decodeIfPresent(ProfileEmailChallengeDTO.self, forKey: .challenge)
        session = try values.decodeIfPresent(SessionTokens.self, forKey: .session)
        user = try values.decodeIfPresent(UserProfile.self, forKey: .user)
    }
}

/// Process-local proof context. It intentionally does not conform to Codable, so neither the
/// challenge nor its account/session binding can enter the encrypted profile cache by accident.
struct ProfileEmailChallenge: Equatable, Sendable {
    let id: String
    let destination: String
    let requestedEmail: String
    let ownerUserID: String
    let sessionID: String
    let issuedAt: Date
    let expiresAt: Date?
    let resendAfterSeconds: Int
}

enum ProfileEmailChallengePolicy {
    static let defaultResendCooldownSeconds = 60
    static let maximumResendCooldownSeconds = 3_600

    static func normalizedEmail(_ value: String) -> String {
        EmailAccountValidation.normalizeEmail(value).lowercased()
    }

    static func challenge(
        from result: ProfileEmailRequestResultDTO,
        requestedEmail: String,
        ownerUserID: String,
        sessionID: String,
        issuedAt: Date = Date()
    ) -> ProfileEmailChallenge? {
        let requestedEmail = normalizedEmail(requestedEmail)
        guard result.state == "challenge_required",
              result.session == nil,
              result.user == nil,
              let challenge = result.challenge,
              challenge.type == "email_attachment",
              challenge.method == "email",
              EmailAccountValidation.isValidEmail(requestedEmail),
              isValidOpaqueValue(challenge.id, maximumLength: 256),
              isValidOpaqueValue(challenge.destination, maximumLength: 254),
              isValidOpaqueValue(ownerUserID, maximumLength: 256),
              SessionRefreshPolicy.isValidSessionID(sessionID)
        else { return nil }

        let expiration: Date?
        if let expiresAt = challenge.expiresAt {
            guard let parsed = timestamp(expiresAt), parsed > issuedAt else { return nil }
            expiration = parsed
        } else {
            // Android treats omitted legacy expiry metadata as server-managed. The challenge is
            // still short-lived on the backend and never survives this in-memory sheet.
            expiration = nil
        }

        let cooldown: Int
        if let rawCooldown = challenge.resendAfterSeconds {
            guard rawCooldown.isFinite else { return nil }
            cooldown = Int(
                ceil(rawCooldown)
                    .clamped(to: 0 ... Double(maximumResendCooldownSeconds))
            )
        } else {
            cooldown = defaultResendCooldownSeconds
        }

        return ProfileEmailChallenge(
            id: challenge.id,
            destination: challenge.destination,
            requestedEmail: requestedEmail,
            ownerUserID: ownerUserID,
            sessionID: sessionID,
            issuedAt: issuedAt,
            expiresAt: expiration,
            resendAfterSeconds: cooldown
        )
    }

    static func isValid(_ challenge: ProfileEmailChallenge, at date: Date = Date()) -> Bool {
        challenge.expiresAt.map { $0 > date } ?? true
    }

    static func belongs(
        _ challenge: ProfileEmailChallenge,
        toUserID userID: String,
        sessionID: String
    ) -> Bool {
        challenge.ownerUserID.caseInsensitiveCompare(userID) == .orderedSame
            && SessionRefreshPolicy.matchesSessionID(challenge.sessionID, current: sessionID)
    }

    static func resendAvailableAt(
        for challenge: ProfileEmailChallenge,
        from date: Date = Date()
    ) -> Date {
        date.addingTimeInterval(TimeInterval(challenge.resendAfterSeconds))
    }

    static func secondsUntilResend(availableAt: Date?, now: Date = Date()) -> Int {
        guard let availableAt else { return 0 }
        let remaining = availableAt.timeIntervalSince(now)
        guard remaining.isFinite, remaining > 0 else { return 0 }
        return Int(ceil(min(remaining, Double(maximumResendCooldownSeconds))))
    }

    static func isValidChallengeID(_ value: String) -> Bool {
        isValidOpaqueValue(value, maximumLength: 256)
    }

    private static func isValidOpaqueValue(_ value: String, maximumLength: Int) -> Bool {
        value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.isEmpty
            && value.unicodeScalars.count <= maximumLength
            && !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
    }

    private static func timestamp(_ value: String) -> Date? {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.range(
                of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$"#,
                options: .regularExpression
              ) != nil
        else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = value.contains(".")
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

enum ProfileEmailVerificationCodePolicy {
    static func normalizedCode(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.unicodeScalars.count == 6,
              trimmed.unicodeScalars.allSatisfy({ (0x30 ... 0x39).contains($0.value) })
        else { return nil }
        return trimmed
    }
}

enum ProfileEmailVerificationResponsePolicy {
    static func validatedProfile(
        _ response: UserProfile,
        for challenge: ProfileEmailChallenge,
        currentProfile: UserProfile
    ) -> UserProfile? {
        guard response.id.caseInsensitiveCompare(currentProfile.id) == .orderedSame,
              response.emailVerified == true,
              let rawEmail = response.email,
              EmailAccountValidation.isValidEmail(rawEmail)
        else { return nil }
        let email = ProfileEmailChallengePolicy.normalizedEmail(rawEmail)
        guard email.caseInsensitiveCompare(challenge.requestedEmail) == .orderedSame else {
            return nil
        }

        // Profile-email verification is not authority to erase unrelated cached projections when
        // an older backend omits optional fields from this focused response.
        var merged = response
        merged.name = response.name ?? currentProfile.name
        merged.email = email
        merged.phone = response.phone ?? currentProfile.phone
        merged.countryCode = response.countryCode ?? currentProfile.countryCode
        merged.tag = response.tag ?? currentProfile.tag
        merged.avatarURL = response.avatarURL ?? currentProfile.avatarURL
        merged.kycStatus = response.kycStatus ?? currentProfile.kycStatus
        merged.paymentPinSet = response.paymentPinSet ?? currentProfile.paymentPinSet
        merged.mfaEnabled = response.mfaEnabled ?? currentProfile.mfaEnabled
        merged.emailVerified = true
        merged.phoneVerified = response.phoneVerified ?? currentProfile.phoneVerified
        merged.profileSetupRequired = response.profileSetupRequired
            ?? currentProfile.profileSetupRequired
        merged.legalName = response.legalName ?? currentProfile.legalName
        merged.legalNameVerifiedAt = response.legalNameVerifiedAt
            ?? currentProfile.legalNameVerifiedAt
        merged.usernameRequired = response.usernameRequired ?? currentProfile.usernameRequired
        return merged
    }
}

enum ProfileEmailAttachmentError: LocalizedError, Equatable {
    case offline
    case unavailable
    case invalidEmail
    case invalidCode
    case invalidOrExpiredChallenge
    case operationInProgress
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .offline:
            "Connect to the internet to verify your email address."
        case .unavailable:
            "Email verification is temporarily unavailable."
        case .invalidEmail:
            "Enter a valid email address."
        case .invalidCode:
            "Enter the complete 6-digit code."
        case .invalidOrExpiredChallenge:
            "That verification code has expired. Send a new code and try again."
        case .operationInProgress:
            "Wait for the current email verification step to finish."
        case .invalidResponse:
            "Kit Pay could not confirm that email address. Please try again."
        }
    }
}

private enum ProfileEmailDecoding {
    static func rejectUnknownKeys(from decoder: Decoder, allowed: [String]) throws {
        let values = try decoder.container(keyedBy: ProfileEmailCodingKey.self)
        let allowedKeys = Set(allowed)
        guard let unknown = values.allKeys.first(where: {
            !allowedKeys.contains($0.stringValue)
        }) else { return }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: values.codingPath + [unknown],
                debugDescription: "Unsupported profile email field: \(unknown.stringValue)."
            )
        )
    }
}

private struct ProfileEmailCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}

struct PasswordResetResult: Decodable, Equatable {
    let passwordReset: Bool?

    enum CodingKeys: String, CodingKey {
        case passwordReset = "password_reset"
    }
}

struct SecurityPreferencesDTO: Decodable, Equatable, Sendable {
    let version: Int
    let verifyIdentityOnNewLogin: Bool
    let updatedAt: String?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version
        case verifyIdentityOnNewLogin = "verify_identity_on_new_login"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        try SecurityPreferencesDecoding.rejectUnknownKeys(
            from: decoder,
            allowed: CodingKeys.allCases.map(\.rawValue)
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version >= 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Security preference versions must be positive."
            )
        }
        guard container.contains(.updatedAt) else {
            throw DecodingError.keyNotFound(
                CodingKeys.updatedAt,
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "The security preference timestamp must be present, including null."
                )
            )
        }
        let updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        if let updatedAt, SecurityPreferencesDecoding.date(from: updatedAt) == nil {
            throw DecodingError.dataCorruptedError(
                forKey: .updatedAt,
                in: container,
                debugDescription: "Security preference timestamps must be RFC 3339 values."
            )
        }

        self.version = version
        verifyIdentityOnNewLogin = try container.decode(
            Bool.self,
            forKey: .verifyIdentityOnNewLogin
        )
        self.updatedAt = updatedAt
    }
}

struct UpdateSecurityPreferencesRequest: Encodable, Equatable, Sendable {
    let version: Int
    let verifyIdentityOnNewLogin: Bool

    enum CodingKeys: String, CodingKey {
        case version
        case verifyIdentityOnNewLogin = "verify_identity_on_new_login"
    }

    init(version: Int, verifyIdentityOnNewLogin: Bool) throws {
        guard version >= 1 else {
            throw SecurityPreferencesContractError.invalidVersion
        }
        self.version = version
        self.verifyIdentityOnNewLogin = verifyIdentityOnNewLogin
    }
}

enum SecurityPreferencesContractError: Error, Equatable {
    case invalidVersion
}

enum SecurityPreferencesUpdatePolicy {
    static func isValidTransition(
        from current: SecurityPreferencesDTO,
        to updated: SecurityPreferencesDTO,
        requestedValue: Bool
    ) -> Bool {
        guard updated.verifyIdentityOnNewLogin == requestedValue else { return false }
        if current.verifyIdentityOnNewLogin == requestedValue {
            return updated == current
        }
        let increment = current.version.addingReportingOverflow(1)
        return !increment.overflow
            && updated.version == increment.partialValue
            && updated.updatedAt != nil
    }
}

private enum SecurityPreferencesDecoding {
    static func rejectUnknownKeys(from decoder: Decoder, allowed: [String]) throws {
        let container = try decoder.container(keyedBy: SecurityPreferencesCodingKey.self)
        let allowedKeys = Set(allowed)
        guard let unknown = container.allKeys.first(where: {
            !allowedKeys.contains($0.stringValue)
        }) else { return }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: container.codingPath + [unknown],
                debugDescription: "Unsupported security preference field: \(unknown.stringValue)."
            )
        )
    }

    static func date(from value: String) -> Date? {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.range(
                of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$"#,
                options: .regularExpression
              ) != nil
        else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = value.contains(".")
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

private struct SecurityPreferencesCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

struct DeviceIdentityAssuranceDTO: Codable, Hashable, Sendable {
    let status: String
    let required: Bool
    let epoch: Int
    let verifiedAt: String?

    enum CodingKeys: String, CodingKey {
        case status, required, epoch
        case verifiedAt = "verified_at"
    }

    var isVerified: Bool {
        !required || status.caseInsensitiveCompare("verified") == .orderedSame
    }
}

struct LoginUnlockAssuranceDTO: Codable, Hashable, Sendable {
    let status: String
    let required: Bool
    let method: String?
    let methods: [String]?
    let unlockedAt: String?

    enum CodingKeys: String, CodingKey {
        case status, required, method, methods
        case unlockedAt = "unlocked_at"
    }

    var isUnlocked: Bool {
        !required || status.caseInsensitiveCompare("unlocked") == .orderedSame
    }

    var supportsBiometricSignature: Bool {
        methods?.contains {
            $0.caseInsensitiveCompare("biometric_signature") == .orderedSame
        } == true
    }
}

struct SessionAssuranceDTO: Codable, Hashable, Sendable {
    let deviceIdentity: DeviceIdentityAssuranceDTO
    let loginUnlock: LoginUnlockAssuranceDTO
    let access: String

    enum CodingKeys: String, CodingKey {
        case deviceIdentity = "device_identity"
        case loginUnlock = "login_unlock"
        case access
    }

    var grantsFullAccess: Bool {
        access.caseInsensitiveCompare("full") == .orderedSame
            && deviceIdentity.isVerified
            && loginUnlock.isUnlocked
    }
}

struct SessionAssuranceResponseDTO: Decodable, Hashable, Sendable {
    let sessionAssurance: SessionAssuranceDTO

    enum CodingKeys: String, CodingKey {
        case sessionAssurance = "session_assurance"
    }
}

struct SessionUnlockResultDTO: Decodable, Hashable, Sendable {
    let sessionAssurance: SessionAssuranceDTO
    let method: String

    enum CodingKeys: String, CodingKey {
        case sessionAssurance = "session_assurance"
        case method
    }
}

struct LoginBiometricChallengeDTO: Decodable, Hashable, Sendable {
    let challengeId: String
    let nonce: String
    let signingPayload: String
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case challengeId = "challenge_id"
        case nonce
        case signingPayload = "signing_payload"
        case expiresAt = "expires_at"
    }
}

struct BiometricKeyStatusDTO: Decodable, Hashable, Sendable {
    let deviceId: String?
    let algorithm: String?
    let enrolledAt: String?
    let attestationStatus: String?
    let removed: Bool?
    let sessionAssurance: SessionAssuranceDTO?

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case algorithm
        case enrolledAt = "enrolled_at"
        case attestationStatus = "attestation_status"
        case removed
        case sessionAssurance = "session_assurance"
    }
}

/// A Kit Pay account carries two deliberately separate names.
///
/// `legalName` is read off the identity document during verification and is never replaced by
/// anything the user types — it is the name that governs compliance, payouts and every other
/// place Kit Pay has to know who somebody legally is. `name` and `tag` are the chosen, public
/// identity: a display name and an optional `@username`. Keeping them in different fields is
/// what stops a chosen handle from ever being mistaken for verified identity.
///
/// `legalName` and `usernameRequired` are absent on deployments that predate the split; Swift's
/// synthesized decoder ignores unknown keys, so this stays compatible in both directions.
struct UserProfile: Codable, Hashable, Identifiable, Sendable {
    let id: String
    var name: String?
    var email: String?
    var phone: String?
    var countryCode: String? = nil
    var tag: String?
    var avatarURL: String? = nil
    var kycStatus: String?
    var paymentPinSet: Bool?
    var mfaEnabled: Bool?
    var emailVerified: Bool? = nil
    var phoneVerified: Bool? = nil
    var profileSetupRequired: Bool?
    /// The name on the verified identity document. Server-owned and never writable by the client.
    var legalName: String? = nil
    /// When that document was accepted. Absent means the legal name is not (or not yet) verified.
    var legalNameVerifiedAt: String? = nil
    /// Whether this account still has to choose an `@username` before it can use Kit Pay. Servers
    /// that predate the split omit it; `nil` reads as "required", which is the old behaviour.
    var usernameRequired: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, email, phone, tag
        case countryCode = "country_code"
        case avatarURL = "avatar_url"
        case kycStatus = "kyc_status"
        case paymentPinSet = "payment_pin_set"
        case mfaEnabled = "mfa_enabled"
        case emailVerified = "email_verified"
        case phoneVerified = "phone_verified"
        case profileSetupRequired = "profile_setup_required"
        case legalName = "legal_name"
        case legalNameVerifiedAt = "legal_name_verified_at"
        case usernameRequired = "username_required"
    }

    /// The verified legal name, or nil when identity verification has not produced one.
    var verifiedLegalName: String? {
        guard let legalName else { return nil }
        let trimmed = legalName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The chosen `@username`, or nil while the account still carries a server-issued provisional
    /// tag. A provisional tag is an allocation detail, not a name the user picked.
    var chosenUsername: String? {
        let normalized = normalizeProfileTag(tag ?? "")
        guard !normalized.isEmpty, !isProvisionalProfileTag(normalized) else { return nil }
        return normalized
    }

    /// The name to lead with in secure and financial contexts: the verified identity if there is
    /// one, otherwise whatever display name the account has.
    var identityDisplayName: String? {
        verifiedLegalName ?? {
            let normalized = normalizeProfileName(name ?? "")
            return isPlaceholderProfileName(normalized) ? nil : normalized
        }()
    }
}

/// Profile mutation endpoints may return a focused projection on deployments that predate the
/// full identity presenter. Merge omitted fields from the same authenticated account instead of
/// making unrelated state such as the current avatar, email, KYC status, or PIN flag disappear.
enum UserProfileMutationMergePolicy {
    static func merge(
        response: UserProfile,
        current: UserProfile,
        requestedName: String? = nil,
        requestedTag: String? = nil
    ) -> UserProfile? {
        guard response.id.caseInsensitiveCompare(current.id) == .orderedSame else { return nil }

        var merged = response
        merged.name = response.name ?? requestedName ?? current.name
        merged.email = response.email ?? current.email
        merged.phone = response.phone ?? current.phone
        merged.countryCode = response.countryCode ?? current.countryCode
        merged.tag = response.tag ?? requestedTag ?? current.tag
        merged.avatarURL = response.avatarURL ?? current.avatarURL
        merged.kycStatus = response.kycStatus ?? current.kycStatus
        merged.paymentPinSet = response.paymentPinSet ?? current.paymentPinSet
        merged.mfaEnabled = response.mfaEnabled ?? current.mfaEnabled
        merged.emailVerified = response.emailVerified ?? current.emailVerified
        merged.phoneVerified = response.phoneVerified ?? current.phoneVerified
        merged.profileSetupRequired = response.profileSetupRequired
            ?? ((requestedName != nil || requestedTag != nil) ? false : current.profileSetupRequired)
        // The legal name is server-owned: a profile PATCH neither carries nor may clear it, so an
        // omitted field always means "unchanged", never "removed".
        merged.legalName = response.legalName ?? current.legalName
        merged.legalNameVerifiedAt = response.legalNameVerifiedAt ?? current.legalNameVerifiedAt
        merged.usernameRequired = response.usernameRequired ?? current.usernameRequired
        return merged
    }
}

struct MediaScanDTO: Decodable, Hashable, Sendable {
    let status: String
}

struct MediaAssetDTO: Decodable, Hashable, Identifiable, Sendable {
    let id: String
    let status: String
    let scan: MediaScanDTO
}

struct MediaUploadInstructionsDTO: Decodable, Hashable, Sendable {
    let method: String
    let url: String
    let headers: [String: String]
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case method, url, headers
        case expiresAt = "expires_at"
    }
}

struct MediaUploadIntentDTO: Decodable, Hashable, Sendable {
    let asset: MediaAssetDTO
    let upload: MediaUploadInstructionsDTO
}

struct PreparedProfileAvatarUpload: Hashable, Sendable {
    let assetID: String
    let sourceSHA256: String
}

/// The source JPEG has already been uploaded and finalized at this point. Persisting only the
/// immutable asset reference keeps the retry small while allowing a later launch of the same
/// authenticated session to finish scanning and attach the resulting profile photo.
struct PendingProfileAvatarAttachment: Codable, Hashable, Sendable {
    let assetID: String
    let ownerUserID: String
    let sessionID: String
    let sourceSHA256: String
    let finalizedAt: Date
}

struct BootstrapDTO: Decodable {
    let user: UserProfile
    let wallets: [Wallet]
    let devices: [DeviceDTO]
    let selectedWalletId: String?
    let sessionAssurance: SessionAssuranceDTO?

    enum CodingKeys: String, CodingKey {
        case user, wallets, devices
        case selectedWalletId = "selected_wallet_id"
        case sessionAssurance = "session_assurance"
    }
}

struct DeviceDTO: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let platform: String
    let model: String?
    let isCurrent: Bool?
    let isTrusted: Bool?
    let trustExpiresAt: String?
    let lastSeenAt: String?
    let createdAt: String?

    init(
        id: String,
        name: String,
        platform: String,
        model: String?,
        isCurrent: Bool?,
        isTrusted: Bool? = nil,
        trustExpiresAt: String? = nil,
        lastSeenAt: String? = nil,
        createdAt: String? = nil
    ) {
        self.id = id
        self.name = name
        self.platform = platform
        self.model = model
        self.isCurrent = isCurrent
        self.isTrusted = isTrusted
        self.trustExpiresAt = trustExpiresAt
        self.lastSeenAt = lastSeenAt
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, platform, model
        case isCurrent = "is_current"
        case isTrusted = "is_trusted"
        case trustExpiresAt = "trust_expires_at"
        case lastSeenAt = "last_seen_at"
        case createdAt = "created_at"
    }
}

struct DeviceListDTO: Decodable, Sendable {
    let items: [DeviceDTO]
}

/// Validates the authenticated device directory before it can drive revocation UI. The server
/// identifies the current installation; accepting a duplicate, malformed, or current-less list
/// could otherwise let a stale row appear safe to revoke.
enum RegisteredDevicePolicy {
    private static let allowedPlatforms = Set(["android", "ios", "web", "desktop"])
    private static let maximumDeviceCount = 1_000

    static func validated(
        _ devices: [DeviceDTO],
        now: Date = Date()
    ) -> [DeviceDTO]? {
        guard !devices.isEmpty, devices.count <= maximumDeviceCount else { return nil }

        var seenIDs: Set<String> = []
        var normalized: [DeviceDTO] = []
        normalized.reserveCapacity(devices.count)
        for device in devices {
            let normalizedModel = safeOptionalText(
                device.model,
                maximumCharacters: 120
            )
            guard let id = canonicalID(device.id), seenIDs.insert(id).inserted,
                  let name = safeText(device.name, maximumCharacters: 120),
                  let platform = safePlatform(device.platform),
                  normalizedModel.isValid,
                  timestampsAreValid(device)
            else { return nil }

            let trustExpiresAt = device.trustExpiresAt.flatMap(date(from:))
            let isTrusted = device.isTrusted == true
                && trustExpiresAt.map { $0 > now } == true
            normalized.append(DeviceDTO(
                id: id,
                name: name,
                platform: platform,
                model: normalizedModel.value,
                isCurrent: device.isCurrent == true,
                isTrusted: isTrusted,
                trustExpiresAt: device.trustExpiresAt,
                lastSeenAt: device.lastSeenAt,
                createdAt: device.createdAt
            ))
        }

        guard normalized.filter({ $0.isCurrent == true }).count == 1 else { return nil }
        return normalized.sorted(by: comesBefore)
    }

    static func canRevoke(_ device: DeviceDTO) -> Bool {
        device.isCurrent != true && canonicalID(device.id) != nil
    }

    static func canonicalID(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == value, let identifier = UUID(uuidString: value) else { return nil }
        return identifier.uuidString.lowercased()
    }

    static func lastSeenDate(for device: DeviceDTO) -> Date? {
        device.lastSeenAt.flatMap(date(from:))
    }

    static func createdDate(for device: DeviceDTO) -> Date? {
        device.createdAt.flatMap(date(from:))
    }

    static func trustExpiryDate(for device: DeviceDTO) -> Date? {
        device.trustExpiresAt.flatMap(date(from:))
    }

    static func hasActiveTrust(_ device: DeviceDTO, now: Date = Date()) -> Bool {
        device.isTrusted == true
            && trustExpiryDate(for: device).map { $0 > now } == true
    }

    private static func comesBefore(_ lhs: DeviceDTO, _ rhs: DeviceDTO) -> Bool {
        if (lhs.isCurrent == true) != (rhs.isCurrent == true) { return lhs.isCurrent == true }
        let lhsSeen = lastSeenDate(for: lhs) ?? .distantPast
        let rhsSeen = lastSeenDate(for: rhs) ?? .distantPast
        if lhsSeen != rhsSeen { return lhsSeen > rhsSeen }
        let lhsCreated = createdDate(for: lhs) ?? .distantPast
        let rhsCreated = createdDate(for: rhs) ?? .distantPast
        if lhsCreated != rhsCreated { return lhsCreated > rhsCreated }
        let lhsName = lhs.name.lowercased()
        let rhsName = rhs.name.lowercased()
        if lhsName != rhsName { return lhsName < rhsName }
        return lhs.id < rhs.id
    }

    private static func timestampsAreValid(_ device: DeviceDTO) -> Bool {
        [device.trustExpiresAt, device.lastSeenAt, device.createdAt]
            .compactMap { $0 }
            .allSatisfy { date(from: $0) != nil }
    }

    private static func safePlatform(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized == value.lowercased(), allowedPlatforms.contains(normalized) else {
            return nil
        }
        return normalized
    }

    private static func safeOptionalText(
        _ value: String?,
        maximumCharacters: Int
    ) -> (isValid: Bool, value: String?) {
        guard let value else { return (true, nil) }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return (true, nil) }
        guard let safe = safeText(trimmed, maximumCharacters: maximumCharacters) else {
            return (false, nil)
        }
        return (true, safe)
    }

    private static func safeText(_ value: String, maximumCharacters: Int) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= maximumCharacters,
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return trimmed
    }

    private static func date(from value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

enum DeviceManagementError: LocalizedError, Equatable {
    case invalidDevice
    case invalidServiceResponse
    case currentDevice
    case unavailable
    case revocationFailed

    var errorDescription: String? {
        switch self {
        case .invalidDevice:
            "This linked device is no longer available. Refresh and try again."
        case .invalidServiceResponse:
            "Kit could not verify your linked devices. Please try again."
        case .currentDevice:
            "Sign out normally to remove this device."
        case .unavailable:
            "Connect to the internet to manage linked devices."
        case .revocationFailed:
            "This device could not be signed out. Please try again."
        }
    }
}

struct WalletBalances: Codable, Hashable {
    let available: String
    let ledger: String?
}

struct Wallet: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let accountNumber: String?
    let accountType: String?
    let currency: CurrencyDTO
    let balances: WalletBalances
    let status: String
    let isPrimary: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, currency, balances, status
        case accountNumber = "account_number"
        case accountType = "account_type"
        case isPrimary = "is_primary"
    }
}

struct Counterparty: Codable, Hashable {
    let id: String?
    let name: String?
    let phone: String?
    let accountNumber: String?

    enum CodingKeys: String, CodingKey {
        case id, name, phone
        case accountNumber = "account_number"
    }
}

struct WalletTransaction: Codable, Hashable, Identifiable {
    let id: String
    let walletId: String
    let reference: String
    let amount: String
    let currency: CurrencyDTO
    let type: String
    let direction: String
    let status: String
    let counterparty: Counterparty?
    let note: String?
    /// Present when a Kit Pay → Kit Pay transfer is held for recipient acceptance.
    var claim: TransferAcceptanceDTO? = nil
    let occurredAt: String

    enum CodingKeys: String, CodingKey {
        case id, reference, amount, currency, type, direction, status, counterparty, note, claim
        case walletId = "wallet_id"
        case occurredAt = "occurred_at"
    }
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

struct TransactionPage: Decodable {
    let items: [WalletTransaction]
    let page: CursorPage
}

struct ContactListDTO: Decodable, Sendable {
    let items: [WalletContactDTO]?
    let page: CursorPage?
}

struct WalletContactDTO: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let contactId: String?
    let name: String
    let phone: String
    let isKitUser: Bool?
    let favorite: Bool?
    let status: String?
    let tag: String?
    let avatarURL: String?
    let receivingWalletId: String?

    enum CodingKeys: String, CodingKey {
        case id, name, phone, favorite, status, tag
        case contactId = "contact_id"
        case isKitUser = "is_kit_user"
        case avatarURL = "avatar_url"
        case receivingWalletId = "receiving_wallet_id"
    }
}

struct StepUpChallengeDTO: Decodable, Hashable, Identifiable {
    let id: String
    let purpose: String
    let intentHash: String
    let nonce: String
    let signingPayload: String
    let methods: [String]?
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case id, purpose, nonce, methods
        case intentHash = "intent_hash"
        case signingPayload = "signing_payload"
        case expiresAt = "expires_at"
    }
}

struct StepUpVerificationDTO: Decodable, Hashable {
    let stepUpToken: String
    let expiresAt: String
    let method: String

    enum CodingKeys: String, CodingKey {
        case method
        case stepUpToken = "step_up_token"
        case expiresAt = "expires_at"
    }
}

struct PaymentPinStatusDTO: Decodable, Hashable {
    let paymentPinSet: Bool?
    let paymentPinSetAt: String?
    let sessionAssurance: SessionAssuranceDTO?

    enum CodingKeys: String, CodingKey {
        case paymentPinSet = "payment_pin_set"
        case paymentPinSetAt = "payment_pin_set_at"
        case sessionAssurance = "session_assurance"
    }
}

enum CustomerFacingMessagingCopy {
    static let encryptionAssurance = "Messages are end-to-end encrypted."
    static let openConversationFailure =
        "We could not open this chat right now. Please try again."
    static let sendFailure =
        "We could not confirm that your message was sent. Check this chat before trying again."
    static let draftSaveFailure =
        "Your draft could not be saved. Keep this chat open and try again."
    static let paymentRequestShareFailure =
        "We could not confirm that this payment request was shared. Check the chat before trying again."
    static let deliveryUnconfirmedBeforeSignOut =
        "Delivery could not be confirmed before sign-out."
    static let legacyConversationFailure =
        "This older message could not be sent. Start a new message from this chat."
}

enum MessageDeliveryState: String, Codable, Hashable {
    case queued, encrypting, sending, sent, delivered, read, failed, received
}

struct ConversationDraftWriteVersion: Codable, Hashable, Sendable {
    let writerID: UUID
    let sequence: UInt64
}

struct ConversationDraft: Codable, Hashable, Sendable {
    let body: String
    let updatedAt: Date
    /// Optional keeps drafts written before ordered persistence backward-decodable. Within one
    /// running app, later mutations from the same writer always supersede delayed debounce tasks.
    let writeVersion: ConversationDraftWriteVersion?

    init(
        body: String,
        updatedAt: Date,
        writeVersion: ConversationDraftWriteVersion? = nil
    ) {
        self.body = body
        self.updatedAt = updatedAt
        self.writeVersion = writeVersion
    }
}

/// Authenticated original wire identity retained with a decrypted/projected message. History
/// donors must match a server candidate against this exact record before re-encrypting plaintext
/// for another device on the same account. Optional storage on `LocalMessage` keeps older state
/// files readable; messages that predate this record simply cannot be used as backfill sources.
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

struct LocalMessage: Codable, Hashable, Identifiable {
    let id: UUID
    /// The server message UUID is distinct from the client-generated idempotency UUID for sends.
    /// Keeping both is required to apply authenticated delivery/read sync events correctly.
    var serverMessageId: String? = nil
    let conversationId: String
    let senderId: String
    var body: String
    let createdAt: Date
    var sentAt: Date?
    var state: MessageDeliveryState
    var failureReason: String?
    var isOutgoing: Bool
    /// Optional plaintext media is protected by SecureLocalStore's account-bound AES-GCM file.
    /// Keeping the successfully authenticated image here preserves offline chat history without
    /// placing it in UserDefaults, URLCache, Photos, or an unprotected temporary file.
    var attachmentData: Data? = nil
    /// A photo selected while offline remains an account-bound local draft until reconnect can
    /// upload its ciphertext and replace this marker with the canonical cross-platform media
    /// descriptor. Optional keeps state written by earlier builds backward-decodable.
    var pendingAttachment: LocalPendingAttachment? = nil
    /// Exact authenticated metadata needed to donate this plaintext through the history-backfill
    /// protocol. A missing value is fail-closed: the message remains visible locally but is never
    /// offered as a trusted history source to another enrollment.
    var secureMessagingHistory: SecureMessagingRetainedMessageMetadata? = nil
    /// When the sender asked for this message to leave the device. `nil` is an ordinary send.
    /// It survives delivery on purpose: a message that went out at its scheduled minute belongs
    /// at that minute in the timeline, not at the minute it was composed. Optional keeps state
    /// written by earlier builds decodable.
    var scheduledAt: Date? = nil

    /// Position in the conversation. A scheduled message sits at the moment it is promised for,
    /// which is also where it will read correctly once it has been sent.
    var timelineDate: Date { scheduledAt ?? createdAt }
}

struct LocalPendingAttachment: Codable, Hashable, Sendable {
    let mediaType: String
    let caption: String?
    /// Locally minted storage key of a large plaintext parked in the encrypted media file cache
    /// while the message waits offline for upload. Inline attachments leave this nil. Optional
    /// keeps state written by earlier builds decodable.
    var localStorageKey: String? = nil
    /// Plaintext size for pending bubbles that carry no inline data. Optional for old state.
    var byteCount: Int? = nil
}

struct Conversation: Codable, Hashable, Identifiable {
    let id: String
    var title: String
    var participantUserIds: [String]
    var unreadCount: Int
    var updatedAt: Date
    /// Server conversation type ("direct"/"group"). Optional keeps encrypted state written by
    /// earlier builds decodable — a non-Optional addition would silently reset the whole
    /// protected state on upgrade. `nil` is treated as a direct thread everywhere.
    var conversationType: String? = nil
    /// Authenticated server roles for the active group roster. Optional keeps protected state
    /// written before group management backward-decodable; missing roles expose only self-leave.
    var groupMemberRoles: [String: MessagingGroupRole]? = nil

    var isGroup: Bool { conversationType == SecureMessagingWire.groupConversationType }

    func groupRole(for userID: String?) -> MessagingGroupRole? {
        guard let userID else { return nil }
        return groupMemberRoles?[userID.lowercased()]
    }
}

enum CallState: String, Codable, Hashable, Sendable {
    case queued, ringing, active, completed, missed, declined, failed
}

struct CallRecord: Codable, Hashable, Identifiable, Sendable {
    let id: String
    var name: String
    var participantUserIds: [String]
    var direction: String
    var type: String
    var video: Bool
    var state: CallState
    var startedAt: Date
    var endedAt: Date?
    var isDeferredAttempt: Bool
    /// Server-issued conversation binding for inline call history. Optional defaults keep
    /// encrypted state written by earlier TestFlight builds backward-decodable.
    var conversationId: String? = nil
    /// A connected duration is derived only from authenticated answer/end timestamps.
    var answeredAt: Date? = nil

    /// Android treats either authenticated signal as authoritative. This also keeps media type
    /// stable when an older or partially deployed backend sends a contradictory optional flag.
    var isVideoCall: Bool {
        video || type.caseInsensitiveCompare("video") == .orderedSame
    }
}

struct CallDTO: Decodable {
    let id: String
    let conversationId: String?
    let name: String?
    let participantUserIds: [String]?
    let direction: String
    let type: String
    let video: Bool?
    let state: String
    let startedAt: String
    let answeredAt: String?
    let endedAt: String?
    let ringExpiresAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name, direction, type, video, state
        case conversationId = "conversation_id"
        case participantUserIds = "participant_user_ids"
        case startedAt = "started_at"
        case answeredAt = "answered_at"
        case endedAt = "ended_at"
        case ringExpiresAt = "ring_expires_at"
    }

    var isVideoCall: Bool {
        video == true || type.caseInsensitiveCompare("video") == .orderedSame
    }
}

struct CallPage: Decodable {
    let items: [CallDTO]?
    let page: CursorPage?
}

/// Records only a successfully completed, terminal-page call-history backfill. The explicit owner
/// and schema version prevent a retained offline cache or a future pagination contract from
/// suppressing the first full refresh for another account or implementation.
struct CallHistoryBackfillReceipt: Codable, Hashable, Sendable {
    let ownerUserID: String
    let schemaVersion: Int
    let completedAt: Date
}

enum CallHistoryBackfillPolicy {
    static let schemaVersion = 1
    static let refreshInterval: TimeInterval = 6 * 60 * 60
    static let retryDelay: TimeInterval = 5 * 60

    static func isDue(
        receipt: CallHistoryBackfillReceipt?,
        userID: String,
        now: Date = Date()
    ) -> Bool {
        guard let receipt,
              receipt.ownerUserID.caseInsensitiveCompare(userID) == .orderedSame,
              receipt.schemaVersion == schemaVersion
        else { return true }
        let age = now.timeIntervalSince(receipt.completedAt)
        return age < 0 || age >= refreshInterval
    }
}

enum OfflineCommandKind: String, Codable {
    case secureMessage
    case callAttempt
    case callTermination
    /// A payment request the sender asked Kit to raise later. Unlike a scheduled message there is
    /// nothing to hold back locally: the request must not exist on the server — and must not be
    /// visible to the person being asked — until its moment arrives, so creation itself is what
    /// gets deferred.
    case scheduledPaymentRequest
}

/// Everything needed to raise one payment request at its scheduled time. Held in the account-bound
/// encrypted state, like every other pending command.
struct ScheduledPaymentRequestPayload: Codable, Hashable, Sendable {
    let destinationWalletID: String
    let requestedFromUserID: String
    let amount: String
    /// Only for the scheduled card's preview. The authoritative currency is the destination
    /// wallet's, re-checked against the server's response when the request is finally created.
    let currencyCode: String
    let note: String?
    /// Reused on every attempt, so a retry after a timeout can never raise a second request.
    let idempotencyKey: String
    let recipientName: String
    /// The chat the confirmed request should be shared into, when it was scheduled from one.
    let conversationID: String?
}

enum OfflineCommandFailureDisposition: String, Codable, Hashable {
    /// Automatic replay is paused. The encrypted command remains account-bound on disk so the
    /// sender can explicitly retry it without silently dropping their message or rebuilding it
    /// from an unauthenticated projection.
    case requiresUserRetry
    /// The authenticated session disappeared while transport was active. Replay resumes only
    /// after a later authenticated-session restoration, never on a background timer loop.
    case awaitingSession
}

struct OfflineCommand: Codable, Hashable, Identifiable {
    let id: UUID
    let kind: OfflineCommandKind
    let createdAt: Date
    var nextAttemptAt: Date
    var attemptCount: Int
    var conversationId: String?
    var messageId: UUID?
    var recipientUserIds: [String]?
    var recipientName: String?
    var video: Bool?
    var expiresAt: Date?
    var callId: String? = nil
    var terminationKind: CallTerminationKind? = nil
    var terminationReason: String? = nil
    /// Exact Signal ciphertext committed with the ratchet update. Network retries must reuse this
    /// fanout instead of re-encrypting or reconstructing recipient devices.
    var secureMessageFanout: SecureMessagingCommittedFanout? = nil
    /// Optional fields keep state written by earlier TestFlight builds decodable.
    var failureDisposition: OfflineCommandFailureDisposition? = nil
    var lastFailureReason: String? = nil
    /// The minute the sender chose in Send Later. It is the same value as the first
    /// `nextAttemptAt`, kept separately because `nextAttemptAt` moves with every backoff and the
    /// promise shown in the conversation must not move with it.
    var scheduledAt: Date? = nil
    /// Present only on `.scheduledPaymentRequest`.
    var scheduledPaymentRequest: ScheduledPaymentRequestPayload? = nil

    /// Waiting for its moment rather than for the network. Such a command is deliberately not
    /// runnable yet, and — unlike a message backing off after a failure — it must not hold up the
    /// messages composed after it.
    func isAwaitingScheduledTime(at now: Date) -> Bool {
        guard scheduledAt != nil, failureDisposition == nil else { return false }
        return nextAttemptAt > now
    }
}

struct PersistedState: Codable {
    var profile: UserProfile?
    /// Owns every locally projected conversation, message, call and outbox command. Keeping this
    /// independently of `profile` lets a deliberate sign-out retain encrypted history for the
    /// same account without ever exposing it to a different account on this installation.
    var communicationOwnerUserID: String?
    /// Last server-confirmed assurance for this exact encrypted installation/session projection.
    /// It permits cached chats and call history to remain visible offline; every financial or
    /// network mutation still performs its ordinary live authorization checks.
    var sessionAssurance: SessionAssuranceDTO?
    var wallets: [Wallet] = []
    /// Server-confirmed active installations for the authenticated account. Optional keeps
    /// encrypted state from older builds backward-decodable and is cleared with session data.
    var registeredDevices: [DeviceDTO]?
    /// Monotonic compare-and-swap version for the encrypted device projection. This prevents an
    /// older bootstrap write from restoring a device after a confirmed remote sign-out.
    var registeredDeviceProjectionRevision: UInt64?
    var selectedWalletId: String?
    var transactions: [WalletTransaction] = []
    /// The authoritative result of the most recent address-book sync.
    /// Optional keeps encrypted state written by older app versions decodable.
    var contacts: [WalletContactDTO]?
    var contactSyncFingerprint: String?
    var contactSyncSnapshotScope: ContactSyncSnapshotScope?
    var contactSyncLastCompletedAt: Date?
    /// Whether this installation may upload its address book for contact matching. Device-local
    /// because the server carries no such field and `CommunicationPreferencesDTO` rejects unknown
    /// keys — see [[AccountDiscoveryControl]]. `nil` means the user has never chosen, which reads
    /// as enabled. Optional also keeps encrypted state written by older builds decodable.
    var contactDiscoveryEnabled: Bool?
    /// Server-backed discoverability choices made during account setup, held until the session is
    /// authorized enough to PATCH them. Optional for the same backward-decodability reason.
    var pendingAccountDiscoveryChoice: PendingAccountDiscoveryChoice?
    /// Last server-confirmed privacy settings and outgoing blocks. The enclosing state file is
    /// encrypted and account-bound; optional keeps projections from older builds decodable.
    var communicationPrivacy: CommunicationPrivacyCache?
    var conversations: [Conversation] = []
    /// Freshness clock for server-owned group fields (title, roster, and roles).
    /// Conversation.updatedAt remains the visible-activity clock, so reaction-only sync can
    /// advance this map without incorrectly moving a thread to the top of the chat list.
    /// Optional keeps protected state written by earlier builds backward-decodable.
    var groupProjectionUpdatedAt: [String: Date]?
    /// Unsent composer text is encrypted with the rest of the account-bound communication state.
    /// Optional keeps state written by earlier TestFlight builds backward-decodable.
    var conversationDrafts: [String: ConversationDraft]?
    var messages: [LocalMessage] = []
    var calls: [CallRecord] = []
    /// Optional keeps encrypted state written before paginated call backfills decodable.
    var callHistoryBackfillReceipt: CallHistoryBackfillReceipt?
    var outbox: [OfflineCommand] = []
    /// Account-bound Signal identities, prekeys, sessions, replay markers, and sync cursor.
    /// Optional keeps state written by pre-messaging builds decodable.
    var secureMessaging: SecureMessagingPersistentState?
    /// Finalized avatar uploads awaiting a clean scan and profile attachment. The session fence
    /// prevents an app restart or account switch from borrowing another login's media asset.
    var pendingProfileAvatarAttachment: PendingProfileAvatarAttachment?
    /// Locally pinned/muted chats. Optional keeps state written by older builds decodable —
    /// non-Optional additions would silently reset the entire protected state on upgrade.
    var pinnedConversationIds: [String]?
    var mutedConversationIds: [String]?
    /// End-to-end encrypted iCloud chat-backup settings and receipts. Optional for the same reason.
    var messageBackupPreferences: MessageBackupPreferences?

    static let empty = PersistedState()

    mutating func bindAuthenticatedProfile(_ authenticatedProfile: UserProfile) {
        let previousOwner = communicationOwnerUserID ?? profile?.id
        let containsUnownedAccountData = profile != nil
            || !wallets.isEmpty
            || registeredDevices?.isEmpty == false
            || registeredDeviceProjectionRevision != nil
            || selectedWalletId != nil
            || !transactions.isEmpty
            || contacts?.isEmpty == false
            || contactSyncFingerprint != nil
            || contactSyncSnapshotScope != nil
            || contactSyncLastCompletedAt != nil
            || contactDiscoveryEnabled != nil
            || pendingAccountDiscoveryChoice != nil
            || communicationPrivacy != nil
            || sessionAssurance != nil
            || !conversations.isEmpty
            || groupProjectionUpdatedAt?.isEmpty == false
            || conversationDrafts?.isEmpty == false
            || !messages.isEmpty
            || !calls.isEmpty
            || callHistoryBackfillReceipt != nil
            || !outbox.isEmpty
            || secureMessaging != nil
            || pendingProfileAvatarAttachment != nil
            || pinnedConversationIds?.isEmpty == false
            || mutedConversationIds?.isEmpty == false
            || messageBackupPreferences != nil

        if let previousOwner {
            if previousOwner.caseInsensitiveCompare(authenticatedProfile.id) != .orderedSame {
                self = .empty
            }
        } else if containsUnownedAccountData {
            // State written by an older signed-out build has no trustworthy owner. Fail closed
            // instead of assigning another person's local history to the newly authenticated ID.
            self = .empty
        }
        communicationOwnerUserID = authenticatedProfile.id
        profile = authenticatedProfile
    }

    var currentRegisteredDeviceProjectionRevision: UInt64 {
        registeredDeviceProjectionRevision ?? 0
    }

    mutating func replaceRegisteredDeviceProjection(_ devices: [DeviceDTO]) {
        registeredDevices = devices
        registeredDeviceProjectionRevision = currentRegisteredDeviceProjectionRevision &+ 1
    }
}

enum ConversationDraftPolicy {
    static let maximumBodyScalars = 8_000
    static let maximumDraftCount = 200

    static func boundedBody(_ body: String) -> String {
        var result = ""
        result.reserveCapacity(min(body.utf8.count, maximumBodyScalars))
        var scalarCount = 0
        for character in body {
            let scalars = character.unicodeScalars
            guard !scalars.contains(where: { $0.value == 0 }) else { continue }
            guard scalarCount + scalars.count <= maximumBodyScalars else { break }
            result.append(character)
            scalarCount += scalars.count
        }
        return result
    }

    static func body(
        conversationID: String,
        ownerUserID: String,
        in state: PersistedState
    ) -> String {
        guard owns(state, ownerUserID: ownerUserID),
              let conversationID = OutboxPolicy.canonicalConversationID(conversationID),
              state.conversations.contains(where: {
                  OutboxPolicy.canonicalConversationID($0.id) == conversationID
              })
        else { return "" }
        guard let draft = state.conversationDrafts?[conversationID] else { return "" }
        return boundedBody(draft.body)
    }

    @discardableResult
    static func store(
        _ body: String,
        conversationID: String,
        ownerUserID: String,
        updatedAt: Date = Date(),
        writeVersion: ConversationDraftWriteVersion? = nil,
        in state: inout PersistedState
    ) -> Bool {
        guard owns(state, ownerUserID: ownerUserID),
              let conversationID = OutboxPolicy.canonicalConversationID(conversationID),
              state.conversations.contains(where: {
                  OutboxPolicy.canonicalConversationID($0.id) == conversationID
              })
        else { return false }

        let bounded = boundedBody(body)
        var drafts = state.conversationDrafts ?? [:]
        guard permits(writeVersion, replacing: drafts[conversationID]) else { return false }
        if bounded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let writeVersion {
                // Keep an encrypted, bounded tombstone so a debounce task that was cancelled after
                // crossing an actor boundary cannot resurrect text cleared by a successful queue.
                drafts[conversationID] = ConversationDraft(
                    body: "",
                    updatedAt: updatedAt,
                    writeVersion: writeVersion
                )
                pruneOldestDrafts(&drafts, preserving: conversationID)
            } else {
                guard drafts.removeValue(forKey: conversationID) != nil else { return false }
            }
        } else {
            if drafts[conversationID]?.body == bounded,
               drafts[conversationID]?.writeVersion == writeVersion {
                return false
            }
            drafts[conversationID] = ConversationDraft(
                body: bounded,
                updatedAt: updatedAt,
                writeVersion: writeVersion
            )
            pruneOldestDrafts(&drafts, preserving: conversationID)
        }
        state.conversationDrafts = drafts.isEmpty ? nil : drafts
        return true
    }

    /// The caller invokes this only after the text or photo was durably queued. Matching the exact
    /// submitted body prevents a delayed completion from deleting text entered for the next send.
    @discardableResult
    static func clearAfterSuccessfulQueue(
        submittedBody: String,
        conversationID: String,
        ownerUserID: String,
        writeVersion: ConversationDraftWriteVersion? = nil,
        in state: inout PersistedState
    ) -> Bool {
        guard owns(state, ownerUserID: ownerUserID),
              let conversationID = OutboxPolicy.canonicalConversationID(conversationID),
              state.conversations.contains(where: {
                  OutboxPolicy.canonicalConversationID($0.id) == conversationID
              })
        else { return false }
        var drafts = state.conversationDrafts ?? [:]
        let existing = drafts[conversationID]
        guard existing == nil || existing?.body == boundedBody(submittedBody),
              permits(writeVersion, replacing: existing)
        else { return false }
        if let writeVersion {
            drafts[conversationID] = ConversationDraft(
                body: "",
                updatedAt: Date(),
                writeVersion: writeVersion
            )
            pruneOldestDrafts(&drafts, preserving: conversationID)
        } else {
            guard drafts.removeValue(forKey: conversationID) != nil else { return false }
        }
        state.conversationDrafts = drafts.isEmpty ? nil : drafts
        return true
    }

    static func shouldApplySnapshotDraft(
        _ candidate: ConversationDraft?,
        over current: ConversationDraft?,
        activeWriterID: UUID? = nil
    ) -> Bool {
        guard candidate != current else { return false }
        guard let candidate else { return current?.writeVersion == nil }
        if let activeWriterID,
           let candidateWriterID = candidate.writeVersion?.writerID,
           let currentWriterID = current?.writeVersion?.writerID,
           candidateWriterID != currentWriterID {
            if candidateWriterID == activeWriterID { return true }
            if currentWriterID == activeWriterID { return false }
        }
        return permits(candidate.writeVersion, replacing: current)
    }

    private static func permits(
        _ incoming: ConversationDraftWriteVersion?,
        replacing existing: ConversationDraft?
    ) -> Bool {
        guard let existingVersion = existing?.writeVersion else { return true }
        guard let incoming else { return false }
        guard incoming.writerID == existingVersion.writerID else {
            // Tasks do not survive a process restart. A new writer may therefore supersede a
            // tombstone or draft retained by the previous process.
            return true
        }
        return incoming.sequence > existingVersion.sequence
    }

    private static func owns(_ state: PersistedState, ownerUserID: String) -> Bool {
        guard !ownerUserID.isEmpty,
              state.profile?.id.caseInsensitiveCompare(ownerUserID) == .orderedSame,
              state.communicationOwnerUserID?.caseInsensitiveCompare(ownerUserID) == .orderedSame
        else { return false }
        return true
    }

    private static func pruneOldestDrafts(
        _ drafts: inout [String: ConversationDraft],
        preserving conversationID: String
    ) {
        guard drafts.count > maximumDraftCount else { return }
        let excess = drafts.count - maximumDraftCount
        let oldest = drafts
            .filter { $0.key != conversationID }
            .sorted {
                let lhsIsTombstone = $0.value.body.isEmpty
                let rhsIsTombstone = $1.value.body.isEmpty
                if lhsIsTombstone != rhsIsTombstone {
                    return lhsIsTombstone
                }
                if $0.value.updatedAt != $1.value.updatedAt {
                    return $0.value.updatedAt < $1.value.updatedAt
                }
                return $0.key < $1.key
            }
            .prefix(excess)
        for entry in oldest { drafts.removeValue(forKey: entry.key) }
    }
}

struct KYCStatus: Decodable, Hashable {
    let status: String
    let `case`: KYCCase?
    let providerSession: KYCProviderSession?
    let documents: [KYCDocument]?
    let deviceVerification: DeviceIdentityAssuranceDTO?

    enum CodingKeys: String, CodingKey {
        case status, `case`, documents
        case providerSession = "provider_session"
        case deviceVerification = "device_verification"
    }
}

struct KYCCase: Decodable, Hashable {
    let reference: String?
    let status: String?
    let riskLevel: String?
    let decisionCode: String?
    let decisionRationale: String?

    enum CodingKeys: String, CodingKey {
        case reference, status
        case riskLevel = "risk_level"
        case decisionCode = "decision_code"
        case decisionRationale = "decision_rationale"
    }
}

struct KYCProviderSession: Decodable, Hashable {
    let provider: String?
    let sessionId: String?
    let status: String?
    let verificationURL: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case provider, status
        case sessionId = "session_id"
        case verificationURL = "verification_url"
        case createdAt = "created_at"
    }
}

struct KYCDocument: Decodable, Hashable {
    let type: String?
    let issuingCountry: String?
    let status: String?
    let reasonCodes: [String]?

    enum CodingKeys: String, CodingKey {
        case type, status
        case issuingCountry = "issuing_country"
        case reasonCodes = "reason_codes"
    }
}
