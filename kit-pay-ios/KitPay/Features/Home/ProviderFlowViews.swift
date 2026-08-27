import Foundation
import SwiftUI

enum ProviderFlowEntry: String, Identifiable {
    case bills
    case airtime

    var id: String { rawValue }

    var service: ProviderService {
        switch self {
        case .bills: .bill
        case .airtime: .airtime
        }
    }
}

enum ProviderAmountRangeCopy {
    static func text(for product: ProviderProductDTO) -> String {
        switch (product.minimumAmount, product.maximumAmount) {
        case let (minimum?, maximum?):
            let lowerBound = KitMoney.formatted(minimum, currency: product.currency)
            let upperBound = KitMoney.amount(maximum, scale: product.currency.decimalScale)
            return "Available from \(lowerBound) to \(upperBound)"
        case let (minimum?, nil):
            return "Minimum \(KitMoney.formatted(minimum, currency: product.currency))"
        case let (nil, maximum?):
            return "Maximum \(KitMoney.formatted(maximum, currency: product.currency))"
        default:
            return ""
        }
    }
}

@MainActor
final class ProviderFlowModel: ObservableObject {
    @Published private(set) var products: [ProviderProductDTO] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isQuoting = false
    @Published private(set) var isSubmitting = false
    @Published private(set) var operationUpdates: [String: ProviderOperationDTO] = [:]
    @Published private(set) var pollingOperationIDs: Set<String> = []
    @Published var errorMessage: String?
    /// The wallet debit the server refused for want of balance, so the screen can offer the same
    /// top-up it would have offered had the device's own balance been current.
    @Published var insufficientFundsDebitAmount: String?

    private let api: APIClient
    private var operationPollTasks: [String: Task<Void, Never>] = [:]

    init(api: APIClient = .shared) {
        self.api = api
    }

    deinit {
        operationPollTasks.values.forEach { $0.cancel() }
    }

    var billProducts: [ProviderProductDTO] {
        products.filter { $0.serviceType == ProviderService.bill.rawValue }
    }

    var airtimeProducts: [ProviderProductDTO] {
        AirtimeProductPresentationPolicy.ordered(
            products.filter { $0.serviceType == ProviderService.airtime.rawValue }
        )
    }

    func loadCatalog(force: Bool = false, permitted: Bool, online: Bool) async {
        guard permitted else {
            products = []
            errorMessage = "This service is not enabled for your Kit Pay account."
            return
        }
        guard online else {
            products = []
            errorMessage = "Connect to the internet to load available provider services."
            return
        }
        guard force || products.isEmpty else { return }
        guard !isLoading else { return }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            products = try await api.providerCatalog().items ?? []
        } catch {
            products = []
            errorMessage = message(for: error)
        }
    }

    func createQuote(
        service: ProviderService,
        product: ProviderProductDTO,
        wallet: Wallet?,
        account: String,
        enteredAmount: String,
        permitted: Bool,
        online: Bool
    ) async -> ProviderQuoteDTO? {
        guard !isQuoting, !isSubmitting else { return nil }
        guard permitted else {
            errorMessage = "This service is not enabled for your Kit Pay account."
            return nil
        }
        guard online else {
            errorMessage = "Connect to the internet to submit this payment."
            return nil
        }
        guard product.serviceType == service.rawValue else {
            errorMessage = "The selected service is not available for this payment."
            return nil
        }
        guard let wallet,
              wallet.status.caseInsensitiveCompare("active") == .orderedSame,
              wallet.currency == product.currency
        else {
            errorMessage = "Choose an active \(product.currency.code) wallet."
            return nil
        }

        let enteredAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !enteredAccount.isEmpty else {
            errorMessage = service == .bill ? "Enter the billing account number." : "Enter a phone number."
            return nil
        }
        let cleanAccount: String
        if service == .airtime {
            guard let rukaPayPhone = UgandaMobileMoneyPhone.apiValue(from: enteredAccount) else {
                errorMessage = "Enter a valid phone number."
                return nil
            }
            cleanAccount = rukaPayPhone
        } else {
            cleanAccount = enteredAccount
        }
        guard let amount = ProviderMoney.apiAmount(enteredAmount, product: product) else {
            errorMessage = product.requiresWholeUGXRukaPayAmount
                ? "Enter an amount greater than zero."
                : "Enter an amount greater than zero using no more than \(max(Int(product.currency.scale) ?? 2, 0)) decimal places."
            return nil
        }
        guard ProviderMoney.isWithinProductRange(amount, product: product) else {
            errorMessage = amountRangeMessage(for: product)
            return nil
        }

        isQuoting = true
        errorMessage = nil
        defer { isQuoting = false }

        do {
            let quote = try await api.createProviderQuote(
                productId: product.id,
                account: cleanAccount,
                amount: amount
            )
            try validate(
                quote,
                service: service,
                product: product,
                expectedAmount: amount
            )
            return quote
        } catch {
            errorMessage = message(for: error)
            return nil
        }
    }

    func submitQuotedPurchase(
        service: ProviderService,
        product: ProviderProductDTO,
        wallet: Wallet?,
        quote: ProviderQuoteDTO,
        clientReference: String,
        pin: String,
        permitted: Bool,
        online: Bool,
        authorization: KitFinancialStepUpAuthorization
    ) async -> ProviderOperationDTO? {
        guard !isSubmitting, !isQuoting else { return nil }
        guard permitted else {
            errorMessage = "This service is not enabled for your Kit Pay account."
            return nil
        }
        guard online else {
            errorMessage = "Connect to the internet to submit this payment."
            return nil
        }
        guard let wallet,
              wallet.status.caseInsensitiveCompare("active") == .orderedSame,
              wallet.currency == product.currency
        else {
            errorMessage = "Choose an active \(product.currency.code) wallet."
            return nil
        }
        guard !clientReference.isEmpty, clientReference.count <= 128 else {
            errorMessage = "Create a fresh payment review before approving."
            return nil
        }

        do {
            try validate(
                quote,
                service: service,
                product: product,
                expectedAmount: quote.amount
            )
        } catch {
            errorMessage = message(for: error)
            return nil
        }

        isSubmitting = true
        errorMessage = nil
        insufficientFundsDebitAmount = nil
        defer { isSubmitting = false }

        do {

            let binding = ProviderOperationBinding(
                quoteId: quote.id,
                walletId: wallet.id,
                clientReference: clientReference
            )
            let feeCopy = ProviderMoney.amountsMatch(quote.fee, "0")
                ? "with no transaction fee"
                : "including a \(KitMoney.formatted(quote.fee, currency: quote.currency, trimZeroFraction: true)) transaction fee"
            let verification = try await authorization(
                service.operationType,
                binding.stepUpIntent,
                pin,
                "Approve the quoted total of \(KitMoney.formatted(quote.total, currency: quote.currency, trimZeroFraction: true)) for \(product.customerFacingName), \(feeCopy)"
            )
            guard !verification.stepUpToken.isEmpty else {
                throw ProviderFlowError.invalidStepUp
            }
            try validate(
                quote,
                service: service,
                product: product,
                expectedAmount: quote.amount
            )
            let created: ProviderOperationDTO
            switch service {
            case .bill:
                created = try await api.createBillPayment(
                    request: binding.request,
                    idempotencyKey: binding.idempotencyKey,
                    stepUpToken: verification.stepUpToken
                )
            case .airtime:
                created = try await api.createAirtimePurchase(
                    request: binding.request,
                    idempotencyKey: binding.idempotencyKey,
                    stepUpToken: verification.stepUpToken
                )
            }
            guard created.type == service.operationType,
                  created.walletId == wallet.id,
                  created.productId == product.id,
                  created.providerCode.caseInsensitiveCompare(quote.providerCode) == .orderedSame,
                  created.clientReference == clientReference,
                  ProviderMoney.amountsMatch(created.amount, quote.amount),
                  ProviderMoney.amountsMatch(created.fee, quote.fee),
                  ProviderMoney.amountsMatch(created.total, quote.total),
                  created.currency == quote.currency
            else { throw ProviderFlowError.operationMismatch }

            operationUpdates[created.id] = created
            if !created.isTerminal { pollOperation(created.id) }
            return created
        } catch {
            errorMessage = message(for: error)
            if WalletTopUpPolicy.isInsufficientFunds(error) {
                // The total, not the amount: a balance that covers the airtime but not the
                // transaction fee is refused all the same.
                insufficientFundsDebitAmount = quote.total
            }
            return nil
        }
    }

    func operation(id: String) -> ProviderOperationDTO? {
        operationUpdates[id]
    }

    func clearPaymentError() {
        errorMessage = nil
    }

    func resumeOperationPolling(id: String) {
        guard let operation = operationUpdates[id], !operation.isTerminal else { return }
        pollOperation(id)
    }

    func cancelOperationPolling(id: String) {
        operationPollTasks[id]?.cancel()
        operationPollTasks[id] = nil
        pollingOperationIDs.remove(id)
    }

    func isPollingOperation(id: String) -> Bool {
        pollingOperationIDs.contains(id)
    }

    private func validate(
        _ quote: ProviderQuoteDTO,
        service: ProviderService,
        product: ProviderProductDTO,
        expectedAmount: String
    ) throws {
        guard !quote.isExpired else { throw ProviderFlowError.quoteExpired }
        guard quote.productId == product.id,
              quote.providerCode.caseInsensitiveCompare(product.provider.code) == .orderedSame,
              quote.serviceType == service.rawValue,
              ProviderMoney.amountsMatch(quote.amount, expectedAmount),
              quote.currency == product.currency,
              ProviderMoney.quoteReconciles(quote)
        else { throw ProviderFlowError.quoteMismatch }
    }

    private func pollOperation(_ id: String) {
        operationPollTasks[id]?.cancel()
        pollingOperationIDs.insert(id)
        operationPollTasks[id] = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<40 {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }
                guard let current = operationUpdates[id],
                      let updated = try? await api.providerOperation(id: id),
                      updated.id == id,
                      updated.hasSamePaymentBinding(as: current)
                else { continue }
                operationUpdates[id] = updated
                if updated.isTerminal {
                    operationPollTasks[id] = nil
                    pollingOperationIDs.remove(id)
                    return
                }
            }
            operationPollTasks[id] = nil
            pollingOperationIDs.remove(id)
        }
    }

    private func amountRangeMessage(for product: ProviderProductDTO) -> String {
        switch (product.minimumAmount, product.maximumAmount) {
        case let (minimum?, maximum?):
            """
            Enter an amount from \
            \(KitMoney.formatted(minimum, currency: product.currency, trimZeroFraction: true)) to \
            \(KitMoney.amount(maximum, scale: product.currency.decimalScale, trimZeroFraction: true)).
            """
        case let (minimum?, nil):
            "The minimum is \(KitMoney.formatted(minimum, currency: product.currency, trimZeroFraction: true))."
        case let (nil, maximum?):
            "The maximum is \(KitMoney.formatted(maximum, currency: product.currency, trimZeroFraction: true))."
        default:
            "That amount is not available for this provider."
        }
    }

    private func message(for error: Error) -> String {
        let message = (error as? APIErrorPayload)?.message ?? error.localizedDescription
        return CustomerFacingPaymentCopy.neutralizedServiceMessage(message)
    }
}

struct ProviderFlowContainer: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let entry: ProviderFlowEntry
    @StateObject private var flow = ProviderFlowModel()

    private var permitted: Bool {
        app.capabilities?.enablesProviderService(entry.service) == true
    }

    var body: some View {
        NavigationStack {
            Group {
                if !permitted {
                    ProviderUnavailableView(
                        title: entry == .bills ? "Bill payments unavailable" : "Airtime unavailable",
                        message: "This service is not enabled for your Kit Pay account."
                    )
                } else if !app.isOnline {
                    ProviderUnavailableView(
                        title: "Internet connection required",
                        message: "Provider payments are submitted online and cannot be queued offline."
                    )
                } else if entry == .bills {
                    BillsCatalogView(flow: flow)
                } else {
                    AirtimePurchaseView(flow: flow)
                }
            }
            .background(KitColor.canvas.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                        .disabled(flow.isSubmitting)
                }
            }
        }
        .presentationBackground(.ultraThinMaterial)
        .interactiveDismissDisabled(flow.isSubmitting)
        .task(id: "\(entry.id)-\(permitted)-\(app.isOnline)") {
            await flow.loadCatalog(permitted: permitted, online: app.isOnline)
        }
    }
}

private struct ProviderUnavailableView: View {
    let title: String
    let message: String

    var body: some View {
        ContentUnavailableView(
            title,
            systemImage: "lock.shield",
            description: Text(message)
        )
        .navigationTitle("Kit Pay")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct BillsCatalogView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var flow: ProviderFlowModel

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                if app.capabilities?.enablesProviderService(.airtime) == true,
                   !flow.airtimeProducts.isEmpty {
                    NavigationLink {
                        AirtimePurchaseView(flow: flow)
                    } label: {
                        providerCard(title: "Airtime", icon: "simcard.fill")
                    }
                    .buttonStyle(.plain)
                }

                ForEach(flow.billProducts) { product in
                    NavigationLink {
                        BillPaymentView(flow: flow, product: product)
                    } label: {
                        providerCard(title: product.customerFacingName, icon: icon(for: product.category.name))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)

            if flow.isLoading {
                ProgressView("Loading available services…")
                    .padding(.top, 30)
            } else if let error = flow.errorMessage {
                ProviderInlineError(message: error)
                    .padding(.horizontal, 20)
            } else if flow.billProducts.isEmpty {
                ContentUnavailableView(
                    "No bill providers",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("No production bill service is currently available.")
                )
                .padding(.top, 30)
            }
        }
        .navigationTitle("Pay bills")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        await flow.loadCatalog(
                            force: true,
                            permitted: app.capabilities?.enablesProviderService(.bill) == true,
                            online: app.isOnline
                        )
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(flow.isLoading)
                .accessibilityLabel("Refresh providers")
            }
        }
    }

    private func providerCard(title: String, icon: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2.weight(.semibold))
                .foregroundStyle(KitColor.primaryText)
                .frame(width: 54, height: 54)
                .background(KitColor.paleGreen, in: Circle())
            Text(title)
                .font(.subheadline.bold())
                .foregroundStyle(KitColor.primaryText)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 125)
        .padding(16)
        .kitGlass(cornerRadius: 24)
    }

    private func icon(for category: String) -> String {
        let value = category.lowercased()
        if value.contains("electric") || value.contains("power") { return "bolt.fill" }
        if value.contains("water") { return "drop.fill" }
        if value.contains("internet") { return "wifi" }
        if value.contains("television") || value == "tv" { return "tv.fill" }
        if value.contains("school") || value.contains("education") { return "graduationcap.fill" }
        return "doc.text.fill"
    }
}

private struct BillPaymentView: View {
    @ObservedObject var flow: ProviderFlowModel
    let product: ProviderProductDTO

    var body: some View {
        ProviderPaymentForm(flow: flow, product: product, service: .bill)
            .navigationTitle(product.customerFacingName)
            .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AirtimePurchaseView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var flow: ProviderFlowModel
    @State private var selectedProductId = ""

    private var selectedProduct: ProviderProductDTO? {
        flow.airtimeProducts.first(where: { $0.id == selectedProductId })
            ?? flow.airtimeProducts.first
    }

    var body: some View {
        Group {
            if flow.isLoading && flow.airtimeProducts.isEmpty {
                ProgressView("Loading airtime networks…")
            } else if let selectedProduct {
                VStack(spacing: 0) {
                    if flow.airtimeProducts.count > 1 {
                        Picker("Network", selection: $selectedProductId) {
                            ForEach(flow.airtimeProducts) { product in
                                Text(product.customerFacingName).tag(product.id)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                    }
                    ProviderPaymentForm(
                        flow: flow,
                        product: selectedProduct,
                        service: .airtime,
                        initialAccount: app.profile?.phone ?? ""
                    )
                    .id(selectedProduct.id)
                }
            } else if let error = flow.errorMessage {
                ProviderUnavailableView(title: "Airtime unavailable", message: error)
            } else {
                ProviderUnavailableView(
                    title: "No airtime networks",
                    message: "No production airtime product is currently available."
                )
            }
        }
        .navigationTitle("Buy airtime")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: synchronizeSelection)
        .onChange(of: flow.airtimeProducts) { _, _ in
            synchronizeSelection()
        }
    }

    private func synchronizeSelection() {
        guard !flow.airtimeProducts.contains(where: { $0.id == selectedProductId }) else { return }
        selectedProductId = AirtimeProductPresentationPolicy.preferredProductID(
            in: flow.airtimeProducts
        ) ?? ""
    }
}

private struct ProviderPaymentForm: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var flow: ProviderFlowModel
    let product: ProviderProductDTO
    let service: ProviderService

    @State private var account: String
    @State private var amount = ""
    @State private var pin = ""
    @State private var quote: ProviderQuoteDTO?
    @State private var clientReference = ""
    @State private var operation: ProviderOperationDTO?
    @State private var topUpRequest: WalletTopUpRequirement?

    init(
        flow: ProviderFlowModel,
        product: ProviderProductDTO,
        service: ProviderService,
        initialAccount: String = ""
    ) {
        self.flow = flow
        self.product = product
        self.service = service
        _account = State(initialValue: initialAccount)
    }

    private var permitted: Bool {
        app.capabilities?.enablesProviderService(service) == true
    }

    private var currentOperation: ProviderOperationDTO? {
        guard let operation else { return nil }
        return flow.operation(id: operation.id) ?? operation
    }

    var body: some View {
        Group {
            if let operation = currentOperation {
                operationResult(operation)
            } else if let quote {
                quoteReview(quote)
            } else {
                paymentEntry
            }
        }
        .background(KitColor.canvas.ignoresSafeArea())
        .onChange(of: scenePhase) { _, phase in
            guard let id = operation?.id else { return }
            if phase == .active {
                flow.resumeOperationPolling(id: id)
            } else {
                flow.cancelOperationPolling(id: id)
            }
        }
        .onDisappear {
            if let id = operation?.id { flow.cancelOperationPolling(id: id) }
        }
        .sheet(item: $topUpRequest) { requirement in
            WalletTopUpView(requirement: requirement) { covered in
                guard covered else { return }
                WalletTopUpPresentation.afterDismissal { requoteAfterTopUp() }
            }
            .environmentObject(app)
            .presentationBackground(.ultraThinMaterial)
        }
    }

    /// Everything the wallet has to cover for this quote, or nil once it does.
    private func topUpRequirement(for quote: ProviderQuoteDTO) -> WalletTopUpRequirement? {
        WalletTopUpPolicy.requirement(
            wallet: app.selectedWallet,
            debitAPIAmount: quote.total
        )
    }

    /// A quote reviewed before a top-up has expired by the time the money lands, so a fresh one is
    /// fetched for the same payment — the customer comes back to a ready approval, not a blank form.
    @MainActor
    private func requoteAfterTopUp() {
        guard operation == nil else { return }
        flow.clearPaymentError()
        pin = ""
        Task {
            let refreshed = await flow.createQuote(
                service: service,
                product: product,
                wallet: app.selectedWallet,
                account: account,
                enteredAmount: amount,
                permitted: permitted,
                online: app.isOnline
            )
            guard let refreshed else {
                // The re-quote failed, so the stale one is dropped rather than left on screen
                // promising a total the server would now refuse.
                resetReview()
                return
            }
            quote = refreshed
            clientReference = "ios-provider-\(UUID().uuidString.lowercased())"
        }
    }

    /// The balance on the device can be a moment behind the ledger. When the server is the one to
    /// find it short, the same top-up is offered rather than a bare refusal.
    @MainActor
    private func offerTopUpIfServerFoundBalanceShort() async {
        guard let debit = flow.insufficientFundsDebitAmount else { return }
        flow.insufficientFundsDebitAmount = nil
        await app.refresh()
        guard let requirement = WalletTopUpPolicy.requirement(
            wallet: app.selectedWallet,
            debitAPIAmount: debit
        ) else { return }
        topUpRequest = requirement
    }

    private var paymentEntry: some View {
        ScrollView {
            VStack(spacing: 17) {
                productHeader
                accountField

                if service == .airtime {
                    Text("A leading 0 is removed automatically and the number is securely formatted for payment.")
                        .font(.caption)
                        .foregroundStyle(KitColor.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    presetAmounts
                }

                amountField

                if product.minimumAmount != nil || product.maximumAmount != nil {
                    Text(productRange)
                        .font(.caption)
                        .foregroundStyle(KitColor.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text("Kit Pay will show the payment amount, transaction fee, and exact wallet total before asking for approval.")
                    .font(.caption)
                    .foregroundStyle(KitColor.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let error = flow.errorMessage {
                    ProviderInlineError(message: error)
                }

                Button {
                    Task {
                        if let reviewedQuote = await flow.createQuote(
                            service: service,
                            product: product,
                            wallet: app.selectedWallet,
                            account: account,
                            enteredAmount: amount,
                            permitted: permitted,
                            online: app.isOnline
                        ) {
                            quote = reviewedQuote
                            clientReference = "ios-provider-\(UUID().uuidString.lowercased())"
                            pin = ""
                        }
                    }
                } label: {
                    if flow.isQuoting {
                        ProgressView().tint(.white).frame(maxWidth: .infinity)
                    } else {
                        Label("Review transaction fee and total", systemImage: "doc.text.magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(KitPrimaryButtonStyle())
                .disabled(
                    flow.isQuoting || flow.isSubmitting || !permitted || !app.isOnline
                        || account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || (service == .airtime && UgandaMobileMoneyPhone.apiValue(from: account) == nil)
                        || ProviderMoney.apiAmount(amount, product: product) == nil
                )
            }
            .padding(22)
            .disabled(flow.isQuoting)
        }
    }

    private var productHeader: some View {
        VStack(spacing: 5) {
            Text(service == .airtime ? product.customerFacingName : product.category.name)
                .font(.subheadline)
                .foregroundStyle(KitColor.secondaryText)
            Text(product.currency.code)
                .font(.caption.bold())
                .foregroundStyle(KitColor.green)
        }
    }

    @ViewBuilder
    private var accountField: some View {
        Group {
            if service == .airtime {
                HStack(spacing: 8) {
                    Text("+256")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                    TextField("7XX XXX XXX", text: Binding(
                        get: { UgandaMobileMoneyPhone.spacedNationalDigits(from: account) },
                        set: {
                            account = UgandaMobileMoneyPhone.nationalDigits(from: $0)
                            flow.clearPaymentError()
                        }
                    ))
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .font(.body.monospacedDigit())
                }
            } else {
                TextField(product.accountHint, text: Binding(
                    get: { account },
                    set: {
                        account = $0
                        flow.clearPaymentError()
                    }
                ))
            }
        }
        .padding(17)
        .kitGlass(cornerRadius: 18)
    }

    private var presetAmounts: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                ForEach(["1000", "2000", "5000", "10000", "20000"], id: \.self) { value in
                    Button(KitMoney.amount(value, scale: 0)) {
                        amount = value
                        flow.clearPaymentError()
                    }
                    .font(.caption.bold())
                    .foregroundStyle(amount == value ? .white : KitColor.primaryText)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(amount == value ? KitColor.green : KitColor.paleGreen, in: Capsule())
                }
            }
        }
    }

    private var amountField: some View {
        KitAmountTextField(
            "Amount (\(product.currency.code))",
            value: $amount,
            mode: product.requiresWholeUGXRukaPayAmount
                ? .whole
                : .decimal(maximumFractionDigits: Int(product.currency.scale) ?? 2)
        )
        .onChange(of: amount) { _, _ in flow.clearPaymentError() }
        .padding(17)
        .kitGlass(cornerRadius: 18)
    }

    private func quoteReview(_ quote: ProviderQuoteDTO) -> some View {
        ScrollView {
            VStack(spacing: 17) {
                Label("Review exact total", systemImage: "checkmark.shield.fill")
                    .font(.title2.bold())
                    .foregroundStyle(KitColor.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 7) {
                    Text(product.customerFacingName).font(.headline).foregroundStyle(KitColor.primaryText)
                    Text(quote.accountDisplay ?? account)
                        .font(.subheadline)
                        .foregroundStyle(KitColor.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(17)
                .kitGlass(cornerRadius: 20, shadow: false)

                VStack(spacing: 13) {
                    quoteAmountRow("Payment amount", quote.amount, currency: quote.currency)
                    Divider()
                    quoteAmountRow(
                        CustomerFacingPaymentCopy.transactionFeeTitle,
                        quote.fee,
                        currency: quote.currency
                    )
                    Divider()
                    quoteAmountRow("Total from Kit Pay wallet", quote.total, currency: quote.currency, emphasized: true)
                }
                .padding(18)
                .kitGlass(cornerRadius: 22)

                Text("Approval is bound to the exact payment, transaction fee, total, and wallet shown here.")
                    .font(.caption)
                    .foregroundStyle(KitColor.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let requirement = topUpRequirement(for: quote) {
                    WalletShortfallNotice(requirement: requirement) {
                        topUpRequest = requirement
                    }
                    .padding(18)
                    .kitGlass(cornerRadius: 22)
                }

                approvalControl

                if quote.isExpired {
                    ProviderInlineError(message: "This quote expired. Review the latest transaction fee and total.")
                } else if let error = flow.errorMessage {
                    ProviderInlineError(message: error)
                }

                Button {
                    Task {
                        if let created = await flow.submitQuotedPurchase(
                            service: service,
                            product: product,
                            wallet: app.selectedWallet,
                            quote: quote,
                            clientReference: clientReference,
                            pin: pin,
                            permitted: permitted,
                            online: app.isOnline,
                            authorization: { purpose, intent, pin, reason in
                                try await app.authorizeFinancialStepUp(
                                    purpose: purpose,
                                    intent: intent,
                                    pin: pin,
                                    reason: reason
                                )
                            }
                        ) {
                            operation = created
                            await app.refresh()
                        } else {
                            await offerTopUpIfServerFoundBalanceShort()
                        }
                    }
                } label: {
                    if flow.isSubmitting {
                        ProgressView().tint(.white).frame(maxWidth: .infinity)
                    } else {
                        Label(
                            service == .bill ? "Approve and pay bill" : "Approve and buy airtime",
                            systemImage: app.financialApprovalUsesBiometrics
                                ? app.biometricSymbolName
                                : "lock.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(KitPrimaryButtonStyle())
                .disabled(
                    flow.isSubmitting || quote.isExpired || !permitted || !app.isOnline
                        || clientReference.isEmpty
                        || topUpRequirement(for: quote) != nil
                        || (!app.financialApprovalUsesBiometrics && pin.count != 4)
                )

                Button("Edit payment details") { resetReview() }
                    .font(.subheadline.bold())
                    .foregroundStyle(KitColor.green)
                    .disabled(flow.isSubmitting)
            }
            .padding(22)
        }
    }

    @ViewBuilder
    private var approvalControl: some View {
        if app.financialApprovalUsesBiometrics {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Approve with \(app.biometricDisplayName)")
                        .font(.headline)
                        .foregroundStyle(KitColor.primaryText)
                    Text("Kit Pay will authorize only the exact total shown above.")
                        .font(.caption)
                        .foregroundStyle(KitColor.secondaryText)
                }
            } icon: {
                Image(systemName: app.biometricSymbolName)
                    .font(.title2)
                    .foregroundStyle(KitColor.green)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .kitGlass(cornerRadius: 18, shadow: false)
        } else {
            SecureField("4-digit wallet PIN", text: $pin)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .padding(17)
                .kitGlass(cornerRadius: 18)
                .onChange(of: pin) { _, value in
                    pin = String(value.filter(\.isNumber).prefix(4))
                }
            Text("Your PIN authorizes only the exact quote and total shown above.")
                .font(.caption)
                .foregroundStyle(KitColor.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func operationResult(_ operation: ProviderOperationDTO) -> some View {
        let presentation = ProviderOperationPresentation(status: operation.status)
        return VStack(spacing: 18) {
            Spacer()
            Image(systemName: presentation.icon)
                .font(.system(size: 38, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 88, height: 88)
                .background(presentation.color.gradient, in: Circle())
            Text(presentation.title)
                .font(.largeTitle.bold())
                .foregroundStyle(KitColor.primaryText)
            Text(displayAmount(operation.total, currency: operation.currency))
                .font(.system(size: 34, weight: .heavy, design: .rounded))
                .foregroundStyle(KitColor.primaryText)
            Text(presentation.message)
                .multilineTextAlignment(.center)
                .foregroundStyle(KitColor.secondaryText)
            quoteAmountRow(
                CustomerFacingPaymentCopy.transactionFeeTitle,
                operation.fee,
                currency: operation.currency
            )
            .padding(16)
            .kitGlass(cornerRadius: 18, shadow: false)
            if let reference = operation.providerReference ?? operation.clientReference {
                Text("Ref \(reference)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            if !operation.isTerminal {
                if flow.isPollingOperation(id: operation.id) {
                    ProgressView("Checking payment status…")
                        .font(.caption)
                        .tint(KitColor.green)
                } else {
                    VStack(spacing: 8) {
                        Text("This payment is still awaiting confirmation.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Check status again") {
                            flow.resumeOperationPolling(id: operation.id)
                        }
                        .font(.subheadline.bold())
                        .foregroundStyle(KitColor.green)
                    }
                }
            }
            Spacer()
        }
        .padding(28)
    }

    private func quoteAmountRow(
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

    private func displayAmount(_ amount: String, currency: CurrencyDTO) -> String {
        KitMoney.formatted(amount, currency: currency, trimZeroFraction: true)
    }

    private func resetReview() {
        quote = nil
        clientReference = ""
        pin = ""
        flow.clearPaymentError()
    }

    private var productRange: String {
        ProviderAmountRangeCopy.text(for: product)
    }
}

private struct ProviderInlineError: View {
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

private struct ProviderOperationPresentation {
    let title: String
    let message: String
    let icon: String
    let color: Color

    init(status: String) {
        switch status.lowercased() {
        case "succeeded":
            title = "Payment complete"
            message = "This payment was confirmed successfully."
            icon = "checkmark"
            color = KitColor.green
        case "failed":
            title = "Payment failed"
            message = "This payment was not completed. No offline success was recorded."
            icon = "xmark"
            color = .red
        case "reversed":
            title = "Payment reversed"
            message = "This payment was reversed. Kit Pay keeps the final status visible for your records."
            icon = "arrow.uturn.backward"
            color = .orange
        default:
            title = "Payment pending"
            message = "Kit Pay submitted this payment online and is awaiting confirmation."
            icon = "clock.fill"
            color = .orange
        }
    }
}

private enum ProviderFlowError: LocalizedError {
    case quoteMismatch
    case quoteExpired
    case operationMismatch
    case invalidStepUp

    var errorDescription: String? {
        switch self {
        case .quoteMismatch:
            "The payment quote does not match this exact payment. Nothing was submitted."
        case .quoteExpired:
            "This payment quote expired. Review the latest transaction fee and total before approving."
        case .operationMismatch:
            "We couldn't confirm the payment response. Check its status before trying again."
        case .invalidStepUp:
            "We couldn't approve this payment. Review it and try again."
        }
    }
}
