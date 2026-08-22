import Foundation

extension APIClient {
    func merchantAccounts() async throws -> MerchantAccountListDTO {
        try await send(
            path: "payments/merchants",
            method: "GET",
            body: MerchantQREmptyBody()
        )
    }

    func createMerchantAccount(
        settlementWalletId: String,
        displayName: String,
        legalName: String?,
        countryCode: String,
        idempotencyKey: String
    ) async throws -> MerchantAccountDTO {
        try await send(
            path: "payments/merchants",
            method: "POST",
            body: CreateMerchantAccountRequest(
                settlementWalletId: settlementWalletId,
                displayName: displayName,
                legalName: legalName,
                countryCode: countryCode
            ),
            headers: ["Idempotency-Key": idempotencyKey]
        )
    }

    func createMerchantPaymentIntent(
        merchantAccountId: String,
        amount: String,
        note: String?,
        idempotencyKey: String
    ) async throws -> MerchantPaymentIntentDTO {
        try await send(
            path: "payments/merchants/\(merchantAccountId)/intents",
            method: "POST",
            body: CreateMerchantPaymentIntentRequest(
                amount: amount,
                settlementMode: "direct",
                note: note
            ),
            headers: ["Idempotency-Key": idempotencyKey]
        )
    }

    func createMerchantQRCode(
        merchantAccountId: String,
        kind: String,
        merchantPaymentIntentId: String?,
        expiresAt: String? = nil,
        idempotencyKey: String
    ) async throws -> MerchantQRCodeDTO {
        try await send(
            path: "payments/merchants/\(merchantAccountId)/qr-codes",
            method: "POST",
            body: CreateMerchantQRRequest(
                kind: kind,
                merchantPaymentIntentId: merchantPaymentIntentId,
                expiresAt: expiresAt
            ),
            headers: ["Idempotency-Key": idempotencyKey]
        )
    }

    func resolveMerchantQRCode(payload: String) async throws -> MerchantQRCodeDTO {
        try await send(
            path: "payments/merchant-qr/resolve",
            method: "POST",
            body: ResolveMerchantQRRequest(payload: payload)
        )
    }

    func payMerchantQRCode(
        payload: String,
        sourceWalletId: String,
        amount: String?,
        idempotencyKey: String,
        stepUpToken: String
    ) async throws -> MerchantPaymentIntentDTO {
        try await send(
            path: "payments/merchant-qr/pay",
            method: "POST",
            body: PayMerchantQRRequest(
                payload: payload,
                sourceWalletId: sourceWalletId,
                amount: amount
            ),
            headers: [
                "Idempotency-Key": idempotencyKey,
                "X-Kit-Wallet-Step-Up": stepUpToken,
            ]
        )
    }
}

private struct MerchantQREmptyBody: Encodable {}
