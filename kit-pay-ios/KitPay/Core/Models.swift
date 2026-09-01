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

struct CurrencyDTO: Codable, Hashable {
    let code: String
    let scale: String
}

/// Versioned marker for pricing payloads that contain customer-facing totals only.
///
/// A missing marker is accepted for compatibility with already-deployed servers. Once a server
/// supplies the marker, an unknown value must fail closed rather than being interpreted as a
/// customer-safe fee contract.
enum CustomerPricingContract {
    static let scope = "customer_totals"

    static func accepts(scope value: String?, authoritativeTotal: String?) -> Bool {
        guard let value else { return true }
        return value == Self.scope && authoritativeTotal != nil
    }

    static func totalsMatch(_ authoritative: String?, legacy: String) -> Bool {
        guard let authoritative else { return true }
        let locale = Locale(identifier: "en_US_POSIX")
        guard let total = Decimal(string: authoritative, locale: locale),
              let fallback = Decimal(string: legacy, locale: locale)
        else { return false }
        return total == fallback
    }
}

struct CapabilitiesDTO: Decodable {
    let apiVersion: String?
    let currency: CurrencyDTO
    let features: [String: Bool?]?
    let authentication: [String: Bool?]?
    var protocols: CapabilityProtocolsDTO? = nil
    /// Omitted on the public/anonymous response and present for an authenticated session.
    var communicationAccess: SessionCommunicationAccessDTO? = nil
    var financialAccess: SessionFinancialAccessDTO? = nil

    enum CodingKeys: String, CodingKey {
        case apiVersion = "api_version"
        case currency, features, authentication, protocols
        case communicationAccess = "communication_access"
        case financialAccess = "financial_access"
    }

    /// Authentication and account-access capabilities fail closed when the server omits a key,
    /// returns null, or has not supplied capabilities yet.
    var supportsPhoneOTP: Bool { authentication?["phone_otp"] == true }
    var supportsEmailPassword: Bool { authentication?["email_password"] == true }
    var supportsMFA: Bool { authentication?["mfa"] == true }
    // `email_registration` is deliberately unread. Registration happens through a phone number
    // alone — the backend decides whether a number is new or returning — so a stale server
    // capability advertising email registration must not be able to resurrect the retired form.
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

/// The email-path screens. There is deliberately no registration case: a phone number is the
/// only way to create a Kit Pay account, so the type itself cannot express a registration form.
enum EmailAccountScreen: Equatable {
    case signIn
    case verification
    case forgotPassword
    case resetPassword
}

/// Capability policy for email-account navigation. Verification and reset are completion routes:
/// once a user has received a token, a later rollout change must not strand that flow.
struct EmailAccountNavigationPolicy: Equatable {
    let emailPasswordEnabled: Bool
    let recoveryEnabled: Bool

    init(
        emailPasswordEnabled: Bool,
        recoveryEnabled: Bool
    ) {
        self.emailPasswordEnabled = emailPasswordEnabled
        self.recoveryEnabled = recoveryEnabled
    }

    init(capabilities: CapabilitiesDTO?) {
        self.init(
            emailPasswordEnabled: capabilities?.supportsEmailPassword == true,
            recoveryEnabled: capabilities?.supportsEmailRecovery == true
        )
    }

    func allows(_ screen: EmailAccountScreen) -> Bool {
        switch screen {
        case .signIn:
            emailPasswordEnabled
        case .verification:
            true
        case .forgotPassword:
            recoveryEnabled
        case .resetPassword:
            true
        }
    }
}

/// What the phone-first sign-in surface offers, derived from server capabilities alone.
///
/// Phone is the sole registration route: the customer enters a number and the backend decides
/// whether it is a first-time registration or a returning login. Email exists only as a
/// restrained secondary sign-in for accounts that already attached one, so this policy can
/// never produce a registration affordance — the retired `email_registration` capability is
/// not even an input.
struct PhoneFirstAuthAccessPolicy: Equatable {
    enum PrimaryRoute: Equatable {
        case phone
        case email
        case unavailable
    }

    let primaryRoute: PrimaryRoute
    /// "Sign in with email instead" from the phone screen; offered only when both exist.
    let offersEmailSecondary: Bool

    init(phoneOTPEnabled: Bool, emailPasswordEnabled: Bool) {
        primaryRoute = phoneOTPEnabled ? .phone : (emailPasswordEnabled ? .email : .unavailable)
        offersEmailSecondary = phoneOTPEnabled && emailPasswordEnabled
    }

    init(capabilities: CapabilitiesDTO?) {
        self.init(
            phoneOTPEnabled: capabilities?.supportsPhoneOTP == true,
            emailPasswordEnabled: capabilities?.supportsEmailPassword == true
        )
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

    /// Multi-attachment media messages (KITMEDIA2) ride the same attachment service but are a
    /// separately attested profile. §6 advertises the readiness twice — the features key and the
    /// `protocols.messaging.media_message` block — and both must agree; false, missing, null, or
    /// a malformed/incoherent block all fail closed. This only ever answers for the server leg:
    /// every destination device must additionally attest the capability at flush time.
    var enablesMessagingMediaMessageV2: Bool {
        supportsFeature(MessagingMediaMessageV2CapabilityPolicy.featureKey)
            && protocols?.messaging?.mediaMessage?.supportsIOSV2 == true
    }
}

struct CapabilityProtocolsDTO: Decodable {
    let messaging: MessagingProtocolCapabilityDTO?
    /// Additive payment protocols. A malformed advertisement disables only the affected payment
    /// surface; it must never invalidate authentication or ordinary wallet capabilities.
    var payments: PaymentProtocolsCapabilityDTO? = nil
    /// Realtime is an additive transport hint. A malformed advertisement must disable only the
    /// socket path rather than making the entire capabilities response unusable.
    var realtime: RealtimeProtocolCapabilityDTO? = nil
    /// Typed support contract advertisement. Lenient at this layer for the same reason as
    /// `realtime` (a malformed block must not make the whole capabilities response unusable);
    /// `SupportProtocolDTO` itself decodes strictly, so any missing, malformed, unknown, or
    /// extra value yields `nil` here and `SupportGate` fails closed on it.
    var support: SupportProtocolDTO? = nil

    private enum CodingKeys: String, CodingKey {
        case messaging, payments, realtime, support
    }

    init(
        messaging: MessagingProtocolCapabilityDTO?,
        payments: PaymentProtocolsCapabilityDTO? = nil,
        realtime: RealtimeProtocolCapabilityDTO? = nil,
        support: SupportProtocolDTO? = nil
    ) {
        self.messaging = messaging
        self.payments = payments
        self.realtime = realtime
        self.support = support
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        messaging = try values.decodeIfPresent(
            MessagingProtocolCapabilityDTO.self,
            forKey: .messaging
        )
        payments = try? values.decodeIfPresent(
            PaymentProtocolsCapabilityDTO.self,
            forKey: .payments
        )
        realtime = try? values.decodeIfPresent(
            RealtimeProtocolCapabilityDTO.self,
            forKey: .realtime
        )
        support = try? values.decodeIfPresent(
            SupportProtocolDTO.self,
            forKey: .support
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
    let calls: Bool?

    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case scheme, host, port, path, key, channels, presence, typing, calls
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
    /// Whether `kit.call.answered` will arrive on the user channel. Absent from an older
    /// advertisement means false: the frame is ignored and the `call.answered` push keeps
    /// carrying the answer, rather than the whole socket failing over a missing member.
    let callAnswerEnabled: Bool

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
        callAnswerEnabled = capability.calls == true
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
            String(callAnswerEnabled),
        ].joined(separator: "|")
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

    enum CodingKeys: String, CodingKey {
        case ready, version, suite
        case postQuantum = "post_quantum"
        case richMedia = "rich_media"
        case mediaMessage = "media_message"
        case resumableAttachments = "resumable_attachments"
    }

    init(
        ready: Bool?,
        version: String?,
        suite: String?,
        postQuantum: Bool?,
        richMedia: MessagingRichMediaProtocolCapabilityDTO? = nil,
        mediaMessage: MessagingMediaMessageProtocolCapabilityDTO? = nil,
        resumableAttachments: MessagingResumableAttachmentsCapabilityDTO? = nil
    ) {
        self.ready = ready
        self.version = version
        self.suite = suite
        self.postQuantum = postQuantum
        self.richMedia = richMedia
        self.mediaMessage = mediaMessage
        self.resumableAttachments = resumableAttachments
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
    }

    var supportsReviewedV2: Bool {
        ready == true
            && version == SecureMessagingWire.protocolVersion
            && suite == SecureMessagingWire.protocolSuite
            && postQuantum == true
    }
}

/// Fail-closed advertisement for the ciphertext-offset upload protocol. The fixed chunk ceiling
/// is part of the reviewed wire contract, not a server tuning hint: accepting a larger value
/// could defeat the client's bounded-memory guarantee.
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

    /// Canonicalizes live code entry: any single numeral a localized keyboard, SMS autofill, or
    /// paste can produce — Arabic-Indic, Devanagari, full-width, and friends — becomes its ASCII
    /// digit, everything else is dropped, and the result caps at six digits. Submission stays
    /// strictly ASCII above; without this mapping, six digits typed on a non-Latin keyboard fill
    /// the field yet never validate, leaving the verify button disabled with no visible reason.
    static func sanitizedSixDigitEntry(_ value: String) -> String {
        var digits = ""
        for character in value {
            guard let digit = character.wholeNumberValue, (0 ... 9).contains(digit) else {
                continue
            }
            digits.append(Character("\(digit)"))
            if digits.count == 6 { break }
        }
        return digits
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

enum AuthenticationSecretLifecyclePolicy {
    static func shouldClear(afterSuccessfulRequest succeeded: Bool) -> Bool { succeeded }

    static func shouldConceal(sceneIsActive: Bool) -> Bool { !sceneIsActive }
}

struct EmailVerificationResult: Decodable {
    let verified: Bool?
    let user: UserProfile
}

enum EmailAccountResponsePolicy {
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

/// The backend's scoped admission decision for authenticated, non-financial product areas.
///
/// The wire values remain strings so a future server value does not make the surrounding login
/// or bootstrap response undecodable. The policy below accepts only the exact reviewed values;
/// anything new therefore fails closed until this client understands it.
struct SessionCommunicationAccessDTO: Codable, Hashable, Sendable {
    let allowed: Bool
    let basis: String
    let requiredAction: String?

    enum CodingKeys: String, CodingKey {
        case allowed, basis
        case requiredAction = "required_action"
    }

    init(allowed: Bool, basis: String, requiredAction: String?) {
        self.allowed = allowed
        self.basis = basis
        self.requiredAction = requiredAction
    }
}

/// The backend's independent wallet/payment decision. `readOnly` is deliberately required when
/// the object is present: silently defaulting a malformed authenticated projection to writable
/// would turn a server contract error into money-moving authority.
struct SessionFinancialAccessDTO: Codable, Hashable, Sendable {
    let allowed: Bool
    let basis: String
    let requiredAction: String?
    let readOnly: Bool

    enum CodingKeys: String, CodingKey {
        case allowed, basis
        case requiredAction = "required_action"
        case readOnly = "read_only"
    }

    init(allowed: Bool, basis: String, requiredAction: String?, readOnly: Bool) {
        self.allowed = allowed
        self.basis = basis
        self.requiredAction = requiredAction
        self.readOnly = readOnly
    }
}

struct SessionAssuranceDTO: Codable, Hashable, Sendable {
    let deviceIdentity: DeviceIdentityAssuranceDTO
    let loginUnlock: LoginUnlockAssuranceDTO
    let access: String
    /// Scoped decisions are optional only for encrypted state and servers from before this
    /// contract. When either appears, both must appear before policy grants anything.
    let communicationAccess: SessionCommunicationAccessDTO?
    let financialAccess: SessionFinancialAccessDTO?

    enum CodingKeys: String, CodingKey {
        case deviceIdentity = "device_identity"
        case loginUnlock = "login_unlock"
        case access
        case communicationAccess = "communication_access"
        case financialAccess = "financial_access"
    }

    init(
        deviceIdentity: DeviceIdentityAssuranceDTO,
        loginUnlock: LoginUnlockAssuranceDTO,
        access: String,
        communicationAccess: SessionCommunicationAccessDTO? = nil,
        financialAccess: SessionFinancialAccessDTO? = nil
    ) {
        self.deviceIdentity = deviceIdentity
        self.loginUnlock = loginUnlock
        self.access = access
        self.communicationAccess = communicationAccess
        self.financialAccess = financialAccess
    }

    var grantsFullAccess: Bool {
        access.caseInsensitiveCompare("full") == .orderedSame
            && deviceIdentity.isVerified
            && loginUnlock.isUnlocked
    }

    func communicationRequirement(accountKYCStatus: String?) -> CommunicationAccessRequirement {
        SessionCommunicationAccessPolicy.requirement(
            scopedCommunication: communicationAccess,
            scopedFinancial: financialAccess,
            legacyAccountKYCStatus: accountKYCStatus,
            sessionGrantsFullAccess: grantsFullAccess,
            deviceIdentityVerified: deviceIdentity.isVerified
        )
    }

    func grantsCommunicationAccess(accountKYCStatus: String?) -> Bool {
        communicationRequirement(accountKYCStatus: accountKYCStatus) == .allowed
    }

    /// Bootstrap and authenticated capabilities repeat the scoped objects at their top level.
    /// A present top-level pair is newer authority and replaces the nested pair atomically. A
    /// partial pair is deliberately preserved as partial so policy fails closed instead of
    /// borrowing one half from a stale response.
    func applyingTopLevelAccess(
        communication: SessionCommunicationAccessDTO?,
        financial: SessionFinancialAccessDTO?
    ) -> SessionAssuranceDTO {
        guard communication != nil || financial != nil else { return self }
        return SessionAssuranceDTO(
            deviceIdentity: deviceIdentity,
            loginUnlock: loginUnlock,
            access: access,
            communicationAccess: communication,
            financialAccess: financial
        )
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

/// A server-owned public verification designation.
///
/// This is intentionally separate from KYC. Passing an identity check may unlock regulated
/// features, but it never grants a public badge by itself. Only one of these exact values, sent by
/// the authenticated API, may put a blue verification seal on screen.
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

/// Verification metadata embedded in profile and contact projections.
///
/// Unknown, padded, or differently-cased designations decode without breaking the surrounding
/// profile, but remain unrecognised and therefore cannot earn a badge. This fail-closed behaviour
/// also keeps a future server designation safe on older clients.
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

/// A small, authenticated identity projection carried beside messaging and calling rosters.
///
/// Contacts remain a useful fallback, but they are not guaranteed to contain a person the first
/// time they message or call. Persisting only these public fields lets that first interaction draw
/// the same avatar and verification seal without coupling a public badge to KYC or phone-book
/// access. Every field stays optional so payloads from servers predating this projection continue
/// to decode.
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
        ProfileAvatarCache.validatedURL(rawValue)?.absoluteString
    }

    var isValid: Bool {
        displayName == Self.validatedDisplayName(displayName)
            && avatarURL == Self.validatedAvatarURL(avatarURL)
            && (verification.map({ $0.designation != nil }) ?? true)
            && (displayName != nil || avatarURL != nil || verification != nil)
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
    /// Public verification is server-assigned and distinct from identity/KYC completion.
    var verification: AccountVerificationDTO? = nil

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
        case verification
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
        // Profile mutation endpoints can return a focused projection. Do not make a server-owned
        // public designation disappear merely because an unrelated name/photo response omitted it.
        merged.verification = response.verification ?? current.verification
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
    let communicationAccess: SessionCommunicationAccessDTO?
    let financialAccess: SessionFinancialAccessDTO?

    enum CodingKeys: String, CodingKey {
        case user, wallets, devices
        case selectedWalletId = "selected_wallet_id"
        case sessionAssurance = "session_assurance"
        case communicationAccess = "communication_access"
        case financialAccess = "financial_access"
    }

    var resolvedSessionAssurance: SessionAssuranceDTO? {
        sessionAssurance?.applyingTopLevelAccess(
            communication: communicationAccess,
            financial: financialAccess
        )
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

/// The complete customer-visible effect of one transaction on the selected wallet.
///
/// A single customer action may have several immutable accounting legs on the server. Those
/// remain private to Kit's ledger; the client receives only the combined money added/deducted.
struct CustomerTransactionTotals: Codable, Hashable {
    let added: String
    let deducted: String
}

/// Combined movement in the currently displayed wallet-history page.
///
/// These are minor units so aggregation and rendering never pass through binary floating point.
/// They deliberately describe the customer's wallet only; Kit's institutional ledger remains a
/// separate, server-side accounting concern.
struct CustomerTransactionActivitySummary: Equatable {
    let addedMinorUnits: Int64
    let deductedMinorUnits: Int64

    static let zero = CustomerTransactionActivitySummary(
        addedMinorUnits: 0,
        deductedMinorUnits: 0
    )
}

struct WalletTransaction: Codable, Hashable, Identifiable {
    let id: String
    let walletId: String
    let reference: String
    let amount: String
    var totals: CustomerTransactionTotals? = nil
    let currency: CurrencyDTO
    let type: String
    let direction: String
    let status: String
    var counterparty: Counterparty?
    let note: String?
    /// Present when a Kit Pay → Kit Pay transfer is held for recipient acceptance.
    var claim: TransferAcceptanceDTO? = nil
    let occurredAt: String

    enum CodingKeys: String, CodingKey {
        case id, reference, amount, totals, currency, type, direction, status, counterparty, note, claim
        case walletId = "wallet_id"
        case occurredAt = "occurred_at"
    }
}

extension WalletTransaction {
    /// The counterparty identity that is safe to show in customer-facing history and receipts.
    ///
    /// Service-backed movements can carry a historical settlement/service wallet in an older
    /// protected cache. That identity is never the customer's actual counterparty, so only
    /// transaction families whose counterparty is inherently another customer or merchant may
    /// surface it.
    var customerCounterparty: Counterparty? {
        CustomerTransactionPresentationPolicy.customerCounterparty(for: self)
    }

    var customerAmountAdded: String {
        totals?.added ?? "0"
    }

    var customerAmountDeducted: String {
        totals?.deducted ?? "0"
    }

    var customerImpactLabel: String {
        customerDirection == "credit" ? "Money Added" : "Money Deducted"
    }

    var customerImpactAmount: String {
        customerDirection == "credit" ? customerAmountAdded : customerAmountDeducted
    }

    var customerDirection: String {
        direction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// The fail-closed boundary between Kit's ledger taxonomy and customer-visible activity.
///
/// The server remains authoritative for grouping accounting legs into one customer movement, but
/// an old protected cache or a temporarily incompatible response must not make an institutional
/// or newly introduced ledger type visible. Adding a new customer transaction therefore requires
/// an explicit client contract update instead of becoming visible by accident.
enum CustomerTransactionPresentationPolicy {
    /// Exact public types emitted by the backend customer-history projection. Legacy aliases and
    /// internal fee, commission, settlement, rounding, and float types are deliberately absent.
    static let supportedTypes: Set<String> = [
        "airtime",
        "bank_deposit",
        "bank_reversal",
        "bank_transfer",
        "bank_withdrawal",
        "bill_payment",
        "internal_transfer",
        "internal_transfer_reversal",
        "merchant_escrow_release",
        "merchant_payment",
        "merchant_refund",
        "provider_reversal",
        "referral_reward",
        "referral_reward_reversal",
    ]

    /// These transaction families have an actual customer/merchant on the opposite side. All
    /// other supported types are service-backed, so a cached counterparty can only be stale
    /// institutional metadata and must fail closed at presentation time.
    static let customerCounterpartyTypes: Set<String> = [
        "internal_transfer",
        "internal_transfer_reversal",
        "merchant_escrow_release",
        "merchant_payment",
        "merchant_refund",
    ]

    static func isCustomerVisible(_ transaction: WalletTransaction) -> Bool {
        supportedTypes.contains(normalizedType(transaction.type))
            && hasValidCustomerImpact(transaction)
    }

    static func customerVisibleTransactions(
        _ transactions: [WalletTransaction]
    ) -> [WalletTransaction] {
        transactions.compactMap { transaction in
            guard isCustomerVisible(transaction) else { return nil }
            var presented = transaction
            presented.counterparty = customerCounterparty(for: transaction)
            return presented
        }
    }

    /// Returns only rows that belong to the selected wallet and its currency. This prevents a
    /// cached page from the previously selected wallet appearing during an asynchronous refresh.
    static func customerVisibleTransactions(
        _ transactions: [WalletTransaction],
        for wallet: Wallet
    ) -> [WalletTransaction] {
        guard let walletScale = validScale(wallet.currency),
              !normalizedCurrencyCode(wallet.currency.code).isEmpty
        else { return [] }

        return customerVisibleTransactions(transactions).filter { transaction in
            transaction.walletId.caseInsensitiveCompare(wallet.id) == .orderedSame
                && normalizedCurrencyCode(transaction.currency.code)
                    == normalizedCurrencyCode(wallet.currency.code)
                && validScale(transaction.currency) == walletScale
        }
    }

    /// Sums the server-provided combined customer totals for the selected wallet page. Each row
    /// is independently validated and converted through `Decimal`; malformed or over-precision
    /// values fail closed. Addition saturates so an unexpectedly large valid page cannot wrap.
    static func activitySummary(
        _ transactions: [WalletTransaction],
        for wallet: Wallet
    ) -> CustomerTransactionActivitySummary {
        guard let scale = validScale(wallet.currency) else { return .zero }

        return customerVisibleTransactions(transactions, for: wallet).reduce(into: .zero) {
            summary, transaction in
            guard let totals = transaction.totals else { return }

            switch transaction.customerDirection {
            case "credit":
                guard let amount = minorUnits(for: totals.added, scale: scale) else { return }
                summary = CustomerTransactionActivitySummary(
                    addedMinorUnits: saturatingAdd(summary.addedMinorUnits, amount),
                    deductedMinorUnits: summary.deductedMinorUnits
                )
            case "debit":
                guard let amount = minorUnits(for: totals.deducted, scale: scale) else { return }
                summary = CustomerTransactionActivitySummary(
                    addedMinorUnits: summary.addedMinorUnits,
                    deductedMinorUnits: saturatingAdd(summary.deductedMinorUnits, amount)
                )
            default:
                return
            }
        }
    }

    static func customerCounterparty(for transaction: WalletTransaction) -> Counterparty? {
        guard customerCounterpartyTypes.contains(normalizedType(transaction.type)) else {
            return nil
        }
        return transaction.counterparty
    }

    @discardableResult
    static func hardenCustomerTransactions(
        from transactions: inout [WalletTransaction]
    ) -> Int {
        let visibleTransactions = transactions.filter(isCustomerVisible)
        let removedCount = transactions.count - visibleTransactions.count
        let redactedCounterpartyCount = visibleTransactions.reduce(into: 0) { count, transaction in
            if transaction.counterparty != nil,
               customerCounterparty(for: transaction) == nil {
                count += 1
            }
        }
        transactions = customerVisibleTransactions(transactions)
        return removedCount + redactedCounterpartyCount
    }

    private static func normalizedType(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizedCurrencyCode(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private static func validScale(_ currency: CurrencyDTO) -> Int? {
        guard let scale = Int(currency.scale), (0 ... 9).contains(scale) else { return nil }
        return scale
    }

    /// Reject malformed aggregate rows before they can reach any customer-facing projection.
    /// Authoritative responses carry both sides explicitly; exactly one side must be positive and
    /// it must agree with the transaction direction. Principal-only legacy rows fail closed because
    /// they cannot prove that fees or companion accounting legs have been included.
    private static func hasValidCustomerImpact(_ transaction: WalletTransaction) -> Bool {
        let direction = transaction.direction
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard direction == "credit" || direction == "debit" else { return false }

        guard let totals = transaction.totals,
              let publicAmount = canonicalNonnegativeAmount(transaction.amount),
              publicAmount > 0,
              let added = canonicalNonnegativeAmount(totals.added),
              let deducted = canonicalNonnegativeAmount(totals.deducted),
              let scale = validScale(transaction.currency),
              minorUnits(for: transaction.amount, scale: scale) != nil,
              minorUnits(for: totals.added, scale: scale) != nil,
              minorUnits(for: totals.deducted, scale: scale) != nil
        else { return false }

        switch direction {
        case "credit":
            return added == publicAmount && deducted == 0
        case "debit":
            return deducted == publicAmount && added == 0
        default:
            return false
        }
    }

    private static func canonicalNonnegativeAmount(_ raw: String) -> Decimal? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !value.isEmpty,
              components.count <= 2,
              components.allSatisfy({ component in
                  !component.isEmpty
                      && component.allSatisfy { character in
                          character.isASCII && character.isNumber
                      }
              }),
              let amount = Decimal(
                  string: value,
                  locale: Locale(identifier: "en_US_POSIX")
              ),
              amount >= 0
        else { return nil }
        return amount
    }

    /// Converts a canonical nonnegative decimal into minor units without rounding or `Double`.
    private static func minorUnits(for raw: String, scale: Int) -> Int64? {
        guard (0 ... 9).contains(scale),
              let amount = canonicalNonnegativeAmount(raw)
        else { return nil }

        var multiplier = Decimal(1)
        if scale > 0 {
            for _ in 0 ..< scale { multiplier *= 10 }
        }
        let scaled = amount * multiplier
        var source = scaled
        var integral = Decimal()
        NSDecimalRound(&integral, &source, 0, .plain)
        guard integral == scaled,
              integral <= Decimal(Int64.max)
        else { return nil }
        return NSDecimalNumber(decimal: integral).int64Value
    }

    private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        guard lhs <= Int64.max - rhs else { return Int64.max }
        return lhs + rhs
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
    var verification: AccountVerificationDTO? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, phone, favorite, status, tag
        case contactId = "contact_id"
        case isKitUser = "is_kit_user"
        case avatarURL = "avatar_url"
        case receivingWalletId = "receiving_wallet_id"
        case verification
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

// MARK: - Home starter checklist

/// How each starter step's destination is presented. Identity verification is a substantive
/// flow and must open as a true full screen — the half-height sheet pattern was explicitly
/// rejected for flows like it.
enum HomeStarterStepRoutePolicy {
    enum Presentation: Equatable {
        case fullScreen
        case tabSwitch
        case walletSheet
        /// The destination cannot work right now. Explain the real next step instead of
        /// dropping the customer into a disabled surface.
        case unavailable(message: String)
    }

    static let messagingUnavailableMessage =
        "Secure messaging is still being set up for this device. Connect to the internet, then try again from the Messages tab."

    static func presentation(
        for step: HomeStarterStep,
        secureMessagingAvailable: Bool
    ) -> Presentation {
        switch step {
        case .verifyIdentity: .fullScreen
        case .sendFirstMessage:
            // Switching tabs into a composer that cannot compose would read as broken and
            // could never complete the step; say what is actually missing instead.
            secureMessagingAvailable
                ? .tabSwitch
                : .unavailable(message: messagingUnavailableMessage)
        case .makeFirstTransaction: .walletSheet
        }
    }
}

/// The three first-run steps Home shows above Recent activity, each proven by real state.
/// The declaration order is the display order the checklist promises.
enum HomeStarterStep: String, CaseIterable, Hashable {
    case verifyIdentity
    case sendFirstMessage
    case makeFirstTransaction
}

/// The sole client-side KYC admission rule for wallet and payment surfaces.
///
/// Public blue verification is deliberately absent here: it is a separate, rare designation
/// assigned by the server and never grants financial access. The live account-wide KYC value
/// wins over the cached profile; the blended per-device `KYCStatus.status` must not be used.
enum MoneyIdentityAccessPolicy {
    static let approvedStatuses: Set<String> = ["verified", "approved"]
    /// Known account states that have not yet unlocked money. Unknown/missing values are excluded
    /// so they can never turn a generic restricted session into authenticated communication.
    static let explicitlyUnverifiedStatuses: Set<String> = [
        "unverified", "not_started", "pending", "in_review", "review", "reviewing", "submitted",
        "processing", "rejected", "declined", "failed",
    ]

    static func isVerified(
        liveAccountStatus: String?,
        cachedProfileStatus: String?
    ) -> Bool {
        normalizedStatus(liveAccountStatus ?? cachedProfileStatus)
            .map(approvedStatuses.contains) == true
    }

    static func isExplicitlyUnverified(
        liveAccountStatus: String?,
        cachedProfileStatus: String?
    ) -> Bool {
        normalizedStatus(liveAccountStatus ?? cachedProfileStatus)
            .map(explicitlyUnverifiedStatuses.contains) == true
    }

    private static func normalizedStatus(_ status: String?) -> String? {
        guard let status else { return nil }
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}

enum CommunicationAccessRequirement: Equatable {
    case allowed
    case verifyDeviceIdentity
    case unlockSession
    case unavailable
}

enum SessionScopedAccessPolicy {
    static let accountOnboarding = "account_onboarding"
    static let fullAssurance = "full_assurance"
    static let appReview = "app_review"
    static let identityVerificationRequired = "identity_verification_required"
    static let verifyDeviceIdentity = "verify_device_identity"
    static let unlockSession = "unlock_session"

    /// The two objects describe one admission state and must move together. This prevents a
    /// partial, stale, or internally contradictory projection from granting either surface.
    static func isCoherent(
        communication: SessionCommunicationAccessDTO,
        financial: SessionFinancialAccessDTO
    ) -> Bool {
        guard communication.basis == communication.basis.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ),
              financial.basis == financial.basis.trimmingCharacters(in: .whitespacesAndNewlines),
              communication.requiredAction == communication.requiredAction?.trimmingCharacters(
                in: .whitespacesAndNewlines
              ),
              financial.requiredAction == financial.requiredAction?.trimmingCharacters(
                in: .whitespacesAndNewlines
              ),
              communication.basis == financial.basis
        else { return false }

        switch communication.basis {
        case Self.accountOnboarding:
            return communication.allowed
                && communication.requiredAction == nil
                && !financial.allowed
                && !financial.readOnly
                && financial.requiredAction == identityVerificationRequired
        case Self.fullAssurance:
            if communication.allowed || financial.allowed {
                return communication.allowed
                    && financial.allowed
                    && !financial.readOnly
                    && communication.requiredAction == nil
                    && financial.requiredAction == nil
            }
            guard let requiredAction = communication.requiredAction else { return false }
            return !financial.readOnly
                && [verifyDeviceIdentity, unlockSession].contains(requiredAction)
                && communication.requiredAction == financial.requiredAction
        case Self.appReview:
            if communication.allowed || financial.allowed {
                return communication.allowed
                    && financial.allowed
                    && financial.readOnly
                    && communication.requiredAction == nil
                    && financial.requiredAction == nil
            }
            guard let requiredAction = communication.requiredAction else { return false }
            return financial.readOnly
                && [verifyDeviceIdentity, unlockSession].contains(requiredAction)
                && communication.requiredAction == financial.requiredAction
        default:
            return false
        }
    }
}

/// Validates the scoped communication projection as a coherent server decision. The legacy
/// fallback exists only for saved state and servers predating the scoped contract; once either
/// scoped object appears, a missing peer object or unknown value fails closed.
enum SessionCommunicationAccessPolicy {
    static func requirement(
        scopedCommunication: SessionCommunicationAccessDTO?,
        scopedFinancial: SessionFinancialAccessDTO?,
        legacyAccountKYCStatus: String?,
        sessionGrantsFullAccess: Bool,
        deviceIdentityVerified: Bool
    ) -> CommunicationAccessRequirement {
        if scopedCommunication != nil || scopedFinancial != nil {
            guard let scopedCommunication,
                  let scopedFinancial,
                  SessionScopedAccessPolicy.isCoherent(
                    communication: scopedCommunication,
                    financial: scopedFinancial
                  )
            else { return .unavailable }
            return scopedRequirement(
                scopedCommunication,
                sessionGrantsFullAccess: sessionGrantsFullAccess
            )
        }

        // Compatibility for a last confirmed encrypted projection from before this contract.
        if sessionGrantsFullAccess { return .allowed }
        if MoneyIdentityAccessPolicy.isExplicitlyUnverified(
            liveAccountStatus: legacyAccountKYCStatus,
            cachedProfileStatus: nil
        ) {
            return .allowed
        }
        return deviceIdentityVerified ? .unlockSession : .verifyDeviceIdentity
    }

    private static func scopedRequirement(
        _ access: SessionCommunicationAccessDTO,
        sessionGrantsFullAccess: Bool
    ) -> CommunicationAccessRequirement {
        guard access.basis == access.basis.trimmingCharacters(in: .whitespacesAndNewlines),
              access.requiredAction == access.requiredAction?.trimmingCharacters(
                in: .whitespacesAndNewlines
              )
        else { return .unavailable }

        if access.allowed {
            guard access.requiredAction == nil else { return .unavailable }
            switch access.basis {
            case SessionScopedAccessPolicy.accountOnboarding:
                return .allowed
            case SessionScopedAccessPolicy.fullAssurance, SessionScopedAccessPolicy.appReview:
                return sessionGrantsFullAccess ? .allowed : .unavailable
            default:
                return .unavailable
            }
        }

        guard [SessionScopedAccessPolicy.fullAssurance, SessionScopedAccessPolicy.appReview]
            .contains(access.basis)
        else { return .unavailable }
        switch access.requiredAction {
        case SessionScopedAccessPolicy.verifyDeviceIdentity: return .verifyDeviceIdentity
        case SessionScopedAccessPolicy.unlockSession: return .unlockSession
        default: return .unavailable
        }
    }
}

enum MoneyActionAccessRequirement: Equatable {
    case allowed
    case readOnly
    case verifyIdentity
    case verifyDeviceIdentity
    case unlockSession
    case unavailable
}

enum FinancialEntryKind: Equatable {
    case readOnlySurface
    case moneyMovement
}

/// Testable navigation decision shared by Home, chat and support payment entry points. Keeping
/// visibility separate from mutation authority lets pre-KYC users see the complete product and
/// routes their tap to KYC, while App Review can inspect financial screens without moving money.
enum FinancialEntryRoute: Equatable {
    case open
    case verifyIdentity
    case verifyDeviceIdentity
    case unlockSession
    case readOnly
    case unavailable
}

enum FinancialEntryRoutePolicy {
    static func route(
        requirement: MoneyActionAccessRequirement,
        kind: FinancialEntryKind
    ) -> FinancialEntryRoute {
        switch (requirement, kind) {
        case (.allowed, _), (.readOnly, .readOnlySurface):
            return .open
        case (.readOnly, .moneyMovement):
            return .readOnly
        case (.verifyIdentity, _):
            return .verifyIdentity
        case (.verifyDeviceIdentity, _):
            return .verifyDeviceIdentity
        case (.unlockSession, _):
            return .unlockSession
        case (.unavailable, _):
            return .unavailable
        }
    }
}

/// One decision shared by every wallet/payment entry point. Identity is checked first so a
/// pre-KYC communication session is routed to the KYC flow; an already verified account with a
/// stepped-down device/session must restore its stronger assurance instead.
enum MoneyActionAccessPolicy {
    static func requirement(
        identityVerified: Bool,
        sessionGrantsFullAccess: Bool,
        scopedCommunication: SessionCommunicationAccessDTO? = nil,
        scopedFinancial: SessionFinancialAccessDTO? = nil
    ) -> MoneyActionAccessRequirement {
        if scopedCommunication != nil || scopedFinancial != nil {
            guard let scopedCommunication,
                  let scopedFinancial,
                  SessionScopedAccessPolicy.isCoherent(
                    communication: scopedCommunication,
                    financial: scopedFinancial
                  )
            else { return .unavailable }
            return scopedRequirement(
                scopedFinancial,
                sessionGrantsFullAccess: sessionGrantsFullAccess
            )
        }

        // Compatibility for a last confirmed encrypted projection from before this contract.
        guard identityVerified else { return .verifyIdentity }
        guard sessionGrantsFullAccess else { return .unlockSession }
        return .allowed
    }

    static func permitsFinancialData(
        identityVerified: Bool,
        sessionGrantsFullAccess: Bool,
        scopedCommunication: SessionCommunicationAccessDTO?,
        scopedFinancial: SessionFinancialAccessDTO?
    ) -> Bool {
        switch requirement(
            identityVerified: identityVerified,
            sessionGrantsFullAccess: sessionGrantsFullAccess,
            scopedCommunication: scopedCommunication,
            scopedFinancial: scopedFinancial
        ) {
        case .allowed, .readOnly:
            return true
        case .verifyIdentity, .verifyDeviceIdentity, .unlockSession, .unavailable:
            return false
        }
    }

    private static func scopedRequirement(
        _ access: SessionFinancialAccessDTO,
        sessionGrantsFullAccess: Bool
    ) -> MoneyActionAccessRequirement {
        guard access.basis == access.basis.trimmingCharacters(in: .whitespacesAndNewlines),
              access.requiredAction == access.requiredAction?.trimmingCharacters(
                in: .whitespacesAndNewlines
              )
        else { return .unavailable }

        if access.allowed {
            guard sessionGrantsFullAccess, access.requiredAction == nil else {
                return .unavailable
            }
            switch (access.basis, access.readOnly) {
            case (SessionScopedAccessPolicy.fullAssurance, false): return .allowed
            case (SessionScopedAccessPolicy.appReview, true): return .readOnly
            default: return .unavailable
            }
        }

        if access.basis == SessionScopedAccessPolicy.accountOnboarding,
           access.requiredAction == SessionScopedAccessPolicy.identityVerificationRequired,
           !access.readOnly {
            return .verifyIdentity
        }
        if access.requiredAction == SessionScopedAccessPolicy.verifyDeviceIdentity,
           ((access.basis == SessionScopedAccessPolicy.fullAssurance && !access.readOnly)
               || (access.basis == SessionScopedAccessPolicy.appReview && access.readOnly)) {
            return .verifyDeviceIdentity
        }
        if access.requiredAction == SessionScopedAccessPolicy.unlockSession,
           ((access.basis == SessionScopedAccessPolicy.fullAssurance && !access.readOnly)
               || (access.basis == SessionScopedAccessPolicy.appReview && access.readOnly)) {
            return .unlockSession
        }
        return .unavailable
    }
}

struct HomeStarterChecklist: Equatable {
    struct Entry: Equatable {
        let step: HomeStarterStep
        let isComplete: Bool
    }

    let entries: [Entry]

    var completedCount: Int { entries.filter(\.isComplete).count }
    var totalCount: Int { entries.count }
}

/// Decides each starter step from authoritative state alone — never a manual or demo toggle.
///
/// Everything fails closed: missing or not-yet-loaded state reads as "not done", an unknown
/// transaction status reads as "not settled", and App Review demo content can complete nothing
/// because the checklist is withheld for the demo account entirely. The checklist disappears
/// once all three steps are genuinely complete.
enum HomeStarterChecklistPolicy {
    /// Wallet statuses that mean money actually moved and stayed moved. An allowlist on
    /// purpose: pending, failed, reversed, and anything unrecognized all fail closed.
    static let settledTransactionStatuses: Set<String> = [
        "completed", "settled", "success", "succeeded",
    ]

    static func identityVerified(kycStatus: String?) -> Bool {
        MoneyIdentityAccessPolicy.isVerified(
            liveAccountStatus: kycStatus,
            cachedProfileStatus: nil
        )
    }

    /// A genuine outbound user message: authored by this account, actually sent — not failed
    /// and not still waiting in the outbox — and not a payment, system, or reaction event
    /// riding the message wire. Demo conversations never count.
    static func hasSentFirstMessage(
        messages: [LocalMessage],
        isDemoConversation: (String) -> Bool = { _ in false }
    ) -> Bool {
        messages.contains { message in
            message.isOutgoing
                && [.sent, .delivered, .read].contains(message.state)
                && !message.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                // A first photo (valid `KITMEDIA1`) or a first media batch (valid `KITMEDIA2`)
                // is a first message, so the strict parses count explicitly — the shared
                // reserved-namespace policy now refuses the whole KITMEDIA family as authored
                // text. Everything else counts only as allowed ordinary text: a malformed or
                // unknown-version family body is nobody's first message.
                && (KitMediaMessageDescriptor.parse(message.body) != nil
                    || KitMediaMessageV2Descriptor.parse(message.body) != nil
                    || SecureMessageReservedPrefixPolicy.allowsUserAuthoredText(message.body))
                && !isDemoConversation(message.conversationId)
        }
    }

    /// Types that are not money movement however they are spelled: a request is an ask, and a
    /// reversal or refund is money moving *back*, which must not read as a first transaction.
    static let nonMovementTransactionTypes: Set<String> = ["payment_request", "request"]
    static let reversalTypeFragments: [String] = ["reversal", "reversed", "refund"]

    /// The step is "make first transaction" — money the customer sent, so only the ledger's
    /// outgoing direction counts. `credit` is a received deposit, and an unrecognized direction
    /// fails closed like an unrecognized status. (`debit` is the wallet ledger's outgoing word;
    /// see `KitMoney.signed`.)
    static let outgoingTransactionDirections: Set<String> = ["debit"]

    /// A genuine settled money-moving transaction the customer made: a recognized settled
    /// status, an outgoing direction, a type that is neither a request nor a reversal/refund,
    /// and an amount that actually moved value. Unknown statuses, unknown directions,
    /// unparseable amounts, and zero amounts all fail closed.
    static func isSettledMoneyMovement(_ transaction: WalletTransaction) -> Bool {
        let type = transaction.type
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let status = transaction.status
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let direction = transaction.direction
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard settledTransactionStatuses.contains(status),
              outgoingTransactionDirections.contains(direction),
              !nonMovementTransactionTypes.contains(type),
              !reversalTypeFragments.contains(where: type.contains),
              // POSIX locale: API amounts use a dot decimal separator regardless of the
              // device's region format.
              let amount = Decimal(
                  string: transaction.amount.trimmingCharacters(in: .whitespacesAndNewlines),
                  locale: Locale(identifier: "en_US_POSIX")
              ),
              amount.magnitude > 0
        else { return false }
        return true
    }

    static func hasMadeFirstTransaction(transactions: [WalletTransaction]) -> Bool {
        transactions.contains(where: isSettledMoneyMovement)
    }

    /// Nil means Home shows no checklist: either every step is done, or the signed-in account
    /// is the App Review demo, whose synthetic rows must neither show nor satisfy first-run
    /// steps.
    static func checklist(
        kycStatus: String?,
        messages: [LocalMessage],
        transactions: [WalletTransaction],
        hasConfirmedFirstMessage: Bool = false,
        hasConfirmedFirstTransaction: Bool = false,
        isDemoActive: Bool,
        isDemoConversation: (String) -> Bool = { _ in false }
    ) -> HomeStarterChecklist? {
        guard !isDemoActive else { return nil }
        let entries = [
            HomeStarterChecklist.Entry(
                step: .verifyIdentity,
                isComplete: identityVerified(kycStatus: kycStatus)
            ),
            HomeStarterChecklist.Entry(
                step: .sendFirstMessage,
                // Chats can be deleted and history paginated away; the persisted marker keeps
                // a genuinely sent first message from un-completing later.
                isComplete: hasConfirmedFirstMessage
                    || hasSentFirstMessage(
                        messages: messages,
                        isDemoConversation: isDemoConversation
                    )
            ),
            HomeStarterChecklist.Entry(
                step: .makeFirstTransaction,
                // The live rows are only the latest page of the selected wallet; the persisted
                // marker is the account-wide memory of a settled movement once observed.
                isComplete: hasConfirmedFirstTransaction
                    || hasMadeFirstTransaction(transactions: transactions)
            ),
        ]
        guard entries.contains(where: { !$0.isComplete }) else { return nil }
        return HomeStarterChecklist(entries: entries)
    }
}

/// Optional server-owned account-wide starter checklist (feature key `starter_checklist`,
/// `GET onboarding/starter-checklist`). The authoritative response is nested: the account it
/// speaks for, an eligibility flag, an integer policy version, and one entry per milestone.
/// Device evidence stays one-directional — seeing a sent message or a settled outgoing movement
/// proves the milestone, but a fresh device or paginated-away history proves nothing — so the
/// backend's account-wide truth may confirm the same persisted markers. Everything here fails
/// closed, and it fails whole: a missing capability, a missing or mistyped field, a payload
/// naming another account, `eligible` false, a policy version below 1, an unknown or duplicate
/// milestone key, and an unknown status each discard the entire confirmation rather than the
/// parts that look wrong. Nothing here can un-complete a step.
struct StarterMilestonesDTO: Decodable, Equatable, Sendable {
    static let capabilityKey = "starter_checklist"

    /// The status vocabulary this build understands. `completed` — exact, lowercase — is the
    /// only status that confirms; `pending` is valid and confirms nothing; anything else means
    /// the contract has moved and the whole payload is beyond this build's judgement.
    static let completedStatus = "completed"
    static let pendingStatus = "pending"

    /// The canonical milestone vocabulary, mirroring the checklist's own steps. All three are
    /// part of validation even though identity verification keeps its own server-owned KYC
    /// contract and never persists a checklist marker on the device.
    static let verifyIdentityMilestoneKey = "verify_identity"
    static let sendFirstMessageMilestoneKey = "send_first_message"
    static let makeFirstTransactionMilestoneKey = "make_first_transaction"
    static let knownMilestoneKeys: Set<String> = [
        verifyIdentityMilestoneKey,
        sendFirstMessageMilestoneKey,
        makeFirstTransactionMilestoneKey,
    ]

    struct Milestone: Decodable, Equatable, Sendable {
        let key: String
        let status: String
        /// Server bookkeeping, never part of the gating decision. The key itself is required —
        /// a payload that omits it entirely is not the documented contract — but its value is
        /// null until the milestone completes.
        let completedAt: String?

        enum CodingKeys: String, CodingKey {
            case key, status
            case completedAt = "completed_at"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            key = try container.decode(String.self, forKey: .key)
            status = try container.decode(String.self, forKey: .status)
            // Synthesized decoding would treat a missing key and an explicit null the same;
            // the contract requires the key, so its absence must fail the decode.
            guard container.contains(.completedAt) else {
                throw DecodingError.keyNotFound(CodingKeys.completedAt, DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "completed_at is required; null marks an open milestone"
                ))
            }
            completedAt = try container.decodeIfPresent(String.self, forKey: .completedAt)
        }
    }

    /// The account this checklist speaks for; a payload naming any other account is discarded
    /// whole rather than mined for the parts that look right.
    let accountId: String
    /// The server's own gate on the programme; `false` withholds every confirmation.
    let eligible: Bool
    /// Integer policy revision, 1 or greater.
    let policyVersion: Int
    let milestones: [Milestone]

    enum CodingKeys: String, CodingKey {
        case accountId = "account_id"
        case eligible
        case policyVersion = "policy_version"
        case milestones
    }

    /// The milestone keys the server confirms for the given account — or nil when the payload
    /// must not be trusted at all. The account comparison parses both IDs as they are: a
    /// whitespace-corrupted `account_id` is evidence of a broken producer, not something to
    /// repair into a match.
    func confirmedMilestoneKeys(forAccountID activeAccountID: String) -> Set<String>? {
        guard let payloadAccount = UUID(uuidString: accountId),
              let activeAccount = UUID(uuidString: activeAccountID),
              payloadAccount == activeAccount,
              eligible,
              policyVersion >= 1
        else { return nil }
        var confirmed: Set<String> = []
        var seenKeys: Set<String> = []
        for milestone in milestones {
            guard Self.knownMilestoneKeys.contains(milestone.key),
                  seenKeys.insert(milestone.key).inserted
            else { return nil }
            switch milestone.status {
            case Self.completedStatus:
                confirmed.insert(milestone.key)
            case Self.pendingStatus:
                continue
            default:
                return nil
            }
        }
        return confirmed
    }
}

struct ConversationDraftWriteVersion: Codable, Hashable, Sendable {
    let writerID: UUID
    let sequence: UInt64
}

/// Encrypted, account-bound ownership of one composer attachment before Send is pressed.
///
/// The media bytes live in `SecureMediaFileCache`; this manifest deliberately stores only a
/// permanent client id and bounded metadata, never an absolute path or a remote URL. Persisting
/// it beside the text draft closes the relaunch gap between selecting/capturing media and
/// committing the eventual message/outbox row.
struct ConversationDraftMediaAttachment: Codable, Hashable, Sendable {
    enum StorageKind: String, Codable, Hashable, Sendable {
        case encryptedBlob
        case protectedFile
    }

    static let maximumDisplayNameScalars = 1_024

    let id: UUID
    let storageKind: StorageKind
    /// The representation that will enter the encrypted wire after any durable preprocessing.
    let mediaType: String
    /// The exact protected source MIME when `mediaType` is a later optimized representation.
    let originalMediaType: String?
    let byteCount: Int
    let displayName: String
    let duration: TimeInterval?
    let acceptedAt: Date
    let clientMessageID: UUID?
    let preprocessingOutputStorageKey: String?

    var storageKey: String { id.uuidString.lowercased() }

    static func boundedDisplayName(_ value: String, fallback: String) -> String {
        var result = ""
        var scalarCount = 0
        for character in value where !character.unicodeScalars.contains(where: {
            $0.value == 0
        }) {
            let count = character.unicodeScalars.count
            guard scalarCount + count <= maximumDisplayNameScalars else { break }
            result.append(character)
            scalarCount += count
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? fallback
            : result
    }

    var isStructurallyValid: Bool {
        guard SecureMessagingWire.allowedAttachmentMediaTypes.contains(mediaType),
              KitChatMediaLimits.fitsLocalOriginal(
                  byteCount: byteCount,
                  mediaType: originalMediaType ?? mediaType
              ),
              !displayName.isEmpty,
              displayName.unicodeScalars.count <= Self.maximumDisplayNameScalars,
              !displayName.unicodeScalars.contains(where: { $0.value == 0 }),
              duration.map({ $0.isFinite && $0 > 0 }) ?? true,
              acceptedAt.timeIntervalSinceReferenceDate.isFinite
        else { return false }

        switch (originalMediaType, preprocessingOutputStorageKey) {
        case (nil, nil):
            return true
        case let (sourceMediaType?, outputStorageKey?):
            return mediaType == "image/jpeg"
                && sourceMediaType == sourceMediaType.lowercased()
                && sourceMediaType.hasPrefix("image/")
                && sourceMediaType.utf8.count <= 127
                && sourceMediaType.unicodeScalars.allSatisfy {
                    $0.value >= 0x21 && $0.value <= 0x7e
                }
                && UUID(uuidString: outputStorageKey)?.uuidString.lowercased()
                    == outputStorageKey
                && outputStorageKey != storageKey
        case (.some, nil), (nil, .some):
            return false
        }
    }
}

struct ConversationDraft: Codable, Hashable, Sendable {
    let body: String
    let updatedAt: Date
    /// Optional keeps drafts written before ordered persistence backward-decodable. Within one
    /// running app, later mutations from the same writer always supersede delayed debounce tasks.
    let writeVersion: ConversationDraftWriteVersion?
    /// Optional keeps every draft written before local-first composer media backward-decodable.
    /// An empty array is normalized to nil when written.
    let mediaAttachments: [ConversationDraftMediaAttachment]?

    init(
        body: String,
        updatedAt: Date,
        writeVersion: ConversationDraftWriteVersion? = nil,
        mediaAttachments: [ConversationDraftMediaAttachment]? = nil
    ) {
        self.body = body
        self.updatedAt = updatedAt
        self.writeVersion = writeVersion
        self.mediaAttachments = mediaAttachments
    }

    var localMediaStorageKeys: [String] {
        let keys = (mediaAttachments ?? []).flatMap { attachment in
            [attachment.storageKey, attachment.preprocessingOutputStorageKey].compactMap { $0 }
        }
        var seen = Set<String>()
        return keys.compactMap { raw -> String? in
            guard let canonical = UUID(uuidString: raw)?.uuidString.lowercased(),
                  seen.insert(canonical).inserted
            else { return nil }
            return canonical
        }
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

/// Device-local ownership of one media item. The media id is minted before upload and never
/// changes when a server storage key appears, which keeps rendering, retry and cleanup rooted in
/// local identity rather than a CDN/object URL. This metadata lives inside the account-bound
/// encrypted state file; `localStorageKey` addresses either the encrypted blob cache or the
/// message's encrypted inline slot and never exposes a filesystem path to the UI.
/// One immutable sender-side source retained independently of any optimized upload
/// representation. A voice note can have several finalized AAC segments; an image has one
/// camera/library original. These references remain part of the message's ownership graph after
/// preprocessing succeeds, so cleanup can never orphan (or prematurely delete) the original.
struct LocalMediaOriginalSource: Codable, Hashable, Sendable {
    let storageKey: String
    let mediaType: String
    let fileSize: Int
    let duration: TimeInterval?

    var isStructurallyValid: Bool {
        guard UUID(uuidString: storageKey)?.uuidString.lowercased() == storageKey,
              !mediaType.isEmpty,
              mediaType == mediaType.lowercased(),
              mediaType.utf8.count <= 127,
              mediaType.unicodeScalars.allSatisfy({ scalar in
                  scalar.value >= 0x21 && scalar.value <= 0x7e
              }),
              (1 ... SecureMediaAttachmentCipher.maximumPlaintextBytes).contains(fileSize),
              duration.map({ $0.isFinite && $0 > 0 }) ?? true
        else { return false }
        return true
    }
}

/// Durable work that must finish before ciphertext/upload may start. The visible message and its
/// protected originals are committed first; the outbox command is explicitly parked while this
/// value exists. Relaunch simply resumes the same job and publishes to the same output key.
struct LocalMediaPreprocessingJob: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable {
        case imageJPEG
        case voiceAssembly
    }

    let kind: Kind
    let sources: [LocalMediaOriginalSource]
    let outputStorageKey: String
    let outputMediaType: String

    var isStructurallyValid: Bool {
        guard !sources.isEmpty,
              sources.count <= 256,
              sources.allSatisfy(\.isStructurallyValid),
              Set(sources.map(\.storageKey)).count == sources.count,
              UUID(uuidString: outputStorageKey)?.uuidString.lowercased() == outputStorageKey,
              !Set(sources.map(\.storageKey)).contains(outputStorageKey),
              SecureMessagingWire.allowedAttachmentMediaTypes.contains(outputMediaType)
        else { return false }
        var aggregate = 0
        for source in sources {
            let (next, overflow) = aggregate.addingReportingOverflow(source.fileSize)
            guard !overflow,
                  next <= SecureMediaAttachmentCipher.maximumPlaintextBytes
            else { return false }
            aggregate = next
        }
        switch kind {
        case .imageJPEG:
            return sources.count == 1
                && sources[0].mediaType.hasPrefix("image/")
                && outputMediaType == "image/jpeg"
        case .voiceAssembly:
            return sources.allSatisfy { $0.mediaType == "audio/mp4" }
                && outputMediaType == "audio/mp4"
        }
    }
}

struct LocalMediaRecord: Codable, Hashable, Identifiable, Sendable {
    enum Direction: String, Codable, Hashable, Sendable {
        case sent
        case received
    }

    enum LocalStorageKind: String, Codable, Hashable, Sendable {
        case encryptedState
        case encryptedBlob
        /// A sender-owned original kept as a file so video/document playback never requires a
        /// whole-file decrypt/copy. The file is account-scoped, backup-excluded and protected by
        /// iOS Data Protection; transmission still uses the attachment E2EE cipher.
        case protectedFile
        case none
    }

    enum ProcessingState: String, Codable, Hashable, Sendable {
        case ready
        case processing
        case failed
    }

    enum UploadState: String, Codable, Hashable, Sendable {
        case notRequired
        case pending
        case uploading
        case uploaded
        case failed
    }

    enum DownloadState: String, Codable, Hashable, Sendable {
        case notRequired
        case pending
        case downloading
        case downloaded
        case failed
    }

    enum EncryptionState: String, Codable, Hashable, Sendable {
        case pending
        case encrypting
        case encrypted
        case decrypted
        case failed
    }

    enum AvailabilityState: String, Codable, Hashable, Sendable {
        case localOriginal
        case localCached
        case remoteOnly
        case unavailable
    }

    let id: String
    let messageID: UUID
    let conversationID: String
    let direction: Direction
    var mediaType: String
    var fileSize: Int
    var duration: TimeInterval?
    /// Sender-only E2EE attachment key material, protected by SecureLocalStore. Persisting it
    /// before upload lets retries reproduce the same ciphertext for the permanent media id.
    var outboundKeyMaterialBase64: String?
    var localStorageKind: LocalStorageKind
    var localStorageKey: String?
    var remoteEncryptedObjectID: String?
    var processingState: ProcessingState
    var uploadState: UploadState
    var downloadState: DownloadState
    var encryptionState: EncryptionState
    var availabilityState: AvailabilityState
    /// Capture/selection inputs retained even after `localStorageKey` switches to the processed
    /// representation. Optional keeps every pre-local-first state file backward-decodable.
    var originalSources: [LocalMediaOriginalSource]? = nil
    /// Non-nil only while durable preprocessing is pending or retryable after a failure.
    var preprocessingJob: LocalMediaPreprocessingJob? = nil
    /// Durable facts for the deterministic encrypted spool. Optional fields keep protected
    /// state written by build 44 and earlier readable without a migration rewrite.
    var ciphertextSpoolByteSize: Int64? = nil
    var ciphertextSpoolSHA256: String? = nil
    /// Authoritative server offset/session checkpoint. Once present it is drained even if the
    /// capability is later withdrawn; starting a new session still requires the live capability.
    var resumableUpload: LocalMediaResumableUpload? = nil
    /// A receiver-cache eviction remains remote and fetchable, but is not immediately prefetched
    /// again by the background hydrator. An explicit open clears this marker before downloading.
    var cacheEvictedAt: Date? = nil
    let createdAt: Date
    var updatedAt: Date

    var isStructurallyValid: Bool {
        guard UUID(uuidString: id)?.uuidString.lowercased() == id,
              OutboxPolicy.canonicalConversationID(conversationID) == conversationID,
              SecureMessagingWire.allowedAttachmentMediaTypes.contains(mediaType),
              KitChatMediaLimits.fits(fileSize, kind: KitChatMediaKind(mediaType: mediaType)),
              duration.map({ $0.isFinite && $0 >= 0 }) ?? true,
              outboundKeyMaterialBase64.map({ encoded in
                  guard let decoded = Data(base64Encoded: encoded) else { return false }
                  return decoded.count == SecureMediaAttachmentCipher.keyMaterialBytes
                      && decoded.base64EncodedString() == encoded
              }) ?? true,
              localStorageKey.map({ UUID(uuidString: $0)?.uuidString.lowercased() == $0 }) ?? true,
              remoteEncryptedObjectID.map({
                  UUID(uuidString: $0)?.uuidString.lowercased() == $0
              }) ?? true,
              ciphertextSpoolByteSize.map({
                  $0 >= SecureMessagingWire.minimumAttachmentCiphertextBytes
                      && $0 <= SecureMessagingWire.maximumAttachmentCiphertextBytes
              }) ?? true,
              ciphertextSpoolSHA256.map(SecureMessagingWirePolicy.isLowercaseSHA256) ?? true,
              (ciphertextSpoolByteSize == nil) == (ciphertextSpoolSHA256 == nil),
              resumableUpload?.isStructurallyValid ?? true,
              resumableUpload.map({ checkpoint in
                  checkpoint.uploadID == id
                      && checkpoint.storageKey != nil
                      && ciphertextSpoolByteSize.map({ checkpoint.nextOffset <= $0 }) == true
              }) ?? true,
              originalSources.map({ sources in
                  !sources.isEmpty
                      && sources.count <= 256
                      && sources.allSatisfy(\.isStructurallyValid)
                      && Set(sources.map(\.storageKey)).count == sources.count
              }) ?? true,
              preprocessingJob?.isStructurallyValid ?? true,
              cacheEvictedAt.map({ _ in
                  direction == .received
                      && localStorageKind == .none
                      && localStorageKey == nil
                      && remoteEncryptedObjectID != nil
                      && downloadState == .pending
                      && encryptionState == .encrypted
                      && availabilityState == .remoteOnly
              }) ?? true,
              preprocessingJob.map({ job in
                  direction == .sent
                      && id != job.outputStorageKey
                      && originalSources == job.sources
                      && localStorageKind == .protectedFile
                      && localStorageKey == job.sources.first?.storageKey
                      && mediaType == job.outputMediaType
                      && fileSize == job.sources.first?.fileSize
                      && remoteEncryptedObjectID == nil
                      && uploadState == .pending
                      && encryptionState == .pending
                      && [.processing, .failed].contains(processingState)
              }) ?? true
        else { return false }

        // A sender's permanent client id addresses its ciphertext spool, while its local key,
        // original sources and preprocessing output address plaintext representations. A server
        // object may never alias any of those roles. Resumable and finalized server references
        // may coexist only while they name the same object during the READY-to-sealed handoff.
        if direction == .sent {
            var clientOwnedKeys = Set([id])
            if let localStorageKey { clientOwnedKeys.insert(localStorageKey) }
            clientOwnedKeys.formUnion(originalSources?.map(\.storageKey) ?? [])
            if let output = preprocessingJob?.outputStorageKey {
                clientOwnedKeys.insert(output)
            }
            let resumableStorageKey = resumableUpload?.storageKey
            for serverKey in [remoteEncryptedObjectID, resumableStorageKey].compactMap({ $0 }) {
                guard !clientOwnedKeys.contains(serverKey) else { return false }
            }
            if let remoteEncryptedObjectID, let resumableStorageKey,
               remoteEncryptedObjectID != resumableStorageKey {
                return false
            }
        }

        switch localStorageKind {
        case .encryptedState:
            guard localStorageKey == nil else { return false }
        case .encryptedBlob, .protectedFile:
            guard localStorageKey != nil else { return false }
        case .none:
            guard localStorageKey == nil else { return false }
        }
        switch availabilityState {
        case .localOriginal, .localCached:
            guard localStorageKind != .none else { return false }
        case .remoteOnly:
            guard localStorageKind == .none, remoteEncryptedObjectID != nil else { return false }
        case .unavailable:
            break
        }
        if direction == .received, uploadState != .notRequired { return false }
        if direction == .received, outboundKeyMaterialBase64 != nil { return false }
        if direction == .sent, downloadState != .notRequired { return false }
        return true
    }
}

struct LocalMediaResumableUpload: Codable, Hashable, Sendable {
    let uploadID: String
    /// Server object allocated at start. Optional solely for decoding never-shipped interim
    /// state; every live response must supply and pin a canonical value before upload proceeds.
    var storageKey: String? = nil
    var nextOffset: Int64
    let maxChunkBytes: Int
    let expiresAt: String?

    var isStructurallyValid: Bool {
        SecureMessagingWirePolicy.isCanonicalUUID(uploadID)
            && (storageKey.map(SecureMessagingWirePolicy.isCanonicalUUID) ?? true)
            && nextOffset >= 0
            && maxChunkBytes > 0
            && maxChunkBytes <= MessagingResumableAttachmentPolicy.maximumChunkBytes
            && expiresAt.map({ !$0.isEmpty && $0.utf8.count <= 128 }) ?? true
    }
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
    /// Durable send-side state of a queued multi-attachment (KITMEDIA2) message: every item's
    /// park key, its queue-minted key material, and the per-item upload checkpoints. Present
    /// exactly from queue time until the sealed descriptor replaces `body`, so a crash at any
    /// point resumes the same one-message identity instead of re-queueing or splitting.
    /// Optional keeps state written by earlier builds decodable.
    var pendingMediaBatch: KitMediaMessageV2OutboundBatch? = nil
    /// Stable local-first records for every attachment in this message. Optional keeps protected
    /// state written before the media-library layer backward-decodable; restore backfills safe
    /// descriptor metadata without guessing that a local blob exists.
    var localMediaRecords: [LocalMediaRecord]? = nil
    /// Exact authenticated metadata needed to donate this plaintext through the history-backfill
    /// protocol. A missing value is fail-closed: the message remains visible locally but is never
    /// offered as a trusted history source to another enrollment.
    var secureMessagingHistory: SecureMessagingRetainedMessageMetadata? = nil
    /// Server message this one answers, when the sender swiped to reply. It is the same value
    /// the wire carries in `replyToMessageID`, kept here so a queued answer can already draw its
    /// quote before the send round-trip mints a metadata record. Reactions never populate it:
    /// they point at a target too, but they are timeline metadata rather than an answer.
    /// Optional keeps state written by earlier builds decodable.
    var replyToServerMessageID: String? = nil
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
    var mediaType: String
    let caption: String?
    /// Locally minted storage key of a large plaintext parked in the encrypted media file cache
    /// while the message waits offline for upload. Inline attachments leave this nil. Optional
    /// keeps state written by earlier builds decodable.
    var localStorageKey: String? = nil
    /// Plaintext size for pending bubbles that carry no inline data. Optional for old state.
    var byteCount: Int? = nil
}

/// One composer-owned input crossing into the durable batch queue. Large sources carry only the
/// permanent protected-file key and byte count; small sources may carry in-memory bytes. This
/// type never holds a filesystem path, so the model/coordinator always re-resolve storage inside
/// the active account boundary.
struct LocalMediaQueueAttachment: Sendable {
    let mediaID: UUID
    let mediaData: Data?
    let mediaType: String
    let byteCount: Int
    let localStorageKind: LocalMediaRecord.LocalStorageKind
    /// Optional durable transform that owns this attachment's source/output keys. Batch items
    /// carry this independently so a mixed album can preprocess one HEIC while an adjacent
    /// video/document remains immediately ready.
    let preprocessingJob: LocalMediaPreprocessingJob?

    init(
        mediaID: UUID,
        mediaData: Data?,
        mediaType: String,
        byteCount: Int,
        localStorageKind: LocalMediaRecord.LocalStorageKind,
        preprocessingJob: LocalMediaPreprocessingJob? = nil
    ) {
        self.mediaID = mediaID
        self.mediaData = mediaData
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.localStorageKind = localStorageKind
        self.preprocessingJob = preprocessingJob
    }
}

/// Pure state transitions for the local media library. File I/O remains in
/// `SecureMediaFileCache`; these helpers keep its stable identity and lifecycle metadata in the
/// same atomic state mutation as the message/outbox projection.
enum LocalMediaRecordPolicy {
    static func queuedOutgoing(
        id: String,
        messageID: UUID,
        conversationID: String,
        mediaType: String,
        fileSize: Int,
        duration: TimeInterval? = nil,
        localStorageKey: String?,
        storesInline: Bool,
        now: Date,
        outboundKeyMaterial: Data? = nil,
        localStorageKind suppliedStorageKind: LocalMediaRecord.LocalStorageKind? = nil,
        originalSources: [LocalMediaOriginalSource]? = nil,
        preprocessingJob: LocalMediaPreprocessingJob? = nil
    ) -> LocalMediaRecord? {
        guard let mediaID = canonicalUUID(id),
              let conversationID = canonicalUUID(conversationID)
        else { return nil }
        let record = LocalMediaRecord(
            id: mediaID,
            messageID: messageID,
            conversationID: conversationID,
            direction: .sent,
            mediaType: mediaType,
            fileSize: fileSize,
            duration: duration,
            outboundKeyMaterialBase64: outboundKeyMaterial?.base64EncodedString(),
            localStorageKind: storesInline
                ? .encryptedState
                : suppliedStorageKind ?? .encryptedBlob,
            localStorageKey: storesInline ? nil : canonicalUUID(localStorageKey),
            remoteEncryptedObjectID: nil,
            processingState: preprocessingJob == nil ? .ready : .processing,
            uploadState: .pending,
            downloadState: .notRequired,
            encryptionState: .pending,
            availabilityState: .localOriginal,
            originalSources: originalSources,
            preprocessingJob: preprocessingJob,
            createdAt: now,
            updatedAt: now
        )
        return record.isStructurallyValid ? record : nil
    }

    static func queuedOutgoing(
        batch: KitMediaMessageV2OutboundBatch,
        messageID: UUID,
        conversationID: String,
        now: Date,
        localStorageKinds: [LocalMediaRecord.LocalStorageKind]? = nil,
        preprocessingJobs: [LocalMediaPreprocessingJob?]? = nil
    ) -> [LocalMediaRecord]? {
        guard batch.isStructurallyValid,
              localStorageKinds.map({ $0.count == batch.items.count }) ?? true,
              preprocessingJobs.map({ $0.count == batch.items.count }) ?? true
        else { return nil }
        let records = batch.items.enumerated().compactMap { index, item in
            let job = preprocessingJobs?[index]
            return queuedOutgoing(
                id: item.attachmentID,
                messageID: messageID,
                conversationID: conversationID,
                mediaType: item.mediaType,
                fileSize: item.plaintextByteSize,
                localStorageKey: item.localStorageKey,
                storesInline: false,
                now: now,
                outboundKeyMaterial: Data(base64Encoded: item.keyMaterialBase64),
                localStorageKind: localStorageKinds?[index],
                originalSources: job?.sources,
                preprocessingJob: job
            )
        }
        return records.count == batch.items.count ? records : nil
    }

    /// Creates remote-only records for an authenticated media projection. Merely receiving
    /// metadata never claims plaintext is local; the verifying download path promotes a record
    /// to `localCached` only after its protected cache write succeeds.
    static func remoteRecords(for message: LocalMessage, now: Date? = nil) -> [LocalMediaRecord]? {
        let direction: LocalMediaRecord.Direction = message.isOutgoing ? .sent : .received
        let timestamp = now ?? message.sentAt ?? message.createdAt
        let items: [(String, String, Int, String)]
        if let descriptor = KitMediaMessageDescriptor.parse(message.body) {
            items = [(
                descriptor.attachmentID,
                descriptor.mediaType,
                descriptor.plaintextByteSize,
                descriptor.storageKey
            )]
        } else if let descriptor = KitMediaMessageV2Descriptor.parse(message.body) {
            items = descriptor.items.map {
                ($0.attachmentID, $0.mediaType, $0.plaintextByteSize, $0.storageKey)
            }
        } else {
            return nil
        }
        let records = items.map { mediaID, mediaType, size, storageKey in
            LocalMediaRecord(
                id: mediaID,
                messageID: message.id,
                conversationID: message.conversationId,
                direction: direction,
                mediaType: mediaType,
                fileSize: size,
                duration: nil,
                outboundKeyMaterialBase64: nil,
                localStorageKind: .none,
                localStorageKey: nil,
                remoteEncryptedObjectID: storageKey,
                processingState: .ready,
                uploadState: direction == .sent ? .uploaded : .notRequired,
                downloadState: direction == .received ? .pending : .notRequired,
                encryptionState: .encrypted,
                availabilityState: .remoteOnly,
                createdAt: timestamp,
                updatedAt: timestamp
            )
        }
        return records.allSatisfy(\.isStructurallyValid) ? records : nil
    }

    /// Backfills old protected rows and resets process-only in-flight states after a relaunch.
    /// It never guesses that a descriptor-backed blob exists: old sealed rows begin remote-only
    /// unless their plaintext is visibly inline, and a successful local read promotes them.
    @discardableResult
    static func migrateAndRecover(_ message: inout LocalMessage, now: Date = Date()) -> Bool {
        let before = message.localMediaRecords
        if message.localMediaRecords == nil {
            if let pending = message.pendingAttachment {
                let mediaID = message.id.uuidString.lowercased()
                message.localMediaRecords = queuedOutgoing(
                    id: mediaID,
                    messageID: message.id,
                    conversationID: message.conversationId,
                    mediaType: pending.mediaType,
                    fileSize: pending.byteCount ?? message.attachmentData?.count ?? 0,
                    localStorageKey: pending.localStorageKey,
                    storesInline: message.attachmentData != nil,
                    now: message.createdAt
                ).map { [$0] }
            } else if let batch = message.pendingMediaBatch {
                message.localMediaRecords = queuedOutgoing(
                    batch: batch,
                    messageID: message.id,
                    conversationID: message.conversationId,
                    now: message.createdAt
                )
                if var records = message.localMediaRecords {
                    for index in records.indices where batch.items[index].isUploaded {
                        let item = batch.items[index]
                        records[index].remoteEncryptedObjectID = item.storageKey
                        records[index].uploadState = .uploaded
                        records[index].encryptionState = .encrypted
                        records[index].updatedAt = now
                    }
                    message.localMediaRecords = records
                }
            } else if let remote = remoteRecords(for: message) {
                if message.attachmentData != nil, remote.count == 1 {
                    var local = remote[0]
                    local.localStorageKind = .encryptedState
                    local.availabilityState = message.isOutgoing ? .localOriginal : .localCached
                    local.downloadState = message.isOutgoing ? .notRequired : .downloaded
                    local.encryptionState = message.isOutgoing ? .encrypted : .decrypted
                    message.localMediaRecords = [local]
                } else {
                    message.localMediaRecords = remote
                }
            }
        }
        if var records = message.localMediaRecords {
            for index in records.indices {
                var recovered = false
                if let upload = records[index].resumableUpload,
                   upload.storageKey == nil || upload.uploadID != records[index].id {
                    records[index].resumableUpload = nil
                    records[index].uploadState = .pending
                    recovered = true
                }
                switch records[index].processingState {
                case .processing where records[index].preprocessingJob == nil:
                    records[index].processingState = .ready
                    recovered = true
                case .ready, .failed, .processing:
                    break
                }
                if records[index].uploadState == .uploading {
                    records[index].uploadState = .pending
                    recovered = true
                }
                if records[index].downloadState == .downloading {
                    records[index].downloadState = .pending
                    recovered = true
                }
                if records[index].direction == .received,
                   records[index].downloadState == .failed {
                    records[index].downloadState = .pending
                    records[index].processingState = .ready
                    recovered = true
                }
                if records[index].encryptionState == .encrypting {
                    records[index].encryptionState = records[index].uploadState == .uploaded
                        ? .encrypted
                        : .pending
                    recovered = true
                }
                if recovered { records[index].updatedAt = max(records[index].updatedAt, now) }
            }
            message.localMediaRecords = records
        }
        return before != message.localMediaRecords
    }

    static func record(
        messageID: UUID,
        conversationID: String,
        attachmentID: String,
        mediaType: String,
        fileSize: Int,
        remoteStorageKey: String?,
        in messages: [LocalMessage]
    ) -> LocalMediaRecord? {
        let rows = messages.filter {
            $0.id == messageID && $0.conversationId == conversationID
        }
        guard rows.count == 1, let message = rows.first else { return nil }
        let matches = (message.localMediaRecords ?? []).filter { record in
            record.id == attachmentID
                && record.messageID == messageID
                && record.conversationID == conversationID
                && record.direction == (message.isOutgoing ? .sent : .received)
                && record.mediaType == mediaType
                && record.fileSize == fileSize
                && record.remoteEncryptedObjectID == remoteStorageKey
                && record.isStructurallyValid
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    static func markUploading(_ message: inout LocalMessage, attachmentID: String, now: Date = Date()) -> Bool {
        mutate(&message, attachmentID: attachmentID) { record in
            guard record.direction == .sent,
                  record.preprocessingJob == nil,
                  record.uploadState == .pending || record.uploadState == .failed
            else { return false }
            record.processingState = .processing
            record.uploadState = .uploading
            record.encryptionState = record.ciphertextSpoolByteSize == nil
                ? .encrypting
                : .encrypted
            record.updatedAt = now
            return true
        }
    }

    static func setCiphertextSpool(
        _ message: inout LocalMessage,
        attachmentID: String,
        byteSize: Int64,
        sha256: String,
        now: Date = Date()
    ) -> Bool {
        guard byteSize >= SecureMessagingWire.minimumAttachmentCiphertextBytes,
              byteSize <= SecureMessagingWire.maximumAttachmentCiphertextBytes,
              SecureMessagingWirePolicy.isLowercaseSHA256(sha256)
        else { return false }
        return mutate(&message, attachmentID: attachmentID) { record in
            guard record.direction == .sent,
                  record.ciphertextSpoolByteSize.map({ $0 == byteSize }) ?? true,
                  record.ciphertextSpoolSHA256.map({ $0 == sha256 }) ?? true
            else { return false }
            record.ciphertextSpoolByteSize = byteSize
            record.ciphertextSpoolSHA256 = sha256
            record.encryptionState = .encrypted
            record.processingState = .processing
            record.updatedAt = now
            return true
        }
    }

    static func setResumableUpload(
        _ message: inout LocalMessage,
        attachmentID: String,
        checkpoint: LocalMediaResumableUpload,
        now: Date = Date()
    ) -> Bool {
        guard checkpoint.isStructurallyValid else { return false }
        return mutate(&message, attachmentID: attachmentID) { record in
            guard record.direction == .sent,
                  record.uploadState == .uploading,
                  let spoolSize = record.ciphertextSpoolByteSize,
                  checkpoint.nextOffset <= spoolSize,
                  checkpoint.storageKey != nil,
                  checkpoint.uploadID == record.id,
                  record.resumableUpload.map({ $0.uploadID == checkpoint.uploadID }) ?? true
            else { return false }
            record.resumableUpload = checkpoint
            record.updatedAt = now
            return true
        }
    }

    /// Binds a completed server object to its attachment without declaring the whole message
    /// sealed. A batch can finish one item while siblings still upload; retaining the resumable
    /// checkpoint here permits the final READY lease preflight after an app restart.
    static func checkpointRemoteObject(
        _ message: inout LocalMessage,
        attachmentID: String,
        remoteStorageKey: String,
        now: Date = Date()
    ) -> Bool {
        guard let remoteStorageKey = canonicalUUID(remoteStorageKey) else { return false }
        return mutate(&message, attachmentID: attachmentID) { record in
            guard record.direction == .sent,
                  record.uploadState == .uploading,
                  record.remoteEncryptedObjectID.map({ $0 == remoteStorageKey }) ?? true,
                  (record.resumableUpload?.storageKey).map({
                      $0 == remoteStorageKey
                  }) ?? true
            else { return false }
            record.remoteEncryptedObjectID = remoteStorageKey
            record.updatedAt = now
            return true
        }
    }

    /// Retention may replace a completed but unclaimed resumable object with a fresh empty
    /// lease. Clear the old batch object's record binding and install the replacement checkpoint
    /// in one message-local transition; the caller persists this together with reopening the
    /// matching batch item under the account-wide ownership policy.
    static func replaceCompletedResumableUpload(
        _ message: inout LocalMessage,
        attachmentID: String,
        previousStorageKey: String,
        checkpoint: LocalMediaResumableUpload,
        now: Date = Date()
    ) -> Bool {
        guard let previousStorageKey = canonicalUUID(previousStorageKey),
              checkpoint.isStructurallyValid,
              let replacementStorageKey = checkpoint.storageKey,
              replacementStorageKey != previousStorageKey
        else { return false }
        return mutate(&message, attachmentID: attachmentID) { record in
            guard record.direction == .sent,
                  record.uploadState == .uploading,
                  let spoolSize = record.ciphertextSpoolByteSize,
                  checkpoint.nextOffset <= spoolSize,
                  checkpoint.uploadID == record.id,
                  record.resumableUpload?.uploadID == checkpoint.uploadID,
                  record.resumableUpload?.storageKey == previousStorageKey,
                  record.remoteEncryptedObjectID.map({ $0 == previousStorageKey }) ?? true
            else { return false }
            record.remoteEncryptedObjectID = nil
            record.resumableUpload = checkpoint
            record.updatedAt = now
            return true
        }
    }

    /// Drops only the server lease after it expires or disappears. The permanent media id,
    /// outbound key and deterministic ciphertext-spool facts remain pinned, so restarting the
    /// lease cannot create a duplicate attachment or re-encrypt different bytes.
    static func clearResumableUpload(
        _ message: inout LocalMessage,
        attachmentID: String,
        now: Date = Date()
    ) -> Bool {
        mutate(&message, attachmentID: attachmentID) { record in
            guard record.direction == .sent,
                  record.uploadState == .uploading,
                  record.resumableUpload != nil,
                  record.ciphertextSpoolByteSize != nil,
                  record.ciphertextSpoolSHA256 != nil
            else { return false }
            record.resumableUpload = nil
            record.updatedAt = now
            return true
        }
    }

    static func setOutboundKeyMaterial(
        _ message: inout LocalMessage,
        attachmentID: String,
        keyMaterial: Data,
        now: Date = Date()
    ) -> Bool {
        guard keyMaterial.count == SecureMediaAttachmentCipher.keyMaterialBytes else { return false }
        let encoded = keyMaterial.base64EncodedString()
        return mutate(&message, attachmentID: attachmentID) { record in
            guard record.direction == .sent,
                  record.outboundKeyMaterialBase64 == nil
                    || record.outboundKeyMaterialBase64 == encoded
            else { return false }
            record.outboundKeyMaterialBase64 = encoded
            record.updatedAt = now
            return true
        }
    }

    /// Persists locally-derived audiovisual duration without changing upload identity or any
    /// remote/E2EE state. Metadata extraction is intentionally asynchronous and may finish after
    /// the message has already entered the outbox. Do not rewrite an actively uploading record:
    /// deferred transfer commits compare-and-swap the complete message projection, so an
    /// otherwise harmless `updatedAt` change there would cancel a valid resumable upload pass.
    static func setDuration(
        _ message: inout LocalMessage,
        attachmentID: String,
        duration: TimeInterval,
        now: Date = Date()
    ) -> Bool {
        guard duration.isFinite, duration > 0 else { return false }
        return mutate(&message, attachmentID: attachmentID) { record in
            guard record.fileSize > 0,
                  record.uploadState != .uploading,
                  record.duration != duration
            else { return false }
            record.duration = duration
            record.updatedAt = now
            return true
        }
    }

    static func markUploaded(
        _ message: inout LocalMessage,
        attachmentID: String,
        remoteStorageKey: String,
        now: Date = Date()
    ) -> Bool {
        guard let remoteStorageKey = canonicalUUID(remoteStorageKey) else { return false }
        return mutate(&message, attachmentID: attachmentID) { record in
            guard record.direction == .sent else { return false }
            record.remoteEncryptedObjectID = remoteStorageKey
            record.processingState = .ready
            record.uploadState = .uploaded
            record.encryptionState = .encrypted
            record.availabilityState = .localOriginal
            record.ciphertextSpoolByteSize = nil
            record.ciphertextSpoolSHA256 = nil
            record.resumableUpload = nil
            record.updatedAt = now
            return true
        }
    }

    /// Reopens a sealed single attachment whose server object expired before message acceptance.
    /// Identity, local original and E2EE key stay pinned; only remote/upload-derived facts reset.
    static func reopenExpiredSingleUpload(
        _ message: inout LocalMessage,
        descriptor: KitMediaMessageDescriptor,
        now: Date = Date()
    ) -> Bool {
        guard message.pendingAttachment == nil,
              message.pendingMediaBatch == nil,
              message.body == descriptor.encoded,
              var records = message.localMediaRecords
        else { return false }
        let indices = records.indices.filter { records[$0].id == descriptor.attachmentID }
        guard indices.count == 1, let index = indices.first else { return false }
        var record = records[index]
        guard record.direction == .sent,
              record.messageID == message.id,
              record.conversationID == message.conversationId,
              record.mediaType == descriptor.mediaType,
              record.fileSize == descriptor.plaintextByteSize,
              record.outboundKeyMaterialBase64 == descriptor.keyMaterialBase64,
              record.remoteEncryptedObjectID == descriptor.storageKey,
              record.localStorageKind != .none,
              record.availabilityState == .localOriginal,
              record.isStructurallyValid
        else { return false }

        message.body = descriptor.caption
            ?? KitChatMediaKind(mediaType: descriptor.mediaType).previewLabel
        message.pendingAttachment = LocalPendingAttachment(
            mediaType: descriptor.mediaType,
            caption: descriptor.caption,
            localStorageKey: record.localStorageKind == .encryptedState
                ? nil
                : record.localStorageKey,
            byteCount: descriptor.plaintextByteSize
        )
        record.remoteEncryptedObjectID = nil
        record.processingState = .ready
        record.uploadState = .pending
        record.encryptionState = .pending
        record.ciphertextSpoolByteSize = nil
        record.ciphertextSpoolSHA256 = nil
        record.resumableUpload = nil
        record.updatedAt = now
        guard record.isStructurallyValid else { return false }
        records[index] = record
        message.localMediaRecords = records
        return true
    }

    /// Batch form of expiry recovery. The sealed descriptor authenticates immutable wire facts;
    /// each matching record supplies the independently retained local source to re-upload.
    static func reopenExpiredBatchUploads(
        _ message: inout LocalMessage,
        descriptor: KitMediaMessageV2Descriptor,
        now: Date = Date()
    ) -> Bool {
        guard message.pendingAttachment == nil,
              message.pendingMediaBatch == nil,
              message.attachmentData == nil,
              message.body == descriptor.encoded,
              var records = message.localMediaRecords,
              records.count == descriptor.items.count
        else { return false }
        var reopened = KitMediaMessageV2OutboundBatch.reopened(from: descriptor)
        for itemIndex in descriptor.items.indices {
            let item = descriptor.items[itemIndex]
            let recordIndices = records.indices.filter { records[$0].id == item.attachmentID }
            guard recordIndices.count == 1, let recordIndex = recordIndices.first else {
                return false
            }
            var record = records[recordIndex]
            guard record.direction == .sent,
                  record.messageID == message.id,
                  record.conversationID == message.conversationId,
                  record.mediaType == item.mediaType,
                  record.fileSize == item.plaintextByteSize,
                  record.outboundKeyMaterialBase64 == item.keyMaterialBase64,
                  record.remoteEncryptedObjectID == item.storageKey,
                  [.protectedFile, .encryptedBlob].contains(record.localStorageKind),
                  let localStorageKey = record.localStorageKey,
                  record.availabilityState == .localOriginal,
                  record.isStructurallyValid
            else { return false }
            reopened.items[itemIndex].localStorageKey = localStorageKey
            record.remoteEncryptedObjectID = nil
            record.processingState = .ready
            record.uploadState = .pending
            record.encryptionState = .pending
            record.ciphertextSpoolByteSize = nil
            record.ciphertextSpoolSHA256 = nil
            record.resumableUpload = nil
            record.updatedAt = now
            guard record.isStructurallyValid else { return false }
            records[recordIndex] = record
        }
        guard reopened.isStructurallyValid else { return false }
        message.body = reopened.caption
            ?? SecureMessagingExchangeCoordinator.mediaBatchPlaceholderBody(
                itemCount: reopened.items.count
            )
        message.pendingMediaBatch = reopened
        message.localMediaRecords = records
        return true
    }

    static func markDownloaded(
        _ message: inout LocalMessage,
        attachmentID: String,
        storageKey: String,
        now: Date = Date()
    ) -> Bool {
        guard let storageKey = canonicalUUID(storageKey) else { return false }
        return mutate(&message, attachmentID: attachmentID) { record in
            guard record.remoteEncryptedObjectID == storageKey else { return false }
            record.localStorageKind = .encryptedBlob
            record.localStorageKey = storageKey
            record.processingState = .ready
            record.downloadState = record.direction == .received ? .downloaded : .notRequired
            record.encryptionState = .decrypted
            record.availabilityState = .localCached
            record.cacheEvictedAt = nil
            record.updatedAt = now
            return true
        }
    }

    static func markDownloadedProtectedFile(
        _ message: inout LocalMessage,
        attachmentID: String,
        remoteStorageKey: String,
        localStorageKey: String,
        now: Date = Date()
    ) -> Bool {
        guard let remoteStorageKey = canonicalUUID(remoteStorageKey),
              let localStorageKey = canonicalUUID(localStorageKey)
        else { return false }
        return mutate(&message, attachmentID: attachmentID) { record in
            guard record.direction == .received,
                  record.remoteEncryptedObjectID == remoteStorageKey
            else { return false }
            record.localStorageKind = .protectedFile
            record.localStorageKey = localStorageKey
            record.processingState = .ready
            record.downloadState = .downloaded
            record.encryptionState = .decrypted
            record.availabilityState = .localCached
            record.cacheEvictedAt = nil
            record.updatedAt = now
            return true
        }
    }

    /// A verified small receive may live in the account-bound encrypted state row instead of
    /// the file cache. Keep that storage fact explicit so a relaunch does not pretend the
    /// server object is the only available representation.
    static func markDownloadedInline(
        _ message: inout LocalMessage,
        attachmentID: String,
        storageKey: String,
        now: Date = Date()
    ) -> Bool {
        guard let storageKey = canonicalUUID(storageKey) else { return false }
        return mutate(&message, attachmentID: attachmentID) { record in
            guard record.remoteEncryptedObjectID == storageKey else { return false }
            record.localStorageKind = .encryptedState
            record.localStorageKey = nil
            record.processingState = .ready
            record.downloadState = record.direction == .received ? .downloaded : .notRequired
            record.encryptionState = .decrypted
            record.availabilityState = .localCached
            record.cacheEvictedAt = nil
            record.updatedAt = now
            return true
        }
    }

    static func markDownloading(
        _ message: inout LocalMessage,
        attachmentID: String,
        now: Date = Date()
    ) -> Bool {
        mutate(&message, attachmentID: attachmentID) { record in
            guard record.direction == .received,
                  record.downloadState == .pending || record.downloadState == .failed
            else { return false }
            record.processingState = .processing
            record.downloadState = .downloading
            record.cacheEvictedAt = nil
            record.updatedAt = now
            return true
        }
    }

    static func markDownloadFailed(
        _ message: inout LocalMessage,
        attachmentID: String,
        now: Date = Date()
    ) -> Bool {
        mutate(&message, attachmentID: attachmentID) { record in
            guard record.direction == .received, record.downloadState != .downloaded
            else { return false }
            record.processingState = .failed
            record.downloadState = .failed
            record.updatedAt = now
            return true
        }
    }

    /// State half of receiver-cache eviction. The caller reserves the exact file first, performs
    /// this transition in the protected-state transaction, and only then commits deletion. Sender
    /// originals and inline received bytes are never accepted by this transition.
    static func markReceivedCacheEvicted(
        _ message: inout LocalMessage,
        attachmentID: String,
        expectedLocalStorageKey: String,
        expectedUpdatedAt: Date,
        now: Date = Date()
    ) -> Bool {
        guard let expectedLocalStorageKey = canonicalUUID(expectedLocalStorageKey) else {
            return false
        }
        return mutate(&message, attachmentID: attachmentID) { record in
            guard record.direction == .received,
                  record.availabilityState == .localCached,
                  record.downloadState == .downloaded,
                  record.remoteEncryptedObjectID != nil,
                  [.protectedFile, .encryptedBlob].contains(record.localStorageKind),
                  record.localStorageKey == expectedLocalStorageKey,
                  record.updatedAt == expectedUpdatedAt
            else { return false }
            record.localStorageKind = .none
            record.localStorageKey = nil
            record.processingState = .ready
            record.downloadState = .pending
            record.encryptionState = .encrypted
            record.availabilityState = .remoteOnly
            record.cacheEvictedAt = now
            record.updatedAt = now
            return true
        }
    }

    static func markRetryPending(_ message: inout LocalMessage, now: Date = Date()) {
        guard var records = message.localMediaRecords else { return }
        for index in records.indices where records[index].direction == .sent {
            if records[index].uploadState == .uploading
                || records[index].uploadState == .failed {
                records[index].uploadState = .pending
            }
            if records[index].encryptionState == .encrypting
                || records[index].encryptionState == .failed {
                records[index].encryptionState = .pending
            }
            if records[index].preprocessingJob == nil,
               (records[index].processingState == .processing
                   || records[index].processingState == .failed) {
                records[index].processingState = .ready
            }
            records[index].updatedAt = now
        }
        message.localMediaRecords = records
    }

    /// Moves one exact durable preprocessing job to a fresh immutable destination after finding
    /// an invalid crash remnant at the old key. The old key is intentionally not returned for
    /// inline deletion: once this state mutation commits it becomes an orphan for the bounded,
    /// age-gated cache sweep. The caller must prove the new key has no owner in the full state in
    /// the same store transaction before invoking this message-local transition.
    static func rekeyPreprocessingOutput(
        _ message: inout LocalMessage,
        attachmentID: String,
        expectedJob: LocalMediaPreprocessingJob,
        newOutputStorageKey: String,
        now: Date = Date()
    ) -> Bool {
        guard expectedJob.isStructurallyValid,
              let canonicalOutput = canonicalUUID(newOutputStorageKey),
              canonicalOutput == newOutputStorageKey,
              canonicalOutput != expectedJob.outputStorageKey,
              !expectedJob.sources.contains(where: { $0.storageKey == canonicalOutput }),
              !message.localMediaOwnershipKeys.contains(canonicalOutput)
        else { return false }
        let replacement = LocalMediaPreprocessingJob(
            kind: expectedJob.kind,
            sources: expectedJob.sources,
            outputStorageKey: canonicalOutput,
            outputMediaType: expectedJob.outputMediaType
        )
        guard replacement.isStructurallyValid else { return false }
        return mutate(&message, attachmentID: attachmentID) { record in
            guard record.preprocessingJob == expectedJob,
                  record.id != canonicalOutput,
                  record.originalSources == expectedJob.sources,
                  record.uploadState == .pending,
                  record.encryptionState == .pending,
                  record.remoteEncryptedObjectID == nil
            else { return false }
            record.preprocessingJob = replacement
            record.processingState = .processing
            record.updatedAt = now
            return true
        }
    }

    /// Atomically switches a preprocessing message from its immediately playable source to the
    /// finished local representation. The outbox command is released by the same store mutation
    /// at the call site, so encryption can never race an incompletely published output.
    static func completePreprocessing(
        _ message: inout LocalMessage,
        attachmentID: String,
        expectedJob: LocalMediaPreprocessingJob,
        outputByteCount: Int,
        now: Date = Date()
    ) -> Bool {
        guard expectedJob.isStructurallyValid,
              KitChatMediaLimits.fits(
                  outputByteCount,
                  kind: KitChatMediaKind(mediaType: expectedJob.outputMediaType)
              ),
              var records = message.localMediaRecords
        else { return false }
        let indices = records.indices.filter { records[$0].id == attachmentID }
        guard indices.count == 1, let index = indices.first else { return false }
        var record = records[index]
        guard record.messageID == message.id,
              record.conversationID == message.conversationId,
              record.isStructurallyValid,
              record.preprocessingJob == expectedJob,
              record.originalSources == expectedJob.sources
        else { return false }

        var nextPendingAttachment = message.pendingAttachment
        var nextPendingBatch = message.pendingMediaBatch
        if var pending = nextPendingAttachment {
            guard nextPendingBatch == nil,
                  pending.localStorageKey == record.localStorageKey,
                  pending.mediaType == expectedJob.outputMediaType,
                  pending.byteCount == record.fileSize
            else { return false }
            pending.mediaType = expectedJob.outputMediaType
            pending.localStorageKey = expectedJob.outputStorageKey
            pending.byteCount = outputByteCount
            nextPendingAttachment = pending
        } else if var batch = nextPendingBatch {
            let itemIndices = batch.items.indices.filter {
                batch.items[$0].attachmentID == attachmentID
            }
            guard itemIndices.count == 1, let itemIndex = itemIndices.first else { return false }
            let item = batch.items[itemIndex]
            guard item.localStorageKey == record.localStorageKey,
                  item.mediaType == expectedJob.outputMediaType,
                  item.plaintextByteSize == record.fileSize,
                  let processed = item.preprocessed(
                      storageKey: expectedJob.outputStorageKey,
                      mediaType: expectedJob.outputMediaType,
                      plaintextByteSize: outputByteCount
                  )
            else { return false }
            batch.items[itemIndex] = processed
            guard batch.isStructurallyValid else { return false }
            nextPendingBatch = batch
        } else {
            return false
        }

        record.localStorageKind = .protectedFile
        record.localStorageKey = expectedJob.outputStorageKey
        record.mediaType = expectedJob.outputMediaType
        record.fileSize = outputByteCount
        record.preprocessingJob = nil
        record.processingState = .ready
        record.uploadState = .pending
        record.encryptionState = .pending
        record.availabilityState = .localOriginal
        record.updatedAt = now
        guard record.isStructurallyValid else { return false }
        records[index] = record
        message.localMediaRecords = records
        message.pendingAttachment = nextPendingAttachment
        message.pendingMediaBatch = nextPendingBatch
        return true
    }

    static func markPreprocessingStarted(
        _ message: inout LocalMessage,
        attachmentID: String,
        expectedJob: LocalMediaPreprocessingJob,
        now: Date = Date()
    ) -> Bool {
        mutate(&message, attachmentID: attachmentID) { record in
            guard record.preprocessingJob == expectedJob,
                  record.uploadState == .pending,
                  record.encryptionState == .pending
            else { return false }
            record.processingState = .processing
            record.updatedAt = now
            return true
        }
    }

    static func markPreprocessingFailed(
        _ message: inout LocalMessage,
        attachmentID: String,
        expectedJob: LocalMediaPreprocessingJob,
        now: Date = Date()
    ) -> Bool {
        mutate(&message, attachmentID: attachmentID) { record in
            guard record.preprocessingJob == expectedJob else { return false }
            record.processingState = .failed
            record.updatedAt = now
            return true
        }
    }

    static func markUploadFailed(_ message: inout LocalMessage, now: Date = Date()) {
        guard var records = message.localMediaRecords else { return }
        for index in records.indices where records[index].direction == .sent {
            guard records[index].uploadState != .uploaded else { continue }
            records[index].processingState = .failed
            records[index].uploadState = .failed
            records[index].encryptionState = records[index].ciphertextSpoolByteSize == nil
                ? .failed
                : .encrypted
            records[index].updatedAt = now
        }
        message.localMediaRecords = records
    }

    private static func mutate(
        _ message: inout LocalMessage,
        attachmentID: String,
        mutation: (inout LocalMediaRecord) -> Bool
    ) -> Bool {
        guard var records = message.localMediaRecords else { return false }
        let indices = records.indices.filter { records[$0].id == attachmentID }
        guard indices.count == 1, let index = indices.first,
              records[index].messageID == message.id,
              records[index].conversationID == message.conversationId,
              records[index].isStructurallyValid
        else { return false }
        var record = records[index]
        guard mutation(&record), record.isStructurallyValid else { return false }
        records[index] = record
        message.localMediaRecords = records
        return true
    }

    private static func canonicalUUID(_ raw: String?) -> String? {
        guard let raw,
              let uuid = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return uuid.uuidString.lowercased()
    }
}

extension LocalMessage {
    /// The collision namespace is wider than the plaintext files returned by
    /// `localMediaStorageKeys`: ciphertext spools are addressed by `LocalMediaRecord.id`, and a
    /// remote or partially damaged row can claim a key before it has a local representation.
    /// Queue/draft admission uses this fail-closed ownership set; deletion deliberately continues
    /// to use the narrower structurally validated storage-key set below.
    var localMediaOwnershipClaims: [String: Set<String>] {
        var claims: [String: Set<String>] = [:]
        func canonical(_ raw: String?) -> String? {
            raw.flatMap { UUID(uuidString: $0)?.uuidString.lowercased() }
        }
        func claim(_ rawKey: String?, owner rawOwner: String?) {
            guard let key = canonical(rawKey) else { return }
            // Empty is a fail-closed owner for malformed legacy state that names a valid cache
            // key but cannot bind that key to one canonical attachment identity.
            let owner = canonical(rawOwner) ?? ""
            claims[key, default: []].insert(owner)
        }
        for record in localMediaRecords ?? [] {
            claim(record.id, owner: record.id)
            for key in [
                record.localStorageKey,
                record.remoteEncryptedObjectID,
                record.preprocessingJob?.outputStorageKey,
                record.resumableUpload?.storageKey,
            ] {
                claim(key, owner: record.id)
            }
            for source in record.originalSources ?? [] {
                claim(source.storageKey, owner: record.id)
            }
        }
        if let pending = pendingAttachment?.localStorageKey {
            let matchingOwners = Set((localMediaRecords ?? []).compactMap { record -> String? in
                canonical(record.localStorageKey) == canonical(pending)
                    ? canonical(record.id)
                    : nil
            })
            if matchingOwners.count == 1, let owner = matchingOwners.first {
                claim(pending, owner: owner)
            } else {
                claim(pending, owner: nil)
            }
        }
        if let batch = pendingMediaBatch {
            for item in batch.items {
                claim(item.attachmentID, owner: item.attachmentID)
                claim(item.localStorageKey, owner: item.attachmentID)
                claim(item.storageKey, owner: item.attachmentID)
            }
        }
        if let descriptor = KitMediaMessageDescriptor.parse(body) {
            claim(descriptor.attachmentID, owner: descriptor.attachmentID)
            claim(descriptor.storageKey, owner: descriptor.attachmentID)
        }
        if let descriptor = KitMediaMessageV2Descriptor.parse(body) {
            for item in descriptor.items {
                claim(item.attachmentID, owner: item.attachmentID)
                claim(item.storageKey, owner: item.attachmentID)
            }
        }
        return claims
    }

    var localMediaOwnershipKeys: [String] {
        localMediaOwnershipClaims.keys.sorted()
    }

    /// Every key this message may hold media under in the encrypted file cache, across both
    /// media generations and every outbound phase: the v1 pending park key, a sealed v1
    /// descriptor's storage key, every v2 batch park/checkpoint key, and every storage key of a
    /// sealed v2 descriptor. Local deletion and scheduled-send cancellation must remove exactly
    /// this set — enumerating any less leaves recoverable media behind after a local delete.
    var localMediaStorageKeys: [String] {
        var keys: [String] = []
        keys.append(contentsOf: (localMediaRecords ?? []).compactMap { record in
            record.isStructurallyValid ? record.localStorageKey : nil
        })
        keys.append(contentsOf: (localMediaRecords ?? []).flatMap { record in
            guard record.isStructurallyValid else { return [String]() }
            var owned = record.originalSources?.map(\.storageKey) ?? []
            if let output = record.preprocessingJob?.outputStorageKey { owned.append(output) }
            return owned
        })
        if let parked = pendingAttachment?.localStorageKey { keys.append(parked) }
        // Structural gate before trusting any batch key field: a corrupt batch's keys are
        // arbitrary persisted bytes that can name blobs owned by *other* messages even while
        // individually canonical-shaped, so deletion driven by them could destroy another
        // conversation's cached media. Fail closed; retiring the damaged row is the visible
        // path for its own residue.
        if let batch = pendingMediaBatch, batch.isStructurallyValid {
            keys.append(contentsOf: batch.allLocalStorageKeys)
        }
        if let v1 = KitMediaMessageDescriptor.parse(body) { keys.append(v1.storageKey) }
        if let v2 = KitMediaMessageV2Descriptor.parse(body) {
            keys.append(contentsOf: v2.items.map { $0.storageKey })
        }
        // Only canonical lowercase UUIDs may reach the file cache: damaged persisted state must
        // never turn local deletion into removal under a malformed or attacker-shaped key.
        var seen = Set<String>()
        return keys.filter {
            UUID(uuidString: $0)?.uuidString.lowercased() == $0 && seen.insert($0).inserted
        }
    }
}

/// A server object key paired with the permanent client attachment that is allowed to own it.
/// Bare storage keys are deliberately insufficient at a persistence boundary: without the
/// attachment identity a same-message sibling alias is indistinguishable from a valid retry.
struct LocalMediaStorageBinding: Hashable, Sendable {
    let attachmentID: String
    let storageKey: String
}

/// Account-wide admission for server-issued media object keys.
///
/// The policy is evaluated inside the same `SecureLocalStore.update` that replaces a message.
/// A fresh or replacement key must have no current owner anywhere. An already-checkpointed key
/// may be repeated only by the exact target record's server fields and its paired batch/wire
/// projection. Client ids, plaintext keys, preprocessing inputs/outputs, sibling attachments,
/// other messages, and active drafts can never be reinterpreted as server storage.
enum LocalMediaStorageOwnershipPolicy {
    static func permitsTransition(
        from current: LocalMessage,
        to proposed: LocalMessage,
        in state: PersistedState
    ) -> Bool {
        guard current.id == proposed.id,
              current.conversationId == proposed.conversationId,
              current.senderId == proposed.senderId,
              current.isOutgoing,
              proposed.isOutgoing,
              state.messages.filter({ $0.id == current.id }) == [current],
              let storageBindings = bindings(in: proposed)
        else { return false }

        let draftKeys = ConversationDraftPolicy.localMediaStorageKeysOwnedByDrafts(in: state)
        for binding in storageBindings {
            guard !draftKeys.contains(binding.storageKey),
                  proposedClaimsOnlyTargetServerRoles(
                      binding.storageKey,
                      attachmentID: binding.attachmentID,
                      in: proposed
                  ),
                  state.messages.allSatisfy({ message in
                      message.id == current.id
                          || message.localMediaOwnershipClaims[binding.storageKey] == nil
                  })
            else { return false }

            let currentTargetRecords = (current.localMediaRecords ?? []).filter {
                $0.id == binding.attachmentID
                    && $0.messageID == current.id
                    && $0.conversationID == current.conversationId
                    && $0.direction == .sent
            }
            let wasCheckpointedByTarget = currentTargetRecords.count == 1
                && currentTargetRecords.contains(where: { record in
                    record.resumableUpload?.storageKey == binding.storageKey
                        || record.remoteEncryptedObjectID == binding.storageKey
                })
            if wasCheckpointedByTarget {
                guard proposedClaimsOnlyTargetServerRoles(
                    binding.storageKey,
                    attachmentID: binding.attachmentID,
                    in: current
                ) else { return false }
            } else {
                // This is the first admission of a server key, or a lease replacement. Even a
                // target attachment's own client id/source/output is an existing owner here.
                guard current.localMediaOwnershipClaims[binding.storageKey] == nil else {
                    return false
                }
            }
        }
        return true
    }

    /// Derives bindings from the complete proposed projection rather than trusting arguments at
    /// a call site. Every persisted server reference must agree on one attachment owner, and an
    /// attachment may not name two server objects in one state transition.
    static func bindings(in message: LocalMessage) -> [LocalMediaStorageBinding]? {
        var ownerByKey: [String: String] = [:]
        var keyByOwner: [String: String] = [:]

        func add(_ rawKey: String?, owner rawOwner: String) -> Bool {
            guard let rawKey,
                  let key = canonical(rawKey), key == rawKey,
                  let owner = canonical(rawOwner), owner == rawOwner,
                  ownerByKey[key].map({ $0 == owner }) ?? true,
                  keyByOwner[owner].map({ $0 == key }) ?? true
            else { return false }
            ownerByKey[key] = owner
            keyByOwner[owner] = key
            return true
        }

        for record in message.localMediaRecords ?? [] where record.direction == .sent {
            if record.resumableUpload?.storageKey != nil,
               !add(record.resumableUpload?.storageKey, owner: record.id) {
                return nil
            }
            if record.remoteEncryptedObjectID != nil,
               !add(record.remoteEncryptedObjectID, owner: record.id) {
                return nil
            }
        }
        if let batch = message.pendingMediaBatch {
            guard batch.isStructurallyValid else { return nil }
            for item in batch.items where item.storageKey != nil {
                guard add(item.storageKey, owner: item.attachmentID) else { return nil }
            }
        }
        if let descriptor = KitMediaMessageDescriptor.parse(message.body) {
            guard add(descriptor.storageKey, owner: descriptor.attachmentID) else { return nil }
        }
        if let descriptor = KitMediaMessageV2Descriptor.parse(message.body) {
            for item in descriptor.items {
                guard add(item.storageKey, owner: item.attachmentID) else { return nil }
            }
        }

        let bindings = ownerByKey.map {
            LocalMediaStorageBinding(attachmentID: $0.value, storageKey: $0.key)
        }.sorted {
            if $0.attachmentID == $1.attachmentID {
                return $0.storageKey < $1.storageKey
            }
            return $0.attachmentID < $1.attachmentID
        }
        for binding in bindings {
            let targetRecords = (message.localMediaRecords ?? []).filter {
                $0.id == binding.attachmentID
                    && $0.messageID == message.id
                    && $0.conversationID == message.conversationId
                    && $0.direction == .sent
                    && $0.isStructurallyValid
            }
            guard targetRecords.count == 1,
                  targetRecords.contains(where: { record in
                      record.resumableUpload?.storageKey == binding.storageKey
                          || record.remoteEncryptedObjectID == binding.storageKey
                  })
            else { return nil }
        }
        return bindings
    }

    private static func proposedClaimsOnlyTargetServerRoles(
        _ storageKey: String,
        attachmentID: String,
        in message: LocalMessage
    ) -> Bool {
        func matches(_ raw: String?) -> Bool {
            canonical(raw) == storageKey
        }

        for record in message.localMediaRecords ?? [] {
            // These are client-owned roles even when they belong to the target attachment.
            if matches(record.id)
                || matches(record.localStorageKey)
                || matches(record.preprocessingJob?.outputStorageKey)
                || (record.originalSources ?? []).contains(where: {
                    matches($0.storageKey)
                }) {
                return false
            }
            if matches(record.resumableUpload?.storageKey), record.id != attachmentID {
                return false
            }
            if matches(record.remoteEncryptedObjectID), record.id != attachmentID {
                return false
            }
        }
        if matches(message.pendingAttachment?.localStorageKey) { return false }
        if let batch = message.pendingMediaBatch {
            for item in batch.items {
                if matches(item.attachmentID) || matches(item.localStorageKey) { return false }
                if matches(item.storageKey), item.attachmentID != attachmentID { return false }
            }
        }
        if let descriptor = KitMediaMessageDescriptor.parse(message.body) {
            if matches(descriptor.attachmentID) { return false }
            if matches(descriptor.storageKey), descriptor.attachmentID != attachmentID {
                return false
            }
        }
        if let descriptor = KitMediaMessageV2Descriptor.parse(message.body) {
            for item in descriptor.items {
                if matches(item.attachmentID) { return false }
                if matches(item.storageKey), item.attachmentID != attachmentID { return false }
            }
        }
        return true
    }

    private static func canonical(_ raw: String?) -> String? {
        guard let raw, let uuid = UUID(uuidString: raw) else { return nil }
        return uuid.uuidString.lowercased()
    }
}

/// The identity step of every secure media load. Views hand loaders nothing but identity — a
/// message UUID, its conversation, and (for a multi-attachment message) the display index —
/// and this policy resolves that identity against the CURRENT persisted rows: exactly one row
/// must match, its body (or pending batch) is parsed and gated fresh, and the index is bounds-
/// checked, all before any cache is consulted. A snapshot a view captured earlier — an entire
/// `LocalMessage`, or worse its raw descriptor text — can therefore never serve bytes for a
/// message that has since been deleted, replaced, or rewritten, and no caller-supplied wire
/// text ever reaches the verifying open paths. Anything that does not resolve cleanly is nil:
/// fail closed, surface nothing.
enum SecureMediaLoadPolicy {
    enum Resolved: Equatable {
        /// One legacy-format attachment still queued locally. It is intentionally part of the
        /// common identity resolver so media-library and presentation surfaces do not need a
        /// network-only special case while upload is pending.
        case pendingSingle(ResolvedPendingSingle)
        /// A sealed single-attachment (KITMEDIA1) message. `descriptorText` is the current
        /// persisted body re-read here — the one string the legacy open path may see — and
        /// `inlineData` is the v1 inline plaintext slot, when the row still carries it.
        case single(
            descriptor: KitMediaMessageDescriptor,
            descriptorText: String,
            inlineData: Data?
        )
        /// One §8-ordered item of a batch still pending upload, addressed by index into its
        /// complete logical projection: the whole structurally valid batch plus the row body
        /// bound to it. Pending plaintext lives only in the local encrypted cache; there is
        /// nothing on the server bound to this message yet.
        case pendingBatchItem(
            batch: KitMediaMessageV2OutboundBatch,
            body: String,
            itemIndex: Int
        )
        /// One §8-ordered item of a sealed KITMEDIA2 message, addressed by index into the
        /// complete sealed projection: the parsed descriptor plus the exact body it came from.
        case sealedBatchItem(
            descriptor: KitMediaMessageV2Descriptor,
            descriptorText: String,
            itemIndex: Int
        )
    }
    // The batch cases deliberately carry the whole message projection rather than the selected
    // item: a loader's post-await revalidation compares entire resolutions, and equality must
    // fail when a replacement row preserves the one selected item while changing the shared
    // caption or any sibling. Consumers derive the item by subscripting the carried projection
    // with the carried index (bounds-proven at resolution).

    /// `itemIndex` nil addresses the single-attachment (v1) shape; non-nil addresses one item
    /// of a multi-attachment batch. A version/shape mismatch, a missing or duplicated row, a
    /// structurally invalid pending batch, an unparseable body, or an out-of-bounds index all
    /// resolve to nil.
    static func resolve(
        messageID: UUID,
        conversationId: String,
        itemIndex: Int?,
        in messages: [LocalMessage]
    ) -> Resolved? {
        let rows = messages.filter {
            $0.id == messageID && $0.conversationId == conversationId
        }
        guard rows.count == 1, let row = rows.first else { return nil }
        if let itemIndex {
            if let batch = row.pendingMediaBatch {
                // A pending row is coherent only in the exact shape the queue wrote: no v1
                // pending slot, no inline v1 bytes, and a body that is the batch caption (or
                // the content-free placeholder) — nothing else. A row where a v1 shape and a
                // v2 batch coexist, or whose body stopped being bound to its own batch, is
                // damaged or forged state; serve nothing from it.
                guard batch.isStructurallyValid,
                      row.pendingAttachment == nil,
                      row.attachmentData == nil,
                      row.body == (batch.caption
                          ?? SecureMessagingExchangeCoordinator.mediaBatchPlaceholderBody(
                              itemCount: batch.items.count
                          )),
                      batch.items.indices.contains(itemIndex)
                else { return nil }
                return .pendingBatchItem(batch: batch, body: row.body, itemIndex: itemIndex)
            }
            // Sealed batch items are never stored inline — `attachmentData` is the v1 slot —
            // so a sealed v2 row carrying either v1 field is likewise incoherent.
            guard row.pendingAttachment == nil,
                  row.attachmentData == nil,
                  let descriptor = KitMediaMessageV2Descriptor.parse(row.body),
                  descriptor.items.indices.contains(itemIndex)
            else { return nil }
            return .sealedBatchItem(
                descriptor: descriptor,
                descriptorText: row.body,
                itemIndex: itemIndex
            )
        }
        if let pending = resolvePendingSingle(
            messageID: messageID,
            conversationId: conversationId,
            in: messages
        ) {
            return .pendingSingle(pending)
        }
        guard row.pendingAttachment == nil,
              row.pendingMediaBatch == nil,
              let descriptor = KitMediaMessageDescriptor.parse(row.body)
        else { return nil }
        // The inline slot is trusted only at the exact declared plaintext size: a truncated
        // write or foreign bytes on a rewritten row must fall through to the verifying open
        // paths rather than display as this attachment.
        return .single(
            descriptor: descriptor,
            descriptorText: row.body,
            inlineData: row.attachmentData.flatMap {
                $0.count == descriptor.plaintextByteSize ? $0 : nil
            }
        )
    }

    /// Plaintext bytes together with the display facts of the row they were resolved from.
    /// Consumers that go on to re-encode media (forward, share) must take the MIME type and
    /// caption from here — bound to the same authoritative resolution that produced the bytes —
    /// never from a row snapshot captured earlier, where only the bytes would be current.
    struct LoadedItem {
        let data: Data
        /// Non-nil for a sender-owned protected original or persisted receiver cache. `data` is
        /// empty in that case so large local media presentation remains bounded-memory.
        let localFileURL: URL?
        /// Retains receiver-cache ownership while a file-backed presentation keeps this value.
        /// Sender originals are never eviction candidates, but use the same shape for callers.
        let localFileLease: SecureMediaOriginalAccessLease?
        let byteCount: Int
        let mediaType: String
        /// The v1 message caption. nil for batch items: a batch caption belongs to the whole
        /// message, and forwarding one item must never smuggle the message's text with it.
        let caption: String?

        init(data: Data, mediaType: String, caption: String?) {
            self.data = data
            localFileURL = nil
            localFileLease = nil
            byteCount = data.count
            self.mediaType = mediaType
            self.caption = caption
        }

        init(localFile: LocalFileItem) {
            data = Data()
            localFileURL = localFile.url
            localFileLease = localFile.accessLease
            byteCount = localFile.byteCount
            mediaType = localFile.mediaType
            caption = localFile.caption
        }
    }

    /// A direct lease on a sender-owned protected original. Large video/document UI uses this
    /// instead of materializing `LoadedItem.data`; identity is resolved and revalidated by the
    /// model before the URL is returned.
    struct LocalFileItem {
        let url: URL
        let mediaType: String
        let caption: String?
        let byteCount: Int
        let attachmentID: String
        let accessLease: SecureMediaOriginalAccessLease?

        init(
            url: URL,
            mediaType: String,
            caption: String?,
            byteCount: Int,
            attachmentID: String,
            accessLease: SecureMediaOriginalAccessLease? = nil
        ) {
            self.url = url
            self.mediaType = mediaType
            self.caption = caption
            self.byteCount = byteCount
            self.attachmentID = attachmentID
            self.accessLease = accessLease
        }
    }

    struct LocalVoicePlayback: Sendable {
        let fileURLs: [URL]
        let segmentDurations: [TimeInterval]
        let attachmentID: String

        var isStructurallyValid: Bool {
            !fileURLs.isEmpty
                && fileURLs.count == segmentDurations.count
                && segmentDurations.allSatisfy { $0.isFinite && $0 > 0 }
                && UUID(uuidString: attachmentID)?.uuidString.lowercased() == attachmentID
        }
    }

    /// A single-attachment (KITMEDIA1) message still waiting for upload. Exactly one storage
    /// form is ever populated: the small-media inline slot, or the canonical encrypted-cache
    /// park key for large media. `expectedByteCount` is the declared plaintext size; the parked
    /// form requires it (every cache read is pinned to it), while inline rows written by builds
    /// that predate the size field may carry nil — their bytes live on the identity-resolved
    /// row itself and cannot alias another blob.
    ///
    /// This is the complete authoritative pending projection, not just the storage locator:
    /// post-await equality compares whole values, and it must fail when a replacement row
    /// reuses the storage form while changing the MIME type, caption, or bound body. Display
    /// facts shown with the loaded bytes must come from this same value.
    struct ResolvedPendingSingle: Equatable {
        let attachmentID: String
        let inlineData: Data?
        let localStorageKey: String?
        let expectedByteCount: Int?
        let mediaType: String
        let caption: String?
        /// The row body the resolution validated (the caption, or the kind's preview label).
        let body: String
    }

    /// Identity resolution for the pending single-attachment shape, under the same rule as
    /// `resolve`: exactly one current row, gated fresh at load time. A row that has since
    /// sealed, vanished, duplicated, or grown a coexisting batch resolves to nil — and so does
    /// every shape no queue writer produces: both storage forms or neither, a non-canonical
    /// park key, a body no longer bound to the attachment's own caption or preview label, a
    /// declared size outside the transfer bounds, or inline bytes that contradict it.
    static func resolvePendingSingle(
        messageID: UUID,
        conversationId: String,
        in messages: [LocalMessage]
    ) -> ResolvedPendingSingle? {
        let rows = messages.filter {
            $0.id == messageID && $0.conversationId == conversationId
        }
        guard rows.count == 1, let row = rows.first,
              let pending = row.pendingAttachment,
              row.pendingMediaBatch == nil,
              // The queue writes the caption as the body, or the kind's preview label when
              // there is none. A pending row whose body stopped being bound to its own
              // attachment facts is damaged or forged state; serve nothing from it.
              row.body == (pending.caption
                  ?? KitChatMediaKind(mediaType: pending.mediaType).previewLabel)
        else { return nil }
        // The MIME type must be one this wire actually carries — `KitChatMediaKind` classifies
        // any string into a bucket and the size check is kind-agnostic, so without this gate a
        // forged pending row could smuggle an arbitrary type through to display and forward.
        guard SecureMessagingWire.allowedAttachmentMediaTypes.contains(pending.mediaType)
        else { return nil }
        let kind = KitChatMediaKind(mediaType: pending.mediaType)
        if let declared = pending.byteCount,
           !KitChatMediaLimits.fits(declared, kind: kind) {
            return nil
        }
        let records = (row.localMediaRecords ?? []).filter { record in
            record.messageID == row.id
                && record.conversationID == row.conversationId
                && record.direction == .sent
                && record.mediaType == pending.mediaType
                && (pending.byteCount.map { $0 == record.fileSize } ?? true)
                && record.isStructurallyValid
        }
        guard records.count <= 1 else { return nil }
        let attachmentID = records.first?.id ?? row.id.uuidString.lowercased()
        switch (row.attachmentData, pending.localStorageKey) {
        case (let inline?, nil):
            guard KitChatMediaLimits.shouldCacheInline(byteCount: inline.count),
                  pending.byteCount.map({ $0 == inline.count }) ?? true
            else { return nil }
            return ResolvedPendingSingle(
                attachmentID: attachmentID,
                inlineData: inline,
                localStorageKey: nil,
                expectedByteCount: pending.byteCount,
                mediaType: pending.mediaType,
                caption: pending.caption,
                body: row.body
            )
        case (nil, let key?):
            // Parked bytes come back through the shared encrypted cache, so the key must be
            // canonical and the declared size present — a legacy row with no declared size
            // never serves cache bytes unpinned.
            guard UUID(uuidString: key)?.uuidString.lowercased() == key,
                  let declared = pending.byteCount
            else { return nil }
            return ResolvedPendingSingle(
                attachmentID: attachmentID,
                inlineData: nil,
                localStorageKey: key,
                expectedByteCount: declared,
                mediaType: pending.mediaType,
                caption: pending.caption,
                body: row.body
            )
        default:
            return nil
        }
    }
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
    /// Server-visible group description. Optional with a default for the same reason as
    /// `conversationType`: encrypted state written by earlier builds must stay decodable.
    var groupDescription: String? = nil
    /// The group photo's public content address; nil shows the generated group avatar.
    var groupPhotoURL: String? = nil
    /// Authenticated public identity metadata for active members. Optional keeps state written by
    /// older builds readable and lets clients fall back to the synchronized contact directory.
    var memberIdentities: [String: AccountIdentityProjection]? = nil

    var isGroup: Bool { conversationType == SecureMessagingWire.groupConversationType }

    func groupRole(for userID: String?) -> MessagingGroupRole? {
        guard let userID else { return nil }
        return groupMemberRoles?[userID.lowercased()]
    }

    func memberIdentity(for userID: String?) -> AccountIdentityProjection? {
        guard let userID,
              userID == userID.trimmingCharacters(in: .whitespacesAndNewlines),
              let identifier = UUID(uuidString: userID)
        else { return nil }
        guard let identity = memberIdentities?[identifier.uuidString.lowercased()],
              identity.isValid
        else { return nil }
        return identity
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
    /// Viewer-safe public identities for the authenticated participant roster. Older call rows
    /// omit this and resolve through contacts exactly as before.
    var participantIdentities: [String: AccountIdentityProjection]? = nil

    /// Android treats either authenticated signal as authoritative. This also keeps media type
    /// stable when an older or partially deployed backend sends a contradictory optional flag.
    var isVideoCall: Bool {
        video || type.caseInsensitiveCompare("video") == .orderedSame
    }
}

struct CallParticipantDTO: Decodable, Equatable, Sendable {
    let userId: String?
    let name: String?
    let avatarUrl: String?
    let verification: AccountVerificationDTO?

    private enum CodingKeys: String, CodingKey {
        case name, verification
        case userId = "user_id"
        case avatarUrl = "avatar_url"
    }

    init(
        userId: String? = nil,
        name: String? = nil,
        avatarUrl: String? = nil,
        verification: AccountVerificationDTO? = nil
    ) {
        self.userId = userId
        self.name = name
        self.avatarUrl = avatarUrl
        self.verification = verification
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        userId = try? values.decode(String.self, forKey: .userId)
        name = try? values.decode(String.self, forKey: .name)
        avatarUrl = try? values.decode(String.self, forKey: .avatarUrl)
        verification = try? values.decode(AccountVerificationDTO.self, forKey: .verification)
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
    let participants: [CallParticipantDTO]?

    enum CodingKeys: String, CodingKey {
        case id, name, direction, type, video, state
        case conversationId = "conversation_id"
        case participantUserIds = "participant_user_ids"
        case startedAt = "started_at"
        case answeredAt = "answered_at"
        case endedAt = "ended_at"
        case ringExpiresAt = "ring_expires_at"
        case participants
    }

    init(
        id: String,
        conversationId: String?,
        name: String?,
        participantUserIds: [String]?,
        direction: String,
        type: String,
        video: Bool?,
        state: String,
        startedAt: String,
        answeredAt: String?,
        endedAt: String?,
        ringExpiresAt: String?,
        participants: [CallParticipantDTO]? = nil
    ) {
        self.id = id
        self.conversationId = conversationId
        self.name = name
        self.participantUserIds = participantUserIds
        self.direction = direction
        self.type = type
        self.video = video
        self.state = state
        self.startedAt = startedAt
        self.answeredAt = answeredAt
        self.endedAt = endedAt
        self.ringExpiresAt = ringExpiresAt
        self.participants = participants
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        conversationId = try values.decodeIfPresent(String.self, forKey: .conversationId)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        participantUserIds = try values.decodeIfPresent([String].self, forKey: .participantUserIds)
        direction = try values.decode(String.self, forKey: .direction)
        type = try values.decode(String.self, forKey: .type)
        video = try values.decodeIfPresent(Bool.self, forKey: .video)
        state = try values.decode(String.self, forKey: .state)
        startedAt = try values.decode(String.self, forKey: .startedAt)
        answeredAt = try values.decodeIfPresent(String.self, forKey: .answeredAt)
        endedAt = try values.decodeIfPresent(String.self, forKey: .endedAt)
        ringExpiresAt = try values.decodeIfPresent(String.self, forKey: .ringExpiresAt)
        // This is additive presentation metadata. A malformed optional projection must not hide
        // an otherwise valid call; validation below simply declines to grant it identity data.
        participants = try? values.decode([CallParticipantDTO].self, forKey: .participants)
    }

    var isVideoCall: Bool {
        video == true || type.caseInsensitiveCompare("video") == .orderedSame
    }
}

enum CallParticipantIdentityPolicy {
    static func validated(
        _ participants: [CallParticipantDTO]?,
        matching rawParticipantUserIDs: [String]?
    ) -> [String: AccountIdentityProjection]? {
        guard let participants,
              let rawParticipantUserIDs,
              !participants.isEmpty,
              participants.count == rawParticipantUserIDs.count
        else { return nil }

        let roster = rawParticipantUserIDs.compactMap(canonicalUserID)
        guard roster.count == rawParticipantUserIDs.count,
              Set(roster).count == roster.count
        else { return nil }

        var identities: [String: AccountIdentityProjection] = [:]
        var participantIDs: Set<String> = []
        for participant in participants {
            guard let userID = canonicalUserID(participant.userId),
                  participantIDs.insert(userID).inserted
            else { return nil }
            if let identity = AccountIdentityProjection(
                displayName: participant.name,
                avatarURL: participant.avatarUrl,
                verification: participant.verification
            ) {
                identities[userID] = identity
            }
        }
        guard participantIDs == Set(roster) else { return nil }
        return identities.isEmpty ? nil : identities
    }

    private static func canonicalUserID(_ rawValue: String?) -> String? {
        guard let rawValue,
              rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
              let identifier = UUID(uuidString: rawValue)
        else { return nil }
        return identifier.uuidString.lowercased()
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
    /// Set only after the idempotent server create returned an exact, validated request. The
    /// schedule command remains durable with this receipt until the matching encrypted chat card
    /// is also durable, closing the crash window between those two commits.
    var confirmedRequest: ScheduledPaymentRequestConfirmation? = nil
}

struct ScheduledPaymentRequestConfirmation: Codable, Hashable, Sendable {
    let requestID: String
    let encodedDescriptor: String

    var clientMessageID: UUID? { UUID(uuidString: requestID) }

    init?(
        request: PaymentRequestDTO,
        payload: ScheduledPaymentRequestPayload
    ) {
        guard let requestID = Self.canonicalUUID(request.id),
              let recipientID = Self.canonicalUUID(request.requestedFromUserId),
              recipientID == Self.canonicalUUID(payload.requestedFromUserID),
              request.type == "payment_request",
              request.knownStatus == .pending,
              request.destinationWalletId == payload.destinationWalletID,
              request.currency.code == payload.currencyCode,
              request.amount == payload.amount,
              request.note == payload.note,
              let descriptor = KitPaymentMessage(action: .request, paymentRequest: request)
        else { return nil }
        self.requestID = requestID
        encodedDescriptor = descriptor.encoded
    }

    func isValid(for payload: ScheduledPaymentRequestPayload) -> Bool {
        guard let requestID = Self.canonicalUUID(requestID),
              let clientMessageID,
              clientMessageID.uuidString.lowercased() == requestID,
              let descriptor = KitPaymentMessage.parse(encodedDescriptor),
              descriptor.action == .request,
              descriptor.paymentRequestId == requestID,
              descriptor.currencyCode == payload.currencyCode,
              KitPaymentMessage.minorUnits(
                  for: payload.amount,
                  scale: descriptor.currencyScale
              ) == descriptor.amountMinor,
              descriptor.note == payload.note
        else { return false }
        return true
    }

    private static func canonicalUUID(_ value: String?) -> String? {
        guard let value,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              let uuid = UUID(uuidString: value)
        else { return nil }
        return uuid.uuidString.lowercased()
    }
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
    /// A visible, durable local-first message can exist before image optimization or voice
    /// assembly finishes. Such a command is deliberately excluded from FIFO head selection, so
    /// later text/media in the same conversation remains sendable while local CPU work proceeds.
    var awaitingMediaPreprocessing: Bool? = nil
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
    /// When this account was first seen to have a settled money-moving transaction, recorded at
    /// the server-confirmed transactions write. `transactions` holds only the latest page of the
    /// selected wallet, so an account-wide "has ever transacted" milestone must not be recomputed
    /// from it — once true it stays true here. Optional keeps older encrypted state decodable.
    var starterFirstTransactionAt: Date? = nil
    /// Same idea for the first genuinely sent message: chat deletion or history pagination must
    /// not resurrect the starter checklist. Optional for the same decodability reason.
    var starterFirstMessageAt: Date? = nil
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

    /// Replaces every cached balance with the authenticated bootstrap projection. Wallet balances
    /// are server-owned; retaining an older local entry by id would show stale money after another
    /// device changed the account while this installation was in the background.
    mutating func replaceAuthoritativeWalletProjection(
        _ authoritativeWallets: [Wallet],
        selectedWalletID: String?
    ) {
        let previousSelectedWalletID = selectedWalletId
        wallets = authoritativeWallets
        selectedWalletId = selectedWalletID
        if previousSelectedWalletID != selectedWalletID {
            transactions = []
        }
    }

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
            || starterFirstTransactionAt != nil
            || starterFirstMessageAt != nil

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
    static let maximumMediaAttachments = 8

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

    static func mediaAttachments(
        conversationID: String,
        ownerUserID: String,
        in state: PersistedState
    ) -> [ConversationDraftMediaAttachment] {
        guard owns(state, ownerUserID: ownerUserID),
              let conversationID = OutboxPolicy.canonicalConversationID(conversationID),
              state.conversations.contains(where: {
                  OutboxPolicy.canonicalConversationID($0.id) == conversationID
              }),
              let attachments = state.conversationDrafts?[conversationID]?.mediaAttachments,
              validMediaAttachments(attachments)
        else { return [] }
        return attachments
    }

    /// Every local media key still reserved by a composer draft. Queue admission may ignore only
    /// the exact, versioned draft that the same atomic state mutation will consume; a stale body,
    /// changed manifest, different conversation, or unrelated writer keeps all of its keys live.
    static func localMediaStorageKeysOwnedByDrafts(
        in state: PersistedState,
        excludingSubmittedDraftFor submittedConversationID: String? = nil,
        submittedBody: String? = nil,
        submittedMediaAttachments: [ConversationDraftMediaAttachment]? = nil,
        draftClearVersion: ConversationDraftWriteVersion? = nil,
        consumingStorageKeys: Set<String>? = nil
    ) -> Set<String> {
        let canonicalSubmittedConversationID = submittedConversationID.flatMap {
            OutboxPolicy.canonicalConversationID($0)
        }
        return Set((state.conversationDrafts ?? [:]).flatMap { entry -> [String] in
            let (conversationID, draft) = entry
            if let canonicalSubmittedConversationID,
               conversationID == canonicalSubmittedConversationID,
               isExactSubmittedDraft(
                   draft,
                   submittedBody: submittedBody,
                   submittedMediaAttachments: submittedMediaAttachments,
                   draftClearVersion: draftClearVersion,
                   consumingStorageKeys: consumingStorageKeys
               ) {
                return []
            }
            return draft.localMediaStorageKeys
        })
    }

    @discardableResult
    static func store(
        _ body: String,
        conversationID: String,
        ownerUserID: String,
        updatedAt: Date = Date(),
        writeVersion: ConversationDraftWriteVersion? = nil,
        mediaAttachments requestedMediaAttachments: [ConversationDraftMediaAttachment]? = nil,
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
        let mediaAttachments: [ConversationDraftMediaAttachment]?
        if let requestedMediaAttachments {
            guard validMediaAttachments(requestedMediaAttachments) else { return false }
            mediaAttachments = requestedMediaAttachments.isEmpty ? nil : requestedMediaAttachments
        } else {
            mediaAttachments = drafts[conversationID]?.mediaAttachments
        }
        if requestedMediaAttachments != nil, let mediaAttachments {
            let requestedKeys = Set(ConversationDraft(
                body: bounded,
                updatedAt: updatedAt,
                writeVersion: writeVersion,
                mediaAttachments: mediaAttachments
            ).localMediaStorageKeys)
            let otherDraftKeys = Set(drafts.flatMap { entry -> [String] in
                entry.key == conversationID ? [] : entry.value.localMediaStorageKeys
            })
            let messageKeys = Set(state.messages.flatMap(\.localMediaOwnershipKeys))
            guard otherDraftKeys.isDisjoint(with: requestedKeys),
                  messageKeys.isDisjoint(with: requestedKeys)
            else { return false }
        }
        let hasText = !bounded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !hasText, mediaAttachments == nil {
            if let writeVersion {
                // Keep an encrypted, bounded tombstone so a debounce task that was cancelled after
                // crossing an actor boundary cannot resurrect text cleared by a successful queue.
                drafts[conversationID] = ConversationDraft(
                    body: "",
                    updatedAt: updatedAt,
                    writeVersion: writeVersion,
                    mediaAttachments: nil
                )
                pruneOldestDrafts(&drafts, preserving: conversationID)
            } else {
                guard drafts.removeValue(forKey: conversationID) != nil else { return false }
            }
        } else {
            if drafts[conversationID]?.body == bounded,
               drafts[conversationID]?.mediaAttachments == mediaAttachments,
               drafts[conversationID]?.writeVersion == writeVersion {
                return false
            }
            drafts[conversationID] = ConversationDraft(
                body: bounded,
                updatedAt: updatedAt,
                writeVersion: writeVersion,
                mediaAttachments: mediaAttachments
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
        submittedMediaAttachments: [ConversationDraftMediaAttachment]? = nil,
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
        if let submittedMediaAttachments {
            guard validMediaAttachments(submittedMediaAttachments),
                  (existing?.mediaAttachments ?? []) == submittedMediaAttachments
            else { return false }
        } else if existing?.mediaAttachments?.isEmpty == false {
            // A media draft can be consumed only by a queue operation carrying its exact
            // manifest. A text-only or malformed caller must never orphan its local originals.
            return false
        }
        guard existing == nil || existing?.body == boundedBody(submittedBody),
              permits(writeVersion, replacing: existing)
        else { return false }
        if let writeVersion {
            drafts[conversationID] = ConversationDraft(
                body: "",
                updatedAt: Date(),
                writeVersion: writeVersion,
                mediaAttachments: nil
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

    private static func validMediaAttachments(
        _ attachments: [ConversationDraftMediaAttachment]
    ) -> Bool {
        guard attachments.count <= maximumMediaAttachments,
              attachments.allSatisfy(\.isStructurallyValid),
              Set(attachments.map(\.id)).count == attachments.count
        else { return false }
        let outputKeys = attachments.compactMap(\.preprocessingOutputStorageKey)
        let sourceKeys = Set(attachments.map(\.storageKey))
        return Set(outputKeys).count == outputKeys.count
            && sourceKeys.isDisjoint(with: outputKeys)
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

    private static func isExactSubmittedDraft(
        _ draft: ConversationDraft,
        submittedBody: String?,
        submittedMediaAttachments: [ConversationDraftMediaAttachment]?,
        draftClearVersion: ConversationDraftWriteVersion?,
        consumingStorageKeys: Set<String>?
    ) -> Bool {
        guard let submittedBody,
              let submittedMediaAttachments,
              validMediaAttachments(submittedMediaAttachments),
              draft.body == boundedBody(submittedBody),
              (draft.mediaAttachments ?? []) == submittedMediaAttachments,
              let existingVersion = draft.writeVersion,
              let draftClearVersion,
              draftClearVersion.writerID == existingVersion.writerID,
              draftClearVersion.sequence > existingVersion.sequence,
              let consumingStorageKeys,
              Set(draft.localMediaStorageKeys) == consumingStorageKeys
        else { return false }
        return true
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
                    && ($0.value.mediaAttachments?.isEmpty ?? true)
                let rhsIsTombstone = $1.value.body.isEmpty
                    && ($1.value.mediaAttachments?.isEmpty ?? true)
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
    /// The blended status the KYC screen renders: the backend overrides it with per-device
    /// verification, so it can read "pending" for a fully verified account on a new iPhone.
    let status: String
    /// The account's own identity status, independent of this device. Optional keeps older
    /// backend responses decodable; account-identity consumers (the Home starter checklist)
    /// read this first and fall back to the cached profile.
    let accountStatus: String?
    let `case`: KYCCase?
    let providerSession: KYCProviderSession?
    let documents: [KYCDocument]?
    let deviceVerification: DeviceIdentityAssuranceDTO?

    enum CodingKeys: String, CodingKey {
        case status, `case`, documents
        case accountStatus = "account_status"
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
