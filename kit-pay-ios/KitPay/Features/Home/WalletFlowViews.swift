import Foundation
import SwiftUI

enum WalletDestination: Identifiable {
    case send
    case receive
    case request
    case transactions
    case transaction(WalletTransaction)

    var id: String {
        switch self {
        case .send: "send"
        case .receive: "receive"
        case .request: "request"
        case .transactions: "transactions"
        case let .transaction(transaction): "transaction-\(transaction.id)"
        }
    }
}

@MainActor
final class WalletFlowModel: ObservableObject {
    @Published private(set) var contacts: [WalletContactDTO] = []
    @Published private(set) var isLoadingContacts = false
    @Published private(set) var isSubmitting = false
    @Published private(set) var sentTransaction: WalletTransaction?
    @Published private(set) var scheduledPayment: ScheduledPaymentDTO?
    @Published private(set) var createdRequest: PaymentRequestDTO?
    @Published private(set) var paymentPinConfigured = false
    /// The debit the server refused for want of funds. The device's own balance can be a moment
    /// stale — an unrelated payment posting between the review and the approval is enough — so the
    /// shortfall is worked out again from a fresh balance rather than assumed.
    @Published var insufficientFundsDebitAmount: String?
    @Published var errorMessage: String?

    private let api: APIClient
    private var pendingRequestSubmission: (fingerprint: String, idempotencyKey: String)?
    private var pendingScheduledPaymentSubmission: (fingerprint: String, idempotencyKey: String)?
    let secureShareSession = KitPaymentRequestSecureShareSession()

    init(api: APIClient = .shared) {
        self.api = api
    }

    func useSyncedContacts(_ updatedContacts: [WalletContactDTO]) {
        contacts = updatedContacts
    }

    /// Approval routes through `AppModel.authorizeFinancialStepUp`, which signs with the
    /// Secure Enclave when biometrics are available and otherwise verifies the wallet PIN.
    func send(
        from wallet: Wallet,
        to contact: WalletContactDTO,
        enteredAmount: String,
        note: String,
        pin: String,
        authorize: KitFinancialStepUpAuthorization
    ) async -> Bool {
        guard !isSubmitting else { return false }
        guard let destinationWalletId = contact.receivingWalletId, !destinationWalletId.isEmpty else {
            errorMessage = "This contact cannot receive Kit Pay transfers yet."
            return false
        }
        guard let amount = WalletMoney.apiAmount(enteredAmount, scale: wallet.currency.decimalScale) else {
            errorMessage = "Enter an amount greater than zero."
            return false
        }

        isSubmitting = true
        errorMessage = nil
        insufficientFundsDebitAmount = nil
        defer { isSubmitting = false }

        let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let intent: [String: String?] = [
            "source_wallet_id": wallet.id,
            "destination_wallet_id": destinationWalletId,
            "amount": amount,
            "note": cleanNote,
        ]

        do {
            scheduledPayment = nil
            let verification = try await authorize(
                "wallet_transfer",
                intent,
                pin,
                "Approve sending \(KitMoney.formatted(amount, currency: wallet.currency)) to \(contact.name)"
            )
            let transaction = try await api.transfer(
                walletId: wallet.id,
                destinationWalletId: destinationWalletId,
                amount: amount,
                note: cleanNote,
                idempotencyKey: "ios-transfer-\(UUID().uuidString.lowercased())",
                stepUpToken: verification.stepUpToken
            )
            guard CustomerTransactionPresentationPolicy.isCustomerVisible(transaction),
                  transaction.walletId.caseInsensitiveCompare(wallet.id) == .orderedSame,
                  transaction.direction.caseInsensitiveCompare("debit") == .orderedSame
            else { throw WalletFlowError.unconfirmedTransfer }
            sentTransaction = transaction
            return true
        } catch {
            if WalletTopUpPolicy.isInsufficientFunds(error) {
                insufficientFundsDebitAmount = amount
            }
            errorMessage = message(for: error)
            return false
        }
    }

    /// Creates a server-side instruction after one exact biometric/PIN approval. The server, not
    /// this phone, owns execution, so locking or terminating the app cannot make the payment miss
    /// its time. A retained idempotency key makes an ambiguous network retry safe.
    func schedule(
        from wallet: Wallet,
        to contact: WalletContactDTO,
        enteredAmount: String,
        note: String,
        deliverAt requestedDate: Date,
        conversationID rawConversationID: String?,
        pin: String,
        authorize: KitFinancialStepUpAuthorization,
        now: Date = Date()
    ) async -> Bool {
        guard !isSubmitting else { return false }
        guard let destinationWalletID = contact.receivingWalletId,
              ScheduledPaymentValidation.canonicalUUID(wallet.id) != nil,
              ScheduledPaymentValidation.canonicalUUID(destinationWalletID) != nil
        else {
            errorMessage = "This contact cannot receive Kit Pay transfers yet."
            return false
        }
        guard let amount = WalletMoney.apiAmount(
            enteredAmount,
            scale: wallet.currency.decimalScale
        ) else {
            errorMessage = "Enter an amount greater than zero."
            return false
        }
        guard let scheduledFor = ScheduledSendPolicy.normalize(requestedDate, now: now) else {
            errorMessage = "Choose a time from one minute to one year from now."
            return false
        }
        let conversationID: String?
        if let rawConversationID {
            guard let canonical = ScheduledPaymentValidation.canonicalUUID(rawConversationID) else {
                errorMessage = "This conversation is no longer available. Nothing was scheduled."
                return false
            }
            conversationID = canonical
        } else {
            conversationID = nil
        }
        let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard (cleanNote?.utf16.count ?? 0) <= 280 else {
            errorMessage = "Keep the payment note to 280 characters or fewer."
            return false
        }
        let scheduledForText = ScheduledPaymentDates.apiString(scheduledFor)
        let fingerprint = [
            wallet.id.lowercased(),
            destinationWalletID.lowercased(),
            amount,
            cleanNote ?? "",
            scheduledForText,
            conversationID ?? "",
        ].joined(separator: "\u{1F}")
        let idempotencyKey: String
        if let pendingScheduledPaymentSubmission,
           pendingScheduledPaymentSubmission.fingerprint == fingerprint {
            idempotencyKey = pendingScheduledPaymentSubmission.idempotencyKey
        } else {
            idempotencyKey = "ios-scheduled-payment-\(UUID().uuidString.lowercased())"
            pendingScheduledPaymentSubmission = (fingerprint, idempotencyKey)
        }

        isSubmitting = true
        errorMessage = nil
        insufficientFundsDebitAmount = nil
        defer { isSubmitting = false }
        let intent = ScheduledPaymentPolicy.intent(
            sourceWalletID: wallet.id,
            destinationWalletID: destinationWalletID,
            amount: amount,
            currencyCode: wallet.currency.code,
            note: cleanNote,
            scheduledFor: scheduledFor,
            conversationID: conversationID
        )
        do {
            let verification = try await authorize(
                "scheduled_payment",
                intent,
                pin,
                "Approve scheduling \(KitMoney.formatted(amount, currency: wallet.currency)) to \(contact.name)"
            )
            let created = try await api.createScheduledPayment(
                body: CreateScheduledPaymentBody(
                    sourceWalletId: wallet.id,
                    destinationWalletId: destinationWalletID,
                    conversationId: conversationID,
                    amount: amount,
                    note: cleanNote,
                    scheduledFor: scheduledForText
                ),
                idempotencyKey: idempotencyKey,
                stepUpToken: verification.stepUpToken
            )
            guard ScheduledPaymentPolicy.confirms(
                created,
                sourceWalletID: wallet.id,
                destinationWalletID: destinationWalletID,
                amount: amount,
                currency: wallet.currency,
                note: cleanNote,
                scheduledFor: scheduledFor,
                conversationID: conversationID
            ) else { throw WalletFlowError.unconfirmedScheduledPayment }
            sentTransaction = nil
            scheduledPayment = created
            pendingScheduledPaymentSubmission = nil
            return true
        } catch {
            if WalletTopUpPolicy.isInsufficientFunds(error) {
                insufficientFundsDebitAmount = amount
            }
            errorMessage = message(for: error)
            return false
        }
    }

    func configurePaymentPin(_ pin: String, confirmation: String) async -> Bool {
        guard !isSubmitting else { return false }
        guard pin.range(of: #"^[0-9]{4}$"#, options: .regularExpression) != nil else {
            errorMessage = "Choose a four-digit wallet PIN."
            return false
        }
        guard pin == confirmation else {
            errorMessage = "The PINs do not match."
            return false
        }

        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            let result = try await api.setPaymentPin(pin: pin)
            guard result.paymentPinSet == true else { throw WalletFlowError.pinSetupRejected }
            paymentPinConfigured = true
            return true
        } catch {
            errorMessage = message(for: error)
            return false
        }
    }

    func request(
        into wallet: Wallet,
        from contact: WalletContactDTO,
        enteredAmount: String,
        note: String,
        create: (
            _ destinationWalletID: String,
            _ requestedFromUserID: String,
            _ amount: String,
            _ note: String?,
            _ idempotencyKey: String
        ) async throws -> PaymentRequestDTO
    ) async -> Bool {
        guard !isSubmitting else { return false }
        guard contact.canReceivePaymentRequest,
              let recipientUserID = ContactRecipientDirectory.recipientUserId(for: contact)
        else {
            errorMessage = "Choose a valid Kit Pay contact."
            return false
        }
        guard let amount = WalletMoney.apiAmount(enteredAmount, scale: wallet.currency.decimalScale) else {
            errorMessage = "Enter an amount greater than zero."
            return false
        }

        let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let fingerprint = [wallet.id, recipientUserID, amount, cleanNote ?? ""]
            .joined(separator: "\u{1F}")
        let idempotencyKey: String
        if let pendingRequestSubmission, pendingRequestSubmission.fingerprint == fingerprint {
            idempotencyKey = pendingRequestSubmission.idempotencyKey
        } else {
            idempotencyKey = "ios-request-\(UUID().uuidString.lowercased())"
            pendingRequestSubmission = (fingerprint, idempotencyKey)
        }

        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            let created = try await create(
                wallet.id,
                recipientUserID,
                amount,
                cleanNote,
                idempotencyKey
            )
            guard created.type == "payment_request",
                  created.knownStatus == .pending,
                  created.destinationWalletId == wallet.id,
                  created.requestedFromUserId?.caseInsensitiveCompare(recipientUserID)
                    == .orderedSame,
                  created.amount == amount,
                  created.currency == wallet.currency
            else { throw WalletFlowError.unconfirmedPaymentRequest }
            createdRequest = created
            pendingRequestSubmission = nil
            return true
        } catch {
            errorMessage = message(for: error)
            return false
        }
    }

    private func message(for error: Error) -> String {
        let message = (error as? APIErrorPayload)?.message ?? error.localizedDescription
        return CustomerFacingPaymentCopy.neutralizedServiceMessage(message)
    }
}

struct WalletFlowContainer: View {
    let destination: WalletDestination
    @StateObject private var flow = WalletFlowModel()

    var body: some View {
        NavigationStack {
            MoneyAccessBoundary {
                switch destination {
                case .send:
                    SendMoneyView(flow: flow)
                case .receive:
                    ReceiveMoneyView(flow: flow)
                case .request:
                    PaymentRequestsView()
                case .transactions:
                    TransactionsView()
                case let .transaction(transaction):
                    TransactionDetailView(transaction: transaction)
                }
            }
        }
        .presentationBackground(.ultraThinMaterial)
    }
}

private enum SendMoneyStep {
    case recipient
    case amount
    case success
}

struct SendMoneyView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var flow: WalletFlowModel

    @State private var step: SendMoneyStep = .recipient
    @State private var selectedContact: WalletContactDTO?
    @State private var query = ""
    @State private var amount = ""
    @State private var note = ""
    @State private var pin = ""
    @State private var setupPin = ""
    @State private var setupPinConfirmation = ""
    @State private var showingConfirmation = false
    @State private var isPickingScheduledTime = false
    @State private var scheduledFor: Date?
    /// Non-nil while the customer is topping up to cover this very payment.
    @State private var topUpRequest: WalletTopUpRequirement?
    private let preselectedRecipientUserID: String?
    private let conversationID: String?
    private let locksRecipientSelection: Bool
    /// Set by chat: after a confirmed transfer, shares the transaction into the conversation as
    /// an encrypted payment event. Best-effort — a failed share never affects the transfer.
    private let shareTransferInChat: ((WalletTransaction) async -> Bool)?
    private let scheduledPaymentCreated: ((ScheduledPaymentDTO) -> Void)?

    /// Chat opens this flow with the conversation's recipient already chosen, mirroring
    /// `RequestMoneyView`: the amount step comes first and the recipient cannot be swapped.
    init(
        flow: WalletFlowModel,
        preselectedContact: WalletContactDTO? = nil,
        preselectedRecipientUserID: String? = nil,
        conversationID: String? = nil,
        locksRecipientSelection: Bool = false,
        shareTransferInChat: ((WalletTransaction) async -> Bool)? = nil,
        scheduledPaymentCreated: ((ScheduledPaymentDTO) -> Void)? = nil
    ) {
        self.flow = flow
        self.preselectedRecipientUserID = preselectedRecipientUserID
            ?? preselectedContact.flatMap {
                ContactRecipientDirectory.recipientUserId(for: $0)
            }
        self.conversationID = conversationID
        self.locksRecipientSelection = locksRecipientSelection
        self.shareTransferInChat = shareTransferInChat
        self.scheduledPaymentCreated = scheduledPaymentCreated
        let initialContact = preselectedContact?.canReceiveTransfer == true
            ? preselectedContact
            : nil
        _selectedContact = State(initialValue: initialContact)
        _step = State(initialValue: initialContact != nil ? .amount : .recipient)
    }

    private var eligibleContacts: [WalletContactDTO] {
        let transferable = flow.contacts.filter(\.canReceiveTransfer)
        guard locksRecipientSelection else { return transferable }
        // A locked (in-chat) flow must never fall open into the full picker when the chat
        // recipient is not transfer-eligible; it shows the empty state instead.
        guard let preselectedRecipientUserID else { return [] }
        return transferable.filter {
            ContactRecipientDirectory.recipientUserId(for: $0) == preselectedRecipientUserID
        }
    }

    /// The amount exactly as the review step, the confirm button and the receipt should all
    /// state it — grouped in the customer's own separators, like the field they typed it into.
    private var displayedAmount: String {
        WalletMoney.displayAmount(
            amount,
            currency: model.selectedWallet?.currency.code ?? "UGX",
            scale: model.selectedWallet?.currency.decimalScale ?? 2
        )
    }

    private var filteredContacts: [WalletContactDTO] {
        guard !query.isEmpty else { return eligibleContacts }
        return eligibleContacts.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.phone.localizedCaseInsensitiveContains(query)
                || ($0.tag?.localizedCaseInsensitiveContains(query) == true)
        }
    }

    var body: some View {
        Group {
            if model.profile?.paymentPinSet == true || flow.paymentPinConfigured {
                switch step {
                case .recipient: recipientPicker
                case .amount: amountEntry
                case .success: successView
                }
            } else {
                paymentPinSetup
            }
        }
        .background(KitColor.canvas.ignoresSafeArea())
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(step == .amount && !locksRecipientSelection ? "Back" : "Close") {
                    if step == .amount && !locksRecipientSelection {
                        step = .recipient
                    } else {
                        dismiss()
                    }
                }
            }
        }
        .task {
            flow.errorMessage = nil
            await model.loadContactDirectory(forceServerRefresh: true)
            updateContacts(model.contactDirectory)
        }
        .onChange(of: model.contactDirectory) { _, contacts in
            updateContacts(contacts)
        }
        .sheet(isPresented: $showingConfirmation) { confirmationSheet }
        .sheet(isPresented: $isPickingScheduledTime) {
            ScheduleSendSheet(
                title: "Schedule payment",
                confirmTitle: "Continue",
                preview: schedulePreview,
                initialDate: scheduledFor,
                onSchedule: { date in
                    scheduledFor = date
                    WalletTopUpPresentation.afterDismissal {
                        showingConfirmation = true
                    }
                }
            )
        }
        .sheet(item: $topUpRequest) { requirement in
            WalletTopUpView(requirement: requirement) { covered in
                // Straight back to the approval the customer was already committed to.
                guard covered else { return }
                WalletTopUpPresentation.afterDismissal { showingConfirmation = true }
            }
            .environmentObject(model)
            .presentationBackground(.ultraThinMaterial)
        }
    }

    /// Resolves the chat-provided recipient once the synced directory is available. The chat
    /// recipient is identified by user ID because the directory row may not exist until the
    /// first contact sync completes.
    private func updateContacts(_ contacts: [WalletContactDTO]) {
        flow.useSyncedContacts(contacts)

        // Replace a selected row with the fresh server-backed directory value. If the recipient
        // lost transfer eligibility (or disappeared), clear it instead of submitting stale wallet
        // routing data retained by the SwiftUI sheet.
        if let selectedContact {
            if let selectedID = ContactRecipientDirectory.recipientUserId(for: selectedContact) {
                self.selectedContact = contacts.first {
                    ContactRecipientDirectory.recipientUserId(for: $0) == selectedID
                        && $0.canReceiveTransfer
                }
            } else {
                self.selectedContact = nil
            }
        }

        if self.selectedContact == nil, let preselectedRecipientUserID {
            self.selectedContact = contacts.first {
                ContactRecipientDirectory.recipientUserId(for: $0) == preselectedRecipientUserID
                    && $0.canReceiveTransfer
            }
        }

        if locksRecipientSelection {
            step = self.selectedContact == nil ? .recipient : .amount
        } else if self.selectedContact == nil, step == .amount {
            step = .recipient
        }
    }

    private var navigationTitle: String {
        if model.profile?.paymentPinSet != true && !flow.paymentPinConfigured {
            return "Secure your wallet"
        }
        switch step {
        case .recipient: return "Send money"
        case .amount: return selectedContact?.name ?? "Amount"
        case .success: return ""
        }
    }

    private var paymentPinSetup: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(KitColor.green)
                    .frame(width: 92, height: 92)
                    .kitGlass(cornerRadius: 28, tint: KitColor.paleGreen)
                Text("Create your wallet PIN")
                    .font(.title2.bold())
                    .foregroundStyle(KitColor.primaryText)
                Text("You’ll use this four-digit PIN to authorize payments. Do not share it with anyone.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(KitColor.secondaryText)

                SecureField("New 4-digit PIN", text: $setupPin)
                    .keyboardType(.numberPad)
                    .textContentType(.newPassword)
                    .padding(17)
                    .kitGlass(cornerRadius: 18)
                    .onChange(of: setupPin) { _, value in
                        setupPin = String(value.filter(\.isNumber).prefix(4))
                    }
                SecureField("Confirm PIN", text: $setupPinConfirmation)
                    .keyboardType(.numberPad)
                    .textContentType(.newPassword)
                    .padding(17)
                    .kitGlass(cornerRadius: 18)
                    .onChange(of: setupPinConfirmation) { _, value in
                        setupPinConfirmation = String(value.filter(\.isNumber).prefix(4))
                    }

                inlineError

                Button {
                    Task {
                        if await flow.configurePaymentPin(setupPin, confirmation: setupPinConfirmation) {
                            await model.refresh()
                        }
                    }
                } label: {
                    if flow.isSubmitting {
                        ProgressView().tint(.white).frame(maxWidth: .infinity)
                    } else {
                        Label("Create wallet PIN", systemImage: "lock.fill").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(KitPrimaryButtonStyle())
                .disabled(
                    !model.appReviewDemoMutationsAllowed
                        || setupPin.count != 4
                        || setupPinConfirmation.count != 4
                        || flow.isSubmitting
                )
            }
            .padding(24)
        }
    }

    private var recipientPicker: some View {
        VStack(spacing: 12) {
            ContactSyncRecoveryView(horizontalPadding: 16)

            Group {
                if eligibleContacts.isEmpty {
                    ContentUnavailableView(
                        "No eligible contacts",
                        systemImage: "person.2.slash",
                        description: Text(model.isOnline ? "Contacts with an active Kit Pay wallet appear here." : "Connect to load your contacts.")
                    )
                } else {
                    List {
                        let favorites = filteredContacts.filter { $0.favorite == true }
                        if !favorites.isEmpty {
                            Section("Favorites") {
                                ForEach(favorites) { contact in contactButton(contact) }
                            }
                        }
                        Section("All contacts") {
                            ForEach(filteredContacts) { contact in contactButton(contact) }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .searchable(text: $query, prompt: "Name, phone or @kittag")
                }
            }
        }
        .overlay(alignment: .bottom) {
            // Never intercept taps meant for the bottom contact rows underneath.
            inlineError.allowsHitTesting(false)
        }
    }

    private func contactButton(_ contact: WalletContactDTO) -> some View {
        Button {
            selectedContact = contact
            step = .amount
        } label: {
            HStack(spacing: 14) {
                RemoteAvatarView(
                    name: contact.name,
                    avatarURL: contact.avatarURL,
                    size: 46
                )
                VStack(alignment: .leading, spacing: 3) {
                    VerifiedAccountNameLabel(
                        designation: contact.verification?.designation
                    ) {
                        MarqueeText(text: contact.name, font: .headline)
                    }
                    Text(contact.tag?.nilIfEmpty ?? contact.phone)
                        .font(.subheadline)
                        .foregroundStyle(KitColor.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var amountEntry: some View {
        ScrollView {
            VStack(spacing: 22) {
                if let selectedContact {
                    HStack(spacing: 10) {
                        RemoteAvatarView(
                            name: selectedContact.name,
                            avatarURL: selectedContact.avatarURL,
                            size: 38
                        )
                        VStack(alignment: .leading) {
                            VerifiedAccountNameLabel(
                                designation: selectedContact.verification?.designation
                            ) {
                                Text(selectedContact.name).font(.headline)
                            }
                            Text(selectedContact.phone).font(.caption).foregroundStyle(KitColor.secondaryText)
                        }
                    }
                }

                VStack(spacing: 9) {
                    Text("Amount").font(.subheadline).foregroundStyle(KitColor.secondaryText)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(model.selectedWallet?.currency.code ?? "UGX")
                            .font(.title3.bold())
                            .foregroundStyle(KitColor.green)
                        KitAmountTextField(
                            "0",
                            value: $amount,
                            mode: .decimal(
                                maximumFractionDigits:
                                    model.selectedWallet?.currency.decimalScale ?? 2
                            ),
                            textStyle: .hero,
                            textAlignment: .center
                        )
                            .frame(maxWidth: 230)
                    }
                    Text("Balance: \(availableBalance) · No transaction fee")
                        .font(.caption)
                        .foregroundStyle(KitColor.secondaryText)
                }
                .padding(.vertical, 30)
                .frame(maxWidth: .infinity)
                .kitGlass(cornerRadius: 30, tint: KitColor.paleGreen)

                TextField("Add a note (optional)", text: $note)
                    .textFieldStyle(.plain)
                    .padding(17)
                    .kitGlass(cornerRadius: 18)

                if let requirement = topUpRequirement {
                    shortfallNotice(requirement)
                }

                inlineError

                Button {
                    guard model.isOnline else {
                        flow.errorMessage = "Connect to the internet to send money."
                        return
                    }
                    if let requirement = topUpRequirement {
                        topUpRequest = requirement
                    } else {
                        scheduledFor = nil
                        showingConfirmation = true
                    }
                } label: {
                    Label(
                        topUpRequirement == nil ? "Review & send" : "Top up to send",
                        systemImage: topUpRequirement == nil ? "arrow.up.right" : "plus.circle"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(KitPrimaryButtonStyle())
                .disabled(
                    !model.appReviewDemoMutationsAllowed
                        || WalletMoney.apiAmount(
                            amount,
                            scale: model.selectedWallet?.currency.decimalScale ?? 2
                        ) == nil
                )

                if canSchedulePayment {
                    Button {
                        guard model.isOnline else {
                            flow.errorMessage = "Connect to the internet to schedule a payment."
                            return
                        }
                        isPickingScheduledTime = true
                    } label: {
                        Label("Send later", systemImage: "clock.badge.checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(KitSecondaryButtonStyle())
                    .disabled(
                        !model.appReviewDemoMutationsAllowed
                            || WalletMoney.apiAmount(
                                amount,
                                scale: model.selectedWallet?.currency.decimalScale ?? 2
                            ) == nil
                    )
                }
            }
            .padding(20)
        }
    }

    private var confirmationSheet: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if let selectedContact {
                    RemoteAvatarView(
                        name: selectedContact.name,
                        avatarURL: selectedContact.avatarURL,
                        size: 70
                    )
                    VerifiedAccountNameLabel(
                        designation: selectedContact.verification?.designation
                    ) {
                        Text(selectedContact.name).font(.title2.bold())
                    }
                    Text(displayedAmount)
                        .font(.system(size: 38, weight: .heavy, design: .rounded))
                }
                if !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("“\(note)”").foregroundStyle(KitColor.secondaryText)
                }
                HStack {
                    Text(CustomerFacingPaymentCopy.transactionFeeTitle)
                        .foregroundStyle(KitColor.secondaryText)
                    Spacer()
                    Text("Free").bold()
                }
                .padding(17)
                .kitGlass(cornerRadius: 18)

                if let scheduledFor {
                    Label {
                        Text("Kit will send this payment from the server on \(scheduledFor.formatted(date: .abbreviated, time: .shortened)), even if this iPhone is offline.")
                            .font(.footnote)
                            .foregroundStyle(KitColor.secondaryText)
                    } icon: {
                        Image(systemName: "clock.badge.checkmark")
                            .foregroundStyle(KitColor.green)
                    }
                    .padding(17)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .kitGlass(cornerRadius: 18, tint: KitColor.paleGreen, shadow: false)
                }

                if model.financialApprovalUsesBiometrics {
                    Label {
                        Text("Approve with \(model.biometricDisplayName). Your approval covers only this exact payment.")
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
                        .textContentType(.oneTimeCode)
                        .padding(17)
                        .kitGlass(cornerRadius: 18)
                        .onChange(of: pin) { _, value in
                            pin = String(value.filter(\.isNumber).prefix(4))
                        }
                    Text("Your PIN authorizes only this exact payment.")
                        .font(.caption)
                        .foregroundStyle(KitColor.secondaryText)
                }

                inlineError

                Button {
                    guard let wallet = model.selectedWallet, let selectedContact else { return }
                    Task {
                        let succeeded: Bool
                        if let scheduledFor {
                            succeeded = await flow.schedule(
                                from: wallet,
                                to: selectedContact,
                                enteredAmount: amount,
                                note: note,
                                deliverAt: scheduledFor,
                                conversationID: conversationID,
                                pin: pin,
                                authorize: model.authorizeFinancialStepUp
                            )
                        } else {
                            succeeded = await flow.send(
                                from: wallet,
                                to: selectedContact,
                                enteredAmount: amount,
                                note: note,
                                pin: pin,
                                authorize: model.authorizeFinancialStepUp
                            )
                        }
                        if succeeded {
                            showingConfirmation = false
                            step = .success
                            // Every Kit Pay → Kit Pay transfer documents itself as an encrypted
                            // chat event; the transfer's success never depends on it (the event
                            // queues durably offline-first). Chat-initiated sends share into
                            // their conversation; standalone sends go as a direct message.
                            if let payment = flow.scheduledPayment {
                                scheduledPaymentCreated?(payment)
                            } else if let transaction = flow.sentTransaction {
                                if let shareTransferInChat {
                                    _ = await shareTransferInChat(transaction)
                                } else if let recipientUserID = preselectedRecipientUserID
                                    ?? ContactRecipientDirectory.recipientUserId(
                                        for: selectedContact
                                    ) {
                                    _ = await model.queueTransferChatEvent(
                                        transaction: transaction,
                                        recipientId: recipientUserID,
                                        title: selectedContact.name
                                    )
                                }
                            }
                            await model.refresh()
                        } else {
                            await handleServerInsufficientFunds()
                        }
                    }
                } label: {
                    if flow.isSubmitting {
                        ProgressView().tint(.white).frame(maxWidth: .infinity)
                    } else {
                        Label(
                            scheduledFor == nil
                                ? "Send \(displayedAmount)"
                                : "Schedule \(displayedAmount)",
                            systemImage: model.financialApprovalUsesBiometrics
                                ? model.biometricSymbolName
                                : "lock.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(KitPrimaryButtonStyle())
                .disabled(
                    !model.appReviewDemoMutationsAllowed
                        || (!model.financialApprovalUsesBiometrics && pin.count != 4)
                        || flow.isSubmitting
                )
                Spacer()
            }
            .padding(24)
            .background(KitColor.canvas.ignoresSafeArea())
            .navigationTitle("Confirm payment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { showingConfirmation = false }
                        .disabled(flow.isSubmitting)
                }
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(flow.isSubmitting)
    }

    private var successView: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "checkmark")
                .font(.system(size: 42, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 92, height: 92)
                .background(KitColor.green.gradient, in: Circle())
                .shadow(color: KitColor.green.opacity(0.32), radius: 22, y: 10)
            Text(scheduledFor == nil ? "Sent!" : "Payment scheduled")
                .font(.largeTitle.bold())
                .foregroundStyle(KitColor.primaryText)
            Text(successDetail)
                .multilineTextAlignment(.center)
                .foregroundStyle(KitColor.secondaryText)
            if let payment = flow.scheduledPayment {
                Text("Schedule \(payment.id)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            } else if let transaction = flow.sentTransaction {
                Text("Ref \(transaction.reference)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                ShareReceiptButton(transaction: transaction, senderName: model.profile?.name)
            }
            Spacer()
            Button("Done") { dismiss() }
                .frame(maxWidth: .infinity)
                .buttonStyle(KitPrimaryButtonStyle())
        }
        .padding(28)
    }

    @ViewBuilder
    private var inlineError: some View {
        if let error = flow.errorMessage {
            Text(error)
                .font(.footnote)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var availableBalance: String {
        guard let wallet = model.selectedWallet else { return "UGX 0" }
        return KitMoney.formatted(wallet.balances.available, currency: wallet.currency)
    }

    private var canSchedulePayment: Bool {
        let policy = ScheduledPaymentPolicy(capabilities: model.capabilities)
        return conversationID == nil ? policy.enabled : policy.chatEnabled
    }

    private var schedulePreview: String {
        "Send \(displayedAmount) to \(selectedContact?.name ?? "your contact")"
    }

    private var successDetail: String {
        let recipient = selectedContact?.name ?? "your contact"
        guard let scheduledFor else { return "\(displayedAmount) is on its way to \(recipient)." }
        return "Kit will send \(displayedAmount) to \(recipient) on \(scheduledFor.formatted(date: .abbreviated, time: .shortened))."
    }

    private func shortfallNotice(_ requirement: WalletTopUpRequirement) -> some View {
        WalletShortfallNotice(requirement: requirement) { topUpRequest = requirement }
            .padding(17)
            .kitGlass(cornerRadius: 18)
    }

    /// Kit Pay → Kit Pay transfers carry no transaction fee, so the wallet debit is the amount
    /// entered and the shortfall can be shown while the customer is still typing.
    private var topUpRequirement: WalletTopUpRequirement? {
        WalletTopUpPolicy.requirement(
            wallet: model.selectedWallet,
            debitAPIAmount: WalletMoney.apiAmount(
                amount,
                scale: model.selectedWallet?.currency.decimalScale ?? 2
            )
        )
    }

    /// The server refused for want of funds. Re-read the balance before saying by how much.
    @MainActor
    private func handleServerInsufficientFunds() async {
        guard let debit = flow.insufficientFundsDebitAmount else { return }
        flow.insufficientFundsDebitAmount = nil
        await model.refresh()
        guard let requirement = WalletTopUpPolicy.requirement(
            wallet: model.selectedWallet,
            debitAPIAmount: debit
        ) else { return }
        showingConfirmation = false
        topUpRequest = requirement
    }
}

struct RequestMoneyView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var flow: WalletFlowModel

    @State private var selectedContact: WalletContactDTO?
    @State private var amount = ""
    @State private var note = ""
    @State private var query = ""
    @State private var completed = false
    @State private var isSharingCreatedRequest = false
    @State private var secureShareNeedsRetry = false
    @State private var isPickingScheduledTime = false
    @State private var scheduledFor: Date?
    private let preselectedRecipientUserID: String?
    private let locksRecipientSelection: Bool
    private let shareCreatedRequest: ((PaymentRequestDTO) async -> Bool)?
    /// Provided only where a scheduled request has somewhere to land — today, a chat. Absent, the
    /// screen shows no Send Later affordance at all rather than one that quietly does nothing.
    private let scheduleRequest: ((PaymentRequestScheduleDraft) async -> Bool)?

    init(
        flow: WalletFlowModel,
        preselectedContact: WalletContactDTO? = nil,
        preselectedRecipientUserID: String? = nil,
        locksRecipientSelection: Bool = false,
        shareCreatedRequest: ((PaymentRequestDTO) async -> Bool)? = nil,
        scheduleRequest: ((PaymentRequestScheduleDraft) async -> Bool)? = nil
    ) {
        self.flow = flow
        self.preselectedRecipientUserID = preselectedRecipientUserID
            ?? preselectedContact.flatMap {
                ContactRecipientDirectory.recipientUserId(for: $0)
            }
        self.locksRecipientSelection = locksRecipientSelection
        self.shareCreatedRequest = shareCreatedRequest
        self.scheduleRequest = scheduleRequest
        _selectedContact = State(
            initialValue: preselectedContact?.canReceivePaymentRequest == true
                ? preselectedContact
                : nil
        )
    }

    private var eligibleContacts: [WalletContactDTO] {
        flow.contacts.filter(\.canReceivePaymentRequest).filter {
            if locksRecipientSelection {
                guard let preselectedRecipientUserID else { return false }
                return ContactRecipientDirectory.recipientUserId(for: $0)
                    == preselectedRecipientUserID
            }
            return query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                || $0.phone.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        Group {
            if completed { successView } else { form }
        }
        .background(KitColor.canvas.ignoresSafeArea())
        .navigationTitle("Request money")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } }
        }
        .task {
            flow.errorMessage = nil
            secureShareNeedsRetry = flow.secureShareSession.hasPendingRequest
            await model.loadContactDirectory(forceServerRefresh: true)
            updateContacts(model.contactDirectory)
        }
        .onChange(of: model.contactDirectory) { _, contacts in
            updateContacts(contacts)
        }
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Who should pay?").font(.headline).foregroundStyle(KitColor.primaryText)
                if locksRecipientSelection {
                    Text("This request will stay linked to the person in this chat.")
                        .font(.footnote)
                        .foregroundStyle(KitColor.secondaryText)
                } else {
                    TextField("Search contacts", text: $query)
                        .padding(16)
                        .kitGlass(cornerRadius: 18)
                        .disabled(secureShareNeedsRetry)
                }

                ContactSyncRecoveryView()

                if eligibleContacts.isEmpty {
                    ContentUnavailableView(
                        "No eligible contacts",
                        systemImage: "person.2.slash",
                        description: Text("Contacts with an active Kit Pay wallet appear here.")
                    )
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(eligibleContacts) { contact in
                                Button {
                                    selectedContact = contact
                                } label: {
                                    VStack(spacing: 8) {
                                        RemoteAvatarView(
                                            name: contact.name,
                                            avatarURL: contact.avatarURL,
                                            size: 50
                                        )
                                        // A tile this narrow cannot show most full names, and a
                                        // first name alone is ambiguous between contacts. Long
                                        // names scroll past instead of being cut short.
                                        VerifiedAccountNameLabel(
                                            designation: contact.verification?.designation
                                        ) {
                                            MarqueeText(
                                                text: contact.name,
                                                font: .caption.bold(),
                                                color: KitColor.primaryText
                                            )
                                        }
                                    }
                                    .frame(width: 82)
                                    .padding(.vertical, 12)
                                    .background(selectedContact?.id == contact.id ? KitColor.paleGreen : .clear)
                                    .kitGlass(cornerRadius: 20, tint: selectedContact?.id == contact.id ? KitColor.green : .white)
                                }
                                .buttonStyle(.plain)
                                .disabled(secureShareNeedsRetry)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Text("Amount").font(.headline).foregroundStyle(KitColor.primaryText)
                HStack {
                    Text(model.selectedWallet?.currency.code ?? "UGX").bold().foregroundStyle(KitColor.green)
                    KitAmountTextField(
                        "0",
                        value: $amount,
                        mode: .decimal(
                            maximumFractionDigits:
                                model.selectedWallet?.currency.decimalScale ?? 2
                        ),
                        textStyle: .title
                    )
                        .disabled(secureShareNeedsRetry)
                }
                .padding(18)
                .kitGlass(cornerRadius: 22, tint: KitColor.paleGreen)

                TextField("What is it for? (optional)", text: $note)
                    .padding(16)
                    .kitGlass(cornerRadius: 18)
                    .disabled(secureShareNeedsRetry)

                if secureShareNeedsRetry {
                    Label(
                        "Your request was created and is waiting to be added to the chat. Retrying will not create another request.",
                        systemImage: "arrow.clockwise.circle"
                    )
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
                }

                if let error = flow.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(.red).frame(maxWidth: .infinity)
                }

                Button {
                    submitRequest()
                } label: {
                    if flow.isSubmitting || isSharingCreatedRequest {
                        ProgressView().tint(.white).frame(maxWidth: .infinity)
                    } else {
                        Label(
                            secureShareNeedsRetry ? "Retry delivery" : "Send request",
                            systemImage: secureShareNeedsRetry ? "arrow.clockwise.circle" : "paperplane.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(KitPrimaryButtonStyle())
                .disabled(
                    !model.appReviewDemoMutationsAllowed
                        || flow.isSubmitting
                        || isSharingCreatedRequest
                        || (!secureShareNeedsRetry && (
                            selectedContact == nil
                                || WalletMoney.apiAmount(
                                    amount,
                                    scale: model.selectedWallet?.currency.decimalScale ?? 2
                                ) == nil
                        ))
                )
                .contextMenu {
                    if canScheduleRequest {
                        Button {
                            submitRequest()
                        } label: {
                            Label("Send now", systemImage: "paperplane.fill")
                        }
                        Button {
                            isPickingScheduledTime = true
                        } label: {
                            Label("Send later", systemImage: "clock")
                        }
                    }
                }

                if canScheduleRequest {
                    Button {
                        isPickingScheduledTime = true
                    } label: {
                        Label("Send later", systemImage: "clock")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(KitSecondaryButtonStyle())
                    .disabled(flow.isSubmitting || isSharingCreatedRequest)
                }
            }
            .padding(20)
        }
        .sheet(isPresented: $isPickingScheduledTime) {
            ScheduleSendSheet(
                title: "Send later",
                confirmTitle: "Schedule",
                preview: schedulePreview,
                initialDate: nil,
                onSchedule: { date in scheduleSubmission(at: date) }
            )
        }
    }

    /// Send Later is offered only once the request is otherwise ready to go, so the option never
    /// appears next to an amount the screen would refuse anyway.
    private var canScheduleRequest: Bool {
        guard scheduleRequest != nil, !secureShareNeedsRetry, selectedContact != nil else {
            return false
        }
        return WalletMoney.apiAmount(
            amount,
            scale: model.selectedWallet?.currency.decimalScale ?? 2
        ) != nil
    }

    private var schedulePreview: String {
        let name = selectedContact?.name ?? "your contact"
        return "Request \(successAmount) from \(name)"
    }

    private func scheduleSubmission(at date: Date) {
        guard let scheduleRequest else { return }
        guard let wallet = model.selectedWallet,
              let selectedContact,
              let recipientUserID = ContactRecipientDirectory.recipientUserId(
                  for: selectedContact
              ),
              let apiAmount = WalletMoney.apiAmount(
                  amount,
                  scale: wallet.currency.decimalScale
              ),
              canEncodeSecureRequest(
                  amount: amount,
                  note: note,
                  currency: wallet.currency
              )
        else {
            flow.errorMessage = "Use a valid amount and a note that fits the secure payment card."
            return
        }
        guard !isSharingCreatedRequest, !flow.isSubmitting else { return }
        isSharingCreatedRequest = true
        Task {
            defer { isSharingCreatedRequest = false }
            // Approved now, raised later. The person arranging the request is present for this
            // check; the queue re-tests the session's authorization again before it acts.
            guard await authorizeSubmission() else { return }
            let scheduled = await scheduleRequest(
                PaymentRequestScheduleDraft(
                    destinationWalletID: wallet.id,
                    recipientUserID: recipientUserID,
                    recipientName: selectedContact.name,
                    amount: apiAmount,
                    currencyCode: wallet.currency.code,
                    note: note.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                    deliverAt: date
                )
            )
            guard scheduled else {
                if flow.errorMessage == nil {
                    flow.errorMessage = model.lastError
                        ?? "Kit Pay could not schedule this request. Please try again."
                }
                return
            }
            scheduledFor = date
            completed = true
        }
    }

    private var successView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: scheduledFor == nil ? "paperplane.fill" : "clock.badge.checkmark")
                .font(.system(size: 38))
                .foregroundStyle(.white)
                .frame(width: 88, height: 88)
                .background(KitColor.green.gradient, in: Circle())
            Text(scheduledFor == nil ? "Request sent" : "Request scheduled")
                .font(.largeTitle.bold())
                .foregroundStyle(KitColor.primaryText)
            Text(successDetail)
                .multilineTextAlignment(.center)
                .foregroundStyle(KitColor.secondaryText)
            if scheduledFor == nil, let id = flow.createdRequest?.id {
                Text("Request \(id)").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .frame(maxWidth: .infinity)
                .buttonStyle(KitPrimaryButtonStyle())
        }
        .padding(28)
    }

    private var successDetail: String {
        let name = selectedContact?.name ?? "Your contact"
        guard let scheduledFor else {
            return "\(name) will receive your request for \(successAmount)."
        }
        let when = ScheduledSendPolicy.label(
            for: scheduledFor,
            now: AppPresentationClock.now,
            calendar: AppPresentationClock.calendar,
            time: ScheduleSendSheet.timeLabel,
            day: ScheduleSendSheet.dayLabel
        )
        // Deliberately not "will be sent": nothing exists on the server yet, and the request is
        // raised only when the queue reaches it.
        return "Kit sends this request to \(name) \(when.lowercased()). Nothing has been sent yet."
    }

    private var successAmount: String {
        if let request = flow.createdRequest {
            return WalletMoney.displayAmount(
                request.amount,
                currency: request.currency.code,
                scale: request.currency.decimalScale
            )
        }
        return WalletMoney.displayAmount(
            amount,
            currency: model.selectedWallet?.currency.code ?? "UGX",
            scale: model.selectedWallet?.currency.decimalScale ?? 2
        )
    }

    private func updateContacts(_ contacts: [WalletContactDTO]) {
        flow.useSyncedContacts(contacts)
        if let selectedContact {
            if let selectedID = ContactRecipientDirectory.recipientUserId(for: selectedContact) {
                self.selectedContact = contacts.first {
                    ContactRecipientDirectory.recipientUserId(for: $0) == selectedID
                        && $0.canReceivePaymentRequest
                }
            } else {
                self.selectedContact = nil
            }
        }
        guard self.selectedContact == nil, let preselectedRecipientUserID else { return }
        self.selectedContact = contacts.first {
            ContactRecipientDirectory.recipientUserId(for: $0) == preselectedRecipientUserID
                && $0.canReceivePaymentRequest
        }
    }

    private func submitRequest() {
        guard !isSharingCreatedRequest, !flow.isSubmitting else { return }
        isSharingCreatedRequest = true
        Task {
            defer { isSharingCreatedRequest = false }
            let shared = await flow.secureShareSession.submit(
                create: {
                    guard let wallet = model.selectedWallet, let selectedContact else {
                        flow.errorMessage = "Choose a wallet and Kit Pay contact."
                        return nil
                    }
                    guard canEncodeSecureRequest(
                        amount: amount,
                        note: note,
                        currency: wallet.currency
                    ) else {
                        flow.errorMessage = "Use a valid amount and a note that fits the secure payment card."
                        return nil
                    }
                    guard model.secureMessagingAvailable else {
                        flow.errorMessage = CustomerFacingMessagingCopy.paymentRequestShareFailure
                        return nil
                    }
                    guard model.isOnline else {
                        flow.errorMessage = "Connect to the internet to create this payment request."
                        return nil
                    }
                    guard await authorizeSubmission() else { return nil }
                    guard await flow.request(
                        into: wallet,
                        from: selectedContact,
                        enteredAmount: amount,
                        note: note,
                        create: { destinationWalletID, recipientUserID, amount, note, idempotencyKey in
                            try await model.createPaymentRequest(
                                destinationWalletID: destinationWalletID,
                                requestedFromUserID: recipientUserID,
                                amount: amount,
                                note: note,
                                idempotencyKey: idempotencyKey
                            )
                        }
                    ) else { return nil }
                    guard let createdRequest = flow.createdRequest else {
                        flow.errorMessage = "Kit Pay created no confirmed request. Nothing was shared."
                        return nil
                    }
                    return createdRequest
                },
                share: { request in
                    await shareRequestInChat(request)
                }
            )
            secureShareNeedsRetry = flow.secureShareSession.hasPendingRequest
            completed = shared
            if !shared, secureShareNeedsRetry {
                flow.errorMessage = "Your request was created and is awaiting delivery in the chat. Tap retry to finish sending it; another request will not be created."
            }
        }
    }

    private func shareRequestInChat(_ request: PaymentRequestDTO) async -> Bool {
        if let shareCreatedRequest {
            return await shareCreatedRequest(request)
        }
        guard let rawRecipientUserID = request.requestedFromUserId,
              rawRecipientUserID == rawRecipientUserID.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ),
              let recipientUUID = UUID(uuidString: rawRecipientUserID)
        else {
            flow.errorMessage = "Kit Pay could not confirm who should receive this request."
            return false
        }
        let recipientUserID = recipientUUID.uuidString.lowercased()
        let recipientName = flow.contacts.first(where: {
            ContactRecipientDirectory.recipientUserId(for: $0) == recipientUserID
        })?.name.nilIfBlank ?? "Kit Pay contact"
        let queued = await model.queuePaymentRequest(
            request,
            recipientId: recipientUserID,
            title: recipientName
        )
        if !queued, flow.errorMessage == nil {
            flow.errorMessage = "Your request was created and is waiting for chat delivery. Tap retry to continue."
        }
        return queued
    }

    private func authorizeSubmission() async -> Bool {
        guard await model.authorizePaymentRequestSubmission() else {
            flow.errorMessage = model.biometricErrorMessage
                ?? "Biometric approval is required to send this payment request."
            return false
        }
        return true
    }

    private func canEncodeSecureRequest(
        amount: String,
        note: String,
        currency: CurrencyDTO
    ) -> Bool {
        guard let scale = Int(currency.scale),
              let apiAmount = WalletMoney.apiAmount(amount, scale: scale),
              let amountMinor = KitPaymentMessage.minorUnits(for: apiAmount, scale: scale)
        else { return false }
        let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        return KitPaymentMessage(
            action: .request,
            paymentRequestId: "00000000-0000-0000-0000-000000000000",
            amountMinor: amountMinor,
            currencyCode: currency.code,
            currencyScale: scale,
            note: cleanNote
        ) != nil
    }
}

struct ReceiveMoneyView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var flow: WalletFlowModel
    @State private var comingSoonMessage: String?
    @State private var showingMerchantQR = false

    private var shareText: String {
        WalletShare.receive(profile: model.profile, wallet: model.selectedWallet)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: "qrcode")
                    .font(.system(size: 74, weight: .thin))
                    .foregroundStyle(KitColor.primaryText)
                    .frame(width: 156, height: 156)
                    .kitGlass(cornerRadius: 30, tint: KitColor.paleGreen)
                Text(model.profile?.name ?? "Kit Pay user")
                    .font(.title2.bold())
                    .foregroundStyle(KitColor.primaryText)
                Text(identityLine)
                    .foregroundStyle(KitColor.secondaryText)
                    .textSelection(.enabled)
                Text("Share your Kit Pay tag or verified phone number. Business wallets can also create signed static or amount-bound merchant QR codes.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(KitColor.secondaryText)

                HStack(spacing: 12) {
                    Button { openMerchantQR() } label: {
                        Label("My QR", systemImage: "qrcode").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(KitSecondaryButtonStyle())
                    .disabled(!model.appReviewDemoMutationsAllowed)

                    if canRequestMoney {
                        NavigationLink {
                            RequestMoneyView(flow: flow)
                        } label: {
                            Label("Request", systemImage: "doc.text").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(KitSecondaryButtonStyle())
                        .disabled(!model.appReviewDemoMutationsAllowed)
                    } else {
                        Button { comingSoonMessage = "Coming soon: Request amount." } label: {
                            Label("Request", systemImage: "doc.text").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(KitSecondaryButtonStyle())
                    }
                }

                Button { openMerchantQR() } label: {
                    Label("Set amount", systemImage: "number").frame(maxWidth: .infinity)
                }
                .buttonStyle(KitSecondaryButtonStyle())
                .disabled(!model.appReviewDemoMutationsAllowed)

                ShareLink(item: shareText) {
                    Label("Share my details", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(KitPrimaryButtonStyle())
            }
            .padding(24)
        }
        .background(KitColor.canvas.ignoresSafeArea())
        .navigationTitle("Receive money")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } } }
        .sheet(isPresented: $showingMerchantQR) {
            MerchantReceiveQRView().environmentObject(model)
                .presentationBackground(.ultraThinMaterial)
        }
        .alert("Kit Pay", isPresented: Binding(
            get: { comingSoonMessage != nil },
            set: { if !$0 { comingSoonMessage = nil } }
        )) {
            Button("OK") { comingSoonMessage = nil }
        } message: {
            Text(comingSoonMessage ?? "")
        }
    }

    private var identityLine: String {
        let tag = model.profile?.tag?.nilIfEmpty.map { $0.hasPrefix("@") ? $0 : "@\($0)" }
        return [tag, model.profile?.phone?.nilIfEmpty].compactMap { $0 }.joined(separator: " · ")
    }

    private var canRequestMoney: Bool {
        let features = model.capabilities?.features?.compactMapValues { $0 }
        return features?["wallets"] == true && features?["payment_requests"] == true
    }

    private func openMerchantQR() {
        guard model.appReviewDemoMutationsAllowed else {
            comingSoonMessage = AppReviewDemoMutationPolicy.readOnlyMessage
            return
        }
        guard model.capabilities?.enablesMerchantQRPayments == true else {
            comingSoonMessage = "Merchant QR payments are not enabled for this Kit Pay account."
            return
        }
        guard model.isOnline else {
            comingSoonMessage = "Connect to the internet to create a signed payment QR."
            return
        }
        showingMerchantQR = true
    }
}

struct TransactionsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if visibleTransactions.isEmpty {
                ContentUnavailableView(
                    "No activity yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text(model.isOnline ? "Wallet transactions will appear here." : "Your latest cached activity is available offline.")
                )
            } else {
                List {
                    if let wallet = model.selectedWallet {
                        Section {
                            HStack(spacing: 12) {
                                activityTotal(
                                    title: "Money Added",
                                    amount: KitMoney.formatted(
                                        minorUnits: activitySummary.addedMinorUnits,
                                        code: wallet.currency.code,
                                        scale: wallet.currency.decimalScale
                                    ),
                                    systemImage: "arrow.down.left",
                                    color: KitColor.green
                                )
                                activityTotal(
                                    title: "Money Deducted",
                                    amount: KitMoney.formatted(
                                        minorUnits: activitySummary.deductedMinorUnits,
                                        code: wallet.currency.code,
                                        scale: wallet.currency.decimalScale
                                    ),
                                    systemImage: "arrow.up.right",
                                    color: KitColor.primaryText
                                )
                            }
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                        }
                    }

                    Section("Activity") {
                        ForEach(visibleTransactions) { transaction in
                            NavigationLink {
                                TransactionDetailView(transaction: transaction)
                            } label: {
                                WalletTransactionRow(transaction: transaction)
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background(KitColor.canvas.ignoresSafeArea())
        .navigationTitle("Transactions")
        .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } } }
        .refreshable { await model.refresh(userInitiated: true) }
    }

    private var visibleTransactions: [WalletTransaction] {
        guard let wallet = model.selectedWallet else { return [] }
        return CustomerTransactionPresentationPolicy.customerVisibleTransactions(
            model.state.transactions,
            for: wallet
        )
    }

    private var activitySummary: CustomerTransactionActivitySummary {
        guard let wallet = model.selectedWallet else { return .zero }
        return CustomerTransactionPresentationPolicy.activitySummary(
            visibleTransactions,
            for: wallet
        )
    }

    private func activityTotal(
        title: String,
        amount: String,
        systemImage: String,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.caption.bold())
                .foregroundStyle(KitColor.secondaryText)
            Text(amount)
                .font(.headline.weight(.bold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .accessibilityLabel("\(title), \(amount)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .kitGlass(cornerRadius: 20)
    }
}

struct TransactionDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    let transaction: WalletTransaction

    var body: some View {
        Group {
            if let transaction = customerVisibleTransaction {
                ScrollView {
                    VStack(spacing: 18) {
                        // The ledger carries the counterparty's id but not their photo, so the
                        // face comes from the persisted contact directory and resolves offline.
                        RemoteAvatarView(
                            name: transaction.customerCounterparty?.name ?? "Kit Pay",
                            avatarURL: model.contactAvatarURL(
                                forUserID: transaction.customerCounterparty?.id
                            ),
                            size: 68
                        )
                        VerifiedAccountNameLabel(
                            designation: model.contactVerification(
                                forUserID: transaction.customerCounterparty?.id
                            )
                        ) {
                            Text(
                                transaction.customerCounterparty?.name
                                    ?? transaction.type.displayLabel
                            )
                            .font(.title2.bold())
                            .foregroundStyle(KitColor.primaryText)
                        }
                        Text(transaction.customerImpactLabel)
                            .font(.caption.bold())
                            .foregroundStyle(KitColor.secondaryText)
                        Text(transaction.customerImpactDisplayAmount)
                            .font(.system(size: 38, weight: .heavy, design: .rounded))
                            .foregroundStyle(
                                transaction.customerDirection == "credit"
                                    ? KitColor.green
                                    : KitColor.primaryText
                            )
                        Text(transaction.status.capitalized)
                            .font(.caption.bold())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(statusColor.opacity(0.16), in: Capsule())
                            .foregroundStyle(statusColor)

                        VStack(spacing: 0) {
                            detailRow("Date", transaction.occurredAt.displayDate)
                            Divider()
                            detailRow("Reference", transaction.reference)
                            Divider()
                            detailRow("Type", transaction.type.displayLabel)
                            if let note = transaction.note?.nilIfEmpty {
                                Divider()
                                detailRow("Note", note)
                            }
                        }
                        .padding(18)
                        .kitGlass(cornerRadius: 24)

                        ShareReceiptButton(transaction: transaction, senderName: nil)
                    }
                    .padding(24)
                }
            } else {
                ContentUnavailableView(
                    "Transaction unavailable",
                    systemImage: "lock.shield",
                    description: Text(
                        "Refresh your wallet activity to load a verified transaction record."
                    )
                )
                .padding(24)
            }
        }
        .background(KitColor.canvas.ignoresSafeArea())
        .navigationTitle("Transaction")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } } }
    }

    private var customerVisibleTransaction: WalletTransaction? {
        CustomerTransactionPresentationPolicy.customerVisibleTransaction(
            transaction,
            for: model.selectedWallet
        )
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(KitColor.secondaryText)
            Spacer(minLength: 20)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.subheadline)
        .padding(.vertical, 10)
    }

    private var statusColor: Color {
        switch transaction.status.lowercased() {
        case "completed", "successful", "success": KitColor.green
        case "failed", "reversed": .red
        default: .orange
        }
    }
}

struct WalletTransactionRow: View {
    let transaction: WalletTransaction

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: transaction.customerDirection == "credit" ? "arrow.down.left" : "arrow.up.right")
                .font(.headline)
                .foregroundStyle(transaction.customerDirection == "credit" ? KitColor.green : KitColor.primaryText)
                .frame(width: 46, height: 46)
                .background(.thinMaterial, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(transaction.customerCounterparty?.name ?? transaction.type.displayLabel)
                    .font(.headline)
                    .foregroundStyle(KitColor.primaryText)
                Text(transaction.occurredAt.displayDate)
                    .font(.caption)
                    .foregroundStyle(KitColor.secondaryText)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(transaction.customerImpactLabel)
                    .font(.caption2)
                    .foregroundStyle(KitColor.secondaryText)
                Text(transaction.customerImpactDisplayAmount)
                    .font(.subheadline.bold())
                    .foregroundStyle(transaction.customerDirection == "credit" ? KitColor.green : KitColor.primaryText)
            }
        }
        .padding(.vertical, 5)
    }
}

struct KitPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.vertical, 16)
            .padding(.horizontal, 18)
            .background(KitColor.green.opacity(configuration.isPressed ? 0.78 : 1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: KitColor.green.opacity(configuration.isPressed ? 0.08 : 0.24), radius: 14, y: 7)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

struct KitSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(KitColor.primaryText)
            .padding(.vertical, 15)
            .padding(.horizontal, 14)
            .background(.ultraThinMaterial.opacity(configuration.isPressed ? 0.72 : 1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(.white.opacity(0.65), lineWidth: 0.8)
                    .allowsHitTesting(false)
            }
    }
}

private enum WalletMoney {
    static func apiAmount(_ raw: String, scale: Int) -> String? {
        let scale = min(max(scale, 0), 9)
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
        let pieces = cleaned.split(separator: ".", omittingEmptySubsequences: false)
        guard !cleaned.isEmpty, pieces.count <= 2 else { return nil }
        let wholeRaw = String(pieces.first ?? "")
        let fractionRaw = pieces.count == 2 ? String(pieces[1]) : ""
        guard !wholeRaw.isEmpty,
              wholeRaw.allSatisfy(\.isNumber),
              fractionRaw.allSatisfy(\.isNumber),
              fractionRaw.count <= scale
        else { return nil }

        let whole = String(wholeRaw.drop(while: { $0 == "0" })).nilIfEmpty ?? "0"
        let fraction = fractionRaw + String(repeating: "0", count: scale - fractionRaw.count)
        let result = scale == 0 ? whole : "\(whole).\(fraction)"
        guard let decimal = Decimal(string: result, locale: Locale(identifier: "en_US_POSIX")), decimal > 0 else {
            return nil
        }
        return result
    }

    /// Renders a canonical amount the way the amount field renders it, so the review step, the
    /// confirm button and the receipt cannot disagree with what the customer typed.
    static func displayAmount(_ raw: String, currency: String, scale: Int = 2) -> String {
        KitMoney.formatted(raw, code: currency, scale: scale)
    }
}

private enum WalletShare {
    static func receive(profile: UserProfile?, wallet: Wallet?) -> String {
        var lines = ["Send me money on Kit Pay."]
        if let name = profile?.name?.nilIfEmpty { lines.append("Name: \(name)") }
        if let tag = profile?.tag?.nilIfEmpty { lines.append("Kit tag: \(tag.hasPrefix("@") ? tag : "@\(tag)")") }
        if let phone = profile?.phone?.nilIfEmpty { lines.append("Phone: \(phone)") }
        if let account = wallet?.accountNumber?.nilIfEmpty { lines.append("Account: \(account)") }
        return lines.joined(separator: "\n")
    }
}

private enum WalletFlowError: LocalizedError {
    case pinSetupRejected
    case unconfirmedTransfer
    case unconfirmedPaymentRequest
    case unconfirmedScheduledPayment

    var errorDescription: String? {
        switch self {
        case .pinSetupRejected: "Kit Pay did not confirm the new wallet PIN. Please try again."
        case .unconfirmedTransfer:
            "Kit Pay did not confirm the exact transfer total. Check your activity before trying again."
        case .unconfirmedPaymentRequest: "Kit Pay did not confirm the exact payment request. Check your requests before trying again."
        case .unconfirmedScheduledPayment: "Kit Pay did not confirm the exact scheduled payment. Nothing new was scheduled."
        }
    }
}

extension WalletContactDTO {
    var canReceiveTransfer: Bool {
        !id.isEmpty && isKitUser == true && receivingWalletId?.nilIfEmpty != nil
    }

    var canReceivePaymentRequest: Bool {
        !id.isEmpty && isKitUser == true
    }
}

private extension WalletTransaction {
    var customerImpactDisplayAmount: String {
        KitMoney.formatted(customerImpactAmount, currency: currency)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }

    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var displayLabel: String {
        replacingOccurrences(of: "_", with: " ").capitalized
    }

    var displayDate: String {
        guard let date = KitServerDateParser.date(from: self) else { return self }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// The backend emits both plain and fractional-second ISO 8601 timestamps; parsing must accept
/// both or transaction rows render the raw string. Formatters are cached — allocating an
/// ISO8601DateFormatter per row is a measurable scroll hitch.
enum KitServerDateParser {
    private static let plain = ISO8601DateFormatter()
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func date(from value: String) -> Date? {
        plain.date(from: value) ?? fractional.date(from: value)
    }
}
