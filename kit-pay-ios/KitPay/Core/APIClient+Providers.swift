import Foundation

extension APIClient {
    func providerCatalog(
        serviceType: String? = nil,
        category: String? = nil
    ) async throws -> ProviderProductListDTO {
        var queryItems: [URLQueryItem] = []
        if let serviceType { queryItems.append(URLQueryItem(name: "service_type", value: serviceType)) }
        if let category { queryItems.append(URLQueryItem(name: "category", value: category)) }

        return try await send(
            path: "providers/catalog",
            method: "GET",
            body: ProviderEmptyBody(),
            queryItems: queryItems
        )
    }

    func createProviderQuote(
        productId: String,
        account: String,
        amount: String
    ) async throws -> ProviderQuoteDTO {
        try await send(
            path: "providers/products/\(productId)/quotes",
            method: "POST",
            body: CreateProviderQuoteRequest(account: account, amount: amount)
        )
    }

    func createBillPayment(
        request: CreateProviderOperationRequest,
        idempotencyKey: String,
        stepUpToken: String
    ) async throws -> ProviderOperationDTO {
        try await createProviderOperation(
            path: "providers/bill-payments",
            request: request,
            idempotencyKey: idempotencyKey,
            stepUpToken: stepUpToken
        )
    }

    func createAirtimePurchase(
        request: CreateProviderOperationRequest,
        idempotencyKey: String,
        stepUpToken: String
    ) async throws -> ProviderOperationDTO {
        try await createProviderOperation(
            path: "providers/airtime-purchases",
            request: request,
            idempotencyKey: idempotencyKey,
            stepUpToken: stepUpToken
        )
    }

    func providerOperation(id: String) async throws -> ProviderOperationDTO {
        try await send(
            path: "providers/operations/\(id)",
            method: "GET",
            body: ProviderEmptyBody()
        )
    }

    private func createProviderOperation(
        path: String,
        request: CreateProviderOperationRequest,
        idempotencyKey: String,
        stepUpToken: String
    ) async throws -> ProviderOperationDTO {
        try await send(
            path: path,
            method: "POST",
            body: request,
            headers: [
                "Idempotency-Key": idempotencyKey,
                "X-Kit-Wallet-Step-Up": stepUpToken,
            ]
        )
    }
}

private struct ProviderEmptyBody: Encodable {}
