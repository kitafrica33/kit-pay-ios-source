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
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 54, weight: .semibold))
                        .foregroundStyle(KitColor.green)

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
            .background(KitColor.canvas)
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
    @EnvironmentObject private var model: AppModel
    // Deliberately plain @State: payment credentials must never enter scene/app restoration.
    @State private var pin = ""
    @State private var confirmation = ""
    @State private var validationError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 54, weight: .semibold))
                        .foregroundStyle(KitColor.green)

                    Text("Create a wallet PIN")
                        .font(.largeTitle.bold())
                        .foregroundStyle(KitColor.primaryText)

                    Text("Your PIN approves payments and unlocks Kit Pay.")
                        .foregroundStyle(KitColor.secondaryText)

                    pinField("Four-digit PIN", text: $pin)
                    pinField("Confirm PIN", text: $confirmation)

                    Label(
                        "This PIN authorizes the exact amount and recipient for each payment.",
                        systemImage: "lock"
                    )
                    .font(.footnote)
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
                                Text("Set wallet PIN")
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 18))
                    .tint(KitColor.green)
                    .disabled(model.isCompletingAccountSetup || pin.count != 4 || confirmation.count != 4)
                }
                .padding(24)
            }
            .background(KitColor.canvas)
        }
    }

    private func pinField(_ title: String, text: Binding<String>) -> some View {
        SecureField(title, text: text)
            .keyboardType(.numberPad)
            .multilineTextAlignment(.center)
            .font(.system(size: 26, weight: .bold, design: .monospaced))
            .privacySensitive()
            .padding(16)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
            .onChange(of: text.wrappedValue) { _, value in
                let filtered = String(value.filter { $0 >= "0" && $0 <= "9" }.prefix(4))
                if filtered != value { text.wrappedValue = filtered }
                validationError = nil
            }
    }

    private func save() {
        guard isValidPaymentPin(pin) else {
            validationError = "Enter a four-digit wallet PIN."
            return
        }
        guard pin == confirmation else {
            validationError = "The PINs did not match. Start again."
            pin = ""
            confirmation = ""
            return
        }
        let confirmedPin = pin
        pin = ""
        confirmation = ""
        Task { await model.completePaymentPinSetup(pin: confirmedPin) }
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
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: model.loginUnlockSupportsBiometrics
                        ? model.biometricSymbolName
                        : "lock.shield.fill")
                        .font(.system(size: 54, weight: .semibold))
                        .foregroundStyle(KitColor.green)

                    Text("Unlock Kit Pay")
                        .font(.largeTitle.bold())
                        .foregroundStyle(KitColor.primaryText)

                    Text("Confirm it is you to finish this sign-in.")
                        .foregroundStyle(KitColor.secondaryText)

                    if model.loginUnlockSupportsBiometrics {
                        if let biometricError = model.biometricErrorMessage {
                            Label(biometricError, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }

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
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.roundedRectangle(radius: 18))
                        .tint(KitColor.green)
                        .disabled(model.isCompletingAccountSetup || !model.isOnline)

                        Label(
                            "\(model.biometricDisplayName) replaces your PIN on this iPhone.",
                            systemImage: "lock"
                        )
                        .font(.footnote)
                        .foregroundStyle(KitColor.secondaryText)
                    } else {
                        SecureField("Four-digit PIN", text: $pin)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.center)
                            .font(.system(size: 28, weight: .bold, design: .monospaced))
                            .privacySensitive()
                            .padding(16)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
                            .onChange(of: pin) { _, value in
                                let filtered = String(value.filter { $0 >= "0" && $0 <= "9" }.prefix(4))
                                if filtered != value { pin = filtered }
                                validationError = nil
                            }

                        if let validationError {
                            Text(validationError)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }

                        Button {
                            submitPIN()
                        } label: {
                            Group {
                                if model.isCompletingAccountSetup {
                                    ProgressView().tint(.white)
                                } else {
                                    Text("Unlock with PIN")
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.roundedRectangle(radius: 18))
                        .tint(KitColor.green)
                        .disabled(model.isCompletingAccountSetup || pin.count != 4)

                        Label(
                            "Your PIN is verified by Kit and is never stored in this app.",
                            systemImage: "lock"
                        )
                        .font(.footnote)
                        .foregroundStyle(KitColor.secondaryText)
                    }
                }
                .padding(24)
            }
            .background(KitColor.canvas)
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
    }

    private func submitPIN() {
        guard isValidPaymentPin(pin) else {
            validationError = "Enter your four-digit Kit Pay PIN."
            return
        }
        let submittedPIN = pin
        pin = ""
        Task { await model.unlockSessionWithPIN(submittedPIN) }
    }
}
