import Foundation

/// One payment into a group chat, shared out among its members.
///
/// Every share is an ordinary held transfer underneath, which is why these calls need
/// `features.claimable_transfers` as well as `features.group_payments`; the server fails closed
/// either way. Note what is missing here: there is no way to accept or decline a share by claim
/// id. Money sent into a group is answered through the group, so the only accept and reject
/// below take a group payment.
extension APIClient {
    /// Sends into the conversation. The step-up proof covers the whole intent — recipients and
    /// their amounts included — so an approval cannot be replayed against a different split.
    func createGroupPayment(
        conversationId: String,
        body: CreateGroupPaymentBody,
        idempotencyKey: String,
        stepUpToken: String
    ) async throws -> GroupPaymentDTO {
        try await send(
            path: "conversations/\(conversationId)/group-payments",
            method: "POST",
            body: body,
            headers: [
                "Idempotency-Key": idempotencyKey,
                "X-Kit-Wallet-Step-Up": stepUpToken,
            ]
        )
    }

    /// Reads the payment as the server scopes it for this account: a recipient of a custom split
    /// is told their own amount and nobody else's.
    func groupPayment(id: String) async throws -> GroupPaymentDTO {
        try await send(
            path: "group-payments/\(id)",
            method: "GET",
            body: GroupPaymentEmptyBody()
        )
    }

    /// Takes your own share. No step-up: this releases money that is already in your wallet.
    func acceptGroupPaymentShare(id: String) async throws -> GroupPaymentDTO {
        try await send(
            path: "group-payments/\(id)/accept",
            method: "POST",
            body: GroupPaymentEmptyBody()
        )
    }

    /// Turns down your own share; it goes back to the sender.
    func rejectGroupPaymentShare(id: String, reason: String?) async throws -> GroupPaymentDTO {
        try await send(
            path: "group-payments/\(id)/reject",
            method: "POST",
            body: GroupPaymentResolutionBody(reason: reason)
        )
    }

    /// Sender pulls back every share nobody has taken yet, in one move. Shares already accepted
    /// are untouched.
    func reverseUnclaimedGroupPayment(
        id: String,
        reason: String?,
        stepUpToken: String? = nil
    ) async throws -> GroupPaymentDTO {
        var headers: [String: String] = [:]
        if let stepUpToken, !stepUpToken.isEmpty {
            headers["X-Kit-Wallet-Step-Up"] = stepUpToken
        }
        return try await send(
            path: "group-payments/\(id)/reverse-unclaimed",
            method: "POST",
            body: GroupPaymentResolutionBody(reason: reason),
            headers: headers
        )
    }
}
