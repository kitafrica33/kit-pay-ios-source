import Foundation

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
}
