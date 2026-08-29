import Foundation

enum ReferralAPIEndpoint: Equatable {
    case overview
    case ensureCode

    var path: String {
        switch self {
        case .overview: "referrals"
        case .ensureCode: "referrals/code"
        }
    }

    var method: String {
        switch self {
        case .overview: "GET"
        case .ensureCode: "POST"
        }
    }
}

extension APIClient {
    /// The caller's referral overview: active program terms (or null), share code (or null),
    /// coarse per-referral statuses, and totals. Strictly validated on decode
    /// (`ReferralOverviewDTO`) — the screen renders exactly this payload and nothing derived.
    func referralOverview() async throws -> ReferralOverviewDTO {
        let endpoint = ReferralAPIEndpoint.overview
        return try await send(
            path: endpoint.path,
            method: endpoint.method,
            body: ReferralEmptyBody()
        )
    }

    /// Idempotent by server contract: the caller's single active code is returned every time and
    /// a new one is only minted on first use, so retrying after any failure is always safe and
    /// can never produce a second code.
    func ensureReferralCode() async throws -> ReferralShareCodeDTO {
        let endpoint = ReferralAPIEndpoint.ensureCode
        let response: ReferralCodeResponseDTO = try await send(
            path: endpoint.path,
            method: endpoint.method,
            body: ReferralEmptyBody()
        )
        return response.code
    }
}

private struct ReferralEmptyBody: Encodable {}
