import SwiftUI

struct AccountSetupView: View {
    let step: AccountSetupStep

    var body: some View {
        switch step {
        case .profile:
            ProfileSetupView()
        case .deviceVerification:
            NavigationStack {
                KYCView(isRequiredForSignIn: true)
            }
        case .paymentPin:
            PaymentPinSetupView()
        case .loginUnlock:
            LoginUnlockView()
        }
    }
}

private struct ProfileSetupView: View {
    @EnvironmentObject private var model: AppModel
    @State private var name = ""
    @State private var tag = ""
    @State private var initialized = false
    @State private var nameEdited = false
    @State private var tagEdited = false
    @State private var validationError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    KitAuthLogoBadge(size: 72)
                        .frame(maxWidth: .infinity)

                    Text("Choose your username and Kit Pay tag")
                        .font(.largeTitle.bold())
                        .foregroundStyle(KitColor.primaryText)

                    Text("Choose the username / display name and unique @tag people will see when they pay or contact you.")
                        .foregroundStyle(KitColor.secondaryText)

                    TextField("Username / display name", text: $name)
                        .textContentType(.name)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .padding(16)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
                        .onChange(of: name) { _, _ in
                            nameEdited = true
                            validationError = nil
                        }

                    HStack(spacing: 4) {
                        Text("@").foregroundStyle(.secondary)
                        TextField("unique_tag", text: $tag)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: tag) { _, value in
                                tagEdited = true
                                let normalized = normalizeProfileTag(value)
                                if normalized != value { tag = normalized }
                                validationError = nil
                            }
                    }
                    .padding(16)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))

                    Text("3–32 lowercase letters, numbers, or underscores")
                        .font(.caption)
                        .foregroundStyle(KitColor.secondaryText)

                    if let validationError {
                        Text(validationError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    Button {
                        save()
                    } label: {
                        Group {
                            if model.isCompletingAccountSetup {
                                ProgressView().tint(.white)
                            } else {
                                Text("Save profile")
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 18))
                    .tint(KitColor.green)
                    .disabled(model.isCompletingAccountSetup)
                }
                .padding(24)
            }
            .background(KitAuthBackground())
            .onAppear(perform: initializeFromProfile)
            .onChange(of: model.profile) { _, _ in initializeFromProfile() }
        }
    }

    private func initializeFromProfile() {
        guard !initialized, let profile = model.profile else { return }
        if !nameEdited && !isPlaceholderProfileName(profile.name ?? "") {
            name = normalizeProfileName(profile.name ?? "")
        }
        if !tagEdited && !isProvisionalProfileTag(profile.tag ?? "") {
            tag = normalizeProfileTag(profile.tag ?? "")
        }
        initialized = true
    }

    private func save() {
        let normalizedName = normalizeProfileName(name)
        let normalizedTag = normalizeProfileTag(tag)
        if let error = profileIdentityValidationError(name: normalizedName, tag: normalizedTag) {
            validationError = error
            return
        }
        Task { await model.completeProfile(name: normalizedName, tag: normalizedTag) }
    }
}

private struct PaymentPinSetupView: View {
    private enum Stage {
        case create
        case confirm
    }

    @EnvironmentObject private var model: AppModel
    // Deliberately plain @State: payment credentials must never enter scene/app restoration.
    @State private var stage: Stage = .create
    @State private var pin = ""
    @State private var firstEntry = ""
    @State private var validationError: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        KitPinEntryPage(
            title: stage == .create ? "Create your wallet PIN" : "Confirm your PIN",
            subtitle: stage == .create
                ? "This four-digit PIN approves payments and unlocks Kit Pay. Never share it."
                : "Enter the same four digits once more.",
            pin: $pin,
            errorMessage: validationError,
            isBusy: model.isCompletingAccountSetup,
            accessory: stage == .confirm
                ? .action(title: "Start over", action: { restart() })
                : .none,
            onFilled: handleFilled
        ) {
            Label(
                "Your PIN authorizes the exact amount and recipient of each payment.",
                systemImage: "lock"
            )
            .font(.footnote)
            .foregroundStyle(KitColor.secondaryText)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
        }
        .privacySensitive()
        .onChange(of: pin) { _, value in
            // Clear the error once the user starts typing again — not when a stage reset
            // empties the digits, or the mismatch message would vanish unread.
            if !value.isEmpty { validationError = nil }
        }
    }

    private func handleFilled(_ filled: String) {
        switch stage {
        case .create:
            guard isValidPaymentPin(filled) else {
                validationError = "Enter a four-digit wallet PIN."
                pin = ""
                return
            }
            firstEntry = filled
            pin = ""
            withAnimation(reduceMotion ? nil : .snappy) { stage = .confirm }
        case .confirm:
            guard filled == firstEntry else {
                validationError = "The PINs did not match. Start again."
                restart(keepingError: true)
                return
            }
            let confirmedPin = filled
            pin = ""
            // Keep the original entry until setup succeeds (and this view is dismissed). If the
            // request fails or the device goes offline, the confirmation page remains usable and
            // the user can retry without being forced through a guaranteed mismatch first.
            Task { await model.completePaymentPinSetup(pin: confirmedPin) }
        }
    }

    private func restart(keepingError: Bool = false) {
        pin = ""
        firstEntry = ""
        if !keepingError { validationError = nil }
        withAnimation(reduceMotion ? nil : .snappy) { stage = .create }
    }
}

private struct LoginUnlockView: View {
    @EnvironmentObject private var model: AppModel
    @State private var pin = ""
    @State private var validationError: String?
    @State private var didAttemptAutomaticBiometric = false

    // While a working biometric enrollment exists, biometrics are the only unlock offered here —
    // the PIN is never requested. Terminal biometric failures disable the enrollment in AppModel,
    // which flips `loginUnlockSupportsBiometrics` and legitimately reveals the PIN path.
    var body: some View {
        Group {
            if model.loginUnlockSupportsBiometrics {
                biometricUnlock
            } else {
                KitPinEntryPage(
                    title: "Enter your PIN",
                    subtitle: "Confirm it is you to finish this sign-in.",
                    pin: $pin,
                    errorMessage: validationError,
                    isBusy: model.isCompletingAccountSetup,
                    onFilled: submitPIN
                ) {
                    Label(
                        "Your PIN is verified by Kit and is never stored in this app.",
                        systemImage: "lock"
                    )
                    .font(.footnote)
                    .foregroundStyle(KitColor.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                }
                .privacySensitive()
                .onChange(of: pin) { _, value in
                    if !value.isEmpty { validationError = nil }
                }
            }
        }
        .task {
            // Lead with the enrolled biometric so returning users never reach for a PIN.
            guard model.loginUnlockSupportsBiometrics,
                  model.isOnline,
                  !didAttemptAutomaticBiometric
            else { return }
            didAttemptAutomaticBiometric = true
            await model.unlockSessionWithBiometrics()
        }
    }

    private var biometricUnlock: some View {
        ZStack {
            KitAuthBackground()
            VStack(spacing: 0) {
                Spacer(minLength: 24)
                KitAuthLogoBadge()
                Spacer(minLength: 16)
                Text("Unlock Kit Pay")
                    .font(.title2.bold())
                    .foregroundStyle(KitColor.primaryText)
                    .multilineTextAlignment(.center)
                Text("Confirm it is you to finish this sign-in.")
                    .font(.subheadline)
                    .foregroundStyle(KitColor.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
                    .padding(.top, 6)

                if let biometricError = model.biometricErrorMessage {
                    Label(biometricError, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.top, 14)
                }

                Spacer(minLength: 24)

                Button {
                    Task { await model.unlockSessionWithBiometrics() }
                } label: {
                    Group {
                        if model.isCompletingAccountSetup {
                            ProgressView().tint(.white)
                        } else {
                            Label(
                                "Continue with \(model.biometricDisplayName)",
                                systemImage: model.biometricSymbolName
                            )
                            .font(.body.weight(.semibold))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(KitColor.green, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(model.isCompletingAccountSetup || !model.isOnline)
                .opacity(model.isCompletingAccountSetup || !model.isOnline ? 0.6 : 1)
                .padding(.horizontal, 32)

                Label(
                    "\(model.biometricDisplayName) replaces your PIN on this iPhone.",
                    systemImage: "lock"
                )
                .font(.footnote)
                .foregroundStyle(KitColor.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.top, 14)

                Spacer(minLength: 40)
            }
            .frame(maxWidth: 430)
            .frame(maxWidth: .infinity)
        }
    }

    private func submitPIN(_ filled: String) {
        guard isValidPaymentPin(filled) else {
            validationError = "Enter your four-digit Kit Pay PIN."
            pin = ""
            return
        }
        pin = ""
        Task { await model.unlockSessionWithPIN(filled) }
    }
}
