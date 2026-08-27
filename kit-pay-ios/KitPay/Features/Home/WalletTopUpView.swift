import SwiftUI

enum WalletTopUpPresentation {
    /// Re-opens an approval that was interrupted by a top-up.
    ///
    /// The two sheets hang off the same view, so the payment's confirmation cannot be presented
    /// until the top-up sheet has finished leaving — SwiftUI drops the second presentation
    /// otherwise, and the customer is left staring at the screen they started from.
    static func afterDismissal(_ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            work()
        }
    }
}

/// The insufficient-balance line, wherever a payment is blocked: what the shortfall is, and the
/// one button that resolves it. Deliberately unstyled so each rail can drop it into its own layout
/// — a wallet card, a Form section — without looking bolted on.
struct WalletShortfallNotice: View {
    let requirement: WalletTopUpRequirement
    let topUp: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(requirement.summary)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(KitColor.primaryText)
                    Text("Top up \(requirement.displaySuggestedTopUp) and approve this payment straight after.")
                        .font(.caption)
                        .foregroundStyle(KitColor.secondaryText)
                }
                .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
            }
            Button {
                topUp()
            } label: {
                Label("Top up \(requirement.displaySuggestedTopUp)", systemImage: "plus.circle")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(KitColor.green)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The way out of "insufficient balance".
///
/// A payment that the wallet cannot cover used to end at a red line of text, leaving the customer
/// to work out the difference, leave the payment, find the add-money screen, guess an amount, and
/// start over. This sheet does that work instead: it says what the shortfall is, offers the rounded
/// top-up, collects it over mobile money — the only rail that moves money into Kit Pay — waits for
/// the balance to actually land, and hands control back so the original payment can be approved.
///
/// Every rail that debits the wallet (internal transfers, mobile money payouts, bank transfers)
/// presents this same sheet, so the recovery is identical wherever the customer hit the wall.
struct WalletTopUpView: View {
    /// Where the customer is in the recovery.
    private enum Stage: Equatable {
        case choosing
        /// The collection was authorized; the money has not arrived yet.
        case waiting
        case covered
        /// Still not covered after a long wait. The request may yet land — nothing is cancelled.
        case timedOut
    }

    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    let requirement: WalletTopUpRequirement
    /// True once the wallet covers the blocked payment, so the caller can re-open its approval.
    let completion: (Bool) -> Void

    @StateObject private var model = MobileMoneyViewModel()
    @State private var stage: Stage = .choosing
    @State private var selectedAccountID = ""
    @State private var addingAccount = false
    @State private var collecting = false
    @State private var didFinish = false

    private var permitted: Bool { app.capabilities?.enablesMobileMoney == true }

    /// The wallet the blocked payment debits — not necessarily the selected one by the time the
    /// customer gets here.
    private var wallet: Wallet? {
        app.state.wallets.first { $0.id == requirement.walletID }
    }

    private var eligibleAccounts: [MobileMoneyAccountDTO] {
        model.accounts.filter { $0.isEligible(for: .addMoney) }
    }

    /// Shown at the top of the collection form so the customer can see why the amount is already
    /// filled in, and why the transaction fee sits on top of it rather than inside it.
    private var collectionNotice: String {
        "\(requirement.summary) This tops up \(requirement.displaySuggestedTopUp) in full — "
            + "the mobile money transaction fee is added on top so your wallet is credited the "
            + "whole amount."
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    shortfallCard
                    switch stage {
                    case .choosing:
                        chooseSection
                    case .waiting:
                        waitingCard
                    case .covered:
                        coveredCard
                    case .timedOut:
                        timedOutCard
                    }
                }
                .padding(20)
                .padding(.bottom, 24)
            }
            .background(KitColor.canvas.ignoresSafeArea())
            .navigationTitle("Top up to continue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(stage == .covered ? "Close" : "Cancel") { finish(covered: stage == .covered) }
                }
            }
            .task(id: "\(permitted)-\(app.isOnline)") {
                await model.load(permitted: permitted, online: app.isOnline)
                if selectedAccountID.isEmpty {
                    selectedAccountID = eligibleAccounts.first?.id ?? ""
                }
            }
            .onChange(of: model.accounts) { _, _ in
                // A number verified from the sheet below should be the one that is used.
                if selectedAccountID.isEmpty || !eligibleAccounts.contains(where: { $0.id == selectedAccountID }) {
                    selectedAccountID = eligibleAccounts.last?.id ?? ""
                }
            }
            .task(id: stage) { await waitForTopUp() }
            .sheet(isPresented: $addingAccount) {
                AddMobileMoneyAccountView(
                    model: model,
                    permitted: permitted,
                    online: app.isOnline
                )
                .presentationBackground(.ultraThinMaterial)
            }
            .sheet(isPresented: $collecting) {
                MobileMoneyOperationView(
                    model: model,
                    flow: .addMoney,
                    wallet: wallet,
                    permitted: permitted,
                    online: app.isOnline,
                    initialAccountID: selectedAccountID,
                    initialAmount: requirement.suggestedTopUpAPIAmount,
                    initialReceiveFullAmount: true,
                    notice: collectionNotice
                ) {
                    await MainActor.run { stage = .waiting }
                }
                .environmentObject(app)
                .presentationBackground(.ultraThinMaterial)
            }
        }
        .interactiveDismissDisabled(stage == .waiting)
    }

    private var shortfallCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("Short by \(requirement.displayShortfall)")
                    .font(.title3.bold())
                    .foregroundStyle(KitColor.primaryText)
            } icon: {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
            }
            Text("Add \(requirement.displaySuggestedTopUp) to your Kit Pay wallet and you can approve this payment straight after.")
                .font(.subheadline)
                .foregroundStyle(KitColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 6) {
                amountRow("This payment needs", requirement.displayRequired)
                Divider()
                amountRow("Your balance", requirement.displayAvailable)
                Divider()
                amountRow("Top up", requirement.displaySuggestedTopUp, emphasized: true)
            }
            .padding(.top, 2)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .kitGlass(cornerRadius: 24, tint: KitColor.paleGreen)
    }

    @ViewBuilder
    private var chooseSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Top up from")
                .font(.headline)
                .foregroundStyle(KitColor.primaryText)
            if !permitted {
                explanation("Mobile money is not enabled for this Kit Pay account. Add money another way, then come back to this payment.")
            } else if !app.isOnline {
                explanation("Connect to the internet to top up.")
            } else if model.isLoading, model.accounts.isEmpty {
                ProgressView().frame(maxWidth: .infinity)
            } else if eligibleAccounts.isEmpty {
                explanation("Add and verify an MTN or Airtel number to top up from.")
            } else {
                VStack(spacing: 0) {
                    ForEach(eligibleAccounts) { account in
                        Button {
                            selectedAccountID = account.id
                        } label: {
                            accountRow(account)
                        }
                        .buttonStyle(.plain)
                        if account.id != eligibleAccounts.last?.id {
                            Divider()
                        }
                    }
                }
            }
            if let error = model.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            Button {
                addingAccount = true
            } label: {
                Label("Use another number", systemImage: "plus.circle")
                    .font(.subheadline.weight(.semibold))
            }
            .disabled(!permitted || !app.isOnline)

            Button {
                collecting = true
            } label: {
                Label(
                    "Top up \(requirement.displaySuggestedTopUp)",
                    systemImage: app.financialApprovalUsesBiometrics ? app.biometricSymbolName : "lock.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(KitColor.green)
            .controlSize(.large)
            .disabled(!permitted || !app.isOnline || selectedAccountID.isEmpty)
            Text("You will approve the top-up on your phone, then approve the payment itself.")
                .font(.caption)
                .foregroundStyle(KitColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .kitGlass(cornerRadius: 24)
    }

    private var waitingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ProgressView()
                Text("Waiting for your top-up")
                    .font(.headline)
                    .foregroundStyle(KitColor.primaryText)
            }
            Text("Approve the mobile money request on your phone if you have not already. Kit Pay is watching your balance and will bring you back to the payment the moment the money lands.")
                .font(.subheadline)
                .foregroundStyle(KitColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .kitGlass(cornerRadius: 24)
    }

    private var coveredCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("Balance topped up")
                    .font(.headline)
                    .foregroundStyle(KitColor.primaryText)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(KitColor.green)
            }
            Text("Your wallet now covers this payment.")
                .font(.subheadline)
                .foregroundStyle(KitColor.secondaryText)
            Button {
                finish(covered: true)
            } label: {
                Text("Continue to payment").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(KitColor.green)
            .controlSize(.large)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .kitGlass(cornerRadius: 24, tint: KitColor.paleGreen)
    }

    private var timedOutCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The top-up has not arrived yet")
                .font(.headline)
                .foregroundStyle(KitColor.primaryText)
            Text("Mobile money requests can take a few minutes. Nothing was cancelled — check again, or close this and approve the payment once the money shows in your balance.")
                .font(.subheadline)
                .foregroundStyle(KitColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Button("Check again") { stage = .waiting }
                .buttonStyle(.borderedProminent)
                .tint(KitColor.green)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            Button("Top up again") { stage = .choosing }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .kitGlass(cornerRadius: 24)
    }

    private func accountRow(_ account: MobileMoneyAccountDTO) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(KitColor.navy)
                .frame(width: 40, height: 40)
                .background(KitColor.paleGreen, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(account.accountName ?? account.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KitColor.primaryText)
                Text("\(account.network.name) • \(account.phoneNumberMasked)")
                    .font(.caption)
                    .foregroundStyle(KitColor.secondaryText)
            }
            Spacer(minLength: 8)
            Image(systemName: selectedAccountID == account.id ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selectedAccountID == account.id ? KitColor.green : .secondary)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selectedAccountID == account.id ? [.isButton, .isSelected] : .isButton)
    }

    private func amountRow(_ title: String, _ value: String, emphasized: Bool = false) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(KitColor.secondaryText)
            Spacer(minLength: 8)
            Text(value)
                .font(emphasized ? .subheadline.bold().monospacedDigit() : .subheadline.monospacedDigit())
                .foregroundStyle(emphasized ? KitColor.green : KitColor.primaryText)
        }
    }

    private func explanation(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(KitColor.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Polls the wallet until the top-up lands. Collections settle out of band — the customer
    /// approves on the handset — so there is nothing to await other than the balance itself.
    @MainActor
    private func waitForTopUp() async {
        guard stage == .waiting else { return }
        if requirement.isCovered(by: wallet) {
            stage = .covered
            return
        }
        // Roughly three minutes; a mobile money prompt that is never answered simply expires.
        for _ in 0..<36 {
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled, stage == .waiting else { return }
            await app.refresh()
            guard !Task.isCancelled, stage == .waiting else { return }
            if requirement.isCovered(by: wallet) {
                stage = .covered
                return
            }
        }
        if stage == .waiting { stage = .timedOut }
    }

    private func finish(covered: Bool) {
        guard !didFinish else { return }
        didFinish = true
        completion(covered)
        dismiss()
    }
}
