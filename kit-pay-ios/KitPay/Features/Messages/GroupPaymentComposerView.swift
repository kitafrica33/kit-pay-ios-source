import SwiftUI

/// Sending one payment into a group chat.
///
/// Three decisions, in the order people actually make them: who is being paid, how the money is
/// divided, and then approval. Everything is gold, so at no point does this look like the
/// one-to-one transfer sheet it is not — a group payment is claimed by each member in the group,
/// and that is a different promise.
struct GroupPaymentComposerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let conversationId: String
    let conversationTitle: String
    let members: [GroupPaymentDraftPolicy.Member]
    let wallet: Wallet
    let isSubmitting: Bool
    let errorMessage: String?
    /// Returns the confirmed payment, so the caller can post the announcement into the thread.
    let submit: (CreateGroupPaymentBody, String) async -> GroupPaymentDTO?
    /// Server-owned scheduling remains distinct from delayed E2EE messages: the immutable plan
    /// executes even while this iPhone is locked or offline.
    let schedulePayment: ((CreateGroupPaymentBody, Date, String) async
        -> ScheduledGroupPaymentDTO?)?

    @State private var audience: GroupPaymentAudience = .all
    @State private var splitMode: GroupPaymentSplitMode = .even
    @State private var selectedIds: Set<String> = []
    @State private var totalInput = ""
    @State private var customAmounts: [String: String] = [:]
    @State private var note = ""
    @State private var pin = ""
    @State private var scheduledFor: Date?
    @State private var showsSchedulePicker = false
    @State private var validationMessage: String?
    /// Claimed synchronously before the async task is created, closing the small window in which
    /// two fast taps could otherwise both enter `submit` before the observable view model redraws.
    @State private var submissionGate = GroupPaymentSubmissionGate()

    private var isSubmissionInFlight: Bool {
        isSubmitting || submissionGate.isSubmitting
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    heading
                    audiencePicker
                    if audience == .selected { memberPicker }
                    splitPicker
                    amountSection
                    noteField
                    deliverySection
                    reviewLine
                    approval
                    if let message = validationMessage ?? errorMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    sendButton
                }
                .padding(22)
            }
            .background(KitColor.canvas.ignoresSafeArea())
            .navigationTitle("Pay the group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSubmissionInFlight)
                }
            }
            .onAppear {
                if selectedIds.isEmpty {
                    selectedIds = Set(members.map(\.userId))
                }
            }
            .onChange(of: splitMode) { _, mode in
                // Different amounts each is only meaningful for members you picked by hand.
                if mode == .custom { audience = .selected }
                validationMessage = nil
            }
            .onChange(of: audience) { _, value in
                if value == .all {
                    selectedIds = Set(members.map(\.userId))
                    splitMode = .even
                }
                validationMessage = nil
            }
        }
        .interactiveDismissDisabled(isSubmissionInFlight)
        .sheet(isPresented: $showsSchedulePicker) {
            ScheduleSendSheet(
                title: "Schedule group payment",
                confirmTitle: "Use this time",
                preview: "Pay \(recipientSummary)",
                initialDate: scheduledFor,
                onSchedule: { scheduledFor = $0 }
            )
        }
    }

    // MARK: Sections

    private var heading: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("Group payment")
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
            } icon: {
                Image(systemName: "banknote.fill")
            }
            .foregroundStyle(KitColor.gold)
            Text(conversationTitle)
                .font(.title3.bold())
                .foregroundStyle(KitColor.primaryText)
            Text("Each member claims their own share here in the group. Anything nobody claims comes back to you.")
                .font(.footnote)
                .foregroundStyle(KitColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text("Available: \(KitMoney.formatted(wallet.balances.available, currency: wallet.currency))")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(KitColor.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .kitGlass(cornerRadius: 20, tint: KitColor.paleGold)
    }

    private var audiencePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Who are you paying?")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(KitColor.primaryText)
            Picker("Who are you paying?", selection: $audience) {
                Text("Everyone").tag(GroupPaymentAudience.all)
                Text("Choose members").tag(GroupPaymentAudience.selected)
            }
            .pickerStyle(.segmented)
        }
    }

    private var memberPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(members) { member in
                Button {
                    toggle(member)
                } label: {
                    HStack(spacing: 10) {
                        Image(
                            systemName: selectedIds.contains(member.userId)
                                ? "checkmark.circle.fill"
                                : "circle"
                        )
                            .foregroundStyle(
                                selectedIds.contains(member.userId)
                                    ? KitColor.gold
                                    : KitColor.secondaryText.opacity(0.5)
                            )
                        Text(member.name)
                            .font(.body)
                            .foregroundStyle(KitColor.primaryText)
                        Spacer(minLength: 8)
                        if splitMode == .custom, selectedIds.contains(member.userId) {
                            KitAmountTextField(
                                "Amount",
                                value: customAmountBinding(for: member.userId),
                                mode: amountMode,
                                textAlignment: .right
                            )
                            .frame(width: 120)
                        }
                    }
                    .padding(.vertical, 9)
                    .padding(.horizontal, 12)
                }
                .buttonStyle(.plain)
                .kitGlass(cornerRadius: 14, shadow: false)
            }
        }
    }

    private var splitPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How is it divided?")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(KitColor.primaryText)
            Picker("How is it divided?", selection: $splitMode) {
                Text("Split evenly").tag(GroupPaymentSplitMode.even)
                Text("Different amounts").tag(GroupPaymentSplitMode.custom)
            }
            .pickerStyle(.segmented)
            Text(
                splitMode == .even
                    ? "One amount, shared out equally between everyone you are paying."
                    : "You write what each member gets. Only the member and you see their amount."
            )
                .font(.caption)
                .foregroundStyle(KitColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var amountSection: some View {
        if splitMode == .even {
            VStack(alignment: .leading, spacing: 8) {
                Text("Total to share")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KitColor.primaryText)
                HStack(spacing: 10) {
                    Text(wallet.currency.code)
                        .font(.headline)
                        .foregroundStyle(KitColor.secondaryText)
                    KitAmountTextField(
                        "0",
                        value: $totalInput,
                        mode: amountMode,
                        textStyle: .large
                    )
                }
                .padding(16)
                .kitGlass(cornerRadius: 18)
                if let perMember = evenShareCopy {
                    Text(perMember)
                        .font(.footnote)
                        .foregroundStyle(KitColor.secondaryText)
                }
            }
        }
    }

    private var noteField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Note (optional)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(KitColor.primaryText)
            TextField("What is this for?", text: $note, axis: .vertical)
                .lineLimit(1 ... 3)
                .padding(14)
                .kitGlass(cornerRadius: 16)
                .onChange(of: note) { _, value in
                    note = GroupPaymentDraftPolicy.boundedNoteInput(value)
                }
        }
    }

    @ViewBuilder
    private var deliverySection: some View {
        if schedulePayment != nil {
            VStack(alignment: .leading, spacing: 10) {
                if let scheduledFor {
                    Label(
                        scheduledFor.formatted(date: .abbreviated, time: .shortened),
                        systemImage: "clock.badge.checkmark"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KitColor.green)
                    Text("Kit will send this from the server at that time, even if this iPhone is offline.")
                        .font(.caption)
                        .foregroundStyle(KitColor.secondaryText)
                    HStack {
                        Button("Change time") { showsSchedulePicker = true }
                        Spacer()
                        Button("Send now", role: .destructive) { self.scheduledFor = nil }
                    }
                    .font(.footnote.weight(.semibold))
                } else {
                    Button { showsSchedulePicker = true } label: {
                        Label("Send later", systemImage: "clock.badge.checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(KitSecondaryButtonStyle())
                }
            }
            .padding(16)
            .kitGlass(cornerRadius: 18, tint: KitColor.paleGreen, shadow: false)
        }
    }

    @ViewBuilder
    private var reviewLine: some View {
        if let total = GroupPaymentDraftPolicy.totalMinor(
            splitMode: splitMode,
            selected: selectedMembers,
            totalInput: totalInput,
            customAmounts: customAmounts,
            scale: scale
        ), total > 0 {
            HStack {
                Text("Leaving your wallet")
                    .font(.footnote)
                    .foregroundStyle(KitColor.secondaryText)
                Spacer()
                Text(
                    KitMoney.formatted(
                        minorUnits: total,
                        code: wallet.currency.code,
                        scale: scale
                    )
                )
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(KitColor.primaryText)
            }
            .padding(16)
            .kitGlass(cornerRadius: 18, tint: KitColor.paleGold, shadow: false)
        }
    }

    @ViewBuilder
    private var approval: some View {
        if model.financialApprovalUsesBiometrics {
            Label {
                Text("Approve with \(model.biometricDisplayName). Your approval covers only this payment, these members and these amounts.")
                    .font(.footnote)
                    .foregroundStyle(KitColor.secondaryText)
            } icon: {
                Image(systemName: model.biometricSymbolName)
                    .foregroundStyle(KitColor.gold)
            }
            .padding(17)
            .frame(maxWidth: .infinity, alignment: .leading)
            .kitGlass(cornerRadius: 18, tint: KitColor.paleGold, shadow: false)
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
        }
    }

    private var sendButton: some View {
        Button {
            send()
        } label: {
            if isSubmissionInFlight {
                ProgressView().tint(.white).frame(maxWidth: .infinity)
            } else {
                Label(
                    scheduledFor == nil
                        ? "Send to \(recipientSummary)"
                        : "Schedule for \(recipientSummary)",
                    systemImage: scheduledFor == nil
                        ? (model.financialApprovalUsesBiometrics
                            ? model.biometricSymbolName
                            : "lock.fill")
                        : "clock.badge.checkmark"
                )
                .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(GroupPaymentGoldButtonStyle())
        .disabled(
            isSubmissionInFlight
                || (!model.financialApprovalUsesBiometrics && pin.count != 4)
        )
    }

    // MARK: Behaviour

    private var scale: Int { wallet.currency.decimalScale }

    private var amountMode: PaymentAmountInputMode {
        scale == 0 ? .whole : .decimal(maximumFractionDigits: scale)
    }

    private var selectedMembers: [GroupPaymentDraftPolicy.Member] {
        audience == .all ? members : members.filter { selectedIds.contains($0.userId) }
    }

    private var recipientSummary: String {
        if audience == .all { return "everyone" }
        let count = selectedMembers.count
        return count == 1 ? "1 member" : "\(count) members"
    }

    private var evenShareCopy: String? {
        let count = selectedMembers.count
        guard count > 1,
              let total = KitPaymentMessage.minorUnits(for: totalInput, scale: scale),
              total >= Int64(count)
        else { return nil }
        let share = KitMoney.formatted(
            minorUnits: total / Int64(count),
            code: wallet.currency.code,
            scale: scale
        )
        // The odd minor unit lands on one member and the composer cannot know which, so it is
        // never quoted as an exact figure that one of them will not receive.
        return total % Int64(count) == 0
            ? "\(share) each, for \(count) members."
            : "About \(share) each, for \(count) members. The odd \(wallet.currency.code) is dealt out so the shares add up exactly."
    }

    private func toggle(_ member: GroupPaymentDraftPolicy.Member) {
        if selectedIds.contains(member.userId) {
            selectedIds.remove(member.userId)
            customAmounts[member.userId] = nil
        } else {
            selectedIds.insert(member.userId)
        }
        validationMessage = nil
    }

    private func customAmountBinding(for userId: String) -> Binding<String> {
        Binding(
            get: { customAmounts[userId] ?? "" },
            set: { customAmounts[userId] = $0 }
        )
    }

    private func send() {
        guard !isSubmitting, submissionGate.begin() else { return }
        let outcome = GroupPaymentDraftPolicy.draft(
            sourceWalletId: wallet.id,
            splitMode: splitMode,
            audience: audience,
            selected: selectedMembers,
            totalInput: totalInput,
            customAmounts: customAmounts,
            note: note,
            scale: scale,
            availableBalance: wallet.balances.available
        )
        switch outcome {
        case .problem(let message):
            validationMessage = message
            submissionGate.resolve(succeeded: false)
        case .ready(let body):
            validationMessage = nil
            Task { @MainActor in
                let succeeded: Bool
                if let scheduledFor, let schedulePayment {
                    succeeded = await schedulePayment(body, scheduledFor, pin) != nil
                } else {
                    succeeded = await submit(body, pin) != nil
                }
                if submissionGate.resolve(succeeded: succeeded) {
                    pin = ""
                    dismiss()
                }
            }
        }
    }
}

/// One submission per presentation. The successful transition returns `true` exactly once, which
/// is the composer's sole authority to dismiss itself; a failed attempt reopens the same draft for
/// a deliberate retry with the same idempotency key.
struct GroupPaymentSubmissionGate: Equatable {
    private enum Phase: Equatable {
        case idle
        case submitting
        case succeeded
    }

    private var phase: Phase = .idle

    var isSubmitting: Bool { phase == .submitting }

    mutating func begin() -> Bool {
        guard phase == .idle else { return false }
        phase = .submitting
        return true
    }

    @discardableResult
    mutating func resolve(succeeded: Bool) -> Bool {
        guard phase == .submitting else { return false }
        if succeeded {
            phase = .succeeded
            return true
        }
        phase = .idle
        return false
    }
}

// MARK: - Collaborative payment requests

struct GroupPaymentRequestComposerView: View {
    @Environment(\.dismiss) private var dismiss

    let conversationTitle: String
    let wallet: Wallet
    let isSubmitting: Bool
    let errorMessage: String?
    let submit: (CreateGroupPaymentRequestBody) async -> GroupPaymentRequestDTO?

    @State private var amount = ""
    @State private var note = ""
    @State private var hasExpiry = false
    @State private var expiresAt = Date().addingTimeInterval(7 * 24 * 60 * 60)
    @State private var validationMessage: String?
    @State private var submissionGate = GroupPaymentSubmissionGate()

    private var submissionInFlight: Bool { isSubmitting || submissionGate.isSubmitting }
    private var scale: Int { wallet.currency.decimalScale }
    private var amountMode: PaymentAmountInputMode {
        scale == 0 ? .whole : .decimal(maximumFractionDigits: scale)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Group payment request", systemImage: "chart.pie.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(KitColor.gold)
                            .textCase(.uppercase)
                        Text(conversationTitle)
                            .font(.title2.bold())
                            .foregroundStyle(KitColor.primaryText)
                        Text("Set one target. Members can contribute any amount until the request reaches 100%.")
                            .font(.footnote)
                            .foregroundStyle(KitColor.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Funds go directly to your \(wallet.currency.code) wallet as each contribution is approved.")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(KitColor.secondaryText)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .kitGlass(cornerRadius: 20, tint: KitColor.paleGold)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Target amount")
                            .font(.subheadline.weight(.semibold))
                        HStack(spacing: 10) {
                            Text(wallet.currency.code)
                                .font(.headline)
                                .foregroundStyle(KitColor.secondaryText)
                            KitAmountTextField(
                                "0",
                                value: $amount,
                                mode: amountMode,
                                textStyle: .large
                            )
                        }
                        .padding(16)
                        .kitGlass(cornerRadius: 18)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("What is it for? (optional)")
                            .font(.subheadline.weight(.semibold))
                        TextField("For example, team equipment", text: $note, axis: .vertical)
                            .lineLimit(1 ... 4)
                            .padding(14)
                            .kitGlass(cornerRadius: 16)
                            .onChange(of: note) { _, value in
                                note = GroupPaymentRequestDraftPolicy.boundedNoteInput(value)
                            }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Set a closing date", isOn: $hasExpiry)
                            .font(.subheadline.weight(.semibold))
                            .tint(KitColor.gold)
                        if hasExpiry {
                            DatePicker(
                                "Closes",
                                selection: $expiresAt,
                                in: Date().addingTimeInterval(60) ... Date().addingTimeInterval(90 * 24 * 60 * 60),
                                displayedComponents: [.date, .hourAndMinute]
                            )
                            .datePickerStyle(.compact)
                        } else {
                            Text("The request remains open until it is fully funded or you close it.")
                                .font(.caption)
                                .foregroundStyle(KitColor.secondaryText)
                        }
                    }
                    .padding(16)
                    .kitGlass(cornerRadius: 18, shadow: false)

                    if let message = validationMessage ?? errorMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button {
                        createRequest()
                    } label: {
                        if submissionInFlight {
                            ProgressView().tint(.white).frame(maxWidth: .infinity)
                        } else {
                            Label("Create request", systemImage: "plus.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(GroupPaymentGoldButtonStyle())
                    .disabled(submissionInFlight)
                }
                .padding(22)
            }
            .background(KitColor.canvas.ignoresSafeArea())
            .navigationTitle("Request from group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(submissionInFlight)
                }
            }
        }
        .interactiveDismissDisabled(submissionInFlight)
    }

    private func createRequest() {
        guard !isSubmitting, submissionGate.begin() else { return }
        let outcome = GroupPaymentRequestDraftPolicy.draft(
            destinationWalletID: wallet.id,
            amountInput: amount,
            note: note,
            expiresAt: hasExpiry ? expiresAt : nil,
            currencyScale: scale
        )
        switch outcome {
        case .problem(let message):
            validationMessage = message
            submissionGate.resolve(succeeded: false)
        case .ready(let body):
            validationMessage = nil
            Task { @MainActor in
                let succeeded = await submit(body) != nil
                if submissionGate.resolve(succeeded: succeeded) {
                    dismiss()
                }
            }
        }
    }
}

struct GroupPaymentRequestContributionView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let request: GroupPaymentRequestDTO
    let wallet: Wallet
    let startsWithRemainingAmount: Bool
    let isSubmitting: Bool
    let errorMessage: String?
    let submit: (String, String) async -> GroupPaymentRequestContributionResultDTO?

    @State private var amount = ""
    @State private var pin = ""
    @State private var validationMessage: String?
    @State private var submissionGate = GroupPaymentSubmissionGate()

    private var submissionInFlight: Bool { isSubmitting || submissionGate.isSubmitting }
    private var scale: Int { request.currencyScale }
    private var amountMode: PaymentAmountInputMode {
        scale == 0 ? .whole : .decimal(maximumFractionDigits: scale)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Contribute to request", systemImage: "chart.pie.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(KitColor.gold)
                            .textCase(.uppercase)
                        Text("\(formatted(request.remainingAmount)) remaining")
                            .font(.title2.bold())
                            .foregroundStyle(KitColor.primaryText)
                        Text("Available: \(KitMoney.formatted(wallet.balances.available, currency: wallet.currency, trimZeroFraction: true))")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(KitColor.secondaryText)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .kitGlass(cornerRadius: 20, tint: KitColor.paleGold)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your contribution")
                            .font(.subheadline.weight(.semibold))
                        HStack(spacing: 10) {
                            Text(request.currency.code)
                                .font(.headline)
                                .foregroundStyle(KitColor.secondaryText)
                            KitAmountTextField(
                                "0",
                                value: $amount,
                                mode: amountMode,
                                textStyle: .large
                            )
                        }
                        .padding(16)
                        .kitGlass(cornerRadius: 18)
                        Button("Use remaining amount") {
                            amount = request.remainingAmount
                            validationMessage = nil
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(KitColor.gold)
                    }

                    if model.financialApprovalUsesBiometrics {
                        Label {
                            Text("Approve with \(model.biometricDisplayName). Your approval covers only this request, wallet and amount.")
                                .font(.footnote)
                                .foregroundStyle(KitColor.secondaryText)
                        } icon: {
                            Image(systemName: model.biometricSymbolName)
                                .foregroundStyle(KitColor.gold)
                        }
                        .padding(17)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .kitGlass(cornerRadius: 18, tint: KitColor.paleGold, shadow: false)
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
                    }

                    if let message = validationMessage ?? errorMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button {
                        contribute()
                    } label: {
                        if submissionInFlight {
                            ProgressView().tint(.white).frame(maxWidth: .infinity)
                        } else {
                            Label(
                                "Approve contribution",
                                systemImage: model.financialApprovalUsesBiometrics
                                    ? model.biometricSymbolName
                                    : "lock.fill"
                            )
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(GroupPaymentGoldButtonStyle())
                    .disabled(
                        submissionInFlight
                            || (!model.financialApprovalUsesBiometrics && pin.count != 4)
                    )
                }
                .padding(22)
            }
            .background(KitColor.canvas.ignoresSafeArea())
            .navigationTitle("Contribute")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(submissionInFlight)
                }
            }
            .onAppear {
                if startsWithRemainingAmount, amount.isEmpty {
                    amount = request.remainingAmount
                }
            }
        }
        .interactiveDismissDisabled(submissionInFlight)
    }

    private func contribute() {
        guard !isSubmitting, submissionGate.begin() else { return }
        guard GroupPaymentRequestContributionPolicy.canonicalAmount(
            amount,
            request: request,
            wallet: wallet
        ) != nil else {
            validationMessage = "Enter an amount no greater than the remaining request or your available balance."
            submissionGate.resolve(succeeded: false)
            return
        }
        validationMessage = nil
        Task { @MainActor in
            let succeeded = await submit(amount, pin) != nil
            if submissionGate.resolve(succeeded: succeeded) {
                pin = ""
                dismiss()
            }
        }
    }

    private func formatted(_ value: String) -> String {
        KitMoney.formatted(value, currency: request.currency, trimZeroFraction: true)
    }
}
