import Foundation

extension APIClient {
    func mobileMoneyNetworks() async throws -> MobileMoneyNetworkListDTO {
        try await send(
            path: "mobile-money/networks",
            method: "GET",
            body: MobileMoneyEmptyBody()
        )
    }

    func mobileMoneyAccounts() async throws -> MobileMoneyAccountListDTO {
        try await send(
            path: "mobile-money/accounts",
            method: "GET",
            body: MobileMoneyEmptyBody()
        )
    }

    func mobileMoneyAccountDetails(id: String) async throws -> MobileMoneyAccountDetailDTO {
        let accountID = try canonicalMobileMoneyAccountID(id)
        return try await send(
            path: "mobile-money/accounts/\(accountID)",
            method: "GET",
            body: MobileMoneyEmptyBody()
        )
    }

    func updateMobileMoneyAccountOwnership(
        id: String,
        ownership: MobileMoneySavedAccountOwnership,
        idempotencyKey: String
    ) async throws -> MobileMoneyAccountDTO {
        let accountID = try canonicalMobileMoneyAccountID(id)
        return try await send(
            path: "mobile-money/accounts/\(accountID)",
            method: "PATCH",
            body: UpdateMobileMoneyAccountRequest(kind: ownership.rawValue),
            headers: ["Idempotency-Key": idempotencyKey]
        )
    }

    func deleteMobileMoneyAccount(
        id: String,
        idempotencyKey: String
    ) async throws -> MobileMoneyAccountDeletionDTO {
        let accountID = try canonicalMobileMoneyAccountID(id)
        return try await send(
            path: "mobile-money/accounts/\(accountID)",
            method: "DELETE",
            body: MobileMoneyEmptyBody(),
            headers: ["Idempotency-Key": idempotencyKey]
        )
    }

    func mobileMoneyOperations() async throws -> MobileMoneyOperationListDTO {
        try await send(
            path: "mobile-money/operations",
            method: "GET",
            body: MobileMoneyEmptyBody()
        )
    }

    func mobileMoneyOperation(id: String) async throws -> MobileMoneyOperationDTO {
        try await send(
            path: "mobile-money/operations/\(id)",
            method: "GET",
            body: MobileMoneyEmptyBody()
        )
    }

    func createMobileMoneyVerification(
        network: String,
        phoneNumber: String,
        idempotencyKey: String
    ) async throws -> MobileMoneyVerificationDTO {
        try await send(
            path: "mobile-money/account-verifications",
            method: "POST",
            body: CreateMobileMoneyVerificationRequest(
                network: network,
                phoneNumber: phoneNumber
            ),
            headers: ["Idempotency-Key": idempotencyKey]
        )
    }

    func mobileMoneyVerification(id: String) async throws -> MobileMoneyVerificationDTO {
        try await send(
            path: "mobile-money/account-verifications/\(id)",
            method: "GET",
            body: MobileMoneyEmptyBody()
        )
    }

    func createMobileMoneyAccount(
        verificationId: String,
        kind: String,
        label: String,
        idempotencyKey: String
    ) async throws -> MobileMoneyAccountDTO {
        try await send(
            path: "mobile-money/accounts",
            method: "POST",
            body: CreateMobileMoneyAccountRequest(
                verificationId: verificationId,
                kind: kind,
                label: label
            ),
            headers: ["Idempotency-Key": idempotencyKey]
        )
    }

    func createMobileMoneyCollectionQuote(
        walletId: String,
        accountId: String,
        amount: String,
        feeMode: MobileMoneyFeeMode
    ) async throws -> MobileMoneyCollectionQuoteDTO {
        try await send(
            path: "mobile-money/collection-quotes",
            method: "POST",
            body: CreateMobileMoneyCollectionQuoteRequest(
                walletId: walletId,
                accountId: accountId,
                amount: amount,
                feeMode: feeMode
            )
        )
    }

    func createQuotedMobileMoneyCollection(
        quoteId: String,
        idempotencyKey: String,
        stepUpToken: String
    ) async throws -> MobileMoneyOperationDTO {
        try await send(
            path: "mobile-money/collections",
            method: "POST",
            body: CreateQuotedMobileMoneyCollectionRequest(quoteId: quoteId),
            headers: [
                "Idempotency-Key": idempotencyKey,
                "X-Kit-Wallet-Step-Up": stepUpToken,
            ]
        )
    }

    func createMobileMoneyPayoutQuote(
        walletId: String,
        accountId: String,
        amount: String,
        feeMode: MobileMoneyPayoutFeeMode
    ) async throws -> MobileMoneyPayoutQuoteDTO {
        try await send(
            path: "mobile-money/payout-quotes",
            method: "POST",
            body: CreateMobileMoneyPayoutQuoteRequest(
                walletId: walletId,
                accountId: accountId,
                amount: amount,
                feeMode: feeMode
            )
        )
    }

    func createQuotedMobileMoneyPayout(
        quoteId: String,
        idempotencyKey: String,
        stepUpToken: String
    ) async throws -> MobileMoneyOperationDTO {
        try await send(
            path: "mobile-money/payouts",
            method: "POST",
            body: CreateQuotedMobileMoneyPayoutRequest(quoteId: quoteId),
            headers: [
                "Idempotency-Key": idempotencyKey,
                "X-Kit-Wallet-Step-Up": stepUpToken,
            ]
        )
    }

    func createLegacyMobileMoneyCollection(
        walletId: String,
        accountId: String,
        amount: String,
        idempotencyKey: String,
        stepUpToken: String
    ) async throws -> MobileMoneyOperationDTO {
        return try await send(
            path: "mobile-money/collections",
            method: "POST",
            body: CreateLegacyMobileMoneyCollectionRequest(
                walletId: walletId,
                accountId: accountId,
                amount: amount
            ),
            headers: [
                "Idempotency-Key": idempotencyKey,
                "X-Kit-Wallet-Step-Up": stepUpToken,
            ]
        )
    }
}

private struct MobileMoneyEmptyBody: Encodable {}

private func canonicalMobileMoneyAccountID(_ value: String) throws -> String {
    guard let id = MobileMoneySavedAccountContract.canonicalID(value) else {
        throw APIClientError.invalidURL
    }
    return id.uuidString.lowercased()
}
