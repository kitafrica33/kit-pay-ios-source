import SwiftUI

private enum HomePaymentFeature {
    case mobileMoney
    case bankTransfer
    case scanQR
}

/// Every Home modal, addressed by one value.
///
/// Home used to chain five separate `.sheet` modifiers on the same view. SwiftUI only guarantees
/// one presentation per view, so the modifiers competed and the first of them — the wallet
/// destinations behind "See all" and a tapped transaction — silently did nothing. One `sheet(item:)`
/// removes the whole class of problem.
private enum HomeModal: Identifiable {
    case wallet(WalletDestination)
    case provider(ProviderFlowEntry)
    case mobileMoney
    case scanQR

    var id: String {
        switch self {
        case let .wallet(destination): "wallet-\(destination.id)"
        case let .provider(entry): "provider-\(entry.id)"
        case .mobileMoney: "mobile-money"
        case .scanQR: "scan-qr"
        }
    }
}

/// Home's full-screen flows, addressed by one value for the same reason as `HomeModal`:
/// SwiftUI guarantees one presentation per view, so a second `fullScreenCover` on the same
/// hierarchy would compete with the first and silently drop.
private enum HomeCover: String, Identifiable {
    case bankTransfer
    case identityVerification

    var id: String { rawValue }
}

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var balancesVisible = true
    @State private var modal: HomeModal?
    @State private var cover: HomeCover?

    var body: some View {
        Group {
            if model.homeAccessGranted {
                homeContent
            } else {
                KitBiometricGateView(
                    symbolName: model.biometricSymbolName,
                    title: "Wallet locked",
                    message: "Use \(model.biometricDisplayName) to open Home, balances, and payments.",
                    errorMessage: model.biometricErrorMessage,
                    isAuthorizing: model.homeBiometricState == .authorizing,
                    buttonTitle: "Open Home",
                    authenticate: { await model.homeDidBecomeActive() }
                )
            }
        }
    }

    private var homeContent: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    header
                    if model.appReviewDemoIsActive {
                        Label(
                            "App Review demo is read-only. Payment and account changes are disabled.",
                            systemImage: "eye.fill"
                        )
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(KitColor.secondaryText)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .kitGlass(cornerRadius: 20, shadow: false)
                    }
                    if model.financialDataAccessGranted {
                        balanceCard
                    } else {
                        identityRequiredCard
                    }
                    // Financial actions stay discoverable before KYC. Their shared route guard
                    // opens identity verification instead of silently removing the product.
                    quickServices
                    if let checklist = starterChecklist {
                        starterChecklistSection(checklist)
                    }
                    if model.financialDataAccessGranted {
                        recentActivity
                    } else {
                        lockedRecentActivity
                    }
                }
                .padding(.horizontal, 18)
                // No extra bottom padding: the floating menu already reserves its own scroll
                // clearance as a safe-area inset. Adding more here only pushes the last card
                // further from the glass and makes the page look like it ends early.
                .padding(.bottom, RootTabBarLayoutPolicy.pageBottomPadding)
            }
            .rootTabBarScrollClearance()
            .background(KitColor.canvas)
            .refreshable { await model.refresh(userInitiated: true) }
            .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(item: $modal) { modal in
            switch modal {
            case let .wallet(destination):
                WalletFlowContainer(destination: destination)
                    .environmentObject(model)
            case let .provider(entry):
                ProviderFlowContainer(entry: entry)
                    .environmentObject(model)
            case .mobileMoney:
                MobileMoneyView().environmentObject(model)
                    .presentationBackground(.ultraThinMaterial)
            case .scanQR:
                MerchantQRPaymentView().environmentObject(model)
                    .presentationBackground(.ultraThinMaterial)
            }
        }
        .fullScreenCover(item: $cover) { cover in
            switch cover {
            case .bankTransfer:
                BankTransferView().environmentObject(model)
            case .identityVerification:
                // Identity verification is a substantive flow: a true full screen with its own
                // close affordance, never a half-height sheet.
                NavigationStack {
                    KYCView()
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button {
                                    self.cover = nil
                                } label: {
                                    Label("Close", systemImage: "xmark")
                                }
                                .accessibilityLabel("Close identity verification")
                            }
                        }
                }
                .environmentObject(model)
            }
        }
        .onAppear { applyWalletClaimNavigation() }
        .onChange(of: model.walletClaimNavigationRequest) { _, _ in
            applyWalletClaimNavigation()
        }
        .onChange(of: model.homeAccessGranted) { _, granted in
            if granted { applyWalletClaimNavigation() }
        }
        .onChange(of: model.financialDataAccessGranted) { _, granted in
            if granted { applyWalletClaimNavigation() }
        }
    }

    private func applyWalletClaimNavigation() {
        guard model.homeAccessGranted,
              let request = model.walletClaimNavigationRequest
        else { return }
        guard routeFinancialAccess(requiresMutation: false) else { return }
        modal = .wallet(.transactions)
        model.consumeWalletClaimNavigationRequest(request.id)
    }

    private var header: some View {
        HStack(spacing: 13) {
            RemoteAvatarView(
                name: model.profile?.name ?? "Kit Pay",
                avatarURL: model.profile?.avatarURL,
                size: 54
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(greeting)
                    .font(.subheadline)
                    .foregroundStyle(KitColor.secondaryText)
                Text(model.profile?.name?.split(separator: " ").first.map(String.init) ?? "there")
                    .font(.title2.bold())
                    .foregroundStyle(KitColor.primaryText)
            }
            Spacer()
            ConnectivityPill(isOnline: model.isOnline, queuedCount: model.queuedCount)
        }
        .padding(.top, 12)
    }

    private var balanceCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Wallet balance").foregroundStyle(.white.opacity(0.76))
                Spacer()
                Button { balancesVisible.toggle() } label: {
                    Image(systemName: balancesVisible ? "eye.slash" : "eye")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.82))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(balancesVisible ? "Hide wallet balance" : "Show wallet balance")
            }
            Text(balancesVisible ? formattedBalance : "••••••")
                .font(.system(size: 38, weight: .heavy, design: .rounded))
                .minimumScaleFactor(0.65)
                .lineLimit(1)
                .foregroundStyle(.white)

            HStack(spacing: 10) {
                walletAction("Send", icon: "arrow.up.right", primary: true, destination: .send, available: canSend, needsInternet: true)
                walletAction("Receive", icon: "arrow.down.left", primary: false, destination: .receive, available: canReceive)
                walletAction("Request", icon: "doc.text", primary: false, destination: .request, available: canRequest, needsInternet: true)
            }
        }
        .padding(22)
        .background(
            LinearGradient(
                colors: [KitColor.deepNavy.opacity(0.98), KitColor.navy.opacity(0.92)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(alignment: .topTrailing) {
            Circle().fill(.white.opacity(0.08)).frame(width: 180).blur(radius: 2).offset(x: 65, y: -90)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 32)
                .stroke(.white.opacity(0.22), lineWidth: 0.8)
                .allowsHitTesting(false)
        }
        .shadow(color: KitColor.navy.opacity(0.18), radius: 20, y: 10)
    }

    private var identityRequiredCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button {
                _ = routeFinancialAccess(requiresMutation: false)
            } label: {
                HStack(spacing: 16) {
                    Image(systemName: "person.text.rectangle")
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(.white.opacity(0.14), in: Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Set up wallet access")
                            .font(.headline)
                        Text("Verify your identity before viewing balances or using payments.")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.78))
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white.opacity(0.8))
                }
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens identity verification")

            HStack(spacing: 10) {
                walletAction("Send", icon: "arrow.up.right", primary: true, destination: .send, available: canSend, needsInternet: true)
                walletAction("Receive", icon: "arrow.down.left", primary: false, destination: .receive, available: canReceive)
                walletAction("Request", icon: "doc.text", primary: false, destination: .request, available: canRequest, needsInternet: true)
            }
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [KitColor.deepNavy, KitColor.navy],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 28, style: .continuous)
        )
    }

    private func walletAction(
        _ title: String,
        icon: String,
        primary: Bool,
        destination: WalletDestination,
        available: Bool,
        needsInternet: Bool = false
    ) -> some View {
        Button {
            open(destination, title: title, available: available, needsInternet: needsInternet)
        } label: {
            Label(title, systemImage: icon)
                .font(.subheadline.bold())
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(primary ? KitColor.green : .white.opacity(0.13), in: Capsule())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(
            !available
                || (model.moneyActionAccessRequirement == .readOnly
                    && destination.isAppReviewDemoMutation)
                || (!model.appReviewDemoMutationsAllowed && destination.isAppReviewDemoMutation)
        )
        .opacity(
            !available
                || (model.moneyActionAccessRequirement == .readOnly
                    && destination.isAppReviewDemoMutation)
                || (!model.appReviewDemoMutationsAllowed && destination.isAppReviewDemoMutation)
                ? 0.55 : 1
        )
    }

    private var quickServices: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
            spacing: 12
        ) {
            service("Pay bills", "doc.text.fill", providerEntry: .bills, available: canPayBills)
            service("Airtime", "iphone.gen3", providerEntry: .airtime, available: canBuyAirtime)
            service("Mobile", "iphone.gen3.radiowaves.left.and.right", feature: .mobileMoney, available: canUseMobileMoney)
            service("Bank", "building.columns.fill", feature: .bankTransfer, available: canUseBank)
            service("Scan", "qrcode.viewfinder", feature: .scanQR, available: canUseMerchantQR)
        }
    }

    private func service(
        _ title: String,
        _ icon: String,
        destination: WalletDestination? = nil,
        providerEntry: ProviderFlowEntry? = nil,
        feature: HomePaymentFeature? = nil,
        available: Bool = false
    ) -> some View {
        Button {
            if let destination {
                open(destination, title: title, available: available, needsInternet: true)
            } else if let providerEntry {
                openProvider(providerEntry, title: title, available: available)
            } else if let feature {
                openFeature(feature, title: title, available: available)
            } else {
                model.lastError = "\(title) is not available in this release yet."
            }
        } label: {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(KitColor.primaryText)
                    .frame(width: 46, height: 46)
                    .background(KitColor.paleGreen, in: Circle())
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(KitColor.primaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .kitGlass(cornerRadius: 22)
        }
        .buttonStyle(.plain)
        .disabled(
            !available
                || model.moneyActionAccessRequirement == .readOnly
                || !model.appReviewDemoMutationsAllowed
        )
        .opacity(
            !available
                || model.moneyActionAccessRequirement == .readOnly
                || !model.appReviewDemoMutationsAllowed
                ? 0.55 : 1
        )
    }

    /// Derived entirely from state already in memory: nothing here waits on the network, so
    /// Home renders at full speed whether or not the checklist appears.
    private var starterChecklist: HomeStarterChecklist? {
        HomeStarterChecklistPolicy.checklist(
            // The live KYC endpoint updates model.kycStatus without rewriting the cached
            // profile, so the freshest verdict is read first and the profile is the fallback.
            // account_status deliberately, never the blended `status`: that one is overridden
            // by per-device verification and would un-verify a verified account on a new phone.
            kycStatus: model.kycStatus?.accountStatus ?? model.profile?.kycStatus,
            messages: model.state.messages,
            transactions: model.state.transactions,
            hasConfirmedFirstMessage: model.state.starterFirstMessageAt != nil,
            hasConfirmedFirstTransaction: model.state.starterFirstTransactionAt != nil,
            isDemoActive: model.appReviewDemoIsActive,
            isDemoConversation: model.isReadOnlyAppReviewDemoConversation
        )
    }

    private func starterChecklistSection(_ checklist: HomeStarterChecklist) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Get started")
                    .font(.title2.bold())
                    .foregroundStyle(KitColor.primaryText)
                Spacer()
                Text("\(checklist.completedCount)/\(checklist.totalCount)")
                    .font(.subheadline.bold())
                    .monospacedDigit()
                    .foregroundStyle(KitColor.green)
                    .accessibilityLabel(
                        "\(checklist.completedCount) of \(checklist.totalCount) steps complete"
                    )
            }
            VStack(spacing: 0) {
                ForEach(Array(checklist.entries.enumerated()), id: \.element.step) { index, entry in
                    starterRow(entry)
                    if index < checklist.entries.count - 1 {
                        Divider().padding(.leading, 62)
                    }
                }
            }
            .kitGlass(cornerRadius: 24, shadow: false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Get started checklist")
    }

    @ViewBuilder
    private func starterRow(_ entry: HomeStarterChecklist.Entry) -> some View {
        if entry.isComplete {
            starterRowContent(entry)
        } else {
            Button {
                openStarterStep(entry.step)
            } label: {
                starterRowContent(entry)
            }
            .buttonStyle(.plain)
        }
    }

    private func starterRowContent(_ entry: HomeStarterChecklist.Entry) -> some View {
        HStack(spacing: 13) {
            Image(systemName: starterIcon(entry.step))
                .font(.headline)
                .foregroundStyle(entry.isComplete ? KitColor.green : KitColor.primaryText)
                .frame(width: 40, height: 40)
                .background(KitColor.paleGreen.opacity(entry.isComplete ? 0.4 : 1), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(starterTitle(entry.step))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(KitColor.primaryText)
                Text(starterSubtitle(entry.step))
                    .font(.caption)
                    .foregroundStyle(KitColor.secondaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if entry.isComplete {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(KitColor.green)
                    .accessibilityLabel("Complete")
            } else {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(KitColor.secondaryText)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(entry.isComplete ? "Complete" : "Not complete")
    }

    private func starterIcon(_ step: HomeStarterStep) -> String {
        switch step {
        case .verifyIdentity: "person.text.rectangle"
        case .sendFirstMessage: "bubble.left.and.text.bubble.right"
        case .makeFirstTransaction: "arrow.up.right.circle"
        }
    }

    private func starterTitle(_ step: HomeStarterStep) -> String {
        switch step {
        case .verifyIdentity: "Verify identity"
        case .sendFirstMessage: "Send first message"
        case .makeFirstTransaction: "Make first transaction"
        }
    }

    private func starterSubtitle(_ step: HomeStarterStep) -> String {
        switch step {
        case .verifyIdentity: "Confirm who you are to unlock full limits."
        case .sendFirstMessage: "Say hello — messages are end-to-end encrypted."
        case .makeFirstTransaction: "Send money to someone on Kit Pay."
        }
    }

    private func openStarterStep(_ step: HomeStarterStep) {
        switch HomeStarterStepRoutePolicy.presentation(
            for: step,
            secureMessagingLocalQueueAvailable: model.secureMessagingLocalQueueAvailable
        ) {
        case .fullScreen:
            cover = .identityVerification
        case .tabSwitch:
            model.requestNewMessageCompose()
        case .walletSheet:
            open(.send, title: "Send", available: canSend, needsInternet: true)
        case let .unavailable(message):
            model.lastError = message
        }
    }

    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Recent activity").font(.title2.bold()).foregroundStyle(KitColor.primaryText)
                Spacer()
                Button {
                    open(.transactions, title: "Transactions", available: canViewWallet, needsInternet: false)
                } label: {
                    Text("See all")
                        .font(.subheadline.bold())
                        .foregroundStyle(KitColor.green)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if recentTransactions.isEmpty {
                ContentUnavailableView(
                    "No activity yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text(model.isOnline ? "Wallet transactions will appear here." : "Connect to refresh your wallet history.")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .kitGlass(cornerRadius: 24)
            } else {
                ForEach(recentTransactions.prefix(8)) { transaction in
                    Button {
                        open(
                            .transaction(transaction),
                            title: "Transaction details",
                            available: canViewWallet,
                            needsInternet: false
                        )
                    } label: {
                        transactionRow(transaction)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var recentTransactions: [WalletTransaction] {
        CustomerTransactionPresentationPolicy.customerVisibleTransactions(
            model.state.transactions,
            selectedWalletID: model.state.selectedWalletId,
            wallets: model.state.wallets
        )
    }

    private var lockedRecentActivity: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent activity")
                    .font(.title2.bold())
                    .foregroundStyle(KitColor.primaryText)
                Spacer()
                Button("See all") {
                    open(
                        .transactions,
                        title: "Transactions",
                        available: canViewWallet,
                        needsInternet: false
                    )
                }
                .font(.subheadline.bold())
                .foregroundStyle(KitColor.green)
            }
            Label(
                "Verify your identity to view wallet activity.",
                systemImage: "lock.shield"
            )
            .font(.subheadline)
            .foregroundStyle(KitColor.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .kitGlass(cornerRadius: 20, shadow: false)
        }
    }

    private func transactionRow(_ transaction: WalletTransaction) -> some View {
        HStack(spacing: 13) {
            Image(systemName: transaction.customerDirection == "credit" ? "arrow.down.left" : "arrow.up.right")
                .font(.headline)
                .foregroundStyle(transaction.customerDirection == "credit" ? KitColor.green : KitColor.primaryText)
                .frame(width: 46, height: 46)
                .background(.thinMaterial, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(
                    transaction.customerCounterparty?.name
                        ?? transaction.type.replacingOccurrences(of: "_", with: " ").capitalized
                )
                    .font(.body.bold())
                    .foregroundStyle(KitColor.primaryText)
                Text(transaction.note ?? transaction.reference)
                    .font(.caption)
                    .foregroundStyle(KitColor.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(transaction.customerImpactLabel)
                    .font(.caption2)
                    .foregroundStyle(KitColor.secondaryText)
                Text(KitMoney.formatted(
                    transaction.customerImpactAmount,
                    currency: transaction.currency
                ))
                    .font(.subheadline.bold())
                    .monospacedDigit()
                    .foregroundStyle(transaction.customerDirection == "credit" ? KitColor.green : KitColor.primaryText)
            }
        }
        .padding(14)
        .kitGlass(cornerRadius: 20, shadow: false)
    }

    private var formattedBalance: String {
        guard let wallet = model.selectedWallet else { return "UGX 0" }
        return KitMoney.formatted(wallet.balances.available, currency: wallet.currency)
    }

    private var greeting: String {
        switch AppPresentationClock.calendar.component(.hour, from: AppPresentationClock.now) {
        case 5..<12: "Good morning,"
        case 12..<17: "Good afternoon,"
        default: "Good evening,"
        }
    }

    private var canSend: Bool {
        featureEnabled("wallets") && featureEnabled("internal_transfers")
    }

    private var canReceive: Bool {
        featureEnabled("wallets")
    }

    private var canRequest: Bool {
        featureEnabled("wallets") && featureEnabled("payment_requests")
    }

    private var canViewWallet: Bool {
        featureEnabled("wallets")
    }

    private var canPayBills: Bool {
        model.capabilities?.enablesProviderService(.bill) == true
    }

    private var canBuyAirtime: Bool {
        model.capabilities?.enablesProviderService(.airtime) == true
    }

    private var canUseMobileMoney: Bool {
        model.capabilities?.enablesMobileMoney == true
    }

    private var canUseBank: Bool {
        model.capabilities?.enablesBankTransfers == true
            || model.capabilities?.enablesBankDeposits == true
    }

    private var canUseMerchantQR: Bool {
        model.capabilities?.enablesMerchantQRPayments == true
    }

    private func featureEnabled(_ name: String) -> Bool {
        model.capabilities?.features?.compactMapValues { $0 }[name] == true
    }

    private func open(
        _ destination: WalletDestination,
        title: String,
        available: Bool,
        needsInternet: Bool
    ) {
        guard routeFinancialAccess(requiresMutation: destination.isAppReviewDemoMutation)
        else { return }
        guard available else {
            model.lastError = "\(title) is not enabled for this Kit Pay account."
            return
        }
        guard !needsInternet || model.isOnline else {
            model.lastError = "Connect to the internet to use \(title.lowercased())."
            return
        }
        modal = .wallet(destination)
    }

    private func openProvider(
        _ entry: ProviderFlowEntry,
        title: String,
        available: Bool
    ) {
        guard routeFinancialAccess(requiresMutation: true) else { return }
        guard available else {
            model.lastError = "\(title) is not enabled for this Kit Pay account."
            return
        }
        guard model.isOnline else {
            model.lastError = "Connect to the internet to use \(title.lowercased()). Provider payments cannot be queued offline."
            return
        }
        modal = .provider(entry)
    }

    private func openFeature(
        _ feature: HomePaymentFeature,
        title: String,
        available: Bool
    ) {
        guard routeFinancialAccess(requiresMutation: true) else { return }
        guard available else {
            model.lastError = "\(title) is not enabled for this Kit Pay account."
            return
        }
        guard model.isOnline else {
            model.lastError = "Connect to the internet to use \(title.lowercased()). Payments cannot be queued offline."
            return
        }
        switch feature {
        case .mobileMoney: modal = .mobileMoney
        case .bankTransfer: cover = .bankTransfer
        case .scanQR: modal = .scanQR
        }
    }

    @discardableResult
    private func routeFinancialAccess(requiresMutation: Bool) -> Bool {
        let route = FinancialEntryRoutePolicy.route(
            requirement: model.moneyActionAccessRequirement,
            kind: requiresMutation ? .moneyMovement : .readOnlySurface
        )
        switch route {
        case .open:
            return true
        case .readOnly:
            model.lastError = AppReviewDemoMutationPolicy.readOnlyMessage
        case .verifyIdentity:
            cover = .identityVerification
        case .verifyDeviceIdentity:
            model.lastError = "Verify this iPhone before using wallet or payment actions."
        case .unlockSession:
            model.lastError = "Unlock this iPhone before using wallet or payment actions."
        case .unavailable:
            model.lastError = "Wallet access is temporarily unavailable. Refresh and try again."
        }
        return false
    }
}

private extension WalletDestination {
    var isAppReviewDemoMutation: Bool {
        switch self {
        case .send, .request:
            true
        case .receive, .transactions, .transaction:
            false
        }
    }
}
