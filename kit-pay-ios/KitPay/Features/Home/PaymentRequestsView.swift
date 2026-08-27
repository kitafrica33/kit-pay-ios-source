import Foundation
import SwiftUI

@MainActor
final class PaymentRequestsViewModel: ObservableObject {
    @Published private(set) var items: [PaymentRequestDTO] = []
    @Published private(set) var isLoading = false
    @Published private(set) var actionRequestId: String?
    @Published var errorMessage: String?

    private let api: APIClient
    private var payIdempotencyKeys: [String: String] = [:]
    private var cancelIdempotencyKeys: [String: String] = [:]

    init(api: APIClient = .shared) {
        self.api = api
    }

    func load(isOnline: Bool) async {
        guard !isLoading else { return }
        guard isOnline else {
            errorMessage = "Connect to the internet to load payment requests. Financial request state is never guessed offline."
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            items = try await api.paymentRequests().items
        } catch {
            errorMessage = message(for: error)
        }
    }

    /// Reloads server-authoritative state before an encrypted chat request can open the PIN flow.
    func resolveChatRequest(
        _ descriptor: KitPaymentMessage,
        isOnline: Bool
    ) async -> PaymentRequestDTO? {
        guard !isLoading else {
            errorMessage = "Wait for the current payment-request refresh to finish."
            return nil
        }
        guard isOnline else {
            errorMessage = "Connect to the internet to verify this request. Payments cannot be queued offline."
            return nil
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            items = try await api.paymentRequests().items
            switch KitPaymentRequestResolutionPolicy.resolve(descriptor, in: items) {
            case .match(let request):
                return request
            case .missing:
                errorMessage = "This payment request is not available in your account. Nothing was paid."
            case .mismatch:
                errorMessage = "The encrypted chat amount or currency does not match Kit Pay's request. Nothing was paid."
            }
        } catch {
            errorMessage = message(for: error)
        }
        return nil
    }

    /// Approval routes through `AppModel.authorizeFinancialStepUp`, which signs with the
    /// Secure Enclave when biometrics are available and otherwise verifies the wallet PIN.
    func pay(
        _ request: PaymentRequestDTO,
        from wallet: Wallet,
        pin: String,
        policy: PaymentRequestPolicy,
        isOnline: Bool,
        authorize: KitFinancialStepUpAuthorization
    ) async -> Bool {
        guard actionRequestId == nil else { return false }
        guard isOnline else {
            errorMessage = "Connect to the internet to pay this request. Payments cannot be queued offline."
            return false
        }
        guard policy.canPay(request, from: wallet) else {
            errorMessage = "This request is not eligible for payment from this account."
            return false
        }

        actionRequestId = request.id
        errorMessage = nil
        defer { actionRequestId = nil }
        let operationId = "\(request.id):\(wallet.id)"
        let key = payIdempotencyKeys[operationId]
            ?? "ios-payment-request-pay-\(UUID().uuidString.lowercased())"
        payIdempotencyKeys[operationId] = key

        do {
            let verification = try await authorize(
                "payment_request",
                PaymentRequestPolicy.payIntent(for: request, sourceWalletId: wallet.id),
                pin,
                "Approve paying this request"
            )
            let paid = try await api.payPaymentRequest(
                requestId: request.id,
                sourceWalletId: wallet.id,
                idempotencyKey: key,
                stepUpToken: verification.stepUpToken
            )
            guard paid.id == request.id,
                  paid.knownStatus == .paid,
                  paid.walletTransactionId?.isEmpty == false
            else { throw PaymentRequestFlowError.unconfirmedPayment }

            upsert(paid)
            payIdempotencyKeys[operationId] = nil
            return true
        } catch {
            errorMessage = message(for: error)
            return false
        }
    }

    func cancel(
        _ request: PaymentRequestDTO,
        policy: PaymentRequestPolicy,
        isOnline: Bool
    ) async -> Bool {
        guard actionRequestId == nil else { return false }
        guard isOnline else {
            errorMessage = "Connect to the internet to cancel this request. Cancellations cannot be queued offline."
            return false
        }
        guard policy.canCancel(request) else {
            errorMessage = "Only your pending payment requests can be cancelled."
            return false
        }

        actionRequestId = request.id
        errorMessage = nil
        defer { actionRequestId = nil }
        let key = cancelIdempotencyKeys[request.id]
            ?? "ios-payment-request-cancel-\(UUID().uuidString.lowercased())"
        cancelIdempotencyKeys[request.id] = key

        do {
            let cancelled = try await api.cancelPaymentRequest(requestId: request.id, idempotencyKey: key)
            guard cancelled.id == request.id, cancelled.knownStatus == .cancelled else {
                throw PaymentRequestFlowError.unconfirmedCancellation
            }
            upsert(cancelled)
            cancelIdempotencyKeys[request.id] = nil
            return true
        } catch {
            errorMessage = message(for: error)
            return false
        }
    }

    private func upsert(_ request: PaymentRequestDTO) {
        if let index = items.firstIndex(where: { $0.id == request.id }) {
            items[index] = request
        } else {
            items.insert(request, at: 0)
        }
    }

    private func message(for error: Error) -> String {
        let message = (error as? APIErrorPayload)?.message ?? error.localizedDescription
        return CustomerFacingPaymentCopy.neutralizedServiceMessage(message)
    }
}

private enum PaymentRequestFlowError: LocalizedError {
    case unconfirmedPayment
    case unconfirmedCancellation

    var errorDescription: String? {
        switch self {
        case .unconfirmedPayment:
            "Kit did not confirm this payment with a transaction. Check the request before trying again."
        case .unconfirmedCancellation:
            "Kit did not confirm cancellation. Refresh the request before trying again."
        }
    }
}

struct PaymentRequestsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var requests = PaymentRequestsViewModel()
    @StateObject private var createFlow = WalletFlowModel()
    @State private var selection: RequestListSelection = .incoming
    @State private var showingCreate = false
    @State private var payingRequest: PaymentRequestDTO?
    @State private var cancellingRequest: PaymentRequestDTO?

    private var policy: PaymentRequestPolicy {
        PaymentRequestPolicy(
            features: model.capabilities?.features,
            currentUserId: model.profile?.id,
            ownedWalletIds: Set(model.state.wallets.map(\.id))
        )
    }

    private var visibleItems: [PaymentRequestDTO] {
        requests.items.filter {
            switch (selection, policy.direction(of: $0)) {
            case (.incoming, .incoming), (.outgoing, .outgoing): true
            default: false
            }
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                summaryCard
                Picker("Request direction", selection: $selection) {
                    Text("Incoming").tag(RequestListSelection.incoming)
                    Text("Sent").tag(RequestListSelection.outgoing)
                }
                .pickerStyle(.segmented)

                if !model.isOnline { offlineNotice }
                if let errorMessage = requests.errorMessage { errorNotice(errorMessage) }

                if requests.isLoading && requests.items.isEmpty {
                    ProgressView("Loading requests…").padding(.vertical, 48)
                } else if visibleItems.isEmpty {
                    ContentUnavailableView(
                        selection == .incoming ? "No incoming requests" : "No sent requests",
                        systemImage: selection == .incoming ? "tray" : "paperplane",
                        description: Text(emptyDescription)
                    )
                    .padding(.vertical, 34)
                    .frame(maxWidth: .infinity)
                    .kitGlass(cornerRadius: 24)
                } else {
                    ForEach(visibleItems) { request in
                        requestCard(request)
                    }
                }
            }
            .padding(20)
        }
        .background(KitColor.canvas.ignoresSafeArea())
        .navigationTitle("Payment requests")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingCreate = true } label: { Image(systemName: "plus") }
                    .disabled(
                        !model.appReviewDemoMutationsAllowed
                            || !policy.paymentRequestsEnabled
                            || !model.isOnline
                    )
                    .accessibilityLabel("Create payment request")
            }
        }
        .task {
            async let requestLoad: Void = requests.load(isOnline: model.isOnline)
            await model.loadContactDirectory()
            createFlow.useSyncedContacts(model.contactDirectory)
            _ = await requestLoad
        }
        .refreshable { await requests.load(isOnline: model.isOnline) }
        .sheet(isPresented: $showingCreate, onDismiss: {
            Task { await requests.load(isOnline: model.isOnline) }
        }) {
            NavigationStack { RequestMoneyView(flow: createFlow).environmentObject(model) }
                .presentationBackground(.ultraThinMaterial)
        }
        .sheet(item: $payingRequest) { request in
            PaymentRequestPINView(
                request: request,
                isSubmitting: requests.actionRequestId == request.id,
                errorMessage: requests.errorMessage
            ) { pin in
                guard let wallet = model.selectedWallet else { return false }
                let paid = await requests.pay(
                    request,
                    from: wallet,
                    pin: pin,
                    policy: policy,
                    isOnline: model.isOnline,
                    authorize: model.authorizeFinancialStepUp
                )
                if paid { await model.refresh() }
                return paid
            }
            .environmentObject(model)
            .onAppear {
                // A stale load error must not surface inside "Confirm payment".
                requests.errorMessage = nil
            }
            .presentationBackground(.ultraThinMaterial)
        }
        .alert("Cancel payment request?", isPresented: Binding(
            get: { cancellingRequest != nil },
            set: { if !$0 { cancellingRequest = nil } }
        ), presenting: cancellingRequest) { request in
            Button("Keep request", role: .cancel) { cancellingRequest = nil }
            Button("Cancel request", role: .destructive) {
                cancellingRequest = nil
                Task { _ = await requests.cancel(request, policy: policy, isOnline: model.isOnline) }
            }
        } message: { request in
            Text("Cancel the request for \(KitMoney.formatted(request.amount, currency: request.currency))? This cannot be undone.")
        }
    }

    private var summaryCard: some View {
        HStack(spacing: 16) {
            Image(systemName: "doc.text.fill")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(KitColor.green.gradient, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text("Request and pay securely").font(.headline).foregroundStyle(KitColor.primaryText)
                Text(
                    model.financialApprovalUsesBiometrics
                        ? "\(model.biometricDisplayName) approval is bound to the exact request amount."
                        : "PIN approval is bound to the exact request amount."
                )
                .font(.caption)
                .foregroundStyle(KitColor.secondaryText)
            }
            Spacer()
        }
        .padding(18)
        .kitGlass(cornerRadius: 24, tint: KitColor.paleGreen)
    }

    private var offlineNotice: some View {
        Label("Offline — request payments and changes are unavailable.", systemImage: "wifi.slash")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.orange)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
    }

    private func errorNotice(_ message: String) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(.red)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }

    private func requestCard(_ request: PaymentRequestDTO) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(request.note?.trimmedNonempty ?? "Payment request")
                        .font(.headline)
                        .foregroundStyle(KitColor.primaryText)
                    MarqueeText(
                        text: counterpartyLabel(for: request),
                        font: .caption,
                        color: KitColor.secondaryText
                    )
                }
                Spacer()
                statusBadge(request)
            }

            Text(KitMoney.formatted(request.amount, currency: request.currency))
                .font(.system(size: 27, weight: .heavy, design: .rounded))
                .foregroundStyle(KitColor.primaryText)

            if let date = request.createdAt?.paymentRequestDisplayDate {
                Text(date).font(.caption).foregroundStyle(.secondary)
            }

            if let wallet = model.selectedWallet, policy.canPay(request, from: wallet) {
                Button {
                    guard model.isOnline else {
                        requests.errorMessage = "Connect to the internet to pay this request."
                        return
                    }
                    payingRequest = request
                } label: {
                    if requests.actionRequestId == request.id {
                        ProgressView().tint(.white).frame(maxWidth: .infinity)
                    } else {
                        Label("Pay request", systemImage: "lock.shield.fill").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(KitPrimaryButtonStyle())
                .disabled(
                    !model.appReviewDemoMutationsAllowed
                        || !model.isOnline
                        || requests.actionRequestId != nil
                )
            } else if policy.canCancel(request) {
                Button(role: .destructive) { cancellingRequest = request } label: {
                    Label("Cancel request", systemImage: "xmark.circle").frame(maxWidth: .infinity)
                }
                .buttonStyle(KitSecondaryButtonStyle())
                .disabled(
                    !model.appReviewDemoMutationsAllowed
                        || !model.isOnline
                        || requests.actionRequestId != nil
                )
            }
        }
        .padding(18)
        .kitGlass(cornerRadius: 24)
    }

    private func statusBadge(_ request: PaymentRequestDTO) -> some View {
        Text(request.status.capitalized)
            .font(.caption2.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(statusColor(request).opacity(0.14), in: Capsule())
            .foregroundStyle(statusColor(request))
    }

    private func statusColor(_ request: PaymentRequestDTO) -> Color {
        switch request.knownStatus {
        case .pending: .orange
        case .paid: KitColor.green
        case .cancelled, .expired: .secondary
        case nil: .red
        }
    }

    private func counterpartyLabel(for request: PaymentRequestDTO) -> String {
        switch policy.direction(of: request) {
        case .incoming: return "Requested from you"
        case .outgoing:
            guard let id = request.requestedFromUserId else { return "Created by you" }
            let name = createFlow.contacts.first(where: { $0.id == id })?.name
            return "Requested from \(name ?? "a Kit Pay user")"
        case .unknown: return "Request details unavailable"
        }
    }

    private var emptyDescription: String {
        if !model.isOnline { return "Connect to load authoritative request status." }
        return selection == .incoming
            ? "Requests addressed to you will appear here."
            : "Tap + to request a payment from a Kit Pay contact."
    }
}

private enum RequestListSelection: Hashable {
    case incoming
    case outgoing
}

struct PaymentRequestPINView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let request: PaymentRequestDTO
    let isSubmitting: Bool
    let errorMessage: String?
    let submit: (String) async -> Bool
    @State private var pin = ""
    /// Non-nil while the customer is topping up to cover this request.
    @State private var topUpRequest: WalletTopUpRequirement?

    /// Paying a request moves money between Kit Pay wallets, so there is no transaction fee and
    /// the debit is the requested amount itself.
    private var topUpRequirement: WalletTopUpRequirement? {
        WalletTopUpPolicy.requirement(
            wallet: model.selectedWallet,
            debitAPIAmount: request.amount
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(KitColor.green)
                        .frame(width: 88, height: 88)
                        .kitGlass(cornerRadius: 28, tint: KitColor.paleGreen)
                    Text("Approve exact payment").font(.title2.bold()).foregroundStyle(KitColor.primaryText)
                    Text(KitMoney.formatted(request.amount, currency: request.currency))
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                        .foregroundStyle(KitColor.primaryText)
                    if let note = request.note?.trimmedNonempty {
                        Text(note).foregroundStyle(KitColor.secondaryText)
                    }
                    if model.financialApprovalUsesBiometrics {
                        Label {
                            Text("Approve with \(model.biometricDisplayName). Your approval covers only this request, source wallet, amount and currency.")
                                .font(.footnote)
                                .foregroundStyle(KitColor.secondaryText)
                        } icon: {
                            Image(systemName: model.biometricSymbolName)
                                .foregroundStyle(KitColor.green)
                        }
                        .padding(17)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .kitGlass(cornerRadius: 18, tint: KitColor.paleGreen, shadow: false)
                    } else {
                        SecureField("4-digit wallet PIN", text: $pin)
                            .keyboardType(.numberPad)
                            .textContentType(.password)
                            .multilineTextAlignment(.center)
                            .font(.title2.monospacedDigit())
                            .padding(17)
                            .kitGlass(cornerRadius: 18)
                            .onChange(of: pin) { _, value in
                                pin = String(value.filter(\.isNumber).prefix(4))
                            }
                        Text("Your PIN authorizes only this request, source wallet, amount and currency.")
                            .font(.caption)
                            .foregroundStyle(KitColor.secondaryText)
                            .multilineTextAlignment(.center)
                    }
                    if let errorMessage {
                        Text(errorMessage).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                    }
                    if let requirement = topUpRequirement {
                        WalletShortfallNotice(requirement: requirement) {
                            topUpRequest = requirement
                        }
                        .padding(17)
                        .kitGlass(cornerRadius: 18)
                    }
                    Button {
                        Task {
                            if await submit(pin) {
                                pin = ""
                                dismiss()
                            }
                        }
                    } label: {
                        if isSubmitting {
                            ProgressView().tint(.white).frame(maxWidth: .infinity)
                        } else {
                            Label(
                                "Pay \(KitMoney.formatted(request.amount, currency: request.currency))",
                                systemImage: model.financialApprovalUsesBiometrics
                                    ? model.biometricSymbolName
                                    : "checkmark.shield.fill"
                            )
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(KitPrimaryButtonStyle())
                    .disabled(
                        !model.appReviewDemoMutationsAllowed
                            || (!model.financialApprovalUsesBiometrics && pin.count != 4)
                            || isSubmitting
                            || topUpRequirement != nil
                    )
                }
                .padding(24)
            }
            .background(KitColor.canvas.ignoresSafeArea())
            .navigationTitle("Confirm payment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } } }
            .interactiveDismissDisabled(isSubmitting)
            .sheet(item: $topUpRequest) { requirement in
                // This screen stays behind the top-up sheet, so the approval simply re-enables
                // itself the moment the balance covers the request.
                WalletTopUpView(requirement: requirement) { _ in }
                    .environmentObject(model)
                    .presentationBackground(.ultraThinMaterial)
            }
        }
    }
}

private extension String {
    var trimmedNonempty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var paymentRequestDisplayDate: String? {
        guard let date = KitServerDateParser.date(from: self) else { return nil }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
