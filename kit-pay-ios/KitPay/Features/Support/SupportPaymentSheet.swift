import SwiftUI

/// `.sheet(item:)` payload for the payment sheet: a nil envelope opens a fresh compose flow, a
/// non-nil one resumes the ticket's frozen attempt at the confirmation step.
struct SupportPaymentSheetPresentation: Identifiable {
    let envelope: SupportPaymentEnvelope?
    var id: String { envelope?.idempotencyKey ?? "new" }
}

/// Customer-initiated payment to the company beneficiary inside a support ticket, mirroring the
/// wallet-transfer approval flow (same step-up, same confirmation idiom) with the support safety
/// rules on top:
///  - the payee is ALWAYS the server-advertised company beneficiary — there is no destination
///    input anywhere, and the receipt shows only the server-authored beneficiary identity;
///  - the reviewed attempt is FROZEN in verified protected storage before the POST, so an
///    ambiguous outcome (timeout, opaque 503, expired step-up) parks as a pending attempt that
///    can only be resolved by verbatim replay under the same idempotency key — never re-minted;
///  - step-up failures are handled separately from POST failures: an approval error can never be
///    mistaken for a server rejection, so it can never clear an envelope an earlier attempt may
///    already have committed;
///  - only an authoritative validated receipt or a definitive server rejection of the POST
///    clears the frozen record, and only with read-back-verified removal.
struct SupportPaymentSheet: View {
    let ticketID: String
    let flow: SupportFlowBinding
    /// Pre-flight payee name from the payments advertisement; nil when resuming while the gate
    /// is dark (the receipt's name is always the server's own).
    let advertisedBeneficiaryName: String?
    let onEnvelopeChange: (SupportPaymentEnvelope?) -> Void
    let onCompleted: () -> Void

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private enum Stage {
        case compose
        case confirm(SupportPaymentEnvelope)
        case receipt(SupportPaymentReceiptDTO, replayed: Bool)
    }

    @State private var stage: Stage
    @State private var selectedWalletID: String?
    @State private var amount: String
    @State private var note: String
    @State private var pin = ""
    /// True once an envelope has been durably frozen (or when resuming one): from then on the
    /// only exits from the confirmation step are an authoritative outcome, an explicit discard,
    /// or leaving the attempt parked as pending.
    @State private var frozen: Bool
    @State private var isSubmitting = false
    @State private var isDiscarding = false
    @State private var showingDiscardConfirmation = false
    @State private var errorMessage: String?
    /// Receipt-stage warning when the payment succeeded but the frozen record's verified
    /// removal failed — the attempt stays visibly pending and replaying it later is harmless.
    @State private var cleanupNote: String?

    init(
        ticketID: String,
        flow: SupportFlowBinding,
        resume: SupportPaymentEnvelope?,
        advertisedBeneficiaryName: String?,
        onEnvelopeChange: @escaping (SupportPaymentEnvelope?) -> Void,
        onCompleted: @escaping () -> Void
    ) {
        self.ticketID = ticketID
        self.flow = flow
        self.advertisedBeneficiaryName = advertisedBeneficiaryName
        self.onEnvelopeChange = onEnvelopeChange
        self.onCompleted = onCompleted
        _stage = State(initialValue: resume.map { .confirm($0) } ?? .compose)
        _frozen = State(initialValue: resume != nil)
        _amount = State(initialValue: resume?.amount ?? "")
        _note = State(initialValue: resume?.note ?? "")
    }

    var body: some View {
        NavigationStack {
            Group {
                switch stage {
                case .compose:
                    composeStage
                case .confirm(let envelope):
                    confirmStage(envelope)
                case .receipt(let receipt, let replayed):
                    receiptStage(receipt, replayed: replayed)
                }
            }
            .background(KitColor.canvas.ignoresSafeArea())
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { leadingToolbarButton }
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(isSubmitting || isDiscarding)
        .confirmationDialog(
            "Discard this payment attempt?",
            isPresented: $showingDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard attempt", role: .destructive) {
                if case .confirm(let envelope) = stage {
                    Task { await discard(envelope) }
                }
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text(
                "If you're unsure whether it went through, check your wallet activity first. "
                    + "Discarding only forgets the attempt on this device."
            )
        }
    }

    private var navigationTitle: String {
        switch stage {
        case .compose: "Send money to Kit Pay"
        case .confirm: "Confirm payment"
        case .receipt: "Payment receipt"
        }
    }

    @ViewBuilder
    private var leadingToolbarButton: some View {
        switch stage {
        case .compose:
            Button("Cancel") { dismiss() }
        case .confirm:
            if frozen {
                // A frozen attempt parks as pending; it is never silently un-frozen.
                Button("Later") { dismiss() }
                    .disabled(isSubmitting || isDiscarding)
            } else {
                Button("Back") {
                    errorMessage = nil
                    stage = .compose
                }
                .disabled(isSubmitting)
            }
        case .receipt:
            Button("Done") { dismiss() }
        }
    }

    // MARK: - Compose

    private var wallets: [Wallet] { model.state.wallets }

    private var selectedWallet: Wallet? {
        if let selectedWalletID, let chosen = wallets.first(where: { $0.id == selectedWalletID }) {
            return chosen
        }
        return model.selectedWallet
    }

    private var beneficiaryDisplayName: String {
        advertisedBeneficiaryName ?? "Kit Pay"
    }

    private var composeStage: some View {
        ScrollView {
            VStack(spacing: 22) {
                beneficiaryCard

                if wallets.count > 1 {
                    Menu {
                        ForEach(wallets) { wallet in
                            Button {
                                selectedWalletID = wallet.id
                            } label: {
                                Text(
                                    "\(wallet.name) · "
                                        + KitMoney.formatted(
                                            wallet.balances.available,
                                            currency: wallet.currency
                                        )
                                )
                            }
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("From").font(.caption).foregroundStyle(KitColor.secondaryText)
                                Text(selectedWallet?.name ?? "Choose a wallet").font(.headline)
                            }
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.footnote)
                                .foregroundStyle(KitColor.secondaryText)
                        }
                        .padding(17)
                        .kitGlass(cornerRadius: 18)
                    }
                }

                VStack(spacing: 9) {
                    Text("Amount").font(.subheadline).foregroundStyle(KitColor.secondaryText)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(selectedWallet?.currency.code ?? "UGX")
                            .font(.title3.bold())
                            .foregroundStyle(KitColor.green)
                        KitAmountTextField(
                            "0",
                            value: $amount,
                            mode: .decimal(
                                maximumFractionDigits: selectedWallet?.currency.decimalScale ?? 2
                            ),
                            textStyle: .hero,
                            textAlignment: .center
                        )
                        .frame(maxWidth: 230)
                    }
                    if let wallet = selectedWallet {
                        Text(
                            "Balance: "
                                + KitMoney.formatted(wallet.balances.available, currency: wallet.currency)
                        )
                        .font(.caption)
                        .foregroundStyle(KitColor.secondaryText)
                    }
                }
                .padding(.vertical, 30)
                .frame(maxWidth: .infinity)
                .kitGlass(cornerRadius: 30, tint: KitColor.paleGreen)

                TextField("Add a note (optional)", text: $note)
                    .textFieldStyle(.plain)
                    .padding(17)
                    .kitGlass(cornerRadius: 18)

                inlineError

                Button {
                    review()
                } label: {
                    Label("Review payment", systemImage: "arrow.up.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(KitPrimaryButtonStyle())
                .disabled(
                    !model.appReviewDemoMutationsAllowed
                        || selectedWallet == nil
                        || SupportPaymentContract.apiAmount(
                            amount,
                            scale: selectedWallet?.currency.decimalScale ?? 2
                        ) == nil
                )
            }
            .padding(20)
        }
    }

    private var beneficiaryCard: some View {
        HStack(spacing: 12) {
            // Support blue, not KYC green: the seal claims verified OFFICIAL Kit Pay identity,
            // the same designation the ticket thread uses.
            Image(systemName: "checkmark.seal.fill")
                .font(.title3)
                .foregroundStyle(KitColor.verifiedBlue)
            VStack(alignment: .leading, spacing: 3) {
                Text("Money goes to \(beneficiaryDisplayName)")
                    .font(.headline)
                Text(
                    "Official Kit Pay company account. Kit Pay never asks you to pay a person "
                        + "or an outside account in support chats."
                )
                .font(.caption)
                .foregroundStyle(KitColor.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .kitGlass(cornerRadius: 18, tint: KitColor.paleGreen, shadow: false)
    }

    /// Normalizes the reviewed intent and freezes it into a NEW envelope with a freshly minted
    /// idempotency key. Minting here is safe precisely because nothing has been frozen or sent
    /// yet — once `submit` persists the envelope, its key is never re-minted.
    private func review() {
        guard let wallet = selectedWallet,
              let sourceWalletID = SupportContract.canonicalUUID(wallet.id)
        else {
            errorMessage = "Choose a wallet to pay from."
            return
        }
        guard let apiAmount = SupportPaymentContract.apiAmount(
            amount,
            scale: wallet.currency.decimalScale
        ) else {
            errorMessage = "Enter an amount greater than zero."
            return
        }
        guard SupportPaymentContract.isCanonicalAPIAmount(apiAmount) else {
            errorMessage = "Enter a smaller amount."
            return
        }
        let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard SupportPaymentContract.isCoherentNote(cleanNote) else {
            errorMessage = "Keep the note under \(SupportPaymentContract.noteMaximumLength) characters."
            return
        }
        let envelope = SupportPaymentEnvelope(
            accountID: flow.accountID,
            ticketID: ticketID,
            sourceWalletID: sourceWalletID,
            amount: apiAmount,
            note: cleanNote,
            currencyCode: wallet.currency.code,
            currencyScale: wallet.currency.decimalScale,
            idempotencyKey: SupportPaymentContract.mintIdempotencyKey()
        )
        guard envelope.isValid(accountID: flow.accountID, ticketID: ticketID) else {
            errorMessage = "This payment can't be prepared safely."
            return
        }
        errorMessage = nil
        stage = .confirm(envelope)
    }

    // MARK: - Confirm

    private func confirmStage(_ envelope: SupportPaymentEnvelope) -> some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(KitColor.verifiedBlue)
                Text(beneficiaryDisplayName).font(.title2.bold())
                Text("Official Kit Pay company account")
                    .font(.caption)
                    .foregroundStyle(KitColor.secondaryText)
                Text(displayedAmount(envelope))
                    .font(.system(size: 38, weight: .heavy, design: .rounded))

                if let noteText = envelope.note {
                    Text("“\(noteText)”").foregroundStyle(KitColor.secondaryText)
                }

                HStack {
                    Text("From").foregroundStyle(KitColor.secondaryText)
                    Spacer()
                    Text(
                        wallets.first(
                            where: { $0.id.lowercased() == envelope.sourceWalletID }
                        )?.name ?? "Your wallet"
                    )
                    .bold()
                }
                .padding(17)
                .kitGlass(cornerRadius: 18)

                if frozen {
                    Label {
                        Text(
                            "This payment wasn't confirmed earlier, so it's saved here. "
                                + "Confirming it again is safe — it will not charge you twice."
                        )
                        .font(.footnote)
                        .foregroundStyle(KitColor.secondaryText)
                    } icon: {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(KitColor.green)
                    }
                    .padding(17)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .kitGlass(cornerRadius: 18, shadow: false)
                }

                if model.financialApprovalUsesBiometrics {
                    Label {
                        Text(
                            "Approve with \(model.biometricDisplayName). "
                                + "Your approval covers only this exact payment."
                        )
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
                    Task { await submit(envelope) }
                } label: {
                    if isSubmitting {
                        ProgressView().tint(.white).frame(maxWidth: .infinity)
                    } else {
                        Label(
                            "Pay \(displayedAmount(envelope))",
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
                        || isSubmitting
                )

                if frozen {
                    Button(role: .destructive) {
                        showingDiscardConfirmation = true
                    } label: {
                        if isDiscarding {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Discard this attempt").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(isSubmitting || isDiscarding)
                }
            }
            .padding(24)
        }
    }

    private func displayedAmount(_ envelope: SupportPaymentEnvelope) -> String {
        KitMoney.formatted(
            envelope.amount,
            code: envelope.currencyCode,
            scale: envelope.currencyScale
        )
    }

    // MARK: - Receipt

    private func receiptStage(_ receipt: SupportPaymentReceiptDTO, replayed: Bool) -> some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(KitColor.green)
                Text(replayed ? "Already completed" : "Payment complete")
                    .font(.title2.bold())
                Text(
                    KitMoney.formatted(
                        receipt.transaction.amount,
                        code: receipt.transaction.currency.code,
                        scale: receipt.transaction.currency.decimalScale
                    )
                )
                .font(.system(size: 38, weight: .heavy, design: .rounded))
                Text("Paid to \(receipt.beneficiary.displayName)")
                    .font(.headline)
                Text("Official Kit Pay company account")
                    .font(.caption)
                    .foregroundStyle(KitColor.secondaryText)

                if replayed {
                    Text(
                        "This payment was already completed by an earlier attempt. "
                            + "You were not charged twice."
                    )
                    .font(.footnote)
                    .foregroundStyle(KitColor.secondaryText)
                    .multilineTextAlignment(.center)
                }

                VStack(spacing: 0) {
                    receiptRow("Reference", receipt.transaction.reference)
                    Divider()
                    receiptRow("Status", receipt.transaction.status.capitalized)
                    Divider()
                    receiptRow("When", receiptTimestamp(receipt.transaction.occurredAt))
                }
                .kitGlass(cornerRadius: 18)

                if let cleanupNote {
                    Label {
                        Text(cleanupNote)
                            .font(.footnote)
                            .foregroundStyle(KitColor.secondaryText)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    .padding(17)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .kitGlass(cornerRadius: 18, shadow: false)
                }

                Button {
                    dismiss()
                } label: {
                    Text("Done").frame(maxWidth: .infinity)
                }
                .buttonStyle(KitPrimaryButtonStyle())
            }
            .padding(24)
        }
    }

    private func receiptRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(KitColor.secondaryText)
            Spacer()
            Text(value).bold().multilineTextAlignment(.trailing)
        }
        .padding(17)
    }

    private func receiptTimestamp(_ iso8601: String) -> String {
        guard let date = SupportDates.parse(iso8601) else { return iso8601 }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    @ViewBuilder
    private var inlineError: some View {
        if let errorMessage {
            Text(errorMessage)
                .font(.footnote)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Actions

    /// The one path that can move money. Order is load-bearing:
    ///  1. verified FREEZE of the envelope (no durable proof, no approval, no POST);
    ///  2. fresh step-up over the envelope's exact intent — an approval failure only reports and
    ///     returns, because it proves nothing about earlier attempts under the same key;
    ///  3. the POST itself, replayed verbatim on retries; only its own definitive rejection or
    ///     an authoritative receipt may clear the frozen record.
    private func submit(_ envelope: SupportPaymentEnvelope) async {
        guard !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        defer {
            isSubmitting = false
            pin = ""
        }
        guard await SupportSessionScope.isCurrent(flow) else {
            errorMessage = SupportErrorText.describe(APIClientError.signedOut)
            return
        }

        do {
            try SupportPaymentStore.shared.save(envelope)
        } catch {
            // Nothing was sent; the customer keeps editing. No frozen record exists.
            errorMessage = SupportErrorText.describe(error)
            return
        }
        frozen = true
        onEnvelopeChange(envelope)

        let verification: StepUpVerificationDTO
        do {
            verification = try await APIClientSessionBinding.$sessionID.withValue(flow.sessionID) {
                try await model.authorizeFinancialStepUp(
                    purpose: SupportPaymentContract.stepUpPurpose,
                    intent: envelope.stepUpIntent,
                    pin: pin,
                    reason: "Approve paying \(displayedAmount(envelope)) to \(beneficiaryDisplayName)"
                )
            }
        } catch is CancellationError {
            return
        } catch {
            guard await SupportSessionScope.isCurrent(flow) else { return }
            errorMessage = SupportErrorText.describe(error)
            return
        }

        do {
            let (receipt, replayed) = try await APIClientSessionBinding.$sessionID
                .withValue(flow.sessionID) {
                    try await APIClient.shared.supportPayment(
                        ticketID: envelope.ticketID,
                        sourceWalletID: envelope.sourceWalletID,
                        amount: envelope.amount,
                        note: envelope.note,
                        idempotencyKey: envelope.idempotencyKey,
                        stepUpToken: verification.stepUpToken
                    )
                }
            try Task.checkCancellation()
            guard await SupportSessionScope.isCurrent(flow) else { return }
            do {
                try SupportPaymentStore.shared.clear(
                    accountID: envelope.accountID,
                    ticketID: envelope.ticketID
                )
                frozen = false
                onEnvelopeChange(nil)
            } catch {
                cleanupNote = "This payment is confirmed, but the saved attempt couldn't be "
                    + "cleared from this device yet, so it may still show as pending. "
                    + "Confirming it again later will not charge you twice."
            }
            stage = .receipt(receipt, replayed: replayed)
            onCompleted()
        } catch is CancellationError {
            return
        } catch {
            guard await SupportSessionScope.isCurrent(flow) else { return }
            if SupportContract.isDefinitiveRejection(error) {
                // The server authoritatively refused THIS key's request, and its ledger check
                // runs before the refusal paths, so nothing settled under this key. Safe to
                // clear — but only with verified removal.
                do {
                    try SupportPaymentStore.shared.clear(
                        accountID: envelope.accountID,
                        ticketID: envelope.ticketID
                    )
                    frozen = false
                    onEnvelopeChange(nil)
                    errorMessage = SupportErrorText.describe(error)
                    stage = .compose
                } catch {
                    errorMessage = SupportErrorText.describe(
                        SupportPaymentStoreError.unverifiedRemoval
                    )
                }
            } else {
                // Ambiguous: the transfer may or may not have settled. The envelope stays
                // frozen for verbatim replay; nothing is retried automatically.
                errorMessage = SupportErrorText.describe(
                    SupportContractError.paymentUnconfirmed
                )
            }
        }
    }

    /// Explicit, user-confirmed abandonment of a frozen attempt. Local-only and verified; if the
    /// account or session changed underneath the sheet, the original account's record is left
    /// untouched.
    private func discard(_ envelope: SupportPaymentEnvelope) async {
        guard !isDiscarding, !isSubmitting else { return }
        isDiscarding = true
        defer { isDiscarding = false }
        guard await SupportSessionScope.isCurrent(flow) else {
            dismiss()
            return
        }
        do {
            try SupportPaymentStore.shared.clear(
                accountID: envelope.accountID,
                ticketID: envelope.ticketID
            )
            frozen = false
            onEnvelopeChange(nil)
            dismiss()
        } catch {
            errorMessage = SupportErrorText.describe(error)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
