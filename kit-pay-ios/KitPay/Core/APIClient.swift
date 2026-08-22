import CryptoKit
import Foundation

/// Binds every nested authenticated request in an asynchronous operation to the server session
/// that authorized that operation. Task-local propagation covers coordinator layers without
/// allowing a sign-out/re-sign-in race to borrow the replacement account's credentials.
enum APIClientSessionBinding {
    @TaskLocal static var sessionID: String?
}

enum APIRequestAuthentication: Equatable, Sendable {
    case none
    case ifAvailable
    case required

    var readsCurrentSession: Bool { self != .none }
    var requiresCurrentSession: Bool { self == .required }
}

enum SecurityPreferencesAPIEndpoint: Equatable {
    case read
    case update

    var path: String { "auth/security-preferences" }

    var method: String {
        switch self {
        case .read: "GET"
        case .update: "PATCH"
        }
    }
}

actor APIClient {
    private struct SessionRefreshFlight {
        let id: UUID
        let sessionID: String
        let task: Task<SessionTokens, Error>
    }

    static let shared = APIClient(sessionStore: .shared)
    static let capabilitiesAuthentication: APIRequestAuthentication = .ifAvailable

    private let baseURL = URL(string: "https://pay.kit.africa/api/kit-wallet/v1/")!
    private let sessionStore: SessionStore
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private var refreshFlight: SessionRefreshFlight?

    init(sessionStore: SessionStore, session: URLSession = .shared) {
        self.sessionStore = sessionStore
        self.session = session
        decoder = JSONDecoder()
        encoder = JSONEncoder()
    }

    func capabilities() async throws -> CapabilitiesDTO {
        // Capabilities is public before sign-in, but the backend returns the authenticated user's
        // rollout/cohort projection when credentials are available. Sending this as a guest after
        // login incorrectly disables messaging and payment rails for enabled accounts.
        try await send(
            path: "capabilities",
            method: "GET",
            body: EmptyBody(),
            authentication: Self.capabilitiesAuthentication
        )
    }

    func loginWithEmail(
        email: String,
        password: String,
        device: DeviceRegistration
    ) async throws -> AuthResult {
        try await send(
            path: "auth/email/login",
            method: "POST",
            body: EmailLoginRequest(
                email: EmailAccountValidation.normalizeEmail(email),
                password: password,
                device: device
            ),
            authentication: .none
        )
    }

    func registerWithEmail(
        name: String,
        tag: String,
        email: String,
        password: String,
        passwordConfirmation: String,
        countryCode: String,
        locale: String,
        timezone: String
    ) async throws -> EmailRegistrationResult {
        try await send(
            path: "auth/email/register",
            method: "POST",
            body: EmailRegistrationRequest(
                name: EmailAccountValidation.normalizeName(name),
                tag: EmailAccountValidation.normalizeTag(tag),
                email: EmailAccountValidation.normalizeEmail(email),
                password: password,
                passwordConfirmation: passwordConfirmation,
                countryCode: countryCode,
                locale: locale,
                timezone: timezone
            ),
            authentication: .none
        )
    }

    func verifyEmail(token: String) async throws -> EmailVerificationResult {
        try await send(
            path: "auth/email/verify",
            method: "POST",
            body: EmailVerificationRequest(
                token: EmailAccountValidation.normalizeOpaqueToken(token)
            ),
            authentication: .none
        )
    }

    func resendEmailVerification(email: String) async throws -> EmailMessageResult {
        try await send(
            path: "auth/email/resend",
            method: "POST",
            body: EmailAddressRequest(email: EmailAccountValidation.normalizeEmail(email)),
            authentication: .none
        )
    }

    func requestPasswordReset(email: String) async throws -> EmailMessageResult {
        try await send(
            path: "auth/password/forgot",
            method: "POST",
            body: EmailAddressRequest(email: EmailAccountValidation.normalizeEmail(email)),
            authentication: .none
        )
    }

    func resetPassword(
        token: String,
        password: String,
        passwordConfirmation: String
    ) async throws -> PasswordResetResult {
        try await send(
            path: "auth/password/reset",
            method: "POST",
            body: PasswordResetRequest(
                token: EmailAccountValidation.normalizeOpaqueToken(token),
                password: password,
                passwordConfirmation: passwordConfirmation
            ),
            authentication: .none
        )
    }

    func requestPhoneOTP(phone: String, device: DeviceRegistration) async throws -> AuthResult {
        try await send(
            path: "auth/otp/request",
            method: "POST",
            body: PhoneOTPRequest(phone: phone, device: device),
            authentication: .none
        )
    }

    func verifyPhoneOTP(
        challengeId: String,
        phone: String,
        code: String,
        device: DeviceRegistration
    ) async throws -> AuthResult {
        try await send(
            path: "auth/otp/verify",
            method: "POST",
            body: PhoneOTPVerifyRequest(
                challengeId: challengeId,
                phone: phone,
                code: code,
                device: device
            ),
            authentication: .none
        )
    }

    func verifyTwoFactor(challengeId: String, code: String) async throws -> AuthResult {
        try await send(
            path: "auth/2fa/verify",
            method: "POST",
            body: TwoFactorVerifyRequest(challengeId: challengeId, code: code),
            authentication: .none
        )
    }

    func currentProfile() async throws -> UserProfile {
        try await send(path: "profile", method: "GET", body: EmptyBody())
    }

    func enrollTOTP() async throws -> TOTPEnrollmentDTO {
        try await send(
            path: "auth/2fa/totp/enroll",
            method: "POST",
            body: EmptyBody()
        )
    }

    func confirmTOTP(code: String) async throws -> MFAStatusDTO {
        try await send(
            path: "auth/2fa/totp/confirm",
            method: "POST",
            body: MFAFactorRequest(code: code)
        )
    }

    func regenerateMFARecoveryCodes(code: String) async throws -> MFARecoveryCodesDTO {
        try await send(
            path: "auth/2fa/recovery-codes",
            method: "POST",
            body: MFAFactorRequest(code: code)
        )
    }

    func disableTOTP(code: String) async throws -> MFAStatusDTO {
        try await send(
            path: "auth/2fa/totp",
            method: "DELETE",
            body: MFAFactorRequest(code: code),
            includeBodyForDelete: true
        )
    }

    func logout(allDevices: Bool = false) async throws {
        let _: EmptyResponse = try await send(
            path: "auth/logout",
            method: "POST",
            body: LogoutRequest(allDevices: allDevices)
        )
    }

    func bootstrap() async throws -> BootstrapDTO {
        try await send(path: "bootstrap", method: "GET", body: EmptyBody())
    }

    func registeredDevices() async throws -> DeviceListDTO {
        try await send(path: "devices", method: "GET", body: EmptyBody())
    }

    func revokeRegisteredDevice(id: String) async throws {
        guard let id = RegisteredDevicePolicy.canonicalID(id) else {
            throw DeviceManagementError.invalidDevice
        }
        let _: EmptyResponse = try await send(
            path: "devices/\(id)",
            method: "DELETE",
            body: EmptyBody()
        )
    }

    func updateProfile(name: String, tag: String) async throws -> UserProfile {
        try await send(
            path: "profile",
            method: "PATCH",
            body: UpdateProfileRequest(name: name, tag: tag)
        )
    }

    /// Convenience entry point retained for callers that do not need durable resumption.
    func updateProfileAvatar(jpegData: Data) async throws -> UserProfile {
        let capturedSessionID: String
        if let inheritedSessionID = APIClientSessionBinding.sessionID {
            capturedSessionID = inheritedSessionID
        } else if let currentSessionID = await sessionStore.current()?.sessionId {
            capturedSessionID = currentSessionID
        } else {
            throw APIClientError.signedOut
        }
        return try await APIClientSessionBinding.$sessionID.withValue(capturedSessionID) {
            let prepared = try await self.prepareProfileAvatarUpload(jpegData: jpegData)
            return try await self.resumeProfileAvatarAttachment(assetID: prepared.assetID)
        }
    }

    /// Reserves, uploads, and finalizes exact JPEG bytes. The returned asset can be persisted
    /// before polling so process suspension never forces the client to upload the photo again.
    func prepareProfileAvatarUpload(jpegData: Data) async throws -> PreparedProfileAvatarUpload {
        guard !jpegData.isEmpty, jpegData.count <= ProfileAvatarUploadPolicy.maximumBytes else {
            throw ProfileAvatarUploadError.invalidImage
        }
        guard let boundSessionID = APIClientSessionBinding.sessionID else {
            throw APIClientError.signedOut
        }
        let digest = ProfileAvatarUploadPolicy.sha256(of: jpegData)
        let intent: MediaUploadIntentDTO = try await send(
            path: "media/upload-intents",
            method: "POST",
            body: CreateProfileAvatarUploadIntentRequest(
                byteSize: jpegData.count,
                sha256: digest
            ),
            headers: ["Idempotency-Key": UUID().uuidString.lowercased()]
        )
        let assetID = try canonicalProfileAvatarAssetID(intent.asset.id)

        try await uploadProfileAvatarBytes(
            jpegData,
            using: intent.upload,
            boundSessionID: boundSessionID
        )
        try Task.checkCancellation()
        let finalized: MediaAssetDTO = try await send(
            path: "media/\(assetID)/finalize",
            method: "POST",
            body: EmptyBody()
        )
        guard finalized.id.caseInsensitiveCompare(assetID) == .orderedSame else {
            throw ProfileAvatarUploadError.invalidServiceResponse
        }
        return PreparedProfileAvatarUpload(assetID: assetID, sourceSHA256: digest)
    }

    /// Polls a previously finalized asset and attaches it only after the backend reports the
    /// atomic ready/clean state. Callers retain the asset reference on timeout or transient error.
    func resumeProfileAvatarAttachment(assetID rawAssetID: String) async throws -> UserProfile {
        guard APIClientSessionBinding.sessionID != nil else { throw APIClientError.signedOut }
        let assetID = try canonicalProfileAvatarAssetID(rawAssetID)
        return try await ProfileAvatarDeadline.run(
            maximumWait: ProfileAvatarUploadPolicy.maximumScanWait
        ) { [self] in
            try await pollProfileAvatarAttachment(assetID: assetID)
        }
    }

    private func pollProfileAvatarAttachment(assetID: String) async throws -> UserProfile {
        var asset: MediaAssetDTO = try await send(
            path: "media/\(assetID)",
            method: "GET",
            body: EmptyBody()
        )
        for attempt in 0 ..< ProfileAvatarUploadPolicy.maximumScanPolls {
            try Task.checkCancellation()
            guard asset.id.caseInsensitiveCompare(assetID) == .orderedSame else {
                throw ProfileAvatarUploadError.invalidServiceResponse
            }
            if asset.status.caseInsensitiveCompare("ready") == .orderedSame,
               asset.scan.status.caseInsensitiveCompare("clean") == .orderedSame {
                try Task.checkCancellation()
                return try await send(
                    path: "profile/avatar",
                    method: "POST",
                    body: AttachProfileAvatarRequest(assetId: assetID)
                )
            }
            if ["failed", "rejected", "deleted"].contains(asset.status.lowercased())
                || ["failed", "infected"].contains(asset.scan.status.lowercased()) {
                throw ProfileAvatarUploadError.rejected
            }
            guard attempt + 1 < ProfileAvatarUploadPolicy.maximumScanPolls else { break }
            try await Task.sleep(nanoseconds: ProfileAvatarUploadPolicy.scanPollNanoseconds)
            asset = try await send(
                path: "media/\(assetID)",
                method: "GET",
                body: EmptyBody()
            )
        }
        throw ProfileAvatarUploadError.scanTimedOut
    }

    private func canonicalProfileAvatarAssetID(_ value: String) throws -> String {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              let identifier = UUID(uuidString: value)
        else { throw ProfileAvatarUploadError.invalidServiceResponse }
        return identifier.uuidString.lowercased()
    }

    func transactions(walletId: String) async throws -> TransactionPage {
        try await send(path: "wallets/\(walletId)/transactions?limit=50", method: "GET", body: EmptyBody())
    }

    func contacts() async throws -> ContactListDTO {
        try await allContacts()
    }

    func createStepUp(purpose: String, intent: [String: String?]) async throws -> StepUpChallengeDTO {
        try await send(
            path: "auth/step-up/challenges",
            method: "POST",
            body: CreateStepUpRequest(purpose: purpose, intent: intent)
        )
    }

    func verifyStepUp(challengeId: String, pin: String) async throws -> StepUpVerificationDTO {
        try await send(
            path: "auth/step-up/challenges/\(challengeId)/verify",
            method: "POST",
            body: VerifyStepUpRequest(pin: pin)
        )
    }

    func verifyStepUp(
        challengeId: String,
        nonce: String,
        signature: String
    ) async throws -> StepUpVerificationDTO {
        try await send(
            path: "auth/step-up/challenges/\(challengeId)/verify",
            method: "POST",
            body: VerifyBiometricStepUpRequest(
                nonce: nonce,
                signature: signature
            )
        )
    }

    func setPaymentPin(pin: String, currentPin: String? = nil) async throws -> PaymentPinStatusDTO {
        try await send(
            path: "auth/payment-pin",
            method: "PUT",
            body: SetPaymentPinRequest(pin: pin, currentPin: currentPin)
        )
    }

    func sessionAssurance() async throws -> SessionAssuranceDTO {
        let response: SessionAssuranceResponseDTO = try await send(
            path: "auth/session-assurance",
            method: "GET",
            body: EmptyBody()
        )
        return response.sessionAssurance
    }

    func securityPreferences() async throws -> SecurityPreferencesDTO {
        let endpoint = SecurityPreferencesAPIEndpoint.read
        return try await send(
            path: endpoint.path,
            method: endpoint.method,
            body: EmptyBody()
        )
    }

    func updateSecurityPreferences(
        _ request: UpdateSecurityPreferencesRequest
    ) async throws -> SecurityPreferencesDTO {
        let endpoint = SecurityPreferencesAPIEndpoint.update
        let updated: SecurityPreferencesDTO = try await send(
            path: endpoint.path,
            method: endpoint.method,
            body: request
        )
        let increment = request.version.addingReportingOverflow(1)
        let isUnchangedVersion = updated.version == request.version
        let isIncrementedVersion = !increment.overflow
            && updated.version == increment.partialValue
            && updated.updatedAt != nil
        guard updated.verifyIdentityOnNewLogin == request.verifyIdentityOnNewLogin,
              isUnchangedVersion || isIncrementedVersion
        else { throw APIClientError.invalidResponse }
        return updated
    }

    func unlockSession(pin: String) async throws -> SessionUnlockResultDTO {
        try await send(
            path: "auth/session-unlock/pin",
            method: "POST",
            body: LoginPinUnlockRequest(pin: pin)
        )
    }

    func createLoginBiometricChallenge() async throws -> LoginBiometricChallengeDTO {
        try await send(
            path: "auth/session-unlock/biometric/challenge",
            method: "POST",
            body: EmptyBody()
        )
    }

    func assertLoginBiometricChallenge(
        challengeId: String,
        nonce: String,
        signature: String
    ) async throws -> SessionUnlockResultDTO {
        try await send(
            path: "auth/session-unlock/biometric/assert",
            method: "POST",
            body: LoginBiometricAssertionRequest(
                challengeId: challengeId,
                nonce: nonce,
                signature: signature
            )
        )
    }

    func enrollBiometricKey(
        publicKeyPEM: String,
        attestation: [String: String]? = nil
    ) async throws -> BiometricKeyStatusDTO {
        try await send(
            path: "devices/current/biometric-key",
            method: "PUT",
            body: EnrollBiometricKeyRequest(
                publicKey: publicKeyPEM,
                attestation: attestation
            )
        )
    }

    func removeBiometricKey() async throws -> BiometricKeyStatusDTO {
        try await send(
            path: "devices/current/biometric-key",
            method: "DELETE",
            body: EmptyBody()
        )
    }

    func transfer(
        walletId: String,
        destinationWalletId: String,
        amount: String,
        note: String?,
        idempotencyKey: String,
        stepUpToken: String
    ) async throws -> WalletTransaction {
        try await send(
            path: "wallets/\(walletId)/transfers",
            method: "POST",
            body: WalletTransferRequest(
                destinationWalletId: destinationWalletId,
                amount: amount,
                note: note
            ),
            headers: [
                "Idempotency-Key": idempotencyKey,
                "X-Kit-Wallet-Step-Up": stepUpToken,
            ]
        )
    }

    func calls(cursor: String? = nil, limit: Int = 50) async throws -> CallPage {
        guard (1 ... 100).contains(limit),
              cursor.map({
                  !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && $0.count <= 2_048
              }) ?? true
        else { throw APIClientError.invalidResponse }

        var queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        return try await send(
            path: "calls",
            method: "GET",
            body: EmptyBody(),
            queryItems: queryItems
        )
    }

    func startCall(
        recipientUserIds: [String],
        video: Bool,
        conversationId: String?,
        clientCallId: String
    ) async throws -> CallSessionDTO {
        try await send(
            path: "calls",
            method: "POST",
            body: StartCallRequest(
                recipientUserIds: recipientUserIds,
                type: video ? "video" : "voice",
                conversationId: conversationId,
                clientCallId: clientCallId
            )
        )
    }

    func registerPushToken(_ token: String, provider: String = "apns") async throws -> PushTokenStatus {
        try await send(
            path: "devices/current/push-token",
            method: "PUT",
            body: RegisterPushTokenRequest(provider: provider, token: token)
        )
    }

    func unregisterPushToken(provider: String) async throws -> PushTokenStatus {
        guard ["fcm", "apns", "apns_voip"].contains(provider) else {
            throw APIClientError.invalidURL
        }
        return try await send(
            path: "devices/current/push-token?provider=\(provider)",
            method: "DELETE",
            body: EmptyBody()
        )
    }

    func kycStatus() async throws -> KYCStatus {
        try await send(path: "kyc/", method: "GET", body: EmptyBody())
    }

    func createKYCSession(consent: Bool, privacyNoticeVersion: String) async throws -> KYCStatus {
        try await send(
            path: "kyc/sessions",
            method: "POST",
            body: CreateKYCSessionRequest(
                consent: consent,
                privacyNoticeVersion: privacyNoticeVersion
            )
        )
    }

    func send<Response: Decodable, Body: Encodable>(
        path: String,
        method: String,
        body: Body,
        authentication: APIRequestAuthentication = .required,
        allowRefresh: Bool = true,
        headers: [String: String] = [:],
        queryItems: [URLQueryItem] = [],
        boundSessionID: String? = nil,
        includeBodyForDelete: Bool = false
    ) async throws -> Response {
        let inheritedSessionID = APIClientSessionBinding.sessionID
        if let boundSessionID,
           let inheritedSessionID,
           !SessionRefreshPolicy.matchesSessionID(boundSessionID, current: inheritedSessionID) {
            throw APIClientError.signedOut
        }
        let requiredSessionID = boundSessionID ?? inheritedSessionID
        let currentSession = authentication.readsCurrentSession
            ? await sessionStore.current()
            : nil
        if authentication.requiresCurrentSession && currentSession == nil {
            throw APIClientError.signedOut
        }
        if authentication.readsCurrentSession,
           let requiredSessionID,
           currentSession.map({
               SessionRefreshPolicy.matchesSessionID(requiredSessionID, current: $0.sessionId)
           }) != true {
            throw APIClientError.signedOut
        }

        var request = URLRequest(url: try endpoint(path, queryItems: queryItems))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(APIClientIdentity.currentHeader, forHTTPHeaderField: "X-Kit-Wallet-Client")
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Request-ID")
        if APIRequestBodyPolicy.encodesBody(
            for: method,
            includeBodyForDelete: includeBodyForDelete
        ) {
            request.httpBody = try encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let currentSession {
            request.setValue("Bearer \(currentSession.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(currentSession.sessionId, forHTTPHeaderField: "X-Kit-Wallet-Session-ID")
        }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIClientError.invalidResponse }
        if http.statusCode == 401,
           authentication.readsCurrentSession,
           currentSession != nil,
           allowRefresh {
            try await refreshSession(afterRejectedSession: currentSession)
            return try await send(
                path: path,
                method: method,
                body: body,
                authentication: authentication,
                allowRefresh: false,
                headers: headers,
                queryItems: queryItems,
                boundSessionID: currentSession?.sessionId,
                includeBodyForDelete: includeBodyForDelete
            )
        }

        let envelope: APIEnvelope<Response>
        do {
            envelope = try decoder.decode(APIEnvelope<Response>.self, from: data)
        } catch {
            if !(200 ... 299).contains(http.statusCode) {
                throw APIClientError.httpResponse(
                    status: http.statusCode,
                    retryAfter: HTTPRetryAfterParser.delay(from: http)
                )
            }
            throw APIClientError.invalidPayload(status: http.statusCode)
        }
        guard http.statusCode >= 200 && http.statusCode < 300, envelope.ok, let value = envelope.data else {
            if let apiError = envelope.error {
                throw apiError.attachingHTTP(
                    status: http.statusCode,
                    retryAfter: HTTPRetryAfterParser.delay(from: http)
                )
            }
            throw APIClientError.httpResponse(
                status: http.statusCode,
                retryAfter: HTTPRetryAfterParser.delay(from: http)
            )
        }
        return value
    }

    private func uploadProfileAvatarBytes(
        _ data: Data,
        using upload: MediaUploadInstructionsDTO,
        boundSessionID: String?
    ) async throws {
        guard upload.method.caseInsensitiveCompare("PUT") == .orderedSame,
              let url = URL(string: upload.url),
              url.scheme?.caseInsensitiveCompare("https") == .orderedSame,
              url.host?.isEmpty == false,
              url.user == nil,
              url.password == nil,
              upload.headers.count <= 32,
              upload.headers.allSatisfy({ isSafeUploadHeader(name: $0.key, value: $0.value) })
        else { throw ProfileAvatarUploadError.invalidServiceResponse }

        try Task.checkCancellation()
        try await requireCurrentProfileAvatarSession(boundSessionID)

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = data
        request.timeoutInterval = 60
        for (name, value) in upload.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let (_, response) = try await session.data(for: request)
        try Task.checkCancellation()
        try await requireCurrentProfileAvatarSession(boundSessionID)
        guard let http = response as? HTTPURLResponse else {
            throw ProfileAvatarUploadError.invalidServiceResponse
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw APIClientError.httpResponse(
                status: http.statusCode,
                retryAfter: HTTPRetryAfterParser.delay(from: http)
            )
        }
    }

    private func requireCurrentProfileAvatarSession(_ expectedSessionID: String?) async throws {
        guard let expectedSessionID else { return }
        guard let currentSessionID = await sessionStore.current()?.sessionId,
              SessionRefreshPolicy.matchesSessionID(
                expectedSessionID,
                current: currentSessionID
              )
        else { throw APIClientError.signedOut }
    }

    private func isSafeUploadHeader(name: String, value: String) -> Bool {
        guard !name.isEmpty,
              name.unicodeScalars.allSatisfy({ scalar in
                  scalar.value > 0x20
                      && scalar.value < 0x7f
                      && !"()<>@,;:\\\"/[]?={} \t".unicodeScalars.contains(scalar)
              }),
              !value.contains("\r"),
              !value.contains("\n"),
              value.utf8.count <= 8_192
        else { return false }
        return true
    }

    /// Uses the same authenticated session, refresh rotation, request identity, and error envelope
    /// handling as JSON requests while allowing the encrypted messaging attachment multipart body.
    func sendMultipart<Response: Decodable>(
        path: String,
        fields: [String: String],
        fileField: String,
        fileName: String,
        fileContentType: String,
        fileData: Data,
        allowRefresh: Bool = true,
        boundSessionID: String? = nil
    ) async throws -> Response {
        guard !fields.isEmpty,
              !fileField.isEmpty,
              !fileName.isEmpty,
              !fileContentType.isEmpty,
              !fileData.isEmpty
        else { throw APIClientError.invalidResponse }
        let inheritedSessionID = APIClientSessionBinding.sessionID
        if let boundSessionID,
           let inheritedSessionID,
           !SessionRefreshPolicy.matchesSessionID(boundSessionID, current: inheritedSessionID) {
            throw APIClientError.signedOut
        }
        let requiredSessionID = boundSessionID ?? inheritedSessionID
        let currentSession = await sessionStore.current()
        guard let currentSession else { throw APIClientError.signedOut }
        if let requiredSessionID,
           !SessionRefreshPolicy.matchesSessionID(
            requiredSessionID,
            current: currentSession.sessionId
           ) {
            throw APIClientError.signedOut
        }

        let boundary = "KitPay-\(UUID().uuidString.lowercased())"
        let body = try MultipartFormDataBody.make(
            boundary: boundary,
            fields: fields,
            fileField: fileField,
            fileName: fileName,
            fileContentType: fileContentType,
            fileData: fileData
        )
        var request = URLRequest(url: try endpoint(path, queryItems: []))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(APIClientIdentity.currentHeader, forHTTPHeaderField: "X-Kit-Wallet-Client")
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Request-ID")
        request.setValue(
            "Bearer \(currentSession.accessToken)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(currentSession.sessionId, forHTTPHeaderField: "X-Kit-Wallet-Session-ID")
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIClientError.invalidResponse }
        if http.statusCode == 401, allowRefresh {
            try await refreshSession(afterRejectedSession: currentSession)
            return try await sendMultipart(
                path: path,
                fields: fields,
                fileField: fileField,
                fileName: fileName,
                fileContentType: fileContentType,
                fileData: fileData,
                allowRefresh: false,
                boundSessionID: currentSession.sessionId
            )
        }
        return try decodeEnvelope(data, response: http)
    }

    /// Downloads opaque end-to-end encrypted bytes through the authenticated transport. The
    /// caller supplies the exact authenticated byte bound from the Signal descriptor.
    func downloadAuthenticatedData(
        path: String,
        maximumBytes: Int,
        allowRefresh: Bool = true,
        boundSessionID: String? = nil
    ) async throws -> Data {
        guard maximumBytes > 0,
              maximumBytes <= Int(SecureMessagingWire.maximumAttachmentCiphertextBytes)
        else { throw APIClientError.invalidResponse }
        let inheritedSessionID = APIClientSessionBinding.sessionID
        if let boundSessionID,
           let inheritedSessionID,
           !SessionRefreshPolicy.matchesSessionID(boundSessionID, current: inheritedSessionID) {
            throw APIClientError.signedOut
        }
        let requiredSessionID = boundSessionID ?? inheritedSessionID
        let currentSession = await sessionStore.current()
        guard let currentSession else { throw APIClientError.signedOut }
        if let requiredSessionID,
           !SessionRefreshPolicy.matchesSessionID(
            requiredSessionID,
            current: currentSession.sessionId
           ) {
            throw APIClientError.signedOut
        }

        var request = URLRequest(url: try endpoint(path, queryItems: []))
        request.httpMethod = "GET"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue(APIClientIdentity.currentHeader, forHTTPHeaderField: "X-Kit-Wallet-Client")
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Request-ID")
        request.setValue(
            "Bearer \(currentSession.accessToken)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(currentSession.sessionId, forHTTPHeaderField: "X-Kit-Wallet-Session-ID")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIClientError.invalidResponse }
        if http.statusCode == 401, allowRefresh {
            try await refreshSession(afterRejectedSession: currentSession)
            return try await downloadAuthenticatedData(
                path: path,
                maximumBytes: maximumBytes,
                allowRefresh: false,
                boundSessionID: currentSession.sessionId
            )
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw decodeAPIError(data, response: http)
        }
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw APIClientError.invalidPayload(status: http.statusCode)
        }
        if let rawLength = http.value(forHTTPHeaderField: "Content-Length"),
           let contentLength = Int(rawLength),
           contentLength != data.count {
            throw APIClientError.invalidPayload(status: http.statusCode)
        }
        return data
    }

    private func decodeEnvelope<Response: Decodable>(
        _ data: Data,
        response: HTTPURLResponse
    ) throws -> Response {
        let envelope: APIEnvelope<Response>
        do {
            envelope = try decoder.decode(APIEnvelope<Response>.self, from: data)
        } catch {
            if !(200 ... 299).contains(response.statusCode) {
                throw APIClientError.httpResponse(
                    status: response.statusCode,
                    retryAfter: HTTPRetryAfterParser.delay(from: response)
                )
            }
            throw APIClientError.invalidPayload(status: response.statusCode)
        }
        guard (200 ... 299).contains(response.statusCode),
              envelope.ok,
              let value = envelope.data
        else {
            if let apiError = envelope.error {
                throw apiError.attachingHTTP(
                    status: response.statusCode,
                    retryAfter: HTTPRetryAfterParser.delay(from: response)
                )
            }
            throw APIClientError.httpResponse(
                status: response.statusCode,
                retryAfter: HTTPRetryAfterParser.delay(from: response)
            )
        }
        return value
    }

    private func decodeAPIError(
        _ data: Data,
        response: HTTPURLResponse
    ) -> Error {
        if let envelope = try? decoder.decode(APIEnvelope<EmptyResponse>.self, from: data),
           let apiError = envelope.error {
            return apiError.attachingHTTP(
                status: response.statusCode,
                retryAfter: HTTPRetryAfterParser.delay(from: response)
            )
        }
        return APIClientError.httpResponse(
            status: response.statusCode,
            retryAfter: HTTPRetryAfterParser.delay(from: response)
        )
    }

    private func refreshSession(afterRejectedSession rejected: SessionTokens?) async throws {
        guard let rejected else { throw APIClientError.signedOut }

        if let refreshFlight,
           SessionRefreshPolicy.matchesSessionID(
            refreshFlight.sessionID,
            current: rejected.sessionId
           ) {
            do {
                _ = try await refreshFlight.task.value
            } catch {
                if SessionRefreshPolicy.isTerminal(error) {
                    await invalidateSession(matching: refreshFlight.sessionID)
                    throw APIClientError.signedOut
                }
                throw error
            }
            return
        }
        // Install the single-flight task before the first actor hop. Otherwise
        // two simultaneous 401 responses can both pass the nil check while
        // waiting on SessionStore and overwrite each other's refresh task.
        let flightID = UUID()
        let task = Task { [self] in
            try await executeSessionRefresh(afterRejectedSession: rejected)
        }
        refreshFlight = SessionRefreshFlight(
            id: flightID,
            sessionID: rejected.sessionId,
            task: task
        )
        defer {
            // A replacement sign-in is allowed to install its own refresh flight while this
            // account's request unwinds. The stale completion must not clear that newer flight.
            if refreshFlight?.id == flightID { refreshFlight = nil }
        }
        do {
            _ = try await task.value
        } catch {
            if SessionRefreshPolicy.isTerminal(error) {
                await invalidateSession(matching: rejected.sessionId)
                throw APIClientError.signedOut
            }
            throw error
        }
    }

    private func executeSessionRefresh(
        afterRejectedSession rejected: SessionTokens?
    ) async throws -> SessionTokens {
        guard let old = await sessionStore.current() else { throw APIClientError.signedOut }
        if let rejected,
           !SessionRefreshPolicy.matchesSessionID(rejected.sessionId, current: old.sessionId) {
            throw APIClientError.signedOut
        }
        // Another request may already have completed rotation before this
        // single-flight task began.
        if let rejected, rejected.accessToken != old.accessToken { return old }
        guard SessionRefreshPolicy.isValidSessionID(old.sessionId) else {
            throw APIClientError.signedOut
        }
        let replayNonce = try await sessionStore.replayNonce(for: old)
        let updated = try await performSessionRefresh(old, replayNonce: replayNonce)
        guard let current = await sessionStore.current(),
              current.sessionId.caseInsensitiveCompare(old.sessionId) == .orderedSame,
              current.accessToken == old.accessToken,
              current.refreshToken == old.refreshToken
        else { throw APIClientError.signedOut }
        try await sessionStore.saveAfterRefresh(updated)
        return updated
    }

    private func performSessionRefresh(
        _ old: SessionTokens,
        replayNonce: String
    ) async throws -> SessionTokens {
        let result: AuthResult = try await send(
            path: "auth/refresh",
            method: "POST",
            body: RefreshSessionRequest(
                refreshToken: old.refreshToken,
                refreshReplayNonce: replayNonce
            ),
            authentication: .none,
            allowRefresh: false,
            headers: SessionRefreshPolicy.headers(sessionID: old.sessionId)
        )
        guard let updated = result.session else {
            throw APIClientError.signedOut
        }
        guard updated.sessionId.caseInsensitiveCompare(old.sessionId) == .orderedSame else {
            throw APIClientError.signedOut
        }
        return updated
    }

    private func invalidateSession(matching sessionID: String?) async {
        guard let sessionID,
              let current = await sessionStore.current(),
              current.sessionId.caseInsensitiveCompare(sessionID) == .orderedSame
        else { return }
        try? await sessionStore.clear()
        NotificationCenter.default.post(name: .kitSessionInvalidated, object: sessionID)
    }

    private func endpoint(_ path: String, queryItems: [URLQueryItem]) throws -> URL {
        guard let url = APIEndpointPolicy.url(
            baseURL: baseURL,
            path: path,
            queryItems: queryItems
        )
        else { throw APIClientError.invalidURL }
        return url
    }
}

enum APIRequestBodyPolicy {
    static func encodesBody(for method: String, includeBodyForDelete: Bool = false) -> Bool {
        switch method.uppercased() {
        case "GET", "HEAD":
            false
        case "DELETE":
            includeBodyForDelete
        default:
            true
        }
    }
}

enum APIEndpointPolicy {
    private static let unreservedQueryCharacters = CharacterSet.alphanumerics.union(
        CharacterSet(charactersIn: "-._~")
    )

    static func url(
        baseURL: URL,
        path: String,
        queryItems: [URLQueryItem] = []
    ) -> URL? {
        guard queryItems.isEmpty || !path.contains("?") else { return nil }
        if queryItems.isEmpty {
            guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
            else { return nil }
            return URL(string: encoded, relativeTo: baseURL)
        }

        guard let relativeURL = URL(string: path, relativeTo: baseURL),
              var components = URLComponents(
                  url: relativeURL.absoluteURL,
                  resolvingAgainstBaseURL: false
              )
        else { return nil }
        let encodedPairs = queryItems.compactMap { item -> String? in
            guard let name = item.name.addingPercentEncoding(
                withAllowedCharacters: unreservedQueryCharacters
            ) else { return nil }
            guard let value = item.value else { return name }
            guard let encodedValue = value.addingPercentEncoding(
                withAllowedCharacters: unreservedQueryCharacters
            ) else { return nil }
            return "\(name)=\(encodedValue)"
        }
        guard encodedPairs.count == queryItems.count else { return nil }
        components.percentEncodedQuery = encodedPairs.joined(separator: "&")
        return components.url
    }
}

enum APIClientIdentity {
    private static let fallbackVersion = "0.2.5"

    static var currentHeader: String {
        header(
            marketingVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String,
            buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }

    static func header(marketingVersion: String?, buildNumber: String?) -> String {
        let rawVersion = marketingVersion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let version = rawVersion.range(
            of: #"\A(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\z"#,
            options: .regularExpression
        ) == nil ? fallbackVersion : rawVersion

        let rawBuild = buildNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let validBuild = rawBuild.range(
            of: #"\A(?:0|[1-9][0-9]*)\z"#,
            options: .regularExpression
        ) != nil
        return validBuild ? "ios/\(version)-r\(rawBuild)" : "ios/\(version)"
    }
}

enum SessionRefreshPolicy {
    static func isValidSessionID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
    }

    static func matchesSessionID(_ expected: String, current: String) -> Bool {
        expected.caseInsensitiveCompare(current) == .orderedSame
    }

    /// The API clears a terminal session before notifying the UI. A nil current session therefore
    /// still belongs to that invalidation, while an already-installed replacement must survive.
    static func shouldApplyInvalidation(
        invalidatedSessionID: String,
        currentSessionID: String?
    ) -> Bool {
        guard let currentSessionID else { return true }
        return matchesSessionID(invalidatedSessionID, current: currentSessionID)
    }

    static func headers(sessionID: String) -> [String: String] {
        ["X-Kit-Wallet-Session-ID": sessionID]
    }

    static func isTerminal(_ error: Error) -> Bool {
        if let clientError = error as? APIClientError,
           case .signedOut = clientError {
            return true
        }
        // Stable error codes are meaningful only with the refresh endpoint's documented
        // unauthorized response. A proxy or server fault must never erase valid credentials just
        // because its body happens to reuse one of these strings.
        guard let payload = error as? APIErrorPayload,
              payload.httpStatus == 401
        else { return false }
        return [
            "SESSION_ID_REQUIRED",
            "SESSION_REVOKED",
            "REFRESH_TOKEN_INVALID",
            "REFRESH_TOKEN_EXPIRED",
            "REFRESH_TOKEN_REUSED",
        ].contains(payload.code)
    }
}

extension Notification.Name {
    static let kitSessionInvalidated = Notification.Name("africa.kit.pay.session-invalidated")
}

private struct EmptyBody: Encodable {}

private struct EmptyResponse: Decodable {}

struct LogoutRequest: Encodable, Equatable {
    let allDevices: Bool

    enum CodingKeys: String, CodingKey {
        case allDevices = "all_devices"
    }
}

/// Account-access requests deliberately conform only to `Encodable`: they are transient wire
/// payloads and must never be decoded into, or reused as, persisted application state.
struct EmailLoginRequest: Encodable {
    let email: String
    let password: String
    let device: DeviceRegistration
}

struct EmailRegistrationRequest: Encodable {
    let name: String
    let tag: String
    let email: String
    let password: String
    let passwordConfirmation: String
    let countryCode: String
    let locale: String
    let timezone: String

    enum CodingKeys: String, CodingKey {
        case name, tag, email, password, locale, timezone
        case passwordConfirmation = "password_confirmation"
        case countryCode = "country_code"
    }
}

struct EmailVerificationRequest: Encodable {
    let token: String
}

struct EmailAddressRequest: Encodable {
    let email: String
}

struct PasswordResetRequest: Encodable {
    let token: String
    let password: String
    let passwordConfirmation: String

    enum CodingKeys: String, CodingKey {
        case token, password
        case passwordConfirmation = "password_confirmation"
    }
}

struct TwoFactorVerifyRequest: Encodable {
    let challengeId: String
    let code: String

    enum CodingKeys: String, CodingKey {
        case challengeId = "challenge_id"
        case code
    }
}

private struct CreateProfileAvatarUploadIntentRequest: Encodable {
    let kind = "image"
    let purpose = "avatar"
    let filename = "profile-avatar.jpg"
    let mimeType = "image/jpeg"
    let byteSize: Int
    let sha256: String
    let clientEncrypted = false

    enum CodingKeys: String, CodingKey {
        case kind, purpose, filename, sha256
        case mimeType = "mime_type"
        case byteSize = "byte_size"
        case clientEncrypted = "client_encrypted"
    }
}

private struct AttachProfileAvatarRequest: Encodable {
    let assetId: String

    enum CodingKeys: String, CodingKey {
        case assetId = "asset_id"
    }
}

private enum MultipartFormDataBody {
    static func make(
        boundary: String,
        fields: [String: String],
        fileField: String,
        fileName: String,
        fileContentType: String,
        fileData: Data
    ) throws -> Data {
        guard isSafeToken(boundary),
              isSafeToken(fileField),
              isSafeToken(fileName),
              isSafeToken(fileContentType),
              fields.keys.allSatisfy(isSafeToken),
              fields.values.allSatisfy({ !$0.contains("\r") && !$0.contains("\n") })
        else { throw APIClientError.invalidResponse }
        var body = Data()
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            try append(
                "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n",
                to: &body
            )
        }
        try append(
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(fileName)\"\r\nContent-Type: \(fileContentType)\r\n\r\n",
            to: &body
        )
        body.append(fileData)
        try append("\r\n--\(boundary)--\r\n", to: &body)
        return body
    }

    private static func append(_ value: String, to data: inout Data) throws {
        guard let encoded = value.data(using: .utf8) else {
            throw APIClientError.invalidResponse
        }
        data.append(encoded)
    }

    private static func isSafeToken(_ value: String) -> Bool {
        !value.isEmpty
            && value.unicodeScalars.allSatisfy {
                $0.value >= 0x21 && $0.value <= 0x7E && $0 != "\"" && $0 != "\\"
            }
    }
}

private struct PhoneOTPRequest: Encodable {
    let phone: String
    let device: DeviceRegistration
}

private struct PhoneOTPVerifyRequest: Encodable {
    let challengeId: String
    let phone: String
    let code: String
    let device: DeviceRegistration

    enum CodingKeys: String, CodingKey {
        case challengeId = "challenge_id"
        case phone, code, device
    }
}

private struct RefreshSessionRequest: Encodable {
    let refreshToken: String
    let refreshReplayNonce: String

    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
        case refreshReplayNonce = "refresh_replay_nonce"
    }
}

struct StartCallRequest: Encodable {
    let recipientUserIds: [String]
    let type: String
    let conversationId: String?
    let clientCallId: String

    enum CodingKeys: String, CodingKey {
        case recipientUserIds = "recipient_user_ids"
        case type
        case conversationId = "conversation_id"
        case clientCallId = "client_call_id"
    }
}

private struct RegisterPushTokenRequest: Encodable {
    let provider: String
    let token: String
}

private struct CreateKYCSessionRequest: Encodable {
    let consent: Bool
    let privacyNoticeVersion: String

    enum CodingKeys: String, CodingKey {
        case consent
        case privacyNoticeVersion = "privacy_notice_version"
    }
}

struct CreateStepUpRequest: Encodable {
    let purpose: String
    let intent: [String: String?]
}

private struct VerifyStepUpRequest: Encodable {
    let pin: String
}

struct VerifyBiometricStepUpRequest: Encodable {
    let nonce: String
    let signature: String
}

private struct LoginPinUnlockRequest: Encodable {
    let pin: String
}

private struct LoginBiometricAssertionRequest: Encodable {
    let challengeId: String
    let nonce: String
    let signature: String

    enum CodingKeys: String, CodingKey {
        case challengeId = "challenge_id"
        case nonce, signature
    }
}

private struct EnrollBiometricKeyRequest: Encodable {
    let publicKey: String
    let attestation: [String: String]?

    enum CodingKeys: String, CodingKey {
        case publicKey = "public_key"
        case attestation
    }
}

private struct WalletTransferRequest: Encodable {
    let destinationWalletId: String
    let amount: String
    let note: String?

    enum CodingKeys: String, CodingKey {
        case destinationWalletId = "destination_wallet_id"
        case amount, note
    }
}

struct RTCDetails: Decodable {
    let provider: String
    let url: String
    let token: String
    let room: String
    let iceServers: [RTCIceServer]?
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case provider, url, token, room
        case iceServers = "ice_servers"
        case expiresAt = "expires_at"
    }
}

struct RTCIceServer: Decodable {
    let urls: [String]
    let username: String?
    let credential: String?
    let credentialType: String?

    enum CodingKeys: String, CodingKey {
        case urls, username, credential
        case credentialType = "credential_type"
    }
}

struct CallSessionDTO: Decodable {
    let call: CallDTO
    let rtc: RTCDetails
}

struct PushTokenStatus: Decodable {
    let registered: Bool?
    let provider: String?
}

enum APIClientError: LocalizedError {
    case signedOut
    case invalidResponse
    case invalidPayload(status: Int)
    case httpStatus(Int)
    case httpResponse(status: Int, retryAfter: TimeInterval?)
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .signedOut: "Sign in again to continue."
        case .invalidResponse: "Kit returned an invalid response."
        case .invalidPayload:
            "Kit Pay could not refresh this information. Please try again."
        case .httpStatus(let status): "Kit request failed (HTTP \(status))."
        case .httpResponse(let status, _): "Kit request failed (HTTP \(status))."
        case .invalidURL: "The Kit service address is invalid."
        }
    }
}

enum ProfileAvatarUploadPolicy {
    static let maximumBytes = 384 * 1_024
    static let maximumScanWaitSeconds = 90
    static let scanPollIntervalSeconds = 3
    static let maximumScanWait: Duration = .seconds(maximumScanWaitSeconds)
    /// One immediate observation plus thirty three-second waits stays below the shared request
    /// budget while exceeding the backend's thirty-second managed-scanner timeout. A separate
    /// cancellation task enforces the ninety-second wall-clock deadline, including GET latency.
    static let maximumScanPolls = (maximumScanWaitSeconds / scanPollIntervalSeconds) + 1
    static let scanPollNanoseconds = UInt64(scanPollIntervalSeconds) * 1_000_000_000

    static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum ProfileAvatarDeadline {
    static func run<Value: Sendable>(
        maximumWait: Duration,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: maximumWait)
        return try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask(operation: operation)
            group.addTask {
                try await clock.sleep(until: deadline)
                try Task.checkCancellation()
                throw ProfileAvatarUploadError.scanTimedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw ProfileAvatarUploadError.scanTimedOut
            }
            return result
        }
    }
}

enum ProfileAvatarUploadError: LocalizedError, Equatable {
    case invalidImage
    case invalidServiceResponse
    case rejected
    case scanTimedOut

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            "Choose a valid photo and try again."
        case .invalidServiceResponse:
            "Kit could not prepare the profile photo upload. Please try again."
        case .rejected:
            "That photo could not be used. Choose another photo and try again."
        case .scanTimedOut:
            "Your photo is still being checked. Please try again shortly."
        }
    }
}

enum ProfileAvatarPendingAttachmentPolicy {
    enum SelectionDisposition: Equatable {
        case resumeExisting
        case discardBeforeProfileUpdate
    }

    static let maximumRetentionSeconds: TimeInterval = 24 * 60 * 60
    private static let maximumClockSkewSeconds: TimeInterval = 5 * 60

    static func isResumable(
        _ pending: PendingProfileAvatarAttachment,
        userID: String,
        sessionID: String,
        now: Date = Date()
    ) -> Bool {
        let age = now.timeIntervalSince(pending.finalizedAt)
        return UUID(uuidString: pending.assetID) != nil
            && pending.assetID == pending.assetID.trimmingCharacters(in: .whitespacesAndNewlines)
            && !pending.ownerUserID.isEmpty
            && pending.ownerUserID.caseInsensitiveCompare(userID) == .orderedSame
            && SessionRefreshPolicy.matchesSessionID(pending.sessionID, current: sessionID)
            && isLowercaseSHA256(pending.sourceSHA256)
            && age >= -maximumClockSkewSeconds
            && age <= maximumRetentionSeconds
    }

    static func represents(
        _ pending: PendingProfileAvatarAttachment,
        jpegData: Data,
        userID: String,
        sessionID: String,
        now: Date = Date()
    ) -> Bool {
        isResumable(pending, userID: userID, sessionID: sessionID, now: now)
            && pending.sourceSHA256 == ProfileAvatarUploadPolicy.sha256(of: jpegData)
    }

    /// Resolves replacement intent before the fallible profile PATCH. A different or invalid
    /// durable record must be removed first so a PATCH failure cannot later attach the old photo.
    static func selectionDisposition(
        for pending: PendingProfileAvatarAttachment,
        jpegData: Data,
        userID: String,
        sessionID: String,
        now: Date = Date()
    ) -> SelectionDisposition {
        represents(
            pending,
            jpegData: jpegData,
            userID: userID,
            sessionID: sessionID,
            now: now
        ) ? .resumeExisting : .discardBeforeProfileUpdate
    }

    static func shouldDiscard(after error: Error) -> Bool {
        if let uploadError = error as? ProfileAvatarUploadError {
            return uploadError == .rejected || uploadError == .invalidImage
        }
        if let payload = error as? APIErrorPayload {
            if [404, 410, 422].contains(payload.httpStatus ?? 0) { return true }
            return [
                "MEDIA_NOT_FOUND",
                "MEDIA_TYPE_MISMATCH",
                "MEDIA_UPLOAD_INTEGRITY_MISMATCH",
                "PROFILE_AVATAR_INVALID",
                "PROFILE_AVATAR_NOT_FOUND",
            ].contains(payload.code.uppercased())
        }
        if let clientError = error as? APIClientError {
            switch clientError {
            case .httpStatus(let status), .httpResponse(let status, _):
                return [404, 410, 422].contains(status)
            default:
                return false
            }
        }
        return false
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.unicodeScalars.allSatisfy {
            (48 ... 57).contains($0.value) || (97 ... 102).contains($0.value)
        }
    }
}

enum HTTPRetryAfterParser {
    static func delay(
        from response: HTTPURLResponse,
        now: Date = Date()
    ) -> TimeInterval? {
        guard let rawValue = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawValue.isEmpty
        else { return nil }

        if let seconds = TimeInterval(rawValue), seconds >= 0 {
            return seconds
        }

        for format in [
            "EEE',' dd MMM yyyy HH':'mm':'ss z",
            "EEEE',' dd-MMM-yy HH':'mm':'ss z",
            "EEE MMM d HH':'mm':'ss yyyy",
        ] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: rawValue) {
                return max(0, date.timeIntervalSince(now))
            }
        }
        return nil
    }
}

extension APIErrorPayload: LocalizedError {
    var errorDescription: String? { message }
}
