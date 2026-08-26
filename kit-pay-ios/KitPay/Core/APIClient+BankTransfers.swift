import Foundation

extension APIClient {
    func bankCatalog(country: String) async throws -> BankListDTO {
        try await send(
            path: "banking/banks",
            method: "GET",
            body: BankTransferEmptyBody(),
            queryItems: [URLQueryItem(name: "country", value: country.uppercased())]
        )
    }

    func bankBeneficiaries() async throws -> BankBeneficiaryListDTO {
        try await send(
            path: "banking/beneficiaries",
            method: "GET",
            body: BankTransferEmptyBody()
        )
    }

    func bankingOperations() async throws -> BankingOperationListDTO {
        try await send(
            path: "banking/operations",
            method: "GET",
            body: BankTransferEmptyBody()
        )
    }

    func bankingOperation(id: String) async throws -> BankingOperationDTO {
        try await send(
            path: "banking/operations/\(id)",
            method: "GET",
            body: BankTransferEmptyBody()
        )
    }

    func bankFundingAccounts() async throws -> BankFundingAccountListDTO {
        try await send(
            path: "banking/funding-accounts",
            method: "GET",
            body: BankTransferEmptyBody()
        )
    }

    func bankDepositRequests() async throws -> BankDepositRequestListDTO {
        try await send(
            path: "banking/deposit-requests",
            method: "GET",
            body: BankTransferEmptyBody()
        )
    }

    func bankDepositRequest(id: String) async throws -> BankDepositRequestDTO {
        try await send(
            path: "banking/deposit-requests/\(id)",
            method: "GET",
            body: BankTransferEmptyBody()
        )
    }

    func createBankDepositRequest(
        walletId: String,
        fundingAccountId: String,
        amount: String,
        note: String?,
        idempotencyKey: String
    ) async throws -> BankDepositRequestDTO {
        try await send(
            path: "banking/deposit-requests",
            method: "POST",
            body: CreateBankDepositRequest(
                walletId: walletId,
                fundingAccountId: fundingAccountId,
                amount: amount,
                note: note
            ),
            headers: ["Idempotency-Key": idempotencyKey]
        )
    }

    func attachBankDepositProof(
        depositId: String,
        mediaAssetId: String
    ) async throws -> BankDepositRequestDTO {
        try await send(
            path: "banking/deposit-requests/\(depositId)/proof",
            method: "POST",
            body: AttachBankDepositProofRequest(mediaAssetId: mediaAssetId)
        )
    }

    func createBankAccountVerification(
        bankId: String,
        accountNumber: String,
        idempotencyKey: String
    ) async throws -> BankAccountVerificationDTO {
        try await send(
            path: "banking/account-verifications",
            method: "POST",
            body: CreateBankAccountVerificationRequest(
                bankId: bankId,
                accountNumber: accountNumber
            ),
            headers: ["Idempotency-Key": idempotencyKey]
        )
    }

    func bankAccountVerification(id: String) async throws -> BankAccountVerificationDTO {
        try await send(
            path: "banking/account-verifications/\(id)",
            method: "GET",
            body: BankTransferEmptyBody()
        )
    }

    func createBankBeneficiary(
        verificationId: String,
        kind: String,
        label: String,
        idempotencyKey: String
    ) async throws -> BankBeneficiaryDTO {
        try await send(
            path: "banking/beneficiaries",
            method: "POST",
            body: CreateBankBeneficiaryRequest(
                verificationId: verificationId,
                kind: kind,
                label: label
            ),
            headers: ["Idempotency-Key": idempotencyKey]
        )
    }

    func createBankTransferQuote(
        walletId: String,
        beneficiaryId: String,
        amount: String,
        feeMode: BankTransferFeeMode
    ) async throws -> BankTransferQuoteDTO {
        try await send(
            path: "banking/transfer-quotes",
            method: "POST",
            body: CreateBankTransferQuoteRequest(
                walletId: walletId,
                beneficiaryId: beneficiaryId,
                amount: amount,
                feeMode: feeMode
            )
        )
    }

    func createQuotedBankTransfer(
        quoteId: String,
        idempotencyKey: String,
        stepUpToken: String
    ) async throws -> BankingOperationDTO {
        try await send(
            path: "banking/transfers",
            method: "POST",
            body: CreateQuotedBankTransferRequest(quoteId: quoteId),
            headers: [
                "Idempotency-Key": idempotencyKey,
                "X-Kit-Wallet-Step-Up": stepUpToken,
            ]
        )
    }
}

private struct BankTransferEmptyBody: Encodable {}
