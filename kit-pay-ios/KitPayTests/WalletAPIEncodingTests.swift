import Foundation
import XCTest
@testable import KitPay

final class WalletAPIEncodingTests: XCTestCase {
    func testWalletHistoryRefreshIdentityIncludesAccountSessionAndWallet() {
        let accountEpoch = UUID()
        let base = WalletHistoryRefreshKey(
            accountEpoch: accountEpoch,
            userID: "user-a",
            sessionID: "session-a",
            walletID: "wallet-a"
        )

        XCTAssertEqual(
            base,
            WalletHistoryRefreshKey(
                accountEpoch: accountEpoch,
                userID: "user-a",
                sessionID: "session-a",
                walletID: "WALLET-A"
            )
        )
        XCTAssertNotEqual(
            base,
            WalletHistoryRefreshKey(
                accountEpoch: UUID(),
                userID: "user-a",
                sessionID: "session-a",
                walletID: "wallet-a"
            )
        )
        XCTAssertNotEqual(
            base,
            WalletHistoryRefreshKey(
                accountEpoch: accountEpoch,
                userID: "user-a",
                sessionID: "session-b",
                walletID: "wallet-a"
            )
        )
        XCTAssertNotEqual(
            base,
            WalletHistoryRefreshKey(
                accountEpoch: accountEpoch,
                userID: "user-a",
                sessionID: "session-a",
                walletID: "wallet-b"
            )
        )
    }

    func testCapabilitiesUsesTheSignedInCohortWhenSessionIsAvailable() {
        XCTAssertEqual(APIClient.capabilitiesAuthentication, .ifAvailable)
        XCTAssertTrue(APIClient.capabilitiesAuthentication.readsCurrentSession)
        XCTAssertFalse(APIClient.capabilitiesAuthentication.requiresCurrentSession)
        XCTAssertFalse(APIRequestAuthentication.none.readsCurrentSession)
        XCTAssertTrue(APIRequestAuthentication.required.requiresCurrentSession)
    }

    func testCancelledCapabilitiesRequestDoesNotSuppressAnOlderValidCompletion() {
        var tracker = CapabilitiesRequestResolutionTracker()
        let older = tracker.begin()
        let newer = tracker.begin()

        XCTAssertFalse(tracker.accepts(newer, cancelled: true))
        XCTAssertTrue(tracker.accepts(older, cancelled: false))

        var newerWins = CapabilitiesRequestResolutionTracker()
        let stale = newerWins.begin()
        let latest = newerWins.begin()
        XCTAssertTrue(newerWins.accepts(latest, cancelled: false))
        XCTAssertFalse(newerWins.accepts(stale, cancelled: false))
    }

    func testCurrentDeviceLogoutEncodesExplicitScope() throws {
        let data = try JSONEncoder().encode(LogoutRequest(allDevices: false))
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Bool]
        )

        XCTAssertEqual(body, ["all_devices": false])
    }

    func testInstalledClientHeaderUsesBackendIOSVersionContract() {
        XCTAssertEqual(
            APIClientIdentity.header(marketingVersion: "0.1.0", buildNumber: "2"),
            "ios/0.1.0-r2"
        )
        XCTAssertEqual(
            APIClientIdentity.header(marketingVersion: "01.1", buildNumber: "02"),
            "ios/1.0.0"
        )
        XCTAssertEqual(
            APIClientIdentity.header(marketingVersion: "1.0", buildNumber: "23"),
            "ios/1.0.0-r23"
        )
        XCTAssertEqual(
            APIClientIdentity.appVersion(marketingVersion: "0.2.5", buildNumber: "16"),
            "0.2.5-r16"
        )
        XCTAssertEqual(
            APIClientIdentity.header(marketingVersion: "1.0.16", buildNumber: "24"),
            "ios/1.0.16-r24"
        )
    }

    func testRefreshCarriesTheExistingSessionIDHeader() {
        let sessionID = "550e8400-e29b-41d4-a716-446655440000"
        XCTAssertTrue(SessionRefreshPolicy.isValidSessionID(sessionID))
        XCTAssertEqual(
            SessionRefreshPolicy.headers(sessionID: sessionID),
            ["X-Kit-Wallet-Session-ID": sessionID]
        )
        XCTAssertFalse(SessionRefreshPolicy.isValidSessionID(""))
        XCTAssertFalse(
            SessionRefreshPolicy.isTerminal(
                APIErrorPayload(code: "SESSION_ID_REQUIRED", message: "Missing session")
            )
        )
        XCTAssertTrue(
            SessionRefreshPolicy.isTerminal(
                APIErrorPayload(
                    code: "SESSION_ID_REQUIRED",
                    message: "Missing session",
                    httpStatus: 401
                )
            )
        )
        XCTAssertFalse(
            SessionRefreshPolicy.isTerminal(
                APIErrorPayload(code: "VALIDATION_FAILED", message: "Bad input")
            )
        )
        XCTAssertTrue(SessionRefreshPolicy.isTerminal(APIClientError.signedOut))
        XCTAssertTrue(
            SessionRefreshPolicy.isTerminal(
                APIErrorPayload(
                    code: "REFRESH_TOKEN_REUSED",
                    message: "Reused",
                    httpStatus: 401
                )
            )
        )
        XCTAssertFalse(
            SessionRefreshPolicy.isTerminal(
                APIErrorPayload(
                    code: "REFRESH_TOKEN_REUSED",
                    message: "Unexpected server error",
                    httpStatus: 500
                )
            )
        )
    }

    func testRefreshSingleFlightMayOnlyBeSharedByTheSameSession() {
        let first = "550e8400-e29b-41d4-a716-446655440000"
        let replacement = "550e8400-e29b-41d4-a716-446655440001"

        XCTAssertTrue(SessionRefreshPolicy.matchesSessionID(first, current: first.uppercased()))
        XCTAssertFalse(SessionRefreshPolicy.matchesSessionID(first, current: replacement))
    }

    func testHomeRefreshSuppressesTaskAndTransportCancellationAlerts() {
        XCTAssertTrue(
            RefreshCancellationPolicy.shouldSuppress(
                CancellationError(),
                taskIsCancelled: false
            )
        )
        XCTAssertTrue(
            RefreshCancellationPolicy.shouldSuppress(
                URLError(.cancelled),
                taskIsCancelled: false
            )
        )
        XCTAssertTrue(
            RefreshCancellationPolicy.shouldSuppress(
                URLError(.timedOut),
                taskIsCancelled: true
            )
        )

        let wrapped = NSError(
            domain: "KitPayRefreshTests",
            code: 10,
            userInfo: [NSUnderlyingErrorKey: URLError(.cancelled) as NSError]
        )
        XCTAssertTrue(
            RefreshCancellationPolicy.shouldSuppress(wrapped, taskIsCancelled: false)
        )
    }

    func testHomeRefreshStillPresentsRealNetworkAndServerFailures() {
        XCTAssertFalse(
            RefreshCancellationPolicy.shouldSuppress(
                URLError(.timedOut),
                taskIsCancelled: false
            )
        )
        XCTAssertFalse(
            RefreshCancellationPolicy.shouldSuppress(
                APIClientError.httpStatus(500),
                taskIsCancelled: false
            )
        )
    }

    func testRefreshReplayNonceIsBoundToTheExactStoredRefreshToken() {
        let session = SessionTokens(
            accessToken: "access",
            refreshToken: "refresh-a",
            tokenType: "Bearer",
            accessExpiresAt: nil,
            refreshExpiresAt: nil,
            sessionId: "550e8400-e29b-41d4-a716-446655440000"
        )
        let attempt = SessionRefreshAttempt(
            sessionId: session.sessionId,
            refreshTokenFingerprint: SessionRefreshReplayPolicy.tokenFingerprint(session.refreshToken),
            replayNonce: "550e8400-e29b-41d4-a716-446655440001"
        )
        XCTAssertTrue(SessionRefreshReplayPolicy.matches(attempt, session: session))

        let rotated = SessionTokens(
            accessToken: "access-2",
            refreshToken: "refresh-b",
            tokenType: "Bearer",
            accessExpiresAt: nil,
            refreshExpiresAt: nil,
            sessionId: session.sessionId
        )
        XCTAssertFalse(SessionRefreshReplayPolicy.matches(attempt, session: rotated))
    }

    func testLateRefreshFailureCannotEraseReplacementOrRotatedCredentials() async throws {
        let namespace = "kit-session-invalidation-test-\(UUID().uuidString)"
        let refreshNamespace = "\(namespace)-refresh"
        defer {
            try? KeychainStore.remove(namespace)
            try? KeychainStore.remove(refreshNamespace)
        }
        let store = SessionStore(account: namespace, refreshAttemptAccount: refreshNamespace)
        let api = APIClient(sessionStore: store)
        let rejected = SessionTokens(
            accessToken: "old-access",
            refreshToken: "old-refresh",
            tokenType: "Bearer",
            accessExpiresAt: nil,
            refreshExpiresAt: nil,
            sessionId: "550e8400-e29b-41d4-a716-446655440000"
        )
        let rotated = SessionTokens(
            accessToken: "new-access",
            refreshToken: "new-refresh",
            tokenType: "Bearer",
            accessExpiresAt: nil,
            refreshExpiresAt: nil,
            sessionId: rejected.sessionId
        )
        let replacement = SessionTokens(
            accessToken: "replacement-access",
            refreshToken: "replacement-refresh",
            tokenType: "Bearer",
            accessExpiresAt: nil,
            refreshExpiresAt: nil,
            sessionId: "550e8400-e29b-41d4-a716-446655440001"
        )

        for newer in [rotated, replacement] {
            try await store.save(rejected)
            // The failed flight captured `rejected` before suspension. New credentials win
            // before its invalidation crosses into SessionStore's actor.
            try await store.save(newer)
            await api.invalidateSession(ifCurrent: rejected)
            let current = await store.current()
            XCTAssertEqual(current, newer)
            let restored = SessionStore(account: namespace, refreshAttemptAccount: refreshNamespace)
            let persisted = await restored.current()
            XCTAssertEqual(persisted, newer, "The Keychain must also retain the winning generation")
        }

        try await store.save(rejected)
        await api.invalidateSession(ifCurrent: rejected)
        let invalidated = await store.current()
        XCTAssertNil(invalidated, "A failure for the still-current generation must sign out")
        XCTAssertNil(try KeychainStore.data(for: namespace))
    }

    func testTransferStepUpIntentEncodesAnExplicitNullNote() throws {
        let request = CreateStepUpRequest(
            purpose: "wallet_transfer",
            intent: [
                "source_wallet_id": "source-wallet",
                "destination_wallet_id": "destination-wallet",
                "amount": "2500.00",
                "note": nil,
            ]
        )

        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let intent = try XCTUnwrap(object["intent"] as? [String: Any])

        XCTAssertTrue(intent.keys.contains("note"))
        XCTAssertTrue(intent["note"] is NSNull)
    }

    func testBiometricStepUpAssertionSendsNonceAndSignatureWithoutPIN() throws {
        let request = VerifyBiometricStepUpRequest(
            nonce: "server-nonce",
            signature: "base64url-signature"
        )

        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(object["nonce"] as? String, "server-nonce")
        XCTAssertEqual(object["signature"] as? String, "base64url-signature")
        XCTAssertEqual(Set(object.keys), ["nonce", "signature"])
    }

    func testCallParticipantInviteUsesOnlyCanonicalRecipientArrayField() throws {
        let recipients = [
            "550e8400-e29b-41d4-a716-446655440001",
            "550e8400-e29b-41d4-a716-446655440002",
        ]
        let request = InviteCallParticipantsRequest(recipientUserIds: recipients)
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(object["recipient_user_ids"] as? [String], recipients)
        XCTAssertEqual(Set(object.keys), ["recipient_user_ids"])
    }

    func testEmailLoginRequestUsesExactDeviceContract() throws {
        let request = EmailLoginRequest(
            email: "amina@example.test",
            password: "NotPersisted123",
            device: testDevice
        )

        let object = try jsonObject(request)
        let device = try XCTUnwrap(object["device"] as? [String: Any])

        XCTAssertEqual(object["email"] as? String, "amina@example.test")
        XCTAssertEqual(object["password"] as? String, "NotPersisted123")
        XCTAssertEqual(Set(object.keys), ["email", "password", "device"])
        XCTAssertEqual(device["installation_id"] as? String, "installation-1")
        XCTAssertEqual(device["name"] as? String, "Amina’s iPhone")
        XCTAssertEqual(device["platform"] as? String, "ios")
        XCTAssertEqual(device["app_version"] as? String, "1.2.3")
        XCTAssertEqual(device["os_version"] as? String, "iOS 19.0")
        XCTAssertEqual(device["model"] as? String, "iPhone")
        XCTAssertEqual(
            Set(device.keys),
            ["installation_id", "name", "platform", "app_version", "os_version", "model"]
        )
    }

    func testEmailTokenMessageResetAndTwoFactorRequestsUseExactKeys() throws {
        let token = String(repeating: "t", count: 64)
        let verification = try jsonObject(EmailVerificationRequest(token: token))
        let email = try jsonObject(EmailAddressRequest(email: "amina@example.test"))
        let reset = try jsonObject(
            PasswordResetRequest(
                token: token,
                password: "Replacement123",
                passwordConfirmation: "Replacement123"
            )
        )
        let twoFactor = try jsonObject(
            TwoFactorVerifyRequest(
                challengeId: "550e8400-e29b-41d4-a716-446655440000",
                code: "123456"
            )
        )

        XCTAssertEqual(verification["token"] as? String, token)
        XCTAssertEqual(Set(verification.keys), ["token"])
        XCTAssertEqual(email["email"] as? String, "amina@example.test")
        XCTAssertEqual(Set(email.keys), ["email"])
        XCTAssertEqual(reset["token"] as? String, token)
        XCTAssertEqual(reset["password"] as? String, "Replacement123")
        XCTAssertEqual(reset["password_confirmation"] as? String, "Replacement123")
        XCTAssertEqual(Set(reset.keys), ["token", "password", "password_confirmation"])
        XCTAssertEqual(
            twoFactor["challenge_id"] as? String,
            "550e8400-e29b-41d4-a716-446655440000"
        )
        XCTAssertEqual(twoFactor["code"] as? String, "123456")
        XCTAssertEqual(Set(twoFactor.keys), ["challenge_id", "code"])
    }

    func testEmailAccountResponsesDecodeBackendShapes() throws {
        let verification: EmailVerificationResult = try decode(
            """
            {
              "verified": true,
              "user": {"id": "user-1", "email": "amina@example.test"}
            }
            """
        )
        let message: EmailMessageResult = try decode(#"{"message":null}"#)
        let reset: PasswordResetResult = try decode(#"{"password_reset":true}"#)

        XCTAssertEqual(verification.verified, true)
        XCTAssertEqual(verification.user.email, "amina@example.test")
        XCTAssertEqual(
            EmailAccountResponsePolicy.verifiedEmail(from: verification),
            "amina@example.test"
        )
        XCTAssertNil(message.message)
        XCTAssertEqual(reset.passwordReset, true)
    }

    func testErrorEnvelopePreservesChallengeMetadataWhenDataHasAnotherShape() throws {
        let envelope: APIEnvelope<AuthResult> = try decode(
            """
            {
              "ok": false,
              "data": {},
              "error": {
                "code": "CHALLENGE_CODE_INVALID",
                "message": "The verification code is invalid.",
                "details": {"remaining_attempts": 0}
              }
            }
            """
        )

        XCTAssertFalse(envelope.ok)
        XCTAssertNil(envelope.data)
        XCTAssertEqual(envelope.error?.code, "CHALLENGE_CODE_INVALID")
        XCTAssertEqual(envelope.error?.remainingAttempts, 0)
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                APIEnvelope<AuthResult>.self,
                from: Data(#"{"ok":true,"data":{}}"#.utf8)
            )
        )
    }

    func testEmailCapabilitiesFailClosedForMissingFalseAndNullValues() throws {
        let enabled: CapabilitiesDTO = try decode(
            """
            {
              "currency": {"code": "UGX", "scale": "2"},
              "features": {"email_registration": true, "email_recovery": true},
              "authentication": {"phone_otp": true, "email_password": true, "mfa": true}
            }
            """
        )
        let unknown: CapabilitiesDTO = try decode(
            """
            {
              "currency": {"code": "UGX", "scale": "2"},
              "features": {"email_registration": null},
              "authentication": {"phone_otp": false}
            }
            """
        )

        XCTAssertTrue(enabled.supportsPhoneOTP)
        XCTAssertTrue(enabled.supportsEmailPassword)
        XCTAssertTrue(enabled.supportsMFA)
        XCTAssertTrue(enabled.supportsEmailRecovery)
        XCTAssertFalse(unknown.supportsPhoneOTP)
        XCTAssertFalse(unknown.supportsEmailPassword)
        XCTAssertFalse(unknown.supportsMFA)
        XCTAssertFalse(unknown.supportsEmailRecovery)
        // `email_registration` is retired: even served as true (the `enabled` payload above),
        // it is not a capability the app can read, and recovery does not inherit from it.
        XCTAssertFalse(enabled.featureIsWithdrawn("email_recovery"))
    }

    func testEmailNavigationGatesEntryButNeverStrandsTokenCompletion() {
        let unavailable = EmailAccountNavigationPolicy(capabilities: nil)
        XCTAssertFalse(unavailable.allows(.signIn))
        XCTAssertFalse(unavailable.allows(.forgotPassword))
        XCTAssertTrue(unavailable.allows(.verification))
        XCTAssertTrue(unavailable.allows(.resetPassword))

        let disabled = EmailAccountNavigationPolicy(
            emailPasswordEnabled: false,
            recoveryEnabled: false
        )
        XCTAssertFalse(disabled.allows(.signIn))
        XCTAssertFalse(disabled.allows(.forgotPassword))
        XCTAssertTrue(disabled.allows(.verification))
        XCTAssertTrue(disabled.allows(.resetPassword))

        let recoveryOnly = EmailAccountNavigationPolicy(
            emailPasswordEnabled: false,
            recoveryEnabled: true
        )
        XCTAssertFalse(recoveryOnly.allows(.signIn))
        XCTAssertTrue(recoveryOnly.allows(.forgotPassword))

        let enabled = EmailAccountNavigationPolicy(
            emailPasswordEnabled: true,
            recoveryEnabled: true
        )
        XCTAssertTrue(enabled.allows(.signIn))
        XCTAssertTrue(enabled.allows(.forgotPassword))
    }

    /// The registration affordance cannot come back through a stale server capability: the
    /// screen enum has no registration case, and the phone-first surface derives every route
    /// it offers from phone/email sign-in alone.
    func testStaleEmailRegistrationCapabilityGrantsNoAffordance() throws {
        let stale: CapabilitiesDTO = try decode(
            """
            {
              "currency": {"code": "UGX", "scale": "2"},
              "features": {"email_registration": true},
              "authentication": {"phone_otp": true, "email_password": true}
            }
            """
        )

        let access = PhoneFirstAuthAccessPolicy(capabilities: stale)
        XCTAssertEqual(access.primaryRoute, .phone)
        XCTAssertTrue(access.offersEmailSecondary)

        // Every reachable email screen is a sign-in or token-completion surface.
        let navigation = EmailAccountNavigationPolicy(capabilities: stale)
        XCTAssertTrue(navigation.allows(.signIn))
        XCTAssertTrue(navigation.allows(.verification))
        XCTAssertTrue(navigation.allows(.resetPassword))
        XCTAssertFalse(navigation.allows(.forgotPassword), "Recovery must gate on email_recovery alone.")
    }

    /// Phone is the sole primary route; email is a restrained secondary and the whole surface
    /// fails closed when the server has said nothing.
    func testPhoneFirstAccessPolicyRoutes() {
        let both = PhoneFirstAuthAccessPolicy(phoneOTPEnabled: true, emailPasswordEnabled: true)
        XCTAssertEqual(both.primaryRoute, .phone)
        XCTAssertTrue(both.offersEmailSecondary)

        let phoneOnly = PhoneFirstAuthAccessPolicy(phoneOTPEnabled: true, emailPasswordEnabled: false)
        XCTAssertEqual(phoneOnly.primaryRoute, .phone)
        XCTAssertFalse(phoneOnly.offersEmailSecondary)

        let emailOnly = PhoneFirstAuthAccessPolicy(phoneOTPEnabled: false, emailPasswordEnabled: true)
        XCTAssertEqual(emailOnly.primaryRoute, .email)
        XCTAssertFalse(emailOnly.offersEmailSecondary)

        let none = PhoneFirstAuthAccessPolicy(capabilities: nil)
        XCTAssertEqual(none.primaryRoute, .unavailable)
        XCTAssertFalse(none.offersEmailSecondary)
    }

    func testEmailValidationMatchesServerAndAndroidBoundaries() {
        XCTAssertEqual(
            EmailAccountValidation.normalizeName(" \tAmina\u{00A0}\n Yusuf \u{2029}"),
            "Amina Yusuf"
        )
        XCTAssertEqual(EmailAccountValidation.normalizeTag(" \u{2003}@Amina_01\u{0085}"), "amina_01")
        XCTAssertTrue(EmailAccountValidation.isValidName("Amina Yusuf"))
        XCTAssertTrue(EmailAccountValidation.isValidName("Am"))
        XCTAssertFalse(EmailAccountValidation.isValidName(String(repeating: "a", count: 121)))
        XCTAssertFalse(EmailAccountValidation.isValidName("Kit Pay User"))
        XCTAssertTrue(EmailAccountValidation.isValidTag("abc"))
        XCTAssertFalse(EmailAccountValidation.isValidTag(String(repeating: "a", count: 33)))
        XCTAssertTrue(EmailAccountValidation.isValidTag("@amina_01"))
        XCTAssertFalse(EmailAccountValidation.isValidTag("admin"))
        XCTAssertFalse(EmailAccountValidation.isValidTag("deleted_am1na"))
        XCTAssertFalse(EmailAccountValidation.isValidTag("kit_abcdefghij"))
        XCTAssertFalse(EmailAccountValidation.isValidTag("amina.yusuf"))

        XCTAssertTrue(EmailAccountValidation.isValidEmail(" amina@example.test "))
        XCTAssertFalse(EmailAccountValidation.isValidEmail("amina@example"))
        XCTAssertFalse(EmailAccountValidation.isValidEmail("am ina@example.test"))
        XCTAssertFalse(EmailAccountValidation.isValidEmail("amina@@example.test"))
        XCTAssertTrue(
            EmailAccountValidation.isValidEmail(
                String(repeating: "a", count: 241) + "@example.test"
            )
        )
        XCTAssertFalse(
            EmailAccountValidation.isValidEmail(
                String(repeating: "a", count: 242) + "@example.test"
            )
        )

        XCTAssertTrue(EmailAccountValidation.isStrongPassword("Uppercase123"))
        XCTAssertFalse(EmailAccountValidation.isStrongPassword("uppercase123"))
        XCTAssertFalse(EmailAccountValidation.isStrongPassword("UPPERCASE123"))
        XCTAssertFalse(EmailAccountValidation.isStrongPassword("UppercaseOnly"))
        XCTAssertFalse(EmailAccountValidation.isStrongPassword("Short1A"))
        XCTAssertTrue(
            EmailAccountValidation.isStrongPassword("A1" + String(repeating: "a", count: 1_022))
        )
        XCTAssertFalse(
            EmailAccountValidation.isStrongPassword("A1" + String(repeating: "a", count: 1_023))
        )
    }

    func testOpaqueTokenAndConfirmationValidationAreExact() {
        let token63 = String(repeating: "a", count: 63)
        let token64 = String(repeating: "a", count: 64)
        let token256 = String(repeating: "b", count: 256)
        let token257 = String(repeating: "b", count: 257)

        XCTAssertFalse(EmailAccountValidation.isValidOpaqueToken(token63))
        XCTAssertTrue(EmailAccountValidation.isValidOpaqueToken(" \n\(token64)\t"))
        XCTAssertTrue(EmailAccountValidation.isValidOpaqueToken(token256))
        XCTAssertFalse(EmailAccountValidation.isValidOpaqueToken(token257))
        XCTAssertEqual(
            EmailAccountValidation.passwordResetError(
                token: token64,
                password: "Replacement123",
                passwordConfirmation: "Different1234"
            ),
            .passwordMismatch
        )
    }

    func testAuthenticationResultStateMachineRecognizesPhoneAndTwoFactorOnly() throws {
        let phone: AuthResult = try decode(
            """
            {
              "state": "challenge_required",
              "challenge": {
                "id": "550e8400-e29b-41d4-a716-446655440000",
                "type": "phone_otp",
                "method": "sms",
                "destination": "+256•••678",
                "expires_at": "2026-08-20T12:05:00Z",
                "resend_after_seconds": 60
              },
              "session": null,
              "user": null
            }
            """
        )
        let twoFactor: AuthResult = try decode(
            """
            {
              "state": "challenge_required",
              "challenge": {
                "id": "550e8400-e29b-41d4-a716-446655440001",
                "type": "two_factor",
                "method": "totp",
                "destination": "Authenticator app",
                "expires_at": "2026-08-20T12:05:00Z",
                "resend_after_seconds": 60
              },
              "session": null,
              "user": null
            }
            """
        )
        let unsupported: AuthResult = try decode(
            """
            {
              "state": "challenge_required",
              "challenge": {"id": "challenge-3", "type": "email_verification"},
              "session": null,
              "user": null
            }
            """
        )

        XCTAssertEqual(AuthResultPolicy.disposition(for: phone), .challengeRequired(.phoneOTP))
        XCTAssertEqual(phone.challenge?.resendAfterSeconds, 60)
        XCTAssertEqual(AuthResultPolicy.disposition(for: twoFactor), .challengeRequired(.twoFactor))
        XCTAssertEqual(twoFactor.challenge?.method, "totp")
        XCTAssertEqual(AuthResultPolicy.disposition(for: unsupported), .invalid)
        let receivedAt = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-20T12:00:00Z")
        )
        XCTAssertTrue(
            AuthenticationChallengeContractPolicy.isValid(
                try XCTUnwrap(phone.challenge),
                expectedKind: .phoneOTP,
                at: receivedAt
            )
        )
        XCTAssertTrue(
            AuthenticationChallengeContractPolicy.isValid(
                try XCTUnwrap(twoFactor.challenge),
                expectedKind: .twoFactor,
                at: receivedAt
            )
        )

        let aliasWithoutPresentationMetadata = AuthChallenge(
            id: "550e8400-e29b-41d4-a716-446655440009",
            type: "otp",
            method: "sms",
            expiresAt: "2026-08-20T12:05:00Z"
        )
        XCTAssertEqual(aliasWithoutPresentationMetadata.kind, .phoneOTP)
        XCTAssertTrue(
            AuthenticationChallengeContractPolicy.isValid(
                aliasWithoutPresentationMetadata,
                expectedKind: .phoneOTP,
                at: receivedAt
            )
        )
        XCTAssertNil(
            AuthenticationChallengeTimingPolicy.secondsUntilResend(
                for: aliasWithoutPresentationMetadata,
                receivedAt: receivedAt,
                now: receivedAt
            )
        )
    }

    func testAuthenticationResultStateMachineRequiresCompleteAuthenticatedShape() throws {
        let authenticated: AuthResult = try decode(
            """
            {
              "state": "authenticated",
              "challenge": null,
              "session": {
                "access_token": "access",
                "refresh_token": "refresh",
                "token_type": "Bearer",
                "session_id": "550e8400-e29b-41d4-a716-446655440000"
              },
              "user": {"id": "user-1", "name": "Amina Yusuf", "tag": "amina_01"}
            }
            """
        )
        let missingUser: AuthResult = try decode(
            """
            {
              "state": "authenticated",
              "challenge": null,
              "session": {
                "access_token": "access",
                "refresh_token": "refresh",
                "token_type": "Bearer",
                "session_id": "550e8400-e29b-41d4-a716-446655440000"
              },
              "user": null
            }
            """
        )

        XCTAssertEqual(AuthResultPolicy.disposition(for: authenticated), .authenticated)
        XCTAssertEqual(AuthResultPolicy.disposition(for: missingUser), .invalid)
    }

    func testAuthenticationCodePolicySeparatesOTPAndRecoveryProofs() throws {
        let phone = AuthChallenge(
            id: "550e8400-e29b-41d4-a716-446655440000",
            type: "phone_otp"
        )
        let totp = AuthChallenge(
            id: "550e8400-e29b-41d4-a716-446655440001",
            type: "two_factor",
            method: "totp"
        )
        let emailMFA = AuthChallenge(
            id: "550e8400-e29b-41d4-a716-446655440002",
            type: "two_factor",
            method: "email"
        )

        XCTAssertEqual(AuthenticationCodePolicy.normalizedCode(" 123456 ", for: phone), "123456")
        XCTAssertNil(AuthenticationCodePolicy.normalizedCode("１２３４５６", for: phone))
        XCTAssertNil(AuthenticationCodePolicy.normalizedCode("12345A", for: phone))
        XCTAssertEqual(
            AuthenticationCodePolicy.normalizedCode("ab12-cd34 ef56-7890-abcd", for: totp),
            "AB12CD34EF567890ABCD"
        )
        XCTAssertNil(
            AuthenticationCodePolicy.normalizedCode("gb12-cd34-ef56-7890-abcd", for: totp)
        )
        XCTAssertNil(
            AuthenticationCodePolicy.normalizedCode("ab12!cd34-ef56-7890-abcd", for: totp)
        )
        XCTAssertNil(
            AuthenticationCodePolicy.normalizedCode("ab12-cd34-ef56-7890-abcd", for: emailMFA)
        )
        XCTAssertEqual(AuthenticationCodePolicy.normalizedCode("654321", for: emailMFA), "654321")
    }

    /// Live entry canonicalizes every numeral a localized keyboard or paste produces into the
    /// ASCII digits the strict submission policy requires; the policy itself stays strict.
    func testAuthenticationCodeEntrySanitizationCanonicalizesLocalizedDigits() {
        XCTAssertEqual(AuthenticationCodePolicy.sanitizedSixDigitEntry("123456"), "123456")
        // Full-width, Arabic-Indic, and Devanagari numerals become ASCII instead of jamming
        // the field with characters the verify button silently rejects.
        XCTAssertEqual(AuthenticationCodePolicy.sanitizedSixDigitEntry("１２３４５６"), "123456")
        XCTAssertEqual(AuthenticationCodePolicy.sanitizedSixDigitEntry("٠١٢٣٤٥"), "012345")
        XCTAssertEqual(AuthenticationCodePolicy.sanitizedSixDigitEntry("०१२३४५"), "012345")
        // Pasted codes shed separators and prose around the digits.
        XCTAssertEqual(AuthenticationCodePolicy.sanitizedSixDigitEntry("123 456"), "123456")
        XCTAssertEqual(AuthenticationCodePolicy.sanitizedSixDigitEntry("123-456"), "123456")
        XCTAssertEqual(
            AuthenticationCodePolicy.sanitizedSixDigitEntry("Your Kit code is 987654."),
            "987654"
        )
        // Entry caps at six digits and drops everything that is not a single decimal digit —
        // including multi-digit numerals like Roman numerals and non-digit numerics.
        XCTAssertEqual(AuthenticationCodePolicy.sanitizedSixDigitEntry("1234567890"), "123456")
        XCTAssertEqual(AuthenticationCodePolicy.sanitizedSixDigitEntry("Ⅻ½abc"), "")
        XCTAssertEqual(AuthenticationCodePolicy.sanitizedSixDigitEntry(""), "")
        // The sanitized result satisfies the strict submission policy.
        let phone = AuthChallenge(
            id: "550e8400-e29b-41d4-a716-446655440000",
            type: "phone_otp"
        )
        XCTAssertEqual(
            AuthenticationCodePolicy.normalizedCode(
                AuthenticationCodePolicy.sanitizedSixDigitEntry("٠١٢٣٤٥"),
                for: phone
            ),
            "012345"
        )
    }

    func testAuthenticationChallengeTimingHonorsExpiryAndRelativeResendCooldown() throws {
        let challenge = AuthChallenge(
            id: "550e8400-e29b-41d4-a716-446655440000",
            type: "phone_otp",
            method: "sms",
            expiresAt: "2026-08-20T12:05:00Z",
            resendAfterSeconds: 60
        )
        let receivedAt = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-20T12:00:00Z")
        )
        let beforeResend = receivedAt.addingTimeInterval(0.1)
        let atResend = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-20T12:01:00Z")
        )
        let beforeExpiry = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-20T12:04:59Z")
        )
        let atExpiry = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-20T12:05:00Z")
        )

        XCTAssertEqual(
            AuthenticationChallengeTimingPolicy.secondsUntilResend(
                for: challenge,
                receivedAt: receivedAt,
                now: beforeResend
            ),
            60
        )
        XCTAssertEqual(
            AuthenticationChallengeTimingPolicy.secondsUntilResend(
                for: challenge,
                receivedAt: receivedAt,
                now: atResend
            ),
            0
        )
        XCTAssertFalse(AuthenticationChallengeTimingPolicy.isExpired(challenge, at: beforeExpiry))
        XCTAssertTrue(AuthenticationChallengeTimingPolicy.isExpired(challenge, at: atExpiry))
    }

    func testPhoneChallengeResendRequiresStableIDAndRejectsMalformedTiming() throws {
        let receivedAt = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-20T12:00:00Z")
        )
        let previous = AuthChallenge(
            id: "550e8400-e29b-41d4-a716-446655440000",
            type: "phone_otp",
            method: "sms",
            destination: "+256•••002",
            expiresAt: "2026-08-20T12:05:00Z",
            resendAfterSeconds: 60
        )
        let stable = AuthChallenge(
            id: previous.id,
            type: "phone_otp",
            method: "sms",
            destination: "+256•••002",
            expiresAt: "2026-08-20T12:06:00Z",
            resendAfterSeconds: 60
        )
        let rotated = AuthChallenge(
            id: "550e8400-e29b-41d4-a716-446655440099",
            type: stable.type,
            method: stable.method,
            destination: stable.destination,
            expiresAt: stable.expiresAt,
            resendAfterSeconds: stable.resendAfterSeconds
        )
        let malformedExpiry = AuthChallenge(
            id: stable.id,
            type: stable.type,
            method: stable.method,
            destination: stable.destination,
            expiresAt: "not-a-date",
            resendAfterSeconds: stable.resendAfterSeconds
        )
        let unboundedCooldown = AuthChallenge(
            id: stable.id,
            type: stable.type,
            method: stable.method,
            destination: stable.destination,
            expiresAt: stable.expiresAt,
            resendAfterSeconds: 1e300
        )
        let differentDestination = AuthChallenge(
            id: stable.id,
            type: stable.type,
            method: stable.method,
            destination: "+256•••201",
            expiresAt: stable.expiresAt,
            resendAfterSeconds: stable.resendAfterSeconds
        )

        XCTAssertTrue(
            AuthenticationChallengeContractPolicy.acceptsPhoneRenewal(
                from: previous,
                to: stable,
                at: receivedAt
            )
        )
        XCTAssertEqual(previous.id, stable.id)
        XCTAssertFalse(
            AuthenticationChallengeContractPolicy.acceptsPhoneRenewal(
                from: previous,
                to: rotated,
                at: receivedAt
            )
        )
        XCTAssertTrue(AuthenticationChallengeTimingPolicy.isExpired(malformedExpiry, at: receivedAt))
        XCTAssertFalse(
            AuthenticationChallengeContractPolicy.acceptsPhoneRenewal(
                from: previous,
                to: malformedExpiry,
                at: receivedAt
            )
        )
        XCTAssertFalse(
            AuthenticationChallengeContractPolicy.acceptsPhoneRenewal(
                from: previous,
                to: differentDestination,
                at: receivedAt
            )
        )
        XCTAssertNil(
            AuthenticationChallengeTimingPolicy.secondsUntilResend(
                for: unboundedCooldown,
                receivedAt: receivedAt,
                now: receivedAt
            )
        )
    }

    func testTerminalChallengeErrorsIncludeTheFinalFailedAttempt() throws {
        let finalAttempt: APIErrorPayload = try decode(
            """
            {
              "code": "CHALLENGE_CODE_INVALID",
              "message": "The verification code is invalid.",
              "details": {"remaining_attempts": 0}
            }
            """
        )
        let retryable = APIErrorPayload(
            code: "CHALLENGE_CODE_INVALID",
            message: "Try again",
            remainingAttempts: 2
        )
        let heterogeneousDetails: APIErrorPayload = try decode(
            #"{"code":"OTHER_ERROR","message":"Try later","details":[]}"#
        )

        XCTAssertEqual(finalAttempt.remainingAttempts, 0)
        XCTAssertTrue(AuthenticationChallengeErrorPolicy.isTerminal(finalAttempt))
        XCTAssertFalse(AuthenticationChallengeErrorPolicy.isTerminal(retryable))
        XCTAssertEqual(heterogeneousDetails.code, "OTHER_ERROR")
        XCTAssertEqual(heterogeneousDetails.message, "Try later")
        XCTAssertNil(heterogeneousDetails.remainingAttempts)
        XCTAssertTrue(
            AuthenticationChallengeErrorPolicy.isTerminal(
                APIErrorPayload(code: "CHALLENGE_EXPIRED", message: "Expired")
            )
        )
    }

    func testChallengeResendPreservesOnlyDefinitiveRetryableFailures() {
        XCTAssertTrue(
            AuthenticationChallengeRecoveryPolicy.preservesChallenge(
                afterResendFailure: APIErrorPayload(
                    code: "RATE_LIMITED",
                    message: "Try again shortly.",
                    httpStatus: 429,
                    retryAfter: 30
                )
            )
        )
        XCTAssertFalse(
            AuthenticationChallengeRecoveryPolicy.preservesChallenge(
                afterResendFailure: APIErrorPayload(
                    code: "CHALLENGE_EXPIRED",
                    message: "Expired",
                    httpStatus: 400
                )
            )
        )
        XCTAssertFalse(
            AuthenticationChallengeRecoveryPolicy.preservesChallenge(
                afterResendFailure: URLError(.timedOut)
            )
        )
        XCTAssertFalse(
            AuthenticationChallengeRecoveryPolicy.preservesChallenge(
                afterResendFailure: APIClientError.invalidPayload(status: 502)
            )
        )
    }

    func testSingleUseMutationAmbiguityRoutesAwayFromUnsafeReplay() {
        XCTAssertTrue(
            IrreversibleAuthenticationMutationPolicy.completionIsUncertain(
                after: APIClientError.invalidPayload(status: 200)
            )
        )
        XCTAssertTrue(
            IrreversibleAuthenticationMutationPolicy.completionIsUncertain(
                after: URLError(.networkConnectionLost)
            )
        )
        XCTAssertFalse(
            IrreversibleAuthenticationMutationPolicy.completionIsUncertain(
                after: APIErrorPayload(
                    code: "RESET_TOKEN_INVALID",
                    message: "Invalid token",
                    httpStatus: 422
                )
            )
        )
        XCTAssertFalse(
            IrreversibleAuthenticationMutationPolicy.completionIsUncertain(
                after: APIClientError.signedOut
            )
        )
    }

    func testSensitiveInputLifecyclePolicy() throws {
        XCTAssertTrue(
            AuthenticationSecretLifecyclePolicy.shouldClear(afterSuccessfulRequest: true)
        )
        XCTAssertFalse(
            AuthenticationSecretLifecyclePolicy.shouldClear(afterSuccessfulRequest: false)
        )
        XCTAssertTrue(AuthenticationSecretLifecyclePolicy.shouldConceal(sceneIsActive: false))
        XCTAssertFalse(AuthenticationSecretLifecyclePolicy.shouldConceal(sceneIsActive: true))
    }

    func testMFAFactorCodesNormalizeOnlySupportedProofFormats() throws {
        XCTAssertEqual(MFAFactorCodePolicy.normalizedSixDigitCode(" 123456 "), "123456")
        XCTAssertNil(MFAFactorCodePolicy.normalizedSixDigitCode("12345a"))
        XCTAssertEqual(
            MFAFactorCodePolicy.normalizedFactorCode("0123-4567-89ab-cdef-0123"),
            "0123456789ABCDEF0123"
        )
        XCTAssertNil(MFAFactorCodePolicy.normalizedFactorCode("G123-4567-89AB-CDEF-0123"))
        XCTAssertNil(MFAFactorCodePolicy.normalizedFactorCode("0123!4567-89AB-CDEF-0123"))

        let request = MFAFactorRequest(code: "0123456789ABCDEF0123")
        let object = try jsonObject(request)
        XCTAssertEqual(object["code"] as? String, "0123456789ABCDEF0123")
        XCTAssertEqual(Set(object.keys), ["code"])

        XCTAssertTrue(
            APIRequestBodyPolicy.encodesBody(
                for: "DELETE",
                includeBodyForDelete: true
            )
        )
        XCTAssertFalse(APIRequestBodyPolicy.encodesBody(for: "DELETE"))
        XCTAssertFalse(APIRequestBodyPolicy.encodesBody(for: "GET"))
        XCTAssertTrue(APIRequestBodyPolicy.encodesBody(for: "POST"))
    }

    func testMFARecoveryCodesMustBeCompleteUniqueAndWellFormed() {
        let complete = (0 ..< MFAFactorCodePolicy.requiredRecoveryCodeCount).map {
            String(format: "%020X", $0)
        }
        let formatted = MFAFactorCodePolicy.validatedRecoveryCodes(complete)

        XCTAssertEqual(formatted?.count, 10)
        XCTAssertEqual(formatted?.first, "0000-0000-0000-0000-0000")
        XCTAssertNil(MFAFactorCodePolicy.validatedRecoveryCodes(nil))
        XCTAssertNil(MFAFactorCodePolicy.validatedRecoveryCodes([]))
        XCTAssertNil(MFAFactorCodePolicy.validatedRecoveryCodes(Array(complete.prefix(9))))
        XCTAssertNil(
            MFAFactorCodePolicy.validatedRecoveryCodes([
                complete[0], complete[0], complete[2], complete[3], complete[4],
                complete[5], complete[6], complete[7], complete[8], complete[9],
            ])
        )
        var malformed = complete
        malformed[5] = "not-a-recovery-code"
        XCTAssertNil(MFAFactorCodePolicy.validatedRecoveryCodes(malformed))
    }

    func testRecoveryCodePresentationIsNumberedAccessibleAndExportable() throws {
        let complete = (0 ..< MFAFactorCodePolicy.requiredRecoveryCodeCount).map {
            String(format: "%020X", $0)
        }
        let codes = try XCTUnwrap(MFAFactorCodePolicy.validatedRecoveryCodes(complete))
        let items = MFARecoveryCodePresentationPolicy.items(for: codes)
        let export = MFARecoveryCodePresentationPolicy.exportText(for: codes)

        XCTAssertEqual(items.count, 10)
        XCTAssertEqual(items.first?.accessibilityLabel, "Recovery code 1")
        XCTAssertEqual(items.first?.accessibilityValue, "0000 0000 0000 0000 0000")
        XCTAssertTrue(export.hasPrefix("Kit Pay recovery codes\n\n1. "))
        for code in codes {
            XCTAssertTrue(export.contains(code))
        }
        XCTAssertTrue(export.hasSuffix("Each code works once. Store them privately."))
    }

    func testTOTPEnrollmentAcceptsOnlyTheBoundAuthenticatorDeepLinkBeforeExpiry() throws {
        let enrollment: TOTPEnrollmentDTO = try decode(
            """
            {
              "enrollment_id": "550e8400-e29b-41d4-a716-446655440000",
              "secret": "JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP",
              "provisioning_uri": "otpauth://totp/Kit%20Pay%3Aamina%40example.test?secret=JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP&issuer=Kit%20Pay&algorithm=SHA1&digits=6&period=30",
              "expires_at": "2026-08-20T12:10:00Z"
            }
            """
        )
        let beforeExpiry = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-20T12:00:00Z")
        )
        let atExpiry = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-20T12:10:00Z")
        )

        XCTAssertNotNil(
            TOTPEnrollmentPolicy.validatedProvisioningURL(
                for: enrollment,
                at: beforeExpiry
            )
        )
        XCTAssertTrue(TOTPEnrollmentPolicy.isValid(enrollment, at: beforeExpiry))
        XCTAssertTrue(TOTPEnrollmentPolicy.isExpired(enrollment, at: atExpiry))
        XCTAssertNil(
            TOTPEnrollmentPolicy.validatedProvisioningURL(for: enrollment, at: atExpiry)
        )
        XCTAssertEqual(
            TOTPEnrollmentPolicy.displaySecret(enrollment.secret),
            "JBSW Y3DP EHPK 3PXP JBSW Y3DP EHPK 3PXP"
        )
        XCTAssertEqual(
            TOTPEnrollmentPolicy.accessibilityValue(forSecret: enrollment.secret),
            enrollment.secret.map(String.init).joined(separator: " ")
        )

        let substitutedSecret = TOTPEnrollmentDTO(
            enrollmentId: enrollment.enrollmentId,
            secret: enrollment.secret,
            provisioningURI: enrollment.provisioningURI.replacingOccurrences(
                of: "secret=JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP",
                with: "secret=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
            ),
            expiresAt: enrollment.expiresAt
        )
        XCTAssertNil(
            TOTPEnrollmentPolicy.validatedProvisioningURL(
                for: substitutedSecret,
                at: beforeExpiry
            )
        )

        let duplicateIssuer = TOTPEnrollmentDTO(
            enrollmentId: enrollment.enrollmentId,
            secret: enrollment.secret,
            provisioningURI: enrollment.provisioningURI + "&issuer=Kit%20Pay",
            expiresAt: enrollment.expiresAt
        )
        XCTAssertNil(
            TOTPEnrollmentPolicy.validatedProvisioningURL(
                for: duplicateIssuer,
                at: beforeExpiry
            )
        )
        let mismatchedLabelIssuer = TOTPEnrollmentDTO(
            enrollmentId: enrollment.enrollmentId,
            secret: enrollment.secret,
            provisioningURI: enrollment.provisioningURI.replacingOccurrences(
                of: "otpauth://totp/Kit%20Pay%3A",
                with: "otpauth://totp/Other%3A"
            ),
            expiresAt: enrollment.expiresAt
        )
        XCTAssertNil(
            TOTPEnrollmentPolicy.validatedProvisioningURL(
                for: mismatchedLabelIssuer,
                at: beforeExpiry
            )
        )
        let emptyLabelAccount = TOTPEnrollmentDTO(
            enrollmentId: enrollment.enrollmentId,
            secret: enrollment.secret,
            provisioningURI: enrollment.provisioningURI.replacingOccurrences(
                of: "Kit%20Pay%3Aamina%40example.test",
                with: "Kit%20Pay%3A"
            ),
            expiresAt: enrollment.expiresAt
        )
        XCTAssertNil(
            TOTPEnrollmentPolicy.validatedProvisioningURL(
                for: emptyLabelAccount,
                at: beforeExpiry
            )
        )
        XCTAssertTrue(
            TOTPEnrollmentErrorPolicy.isTerminal(
                APIErrorPayload(code: "MFA_ENROLLMENT_EXPIRED", message: "Expired")
            )
        )
        XCTAssertFalse(
            TOTPEnrollmentErrorPolicy.isTerminal(
                APIErrorPayload(code: "MFA_CODE_INVALID", message: "Try again")
            )
        )
    }

    func testSessionAccountBindingRejectsCrossAccountReuseAndSurvivesCoding() throws {
        let wireSession: SessionTokens = try decode(
            """
            {
              "access_token": "access",
              "refresh_token": "refresh",
              "token_type": "Bearer",
              "session_id": "550e8400-e29b-41d4-a716-446655440000"
            }
            """
        )
        XCTAssertNil(wireSession.accountId)

        let bound = try XCTUnwrap(wireSession.bound(to: "user-a"))
        XCTAssertEqual(bound.accountId, "user-a")
        XCTAssertNil(bound.bound(to: "user-b"))
        XCTAssertTrue(
            SessionAccountBindingPolicy.matches(
                bound,
                profile: UserProfile(
                    id: "USER-A",
                    name: "Amina",
                    email: nil,
                    phone: nil,
                    tag: "amina",
                    kycStatus: nil,
                    paymentPinSet: nil,
                    mfaEnabled: nil,
                    profileSetupRequired: false
                )
            )
        )
        XCTAssertFalse(
            SessionAccountBindingPolicy.matches(
                bound,
                profile: UserProfile(
                    id: "user-b",
                    name: "Binta",
                    email: nil,
                    phone: nil,
                    tag: "binta",
                    kycStatus: nil,
                    paymentPinSet: nil,
                    mfaEnabled: nil,
                    profileSetupRequired: false
                )
            )
        )

        let restored = try JSONDecoder().decode(
            SessionTokens.self,
            from: JSONEncoder().encode(bound)
        )
        XCTAssertEqual(restored, bound)
    }

    func testAuthenticatedSessionContractRejectsUnusableCredentials() throws {
        let valid = SessionTokens(
            accessToken: "access",
            refreshToken: "refresh",
            tokenType: "Bearer",
            accessExpiresAt: nil,
            refreshExpiresAt: nil,
            sessionId: "550e8400-e29b-41d4-a716-446655440000"
        )
        XCTAssertTrue(SessionCredentialContractPolicy.isValid(valid))
        XCTAssertNotNil(valid.bound(to: "user-1"))

        for invalid in [
            SessionTokens(
                accessToken: "",
                refreshToken: valid.refreshToken,
                tokenType: valid.tokenType,
                accessExpiresAt: nil,
                refreshExpiresAt: nil,
                sessionId: valid.sessionId
            ),
            SessionTokens(
                accessToken: valid.accessToken,
                refreshToken: "refresh token",
                tokenType: valid.tokenType,
                accessExpiresAt: nil,
                refreshExpiresAt: nil,
                sessionId: valid.sessionId
            ),
            SessionTokens(
                accessToken: valid.accessToken,
                refreshToken: valid.refreshToken,
                tokenType: "Basic",
                accessExpiresAt: nil,
                refreshExpiresAt: nil,
                sessionId: valid.sessionId
            ),
            SessionTokens(
                accessToken: valid.accessToken,
                refreshToken: valid.refreshToken,
                tokenType: valid.tokenType,
                accessExpiresAt: nil,
                refreshExpiresAt: nil,
                sessionId: "not-a-session-id"
            ),
        ] {
            XCTAssertFalse(SessionCredentialContractPolicy.isValid(invalid))
            XCTAssertNil(invalid.bound(to: "user-1"))
        }

        let malformedResult: AuthResult = try decode(
            """
            {
              "state": "authenticated",
              "challenge": null,
              "session": {
                "access_token": "",
                "refresh_token": "refresh",
                "token_type": "Bearer",
                "session_id": "550e8400-e29b-41d4-a716-446655440000"
              },
              "user": {"id": "user-1"}
            }
            """
        )
        XCTAssertEqual(AuthResultPolicy.disposition(for: malformedResult), .invalid)
    }

    func testLegacySessionBindsOnlyToTheAuthenticatedBootstrapAccount() throws {
        let legacy: SessionTokens = try decode(
            """
            {
              "access_token": "access",
              "refresh_token": "refresh",
              "token_type": "Bearer",
              "session_id": "550e8400-e29b-41d4-a716-446655440000"
            }
            """
        )
        let staleCachedProfile = UserProfile(
            id: "550e8400-e29b-41d4-a716-446655440001",
            name: "Cached account",
            email: nil,
            phone: nil,
            tag: "cached",
            kycStatus: nil,
            paymentPinSet: nil,
            mfaEnabled: nil,
            profileSetupRequired: false
        )
        let authenticatedProfile = UserProfile(
            id: "550e8400-e29b-41d4-a716-446655440002",
            name: "Authenticated account",
            email: nil,
            phone: nil,
            tag: "authenticated",
            kycStatus: nil,
            paymentPinSet: nil,
            mfaEnabled: nil,
            profileSetupRequired: false
        )

        let migrated = try XCTUnwrap(
            SessionAccountBindingPolicy.bindLegacySession(
                legacy,
                authenticatedProfile: authenticatedProfile
            )
        )
        XCTAssertEqual(migrated.accountId, authenticatedProfile.id)
        XCTAssertFalse(
            SessionAccountBindingPolicy.matches(migrated, profile: staleCachedProfile)
        )
        XCTAssertTrue(
            SessionAccountBindingPolicy.matches(migrated, profile: authenticatedProfile)
        )
        XCTAssertNil(
            SessionAccountBindingPolicy.bindLegacySession(
                migrated,
                authenticatedProfile: staleCachedProfile
            )
        )

        var state = PersistedState.empty
        state.bindAuthenticatedProfile(staleCachedProfile)
        state.bindAuthenticatedProfile(authenticatedProfile)
        XCTAssertEqual(state.profile?.id, authenticatedProfile.id)
        XCTAssertEqual(state.communicationOwnerUserID, authenticatedProfile.id)
        XCTAssertTrue(
            SessionAccountBindingPolicy.restorationProjectionMatches(
                state,
                expectedProfileID: authenticatedProfile.id.uppercased(),
                expectedOwnerID: authenticatedProfile.id.uppercased()
            )
        )
        XCTAssertFalse(
            SessionAccountBindingPolicy.restorationProjectionMatches(
                state,
                expectedProfileID: staleCachedProfile.id,
                expectedOwnerID: staleCachedProfile.id
            )
        )

        let refreshed = SessionTokens(
            accessToken: "rotated-access",
            refreshToken: "rotated-refresh",
            tokenType: "Bearer",
            accessExpiresAt: nil,
            refreshExpiresAt: nil,
            sessionId: migrated.sessionId,
            accountId: authenticatedProfile.id.uppercased()
        )
        XCTAssertTrue(
            SessionAccountBindingPolicy.identifiesSameAccountSession(migrated, refreshed)
        )
        XCTAssertFalse(
            SessionAccountBindingPolicy.identifiesSameAccountSession(legacy, refreshed)
        )
    }

    private var testDevice: DeviceRegistration {
        DeviceRegistration(
            installationId: "installation-1",
            name: "Amina’s iPhone",
            appVersion: "1.2.3",
            osVersion: "iOS 19.0",
            model: "iPhone"
        )
    }

    private func jsonObject<Value: Encodable>(_ value: Value) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func decode<Value: Decodable>(_ json: String) throws -> Value {
        try JSONDecoder().decode(Value.self, from: Data(json.utf8))
    }
}
