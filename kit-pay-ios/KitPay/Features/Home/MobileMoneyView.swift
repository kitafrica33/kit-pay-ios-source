import Foundation
import SwiftUI

enum MobileMoneySavedAccountClientError: LocalizedError {
    case unavailable
    case offline
    case busy
    case invalidAccount
    case unconfirmedResponse

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Mobile money account management is not available for this Kit Pay account."
        case .offline:
            "Connect to the internet to manage this saved account."
        case .busy:
            "Another mobile money update is still in progress."
        case .invalidAccount:
            "This saved account could not be verified. Refresh your accounts and try again."
        case .unconfirmedResponse:
            "Kit Pay could not confirm the saved account update. Refresh your accounts before trying again."
        }
    }
}

@MainActor
final class MobileMoneyViewModel: ObservableObject {
    @Published private(set) var networks: [MobileMoneyNetworkDTO] = []
    @Published private(set) var accounts: [MobileMoneyAccountDTO] = []
    @Published private(set) var operations: [MobileMoneyOperationDTO] = []
    @Published private(set) var verification: MobileMoneyVerificationDTO?
    @Published private(set) var payoutLookupState: MobileMoneyPayoutLookupState = .idle
    @Published private(set) var collectionQuote: MobileMoneyCollectionQuoteDTO?
    @Published private(set) var payoutQuote: MobileMoneyPayoutQuoteDTO?
    @Published private(set) var isLoading = false
    @Published private(set) var isSubmitting = false
    @Published private(set) var isQuoting = false
    /// The wallet debit the server refused for want of funds, so the screen can offer a top-up
    /// instead of only reporting the refusal.
    @Published var insufficientFundsDebitAmount: String?
    @Published var errorMessage: String?

    private let api: APIClient
    private var pendingKeys: [String: String] = [:]
    private var operationPollTasks: [String: Task<Void, Never>] = [:]
    private var quoteRequestID: UUID?
    private var payoutQuoteRequestID: UUID?
    private var payoutLookupGeneration = MobileMoneyLookupGeneration()

    init(api: APIClient = .shared) {
        self.api = api
#if DEBUG && APP_STORE_SCREENSHOTS
        if AppStoreScreenshotFixture.isActive {
            networks = AppStoreScreenshotFixture.mobileMoneyNetworks
            accounts = AppStoreScreenshotFixture.mobileMoneyAccounts
            operations = AppStoreScreenshotFixture.mobileMoneyOperations
        }
#endif
    }

    deinit {
        operationPollTasks.values.forEach { $0.cancel() }
    }

    func load(permitted: Bool, online: Bool) async {
#if DEBUG && APP_STORE_SCREENSHOTS
        if AppStoreScreenshotFixture.isActive {
            networks = AppStoreScreenshotFixture.mobileMoneyNetworks
            accounts = AppStoreScreenshotFixture.mobileMoneyAccounts
            operations = AppStoreScreenshotFixture.mobileMoneyOperations
            errorMessage = nil
            return
        }
#endif
        guard !isLoading else { return }
        guard permitted else {
            clear()
            errorMessage = "Mobile money is not enabled for this Kit Pay account."
            return
        }
        guard online else {
            errorMessage = "Connect to the internet to use mobile money."
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let networkResponse = try await api.mobileMoneyNetworks()
            let accountResponse = try await api.mobileMoneyAccounts()
            let operationResponse = try await api.mobileMoneyOperations()
            networks = networkResponse.items ?? []
            accounts = accountResponse.items ?? []
            operations = (operationResponse.items ?? []).sorted {
                ($0.createdAt ?? "") > ($1.createdAt ?? "")
            }
        } catch {
            errorMessage = message(for: error)
        }
    }

    func savedAccountDetails(
        for expectedAccount: MobileMoneyAccountDTO,
        permitted: Bool,
        online: Bool
    ) async throws -> MobileMoneyAccountDetailDTO {
        guard permitted else { throw MobileMoneySavedAccountClientError.unavailable }
        guard online else { throw MobileMoneySavedAccountClientError.offline }
        guard expectedAccount.isActive,
              expectedAccount.ownership != nil,
              MobileMoneySavedAccountContract.canonicalID(expectedAccount.id) != nil
        else { throw MobileMoneySavedAccountClientError.invalidAccount }

        let detail = try await api.mobileMoneyAccountDetails(id: expectedAccount.id)
        guard MobileMoneySavedAccountContract.isValidDetail(
            detail,
            expectedAccount: expectedAccount
        ) else { throw MobileMoneySavedAccountClientError.unconfirmedResponse }
        upsert(detail.account)
        merge(detail.recentOperations)
        return detail
    }

    func updateSavedAccountOwnership(
        _ ownership: MobileMoneySavedAccountOwnership,
        account expectedAccount: MobileMoneyAccountDTO,
        permitted: Bool,
        online: Bool
    ) async throws -> MobileMoneyAccountDTO {
        guard !isSubmitting else { throw MobileMoneySavedAccountClientError.busy }
        guard permitted else { throw MobileMoneySavedAccountClientError.unavailable }
        guard online else { throw MobileMoneySavedAccountClientError.offline }
        guard expectedAccount.isActive,
              expectedAccount.ownership != nil,
              MobileMoneySavedAccountContract.canonicalID(expectedAccount.id) != nil
        else { throw MobileMoneySavedAccountClientError.invalidAccount }

        let fingerprint = "saved-account-update:\(expectedAccount.id):\(ownership.rawValue)"
        let idempotencyKey = key(for: fingerprint, prefix: "ios-mobile-account-update")
        isSubmitting = true
        defer { isSubmitting = false }
        let updated = try await api.updateMobileMoneyAccountOwnership(
            id: expectedAccount.id,
            ownership: ownership,
            idempotencyKey: idempotencyKey
        )
        guard MobileMoneySavedAccountContract.isValidOwnershipUpdate(
            updated,
            expectedAccount: expectedAccount,
            ownership: ownership
        ) else { throw MobileMoneySavedAccountClientError.unconfirmedResponse }
        upsert(updated)
        pendingKeys[fingerprint] = nil
        return updated
    }

    func deleteSavedAccount(
        _ expectedAccount: MobileMoneyAccountDTO,
        permitted: Bool,
        online: Bool
    ) async throws {
        guard !isSubmitting else { throw MobileMoneySavedAccountClientError.busy }
        guard permitted else { throw MobileMoneySavedAccountClientError.unavailable }
        guard online else { throw MobileMoneySavedAccountClientError.offline }
        guard expectedAccount.isActive,
              expectedAccount.ownership != nil,
              MobileMoneySavedAccountContract.canonicalID(expectedAccount.id) != nil
        else { throw MobileMoneySavedAccountClientError.invalidAccount }

        let fingerprint = "saved-account-delete:\(expectedAccount.id)"
        let idempotencyKey = key(for: fingerprint, prefix: "ios-mobile-account-delete")
        isSubmitting = true
        defer { isSubmitting = false }
        let deletion = try await api.deleteMobileMoneyAccount(
            id: expectedAccount.id,
            idempotencyKey: idempotencyKey
        )
        guard MobileMoneySavedAccountContract.isValidDeletion(
            deletion,
            expectedAccountID: expectedAccount.id
        ) else { throw MobileMoneySavedAccountClientError.unconfirmedResponse }
        accounts.removeAll { $0.id.caseInsensitiveCompare(expectedAccount.id) == .orderedSame }
        pendingKeys[fingerprint] = nil
    }

    func verifyAndSaveAccount(
        networkCode: String,
        phoneNumber: String,
        label: String,
        kind: String,
        permitted: Bool,
        online: Bool
    ) async -> Bool {
        guard !isSubmitting else { return false }
        guard permitted, online else {
            errorMessage = permitted
                ? "Connect to the internet to verify this account."
                : "Mobile money is not enabled for this Kit Pay account."
            return false
        }

        let code = networkCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let phone = UgandaMobileMoneyPhone.apiValue(from: phoneNumber) else {
            errorMessage = "Enter a valid Uganda mobile money number beginning with 7."
            return false
        }
        let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let network = networks.first(where: { $0.code.uppercased() == code }),
              network.canVerifyAccount
        else {
            errorMessage = "Choose an available mobile money network."
            return false
        }
        guard !cleanLabel.isEmpty, cleanLabel.count <= 100,
              ["own", "third_party"].contains(kind)
        else {
            errorMessage = "Enter an account label and choose who owns the account."
            return false
        }

        let fingerprint = [code, phone, cleanLabel, kind].joined(separator: "\u{1F}")
        let verificationKey = key(for: "verify:\(fingerprint)", prefix: "ios-mobile-verify")
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        do {
            var result = try await api.createMobileMoneyVerification(
                network: code,
                phoneNumber: phone,
                idempotencyKey: verificationKey
            )
            verification = result
            var pollCount = 0
            while result.isPending, pollCount < 30 {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 1_000_000_000)
                result = try await api.mobileMoneyVerification(id: result.id)
                verification = result
                pollCount += 1
            }
            guard result.isVerified else {
                throw MobileMoneyFlowError.verificationIncomplete(
                    result.failure?.message ?? "The account is still being verified. Try again shortly."
                )
            }

            let accountKey = key(
                for: "account:\(result.id):\(kind):\(cleanLabel)",
                prefix: "ios-mobile-account"
            )
            let account = try await api.createMobileMoneyAccount(
                verificationId: result.id,
                kind: kind,
                label: cleanLabel,
                idempotencyKey: accountKey
            )
            guard account.isActive,
                  account.network.id == network.id,
                  account.kind == kind
            else { throw MobileMoneyFlowError.unconfirmedAccount }

            accounts = try await api.mobileMoneyAccounts().items ?? []
            pendingKeys["verify:\(fingerprint)"] = nil
            pendingKeys["account:\(result.id):\(kind):\(cleanLabel)"] = nil
            return true
        } catch {
            errorMessage = message(for: error)
            return false
        }
    }

    func resetPayoutLookup() {
        payoutLookupGeneration.invalidate()
        payoutLookupState = .idle
        errorMessage = nil
    }

    func selectSavedPayoutAccount(
        id accountID: String,
        ownership: MobileMoneyRecipientOwnership
    ) {
        payoutLookupGeneration.invalidate()
        clearPayoutQuote()
        guard let account = MobileMoneyPayoutSavedAccountPolicy.account(
            id: accountID,
            ownership: ownership,
            in: accounts
        )
        else {
            payoutLookupState = .idle
            errorMessage = nil
            return
        }
        payoutLookupState = .saved(ownership, account)
        errorMessage = nil
    }

    func resolvePayoutAccount(
        _ request: MobileMoneyPayoutLookupRequest,
        permitted: Bool,
        online: Bool
    ) async {
        guard permitted, online else {
            let message = permitted
                ? "Connect to the internet to verify this mobile money number."
                : "Mobile money is not enabled for this Kit Pay account."
            payoutLookupState = .failed(request, message)
            errorMessage = message
            return
        }
        guard let network = networks.first(where: {
            $0.code.caseInsensitiveCompare(request.networkCode) == .orderedSame
        }), network.canVerifyAccount, network.canPayout else {
            let message = "Choose an MTN or Airtel network that supports verified payouts."
            payoutLookupState = .failed(request, message)
            errorMessage = message
            return
        }

        let requestID = payoutLookupGeneration.begin(request)
        payoutLookupState = .verifying(request)
        errorMessage = nil
        let fingerprint = [
            request.networkCode,
            request.phoneNumber,
            request.ownership.accountKind,
        ].joined(separator: "\u{1F}")

        do {
            let verificationKey = key(
                for: "payout-verify:\(fingerprint)",
                prefix: "ios-mobile-payout-verify"
            )
            var result = try await api.createMobileMoneyVerification(
                network: request.networkCode,
                phoneNumber: request.phoneNumber,
                idempotencyKey: verificationKey
            )
            try Task.checkCancellation()
            guard payoutLookupGeneration.accepts(requestID, request: request) else { return }

            var pollCount = 0
            while result.isPending, pollCount < 30 {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                try Task.checkCancellation()
                guard payoutLookupGeneration.accepts(requestID, request: request) else { return }
                let update = try await api.mobileMoneyVerification(id: result.id)
                guard update.id == result.id else {
                    throw MobileMoneyFlowError.unconfirmedAccount
                }
                result = update
                pollCount += 1
            }
            try Task.checkCancellation()
            guard payoutLookupGeneration.accepts(requestID, request: request) else { return }
            guard result.isVerified,
                  result.network.id == network.id,
                  result.network.code.caseInsensitiveCompare(request.networkCode) == .orderedSame,
                  let verifiedName = result.verifiedAccountName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !verifiedName.isEmpty
            else {
                throw MobileMoneyFlowError.verificationIncomplete(
                    "We couldn't confirm the account name for this number. Check the details and try again."
                )
            }

            let label = String(verifiedName.prefix(100))
            let accountFingerprint = [
                result.id,
                request.ownership.accountKind,
                label,
            ].joined(separator: "\u{1F}")
            let account = try await api.createMobileMoneyAccount(
                verificationId: result.id,
                kind: request.ownership.accountKind,
                label: label,
                idempotencyKey: key(
                    for: "payout-account:\(accountFingerprint)",
                    prefix: "ios-mobile-payout-account"
                )
            )
            try Task.checkCancellation()
            guard payoutLookupGeneration.accepts(requestID, request: request) else { return }
            guard account.isActive,
                  account.network.id == network.id,
                  account.network.canPayout,
                  account.kind.caseInsensitiveCompare(request.ownership.accountKind) == .orderedSame,
                  account.accountName?.caseInsensitiveCompare(verifiedName) == .orderedSame
            else { throw MobileMoneyFlowError.unconfirmedAccount }

            accounts.removeAll { $0.id == account.id }
            accounts.append(account)
            accounts.sort { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
            pendingKeys["payout-verify:\(fingerprint)"] = nil
            pendingKeys["payout-account:\(accountFingerprint)"] = nil
            payoutLookupState = .verified(request, account)
        } catch is CancellationError {
            return
        } catch {
            guard payoutLookupGeneration.accepts(requestID, request: request) else { return }
            let message = message(for: error)
            payoutLookupState = .failed(request, message)
            errorMessage = message
        }
    }

    func loadCollectionQuote(
        accountID: String,
        enteredAmount: String,
        feeMode: MobileMoneyFeeMode,
        wallet: Wallet?,
        permitted: Bool,
        online: Bool
    ) async {
        guard !isSubmitting else { return }
        guard permitted, online else {
            clearCollectionQuote()
            errorMessage = permitted
                ? "Connect to the internet to review the transaction fee."
                : "Mobile money is not enabled for this Kit Pay account."
            return
        }
        guard let wallet,
              let account = accounts.first(where: {
                  $0.id.caseInsensitiveCompare(accountID) == .orderedSame
              }),
              MobileMoneySavedAccountActionPolicy.canCollect(from: account),
              wallet.currency == account.network.currency,
              let amount = MobileMoneyAmount.roundedCollectionAPIAmount(
                  enteredAmount,
                  scale: account.network.currency.decimalScale
              )
        else {
            clearCollectionQuote()
            return
        }

        if let current = collectionQuote,
           !current.isExpired,
           current.walletId == wallet.id,
           current.accountId == account.id,
           current.requestedAmount == amount,
           current.feeMode == feeMode {
            return
        }

        let requestID = UUID()
        quoteRequestID = requestID
        collectionQuote = nil
        isQuoting = true
        errorMessage = nil
        defer {
            if quoteRequestID == requestID { isQuoting = false }
        }

        do {
            let quote = try await api.createMobileMoneyCollectionQuote(
                walletId: wallet.id,
                accountId: account.id,
                amount: amount,
                feeMode: feeMode
            )
            try validate(
                quote,
                wallet: wallet,
                account: account,
                amount: amount,
                feeMode: feeMode
            )
            guard quoteRequestID == requestID, !Task.isCancelled else { return }
            collectionQuote = quote
        } catch is CancellationError {
            return
        } catch {
            guard quoteRequestID == requestID, !Task.isCancelled else { return }
            collectionQuote = nil
            errorMessage = message(for: error)
        }
    }

    func clearCollectionQuote() {
        quoteRequestID = nil
        collectionQuote = nil
        isQuoting = false
    }

    func loadPayoutQuote(
        ownership: MobileMoneyRecipientOwnership,
        accountID: String,
        enteredAmount: String,
        feeMode: MobileMoneyPayoutFeeMode,
        wallet: Wallet?,
        permitted: Bool,
        online: Bool
    ) async {
        guard !isSubmitting else { return }
        guard permitted, online else {
            clearPayoutQuote()
            errorMessage = permitted
                ? "Connect to the internet to review the transaction fee."
                : "Mobile money is not enabled for this Kit Pay account."
            return
        }
        guard let wallet,
              let verifiedAccount = payoutLookupState.account(for: ownership),
              verifiedAccount.id.caseInsensitiveCompare(accountID) == .orderedSame,
              let account = accounts.first(where: { $0.id == accountID }),
              account.hasSamePayoutIdentity(as: verifiedAccount),
              account.isPayoutCapable,
              account.hasConfirmedPayoutIdentity,
              account.hasPreferredPayoutOwnership(ownership),
              wallet.currency == account.network.currency,
              let amount = MobileMoneyAmount.wholeUnitAPIAmount(
                  enteredAmount,
                  scale: account.network.currency.decimalScale
              )
        else {
            clearPayoutQuote()
            return
        }

        if let current = payoutQuote,
           !current.isExpired,
           current.walletId == wallet.id,
           current.accountId == account.id,
           MobileMoneyAmount.amountsMatch(current.enteredAmount, amount),
           current.feeMode == feeMode {
            return
        }

        let requestID = UUID()
        payoutQuoteRequestID = requestID
        payoutQuote = nil
        isQuoting = true
        errorMessage = nil
        defer {
            if payoutQuoteRequestID == requestID { isQuoting = false }
        }

        do {
            let quote = try await api.createMobileMoneyPayoutQuote(
                walletId: wallet.id,
                accountId: account.id,
                amount: amount,
                feeMode: feeMode
            )
            try validate(
                quote,
                wallet: wallet,
                account: account,
                amount: amount,
                feeMode: feeMode
            )
            guard payoutQuoteRequestID == requestID, !Task.isCancelled else { return }
            guard let currentAccount = payoutLookupState.account(for: ownership),
                  currentAccount.hasSamePayoutIdentity(as: account)
            else { throw MobileMoneyFlowError.unconfirmedAccount }
            payoutQuote = quote
        } catch is CancellationError {
            return
        } catch {
            guard payoutQuoteRequestID == requestID, !Task.isCancelled else { return }
            payoutQuote = nil
            errorMessage = message(for: error)
        }
    }

    func clearPayoutQuote() {
        payoutQuoteRequestID = nil
        payoutQuote = nil
        isQuoting = false
    }

    func submitQuotedCollection(
        quote: MobileMoneyCollectionQuoteDTO,
        pin: String,
        wallet: Wallet?,
        permitted: Bool,
        online: Bool,
        authorization: KitFinancialStepUpAuthorization
    ) async -> Bool {
        guard !isSubmitting else { return false }
        guard permitted, online else {
            errorMessage = permitted
                ? "Connect to the internet to submit this mobile money request."
                : "Mobile money is not enabled for this Kit Pay account."
            return false
        }
        guard let wallet,
              let account = accounts.first(where: { $0.id == quote.accountId })
        else {
            errorMessage = "Review the mobile money account and transaction fee again."
            return false
        }

        do {
            try validate(
                quote,
                wallet: wallet,
                account: account,
                amount: quote.requestedAmount,
                feeMode: quote.feeMode
            )
        } catch {
            errorMessage = message(for: error)
            return false
        }

        let fingerprint = "collection-quote:\(quote.id)"
        let idempotencyKey = key(for: fingerprint, prefix: "ios-mobile-collection")
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        do {
            let requested = KitMoney.formatted(
                quote.providerAmount, currency: quote.currency, trimZeroFraction: true)
            let credited = KitMoney.formatted(
                quote.walletCredit, currency: quote.currency, trimZeroFraction: true)
            let approvalReason = "Approve a \(requested) mobile money request; "
                + "\(credited) will reach your Kit Pay wallet"
            let verification = try await authorization(
                quote.stepUp.purpose,
                quote.stepUp.authorizationIntent,
                pin,
                approvalReason
            )
            guard !verification.stepUpToken.isEmpty else {
                throw MobileMoneyFlowError.invalidStepUp
            }

            let operation = try await api.createQuotedMobileMoneyCollection(
                quoteId: quote.id,
                idempotencyKey: idempotencyKey,
                stepUpToken: verification.stepUpToken
            )
            guard operation.mobileMoneyType == MobileMoneyAction.collection.rawValue,
                  operation.walletId == quote.walletId,
                  MobileMoneyAmount.amountsMatch(operation.amount, quote.providerAmount),
                  operation.currency == quote.currency,
                  operation.feeQuoteId == quote.id,
                  operation.feeMode == quote.feeMode,
                  let netAmount = operation.netAmount,
                  MobileMoneyAmount.amountsMatch(netAmount, quote.walletCredit)
            else { throw MobileMoneyFlowError.unconfirmedOperation }

            upsert(operation)
            pendingKeys[fingerprint] = nil
            clearCollectionQuote()
            pollOperation(operation.id)
            return true
        } catch {
            errorMessage = message(for: error, confirmedCollectionFailure: true)
            return false
        }
    }

    func submitQuotedPayout(
        quote: MobileMoneyPayoutQuoteDTO,
        ownership: MobileMoneyRecipientOwnership,
        accountID: String,
        pin: String,
        wallet: Wallet?,
        permitted: Bool,
        online: Bool,
        authorization: KitFinancialStepUpAuthorization
    ) async -> Bool {
        guard !isSubmitting else { return false }
        guard permitted, online else {
            errorMessage = permitted
                ? "Connect to the internet to submit this mobile money request."
                : "Mobile money is not enabled for this Kit Pay account."
            return false
        }
        guard let wallet else {
            errorMessage = "Choose an active Kit Pay wallet."
            return false
        }
        guard let account = accounts.first(where: {
            $0.id.caseInsensitiveCompare(accountID) == .orderedSame
        }), account.isActive else {
            errorMessage = "Choose a saved mobile money account."
            return false
        }
        guard let verifiedAccount = payoutLookupState.account(for: ownership),
              verifiedAccount.hasSamePayoutIdentity(as: account),
              account.isPayoutCapable,
              account.hasConfirmedPayoutIdentity,
              account.hasPreferredPayoutOwnership(ownership)
        else {
            errorMessage = ownership == .someoneElse
                ? "Verify the recipient's name on an MTN or Airtel number before sending."
                : "Verify your MTN or Airtel number before withdrawing."
            return false
        }
        do {
            try validate(
                quote,
                wallet: wallet,
                account: account,
                amount: quote.enteredAmount,
                feeMode: quote.feeMode
            )
        } catch {
            errorMessage = message(for: error)
            return false
        }

        let fingerprint = "payout-quote:\(quote.id)"
        let idempotencyKey = key(for: fingerprint, prefix: "ios-mobile-payout")

        isSubmitting = true
        errorMessage = nil
        insufficientFundsDebitAmount = nil
        defer { isSubmitting = false }
        do {
            let received = KitMoney.formatted(
                quote.recipientAmount, currency: quote.currency, trimZeroFraction: true)
            let debit = KitMoney.formatted(
                quote.customerDebit, currency: quote.currency, trimZeroFraction: true)
            let approvalReason: String
            if ownership == .myself {
                approvalReason = "Approve a withdrawal to \(account.network.name) "
                    + "\(account.phoneNumberMasked); \(received) will be received "
                    + "and your Kit Pay wallet debit is \(debit)"
            } else {
                let recipient = account.accountName ?? account.label
                approvalReason = "Approve sending to \(recipient) on \(account.network.name); "
                    + "they receive \(received) and your Kit Pay wallet debit is \(debit)"
            }
            let verification = try await authorization(
                quote.stepUp.purpose,
                quote.stepUp.authorizationIntent,
                pin,
                approvalReason
            )
            guard !verification.stepUpToken.isEmpty else {
                throw MobileMoneyFlowError.invalidStepUp
            }
            guard let currentAccount = payoutLookupState.account(for: ownership),
                  currentAccount.hasSamePayoutIdentity(as: account)
            else { throw MobileMoneyFlowError.unconfirmedAccount }

            let operation = try await api.createQuotedMobileMoneyPayout(
                quoteId: quote.id,
                idempotencyKey: idempotencyKey,
                stepUpToken: verification.stepUpToken
            )
            guard operation.mobileMoneyType == MobileMoneyAction.payout.rawValue,
                  operation.outboundQuoteId == quote.id,
                  operation.walletId == quote.walletId,
                  operation.beneficiaryId == account.id,
                  operation.network.id == account.network.id,
                  MobileMoneyAmount.amountsMatch(operation.amount, quote.recipientAmount),
                  operation.currency == quote.currency,
                  operation.outboundPricing?.matches(quote) == true
            else { throw MobileMoneyFlowError.unconfirmedOperation }

            upsert(operation)
            pendingKeys[fingerprint] = nil
            clearPayoutQuote()
            pollOperation(operation.id)
            return true
        } catch {
            if WalletTopUpPolicy.isInsufficientFunds(error) {
                insufficientFundsDebitAmount = quote.customerDebit
            }
            errorMessage = message(for: error)
            return false
        }
    }

    private func pollOperation(_ id: String) {
        operationPollTasks[id]?.cancel()
        operationPollTasks[id] = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<40 {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }
                guard let operation = try? await api.mobileMoneyOperation(id: id) else { continue }
                upsert(operation)
                if operation.isTerminal {
                    operationPollTasks[id] = nil
                    return
                }
            }
            operationPollTasks[id] = nil
        }
    }

    private func upsert(_ operation: MobileMoneyOperationDTO) {
        operations.removeAll { $0.id == operation.id }
        operations.insert(operation, at: 0)
    }

    private func upsert(_ account: MobileMoneyAccountDTO) {
        accounts.removeAll { $0.id.caseInsensitiveCompare(account.id) == .orderedSame }
        accounts.append(account)
        accounts.sort { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    private func merge(_ recentOperations: [MobileMoneyOperationDTO]) {
        let incomingIDs = Set(recentOperations.map(\.id))
        operations.removeAll { incomingIDs.contains($0.id) }
        operations.append(contentsOf: recentOperations)
        operations.sort { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
    }

    private func key(for fingerprint: String, prefix: String) -> String {
        if let existing = pendingKeys[fingerprint] { return existing }
        let generated = "\(prefix)-\(UUID().uuidString.lowercased())"
        pendingKeys[fingerprint] = generated
        return generated
    }

    private func clear() {
        networks = []
        accounts = []
        operations = []
        verification = nil
        resetPayoutLookup()
        clearCollectionQuote()
        clearPayoutQuote()
    }

    private func validate(
        _ quote: MobileMoneyCollectionQuoteDTO,
        wallet: Wallet,
        account: MobileMoneyAccountDTO,
        amount: String,
        feeMode: MobileMoneyFeeMode
    ) throws {
        let intent = quote.stepUp.intent
        guard !quote.isExpired else { throw MobileMoneyFlowError.quoteExpired }
        guard quote.action == MobileMoneyAction.collection.rawValue,
              MobileMoneySavedAccountActionPolicy.canCollect(from: account),
              quote.feeMode == feeMode,
              quote.walletId == wallet.id,
              quote.accountId == account.id,
              quote.network.caseInsensitiveCompare(account.network.code) == .orderedSame,
              MobileMoneyAmount.amountsMatch(quote.requestedAmount, amount),
              quote.currency == wallet.currency,
              quote.stepUp.purpose == MobileMoneyAction.collection.purpose,
              intent["action"] == MobileMoneyAction.collection.rawValue,
              intent["quote_id"] == quote.id,
              intent["wallet_id"] == quote.walletId,
              intent["mobile_money_account_id"] == quote.accountId,
              intent["network"] == quote.network,
              intent["fee_mode"] == quote.feeMode.rawValue,
              intent["requested_amount"] == quote.requestedAmount,
              intent["provider_amount"] == quote.providerAmount,
              intent["provider_fee"] == quote.providerFee,
              intent["platform_fee"] == quote.platformFee,
              intent["rounding_adjustment"] == quote.roundingAdjustment,
              intent["total_fees"] == quote.totalFees,
              intent["wallet_credit"] == quote.walletCredit,
              intent["currency"] == quote.currency.code
        else { throw MobileMoneyFlowError.quoteMismatch }
    }

    private func validate(
        _ quote: MobileMoneyPayoutQuoteDTO,
        wallet: Wallet,
        account: MobileMoneyAccountDTO,
        amount: String,
        feeMode: MobileMoneyPayoutFeeMode
    ) throws {
        let intent = quote.stepUp.intent
        guard !quote.isExpired else { throw MobileMoneyFlowError.quoteExpired }
        guard quote.action == MobileMoneyAction.payout.rawValue,
              quote.scheduleVerified,
              !quote.scheduleVersion.isEmpty,
              quote.hasConsistentAmounts,
              account.isPayoutCapable,
              quote.feeMode == feeMode,
              quote.walletId == wallet.id,
              quote.accountId == account.id,
              quote.network.caseInsensitiveCompare(account.network.code) == .orderedSame,
              MobileMoneyAmount.amountsMatch(quote.enteredAmount, amount),
              quote.currency == wallet.currency,
              quote.stepUp.purpose == MobileMoneyAction.payout.purpose,
              intent["action"] == MobileMoneyAction.payout.rawValue,
              intent["quote_id"] == quote.id,
              intent["wallet_id"] == quote.walletId,
              intent["mobile_money_account_id"] == quote.accountId,
              intent["network"] == quote.network,
              intent["fee_mode"] == quote.feeMode.rawValue,
              intent["recipient_amount"] == quote.recipientAmount,
              intent["processing_fee"] == quote.processingFee,
              intent["provider_fee"] == quote.providerFee,
              intent["kit_fee"] == quote.kitFee,
              intent["provider_fee_cap"] == quote.providerFeeCap,
              intent["maximum_provider_total"] == quote.maximumProviderTotal,
              intent["customer_debit"] == quote.customerDebit,
              intent["kit_debit"] == quote.kitDebit,
              intent["schedule_version"] == quote.scheduleVersion,
              intent["currency"] == quote.currency.code
        else { throw MobileMoneyFlowError.quoteMismatch }
    }

    private func message(
        for error: Error,
        confirmedCollectionFailure: Bool = false
    ) -> String {
        if confirmedCollectionFailure,
           let payload = error as? APIErrorPayload,
           let message = CustomerFacingPaymentCopy
               .confirmedMobileMoneyCollectionFailureMessage(for: payload.code) {
            return message
        }
        let message = (error as? APIErrorPayload)?.message ?? error.localizedDescription
        return CustomerFacingPaymentCopy.neutralizedServiceMessage(message)
    }
}

private enum MobileMoneyFlowError: LocalizedError {
    case invalidStepUp
    case unconfirmedAccount
    case unconfirmedOperation
    case quoteExpired
    case quoteMismatch
    case verificationIncomplete(String)

    var errorDescription: String? {
        switch self {
        case .invalidStepUp:
            "We couldn't approve this mobile money request. Review it and try again."
        case .unconfirmedAccount:
            "We couldn't confirm this mobile money account. Refresh and try again."
        case .unconfirmedOperation:
            "This mobile money request is still being confirmed. Check recent activity before retrying."
        case .quoteExpired:
            "This review expired. Check the latest transaction fee and total before approving."
        case .quoteMismatch:
            "The transaction fee or total changed. Review the latest amounts and try again."
        case .verificationIncomplete(let message):
            message
        }
    }
}

struct MobileMoneyView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = MobileMoneyViewModel()
    @State private var addingAccount = false
    @State private var flow: MobileMoneyFlow?
    @State private var selectedTransaction: WalletTransaction?
    /// Built once per directory change: the rows below would otherwise rescan every synced contact
    /// on each redraw.
    @State private var contactIndex = BeneficiaryContactIndex()

    private var permitted: Bool { app.capabilities?.enablesMobileMoney == true }
    private var supportsPayouts: Bool { model.networks.supportsMobileMoneyPayouts }
    private var savedMobileMoneyAccounts: [MobileMoneyAccountDTO] {
        MobileMoneySavedAccountRailPolicy.mobileMoneyAccounts(model.accounts)
    }

    var body: some View {
        NavigationStack {
            MoneyAccessBoundary {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        intro
                        actions
                        accountsSection
                        operationsSection
                    }
                    .padding(20)
                    .padding(.bottom, 24)
                }
                .background(KitColor.canvas.ignoresSafeArea())
                .navigationTitle("Mobile money")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Task { await model.load(permitted: permitted, online: app.isOnline) }
                        } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(model.isLoading || model.isSubmitting)
                    }
                }
                .task(id: "\(permitted)-\(app.isOnline)-\(app.financialDataAccessGranted)") {
                    guard app.financialDataAccessGranted else { return }
                    await model.load(permitted: permitted, online: app.isOnline)
                }
                .onAppear { contactIndex = BeneficiaryContactIndex(contacts: app.contactDirectory) }
                .onChange(of: app.contactDirectory) { _, contacts in
                    contactIndex = BeneficiaryContactIndex(contacts: contacts)
                }
                .refreshable {
                    guard app.financialDataAccessGranted else { return }
                    await model.load(permitted: permitted, online: app.isOnline)
                }
                .sheet(isPresented: $addingAccount) {
                    AddMobileMoneyAccountView(
                        model: model,
                        permitted: permitted,
                        online: app.isOnline
                    )
                    .presentationBackground(.ultraThinMaterial)
                }
                .sheet(item: $flow) { flow in
                    MobileMoneyOperationView(
                        model: model,
                        flow: flow,
                        wallet: app.selectedWallet,
                        permitted: permitted,
                        online: app.isOnline
                    ) {
                        await app.refresh()
                    }
                    .environmentObject(app)
                    .presentationBackground(.ultraThinMaterial)
                }
                .sheet(item: $selectedTransaction) { transaction in
                    WalletFlowContainer(destination: .transaction(transaction))
                        .environmentObject(app)
                        .presentationBackground(.ultraThinMaterial)
                }
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("MTN & Airtel", systemImage: "iphone.gen3.radiowaves.left.and.right")
                .font(.title2.bold())
                .foregroundStyle(KitColor.primaryText)
            Text(
                supportsPayouts
                    ? "Collect from a verified MTN or Airtel account, send to a verified recipient, or withdraw to your own verified number. Requests stay visible until their final status arrives."
                    : "Add money to Kit Pay from a verified MTN or Airtel mobile money account. Requests stay visible until their final status arrives."
            )
                .font(.subheadline)
                .foregroundStyle(KitColor.secondaryText)
            if let error = model.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red).padding(.top, 4)
            }
        }
        .padding(18)
        .kitGlass(cornerRadius: 24, tint: KitColor.paleGreen)
    }

    private var actions: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: supportsPayouts ? 3 : 1),
            spacing: 10
        ) {
            actionCard(.addMoney)
            if supportsPayouts {
                actionCard(.send)
                actionCard(.withdraw)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func actionCard(_ flow: MobileMoneyFlow) -> some View {
        Button {
            guard permitted, app.isOnline else {
                model.errorMessage = permitted
                    ? "Connect to the internet to use mobile money."
                    : "Mobile money is not enabled for this Kit Pay account."
                return
            }
            self.flow = flow
        } label: {
            VStack(spacing: 9) {
                Image(systemName: flow.systemImage)
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(KitColor.green.gradient, in: Circle())
                Text(flow.title)
                    .font(.subheadline.bold())
                    .foregroundStyle(KitColor.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Text(flow.subtitle)
                    .font(.caption2)
                    .foregroundStyle(KitColor.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .kitGlass(cornerRadius: 22)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Saved accounts").font(.title3.bold()).foregroundStyle(KitColor.primaryText)
                Spacer()
                Button("Add") { addingAccount = true }
                    .font(.subheadline.bold()).foregroundStyle(KitColor.green)
                    .disabled(!permitted || !app.isOnline || model.isSubmitting)
            }
            if model.isLoading && savedMobileMoneyAccounts.isEmpty {
                ProgressView("Loading mobile money…").frame(maxWidth: .infinity).padding(20)
            } else if savedMobileMoneyAccounts.isEmpty {
                ContentUnavailableView(
                    "No saved account",
                    systemImage: "plus.circle",
                    description: Text(
                        supportsPayouts
                            ? "Verify your MTN or Airtel number to add or withdraw money. Saved verified beneficiaries can be used to collect or send money."
                            : "Verify an MTN or Airtel number before cashing in."
                    )
                )
                .frame(maxWidth: .infinity).padding(16).kitGlass(cornerRadius: 22)
            } else {
                ForEach(savedMobileMoneyAccounts) { account in
                    NavigationLink {
                        MobileMoneySavedAccountDetailView(
                            model: model,
                            account: account,
                            cachedOperations: model.operations,
                            permitted: permitted
                        )
                    } label: {
                        HStack(spacing: 13) {
                            savedAccountAvatar(account)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.label).font(.headline).foregroundStyle(KitColor.primaryText)
                                Text("\(account.network.name) • \(account.phoneNumberMasked)")
                                    .font(.caption).foregroundStyle(KitColor.secondaryText)
                                Text(account.accountName ?? "Verified account")
                                    .font(.caption2).foregroundStyle(KitColor.secondaryText)
                            }
                            Spacer()
                            Text(account.ownership?.title ?? "Review")
                                .font(.caption2.bold())
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .background(KitColor.paleGreen, in: Capsule())
                            Image(systemName: "chevron.right")
                                .font(.caption.bold())
                                .foregroundStyle(.tertiary)
                        }
                        .padding(14).kitGlass(cornerRadius: 20, shadow: false)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// A saved mobile-money number is a phone number, so when it belongs to someone who is already
    /// on Kit Pay the row shows their photo. The network and masked number below it are unchanged.
    @ViewBuilder
    private func savedAccountAvatar(_ account: MobileMoneyAccountDTO) -> some View {
        if let contact = contactIndex.contact(
            forMaskedPhone: account.phoneNumberMasked,
            accountName: account.accountName ?? account.label
        ) {
            RemoteAvatarView(
                name: contact.name,
                avatarURL: contact.avatarURL,
                size: 44,
                ringOpacity: nil,
                verification: contact.verification?.designation
            )
        } else {
            Image(systemName: "iphone.gen3")
                .foregroundStyle(KitColor.primaryText)
                .frame(width: 44, height: 44)
                .background(KitColor.paleGreen, in: Circle())
        }
    }

    private var operationsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent mobile money").font(.title3.bold()).foregroundStyle(KitColor.primaryText)
            if model.operations.isEmpty {
                Text(
                    supportsPayouts
                        ? "Collections and payouts will appear here while they are processed."
                        : "Collections will appear here while they are processed."
                )
                    .font(.subheadline).foregroundStyle(KitColor.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18).kitGlass(cornerRadius: 20)
            } else {
                ForEach(model.operations) { operation in
                    let confirmedFailure = operation.confirmedCollectionFailureMessage
                    Button {
                        selectedTransaction = MobileMoneyTransactionPresentation.transaction(
                            for: operation,
                            accounts: model.accounts,
                            walletTransactions: app.state.transactions
                        )
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: operation.mobileMoneyType == "collection" ? "arrow.down.left" : "arrow.up.right")
                                .foregroundStyle(KitColor.primaryText)
                                .frame(width: 42, height: 42)
                                .background(.thinMaterial, in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(operationTitle(operation))
                                    .font(.headline).foregroundStyle(KitColor.primaryText)
                                Text(confirmedFailure ?? operation.failure.flatMap { $0.message }.map {
                                    CustomerFacingPaymentCopy.neutralizedServiceMessage($0)
                                } ?? operation.reference)
                                    .font(.caption).foregroundStyle(operation.isTerminal && !operation.isSuccessful ? .red : KitColor.secondaryText)
                                    .lineLimit(confirmedFailure == nil ? 1 : nil)
                                    .fixedSize(horizontal: false, vertical: confirmedFailure != nil)
                                if confirmedFailure != nil {
                                    Text("Reference \(operation.reference)")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(KitColor.secondaryText)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)
                                }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(KitMoney.formatted(operation.amount, currency: operation.currency)).font(.subheadline.bold())
                                Text(operation.isSuccessful ? "Completed" : operation.isTerminal ? "Failed" : "Processing")
                                    .font(.caption2.bold())
                                    .foregroundStyle(operation.isSuccessful ? KitColor.green : operation.isTerminal ? .red : .orange)
                            }
                        }
                        .padding(14).kitGlass(cornerRadius: 20, shadow: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens transaction details")
                }
            }
        }
    }

    private func operationTitle(_ operation: MobileMoneyOperationDTO) -> String {
        guard operation.mobileMoneyType == MobileMoneyAction.payout.rawValue else {
            return "Money added"
        }
        guard let accountID = operation.beneficiaryId,
              let account = model.accounts.first(where: { $0.id == accountID })
        else { return "Sent to mobile money" }
        return account.isOwnAccount ? "Withdrawal" : "Sent to mobile money"
    }
}

private struct MobileMoneySavedAccountDetailView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: MobileMoneyViewModel
    let permitted: Bool

    @State private var account: MobileMoneyAccountDTO
    @State private var recentOperations: [MobileMoneyOperationDTO]
    @State private var selectedOwnership: MobileMoneySavedAccountOwnership
    @State private var isRefreshing = false
    @State private var hasConfirmedLatestDetails = false
    @State private var isSavingOwnership = false
    @State private var isDeleting = false
    @State private var showsOwnershipEditor = false
    @State private var showsDeleteConfirmation = false
    @State private var refreshError: String?
    @State private var actionError: String?
    @State private var requestedFlow: MobileMoneyFlow?
    @State private var selectedTransaction: WalletTransaction?

    init(
        model: MobileMoneyViewModel,
        account: MobileMoneyAccountDTO,
        cachedOperations: [MobileMoneyOperationDTO],
        permitted: Bool
    ) {
        self.model = model
        self.permitted = permitted
        _account = State(initialValue: account)
        _recentOperations = State(initialValue: MobileMoneySavedAccountActivity.recentOperations(
            for: account.id,
            from: cachedOperations
        ))
        _selectedOwnership = State(initialValue: account.ownership ?? .beneficiary)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 18) {
                accountHeader
                if let actionError {
                    inlineError(actionError)
                }
                if !app.isOnline {
                    Label(
                        "Showing saved details. Connect to update or delete this account.",
                        systemImage: "wifi.slash"
                    )
                    .font(.footnote)
                    .foregroundStyle(KitColor.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
                accountDetails
                recentActivity
                accountManagement
            }
            .padding(20)
            .padding(.bottom, 30)
        }
        .background(KitColor.canvas.ignoresSafeArea())
        .navigationTitle("Account details")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(account.id)-\(permitted)-\(app.isOnline)") {
            await refreshFromServer()
        }
        .refreshable {
            await refreshFromServer()
        }
        .sheet(isPresented: $showsOwnershipEditor) {
            ownershipEditor
                .presentationDetents([.medium])
                .presentationBackground(.ultraThinMaterial)
        }
        .sheet(item: $requestedFlow) { flow in
            MobileMoneyOperationView(
                model: model,
                flow: flow,
                wallet: app.selectedWallet,
                permitted: permitted,
                online: app.isOnline,
                initialAccountID: account.id
            ) {
                await app.refresh()
                await refreshFromServer()
            }
            .environmentObject(app)
            .presentationBackground(.ultraThinMaterial)
        }
        .sheet(item: $selectedTransaction) { transaction in
            WalletFlowContainer(destination: .transaction(transaction))
                .environmentObject(app)
                .presentationBackground(.ultraThinMaterial)
        }
        .confirmationDialog(
            "Delete this saved account?",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete saved account", role: .destructive) {
                Task { await deleteAccount() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The account will no longer be available for mobile money. Its completed transaction history will remain in your activity.")
        }
    }

    private var accountHeader: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 88, height: 88)
                Circle()
                    .stroke(.white.opacity(0.42), lineWidth: 1)
                    .frame(width: 88, height: 88)
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(KitColor.green)
            }
            Text(account.label)
                .font(.title2.bold())
                .foregroundStyle(KitColor.primaryText)
                .multilineTextAlignment(.center)
            Text(account.accountName ?? "Verified mobile money account")
                .font(.subheadline)
                .foregroundStyle(KitColor.secondaryText)
                .multilineTextAlignment(.center)
            Text(account.ownership?.title ?? "Needs review")
                .font(.caption.bold())
                .foregroundStyle(KitColor.primaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(KitColor.paleGreen, in: Capsule())
            HStack(spacing: 10) {
                Button {
                    requestedFlow = .addMoney
                } label: {
                    Label("Collect Money", systemImage: "arrow.down.left")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(KitSecondaryButtonStyle())
                .disabled(!canCollectFromAccount)

                Button {
                    requestedFlow = payoutFlow
                } label: {
                    Label("Send Money", systemImage: "arrow.up.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(KitSecondaryButtonStyle())
                .disabled(payoutFlow == nil || !canTransact)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 18)
        .kitGlass(cornerRadius: 28, tint: KitColor.paleGreen.opacity(0.35))
    }

    private var accountDetails: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Account")
                .font(.title3.bold())
                .foregroundStyle(KitColor.primaryText)
                .padding(.bottom, 12)
            detailRow("Network", account.network.name)
            Divider()
            detailRow("Mobile number", account.phoneNumberMasked)
            Divider()
            detailRow("Account name", account.accountName ?? "Verified account")
            Divider()
            detailRow("Ownership", account.ownership?.title ?? "Needs review")
            Divider()
            detailRow("Status", account.isActive ? "Verified" : "Unavailable")
        }
        .padding(18)
        .kitGlass(cornerRadius: 24, shadow: false)
    }

    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent transactions")
                    .font(.title3.bold())
                    .foregroundStyle(KitColor.primaryText)
                Spacer()
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let refreshError {
                inlineError(refreshError)
            }

            if recentOperations.isEmpty && !isRefreshing {
                ContentUnavailableView(
                    "No recent transactions",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Transactions linked to this saved account will appear here.")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .kitGlass(cornerRadius: 22, shadow: false)
            } else {
                ForEach(recentOperations) { operation in
                    Button {
                        selectedTransaction = MobileMoneyTransactionPresentation.transaction(
                            for: operation,
                            accounts: model.accounts,
                            walletTransactions: app.state.transactions
                        )
                    } label: {
                        activityRow(operation)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens transaction details")
                }
            }
        }
    }

    private var accountManagement: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Manage account")
                .font(.title3.bold())
                .foregroundStyle(KitColor.primaryText)
            Button {
                selectedOwnership = account.ownership ?? .beneficiary
                actionError = nil
                showsOwnershipEditor = true
            } label: {
                managementRow(
                    title: "Edit ownership",
                    subtitle: "Choose Mine or Beneficiary",
                    icon: "person.crop.circle.badge.checkmark"
                )
            }
            .buttonStyle(.plain)
            .disabled(!canManage || model.isSubmitting)

            Button(role: .destructive) {
                actionError = nil
                showsDeleteConfirmation = true
            } label: {
                managementRow(
                    title: "Delete saved account",
                    subtitle: "Remove it from mobile money",
                    icon: "trash",
                    destructive: true
                )
            }
            .buttonStyle(.plain)
            .disabled(!canManage || model.isSubmitting || isDeleting)
        }
    }

    private var ownershipEditor: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Ownership", selection: $selectedOwnership) {
                        ForEach(MobileMoneySavedAccountOwnership.allCases) { ownership in
                            Text(ownership.title).tag(ownership)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Ownership")
                } footer: {
                    Text(selectedOwnership == .mine
                         ? "Choose Mine for a mobile money account that belongs to you."
                         : "Choose Beneficiary for an account that belongs to someone else.")
                }

                if let actionError {
                    Section {
                        Label(actionError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Edit ownership")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showsOwnershipEditor = false }
                        .disabled(isSavingOwnership)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await saveOwnership() }
                    } label: {
                        if isSavingOwnership {
                            ProgressView()
                        } else {
                            Text("Save")
                        }
                    }
                    .disabled(
                        isSavingOwnership
                            || selectedOwnership == account.ownership
                            || !canManage
                    )
                }
            }
            .interactiveDismissDisabled(isSavingOwnership)
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(KitColor.secondaryText)
            Spacer(minLength: 12)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(KitColor.primaryText)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.vertical, 11)
    }

    private func activityRow(_ operation: MobileMoneyOperationDTO) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: operation.mobileMoneyType == MobileMoneyAction.collection.rawValue
                  ? "arrow.down.left"
                  : "arrow.up.right")
                .font(.headline)
                .foregroundStyle(operation.isSuccessful ? KitColor.green : KitColor.primaryText)
                .frame(width: 42, height: 42)
                .background(.thinMaterial, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(activityTitle(operation))
                    .font(.headline)
                    .foregroundStyle(KitColor.primaryText)
                Text(activityDate(operation))
                    .font(.caption)
                    .foregroundStyle(KitColor.secondaryText)
                if let fee = operation.customerTransactionFee {
                    Text("Transaction fee \(displayAmount(fee, currency: operation.currency))")
                        .font(.caption2)
                        .foregroundStyle(KitColor.secondaryText)
                }
                Text("Reference \(operation.reference)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(KitColor.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(displayAmount(operation.amount, currency: operation.currency))
                    .font(.subheadline.bold())
                    .foregroundStyle(KitColor.primaryText)
                    .monospacedDigit()
                Text(activityStatus(operation))
                    .font(.caption2.bold())
                    .foregroundStyle(activityStatusColor(operation))
            }
        }
        .padding(14)
        .kitGlass(cornerRadius: 20, shadow: false)
    }

    private func managementRow(
        title: String,
        subtitle: String,
        icon: String,
        destructive: Bool = false
    ) -> some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(destructive ? .red : KitColor.primaryText)
                .frame(width: 44, height: 44)
                .background(.thinMaterial, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(destructive ? .red : KitColor.primaryText)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(KitColor.secondaryText)
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

    private func inlineError(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    private func refreshFromServer() async {
        guard permitted, app.isOnline, !isRefreshing else { return }
        isRefreshing = true
        hasConfirmedLatestDetails = false
        refreshError = nil
        defer { isRefreshing = false }
        do {
            let detail = try await model.savedAccountDetails(
                for: account,
                permitted: permitted,
                online: app.isOnline
            )
            account = detail.account
            selectedOwnership = detail.account.ownership ?? selectedOwnership
            recentOperations = detail.recentOperations
            hasConfirmedLatestDetails = true
        } catch is CancellationError {
            return
        } catch {
            refreshError = customerMessage(for: error)
        }
    }

    private func saveOwnership() async {
        guard !isSavingOwnership else { return }
        isSavingOwnership = true
        actionError = nil
        defer { isSavingOwnership = false }
        do {
            account = try await model.updateSavedAccountOwnership(
                selectedOwnership,
                account: account,
                permitted: permitted,
                online: app.isOnline
            )
            hasConfirmedLatestDetails = true
            showsOwnershipEditor = false
        } catch {
            actionError = customerMessage(for: error)
        }
    }

    private func deleteAccount() async {
        guard !isDeleting else { return }
        isDeleting = true
        actionError = nil
        defer { isDeleting = false }
        do {
            try await model.deleteSavedAccount(
                account,
                permitted: permitted,
                online: app.isOnline
            )
            dismiss()
        } catch {
            actionError = customerMessage(for: error)
        }
    }

    private var canManage: Bool {
        permitted
            && app.isOnline
            && account.isActive
            && account.ownership != nil
            && MobileMoneySavedAccountContract.canonicalID(account.id) != nil
    }

    private var canTransact: Bool {
        permitted
            && app.isOnline
            && account.isActive
            && hasConfirmedLatestDetails
            && !model.isSubmitting
    }

    private var canCollectFromAccount: Bool {
        canTransact && MobileMoneySavedAccountActionPolicy.canCollect(from: account)
    }

    private var payoutFlow: MobileMoneyFlow? {
        guard canTransact else { return nil }
        return MobileMoneySavedAccountActionPolicy.payoutFlow(for: account)
    }

    private func activityTitle(_ operation: MobileMoneyOperationDTO) -> String {
        guard operation.mobileMoneyType == MobileMoneyAction.payout.rawValue else {
            return "Money added"
        }
        return account.isOwnAccount ? "Withdrawal" : "Sent to mobile money"
    }

    private func activityDate(_ operation: MobileMoneyOperationDTO) -> String {
        guard let raw = operation.completedAt ?? operation.createdAt,
              let date = ISO8601DateFormatter().date(from: raw)
        else { return "Date pending" }
        return AppPresentationClock.abbreviatedDateAndShortTime(date)
    }

    private func activityStatus(_ operation: MobileMoneyOperationDTO) -> String {
        if operation.isSuccessful { return "Completed" }
        if operation.isFailed { return "Failed" }
        if operation.status.caseInsensitiveCompare("reversed") == .orderedSame { return "Reversed" }
        return "Processing"
    }

    private func activityStatusColor(_ operation: MobileMoneyOperationDTO) -> Color {
        if operation.isSuccessful { return KitColor.green }
        if operation.isTerminal { return .red }
        return .orange
    }

    private func displayAmount(_ amount: String, currency: CurrencyDTO) -> String {
        KitMoney.formatted(amount, currency: currency, trimZeroFraction: true)
    }

    private func customerMessage(for error: Error) -> String {
        let message = (error as? APIErrorPayload)?.message ?? error.localizedDescription
        return CustomerFacingPaymentCopy.neutralizedServiceMessage(message)
    }
}

/// Also reached from the top-up sheet, where a customer who is short on balance may have no
/// verified number saved yet.
struct AddMobileMoneyAccountView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: MobileMoneyViewModel
    let permitted: Bool
    let online: Bool
    @State private var networkCode = ""
    @State private var phone = ""
    @State private var label = ""
    @State private var kind = "own"

    var body: some View {
        NavigationStack {
            Form {
                Section("Network") {
                    Picker("Network", selection: $networkCode) {
                        ForEach(model.networks) { network in
                            Text(network.name).tag(network.code)
                        }
                    }
                    .pickerStyle(.segmented)
                    Picker("Owner", selection: $kind) {
                        Text("My number").tag("own")
                        Text("Recipient").tag("third_party")
                    }
                    .pickerStyle(.segmented)
                    Text(
                        kind == "own"
                            ? "Use your own verified number to add money or withdraw from Kit Pay."
                            : "Save someone else's verified number to collect money from or send money to that account."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Section("Verified details") {
                    HStack(spacing: 8) {
                        Text("+256").font(.body.monospacedDigit()).foregroundStyle(.secondary)
                        TextField("7XX XXX XXX", text: Binding(
                            get: { UgandaMobileMoneyPhone.spacedNationalDigits(from: phone) },
                            set: { phone = UgandaMobileMoneyPhone.nationalDigits(from: $0) }
                        ))
                        .keyboardType(.phonePad)
                        .font(.body.monospacedDigit())
                    }
                    Text("A leading 0 is removed automatically and the number is securely formatted for payment.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Account label", text: $label)
                }
                if model.isSubmitting, let verification = model.verification {
                    Section {
                        ProgressView("Checking \(verification.accountNumberMasked)…")
                    }
                }
                if let error = model.errorMessage {
                    Section { Text(error).font(.footnote).foregroundStyle(.red) }
                }
                Section {
                    Button {
                        Task {
                            if await model.verifyAndSaveAccount(
                                networkCode: networkCode,
                                phoneNumber: phone,
                                label: label,
                                kind: kind,
                                permitted: permitted,
                                online: online
                            ) { dismiss() }
                        }
                    } label: {
                        if model.isSubmitting {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Verify and save account").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(model.isSubmitting || networkCode.isEmpty || phone.count < 9 || label.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("Add mobile money")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() }.disabled(model.isSubmitting) } }
            .interactiveDismissDisabled(model.isSubmitting)
            .onAppear { if networkCode.isEmpty { networkCode = model.networks.first?.code ?? "" } }
        }
    }
}

/// Also reached from the top-up sheet, which drives the collection half of this screen with the
/// amount a blocked payment is short by.
struct MobileMoneyOperationView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: MobileMoneyViewModel
    let flow: MobileMoneyFlow
    let wallet: Wallet?
    let permitted: Bool
    let online: Bool
    private let boundInitialAccountID: String?
    /// Explains, at the top of the form, why the customer was sent here — the payment they were
    /// approving is short by this much.
    private let notice: String?
    let completed: () async -> Void
    @State private var accountID = ""
    @State private var networkCode = ""
    @State private var phone = ""
    @State private var ownership: MobileMoneyRecipientOwnership
    @State private var payoutRecipientSource: MobileMoneyPayoutRecipientSource = .savedAccount
    @State private var savedPayoutAccountID = ""
    @State private var amount = ""
    @State private var pin = ""
    @State private var receiveFullAmount = false
    @State private var selectedPayoutFeeMode: MobileMoneyPayoutFeeMode = .senderAbsorbs
    /// Non-nil while the customer is topping up to cover this payout.
    @State private var topUpRequest: WalletTopUpRequirement?
    /// Bumped after a top-up: the payout quote this screen was holding has expired by then, and
    /// the customer should not have to retype the amount to get a fresh one.
    @State private var quoteReloadToken = 0

    init(
        model: MobileMoneyViewModel,
        flow: MobileMoneyFlow,
        wallet: Wallet?,
        permitted: Bool,
        online: Bool,
        initialAccountID: String? = nil,
        initialAmount: String? = nil,
        /// Collections default to absorbing the transaction fee out of the amount requested. A
        /// top-up cannot: the wallet has to be credited the full shortfall or the payment that
        /// sent the customer here fails again, a fee short.
        initialReceiveFullAmount: Bool = false,
        notice: String? = nil,
        completed: @escaping () async -> Void
    ) {
        self.model = model
        self.flow = flow
        self.wallet = wallet
        self.permitted = permitted
        self.online = online
        self.notice = notice
        let boundAccountID = initialAccountID?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? ""
        _amount = State(
            initialValue: initialAmount?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
        _receiveFullAmount = State(
            initialValue: flow == .addMoney && initialReceiveFullAmount
        )
        boundInitialAccountID = boundAccountID.isEmpty ? nil : boundAccountID
        self.completed = completed
        _accountID = State(initialValue: flow == .addMoney ? boundAccountID : "")
        _savedPayoutAccountID = State(
            initialValue: flow.action == .payout ? boundAccountID : ""
        )
        _payoutRecipientSource = State(initialValue: .savedAccount)
        _ownership = State(initialValue: flow.defaultPayoutOwnership)
    }

    private var action: MobileMoneyAction { flow.action }

    private var eligibleAccounts: [MobileMoneyAccountDTO] {
        model.accounts.filter { $0.isEligible(for: flow) }
    }

    private var payoutNetworks: [MobileMoneyNetworkDTO] {
        model.networks.filter {
            MobileMoneySavedAccountRailPolicy.isMobileMoneyRailDestination($0)
                && ["MTN", "AIRTEL"].contains($0.code.uppercased())
                && $0.canVerifyAccount
                && $0.canPayout
        }
    }

    private var savedPayoutAccounts: [MobileMoneyAccountDTO] {
        MobileMoneyPayoutSavedAccountPolicy.eligibleAccounts(
            from: model.accounts,
            ownership: ownership
        )
    }

    private var payoutLookupRequest: MobileMoneyPayoutLookupRequest? {
        guard action == .payout, payoutRecipientSource == .newNumber else { return nil }
        return MobileMoneyPayoutLookupRequest(
            networkCode: networkCode,
            rawPhoneNumber: phone,
            ownership: ownership
        )
    }

    private var payoutLookupTaskKey: String {
        [
            action.rawValue,
            payoutRecipientSource.rawValue,
            savedPayoutAccountID,
            networkCode.uppercased(),
            phone,
            ownership.rawValue,
            permitted.description,
            online.description,
        ].joined(separator: "|")
    }

    private var feeMode: MobileMoneyFeeMode {
        receiveFullAmount ? .grossUp : .inclusive
    }

    private var payoutFeeMode: MobileMoneyPayoutFeeMode { selectedPayoutFeeMode }

    private var quoteRequestKey: String {
        [
            action.rawValue,
            wallet?.id ?? "",
            action == .collection ? accountID : selectedAccount?.id ?? "",
            amount,
            action == .collection ? feeMode.rawValue : payoutFeeMode.rawValue,
            permitted.description,
            online.description,
            String(quoteReloadToken),
        ].joined(separator: "|")
    }

    /// The wallet as it stands now, not as it stood when this screen was presented — a top-up
    /// lands while this sheet is open.
    private var currentWallet: Wallet? {
        guard let wallet else { return nil }
        return app.state.wallets.first { $0.id == wallet.id } ?? wallet
    }

    /// Payouts debit the wallet, collections credit it, so only a payout can be short. The quote's
    /// customer debit is the number that matters: an amount the balance covers can still fail once
    /// the transaction fee is added.
    private var topUpRequirement: WalletTopUpRequirement? {
        guard action == .payout, let quote = currentPayoutQuote else { return nil }
        return WalletTopUpPolicy.requirement(
            wallet: currentWallet,
            debitAPIAmount: quote.customerDebit
        )
    }

    private var currentQuote: MobileMoneyCollectionQuoteDTO? {
        guard action == .collection,
              let quote = model.collectionQuote,
              !quote.isExpired,
              quote.walletId == wallet?.id,
              quote.accountId == accountID,
              quote.feeMode == feeMode,
              let account = eligibleAccounts.first(where: { $0.id == accountID }),
              let normalizedAmount = MobileMoneyAmount.roundedCollectionAPIAmount(
                  amount,
                  scale: account.network.currency.decimalScale
              ),
              MobileMoneyAmount.amountsMatch(quote.requestedAmount, normalizedAmount)
        else { return nil }
        return quote
    }

    private var currentPayoutQuote: MobileMoneyPayoutQuoteDTO? {
        guard action == .payout,
              let quote = model.payoutQuote,
              !quote.isExpired,
              quote.scheduleVerified,
              quote.walletId == wallet?.id,
              quote.feeMode == payoutFeeMode,
              let account = selectedAccount,
              quote.accountId == account.id,
              let enteredAmount = MobileMoneyAmount.wholeUnitAPIAmount(
                  amount,
                  scale: account.network.currency.decimalScale
              ),
              MobileMoneyAmount.amountsMatch(quote.enteredAmount, enteredAmount)
        else { return nil }
        return quote
    }

    private var selectedAccount: MobileMoneyAccountDTO? {
        if action == .collection {
            return eligibleAccounts.first { $0.id == accountID }
        }
        guard let account = model.payoutLookupState.account(for: ownership) else { return nil }
        if payoutRecipientSource == .savedAccount {
            guard account.id.caseInsensitiveCompare(savedPayoutAccountID) == .orderedSame else {
                return nil
            }
        } else {
            guard let request = payoutLookupRequest,
                  case let .verified(verifiedRequest, _) = model.payoutLookupState,
                  verifiedRequest == request
            else { return nil }
        }
        return account
    }

    var body: some View {
        NavigationStack {
            Form {
                if let notice {
                    Section {
                        Label {
                            Text(notice)
                                .font(.footnote)
                                .foregroundStyle(KitColor.primaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }
                if action == .collection {
                    Section("From mobile money") {
                        Picker("Account", selection: $accountID) {
                            ForEach(eligibleAccounts) { account in
                                Text("\(account.network.name) • \(account.phoneNumberMasked)").tag(account.id)
                            }
                        }
                        .disabled(boundInitialAccountID != nil)
                        if eligibleAccounts.isEmpty {
                            Text("Add and verify an MTN or Airtel mobile money number first.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    payoutDestinationSection
                }
                Section("Amount") {
                    HStack {
                        Text(wallet?.currency.code ?? "UGX").bold()
                        KitAmountTextField(
                            "0",
                            value: $amount,
                            mode: action == .collection
                                ? .decimal(
                                    maximumFractionDigits:
                                        wallet?.currency.decimalScale ?? 2
                                )
                                : .whole,
                            textStyle: .monospacedBody
                        )
                    }
                    Text("The exact amount and transaction fee are shown before approval.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .disabled(model.isSubmitting || model.isQuoting)
                if action == .collection {
                    Section("Fee preference") {
                        Button {
                            receiveFullAmount.toggle()
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: receiveFullAmount ? "checkmark.square.fill" : "square")
                                    .font(.title3)
                                    .foregroundStyle(receiveFullAmount ? KitColor.green : .secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Receive the full amount")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text("Add the transaction fee to the mobile money request so the amount entered reaches your Kit Pay wallet in full.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Receive the full amount")
                        .accessibilityValue(receiveFullAmount ? "Selected" : "Not selected")

                        if !receiveFullAmount {
                            Text("Keep total unchanged (default). The transaction fee is included within the amount entered.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    feeReviewSection
                } else {
                    Section("Fee preference") {
                        ForEach(
                            [MobileMoneyPayoutFeeMode.senderAbsorbs, .beneficiaryAbsorbs],
                            id: \.self
                        ) { mode in
                            Button {
                                selectedPayoutFeeMode = mode
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: selectedPayoutFeeMode == mode
                                        ? "checkmark.circle.fill"
                                        : "circle")
                                        .font(.title3)
                                        .foregroundStyle(selectedPayoutFeeMode == mode
                                            ? KitColor.green
                                            : .secondary)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(mode == .senderAbsorbs
                                            ? "Covered by me"
                                            : "Covered by beneficiary")
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(.primary)
                                        Text(mode == .senderAbsorbs
                                            ? "The beneficiary receives the full amount entered. The transaction fee is added to your wallet debit."
                                            : "The transaction fee is deducted from the amount entered before the beneficiary receives it.")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(mode == .senderAbsorbs
                                ? "Covered by me"
                                : "Covered by beneficiary")
                            .accessibilityValue(selectedPayoutFeeMode == mode
                                ? "Selected"
                                : "Not selected")
                        }
                    }

                    outboundReviewSection
                }
                if let requirement = topUpRequirement {
                    Section {
                        WalletShortfallNotice(requirement: requirement) {
                            topUpRequest = requirement
                        }
                    }
                }
                Section("Approve") {
                    if app.financialApprovalUsesBiometrics {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Approve with \(app.biometricDisplayName)")
                                Text("Kit Pay will ask when you confirm this exact request.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: app.biometricSymbolName)
                                .foregroundStyle(KitColor.green)
                        }
                    } else {
                        SecureField("Four-digit wallet PIN", text: $pin)
                            .keyboardType(.numberPad)
                            .onChange(of: pin) { _, value in
                                pin = String(value.filter(\.isNumber).prefix(4))
                            }
                    }
                }
                if let error = model.errorMessage {
                    Section { Text(error).font(.footnote).foregroundStyle(.red) }
                }
                Section {
                    Button {
                        Task {
                            let authorization: KitFinancialStepUpAuthorization = { purpose, intent, pin, reason in
                                try await app.authorizeFinancialStepUp(
                                    purpose: purpose,
                                    intent: intent,
                                    pin: pin,
                                    reason: reason
                                )
                            }
                            let succeeded: Bool
                            if action == .collection {
                                guard let quote = currentQuote else {
                                    model.errorMessage = "Review the current mobile money total before approving."
                                    return
                                }
                                succeeded = await model.submitQuotedCollection(
                                    quote: quote,
                                    pin: pin,
                                    wallet: wallet,
                                    permitted: permitted,
                                    online: online,
                                    authorization: authorization
                                )
                            } else {
                                guard let account = selectedAccount,
                                      let quote = currentPayoutQuote
                                else {
                                    model.errorMessage = "Verify the recipient and review the current payout total before approving."
                                    return
                                }
                                succeeded = await model.submitQuotedPayout(
                                    quote: quote,
                                    ownership: ownership,
                                    accountID: account.id,
                                    pin: pin,
                                    wallet: wallet,
                                    permitted: permitted,
                                    online: online,
                                    authorization: authorization
                                )
                            }
                            if succeeded {
                                await completed()
                                dismiss()
                            } else {
                                await offerTopUpIfServerFoundBalanceShort()
                            }
                        }
                    } label: {
                        if model.isSubmitting {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Label(
                                action == .collection
                                    ? "Request money"
                                    : ownership == .myself ? "Confirm withdrawal" : "Confirm send",
                                systemImage: app.financialApprovalUsesBiometrics
                                    ? app.biometricSymbolName
                                    : "lock.fill"
                            )
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(
                        model.isSubmitting
                            || model.isQuoting
                            || amount.isEmpty
                            || (action == .collection && accountID.isEmpty)
                            || (action == .collection && currentQuote == nil)
                            || (action == .payout && (selectedAccount == nil || currentPayoutQuote == nil))
                            || topUpRequirement != nil
                            || (!app.financialApprovalUsesBiometrics && pin.count != 4)
                    )
                }
            }
            .navigationTitle(flow.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() }.disabled(model.isSubmitting) } }
            .interactiveDismissDisabled(model.isSubmitting)
            .onAppear {
                if action == .collection, accountID.isEmpty {
                    accountID = eligibleAccounts.first?.id ?? ""
                }
                if action == .payout, networkCode.isEmpty {
                    networkCode = payoutNetworks.first?.code ?? ""
                }
                if action == .payout {
                    configurePayoutRecipientSource()
                }
                if action == .payout, flow == .withdraw, phone.isEmpty,
                   let profilePhone = app.profile?.phone {
                    phone = UgandaMobileMoneyPhone.nationalDigits(from: profilePhone)
                }
            }
            .task(id: quoteRequestKey) {
                model.clearCollectionQuote()
                model.clearPayoutQuote()
                guard permitted,
                      online,
                      !amount.isEmpty
                else { return }
                do {
                    try await Task.sleep(nanoseconds: 450_000_000)
                    try Task.checkCancellation()
                } catch {
                    return
                }
                if action == .collection {
                    guard !accountID.isEmpty else { return }
                    await model.loadCollectionQuote(
                        accountID: accountID,
                        enteredAmount: amount,
                        feeMode: feeMode,
                        wallet: wallet,
                        permitted: permitted,
                        online: online
                    )
                } else {
                    guard let account = selectedAccount
                    else { return }
                    await model.loadPayoutQuote(
                        ownership: ownership,
                        accountID: account.id,
                        enteredAmount: amount,
                        feeMode: payoutFeeMode,
                        wallet: wallet,
                        permitted: permitted,
                        online: online
                    )
                }
            }
            .task(id: payoutLookupTaskKey) {
                model.resetPayoutLookup()
                guard action == .payout else { return }
                if payoutRecipientSource == .savedAccount {
                    guard !savedPayoutAccountID.isEmpty else { return }
                    model.selectSavedPayoutAccount(
                        id: savedPayoutAccountID,
                        ownership: ownership
                    )
                    return
                }
                guard let request = payoutLookupRequest else { return }
                do {
                    try await Task.sleep(nanoseconds: 450_000_000)
                    try Task.checkCancellation()
                } catch {
                    return
                }
                await model.resolvePayoutAccount(
                    request,
                    permitted: permitted,
                    online: online
                )
            }
            .onChange(of: ownership) { _, _ in
                configurePayoutRecipientSource()
            }
            .onDisappear {
                model.clearCollectionQuote()
                model.clearPayoutQuote()
                model.resetPayoutLookup()
            }
            .sheet(item: $topUpRequest) { requirement in
                WalletTopUpView(requirement: requirement) { covered in
                    guard covered else { return }
                    // The quote held here expired while the top-up was in flight; a fresh one is
                    // fetched so the customer returns to a ready approval, not an empty review.
                    quoteReloadToken += 1
                }
                .environmentObject(app)
                .presentationBackground(.ultraThinMaterial)
            }
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
            wallet: currentWallet,
            debitAPIAmount: debit
        ) else { return }
        topUpRequest = requirement
    }

    @ViewBuilder
    private var payoutDestinationSection: some View {
        Section("Recipient") {
            VStack(spacing: 0) {
                ForEach(MobileMoneyRecipientOwnership.allCases) { option in
                    Button {
                        ownership = option
                    } label: {
                        HStack {
                            Text(option.title).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: ownership == option ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(ownership == option ? KitColor.green : .secondary)
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if option != .someoneElse {
                        Divider()
                    }
                }
            }
            .disabled(boundInitialAccountID != nil)

            Picker("Recipient source", selection: $payoutRecipientSource) {
                ForEach(MobileMoneyPayoutRecipientSource.allCases) { source in
                    Text(source.title).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .disabled(boundInitialAccountID != nil)

            if payoutRecipientSource == .savedAccount {
                if savedPayoutAccounts.isEmpty {
                    Text(ownership == .myself
                        ? "You do not have a saved verified number for withdrawals yet."
                        : "You do not have a saved verified beneficiary yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if boundInitialAccountID == nil {
                        Button("Use a new number") {
                            payoutRecipientSource = .newNumber
                        }
                    }
                } else {
                    Picker("Saved account", selection: $savedPayoutAccountID) {
                        ForEach(savedPayoutAccounts) { account in
                            Text(savedPayoutAccountLabel(account)).tag(account.id)
                        }
                    }
                    .disabled(boundInitialAccountID != nil)

                    if let account = savedPayoutAccounts.first(where: {
                        $0.id.caseInsensitiveCompare(savedPayoutAccountID) == .orderedSame
                    }) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.accountName ?? account.label).font(.headline)
                                Text("\(account.network.name) • \(account.phoneNumberMasked)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(KitColor.green)
                        }
                    }
                }
            } else if payoutNetworks.isEmpty {
                Text("Verified MTN and Airtel payouts are not currently available.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Network", selection: $networkCode) {
                    ForEach(payoutNetworks) { network in
                        Text(network.name).tag(network.code)
                    }
                }
                .pickerStyle(.segmented)

                HStack(spacing: 8) {
                    Text("+256")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                    TextField("7XX XXX XXX", text: Binding(
                        get: { UgandaMobileMoneyPhone.spacedNationalDigits(from: phone) },
                        set: { phone = UgandaMobileMoneyPhone.nationalDigits(from: $0) }
                    ))
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .font(.body.monospacedDigit())
                }

                Text("Enter all 9 national digits. Kit Pay formats the number securely and confirms the account name automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                payoutLookupStatus
            }
        }
        .disabled(model.isSubmitting)
    }

    private func configurePayoutRecipientSource() {
        guard action == .payout else { return }
        if let boundInitialAccountID {
            savedPayoutAccountID = boundInitialAccountID
            payoutRecipientSource = .savedAccount
            return
        }
        if savedPayoutAccounts.isEmpty {
            savedPayoutAccountID = ""
            payoutRecipientSource = .newNumber
            return
        }
        if !savedPayoutAccounts.contains(where: {
            $0.id.caseInsensitiveCompare(savedPayoutAccountID) == .orderedSame
        }) {
            savedPayoutAccountID = savedPayoutAccounts[0].id
        }
    }

    private func savedPayoutAccountLabel(_ account: MobileMoneyAccountDTO) -> String {
        "\(account.accountName ?? account.label) • \(account.network.name) • \(account.phoneNumberMasked)"
    }

    @ViewBuilder
    private var payoutLookupStatus: some View {
        if let request = payoutLookupRequest {
            switch model.payoutLookupState {
            case .verifying(let activeRequest) where activeRequest == request:
                ProgressView("Verifying account name…")
            case .verified(let verifiedRequest, let account) where verifiedRequest == request:
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.accountName ?? account.label).font(.headline)
                        Text("\(account.network.name) • \(account.phoneNumberMasked)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(KitColor.green)
                }
            case .failed(let failedRequest, let message) where failedRequest == request:
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            default:
                ProgressView("Preparing verification…")
            }
        } else {
            Text("Account-name verification starts when the full number is entered.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var feeReviewSection: some View {
        Section("Before you approve") {
            if model.isQuoting {
                ProgressView("Updating totals…")
            } else if let quote = currentQuote {
                amountRow("Mobile money request", quote.providerAmount, currency: quote.currency)
                amountRow(
                    CustomerFacingPaymentCopy.transactionFeeTitle,
                    quote.totalFees,
                    currency: quote.currency
                )
                amountRow(
                    "You receive",
                    quote.walletCredit,
                    currency: quote.currency,
                    emphasized: true
                )

                if quote.providerFeeEstimated {
                    Text("The transaction fee is estimated from the current rate. The final amount remains available in your transaction history.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if !amount.isEmpty, !accountID.isEmpty {
                Text("Enter an amount greater than zero to review the exact total and wallet credit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var outboundReviewSection: some View {
        Section("Before you approve") {
            if model.isQuoting {
                ProgressView("Updating exact payout total…")
            } else if let quote = currentPayoutQuote,
                      let account = selectedAccount {
                amountRow(
                    ownership == .someoneElse ? "Recipient receives" : "Amount withdrawn",
                    quote.recipientAmount,
                    currency: quote.currency,
                    emphasized: true
                )
                amountRow(
                    CustomerFacingPaymentCopy.transactionFeeTitle,
                    quote.processingFee,
                    currency: quote.currency
                )
                amountRow(
                    "Your Kit Pay wallet debit",
                    quote.customerDebit,
                    currency: quote.currency,
                    emphasized: true
                )
                HStack {
                    Text("Fee treatment")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(payoutFeeTreatment(quote.feeMode))
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.trailing)
                }

                Text(payoutSummary(quote, account: account))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Text("Approval is bound to the exact transaction fee and wallet debit shown here. It cannot authorize a higher debit.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Enter an amount greater than zero and verify the recipient to review the transaction fee and exact total debit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func amountRow(
        _ title: String,
        _ amount: String,
        currency: CurrencyDTO,
        emphasized: Bool = false
    ) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(emphasized ? .primary : .secondary)
            Spacer()
            Text(displayAmount(amount, currency: currency))
                .fontWeight(emphasized ? .bold : .regular)
                .foregroundStyle(emphasized ? KitColor.green : .primary)
                .monospacedDigit()
        }
    }

    private func payoutFeeTreatment(_ mode: MobileMoneyPayoutFeeMode) -> String {
        switch mode {
        case .senderAbsorbs:
            "Covered by me"
        case .beneficiaryAbsorbs:
            "Covered by beneficiary"
        case .kitCovers:
            "Not charged to your wallet"
        }
    }

    private func payoutSummary(
        _ quote: MobileMoneyPayoutQuoteDTO,
        account: MobileMoneyAccountDTO
    ) -> String {
        let name = account.accountName ?? account.label
        let received = displayAmount(quote.recipientAmount, currency: quote.currency)
        let debit = displayAmount(quote.customerDebit, currency: quote.currency)
        switch quote.feeMode {
        case .senderAbsorbs:
            return "\(name) receives \(received). Your wallet is debited \(debit), including the disclosed transaction fee."
        case .beneficiaryAbsorbs:
            return "Your wallet is debited \(debit). After the disclosed transaction fee is deducted, \(name) receives \(received)."
        case .kitCovers:
            return "\(name) receives \(received). Your wallet is debited \(debit), and the disclosed fee is not charged to your wallet."
        }
    }

    private func displayAmount(_ amount: String, currency: CurrencyDTO) -> String {
        KitMoney.formatted(amount, currency: currency, trimZeroFraction: true)
    }

    private func isZero(_ amount: String) -> Bool {
        guard let value = Decimal(
            string: amount,
            locale: Locale(identifier: "en_US_POSIX")
        ) else { return false }
        return value == 0
    }
}
