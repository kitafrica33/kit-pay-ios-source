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
