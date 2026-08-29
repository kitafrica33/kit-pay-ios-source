import SwiftUI

struct AccountDeletionView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private let submissionGate: AccountDeletionSubmissionGate

    @State private var preflight: AccountDeletionPreflightDTO?
    @State private var confirmation = ""
    @State private var paymentPIN = ""
    @State private var isLoading = false
    @State private var isSubmitting = false
    @State private var submissionOutcomeUncertain = false
    @State private var loadError: String?
    @State private var submissionError: String?
    @State private var showSupport = false

    @MainActor
    init(submissionGate: AccountDeletionSubmissionGate? = nil) {
        self.submissionGate = submissionGate ?? AccountDeletionSubmissionGate()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if protectedFlowAvailable {
                    warningCard
                    protectedFlow
                } else {
                    publicFallbackCard(
                        explanation: "Protected in-app deletion isn't available right now. You can still review and continue your deletion request below."
                    )
                }
            }
            .padding(18)
        }
        .background(KitColor.canvas.ignoresSafeArea())
        .navigationTitle("Delete account")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isSubmitting || model.isSubmittingAccountDeletion)
        .interactiveDismissDisabled(isSubmitting || model.isSubmittingAccountDeletion)
        .task(id: protectedFlowAvailable) {
            guard protectedFlowAvailable else { return }
            await loadPreflight()
        }
        .onDisappear {
            paymentPIN = ""
        }
        .sheet(isPresented: $showSupport) {
            SupportSheetView(
                preferredCategoryKeys: SupportContract.accountDeletionCategoryHints
            )
            .environmentObject(model)
        }
    }

    private var protectedFlowAvailable: Bool {
        AccountDeletionContract.protectedFlowAvailable(
            features: model.capabilities?.features
        )
    }

    private var deletionAssistancePath: SupportAssistancePath {
        SupportContract.deletionAssistancePath(capabilities: model.capabilities)
    }

    private var warningCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.crop.circle.badge.xmark")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.red)
                .frame(width: 68, height: 68)
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle()
                        .stroke(.white.opacity(0.7), lineWidth: 0.8)
                        .allowsHitTesting(false)
                }

            Text("Delete your Kit Pay account?")
                .font(.title2.bold())
                .foregroundStyle(KitColor.primaryText)

            Text(
                "Kit Pay will lock this account immediately, sign out every device and begin "
                    + "deletion or de-identification of eligible data."
            )
            .font(.subheadline)
            .foregroundStyle(KitColor.secondaryText)
            .multilineTextAlignment(.center)

            Text("This action cannot be undone.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.red)
        }
        .frame(maxWidth: .infinity)
        .padding(22)
        .kitGlass(cornerRadius: 30, tint: .red.opacity(0.22))
    }

    @ViewBuilder
    private var protectedFlow: some View {
        if isLoading && preflight == nil {
            HStack(spacing: 12) {
                ProgressView()
                Text("Loading the deletion and retention notice…")
                    .foregroundStyle(KitColor.secondaryText)
            }
            .frame(maxWidth: .infinity)
            .padding(22)
            .kitGlass(cornerRadius: 24)
        } else if let preflight {
            disclosureCard(preflight)
            confirmationCard(preflight)
        } else {
            publicFallbackCard(
                explanation: loadError
                    ?? "Protected account deletion could not be loaded safely."
            )
        }
    }

    private func disclosureCard(_ details: AccountDeletionPreflightDTO) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Label("Before you continue", systemImage: "doc.text.magnifyingglass")
                .font(.headline)
                .foregroundStyle(KitColor.primaryText)

            if !details.closureRequirements.isEmpty {
                Text("Resolve these items before final erasure")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KitColor.primaryText)
                ForEach(details.closureRequirements) { requirement in
                    disclosureRow(requirement.message, icon: "exclamationmark.circle.fill")
                }
            }

            if !details.notice.deletedCategories.isEmpty {
                Text("Eligible for deletion or de-identification")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KitColor.primaryText)
                ForEach(details.notice.deletedCategories, id: \.self) { category in
                    disclosureRow(category, icon: "checkmark.circle.fill")
                }
            }

            if !details.notice.retainedCategories.isEmpty {
                Text("Records that may be retained")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KitColor.primaryText)
                ForEach(details.notice.retainedCategories, id: \.self) { category in
                    disclosureRow(category, icon: "lock.shield.fill")
                }
            }

            Text(
                "Financial, identity-verification, sanctions, fraud, dispute and audit records "
                    + "may be retained where legally required."
            )
            .font(.caption)
            .foregroundStyle(KitColor.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .kitGlass(cornerRadius: 26)
    }

    private func disclosureRow(_ text: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.orange)
                .padding(.top, 1)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(KitColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func confirmationCard(_ details: AccountDeletionPreflightDTO) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Confirm account deletion")
                .font(.headline)
                .foregroundStyle(KitColor.primaryText)

            TextField("Type DELETE", text: $confirmation)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .disabled(isSubmitting)
                .padding(.horizontal, 14)
                .frame(minHeight: 50)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(.white.opacity(0.58), lineWidth: 0.8)
                        .allowsHitTesting(false)
                }
                .accessibilityLabel("Type DELETE to confirm")

            SecureField("Four-digit wallet PIN", text: $paymentPIN)
                .keyboardType(.numberPad)
                .textContentType(.password)
                .privacySensitive()
                .disabled(isSubmitting)
                .onChange(of: paymentPIN) { _, value in
                    let filtered = String(value.filter { $0.isASCII && $0.isNumber }.prefix(4))
                    if filtered != value { paymentPIN = filtered }
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 50)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(.white.opacity(0.58), lineWidth: 0.8)
                        .allowsHitTesting(false)
                }
                .accessibilityLabel("Four-digit wallet PIN")

            Text("Your wallet PIN is required for permanent account deletion.")
                .font(.caption)
                .foregroundStyle(KitColor.secondaryText)

            if let submissionError {
                Label(submissionError, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if submissionOutcomeUncertain {
                switch deletionAssistancePath {
                case .inAppSupport:
                    Button {
                        showSupport = true
                    } label: {
                        Label(
                            "Ask Kit Pay support about this request",
                            systemImage: "bubble.left.and.text.bubble.right"
                        )
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 48)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 17))
                    .tint(KitColor.navy)
                case .legalDeletionPage:
                    if let deletionURL = AccountDeletionContract.trustedFallbackURL {
                        Link(destination: deletionURL) {
                            Label(
                                "Review your deletion request",
                                systemImage: "arrow.up.right.square"
                            )
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 48)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.roundedRectangle(radius: 17))
                        .tint(KitColor.navy)

                        Text(
                            "This opens Kit Pay's official account deletion page, used only to "
                                + "review or continue a deletion request. It is not a support "
                                + "channel."
                        )
                        .font(.caption)
                        .foregroundStyle(KitColor.secondaryText)
                    }
                }
            }

            Button(role: .destructive) {
                Task { await submit(details) }
            } label: {
                HStack(spacing: 10) {
                    if isSubmitting { ProgressView().tint(.white) }
                    Text(isSubmitting ? "Submitting…" : "Delete account")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 18))
            .tint(.red)
            .disabled(!canSubmit(details))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .kitGlass(cornerRadius: 26, tint: .red.opacity(0.12))
    }

    private func publicFallbackCard(explanation: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Continue account deletion", systemImage: "person.crop.circle.badge.xmark")
                .font(.headline)
                .foregroundStyle(KitColor.primaryText)

            Text(explanation)
                .font(.subheadline)
                .foregroundStyle(KitColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if protectedFlowAvailable {
                Button("Retry protected deletion") {
                    Task { await loadPreflight(force: true) }
                }
                .buttonStyle(.bordered)
                .disabled(isLoading || model.isSubmittingAccountDeletion)
            }

            switch deletionAssistancePath {
            case .inAppSupport:
                Button {
                    showSupport = true
                } label: {
                    Label(
                        "Ask Kit Pay support",
                        systemImage: "bubble.left.and.text.bubble.right"
                    )
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 48)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 17))
                .tint(KitColor.navy)

                Text(
                    "Kit Pay support can help with your deletion request without leaving "
                        + "the app."
                )
                .font(.caption)
                .foregroundStyle(KitColor.secondaryText)
            case .legalDeletionPage:
                if let deletionURL = AccountDeletionContract.trustedFallbackURL {
                    Link(destination: deletionURL) {
                        Label(
                            "Continue on the Kit Pay account deletion page",
                            systemImage: "arrow.up.right.square"
                        )
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 48)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 17))
                    .tint(KitColor.navy)

                    Text(
                        "This opens Kit Pay's official account deletion page, used only to "
                            + "review or continue a deletion request. It is not a support "
                            + "channel."
                    )
                    .font(.caption)
                    .foregroundStyle(KitColor.secondaryText)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .kitGlass(cornerRadius: 26)
    }

    private func canSubmit(_ details: AccountDeletionPreflightDTO) -> Bool {
        model.appReviewDemoMutationsAllowed
            && !isSubmitting
            && !model.isSubmittingAccountDeletion
            && !submissionOutcomeUncertain
            && confirmation == details.confirmationText
            && AccountDeletionContract.validPIN(paymentPIN)
    }

    @MainActor
    private func loadPreflight(force: Bool = false) async {
        guard protectedFlowAvailable,
              !isLoading,
              force || preflight == nil
        else { return }
        isLoading = true
        loadError = nil
        if force {
            preflight = nil
            confirmation = ""
            paymentPIN = ""
            submissionOutcomeUncertain = false
            submissionError = nil
        }
        defer { isLoading = false }

        do {
            let response = try await model.loadAccountDeletionPreflight()
            try Task.checkCancellation()
            preflight = response
        } catch is CancellationError {
            return
        } catch {
            preflight = nil
            loadError = "Protected account deletion could not be loaded safely."
        }
    }

    @MainActor
    private func submit(_ details: AccountDeletionPreflightDTO) async {
        guard canSubmit(details), submissionGate.begin() else { return }
        isSubmitting = true
        submissionError = nil
        defer {
            paymentPIN = ""
            isSubmitting = false
            submissionGate.finish()
        }

        do {
            _ = try await model.submitAccountDeletion(
                preflight: details,
                confirmation: confirmation,
                pin: paymentPIN
            )
            dismiss()
        } catch is CancellationError {
            return
        } catch {
            if let deletionError = error as? AccountDeletionSubmissionError,
               deletionError.requiresSupportResolution {
                submissionOutcomeUncertain = true
                submissionError = deletionError.localizedDescription
            } else if let deletionError = error as? AccountDeletionSubmissionError,
                      deletionError.deletionWasAccepted {
                submissionOutcomeUncertain = true
                submissionError = deletionError.localizedDescription
            } else {
                submissionError = "The protected approval was not completed. Review your details and try again."
            }
        }
    }
}
