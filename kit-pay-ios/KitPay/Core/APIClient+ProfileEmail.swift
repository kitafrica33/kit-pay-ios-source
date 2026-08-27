import Foundation

enum ProfileEmailAPIEndpoint: Equatable {
    case request
    case verify

    var path: String {
        switch self {
        case .request: "profile/email"
        case .verify: "profile/email/verify"
        }
    }
}

struct ProfileEmailAddressRequest: Encodable, Equatable {
    let email: String

    init(email: String) throws {
        let normalized = ProfileEmailChallengePolicy.normalizedEmail(email)
        guard EmailAccountValidation.isValidEmail(normalized) else {
            throw ProfileEmailAttachmentError.invalidEmail
        }
        self.email = normalized
    }
}

/// Verification codes are short-lived credentials. This request is encoding-only so a code can
/// never be reconstructed from cached JSON or decoded into application state.
struct ProfileEmailVerificationRequest: Encodable, Equatable {
    let challengeId: String
    let code: String

    enum CodingKeys: String, CodingKey {
        case challengeId = "challenge_id"
        case code
    }

    init(challengeId: String, code: String) throws {
        guard ProfileEmailChallengePolicy.isValidChallengeID(challengeId) else {
            throw ProfileEmailAttachmentError.invalidOrExpiredChallenge
        }
        guard let normalizedCode = ProfileEmailVerificationCodePolicy.normalizedCode(code) else {
            throw ProfileEmailAttachmentError.invalidCode
        }
        self.challengeId = challengeId
        self.code = normalizedCode
    }
}

extension APIClient {
    func requestProfileEmailAttachment(email: String) async throws
        -> ProfileEmailRequestResultDTO {
        try await send(
            path: ProfileEmailAPIEndpoint.request.path,
            method: "POST",
            body: try ProfileEmailAddressRequest(email: email)
        )
    }

    func verifyProfileEmailAttachment(challengeId: String, code: String) async throws
        -> UserProfile {
        try await send(
            path: ProfileEmailAPIEndpoint.verify.path,
            method: "POST",
            body: try ProfileEmailVerificationRequest(challengeId: challengeId, code: code)
        )
    }
}
