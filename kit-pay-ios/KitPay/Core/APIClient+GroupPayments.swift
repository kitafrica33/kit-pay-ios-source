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

    // MARK: Collaborative requests

    func groupPaymentRequests(
        conversationId: String,
        status: GroupPaymentRequestStatus? = nil
    ) async throws -> GroupPaymentRequestListDTO {
        try await send(
            path: "conversations/\(conversationId)/group-payment-requests",
            method: "GET",
            body: GroupPaymentEmptyBody(),
            queryItems: status.map { [URLQueryItem(name: "status", value: $0.rawValue)] } ?? []
        )
    }

    func createGroupPaymentRequest(
        conversationId: String,
        body: CreateGroupPaymentRequestBody,
        idempotencyKey: String
    ) async throws -> GroupPaymentRequestDTO {
        try await send(
            path: "conversations/\(conversationId)/group-payment-requests",
            method: "POST",
            body: body,
            headers: ["Idempotency-Key": idempotencyKey]
        )
    }

    func groupPaymentRequest(id: String) async throws -> GroupPaymentRequestDTO {
        try await send(
            path: "group-payment-requests/\(id)",
            method: "GET",
            body: GroupPaymentEmptyBody()
        )
    }

    func groupPaymentRequestContributions(
        requestId: String,
        before: String? = nil,
        limit: Int = 50
    ) async throws -> GroupPaymentRequestContributionListDTO {
        var queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        if let before { queryItems.append(URLQueryItem(name: "before", value: before)) }
        let page: GroupPaymentRequestContributionListDTO = try await send(
            path: "group-payment-requests/\(requestId)/contributions",
            method: "GET",
            body: GroupPaymentEmptyBody(),
            queryItems: queryItems
        )
        return page
    }

    func groupPaymentRequestContribution(
        requestId: String,
        contributionId: String
    ) async throws -> GroupPaymentRequestContributionDTO {
        try await send(
            path: "group-payment-requests/\(requestId)/contributions/\(contributionId)",
            method: "GET",
            body: GroupPaymentEmptyBody()
        )
    }

    func contributeToGroupPaymentRequest(
        id: String,
        sourceWalletId: String,
        amount: String,
        idempotencyKey: String,
        stepUpToken: String
    ) async throws -> GroupPaymentRequestContributionResultDTO {
        try await send(
            path: "group-payment-requests/\(id)/contributions",
            method: "POST",
            body: ContributeGroupPaymentRequestBody(
                sourceWalletId: sourceWalletId,
                amount: amount
            ),
            headers: [
                "Idempotency-Key": idempotencyKey,
                "X-Kit-Wallet-Step-Up": stepUpToken,
            ]
        )
    }

    func cancelGroupPaymentRequest(
        id: String,
        idempotencyKey: String
    ) async throws -> GroupPaymentRequestDTO {
        try await send(
            path: "group-payment-requests/\(id)/cancel",
            method: "POST",
            body: GroupPaymentEmptyBody(),
            headers: ["Idempotency-Key": idempotencyKey]
        )
    }

    // MARK: Server-side scheduled group payments

    func previewScheduledGroupPayment(
        conversationId: String,
        body: PreviewScheduledGroupPaymentBody
    ) async throws -> ScheduledGroupPaymentPlanDTO {
        try await send(
            path: "conversations/\(conversationId)/scheduled-group-payments/preview",
            method: "POST",
            body: body
        )
    }

    func createScheduledGroupPayment(
        conversationId: String,
        planId: String,
        idempotencyKey: String,
        stepUpToken: String
    ) async throws -> ScheduledGroupPaymentDTO {
        try await send(
            path: "conversations/\(conversationId)/scheduled-group-payments",
            method: "POST",
            body: CreateScheduledGroupPaymentBody(planId: planId),
            headers: [
                "Idempotency-Key": idempotencyKey,
                "X-Kit-Wallet-Step-Up": stepUpToken,
            ]
        )
    }

    func scheduledGroupPayments(
        conversationId: String,
        status: ScheduledGroupPaymentStatus,
        before: String? = nil,
        limit: Int = 100
    ) async throws -> ScheduledGroupPaymentListDTO {
        var queryItems = [
            URLQueryItem(name: "status", value: status.rawValue),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let before { queryItems.append(URLQueryItem(name: "before", value: before)) }
        return try await send(
            path: "conversations/\(conversationId)/scheduled-group-payments",
            method: "GET",
            body: GroupPaymentEmptyBody(),
            queryItems: queryItems
        )
    }

    func scheduledGroupPayment(id: String) async throws -> ScheduledGroupPaymentDTO {
        try await send(
            path: "scheduled-group-payments/\(id)",
            method: "GET",
            body: GroupPaymentEmptyBody()
        )
    }

    func cancelScheduledGroupPayment(
        id: String,
        idempotencyKey: String
    ) async throws -> ScheduledGroupPaymentDTO {
        try await send(
            path: "scheduled-group-payments/\(id)/cancel",
            method: "POST",
            body: GroupPaymentEmptyBody(),
            headers: ["Idempotency-Key": idempotencyKey]
        )
    }
}
