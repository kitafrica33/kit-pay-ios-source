import Foundation

protocol ScheduledPaymentServicing: Sendable {
    func scheduledPayments(
        conversationID: String,
        status: ScheduledPaymentStatus,
        before: String?,
        limit: Int
    ) async throws -> ScheduledPaymentListDTO
    func scheduledPayment(id: String) async throws -> ScheduledPaymentDTO
    func cancelScheduledPayment(id: String, idempotencyKey: String) async throws
        -> ScheduledPaymentDTO
}

extension APIClient {
    func paymentRequests() async throws -> PaymentRequestListDTO {
        try await send(
            path: "payments/requests",
            method: "GET",
            body: PaymentRequestEmptyBody()
        )
    }

    func createPaymentRequest(
        destinationWalletId: String,
        requestedFromUserId: String?,
        amount: String,
        note: String?,
        expiresAt: String? = nil,
        idempotencyKey: String
    ) async throws -> PaymentRequestDTO {
        try await send(
            path: "payments/requests",
            method: "POST",
            body: CreatePaymentRequestBody(
                destinationWalletId: destinationWalletId,
                requestedFromUserId: requestedFromUserId,
                amount: amount,
                note: note,
                expiresAt: expiresAt
            ),
            headers: ["Idempotency-Key": idempotencyKey]
        )
    }

    func payPaymentRequest(
        requestId: String,
        sourceWalletId: String,
        idempotencyKey: String,
        stepUpToken: String
    ) async throws -> PaymentRequestDTO {
        try await send(
            path: "payments/requests/\(requestId)/pay",
            method: "POST",
            body: PayPaymentRequestBody(sourceWalletId: sourceWalletId),
            headers: [
                "Idempotency-Key": idempotencyKey,
                "X-Kit-Wallet-Step-Up": stepUpToken,
            ]
        )
    }

    func cancelPaymentRequest(
        requestId: String,
        idempotencyKey: String
    ) async throws -> PaymentRequestDTO {
        try await send(
            path: "payments/requests/\(requestId)/cancel",
            method: "POST",
            body: PaymentRequestEmptyBody(),
            headers: ["Idempotency-Key": idempotencyKey]
        )
    }

    // MARK: Server-side scheduled payments

    func scheduledPayments(
        conversationID: String,
        status: ScheduledPaymentStatus,
        before: String? = nil,
        limit: Int = 100
    ) async throws -> ScheduledPaymentListDTO {
        var queryItems = [
            URLQueryItem(name: "conversation_id", value: conversationID),
            URLQueryItem(name: "status", value: status.rawValue),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let before { queryItems.append(URLQueryItem(name: "before", value: before)) }
        let page: ScheduledPaymentListDTO = try await send(
            path: "payments/scheduled",
            method: "GET",
            body: PaymentRequestEmptyBody(),
            queryItems: queryItems
        )
        return page
    }

    /// Fetches one instruction exactly. The backend release that introduces chat-bound schedules
    /// exposes this route so a notification or sync receipt never has to rely on a truncated list.
    func scheduledPayment(id: String) async throws -> ScheduledPaymentDTO {
        try await send(
            path: "payments/scheduled/\(id)",
            method: "GET",
            body: PaymentRequestEmptyBody()
        )
    }

    func createScheduledPayment(
        body: CreateScheduledPaymentBody,
        idempotencyKey: String,
        stepUpToken: String
    ) async throws -> ScheduledPaymentDTO {
        try await send(
            path: "payments/scheduled",
            method: "POST",
            body: body,
            headers: [
                "Idempotency-Key": idempotencyKey,
                "X-Kit-Wallet-Step-Up": stepUpToken,
            ]
        )
    }

    func cancelScheduledPayment(
        id: String,
        idempotencyKey: String
    ) async throws -> ScheduledPaymentDTO {
        try await send(
            path: "payments/scheduled/\(id)/cancel",
            method: "POST",
            body: PaymentRequestEmptyBody(),
            headers: ["Idempotency-Key": idempotencyKey]
        )
    }

    func paymentExecution(id: String) async throws -> PaymentExecutionDTO {
        try await send(
            path: "payments/executions/\(id)",
            method: "GET",
            body: PaymentRequestEmptyBody()
        )
    }
}

extension APIClient: ScheduledPaymentServicing {}
