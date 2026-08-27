import Foundation

/// Kit Pay → Kit Pay transfer acceptance lifecycle. Available only when the backend advertises
/// `features.claimable_transfers`; every call fails closed server-side otherwise.
extension APIClient {
    /// Transfers involving the current account that carry acceptance state (both directions).
    func transferAcceptances() async throws -> TransferAcceptanceListDTO {
        try await send(
            path: "transfer-claims",
            method: "GET",
            body: TransferAcceptanceEmptyBody(),
            queryItems: [URLQueryItem(name: "limit", value: "100")]
        )
    }

    /// Fetches one claim immediately before an action so a stale list can never authorize it.
    func transferAcceptance(transferId: String) async throws -> TransferAcceptanceDTO {
        try await send(
            path: "transfer-claims/\(transferId)",
            method: "GET",
            body: TransferAcceptanceEmptyBody()
        )
    }

    /// Recipient accepts a pending transfer; the payment becomes final.
    func acceptTransfer(
        transferId: String
    ) async throws -> TransferAcceptanceDTO {
        try await send(
            path: "transfer-claims/\(transferId)/accept",
            method: "POST",
            body: TransferAcceptanceEmptyBody()
        )
    }

    /// Recipient rejects a pending transfer; the money returns to the sender.
    func rejectTransfer(
        transferId: String,
        reason: String?
    ) async throws -> TransferAcceptanceDTO {
        try await send(
            path: "transfer-claims/\(transferId)/reject",
            method: "POST",
            body: TransferAcceptanceResolutionBody(reason: reason)
        )
    }

    /// Sender reverses a transfer that has not been accepted yet. The optional proof is validated
    /// atomically by supporting backends while older Android clients remain token-optional.
    func reverseTransfer(
        transferId: String,
        reason: String?,
        stepUpToken: String? = nil
    ) async throws -> TransferAcceptanceDTO {
        var headers: [String: String] = [:]
        if let stepUpToken, !stepUpToken.isEmpty {
            headers["X-Kit-Wallet-Step-Up"] = stepUpToken
        }
        return try await send(
            path: "transfer-claims/\(transferId)/reverse",
            method: "POST",
            body: TransferAcceptanceResolutionBody(reason: reason),
            headers: headers
        )
    }
}

struct TransferAcceptanceEmptyBody: Encodable {}

struct TransferAcceptanceResolutionBody: Encodable {
    let reason: String?
}
