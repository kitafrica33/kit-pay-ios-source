import Foundation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct BankTransferLoadResults {
    let country: String
    let bankCatalog: Result<BankListDTO, Error>
    let beneficiaries: Result<BankBeneficiaryListDTO, Error>
    let operations: Result<BankingOperationListDTO, Error>
}

enum BankTransferLoadRequestPolicy {
    static func shouldStart(isCancelled: Bool) -> Bool {
        !isCancelled
    }

    static func shouldJoin(
        activeCountry: String?,
        requestedCountry: String
    ) -> Bool {
        activeCountry == requestedCountry
    }

    static func shouldApply(
        requestID: UUID,
        currentRequestID: UUID?
    ) -> Bool {
        requestID == currentRequestID
    }
}

enum BankTransferActionErrorContext: CaseIterable, Hashable {
    case accountVerification
    case beneficiarySave
    case quoteReview
    case transferApproval
    case transferSubmission

    var invalidPayloadMessage: String {
        switch self {
        case .accountVerification:
            "Kit Pay could not confirm the bank account verification response. No beneficiary was saved. Please try again."
        case .beneficiarySave:
            "Kit Pay could not confirm that this beneficiary was saved. Refresh your beneficiaries before trying again."
        case .quoteReview:
            "We couldn't load the latest transaction fee and total for this bank transfer. Nothing was submitted. Please review the amounts and try again."
        case .transferApproval:
            "Kit Pay could not confirm this bank transfer approval. Nothing was submitted. Please approve again."
        case .transferSubmission:
            "Kit Pay could not confirm the bank transfer response. Check recent bank transfers before retrying."
        }
    }
}

enum BankTransferActionErrorCopy {
    static func transferContext(
        submissionStarted: Bool
    ) -> BankTransferActionErrorContext {
        submissionStarted ? .transferSubmission : .transferApproval
    }

    static func message(
        for error: Error,
        context: BankTransferActionErrorContext,
        feeMode: BankTransferFeeMode? = nil
    ) -> String {
        if let clientError = error as? APIClientError,
           case .invalidPayload = clientError {
            return context.invalidPayloadMessage
        }
        if feeMode == .kitCovers,
           let payload = error as? APIErrorPayload,
           [
               "BANK_OUTBOUND_FEE_WALLET_INVALID",
               "BANK_OUTBOUND_FEE_FUNDING_REQUIRED",
           ].contains(payload.code) {
            return "This fee treatment is unavailable. Review a transfer with the fee covered by you or by the beneficiary."
        }
        let message = (error as? APIErrorPayload)?.message ?? error.localizedDescription
        return CustomerFacingPaymentCopy.neutralizedServiceMessage(message)
    }
}

@MainActor
final class BankTransferViewModel: ObservableObject {
    @Published private(set) var banks: [BankDTO] = []
    @Published private(set) var beneficiaries: [BankBeneficiaryDTO] = []
    @Published private(set) var operations: [BankingOperationDTO] = []
    @Published private(set) var bankCatalogErrorMessage: String?
    @Published private(set) var beneficiaryLoadErrorMessage: String?
    @Published private(set) var operationLoadErrorMessage: String?
    @Published private(set) var verification: BankAccountVerificationDTO?
    @Published private(set) var isLoading = false
    @Published private(set) var isSubmitting = false
    /// The wallet debit the server refused for want of funds, so the screen can offer a top-up
    /// instead of only reporting the refusal.
    @Published var insufficientFundsDebitAmount: String?
    @Published var errorMessage: String?

    private let api: APIClient
    private var loadRequestID: UUID?
    private var loadTask: Task<BankTransferLoadResults, Never>?
    private var loadTaskCountry: String?
    private var loadedBankCountry: String?
    private var operationPollTasks: [String: Task<Void, Never>] = [:]

    init(api: APIClient = .shared) {
        self.api = api
#if DEBUG && APP_STORE_SCREENSHOTS
        if AppStoreScreenshotFixture.isActive {
            banks = AppStoreScreenshotFixture.banks
            beneficiaries = AppStoreScreenshotFixture.bankBeneficiaries
            operations = AppStoreScreenshotFixture.bankOperations
            loadedBankCountry = "UG"
        }
#endif
    }

    deinit {
        loadTask?.cancel()
        operationPollTasks.values.forEach { $0.cancel() }
    }

    var transferableBeneficiaries: [BankBeneficiaryDTO] {
        BankBeneficiaryRailPolicy.bankRailBeneficiaries(
            beneficiaries.filter(\.isActive)
        )
    }

    func load(country: String, permitted: Bool?, online: Bool) async {
#if DEBUG && APP_STORE_SCREENSHOTS
        if AppStoreScreenshotFixture.isActive {
            banks = AppStoreScreenshotFixture.banks
            beneficiaries = AppStoreScreenshotFixture.bankBeneficiaries
            operations = AppStoreScreenshotFixture.bankOperations
            loadedBankCountry = "UG"
            bankCatalogErrorMessage = nil
            beneficiaryLoadErrorMessage = nil
            operationLoadErrorMessage = nil
            errorMessage = nil
            return
        }
#endif
        guard BankTransferLoadRequestPolicy.shouldStart(
            isCancelled: Task.isCancelled
        ) else { return }
        let normalizedCountry = country
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        // Capabilities are briefly unknown while the app refreshes them. Keep an owned catalog
        // request alive during that transition; only an explicit `false` disables the feature.
        guard let permitted else { return }
        guard permitted else {
            cancelActiveLoad()
            clear()
            errorMessage = "Bank transfers are not enabled for your Kit Pay account."
            return
        }
        guard online else {
            cancelActiveLoad()
            errorMessage = "Connect to the internet to load banks and beneficiaries."
            return
        }

        errorMessage = nil

        let requestID: UUID
        let task: Task<BankTransferLoadResults, Never>
        if let activeTask = loadTask,
           let activeRequestID = loadRequestID,
           BankTransferLoadRequestPolicy.shouldJoin(
               activeCountry: loadTaskCountry,
               requestedCountry: normalizedCountry
           ) {
            requestID = activeRequestID
            task = activeTask
        } else {
            loadTask?.cancel()
            requestID = UUID()
            task = Task { [api] in
                async let bankCatalog = Self.loadBankCatalog(
                    api: api,
                    country: normalizedCountry
                )
                async let beneficiaries = Self.loadBeneficiaries(api: api)
                async let operations = Self.loadOperations(api: api)
                let (bankCatalogResult, beneficiaryResult, operationResult) = await (
                    bankCatalog,
                    beneficiaries,
                    operations
                )
                return BankTransferLoadResults(
                    country: normalizedCountry,
                    bankCatalog: bankCatalogResult,
                    beneficiaries: beneficiaryResult,
                    operations: operationResult
                )
            }
            loadRequestID = requestID
            loadTask = task
            loadTaskCountry = normalizedCountry
            isLoading = true
        }

        // The model owns this request. SwiftUI may cancel one `.task` waiter while replacing
        // the view, but that must not discard a valid catalog needed by another waiter.
        let results = await task.value
        guard BankTransferLoadRequestPolicy.shouldApply(
            requestID: requestID,
            currentRequestID: loadRequestID
        ) else { return }
        loadRequestID = nil
        loadTask = nil
        loadTaskCountry = nil
        isLoading = false
        applyLoadResults(results)
    }

    func applyLoadResults(_ results: BankTransferLoadResults) {
        switch results.bankCatalog {
        case .success(let bankList):
            banks = (bankList.items ?? []).sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            loadedBankCountry = results.country
            bankCatalogErrorMessage = nil
        case .failure:
            if loadedBankCountry != results.country {
                banks = []
                loadedBankCountry = nil
            }
            bankCatalogErrorMessage = "Banks could not be loaded. Pull to refresh and try again."
        }

        switch results.beneficiaries {
        case .success(let beneficiaryList):
            beneficiaries = (beneficiaryList.items ?? []).filter(\.isActive).sorted {
                $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
            }
            beneficiaryLoadErrorMessage = nil
        case .failure:
            beneficiaryLoadErrorMessage =
                "Saved beneficiaries could not be loaded. Pull to refresh and try again."
        }

        switch results.operations {
        case .success(let operationList):
            operations = (operationList.items ?? [])
                .filter { $0.type.caseInsensitiveCompare(BankTransferContract.operationType) == .orderedSame }
                .sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
            operations.filter { !$0.isTerminal }.forEach { pollOperation($0.id) }
            operationLoadErrorMessage = nil
        case .failure:
            operationLoadErrorMessage =
                "Recent bank transfers could not be loaded. Pull to refresh and try again."
        }
    }

    private nonisolated static func loadBankCatalog(
        api: APIClient,
        country: String
    ) async -> Result<BankListDTO, Error> {
        do {
            return .success(try await api.bankCatalog(country: country))
        } catch {
            return .failure(error)
        }
    }

    private nonisolated static func loadBeneficiaries(
        api: APIClient
    ) async -> Result<BankBeneficiaryListDTO, Error> {
        do {
            return .success(try await api.bankBeneficiaries())
        } catch {
            return .failure(error)
        }
    }

    private nonisolated static func loadOperations(
        api: APIClient
    ) async -> Result<BankingOperationListDTO, Error> {
        do {
            return .success(try await api.bankingOperations())
        } catch {
            return .failure(error)
        }
    }

    private func cancelActiveLoad() {
        loadTask?.cancel()
        loadTask = nil
        loadTaskCountry = nil
        loadRequestID = nil
        isLoading = false
    }

    func prepareAccountVerification() {
        verification = nil
        errorMessage = nil
    }

    func verifyAccount(
        bankId: String,
        accountNumber: String,
        idempotencyKey: String,
        permitted: Bool,
        online: Bool
    ) async -> BankAccountVerificationDTO? {
        guard !isSubmitting else { return nil }
        guard permitted, online else {
            errorMessage = permitted
                ? "Connect to the internet to verify this bank account."
                : "Bank transfers are not enabled for your Kit Pay account."
            return nil
        }
        guard let bank = banks.first(where: { $0.id == bankId }),
              bank.canVerifyAccount,
              bank.canTransfer
        else {
            errorMessage = "Choose a bank that supports verified transfers."
            return nil
        }
        guard let account = BankAccountNumber.apiValue(from: accountNumber) else {
            errorMessage = "Enter a valid bank account number containing 4 to 40 letters or digits."
            return nil
        }

        isSubmitting = true
        errorMessage = nil
        verification = nil
        defer { isSubmitting = false }

        do {
            var result = try await api.createBankAccountVerification(
                bankId: bank.id,
                accountNumber: account,
                idempotencyKey: idempotencyKey
            )
            guard result.bankId == bank.id else { throw BankTransferFlowError.verificationMismatch }
            verification = result

            var pollCount = 0
            while result.isPending, pollCount < 30 {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 1_000_000_000)
                result = try await api.bankAccountVerification(id: result.id)
                guard result.bankId == bank.id else {
                    throw BankTransferFlowError.verificationMismatch
                }
                verification = result
                pollCount += 1
            }
            guard result.isVerified else {
                throw BankTransferFlowError.verificationIncomplete(
                    result.failure?.message
                        ?? (result.isPending
                            ? "The bank is still verifying this account. Try again shortly."
                            : "The bank could not verify this account.")
                )
            }
            return result
        } catch is CancellationError {
            return nil
        } catch {
            errorMessage = BankTransferActionErrorCopy.message(
                for: error,
                context: .accountVerification
            )
            return nil
        }
    }

    func saveBeneficiary(
        label: String,
        kind: String,
        idempotencyKey: String,
        permitted: Bool,
        online: Bool
    ) async -> BankBeneficiaryDTO? {
        guard !isSubmitting else { return nil }
        guard permitted, online else {
            errorMessage = permitted
                ? "Connect to the internet to save this beneficiary."
                : "Bank transfers are not enabled for your Kit Pay account."
            return nil
        }
        guard let verification, verification.isVerified else {
            errorMessage = "Verify the bank account before saving it."
            return nil
        }
        let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanLabel.isEmpty, cleanLabel.count <= 100,
              ["own", "third_party"].contains(kind)
        else {
            errorMessage = "Enter a beneficiary label and choose who owns the account."
            return nil
        }

        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        do {
            let beneficiary = try await api.createBankBeneficiary(
                verificationId: verification.id,
                kind: kind,
                label: cleanLabel,
                idempotencyKey: idempotencyKey
            )
            guard beneficiary.isActive,
                  beneficiary.bank.id == verification.bankId,
                  beneficiary.bank.canTransfer,
                  !beneficiary.accountName.isEmpty
            else { throw BankTransferFlowError.unconfirmedBeneficiary }
            upsert(beneficiary)
            self.verification = nil
            return beneficiary
        } catch {
            errorMessage = BankTransferActionErrorCopy.message(
                for: error,
                context: .beneficiarySave
            )
            return nil
        }
    }

    func createTransferQuote(
        beneficiary: BankBeneficiaryDTO,
        wallet: Wallet?,
        enteredAmount: String,
        feeMode: BankTransferFeeMode,
        permitted: Bool,
        online: Bool
    ) async -> BankTransferQuoteDTO? {
        guard !isSubmitting else { return nil }
        guard permitted, online else {
            errorMessage = permitted
                ? "Connect to the internet to review this bank transfer."
                : "Bank transfers are not enabled for your Kit Pay account."
            return nil
        }
        guard let wallet, wallet.status.caseInsensitiveCompare("active") == .orderedSame else {
            errorMessage = "Choose an active Kit Pay wallet."
            return nil
        }
        guard beneficiary.isActive,
              beneficiary.bank.canTransfer,
              beneficiary.bank.currency.caseInsensitiveCompare("UGX") == .orderedSame,
              wallet.currency.code.caseInsensitiveCompare(beneficiary.bank.currency) == .orderedSame
        else {
            errorMessage = "Choose an active UGX bank beneficiary for this wallet."
            return nil
        }
        guard let amount = BankTransferMoney.transferableWholeUGXAmount(enteredAmount) else {
            errorMessage = "Enter an amount of at least UGX 20,000."
            return nil
        }

        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        do {
            let quote = try await api.createBankTransferQuote(
                walletId: wallet.id,
                beneficiaryId: beneficiary.id,
                amount: amount,
                feeMode: feeMode
            )
            try validate(
                quote,
                beneficiary: beneficiary,
                wallet: wallet,
                amount: amount,
                feeMode: feeMode
            )
            return quote
        } catch {
            errorMessage = BankTransferActionErrorCopy.message(
                for: error,
                context: .quoteReview,
                feeMode: feeMode
            )
            return nil
        }
    }

    func submitQuotedTransfer(
        quote: BankTransferQuoteDTO,
        beneficiary: BankBeneficiaryDTO,
        wallet: Wallet?,
        pin: String,
        idempotencyKey: String,
        permitted: Bool,
        online: Bool,
        authorization: KitFinancialStepUpAuthorization
    ) async -> BankingOperationDTO? {
        guard !isSubmitting else { return nil }
        guard permitted, online else {
            errorMessage = permitted
                ? "Connect to the internet to send this bank transfer."
                : "Bank transfers are not enabled for your Kit Pay account."
            return nil
        }
        guard let wallet, wallet.status.caseInsensitiveCompare("active") == .orderedSame else {
            errorMessage = "Choose an active Kit Pay wallet."
            return nil
        }

        do {
            try validate(
                quote,
                beneficiary: beneficiary,
                wallet: wallet,
                amount: quote.enteredAmount,
                feeMode: quote.feeMode
            )
        } catch {
            errorMessage = BankTransferActionErrorCopy.message(
                for: error,
                context: .transferApproval,
                feeMode: quote.feeMode
            )
            return nil
        }

        isSubmitting = true
        errorMessage = nil
        insufficientFundsDebitAmount = nil
        defer { isSubmitting = false }

        var transferSubmissionStarted = false
        do {
            let received = KitMoney.formatted(
                quote.recipientAmount, currency: quote.currency, trimZeroFraction: true)
            let debit = KitMoney.formatted(
                quote.customerDebit, currency: quote.currency, trimZeroFraction: true)
            let approval = try await authorization(
                quote.stepUp.purpose,
                quote.stepUp.authorizationIntent,
                pin,
                "Approve sending to \(beneficiary.accountName); they receive \(received) "
                    + "and your Kit Pay wallet debit is \(debit)"
            )
            guard !approval.stepUpToken.isEmpty else {
                throw BankTransferFlowError.invalidStepUp
            }
            try validate(
                quote,
                beneficiary: beneficiary,
                wallet: wallet,
                amount: quote.enteredAmount,
                feeMode: quote.feeMode
            )
            transferSubmissionStarted = true
            let operation = try await api.createQuotedBankTransfer(
                quoteId: quote.id,
                idempotencyKey: idempotencyKey,
                stepUpToken: approval.stepUpToken
            )
            try validate(operation, quote: quote, beneficiary: beneficiary)

            upsert(operation)
            pollOperation(operation.id)
            return operation
        } catch {
            if WalletTopUpPolicy.isInsufficientFunds(error) {
                insufficientFundsDebitAmount = quote.customerDebit
            }
            errorMessage = BankTransferActionErrorCopy.message(
                for: error,
                context: BankTransferActionErrorCopy.transferContext(
                    submissionStarted: transferSubmissionStarted
                ),
                feeMode: quote.feeMode
            )
            return nil
        }
    }

    private func validate(
        _ quote: BankTransferQuoteDTO,
        beneficiary: BankBeneficiaryDTO,
        wallet: Wallet,
        amount: String,
        feeMode: BankTransferFeeMode
    ) throws {
        if quote.isExpired { throw BankTransferFlowError.quoteExpired }
        guard quote.action == "transfer",
              quote.operationType == BankTransferContract.operationType,
              quote.feeMode == feeMode,
              quote.walletId == wallet.id,
              quote.beneficiaryId == beneficiary.id,
              quote.bank.id == beneficiary.bank.id,
              quote.bank.code.caseInsensitiveCompare(beneficiary.bank.code) == .orderedSame,
              quote.scheduleVerified,
              !quote.scheduleVersion.isEmpty,
              quote.currency == wallet.currency,
              quote.currency.code.caseInsensitiveCompare("UGX") == .orderedSame,
              BankTransferMoney.amountsMatch(quote.enteredAmount, amount),
              quote.hasConsistentAmounts,
              quote.hasValidStepUpBinding
        else { throw BankTransferFlowError.quoteMismatch }
    }

    private func validate(
        _ operation: BankingOperationDTO,
        quote: BankTransferQuoteDTO,
        beneficiary: BankBeneficiaryDTO
    ) throws {
        guard operation.hasSameOutboundBinding(as: quote),
              operation.beneficiaryId == beneficiary.id,
              operation.bankId == beneficiary.bank.id
        else { throw BankTransferFlowError.operationMismatch }
    }

    private func pollOperation(_ id: String) {
        operationPollTasks[id]?.cancel()
        operationPollTasks[id] = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<40 {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }
                guard let operation = try? await api.bankingOperation(id: id),
                      operation.type.caseInsensitiveCompare(
                          BankTransferContract.operationType
                      ) == .orderedSame
                else { continue }
                upsert(operation)
                if operation.isTerminal {
                    operationPollTasks[id] = nil
                    return
                }
            }
            operationPollTasks[id] = nil
        }
    }

    private func upsert(_ beneficiary: BankBeneficiaryDTO) {
        beneficiaries.removeAll { $0.id == beneficiary.id }
        beneficiaries.append(beneficiary)
        beneficiaries.sort {
            $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }

    private func upsert(_ operation: BankingOperationDTO) {
        operations.removeAll { $0.id == operation.id }
        operations.insert(operation, at: 0)
    }

    private func clear() {
        banks = []
        beneficiaries = []
        operations = []
        bankCatalogErrorMessage = nil
        beneficiaryLoadErrorMessage = nil
        operationLoadErrorMessage = nil
        loadedBankCountry = nil
        verification = nil
    }

}

private struct BankDepositLoadResults {
    let accounts: Result<BankFundingAccountListDTO, Error>
    let deposits: Result<BankDepositRequestListDTO, Error>
}

private enum BankDepositFlowError: LocalizedError {
    case invalidServiceResponse
    case proofBindingMismatch

    var errorDescription: String? {
        switch self {
        case .invalidServiceResponse:
            "Kit Pay could not confirm the bank-deposit details. Nothing was submitted. Please try again."
        case .proofBindingMismatch:
            "Kit Pay could not confirm that the receipt was attached to this deposit. Refresh before retrying."
        }
    }
}

@MainActor
final class BankDepositViewModel: ObservableObject {
    @Published private(set) var accounts: [BankFundingAccountDTO] = []
    @Published private(set) var deposits: [BankDepositRequestDTO] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isSubmitting = false
    @Published private(set) var accountLoadErrorMessage: String?
    @Published private(set) var depositLoadErrorMessage: String?
    @Published var errorMessage: String?

    private let api: APIClient
    private var loadTask: Task<BankDepositLoadResults, Never>?
    private var pollTasks: [String: Task<Void, Never>] = [:]

    init(api: APIClient = .shared) {
        self.api = api
    }

    deinit {
        loadTask?.cancel()
        pollTasks.values.forEach { $0.cancel() }
    }

    func activeAccounts(for wallet: Wallet?) -> [BankFundingAccountDTO] {
        guard let wallet else { return [] }
        return accounts.filter {
            $0.isActive
                && $0.currency.caseInsensitiveCompare(wallet.currency.code) == .orderedSame
        }
    }

    func load(wallet: Wallet?, permitted: Bool?, online: Bool) async {
        guard !Task.isCancelled, let permitted else { return }
        guard permitted else {
            cancelLoad()
            accounts = []
            deposits = []
            errorMessage = nil
            return
        }
        guard let wallet, wallet.status.caseInsensitiveCompare("active") == .orderedSame else {
            cancelLoad()
            accounts = []
            deposits = []
            errorMessage = "Choose an active Kit Pay wallet to use bank deposits."
            return
        }
        guard online else {
            cancelLoad()
            if accounts.isEmpty && deposits.isEmpty {
                errorMessage = "Connect to the internet to load bank deposits."
            }
            return
        }
        guard loadTask == nil else {
            _ = await loadTask?.value
            return
        }

        isLoading = true
        errorMessage = nil
        let task = Task { [api] in
            async let accountResult: Result<BankFundingAccountListDTO, Error> = Self.result {
                try await api.bankFundingAccounts()
            }
            async let depositResult: Result<BankDepositRequestListDTO, Error> = Self.result {
                try await api.bankDepositRequests()
            }
            return await BankDepositLoadResults(
                accounts: accountResult,
                deposits: depositResult
            )
        }
        loadTask = task
        let results = await task.value
        guard loadTask != nil else { return }
        loadTask = nil
        isLoading = false

        switch results.accounts {
        case .success(let response):
            accounts = (response.items ?? [])
                .filter(\.isActive)
                .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
            accountLoadErrorMessage = nil
        case .failure:
            accountLoadErrorMessage = "Receiving bank accounts could not be loaded. Pull to refresh and try again."
        }

        switch results.deposits {
        case .success(let response):
            deposits = (response.items ?? [])
                .filter { $0.walletId == wallet.id }
                .sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
            deposits.filter { !$0.isTerminal }.forEach { poll($0.id) }
            depositLoadErrorMessage = nil
        case .failure:
            depositLoadErrorMessage = "Recent bank deposits could not be loaded. Pull to refresh and try again."
        }
    }

    func create(
        wallet: Wallet?,
        fundingAccount: BankFundingAccountDTO,
        enteredAmount: String,
        note: String,
        idempotencyKey: String,
        permitted: Bool,
        online: Bool
    ) async -> BankDepositRequestDTO? {
        guard !isSubmitting else { return nil }
        guard permitted, online else {
            errorMessage = permitted
                ? "Connect to the internet to create a bank deposit."
                : "Bank deposits are not enabled for your Kit Pay account."
            return nil
        }
        guard let wallet,
              wallet.status.caseInsensitiveCompare("active") == .orderedSame,
              fundingAccount.isActive,
              fundingAccount.currency.caseInsensitiveCompare(wallet.currency.code) == .orderedSame,
              accounts.contains(where: { $0.id == fundingAccount.id })
        else {
            errorMessage = "Choose an available receiving account for this wallet."
            return nil
        }
        let scale = Int(wallet.currency.scale) ?? -1
        guard let amount = BankDepositMoney.apiAmount(enteredAmount, scale: scale) else {
            errorMessage = "Enter a valid amount greater than zero."
            return nil
        }
        let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanNote.count <= 280 else {
            errorMessage = "Keep the optional note to 280 characters or fewer."
            return nil
        }

        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            let created = try await api.createBankDepositRequest(
                walletId: wallet.id,
                fundingAccountId: fundingAccount.id,
                amount: amount,
                note: cleanNote.isEmpty ? nil : cleanNote,
                idempotencyKey: idempotencyKey
            )
            guard created.hasSameBinding(
                wallet: wallet,
                fundingAccount: fundingAccount,
                submittedAmount: amount
            ), created.status.caseInsensitiveCompare("awaiting_proof") == .orderedSame
            else { throw BankDepositFlowError.invalidServiceResponse }
            upsert(created)
            poll(created.id)
            return created
        } catch {
            errorMessage = customerMessage(error)
            return nil
        }
    }

    func uploadProof(
        for deposit: BankDepositRequestDTO,
        data: Data,
        filename: String,
        mimeType: String,
        permitted: Bool,
        online: Bool
    ) async -> BankDepositRequestDTO? {
        guard !isSubmitting else { return nil }
        guard permitted, online else {
            errorMessage = permitted
                ? "Connect to the internet to upload payment proof."
                : "Bank deposits are not enabled for your Kit Pay account."
            return nil
        }
        guard deposit.acceptsProof else {
            errorMessage = "This bank deposit is no longer accepting payment proof."
            return nil
        }

        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            let assetID = try await api.uploadBankDepositProof(
                data: data,
                filename: filename,
                mimeType: mimeType
            )
            let updated = try await api.attachBankDepositProof(
                depositId: deposit.id,
                mediaAssetId: assetID
            )
            guard updated.id == deposit.id,
                  updated.walletId == deposit.walletId,
                  updated.reference == deposit.reference,
                  updated.fundingAccount.id == deposit.fundingAccount.id,
                  updated.currency == deposit.currency,
                  BankTransferMoney.amountsMatch(updated.amount, deposit.amount),
                  updated.proof?.assetId.caseInsensitiveCompare(assetID) == .orderedSame
            else { throw BankDepositFlowError.proofBindingMismatch }
            upsert(updated)
            poll(updated.id)
            return updated
        } catch {
            errorMessage = customerMessage(error)
            return nil
        }
    }

    func refresh(_ deposit: BankDepositRequestDTO) async -> BankDepositRequestDTO? {
        guard !Task.isCancelled else { return nil }
        do {
            let updated = try await api.bankDepositRequest(id: deposit.id)
            guard updated.id == deposit.id,
                  updated.walletId == deposit.walletId,
                  updated.reference == deposit.reference,
                  updated.fundingAccount.id == deposit.fundingAccount.id,
                  updated.currency == deposit.currency,
                  BankTransferMoney.amountsMatch(updated.amount, deposit.amount)
            else { throw BankDepositFlowError.invalidServiceResponse }
            upsert(updated)
            return updated
        } catch is CancellationError {
            return nil
        } catch {
            errorMessage = customerMessage(error)
            return nil
        }
    }

    func clearError() {
        errorMessage = nil
    }

    private nonisolated static func result<Value>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async -> Result<Value, Error> {
        do { return .success(try await operation()) }
        catch { return .failure(error) }
    }

    private func poll(_ id: String) {
        guard pollTasks[id] == nil else { return }
        pollTasks[id] = Task { [weak self] in
            defer { self?.pollTasks[id] = nil }
            for _ in 0 ..< 120 {
                do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                catch { return }
                guard let self,
                      let current = self.deposits.first(where: { $0.id == id }),
                      !current.isTerminal
                else { return }
                _ = await self.refresh(current)
            }
        }
    }

    private func upsert(_ deposit: BankDepositRequestDTO) {
        deposits.removeAll { $0.id == deposit.id }
        deposits.append(deposit)
        deposits.sort { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
    }

    private func cancelLoad() {
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
    }

    private func customerMessage(_ error: Error) -> String {
        if let flowError = error as? BankDepositFlowError {
            return flowError.localizedDescription
        }
        if let clientError = error as? APIClientError,
           case .invalidPayload = clientError {
            return BankDepositFlowError.invalidServiceResponse.localizedDescription
        }
        let raw = (error as? APIErrorPayload)?.message ?? error.localizedDescription
        return CustomerFacingPaymentCopy.neutralizedServiceMessage(raw)
    }
}

private enum BankModal: Identifiable {
    case addBeneficiary
    case send(BankBeneficiaryDTO)
    case transferReceipt(BankingOperationDTO)
    case newDeposit
    case depositReceipt(BankDepositRequestDTO)

    var id: String {
        switch self {
        case .addBeneficiary: "add-beneficiary"
        case .send(let beneficiary): "send-\(beneficiary.id)"
        case .transferReceipt(let operation): "transfer-\(operation.id)"
        case .newDeposit: "new-deposit"
        case .depositReceipt(let deposit): "deposit-\(deposit.id)"
        }
    }
}

struct BankTransferView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = BankTransferViewModel()
    @StateObject private var depositModel = BankDepositViewModel()
    @State private var modal: BankModal?
    /// Built once per directory change: the rows below would otherwise rescan every synced contact
    /// on each redraw.
    @State private var contactIndex = BeneficiaryContactIndex()

    private var transferPermission: Bool? { app.capabilities?.enablesBankTransfers }
    private var transfersPermitted: Bool { transferPermission == true }
    private var depositPermission: Bool? { app.capabilities?.enablesBankDeposits }
    private var depositsPermitted: Bool { depositPermission == true }
    private var country: String {
        let value = (app.profile?.countryCode ?? "UG")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        return value.count == 2 ? value : "UG"
    }
    private var loadTrigger: String {
        let transfers = transferPermission.map { $0 ? "enabled" : "disabled" } ?? "unknown"
        let deposits = depositPermission.map { $0 ? "enabled" : "disabled" } ?? "unknown"
        return "\(country)-\(transfers)-\(deposits)-\(app.selectedWallet?.id ?? "none")-\(app.isOnline)"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    intro
                    if depositsPermitted {
                        depositSection
                        depositsSection
                    }
                    if transfersPermitted {
                        beneficiariesSection
                        transfersSection
                    }
                }
                .padding(20)
                .padding(.bottom, 24)
            }
            .background(KitColor.canvas.ignoresSafeArea())
            .navigationTitle("Bank")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            async let transfers: Void = model.load(
                                country: country,
                                permitted: transferPermission,
                                online: app.isOnline
                            )
                            async let deposits: Void = depositModel.load(
                                wallet: app.selectedWallet,
                                permitted: depositPermission,
                                online: app.isOnline
                            )
                            _ = await (transfers, deposits)
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(
                        model.isLoading || model.isSubmitting
                            || depositModel.isLoading || depositModel.isSubmitting
                    )
                    .accessibilityLabel("Refresh bank activity")
                }
            }
            .task(id: loadTrigger) {
                async let transfers: Void = model.load(
                    country: country,
                    permitted: transferPermission,
                    online: app.isOnline
                )
                async let deposits: Void = depositModel.load(
                    wallet: app.selectedWallet,
                    permitted: depositPermission,
                    online: app.isOnline
                )
                _ = await (transfers, deposits)
            }
            .onAppear { rebuildContactIndex(app.contactDirectory) }
            .onChange(of: app.contactDirectory) { _, contacts in
                rebuildContactIndex(contacts)
            }
            .refreshable {
                async let transfers: Void = model.load(
                    country: country,
                    permitted: transferPermission,
                    online: app.isOnline
                )
                async let deposits: Void = depositModel.load(
                    wallet: app.selectedWallet,
                    permitted: depositPermission,
                    online: app.isOnline
                )
                _ = await (transfers, deposits)
            }
            .sheet(item: $modal) { presented in
                Group {
                    switch presented {
                    case .addBeneficiary:
                        AddBankBeneficiaryView(
                            model: model,
                            permitted: transfersPermitted,
                            online: app.isOnline
                        )
                    case .send(let beneficiary):
                        BankTransferPaymentView(
                            model: model,
                            beneficiary: beneficiary,
                            permitted: transfersPermitted,
                            online: app.isOnline
                        )
                        .environmentObject(app)
                    case .transferReceipt(let operation):
                        BankTransferHistoryReceiptView(
                            model: model,
                            initialOperation: operation
                        )
                    case .newDeposit:
                        BankDepositFlowView(
                            model: depositModel,
                            initialDeposit: nil,
                            permitted: depositsPermitted,
                            online: app.isOnline
                        )
                        .environmentObject(app)
                    case .depositReceipt(let deposit):
                        BankDepositFlowView(
                            model: depositModel,
                            initialDeposit: deposit,
                            permitted: depositsPermitted,
                            online: app.isOnline
                        )
                        .environmentObject(app)
                    }
                }
                .presentationBackground(.ultraThinMaterial)
            }
        }
        .presentationBackground(.ultraThinMaterial)
        .interactiveDismissDisabled(model.isSubmitting || depositModel.isSubmitting)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "building.columns.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(KitColor.green.gradient, in: Circle())
            Text("Move money with your bank")
                .font(.title2.bold())
                .foregroundStyle(.primary)
            Text("Deposit into your Kit Pay wallet by bank transfer, or send from Kit Pay to a verified bank beneficiary. Every step stays visible until it is confirmed.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .kitGlass(cornerRadius: 25)
    }

    private var depositSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Deposit")
                .font(.title3.bold())
                .foregroundStyle(.primary)

            Button { modal = .newDeposit } label: {
                HStack(spacing: 14) {
                    Image(systemName: "arrow.down.to.line.compact")
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(KitColor.green.gradient, in: Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Deposit by bank transfer")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("Get a unique reference, transfer to Kit Pay, then upload your receipt.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.tertiary)
                }
                .padding(16)
                .kitGlass(cornerRadius: 22, shadow: false)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(
                !depositsPermitted || !app.isOnline
                    || depositModel.isLoading || depositModel.isSubmitting
                    || depositModel.activeAccounts(for: app.selectedWallet).isEmpty
            )
            .opacity(
                depositModel.activeAccounts(for: app.selectedWallet).isEmpty ? 0.58 : 1
            )

            if depositModel.isLoading && depositModel.accounts.isEmpty {
                ProgressView("Loading receiving accounts…")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else if let error = depositModel.accountLoadErrorMessage {
                BankTransferInlineError(message: error)
            } else if depositModel.activeAccounts(for: app.selectedWallet).isEmpty {
                BankTransferInlineError(
                    message: "No receiving bank account is available for this wallet's currency yet."
                )
            }

            if let error = depositModel.errorMessage {
                BankTransferInlineError(message: error)
            }
        }
    }

    private var depositsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent deposits")
                .font(.title3.bold())
                .foregroundStyle(.primary)

            if depositModel.isLoading && depositModel.deposits.isEmpty {
                ProgressView("Loading bank deposits…")
                    .frame(maxWidth: .infinity)
                    .padding(24)
            } else if let error = depositModel.depositLoadErrorMessage,
                      depositModel.deposits.isEmpty {
                BankTransferInlineError(message: error)
            } else if depositModel.deposits.isEmpty {
                Text("Deposits you create will appear here from reference generation through wallet credit.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .kitGlass(cornerRadius: 20, shadow: false)
            } else {
                ForEach(depositModel.deposits.prefix(20)) { deposit in
                    Button { modal = .depositReceipt(deposit) } label: {
                        BankDepositRow(deposit: deposit)
                    }
                    .buttonStyle(.plain)
                }

                if let error = depositModel.depositLoadErrorMessage {
                    BankTransferInlineError(message: error)
                }
            }
        }
    }

    private var beneficiariesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Send to bank")
                    .font(.title3.bold())
                    .foregroundStyle(.primary)
                Spacer()
                Button {
                    model.prepareAccountVerification()
                    modal = .addBeneficiary
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.subheadline.bold())
                }
                .disabled(
                    !transfersPermitted
                        || !app.isOnline
                        || model.isLoading
                        || model.isSubmitting
                        || model.banks.isEmpty
                )
            }

            if let error = model.bankCatalogErrorMessage {
                BankTransferInlineError(message: error)
            }

            if model.isLoading && model.beneficiaries.isEmpty {
                ProgressView("Loading beneficiaries…")
                    .frame(maxWidth: .infinity)
                    .padding(24)
            } else if let error = model.beneficiaryLoadErrorMessage,
                      model.beneficiaries.isEmpty {
                BankTransferInlineError(message: error)
            } else if model.transferableBeneficiaries.isEmpty {
                ContentUnavailableView(
                    "No bank beneficiaries",
                    systemImage: "person.crop.circle.badge.plus",
                    description: Text("Add and verify a beneficiary before sending money to a bank.")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .kitGlass(cornerRadius: 22)
            } else {
                ForEach(model.transferableBeneficiaries) { beneficiary in
                    Button { modal = .send(beneficiary) } label: {
                        beneficiaryRow(beneficiary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!transfersPermitted || !app.isOnline)
                }

                if let error = model.beneficiaryLoadErrorMessage {
                    BankTransferInlineError(message: error)
                }
            }

            if let error = model.errorMessage {
                BankTransferInlineError(message: error)
            }
        }
    }

    private func rebuildContactIndex(_ contacts: [WalletContactDTO]) {
        contactIndex = BeneficiaryContactIndex(contacts: contacts)
    }

    private func beneficiaryRow(_ beneficiary: BankBeneficiaryDTO) -> some View {
        let contact = contactIndex.contact(forAccountName: beneficiary.accountName)
        return HStack(spacing: 13) {
            Group {
                if let contact {
                    // This destination belongs to someone already on Kit Pay, so show the person
                    // rather than the institution — the account details underneath still say
                    // exactly where the money lands.
                    RemoteAvatarView(
                        name: contact.name,
                        avatarURL: contact.avatarURL,
                        size: 46,
                        ringOpacity: nil
                    )
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "building.columns.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(KitColor.primaryText)
                            .padding(3)
                            .background(KitColor.paleGreen, in: Circle())
                            .overlay(Circle().stroke(KitColor.canvas, lineWidth: 1))
                    }
                } else {
                    Image(systemName: "building.columns")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .frame(width: 46, height: 46)
                        .background(KitColor.paleGreen, in: Circle())
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(beneficiary.label)
                    .font(.body.bold())
                    .foregroundStyle(.primary)
                Text(beneficiary.accountName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(beneficiary.bank.name) · \(beneficiary.accountNumberMasked)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .kitGlass(cornerRadius: 20, shadow: false)
        .contentShape(Rectangle())
    }

    private var transfersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent bank transfers")
                .font(.title3.bold())
                .foregroundStyle(.primary)

            if model.isLoading && model.operations.isEmpty {
                ProgressView("Loading bank transfers…")
                    .frame(maxWidth: .infinity)
                    .padding(24)
            } else if let error = model.operationLoadErrorMessage,
                      model.operations.isEmpty {
                BankTransferInlineError(message: error)
            } else if model.operations.isEmpty {
                Text("Your submitted bank transfers will appear here with their confirmation status and reference.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .kitGlass(cornerRadius: 20, shadow: false)
            } else {
                ForEach(model.operations.prefix(20)) { operation in
                    Button { modal = .transferReceipt(operation) } label: {
                        BankTransferOperationRow(
                            operation: operation,
                            bankName: model.banks.first(where: { $0.id == operation.bankId })?.name
                        )
                    }
                    .buttonStyle(.plain)
                }

                if let error = model.operationLoadErrorMessage {
                    BankTransferInlineError(message: error)
                }
            }
        }
    }
}

private struct BankDepositPreparedProof {
    let data: Data
    let filename: String
    let mimeType: String
}

private enum BankDepositProofPreparation {
    static func photo(from data: Data) throws -> BankDepositPreparedProof {
        guard let image = UIImage(data: data) else {
            throw BankDepositProofUploadError.invalidDocument
        }
        let normalized = resized(image, maximumDimension: 3_000)
        for quality in [0.92, 0.82, 0.70, 0.58, 0.46] {
            if let encoded = normalized.jpegData(compressionQuality: quality),
               encoded.count <= BankDepositProofUploadPolicy.maximumBytes {
                return BankDepositPreparedProof(
                    data: encoded,
                    filename: "bank-transfer-receipt.jpg",
                    mimeType: "image/jpeg"
                )
            }
        }
        throw BankDepositProofUploadError.invalidDocument
    }

    static func importedFile(at url: URL) throws -> BankDepositPreparedProof {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        if let fileSize = values.fileSize,
           fileSize <= 0 || fileSize > BankDepositProofUploadPolicy.maximumBytes {
            throw BankDepositProofUploadError.invalidDocument
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let type = values.contentType ?? UTType(filenameExtension: url.pathExtension)
        let mimeType: String
        if type?.conforms(to: .pdf) == true {
            guard data.starts(with: Data("%PDF-".utf8)) else {
                throw BankDepositProofUploadError.invalidDocument
            }
            mimeType = "application/pdf"
        } else if type?.conforms(to: .png) == true {
            guard UIImage(data: data) != nil else {
                throw BankDepositProofUploadError.invalidDocument
            }
            mimeType = "image/png"
        } else if type?.conforms(to: .jpeg) == true {
            guard UIImage(data: data) != nil else {
                throw BankDepositProofUploadError.invalidDocument
            }
            mimeType = "image/jpeg"
        } else {
            throw BankDepositProofUploadError.invalidDocument
        }
        let filename = String(url.lastPathComponent.prefix(255))
        guard BankDepositProofUploadPolicy.accepts(
            data: data,
            filename: filename,
            mimeType: mimeType
        ) else { throw BankDepositProofUploadError.invalidDocument }
        return BankDepositPreparedProof(data: data, filename: filename, mimeType: mimeType)
    }

    private static func resized(_ image: UIImage, maximumDimension: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maximumDimension else { return image }
        let ratio = maximumDimension / longest
        let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

private struct BankDepositFlowView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: BankDepositViewModel
    let initialDeposit: BankDepositRequestDTO?
    let permitted: Bool
    let online: Bool

    @State private var deposit: BankDepositRequestDTO?
    @State private var accountID = ""
    @State private var amount = ""
    @State private var note = ""
    @State private var idempotencyKey = BankTransferIdempotency.key(prefix: "ios-bank-deposit")
    @State private var photoItem: PhotosPickerItem?
    @State private var preparedProof: BankDepositPreparedProof?
    @State private var importingDocument = false
    @State private var isPreparingProof = false

    private var wallet: Wallet? { app.selectedWallet }

    private var availableAccounts: [BankFundingAccountDTO] {
        model.activeAccounts(for: wallet)
    }

    private var selectedAccount: BankFundingAccountDTO? {
        availableAccounts.first(where: { $0.id == accountID })
    }

    private var currentDeposit: BankDepositRequestDTO? {
        guard let deposit else { return nil }
        return model.deposits.first(where: { $0.id == deposit.id }) ?? deposit
    }

    private var amountMode: PaymentAmountInputMode {
        let scale = max(0, min(9, Int(wallet?.currency.scale ?? "0") ?? 0))
        return scale == 0 ? .whole : .decimal(maximumFractionDigits: scale)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let currentDeposit {
                    depositDetails(currentDeposit)
                } else {
                    createForm
                }
            }
            .background(KitColor.canvas.ignoresSafeArea())
            .navigationTitle(currentDeposit == nil ? "Bank deposit" : "Deposit details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(currentDeposit == nil ? "Cancel" : "Done") { dismiss() }
                        .disabled(model.isSubmitting || isPreparingProof)
                }
                if let currentDeposit {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Task { deposit = await model.refresh(currentDeposit) ?? currentDeposit }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(model.isSubmitting || !online)
                        .accessibilityLabel("Refresh deposit status")
                    }
                }
            }
        }
        .interactiveDismissDisabled(model.isSubmitting || isPreparingProof)
        .onAppear {
            deposit = initialDeposit
            if accountID.isEmpty { accountID = availableAccounts.first?.id ?? "" }
            model.clearError()
        }
        .onChange(of: availableAccounts.map(\.id)) { _, ids in
            if !ids.contains(accountID) { accountID = ids.first ?? "" }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await preparePhoto(item) }
        }
        .fileImporter(
            isPresented: $importingDocument,
            allowedContentTypes: [.jpeg, .png, .pdf],
            allowsMultipleSelection: false
        ) { result in
            Task { await prepareImportedFile(result) }
        }
    }

    private var createForm: some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Deposit into Kit Pay", systemImage: "building.columns.fill")
                        .font(.title2.bold())
                        .foregroundStyle(.primary)
                    Text("Choose where to send your bank transfer. You do not need a beneficiary: the unique reference links the payment directly to your Kit Pay wallet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .kitGlass(cornerRadius: 24)

                if let wallet {
                    HStack(spacing: 13) {
                        Image(systemName: "wallet.bifold.fill")
                            .foregroundStyle(KitColor.green)
                            .frame(width: 44, height: 44)
                            .background(KitColor.paleGreen, in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(wallet.name).font(.headline)
                            Text("Funds will be credited to this wallet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(wallet.currency.code)
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .kitGlass(cornerRadius: 20, shadow: false)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Receiving account")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    if availableAccounts.isEmpty {
                        BankTransferInlineError(
                            message: "No receiving bank account is available for this wallet's currency."
                        )
                    } else {
                        Picker("Receiving account", selection: $accountID) {
                            ForEach(availableAccounts) { account in
                                Text("\(account.bank.name) · \(account.accountNumberMasked)")
                                    .tag(account.id)
                            }
                        }
                        .pickerStyle(.menu)
                        if let selectedAccount {
                            Text(selectedAccount.accountName)
                                .font(.subheadline.weight(.semibold))
                            Text(selectedAccount.accountNumberMasked)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .kitGlass(cornerRadius: 20)

                VStack(alignment: .leading, spacing: 9) {
                    Text("Deposit amount")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(wallet?.currency.code ?? "UGX")
                            .font(.headline.bold())
                            .foregroundStyle(KitColor.green)
                        KitAmountTextField(
                            "0",
                            value: $amount,
                            mode: amountMode,
                            textStyle: .large,
                            textAlignment: .right
                        )
                    }
                    Text("Enter the exact amount you will transfer from your bank.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(18)
                .kitGlass(cornerRadius: 20)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Optional note")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    TextField("For your records", text: $note, axis: .vertical)
                        .lineLimit(2 ... 4)
                        .onChange(of: note) { _, value in
                            if value.count > 280 { note = String(value.prefix(280)) }
                        }
                    Text("\(note.count)/280")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(18)
                .kitGlass(cornerRadius: 20)

                if let error = model.errorMessage {
                    BankTransferInlineError(message: error)
                }

                Button {
                    guard let selectedAccount else { return }
                    Task {
                        if let created = await model.create(
                            wallet: wallet,
                            fundingAccount: selectedAccount,
                            enteredAmount: amount,
                            note: note,
                            idempotencyKey: idempotencyKey,
                            permitted: permitted,
                            online: online
                        ) {
                            deposit = created
                        }
                    }
                } label: {
                    if model.isSubmitting {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    } else {
                        Label("Get deposit instructions", systemImage: "arrow.right.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(KitPrimaryButtonStyle())
                .disabled(
                    model.isSubmitting || !permitted || !online || selectedAccount == nil
                        || BankDepositMoney.apiAmount(
                            amount,
                            scale: Int(wallet?.currency.scale ?? "") ?? -1
                        ) == nil
                )
            }
            .padding(22)
        }
    }

    private func depositDetails(_ deposit: BankDepositRequestDTO) -> some View {
        let presentation = BankDepositStatusPresentation(status: deposit.status)
        return ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 12) {
                    Image(systemName: presentation.icon)
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 78, height: 78)
                        .background(presentation.color.gradient, in: Circle())
                    Text(presentation.title)
                        .font(.title.bold())
                        .foregroundStyle(.primary)
                    Text(BankTransferDisplay.amount(deposit.amount, currency: deposit.currency))
                        .font(.system(size: 32, weight: .heavy, design: .rounded))
                        .foregroundStyle(.primary)
                    Text(presentation.message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if !deposit.isTerminal {
                    referenceCard(deposit)
                    receivingAccountCard(deposit)
                }

                if deposit.acceptsProof {
                    proofCard(deposit)
                } else if let proof = deposit.proof {
                    submittedProofCard(proof)
                }

                VStack(spacing: 13) {
                    detailRow("Deposit reference", deposit.reference, monospaced: true)
                    detailRow("Status", presentation.title)
                    detailRow("Bank", deposit.fundingAccount.bank.name)
                    detailRow("Kit Pay wallet", wallet?.name ?? "Selected wallet")
                    if let bankReference = deposit.bankTransactionReference {
                        detailRow("Bank transaction", bankReference, monospaced: true)
                    }
                    if let completed = deposit.completedAt {
                        detailRow("Completed", formattedDate(completed))
                    }
                }
                .padding(18)
                .kitGlass(cornerRadius: 22)

                if let rejection = deposit.rejection {
                    BankTransferInlineError(
                        message: rejection.reason ?? "The payment proof could not be matched to this deposit."
                    )
                }
                if let error = model.errorMessage {
                    BankTransferInlineError(message: error)
                }

                if deposit.isTerminal {
                    Button("Start another deposit") {
                        self.deposit = nil
                        amount = ""
                        note = ""
                        preparedProof = nil
                        photoItem = nil
                        idempotencyKey = BankTransferIdempotency.key(prefix: "ios-bank-deposit")
                        model.clearError()
                    }
                    .buttonStyle(KitPrimaryButtonStyle())
                    .disabled(!permitted || !online)
                }
            }
            .padding(22)
        }
    }

    private func referenceCard(_ deposit: BankDepositRequestDTO) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your payment reference")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Text(deposit.reference)
                    .font(.system(.title3, design: .monospaced).bold())
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .minimumScaleFactor(0.72)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button {
                    UIPasteboard.general.string = deposit.reference
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.caption.bold())
                }
                .buttonStyle(.bordered)
            }
            Text("Use this exact reference in your bank transfer. It is how Kit Pay matches the payment to your wallet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(KitColor.paleGreen.opacity(0.8), in: RoundedRectangle(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .stroke(KitColor.green.opacity(0.28), lineWidth: 1)
        }
    }

    private func receivingAccountCard(_ deposit: BankDepositRequestDTO) -> some View {
        let account = deposit.fundingAccount
        return VStack(alignment: .leading, spacing: 13) {
            Text("Transfer to")
                .font(.headline)
                .foregroundStyle(.primary)
            detailRow("Bank", account.bank.name)
            detailRow("Account name", account.accountName)
            detailRow("Account number", account.accountNumber, monospaced: true)
            if let branch = account.branchName { detailRow("Branch", branch) }
            if let swift = account.swiftCode { detailRow("SWIFT", swift, monospaced: true) }
            if let instructions = account.instructions, !instructions.isEmpty {
                Divider()
                Text(instructions)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Label(
                "Do not send a different amount or omit the reference.",
                systemImage: "exclamationmark.shield.fill"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
        }
        .padding(18)
        .kitGlass(cornerRadius: 22)
    }

    private func proofCard(_ deposit: BankDepositRequestDTO) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(deposit.proof == nil ? "Upload payment proof" : "Replace payment proof")
                .font(.headline)
                .foregroundStyle(.primary)
            Text("After completing the bank transfer, add a clear receipt image or PDF. Kit Pay staff will verify it before your wallet is credited.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Photo", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button { importingDocument = true } label: {
                    Label("File", systemImage: "doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .disabled(model.isSubmitting || isPreparingProof || !online)

            if isPreparingProof {
                ProgressView("Preparing receipt…")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let preparedProof {
                HStack(spacing: 10) {
                    Image(systemName: preparedProof.mimeType == "application/pdf"
                        ? "doc.fill" : "photo.fill")
                        .foregroundStyle(KitColor.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preparedProof.filename)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(ByteCountFormatter.string(
                            fromByteCount: Int64(preparedProof.data.count),
                            countStyle: .file
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(KitColor.green)
                }
                .padding(13)
                .background(KitColor.paleGreen.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))

                Button {
                    Task {
                        if let updated = await model.uploadProof(
                            for: deposit,
                            data: preparedProof.data,
                            filename: preparedProof.filename,
                            mimeType: preparedProof.mimeType,
                            permitted: permitted,
                            online: online
                        ) {
                            self.deposit = updated
                            self.preparedProof = nil
                            self.photoItem = nil
                        }
                    }
                } label: {
                    if model.isSubmitting {
                        HStack { Spacer(); ProgressView("Uploading…"); Spacer() }
                    } else {
                        Label("Submit receipt for review", systemImage: "arrow.up.doc.fill")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(KitPrimaryButtonStyle())
                .disabled(model.isSubmitting || !permitted || !online)
            }
        }
        .padding(18)
        .kitGlass(cornerRadius: 22)
    }

    private func submittedProofCard(_ proof: BankDepositProofDTO) -> some View {
        HStack(spacing: 12) {
            Image(systemName: proof.mimeType == "application/pdf" ? "doc.fill" : "photo.fill")
                .foregroundStyle(KitColor.green)
                .frame(width: 42, height: 42)
                .background(KitColor.paleGreen, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text("Payment proof submitted")
                    .font(.headline)
                Text(proof.filename)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(KitColor.green)
        }
        .padding(17)
        .kitGlass(cornerRadius: 20, shadow: false)
    }

    private func detailRow(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 18)
            Text(value)
                .font(monospaced ? .subheadline.monospaced() : .subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func formattedDate(_ value: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: value) else { return value }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    @MainActor
    private func preparePhoto(_ item: PhotosPickerItem) async {
        isPreparingProof = true
        model.clearError()
        defer { isPreparingProof = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw BankDepositProofUploadError.invalidDocument
            }
            preparedProof = try BankDepositProofPreparation.photo(from: data)
        } catch {
            preparedProof = nil
            model.errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func prepareImportedFile(_ result: Result<[URL], Error>) async {
        isPreparingProof = true
        model.clearError()
        defer { isPreparingProof = false }
        do {
            guard let url = try result.get().first else {
                throw BankDepositProofUploadError.invalidDocument
            }
            preparedProof = try BankDepositProofPreparation.importedFile(at: url)
            photoItem = nil
        } catch {
            preparedProof = nil
            model.errorMessage = error.localizedDescription
        }
    }
}

private struct BankDepositRow: View {
    let deposit: BankDepositRequestDTO

    var body: some View {
        let presentation = BankDepositStatusPresentation(status: deposit.status)
        HStack(spacing: 13) {
            Image(systemName: presentation.icon)
                .font(.headline)
                .foregroundStyle(presentation.color)
                .frame(width: 44, height: 44)
                .background(presentation.color.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(deposit.fundingAccount.bank.name)
                    .font(.body.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(deposit.reference)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text(presentation.title)
                    .font(.caption2.bold())
                    .foregroundStyle(presentation.color)
            }
            Spacer()
            Text(BankTransferDisplay.amount(deposit.amount, currency: deposit.currency))
                .font(.subheadline.bold())
                .foregroundStyle(.primary)
        }
        .padding(14)
        .kitGlass(cornerRadius: 20, shadow: false)
    }
}

private struct BankDepositStatusPresentation {
    let title: String
    let message: String
    let icon: String
    let color: Color

    init(status: String) {
        switch status.lowercased() {
        case "awaiting_proof":
            title = "Awaiting receipt"
            message = "Complete the bank transfer using the exact reference, then upload your receipt."
            icon = "doc.badge.arrow.up.fill"
            color = .orange
        case "proof_submitted":
            title = "Receipt submitted"
            message = "Your receipt is securely uploaded and will be checked before approval."
            icon = "checkmark.shield.fill"
            color = .blue
        case "awaiting_approval":
            title = "Under review"
            message = "The transfer evidence was verified and is awaiting independent approval."
            icon = "person.badge.clock.fill"
            color = .blue
        case "approved", "completed":
            title = "Wallet credited"
            message = "The bank transfer was approved and the money is now in your Kit Pay wallet."
            icon = "checkmark.circle.fill"
            color = KitColor.green
        case "rejected":
            title = "Deposit not approved"
            message = "Review the reason below before creating another deposit."
            icon = "exclamationmark.triangle.fill"
            color = .red
        case "expired":
            title = "Deposit expired"
            message = "This reference expired before the deposit could be approved. Create a new deposit to continue."
            icon = "clock.badge.exclamationmark.fill"
            color = .orange
        default:
            title = status.replacingOccurrences(of: "_", with: " ").capitalized
            message = "Kit Pay is checking the latest status of this bank deposit."
            icon = "clock.arrow.circlepath"
            color = .blue
        }
    }
}

private struct AddBankBeneficiaryView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: BankTransferViewModel
    let permitted: Bool
    let online: Bool

    @State private var bankId = ""
    @State private var accountNumber = ""
    @State private var label = ""
    @State private var kind = "third_party"
    @State private var verificationKey = BankTransferIdempotency.key(prefix: "ios-bank-verify")
    @State private var beneficiaryKey = BankTransferIdempotency.key(prefix: "ios-bank-beneficiary")

    private var eligibleBanks: [BankDTO] {
        BankBeneficiaryRailPolicy.bankRailBanks(model.banks).filter(\.canVerifyAccount)
    }

    private var selectedBank: BankDTO? {
        eligibleBanks.first(where: { $0.id == bankId })
    }

    var body: some View {
        NavigationStack {
            Form {
                if let verification = model.verification, verification.isVerified {
                    verifiedAccountSection(verification)
                    beneficiaryDetailsSection(verification)
                } else {
                    accountEntrySection
                }

                if let error = model.errorMessage {
                    Section { BankTransferInlineError(message: error) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(KitColor.canvas.ignoresSafeArea())
            .navigationTitle("Add bank beneficiary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(model.isSubmitting)
                }
            }
            .interactiveDismissDisabled(model.isSubmitting)
            .onAppear {
                model.prepareAccountVerification()
                if bankId.isEmpty { bankId = eligibleBanks.first?.id ?? "" }
            }
            .onChange(of: bankId) { _, _ in
                guard !model.isSubmitting else { return }
                model.prepareAccountVerification()
                verificationKey = BankTransferIdempotency.key(prefix: "ios-bank-verify")
            }
            .onChange(of: accountNumber) { _, _ in
                guard !model.isSubmitting else { return }
                model.prepareAccountVerification()
                verificationKey = BankTransferIdempotency.key(prefix: "ios-bank-verify")
            }
        }
    }

    private var accountEntrySection: some View {
        Group {
            Section("Bank") {
                if eligibleBanks.isEmpty {
                    ContentUnavailableView(
                        "No transfer banks available",
                        systemImage: "building.columns",
                        description: Text("Refresh the bank catalog and try again.")
                    )
                } else {
                    Picker("Select bank", selection: $bankId) {
                        ForEach(eligibleBanks) { bank in
                            Text(bank.name).tag(bank.id)
                        }
                    }
                }
            }

            Section("Account") {
                TextField("Bank account number", text: Binding(
                    get: { accountNumber },
                    set: { accountNumber = BankAccountNumber.normalizedInput($0) }
                ))
                .keyboardType(.asciiCapable)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()

                Text("Kit Pay sends the account to \(selectedBank?.name ?? "the selected bank") only for verification. A transfer cannot be sent to an unverified account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    Task {
                        if let verification = await model.verifyAccount(
                            bankId: bankId,
                            accountNumber: accountNumber,
                            idempotencyKey: verificationKey,
                            permitted: permitted,
                            online: online
                        ) {
                            label = verification.verifiedAccountName ?? ""
                        }
                    }
                } label: {
                    if model.isSubmitting {
                        HStack {
                            Spacer()
                            ProgressView("Verifying with bank…")
                            Spacer()
                        }
                    } else {
                        Label("Verify bank account", systemImage: "checkmark.shield.fill")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(
                    model.isSubmitting || !permitted || !online || bankId.isEmpty
                        || BankAccountNumber.apiValue(from: accountNumber) == nil
                )
            }
        }
    }

    private func verifiedAccountSection(_ verification: BankAccountVerificationDTO) -> some View {
        Section("Bank-confirmed account") {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verification.verifiedAccountName ?? "Verified account")
                        .font(.headline)
                    Text("\(selectedBank?.name ?? "Bank") · \(verification.accountNumberMasked)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(KitColor.green)
            }

            Button("Use a different account") {
                model.prepareAccountVerification()
                verificationKey = BankTransferIdempotency.key(prefix: "ios-bank-verify")
                beneficiaryKey = BankTransferIdempotency.key(prefix: "ios-bank-beneficiary")
            }
            .disabled(model.isSubmitting)
        }
    }

    private func beneficiaryDetailsSection(_ verification: BankAccountVerificationDTO) -> some View {
        Group {
            Section("Beneficiary details") {
                TextField("Label", text: $label)
                    .textInputAutocapitalization(.words)
                    .onChange(of: label) { _, value in
                        if value.count > 100 { label = String(value.prefix(100)) }
                        if !model.isSubmitting {
                            beneficiaryKey = BankTransferIdempotency.key(
                                prefix: "ios-bank-beneficiary"
                            )
                        }
                    }

                Picker("Account belongs to", selection: $kind) {
                    Text("Someone else").tag("third_party")
                    Text("Me").tag("own")
                }
                .pickerStyle(.segmented)
                .onChange(of: kind) { _, _ in
                    guard !model.isSubmitting else { return }
                    beneficiaryKey = BankTransferIdempotency.key(
                        prefix: "ios-bank-beneficiary"
                    )
                }
            }

            Section {
                Button {
                    Task {
                        if await model.saveBeneficiary(
                            label: label,
                            kind: kind,
                            idempotencyKey: beneficiaryKey,
                            permitted: permitted,
                            online: online
                        ) != nil {
                            dismiss()
                        }
                    }
                } label: {
                    if model.isSubmitting {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    } else {
                        Label("Save verified beneficiary", systemImage: "person.crop.circle.badge.checkmark")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(
                    model.isSubmitting || !permitted || !online
                        || verification.verifiedAccountName == nil
                        || label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
    }
}

private struct BankTransferPaymentView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: BankTransferViewModel
    let beneficiary: BankBeneficiaryDTO
    let permitted: Bool
    let online: Bool

    @State private var amount = ""
    @State private var pin = ""
    @State private var quote: BankTransferQuoteDTO?
    @State private var selectedFeeMode: BankTransferFeeMode = .senderAbsorbs
    @State private var submittedOperation: BankingOperationDTO?
    @State private var idempotencyKey = BankTransferIdempotency.key(prefix: "ios-bank-transfer")
    /// Non-nil while the customer is topping up to cover this transfer.
    @State private var topUpRequest: WalletTopUpRequirement?

    /// The full wallet debit, transaction fee included, against the balance as it stands now.
    private func topUpRequirement(for quote: BankTransferQuoteDTO) -> WalletTopUpRequirement? {
        WalletTopUpPolicy.requirement(
            wallet: app.selectedWallet,
            debitAPIAmount: quote.customerDebit
        )
    }

    private var currentOperation: BankingOperationDTO? {
        guard let submittedOperation else { return nil }
        return model.operations.first(where: { $0.id == submittedOperation.id }) ?? submittedOperation
    }

    private var feeMode: BankTransferFeeMode { selectedFeeMode }

    var body: some View {
        NavigationStack {
            Group {
                if let operation = currentOperation {
                    receipt(operation)
                } else if let quote {
                    quoteReview(quote)
                } else {
                    transferForm
                }
            }
            .background(KitColor.canvas.ignoresSafeArea())
            .navigationTitle("Send to bank")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(submittedOperation == nil ? "Cancel" : "Done") { dismiss() }
                        .disabled(model.isSubmitting)
                }
            }
            .interactiveDismissDisabled(model.isSubmitting)
            .sheet(item: $topUpRequest) { requirement in
                WalletTopUpView(requirement: requirement) { covered in
                    guard covered else { return }
                    WalletTopUpPresentation.afterDismissal { requoteAfterTopUp() }
                }
                .environmentObject(app)
                .presentationBackground(.ultraThinMaterial)
            }
        }
    }

    /// A quote reviewed before a top-up has expired by the time the money lands, so a fresh one is
    /// fetched for the same amount — the customer returns to a ready approval, not a blank form.
    @MainActor
    private func requoteAfterTopUp() {
        guard submittedOperation == nil else { return }
        model.errorMessage = nil
        pin = ""
        idempotencyKey = BankTransferIdempotency.key(prefix: "ios-bank-transfer")
        Task {
            quote = await model.createTransferQuote(
                beneficiary: beneficiary,
                wallet: app.selectedWallet,
                enteredAmount: amount,
                feeMode: feeMode,
                permitted: permitted,
                online: online
            )
        }
    }

    /// The balance on the device can be a moment behind the ledger. When the server is the one to
    /// find it short, the same top-up is offered rather than a bare refusal.
    @MainActor
    private func offerTopUpIfServerFoundBalanceShort() async {
        guard let debit = model.insufficientFundsDebitAmount else { return }
        model.insufficientFundsDebitAmount = nil
        await app.refresh()
        guard let requirement = WalletTopUpPolicy.requirement(
            wallet: app.selectedWallet,
            debitAPIAmount: debit
        ) else { return }
        topUpRequest = requirement
    }

    private var transferForm: some View {
        ScrollView {
            VStack(spacing: 17) {
                beneficiarySummary

                VStack(alignment: .leading, spacing: 9) {
                    Text("Amount")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("UGX")
                            .font(.headline.bold())
                            .foregroundStyle(KitColor.green)
                        KitAmountTextField(
                            "0",
                            value: $amount,
                            mode: .whole,
                            textStyle: .large,
                            textAlignment: .right
                        )
                        .onChange(of: amount) { _, _ in
                            guard !model.isSubmitting else { return }
                            quote = nil
                            idempotencyKey = BankTransferIdempotency.key(
                                prefix: "ios-bank-transfer"
                            )
                        }
                    }
                    Text("Minimum transfer: UGX 20,000")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(18)
                .kitGlass(cornerRadius: 20)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 9) {
                        ForEach(["20000", "50000", "100000", "500000"], id: \.self) { value in
                            Button("UGX \(KitMoney.amount(value, scale: 0))") {
                                amount = value
                            }
                            .font(.caption.bold())
                            .foregroundStyle(amount == value ? Color.white : Color.primary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 9)
                            .background(
                                amount == value ? KitColor.green : KitColor.paleGreen,
                                in: Capsule()
                            )
                        }
                    }
                }

                VStack(spacing: 10) {
                    ForEach(
                        [BankTransferFeeMode.senderAbsorbs, .beneficiaryAbsorbs],
                        id: \.self
                    ) { mode in
                        Button {
                            selectedFeeMode = mode
                            model.errorMessage = nil
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: selectedFeeMode == mode
                                    ? "checkmark.circle.fill"
                                    : "circle")
                                    .font(.title3)
                                    .foregroundStyle(selectedFeeMode == mode
                                        ? KitColor.green
                                        : .secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(mode.customerFacingTreatment)
                                        .font(.subheadline.bold())
                                        .foregroundStyle(.primary)
                                    Text(mode == .senderAbsorbs
                                        ? "The beneficiary receives the full amount entered. The transaction fee is added to your wallet debit."
                                        : "The transaction fee is deducted from the amount entered before it reaches the beneficiary.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .kitGlass(cornerRadius: 18, shadow: false)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isSubmitting)
                        .accessibilityLabel(mode.customerFacingTreatment)
                        .accessibilityValue(selectedFeeMode == mode
                            ? "Selected"
                            : "Not selected")
                    }
                }

                Text("Kit Pay will show the recipient amount, transaction fee, and exact wallet debit before asking for approval.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let error = model.errorMessage {
                    BankTransferInlineError(message: error)
                }

                Button {
                    Task {
                        quote = await model.createTransferQuote(
                            beneficiary: beneficiary,
                            wallet: app.selectedWallet,
                            enteredAmount: amount,
                            feeMode: feeMode,
                            permitted: permitted,
                            online: online
                        )
                    }
                } label: {
                    if model.isSubmitting {
                        ProgressView().tint(.white).frame(maxWidth: .infinity)
                    } else {
                        Label("Review transaction fee and total", systemImage: "doc.text.magnifyingglass")
                        .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(KitPrimaryButtonStyle())
                .disabled(
                    model.isSubmitting || !permitted || !online
                        || BankTransferMoney.transferableWholeUGXAmount(amount) == nil
                )
            }
            .padding(22)
        }
    }

    private func quoteReview(_ quote: BankTransferQuoteDTO) -> some View {
        ScrollView {
            VStack(spacing: 17) {
                beneficiarySummary

                VStack(alignment: .leading, spacing: 14) {
                    Label("Review exact transfer", systemImage: "checkmark.shield.fill")
                        .font(.headline)
                        .foregroundStyle(KitColor.green)

                    quoteAmountRow("Beneficiary receives", quote.recipientAmount, currency: quote.currency)
                    quoteAmountRow(
                        CustomerFacingPaymentCopy.transactionFeeTitle,
                        quote.processingFee,
                        currency: quote.currency
                    )
                    HStack(alignment: .top) {
                        Text("Fee treatment").foregroundStyle(.secondary)
                        Spacer(minLength: 20)
                        Text(quote.feeMode.customerFacingTreatment)
                            .fontWeight(.semibold)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.trailing)
                    }
                    .font(.subheadline)
                    Divider()
                    quoteAmountRow(
                        "Total from your wallet",
                        quote.customerDebit,
                        currency: quote.currency,
                        emphasized: true
                    )
                }
                .padding(18)
                .kitGlass(cornerRadius: 22)

                Text(quote.feeMode.customerFacingExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if quote.isExpired {
                    BankTransferInlineError(
                        message: "This review expired. Check the latest transaction fee and total before approving."
                    )
                }

                if let requirement = topUpRequirement(for: quote) {
                    WalletShortfallNotice(requirement: requirement) {
                        topUpRequest = requirement
                    }
                    .padding(18)
                    .kitGlass(cornerRadius: 22)
                }

                approvalControl

                if let error = model.errorMessage {
                    BankTransferInlineError(message: error)
                }

                Button {
                    Task {
                        if let operation = await model.submitQuotedTransfer(
                            quote: quote,
                            beneficiary: beneficiary,
                            wallet: app.selectedWallet,
                            pin: pin,
                            idempotencyKey: idempotencyKey,
                            permitted: permitted,
                            online: online,
                            authorization: { purpose, intent, pin, reason in
                                try await app.authorizeFinancialStepUp(
                                    purpose: purpose,
                                    intent: intent,
                                    pin: pin,
                                    reason: reason
                                )
                            }
                        ) {
                            submittedOperation = operation
                            self.quote = nil
                            await app.refresh()
                        } else {
                            await offerTopUpIfServerFoundBalanceShort()
                        }
                    }
                } label: {
                    if model.isSubmitting {
                        ProgressView().tint(.white).frame(maxWidth: .infinity)
                    } else {
                        Label(
                            app.financialApprovalUsesBiometrics
                                ? "Approve bank transfer"
                                : "Send bank transfer",
                            systemImage: "lock.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(KitPrimaryButtonStyle())
                .disabled(
                    model.isSubmitting || quote.isExpired || !permitted || !online
                        || topUpRequirement(for: quote) != nil
                        || (!app.financialApprovalUsesBiometrics && pin.count != 4)
                )

                Button("Edit transfer details") { resetQuote() }
                    .disabled(model.isSubmitting)
            }
            .padding(22)
        }
    }

    @ViewBuilder
    private var approvalControl: some View {
        if app.financialApprovalUsesBiometrics {
            Label {
                Text("Approve this exact quoted transfer with \(app.biometricDisplayName).")
            } icon: {
                Image(systemName: app.biometricSymbolName)
                    .foregroundStyle(KitColor.green)
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .kitGlass(cornerRadius: 18, shadow: false)
        } else {
            SecureField("Four-digit wallet PIN", text: $pin)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .padding(17)
                .kitGlass(cornerRadius: 18)
                .onChange(of: pin) { _, value in
                    pin = String(value.filter(\.isNumber).prefix(4))
                }
        }
    }

    private func quoteAmountRow(
        _ title: String,
        _ value: String,
        currency: CurrencyDTO,
        emphasized: Bool = false
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(emphasized ? .primary : .secondary)
            Spacer(minLength: 16)
            Text(BankTransferDisplay.amount(value, currency: currency))
                .fontWeight(emphasized ? .bold : .semibold)
                .foregroundStyle(emphasized ? KitColor.green : .primary)
                .multilineTextAlignment(.trailing)
        }
        .font(emphasized ? .headline : .subheadline)
    }

    private func resetQuote() {
        quote = nil
        pin = ""
        model.errorMessage = nil
        idempotencyKey = BankTransferIdempotency.key(prefix: "ios-bank-transfer")
    }

    private var beneficiarySummary: some View {
        HStack(spacing: 13) {
            Image(systemName: "building.columns.fill")
                .foregroundStyle(.primary)
                .frame(width: 48, height: 48)
                .background(KitColor.paleGreen, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(beneficiary.accountName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(beneficiary.bank.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(beneficiary.accountNumberMasked)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(KitColor.green)
                .accessibilityLabel("Bank verified")
        }
        .padding(17)
        .kitGlass(cornerRadius: 21)
    }

    private func receipt(_ operation: BankingOperationDTO) -> some View {
        let presentation = BankTransferStatusPresentation(status: operation.status)
        return ScrollView {
            VStack(spacing: 18) {
                Image(systemName: presentation.icon)
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 88, height: 88)
                    .background(presentation.color.gradient, in: Circle())

                Text(presentation.title)
                    .font(.largeTitle.bold())
                    .foregroundStyle(.primary)
                Text(BankTransferDisplay.amount(operation.amount, currency: operation.currency))
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .foregroundStyle(.primary)
                Text(presentation.message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                VStack(spacing: 13) {
                    receiptRow("Beneficiary", beneficiary.accountName)
                    receiptRow("Bank", beneficiary.bank.name)
                    receiptRow("Account", beneficiary.accountNumberMasked)
                    receiptRow("Status", operation.status.replacingOccurrences(of: "_", with: " ").capitalized)
                    if let pricing = operation.outboundPricing {
                        receiptRow(
                            CustomerFacingPaymentCopy.transactionFeeTitle,
                            BankTransferDisplay.amount(
                                pricing.processingFee,
                                currency: operation.currency
                            )
                        )
                        receiptRow(
                            "Total from wallet",
                            BankTransferDisplay.amount(
                                pricing.customerDebit,
                                currency: operation.currency
                            )
                        )
                        receiptRow(
                            "Fee treatment",
                            pricing.feeMode.customerFacingTreatment
                        )
                    }
                    receiptRow("Kit Pay reference", operation.reference)
                    if let providerReference = operation.providerReference {
                        receiptRow("Bank reference", providerReference)
                    }
                }
                .padding(18)
                .kitGlass(cornerRadius: 22)

                if let failure = operation.failure {
                    BankTransferInlineError(
                        message: failure.message.map {
                            CustomerFacingPaymentCopy.neutralizedServiceMessage($0)
                        } ?? "The bank did not complete this transfer."
                    )
                }

                Button("Done") { dismiss() }
                    .buttonStyle(KitPrimaryButtonStyle())
            }
            .padding(24)
        }
    }

    private func receiptRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 20)
            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.subheadline)
    }
}

private struct BankTransferOperationRow: View {
    let operation: BankingOperationDTO
    let bankName: String?

    var body: some View {
        let presentation = BankTransferStatusPresentation(status: operation.status)
        HStack(spacing: 13) {
            Image(systemName: presentation.icon)
                .font(.headline)
                .foregroundStyle(presentation.color)
                .frame(width: 44, height: 44)
                .background(presentation.color.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(bankName ?? "Bank transfer")
                    .font(.body.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(operation.reference)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(operation.status.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.caption2.bold())
                    .foregroundStyle(presentation.color)
            }
            Spacer()
            Text(BankTransferDisplay.amount(operation.amount, currency: operation.currency))
                .font(.subheadline.bold())
                .foregroundStyle(.primary)
        }
        .padding(14)
        .kitGlass(cornerRadius: 20, shadow: false)
    }
}

private struct BankTransferHistoryReceiptView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: BankTransferViewModel
    let initialOperation: BankingOperationDTO

    private var operation: BankingOperationDTO {
        model.operations.first(where: { $0.id == initialOperation.id }) ?? initialOperation
    }

    private var beneficiary: BankBeneficiaryDTO? {
        guard let beneficiaryId = operation.beneficiaryId else { return nil }
        return model.beneficiaries.first(where: { $0.id == beneficiaryId })
    }

    private var bankName: String {
        beneficiary?.bank.name
            ?? model.banks.first(where: { $0.id == operation.bankId })?.name
            ?? "Bank"
    }

    var body: some View {
        let presentation = BankTransferStatusPresentation(status: operation.status)
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Image(systemName: presentation.icon)
                        .font(.system(size: 38, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 88, height: 88)
                        .background(presentation.color.gradient, in: Circle())
                    Text(presentation.title)
                        .font(.largeTitle.bold())
                        .foregroundStyle(.primary)
                    Text(BankTransferDisplay.amount(operation.amount, currency: operation.currency))
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                        .foregroundStyle(.primary)
                    Text(presentation.message)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 13) {
                        if let beneficiary {
                            receiptRow("Beneficiary", beneficiary.accountName)
                            receiptRow("Account", beneficiary.accountNumberMasked)
                        }
                        receiptRow("Bank", bankName)
                        receiptRow(
                            "Status",
                            operation.status.replacingOccurrences(of: "_", with: " ").capitalized
                        )
                        if let pricing = operation.outboundPricing {
                            receiptRow(
                                CustomerFacingPaymentCopy.transactionFeeTitle,
                                BankTransferDisplay.amount(
                                    pricing.processingFee,
                                    currency: operation.currency
                                )
                            )
                            receiptRow(
                                "Total from wallet",
                                BankTransferDisplay.amount(
                                    pricing.customerDebit,
                                    currency: operation.currency
                                )
                            )
                            receiptRow(
                                "Fee treatment",
                                pricing.feeMode.customerFacingTreatment
                            )
                        }
                        receiptRow("Kit Pay reference", operation.reference)
                        if let providerReference = operation.providerReference {
                            receiptRow("Bank reference", providerReference)
                        }
                    }
                    .padding(18)
                    .kitGlass(cornerRadius: 22)

                    if let failure = operation.failure {
                        BankTransferInlineError(
                            message: failure.message.map {
                                CustomerFacingPaymentCopy.neutralizedServiceMessage($0)
                            } ?? "The bank did not complete this transfer."
                        )
                    }
                }
                .padding(24)
            }
            .background(KitColor.canvas.ignoresSafeArea())
            .navigationTitle("Transfer receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func receiptRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 20)
            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.subheadline)
    }
}

private extension BankTransferFeeMode {
    var customerFacingTreatment: String {
        switch self {
        case .senderAbsorbs:
            "Covered by me"
        case .beneficiaryAbsorbs:
            "Covered by beneficiary"
        case .kitCovers:
            "Not charged to your wallet"
        }
    }

    var customerFacingExplanation: String {
        switch self {
        case .senderAbsorbs:
            "The beneficiary receives the full amount entered. The disclosed transaction fee is added to your wallet debit."
        case .beneficiaryAbsorbs:
            "The disclosed transaction fee is deducted from the amount entered before the beneficiary receives it."
        case .kitCovers:
            "The beneficiary receives the full amount entered. The disclosed transaction fee is not charged to your wallet."
        }
    }
}

private struct BankTransferInlineError: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 15))
    }
}

private struct BankTransferStatusPresentation {
    let title: String
    let message: String
    let icon: String
    let color: Color

    init(status: String) {
        switch status.lowercased() {
        case "completed", "succeeded":
            title = "Transfer complete"
            message = "The bank confirmed this transfer."
            icon = "checkmark"
            color = KitColor.green
        case "failed", "cancelled", "canceled":
            title = "Transfer not completed"
            message = "The bank did not complete this transfer. Review the status before trying again."
            icon = "xmark"
            color = .red
        case "reversed":
            title = "Transfer reversed"
            message = "The transfer was reversed. Review your wallet activity for the returned amount."
            icon = "arrow.uturn.backward"
            color = .orange
        case "unknown":
            title = "Confirmation pending"
            message = "Kit Pay is reconciling the provider result. Do not submit the same transfer again."
            icon = "questionmark"
            color = .orange
        default:
            title = "Transfer submitted"
            message = "The amount is reserved while Kit Pay waits for the bank's confirmation."
            icon = "clock.fill"
            color = .orange
        }
    }
}

private enum BankTransferDisplay {
    static func amount(_ value: String, currency: CurrencyDTO) -> String {
        KitMoney.formatted(value, currency: currency, trimZeroFraction: true)
    }
}

private enum BankTransferFlowError: LocalizedError {
    case verificationMismatch
    case verificationIncomplete(String)
    case unconfirmedBeneficiary
    case quoteMismatch
    case quoteExpired
    case invalidStepUp
    case operationMismatch

    var errorDescription: String? {
        switch self {
        case .verificationMismatch:
            "Kit Pay could not confirm that the bank verified the selected account. Nothing was saved."
        case .verificationIncomplete(let message):
            message
        case .unconfirmedBeneficiary:
            "Kit Pay did not confirm this verified beneficiary. Refresh before trying again."
        case .quoteMismatch:
            "The transaction fee or total changed. Nothing was submitted. Please review the latest amounts."
        case .quoteExpired:
            "This review expired. Check the latest transaction fee and total before approving."
        case .invalidStepUp:
            "Kit Pay could not bind approval to this exact bank transfer. Nothing was submitted."
        case .operationMismatch:
            "Kit Pay could not confirm the exact bank transfer response. Check recent transfers before retrying."
        }
    }
}
