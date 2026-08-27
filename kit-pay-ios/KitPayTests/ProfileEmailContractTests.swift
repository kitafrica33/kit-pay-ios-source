import Foundation
import XCTest
@testable import KitPay

final class ProfileEmailContractTests: XCTestCase {
    private let userID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let sessionID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    private let issuedAt = Date(timeIntervalSince1970: 1_776_513_600) // 2026-04-18T12:00:00Z

    func testAndroidChallengeContractNormalizesEmailAndRoundsCooldownUp() throws {
        let result = try decodeResult(
            """
            {
              "state": "challenge_required",
              "challenge": {
                "id": "email-challenge",
                "type": "email_attachment",
                "method": "email",
                "destination": "a***@example.test",
                "expires_at": "2026-04-18T12:05:00Z",
                "resend_after_seconds": 59.021593
              },
              "user": null
            }
            """
        )

        let challenge = try XCTUnwrap(
            ProfileEmailChallengePolicy.challenge(
                from: result,
                requestedEmail: " Amina@Example.Test ",
                ownerUserID: userID,
                sessionID: sessionID,
                issuedAt: issuedAt
            )
        )

        XCTAssertEqual(challenge.id, "email-challenge")
        XCTAssertEqual(challenge.destination, "a***@example.test")
        XCTAssertEqual(challenge.requestedEmail, "amina@example.test")
        XCTAssertEqual(challenge.resendAfterSeconds, 60)
        XCTAssertTrue(ProfileEmailChallengePolicy.isValid(challenge, at: issuedAt))
        XCTAssertTrue(
            ProfileEmailChallengePolicy.belongs(
                challenge,
                toUserID: userID,
                sessionID: sessionID
            )
        )
        XCTAssertFalse(
            ProfileEmailChallengePolicy.belongs(
                challenge,
                toUserID: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
                sessionID: sessionID
            )
        )
    }

    func testChallengeFailsClosedForMixedExpiredOrUnknownShapes() throws {
        let mixed = try decodeResult(
            """
            {
              "state": "challenge_required",
              "challenge": {
                "id": "email-challenge",
                "type": "email_attachment",
                "method": "email",
                "destination": "a***@example.test",
                "expires_at": "2026-04-18T12:05:00Z"
              },
              "session": {
                "access_token": "access",
                "refresh_token": "refresh",
                "token_type": "Bearer",
                "session_id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
              }
            }
            """
        )
        XCTAssertNil(validatedChallenge(from: mixed))

        let expired = try decodeResult(
            challengeJSON(expiresAt: "2026-04-18T11:59:59Z")
        )
        XCTAssertNil(validatedChallenge(from: expired))

        let wrongType = try decodeResult(
            challengeJSON(expiresAt: "2026-04-18T12:05:00Z", type: "phone_otp")
        )
        XCTAssertNil(validatedChallenge(from: wrongType))

        XCTAssertThrowsError(
            try decodeResult(
                challengeJSON(
                    expiresAt: "2026-04-18T12:05:00Z",
                    extraChallengeField: #", "code": "123456""#
                )
            )
        )
        XCTAssertThrowsError(
            try decodeResult(
                """
                {
                  "state": "challenge_required",
                  "challenge": {
                    "id": "email-challenge",
                    "type": "email_attachment",
                    "method": "email",
                    "destination": "a***@example.test"
                  },
                  "proof": "unexpected"
                }
                """
            )
        )
    }

    func testMissingCooldownUsesConservativeLocalBackoff() throws {
        let result = try decodeResult(
            challengeJSON(expiresAt: nil, resendAfterSeconds: nil)
        )
        let challenge = try XCTUnwrap(validatedChallenge(from: result))
        XCTAssertEqual(challenge.resendAfterSeconds, 60)

        let availableAt = ProfileEmailChallengePolicy.resendAvailableAt(
            for: challenge,
            from: issuedAt
        )
        XCTAssertEqual(
            ProfileEmailChallengePolicy.secondsUntilResend(
                availableAt: availableAt,
                now: issuedAt.addingTimeInterval(0.2)
            ),
            60
        )
        XCTAssertEqual(
            ProfileEmailChallengePolicy.secondsUntilResend(
                availableAt: availableAt,
                now: issuedAt.addingTimeInterval(60)
            ),
            0
        )
    }

    func testVerificationCodeAndRequestsUseExactStrictWireShape() throws {
        XCTAssertEqual(ProfileEmailVerificationCodePolicy.normalizedCode(" 123456 "), "123456")
        XCTAssertNil(ProfileEmailVerificationCodePolicy.normalizedCode("12345"))
        XCTAssertNil(ProfileEmailVerificationCodePolicy.normalizedCode("12345a"))
        XCTAssertNil(ProfileEmailVerificationCodePolicy.normalizedCode("１２３４５６"))

        let address = try ProfileEmailAddressRequest(email: " Amina@Example.Test ")
        XCTAssertEqual(
            try object(address) as NSDictionary,
            ["email": "amina@example.test"] as NSDictionary
        )

        let verification = try ProfileEmailVerificationRequest(
            challengeId: "email-challenge",
            code: "123456"
        )
        XCTAssertEqual(
            try object(verification) as NSDictionary,
            ["challenge_id": "email-challenge", "code": "123456"] as NSDictionary
        )
        XCTAssertThrowsError(
            try ProfileEmailVerificationRequest(
                challengeId: "email-challenge",
                code: "12345"
            )
        )
        XCTAssertEqual(ProfileEmailAPIEndpoint.request.path, "profile/email")
        XCTAssertEqual(ProfileEmailAPIEndpoint.verify.path, "profile/email/verify")
    }

    func testProfileFlagsDecodeCompatiblyAndVerifiedResponseIsAccountBound() throws {
        let legacy: UserProfile = try decode(
            """
            {
              "id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
              "name": "Amina",
              "email": null,
              "phone": "+256700000200",
              "tag": "amina"
            }
            """
        )
        XCTAssertNil(legacy.emailVerified)
        XCTAssertNil(legacy.phoneVerified)

        let current = profile(
            email: nil,
            emailVerified: nil,
            phoneVerified: true,
            avatarURL: "https://pay.kit.africa/media/avatar.jpg"
        )
        let response = profile(
            name: nil,
            email: "AMINA@EXAMPLE.TEST",
            phone: nil,
            emailVerified: true,
            phoneVerified: nil,
            avatarURL: nil
        )
        let challenge = try XCTUnwrap(
            validatedChallenge(
                from: decodeResult(challengeJSON(expiresAt: "2026-04-18T12:05:00Z"))
            )
        )
        let verified = try XCTUnwrap(
            ProfileEmailVerificationResponsePolicy.validatedProfile(
                response,
                for: challenge,
                currentProfile: current
            )
        )
        XCTAssertEqual(verified.email, "amina@example.test")
        XCTAssertEqual(verified.emailVerified, true)
        XCTAssertEqual(verified.phoneVerified, true)
        XCTAssertEqual(verified.name, "Amina Yusuf")
        XCTAssertEqual(verified.phone, "+256700000200")
        XCTAssertEqual(verified.avatarURL, current.avatarURL)

        let wrongAccount = profile(
            id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
            email: "amina@example.test",
            emailVerified: true
        )
        XCTAssertNil(
            ProfileEmailVerificationResponsePolicy.validatedProfile(
                wrongAccount,
                for: challenge,
                currentProfile: current
            )
        )
        var unverified = response
        unverified.emailVerified = false
        XCTAssertNil(
            ProfileEmailVerificationResponsePolicy.validatedProfile(
                unverified,
                for: challenge,
                currentProfile: current
            )
        )
    }

    func testProfileRowMatchesAndroidAttachVerifyAndVerifiedStates() {
        XCTAssertEqual(
            ProfileEmailPresentationPolicy.presentation(
                profile: profile(email: nil, emailVerified: nil),
                attachmentAvailable: true
            ),
            ProfileEmailPresentation(
                title: "Add email address",
                subtitle: "Add a verified contact and recovery address",
                canAttach: true
            )
        )
        XCTAssertEqual(
            ProfileEmailPresentationPolicy.presentation(
                profile: profile(email: "amina@example.test", emailVerified: false),
                attachmentAvailable: true
            ).title,
            "Verify email address"
        )
        let verified = ProfileEmailPresentationPolicy.presentation(
            profile: profile(email: "amina@example.test", emailVerified: true),
            attachmentAvailable: true
        )
        XCTAssertFalse(verified.canAttach)
        XCTAssertTrue(verified.subtitle.contains("Verified"))

        let unavailable = ProfileEmailPresentationPolicy.presentation(
            profile: profile(email: nil, emailVerified: nil),
            attachmentAvailable: false
        )
        XCTAssertFalse(unavailable.canAttach)
        XCTAssertEqual(unavailable.subtitle, "Email verification is temporarily unavailable")
    }

    private func validatedChallenge(
        from result: ProfileEmailRequestResultDTO
    ) -> ProfileEmailChallenge? {
        ProfileEmailChallengePolicy.challenge(
            from: result,
            requestedEmail: "amina@example.test",
            ownerUserID: userID,
            sessionID: sessionID,
            issuedAt: issuedAt
        )
    }

    private func challengeJSON(
        expiresAt: String?,
        type: String = "email_attachment",
        resendAfterSeconds: Double? = 60,
        extraChallengeField: String = ""
    ) -> String {
        let expiration = expiresAt.map { #", "expires_at": "\#($0)""# } ?? ""
        let cooldown = resendAfterSeconds.map { #", "resend_after_seconds": \#($0)"# } ?? ""
        return """
        {
          "state": "challenge_required",
          "challenge": {
            "id": "email-challenge",
            "type": "\(type)",
            "method": "email",
            "destination": "a***@example.test"\(expiration)\(cooldown)\(extraChallengeField)
          }
        }
        """
    }

    private func profile(
        id: String? = nil,
        name: String? = "Amina Yusuf",
        email: String?,
        phone: String? = "+256700000200",
        emailVerified: Bool?,
        phoneVerified: Bool? = nil,
        avatarURL: String? = nil
    ) -> UserProfile {
        UserProfile(
            id: id ?? userID,
            name: name,
            email: email,
            phone: phone,
            tag: "amina",
            avatarURL: avatarURL,
            kycStatus: "verified",
            paymentPinSet: true,
            mfaEnabled: false,
            emailVerified: emailVerified,
            phoneVerified: phoneVerified,
            profileSetupRequired: false
        )
    }

    private func decodeResult(_ json: String) throws -> ProfileEmailRequestResultDTO {
        try decode(json)
    }

    private func decode<Value: Decodable>(_ json: String) throws -> Value {
        try JSONDecoder().decode(Value.self, from: Data(json.utf8))
    }

    private func object<Value: Encodable>(_ value: Value) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }
}
