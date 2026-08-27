import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SecurityView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var mfaEnabled = false
    @State private var mfaEnrollment: TOTPEnrollmentDTO?
    @State private var recoveryCodes: [String] = []
    @State private var enrollmentCode = ""
    @State private var mfaLoading = false
    @State private var mfaMutationInFlight = false
    @State private var didLoadMFA = false
    @State private var mfaStatusVerified = false
    @State private var mfaMessage: String?
    @State private var mfaError: String?
    @State private var protectedAction: MFAProtectedAction?
    @State private var confirmRecoveryCodesSaved = false
    @State private var mfaViewGeneration = UUID()

    /// Live, not latched — see the note in `OnboardingView`. A cover raised at `onAppear` and
    /// only lowered by a later scene-phase change can outlive the condition that raised it.
    private var concealSensitiveContent: Bool {
        AuthenticationSecretLifecyclePolicy.shouldConceal(sceneIsActive: scenePhase == .active)
    }
    @State private var deviceToRevoke: DeviceDTO?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                biometricHeader
                biometricControls
                    .disabled(!model.appReviewDemoMutationsAllowed)

                if let error = model.biometricErrorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
                }

                loginVerificationControls
                    .disabled(!model.appReviewDemoMutationsAllowed)

                if let error = model.securityPreferencesErrorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
                }

                linkedDevicesCard
                    .disabled(!model.appReviewDemoMutationsAllowed)

                if let error = model.deviceManagementErrorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
                }

                mfaControls
                    .disabled(!model.appReviewDemoMutationsAllowed)

                Label(
                    "Biometrics are preferred for returning sign-in and local app locks on this iPhone. Your server-verified wallet PIN remains available if biometrics are locked or unavailable. Your identity-verification preference applies only to future logins; server-side payment authorization still applies.",
                    systemImage: "lock.shield.fill"
                )
                .font(.footnote)
                .foregroundStyle(KitColor.secondaryText)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .kitGlass(cornerRadius: 20, shadow: false)
            }
            .padding(18)
            .padding(.bottom, 30)
        }
        .accessibilityHidden(concealSensitiveContent)
        .background(KitColor.canvas)
        .navigationTitle("Security")
        .navigationBarTitleDisplayMode(.inline)
        // Recovery codes are shown once. Keep this screen in place until the user explicitly
        // confirms they saved or deliberately hides the complete set.
        .navigationBarBackButtonHidden(mfaMutationInFlight || !recoveryCodes.isEmpty)
        .task(id: model.authenticatorMFAAvailable) {
            if model.authenticatorMFAAvailable {
                await loadMFAStatus(force: true)
            } else {
                mfaEnabled = model.profile?.mfaEnabled == true
                mfaStatusVerified = false
                mfaLoading = false
                mfaError = nil
            }
        }
        .task(id: model.isOnline) {
            if model.isOnline { await model.refreshRegisteredDevices() }
        }
        .task(id: model.isOnline) {
            if model.isOnline { await model.loadSecurityPreferences(force: true) }
        }
        .refreshable {
            await model.refreshRegisteredDevices()
            await model.loadSecurityPreferences(force: true)
            if model.authenticatorMFAAvailable {
                await loadMFAStatus(force: true)
            }
        }
        .task(id: mfaEnrollment?.enrollmentId) {
            await retireTOTPEnrollmentAfterExpiry(mfaEnrollment)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, model.isOnline {
                Task { await model.refreshRegisteredDevices() }
                Task { await model.loadSecurityPreferences(force: true) }
            }
        }
        .onDisappear(perform: clearMFASensitiveState)
        .overlay {
            if concealSensitiveContent {
                KitColor.canvas
                    .overlay {
                        Label("Security details hidden", systemImage: "eye.slash.fill")
                            .font(.headline)
                            .foregroundStyle(KitColor.primaryText)
                    }
                    .ignoresSafeArea()
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isModal)
            }
        }
        .confirmationDialog(
            "Sign out this device?",
            isPresented: Binding(
                get: { deviceToRevoke != nil },
                set: { if !$0 { deviceToRevoke = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let deviceToRevoke {
                Button("Sign out device", role: .destructive) {
                    let id = deviceToRevoke.id
                    self.deviceToRevoke = nil
                    Task { await model.revokeRegisteredDevice(id: id) }
                }
                Button("Cancel", role: .cancel) { self.deviceToRevoke = nil }
            }
        } message: {
            if let deviceToRevoke {
                Text("\(deviceToRevoke.name) will be signed out of Kit Pay and must sign in and unlock again before it can return.")
            }
        }
        .sheet(item: $protectedAction) { action in
            MFAFactorConfirmationSheet(action: action) { code in
                try await performProtectedAction(action, code: code)
            }
        }
        .confirmationDialog(
            "Hide recovery codes?",
            isPresented: $confirmRecoveryCodesSaved,
            titleVisibility: .visible
        ) {
            Button("Hide saved codes", role: .destructive) {
                recoveryCodes.removeAll(keepingCapacity: false)
                mfaMessage = "Recovery codes hidden."
            }
            Button("Keep showing codes", role: .cancel) {}
        } message: {
            Text("Kit Pay cannot display this set again after it is hidden.")
        }
    }

    private var biometricHeader: some View {
        VStack(spacing: 12) {
            Image(systemName: model.biometricSymbolName)
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(KitColor.green)
                .frame(width: 88, height: 88)
                .kitGlass(cornerRadius: 28, tint: KitColor.paleGreen)
            Text("Protect Kit Pay")
                .font(.title2.bold())
                .foregroundStyle(KitColor.primaryText)
            Text("Use \(model.biometricDisplayName) for returning sign-in, every visit to Home, and every payment request you send.")
                .font(.subheadline)
                .foregroundStyle(KitColor.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(22)
        .frame(maxWidth: .infinity)
        .kitGlass(cornerRadius: 28)
    }

    private var biometricControls: some View {
        VStack(spacing: 0) {
            Toggle(isOn: biometricBinding) {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Use \(model.biometricDisplayName)")
                            .font(.headline)
                            .foregroundStyle(KitColor.primaryText)
                        Text(model.biometricUnlockEnabled ? "Enabled on this iPhone" : "Off")
                            .font(.caption)
                            .foregroundStyle(KitColor.secondaryText)
                    }
                } icon: {
                    Image(systemName: model.biometricSymbolName)
                        .foregroundStyle(KitColor.green)
                }
            }
            .tint(KitColor.green)
            .disabled(model.isConfiguringBiometrics)
            .padding(18)

            if model.isConfiguringBiometrics {
                Divider().padding(.leading, 18)
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Verifying on this iPhone…")
                        .font(.footnote)
                        .foregroundStyle(KitColor.secondaryText)
                    Spacer()
                }
                .padding(18)
            }
        }
        .kitGlass(cornerRadius: 24)
    }

    private var loginVerificationControls: some View {
        VStack(spacing: 0) {
            Toggle(isOn: loginVerificationBinding) {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Verify identity on every new login")
                            .font(.headline)
                            .foregroundStyle(KitColor.primaryText)
                        Text(loginVerificationStatusText)
                            .font(.caption)
                            .foregroundStyle(KitColor.secondaryText)
                    }
                } icon: {
                    Image(systemName: "person.badge.shield.checkmark")
                        .foregroundStyle(KitColor.green)
                }
            }
            .tint(KitColor.green)
            .disabled(
                !model.hasLoadedSecurityPreferences
                    || model.isManagingSecurityPreferences
                    || !model.isOnline
            )
            .padding(18)

            if model.isManagingSecurityPreferences {
                Divider().padding(.leading, 18)
                HStack(spacing: 10) {
                    ProgressView()
                    Text(model.isUpdatingSecurityPreferences
                        ? "Saving your choice…"
                        : "Loading your choice…")
                        .font(.footnote)
                        .foregroundStyle(KitColor.secondaryText)
                    Spacer()
                }
                .padding(18)
            }

            Divider().padding(.leading, 18)
            Text("Applies to future logins only. Your first identity verification is always required. When this is off, you still confirm returning logins with your PIN or biometrics.")
                .font(.footnote)
                .foregroundStyle(KitColor.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
        }
        .kitGlass(cornerRadius: 24)
    }

    private var loginVerificationBinding: Binding<Bool> {
        Binding(
            get: { model.verifyIdentityOnNewLogin },
            set: { enabled in
                Task { await model.setVerifyIdentityOnNewLogin(enabled) }
            }
        )
    }

    private var loginVerificationStatusText: String {
        if !model.hasLoadedSecurityPreferences {
            if model.isLoadingSecurityPreferences { return "Loading…" }
            return model.isOnline ? "Setting unavailable" : "Connect to view this setting"
        }
        return model.verifyIdentityOnNewLogin
            ? "Required for future logins"
            : "PIN or enrolled biometrics for future logins"
    }

    private var linkedDevicesCard: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Linked devices")
                        .font(.headline)
                        .foregroundStyle(KitColor.primaryText)
                    Text("Review every phone, browser, and computer signed in to your account.")
                        .font(.caption)
                        .foregroundStyle(KitColor.secondaryText)
                }
                Spacer(minLength: 8)
                Button {
                    Task { await model.refreshRegisteredDevices() }
                } label: {
                    Group {
                        if model.isRefreshingRegisteredDevices {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(KitColor.primaryText)
                    .frame(width: 44, height: 44)
                    .background(.thinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(
                    !model.isOnline
                        || model.isRefreshingRegisteredDevices
                        || model.revokingRegisteredDeviceID != nil
                )
                .accessibilityLabel("Refresh linked devices")
            }
            .padding(18)

            if !model.isOnline {
                Divider().padding(.leading, 18)
                Label("Offline — showing saved device information", systemImage: "wifi.slash")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
            }

            if model.registeredDevices.isEmpty {
                Divider().padding(.leading, 18)
                HStack(spacing: 12) {
                    if model.isRefreshingRegisteredDevices {
                        ProgressView()
                    } else {
                        Image(systemName: "iphone")
                            .foregroundStyle(KitColor.secondaryText)
                    }
                    Text(model.isRefreshingRegisteredDevices
                        ? "Checking linked devices…"
                        : "Linked device information is not available yet.")
                        .font(.subheadline)
                        .foregroundStyle(KitColor.secondaryText)
                    Spacer()
                }
                .padding(18)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(model.registeredDevices) { device in
                        Divider().padding(.leading, 76)
                        registeredDeviceRow(device)
                    }
                }
            }
        }
        .kitGlass(cornerRadius: 24)
    }

    private func registeredDeviceRow(_ device: DeviceDTO) -> some View {
        let hasActiveTrust = RegisteredDevicePolicy.hasActiveTrust(device)
        return HStack(alignment: .top, spacing: 14) {
            Image(systemName: platformSymbol(for: device.platform))
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(device.isCurrent == true ? KitColor.green : KitColor.secondaryText)
                .frame(width: 44, height: 44)
                .background(.thinMaterial, in: Circle())

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(device.name)
                        .font(.subheadline.bold())
                        .foregroundStyle(KitColor.primaryText)
                        .lineLimit(1)
                    if device.isCurrent == true {
                        Text("This device")
                            .font(.caption2.bold())
                            .foregroundStyle(KitColor.green)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(KitColor.green.opacity(0.12), in: Capsule())
                    }
                }
                Text(deviceDescription(device))
                    .font(.caption)
                    .foregroundStyle(KitColor.secondaryText)
                    .lineLimit(1)
                Label(lastSeenDescription(device), systemImage: "clock")
                    .font(.caption2)
                    .foregroundStyle(KitColor.secondaryText)
                Label(trustDescription(device), systemImage: hasActiveTrust
                    ? "checkmark.shield.fill"
                    : "shield")
                    .font(.caption2)
                    .foregroundStyle(hasActiveTrust ? KitColor.green : KitColor.secondaryText)
            }

            Spacer(minLength: 6)

            if device.isCurrent == true {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(KitColor.green)
                    .padding(.top, 10)
                    .accessibilityLabel("Current device")
            } else if model.revokingRegisteredDeviceID == device.id {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 10)
                    .accessibilityLabel("Signing out device")
            } else {
                Button(role: .destructive) {
                    deviceToRevoke = device
                } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .background(.red.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(
                    !model.isOnline
                        || model.isRefreshingRegisteredDevices
                        || model.revokingRegisteredDeviceID != nil
                )
                .accessibilityLabel("Sign out \(device.name)")
            }
        }
        .padding(18)
    }

    private func platformSymbol(for platform: String) -> String {
        switch platform.lowercased() {
        case "ios": "iphone.gen3"
        case "android": "smartphone"
        case "web": "safari"
        default: "desktopcomputer"
        }
    }

    private func deviceDescription(_ device: DeviceDTO) -> String {
        let platform: String = switch device.platform.lowercased() {
        case "ios": "iOS"
        case "android": "Android"
        case "web": "Web"
        default: "Desktop"
        }
        guard let model = device.model, !model.isEmpty else { return platform }
        return "\(model) · \(platform)"
    }

    private func lastSeenDescription(_ device: DeviceDTO) -> String {
        guard let date = RegisteredDevicePolicy.lastSeenDate(for: device) else {
            return "Last active time unavailable"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last active \(formatter.localizedString(for: date, relativeTo: Date()))"
    }

    private func trustDescription(_ device: DeviceDTO) -> String {
        guard RegisteredDevicePolicy.hasActiveTrust(device),
              let expiry = RegisteredDevicePolicy.trustExpiryDate(for: device)
        else { return "Trusted sign-in not enabled" }
        return "Trusted sign-in until \(expiry.formatted(date: .abbreviated, time: .shortened))"
    }

    private var mfaControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: mfaEnabled ? "checkmark.shield.fill" : "lock.shield.fill")
                    .font(.title2)
                    .foregroundStyle(mfaEnabled ? KitColor.green : KitColor.secondaryText)
                    .frame(width: 44, height: 44)
                    .background(KitColor.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Two-step verification")
                        .font(.headline)
                        .foregroundStyle(KitColor.primaryText)
                    Text(mfaEnabled ? "Authenticator protection is on" : "Add an authenticator app")
                        .font(.caption)
                        .foregroundStyle(KitColor.secondaryText)
                }
                Spacer()
                if mfaLoading { ProgressView() }
            }

            if !recoveryCodes.isEmpty {
                recoveryCodePanel
            } else if !model.authenticatorMFAAvailable {
                Text("Authenticator management is temporarily unavailable for this account.")
                    .font(.subheadline)
                    .foregroundStyle(KitColor.secondaryText)
            } else if !mfaStatusVerified {
                Text(
                    mfaLoading
                        ? "Confirming your current security settings…"
                        : "Refresh your security status before making changes."
                )
                    .font(.subheadline)
                    .foregroundStyle(KitColor.secondaryText)
                if !mfaLoading {
                    Button {
                        Task { await loadMFAStatus(force: true) }
                    } label: {
                        Label("Retry security status", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.roundedRectangle(radius: 16))
                    .disabled(!model.isOnline)
                }
            } else if let mfaEnrollment {
                enrollmentPanel(mfaEnrollment)
            } else if mfaEnabled {
                Text("New sign-ins require a current authenticator code or one of your saved recovery codes.")
                    .font(.subheadline)
                    .foregroundStyle(KitColor.secondaryText)
                Button {
                    protectedAction = .regenerateRecoveryCodes
                } label: {
                    Label("Generate new recovery codes", systemImage: "arrow.clockwise.shield")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 16))
                .disabled(mfaLoading || !model.isOnline)

                Button(role: .destructive) {
                    protectedAction = .disable
                } label: {
                    Text("Turn off two-step verification")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 16))
                .disabled(mfaLoading || !model.isOnline)
            } else {
                Text("Use an authenticator app as a second check after your password.")
                    .font(.subheadline)
                    .foregroundStyle(KitColor.secondaryText)
                Button {
                    Task { await startTOTPEnrollment() }
                } label: {
                    Label("Set up authenticator", systemImage: "key.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 16))
                .tint(KitColor.green)
                .disabled(mfaLoading || !model.isOnline)
            }

            if let mfaError {
                Label(mfaError, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let mfaMessage {
                Label(mfaMessage, systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(KitColor.green)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .kitGlass(cornerRadius: 24)
        .privacySensitive()
    }

    private func enrollmentPanel(_ enrollment: TOTPEnrollmentDTO) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let expired = TOTPEnrollmentPolicy.isExpired(enrollment, at: context.date)
            VStack(alignment: .leading, spacing: 14) {
                if expired {
                    Label(
                        "This setup has expired. Start again to create a fresh secret.",
                        systemImage: "clock.badge.exclamationmark"
                    )
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    Button("Start again") {
                        Task { await startTOTPEnrollment() }
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 16))
                    .tint(KitColor.green)
                    .frame(maxWidth: .infinity)
                    .disabled(mfaLoading || !model.isOnline)
                } else {
                    Text("1. Add Kit Pay to your authenticator")
                        .font(.subheadline.bold())
                        .foregroundStyle(KitColor.primaryText)
                    Text(TOTPEnrollmentPolicy.displaySecret(enrollment.secret) ?? "")
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .foregroundStyle(KitColor.primaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                        .frame(maxWidth: .infinity)
                        .background(
                            KitColor.green.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 14)
                        )
                        .accessibilityLabel("Authenticator setup secret")
                        .accessibilityValue(
                            TOTPEnrollmentPolicy.accessibilityValue(
                                forSecret: enrollment.secret
                            ) ?? ""
                        )

                    Button {
                        copySensitiveText(enrollment.secret)
                        mfaError = nil
                        mfaMessage = "Secret copied for two minutes."
                    } label: {
                        Label("Copy secret securely", systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.roundedRectangle(radius: 16))

                    if let url = TOTPEnrollmentPolicy.validatedProvisioningURL(
                        for: enrollment,
                        at: context.date
                    ) {
                        Button {
                            openURL(url)
                        } label: {
                            Label("Open authenticator app", systemImage: "arrow.up.forward.app")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.roundedRectangle(radius: 16))
                    }

                    Divider()

                    if let expiration = TOTPEnrollmentPolicy.expirationDate(for: enrollment) {
                        HStack(spacing: 6) {
                            Image(systemName: "clock")
                            Text("Setup expires in")
                            Text(expiration, style: .timer)
                                .monospacedDigit()
                        }
                        .font(.caption)
                        .foregroundStyle(KitColor.secondaryText)
                    }

                    Text("2. Confirm the current code")
                        .font(.subheadline.bold())
                        .foregroundStyle(KitColor.primaryText)
                    SecureField("6-digit code", text: $enrollmentCode)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 24, weight: .semibold, design: .monospaced))
                        .privacySensitive()
                        .padding(13)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .onChange(of: enrollmentCode) { _, value in
                            let digits = String(value.filter { $0.isNumber }.prefix(6))
                            if digits != value { enrollmentCode = digits }
                        }
                    Button {
                        Task { await confirmTOTPEnrollment() }
                    } label: {
                        Text("Turn on two-step verification")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 16))
                    .tint(KitColor.green)
                    .disabled(enrollmentCode.count != 6 || mfaLoading)
                }
            }
        }
    }

    private var recoveryCodePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Save your recovery codes now", systemImage: "exclamationmark.shield.fill")
                .font(.headline)
                .foregroundStyle(KitColor.primaryText)
            Text("Each code works once. Store them somewhere private—Kit Pay will not show these codes again.")
                .font(.footnote)
                .foregroundStyle(KitColor.secondaryText)

            VStack(spacing: 8) {
                ForEach(MFARecoveryCodePresentationPolicy.items(for: recoveryCodes)) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(item.number).")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(KitColor.secondaryText)
                            .frame(minWidth: 24, alignment: .trailing)
                        Text(item.code)
                            .font(.system(.body, design: .monospaced).weight(.semibold))
                            .foregroundStyle(KitColor.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(item.accessibilityLabel)
                    .accessibilityValue(item.accessibilityValue)
                }
            }
            .padding(14)
            .background(KitColor.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))

            Button {
                copySensitiveText(recoveryCodes.joined(separator: "\n"))
                mfaError = nil
                mfaMessage = "Recovery codes copied for two minutes."
            } label: {
                Label("Copy all codes", systemImage: "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 16))

            ShareLink(item: MFARecoveryCodePresentationPolicy.exportText(for: recoveryCodes)) {
                Label("Share or save codes", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 16))
            .accessibilityHint("Opens the system share sheet. Choose a private destination.")

            Text("Exporting creates a copy in the destination you choose.")
                .font(.caption)
                .foregroundStyle(KitColor.secondaryText)

            Button("I saved these codes") {
                confirmRecoveryCodesSaved = true
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func loadMFAStatus(force: Bool = false) async {
        guard force || !didLoadMFA else { return }
        didLoadMFA = true
        mfaEnabled = model.profile?.mfaEnabled == true
        let generation = mfaViewGeneration
        mfaLoading = true
        mfaError = nil
        defer {
            if generation == mfaViewGeneration { mfaLoading = false }
        }
        do {
            let enabled = try await model.refreshMFAStatus()
            guard generation == mfaViewGeneration else { return }
            mfaEnabled = enabled
            mfaStatusVerified = true
            mfaError = nil
        } catch {
            guard generation == mfaViewGeneration else { return }
            mfaStatusVerified = false
            mfaError = error.localizedDescription
        }
    }

    private func startTOTPEnrollment() async {
        guard !mfaLoading else { return }
        if let current = mfaEnrollment, TOTPEnrollmentPolicy.isExpired(current) {
            mfaEnrollment = nil
            enrollmentCode = ""
        }
        let generation = mfaViewGeneration
        mfaLoading = true
        mfaMutationInFlight = true
        mfaError = nil
        mfaMessage = nil
        defer {
            if generation == mfaViewGeneration {
                mfaLoading = false
                mfaMutationInFlight = false
            }
        }
        do {
            let enrollment = try await model.beginTOTPEnrollment()
            guard generation == mfaViewGeneration else { return }
            mfaEnrollment = enrollment
            recoveryCodes.removeAll(keepingCapacity: false)
            enrollmentCode = ""
            mfaError = nil
            mfaMessage = "Add Kit Pay to your authenticator, then enter its current code."
        } catch {
            guard generation == mfaViewGeneration else { return }
            if await reconcileMFAStatus(generation: generation) == true {
                mfaEnrollment = nil
                mfaError = nil
                mfaMessage = "Two-step verification is already on."
                return
            }
            mfaError = error.localizedDescription
        }
    }

    private func confirmTOTPEnrollment() async {
        guard !mfaLoading else { return }
        let submittedCode = enrollmentCode
        enrollmentCode = ""
        let generation = mfaViewGeneration
        mfaLoading = true
        mfaMutationInFlight = true
        mfaError = nil
        mfaMessage = nil
        defer {
            if generation == mfaViewGeneration {
                mfaLoading = false
                mfaMutationInFlight = false
            }
        }
        do {
            let codes = try await model.confirmTOTPEnrollment(code: submittedCode)
            guard generation == mfaViewGeneration else { return }
            enrollmentCode = ""
            mfaEnrollment = nil
            mfaEnabled = true
            mfaStatusVerified = true
            recoveryCodes = codes
            mfaMessage = "Two-step verification is on. Save these recovery codes now."
        } catch {
            guard generation == mfaViewGeneration else { return }
            if TOTPEnrollmentErrorPolicy.isTerminal(error) {
                mfaEnrollment = nil
            }
            // A response can be lost after the server enables MFA, and a malformed response must
            // not leave the UI offering an enrollment that the server already consumed. Re-read
            // the authoritative profile before deciding that confirmation failed.
            if await reconcileMFAStatus(generation: generation) == true {
                mfaEnrollment = nil
                recoveryCodes.removeAll(keepingCapacity: false)
                mfaError = nil
                mfaMessage =
                    "Two-step verification is on. Generate new recovery codes so you have a complete saved set."
                return
            }
            mfaError = error.localizedDescription
        }
    }

    private func retireTOTPEnrollmentAfterExpiry(_ enrollment: TOTPEnrollmentDTO?) async {
        guard let enrollment,
              let expiration = TOTPEnrollmentPolicy.expirationDate(for: enrollment)
        else { return }
        let delay = max(0, expiration.timeIntervalSinceNow)
        if delay > 0 {
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
        }
        while !Task.isCancelled,
              mfaLoading,
              mfaEnrollment?.enrollmentId == enrollment.enrollmentId {
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
        }
        guard !Task.isCancelled,
              mfaEnrollment?.enrollmentId == enrollment.enrollmentId,
              TOTPEnrollmentPolicy.isExpired(enrollment)
        else { return }
        mfaEnrollment = nil
        enrollmentCode = ""
        mfaMessage = nil
        mfaError = "This authenticator setup expired. Start again."
    }

    private func performProtectedAction(
        _ action: MFAProtectedAction,
        code: String
    ) async throws {
        let generation = mfaViewGeneration
        switch action {
        case .regenerateRecoveryCodes:
            let codes = try await model.regenerateMFARecoveryCodes(code: code)
            guard generation == mfaViewGeneration else { throw CancellationError() }
            recoveryCodes = codes
            mfaError = nil
            mfaMessage = "New recovery codes created. Your previous codes no longer work."
        case .disable:
            do {
                try await model.disableTOTP(code: code)
            } catch {
                guard generation == mfaViewGeneration else { throw CancellationError() }
                // DELETE may commit even when its response is lost. Treat an authoritative
                // disabled profile as success; otherwise preserve the original actionable error.
                guard await reconcileMFAStatus(generation: generation) == false else {
                    throw error
                }
            }
            guard generation == mfaViewGeneration else { throw CancellationError() }
            mfaEnabled = false
            mfaStatusVerified = true
            mfaEnrollment = nil
            recoveryCodes.removeAll(keepingCapacity: false)
            mfaError = nil
            mfaMessage = "Two-step verification is off."
        }
    }

    private func reconcileMFAStatus(generation: UUID) async -> Bool? {
        do {
            let enabled = try await model.refreshMFAStatus()
            guard generation == mfaViewGeneration else { return nil }
            mfaEnabled = enabled
            mfaStatusVerified = true
            return enabled
        } catch {
            return nil
        }
    }

    private func clearMFASensitiveState() {
        mfaViewGeneration = UUID()
        didLoadMFA = false
        mfaStatusVerified = false
        mfaLoading = false
        mfaMutationInFlight = false
        mfaEnrollment = nil
        recoveryCodes.removeAll(keepingCapacity: false)
        enrollmentCode = ""
        protectedAction = nil
        confirmRecoveryCodesSaved = false
        mfaMessage = nil
        mfaError = nil
    }

    private var biometricBinding: Binding<Bool> {
        Binding(
            get: { model.biometricUnlockEnabled },
            set: { enabled in
                Task { await model.setBiometricUnlockEnabled(enabled) }
            }
        )
    }
}

private enum MFAProtectedAction: String, Identifiable {
    case regenerateRecoveryCodes
    case disable

    var id: String { rawValue }

    var title: String {
        switch self {
        case .regenerateRecoveryCodes: "Generate new recovery codes"
        case .disable: "Turn off protection?"
        }
    }

    var explanation: String {
        switch self {
        case .regenerateRecoveryCodes:
            "Enter a current authenticator code or a saved recovery code. Your previous recovery codes will stop working."
        case .disable:
            "Enter a current authenticator code or a saved recovery code to turn off two-step verification."
        }
    }

    var confirmationTitle: String {
        switch self {
        case .regenerateRecoveryCodes: "Generate codes"
        case .disable: "Turn off"
        }
    }
}

private struct MFAFactorConfirmationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    let action: MFAProtectedAction
    let submit: (String) async throws -> Void
    @State private var code = ""
    @State private var errorMessage: String?
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(action.explanation)
                        .font(.subheadline)
                        .foregroundStyle(KitColor.secondaryText)

                    SecureField("Authenticator or recovery code", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .privacySensitive()
                        .padding(14)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .onChange(of: code) { _, value in
                            let filtered = String(
                                value
                                    .uppercased()
                                    .filter {
                                        $0.isLetter || $0.isNumber || $0 == "-" || $0 == " "
                                    }
                                    .prefix(64)
                            )
                            if filtered != value { code = filtered }
                        }

                    Text("Recovery codes work once.")
                        .font(.caption)
                        .foregroundStyle(KitColor.secondaryText)

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button(role: action == .disable ? .destructive : nil) {
                        Task { await performSubmission() }
                    } label: {
                        Group {
                            if isWorking {
                                ProgressView()
                            } else {
                                Text(action.confirmationTitle)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 16))
                    .tint(action == .disable ? .red : KitColor.green)
                    .disabled(
                        MFAFactorCodePolicy.normalizedFactorCode(code) == nil || isWorking
                    )
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(KitColor.canvas)
            .navigationTitle(action.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isWorking)
                }
            }
        }
        .accessibilityHidden(concealsSensitiveContent)
        .overlay {
            if concealsSensitiveContent {
                KitColor.canvas
                    .overlay {
                        Label("Security details hidden", systemImage: "eye.slash.fill")
                            .font(.headline)
                            .foregroundStyle(KitColor.primaryText)
                    }
                    .ignoresSafeArea()
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isModal)
            }
        }
        .presentationDetents(
            dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large]
        )
        .interactiveDismissDisabled(isWorking)
    }

    private var concealsSensitiveContent: Bool {
        AuthenticationSecretLifecyclePolicy.shouldConceal(sceneIsActive: scenePhase == .active)
    }

    private func performSubmission() async {
        guard !isWorking,
              let normalizedCode = MFAFactorCodePolicy.normalizedFactorCode(code)
        else { return }
        code = ""
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await submit(normalizedCode)
            code = ""
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private func copySensitiveText(_ value: String) {
    UIPasteboard.general.setItems(
        [[UTType.plainText.identifier: value]],
        options: [
            .localOnly: true,
            .expirationDate: Date().addingTimeInterval(120),
        ]
    )
}

struct BiometricSignInView: View {
    @EnvironmentObject private var model: AppModel
    @State private var usePIN = false
    @State private var pin = ""
    @State private var didSubmitPIN = false

    var body: some View {
        // A server-verified PIN remains an explicit recovery path after biometric cancellation
        // or lockout. Terminal enrollment failures stay on PIN until AppModel removes the stale
        // biometric credential after a successful unlock.
        if usePIN || model.biometricSignInPermanentlyUnavailable {
            pinUnlock
        } else {
            KitBiometricGateView(
                symbolName: model.biometricSymbolName,
                title: "Kit Pay is locked",
                message: "Use \(model.biometricDisplayName) to sign in on this iPhone.",
                errorMessage: model.biometricErrorMessage,
                isAuthorizing: model.biometricAccessState == .authorizing,
                buttonTitle: "Unlock with \(model.biometricDisplayName)",
                authenticate: { await model.retryBiometricSignIn() },
                secondaryTitle: "Use my PIN instead",
                secondaryAction: {
                    pin = ""
                    didSubmitPIN = false
                    usePIN = true
                }
            )
            .task { await model.retryBiometricSignIn() }
        }
    }

    private var pinUnlock: some View {
        KitPinEntryPage(
            title: "Enter your Kit Pay PIN",
            subtitle: model.biometricSignInPermanentlyUnavailable
                ? "\(model.biometricDisplayName) is no longer available on this iPhone, so your PIN confirms it is you."
                : "Use your wallet PIN if \(model.biometricDisplayName) is locked or unavailable.",
            pin: $pin,
            // Only surface errors from a PIN attempt here — the lingering biometric-cancel
            // message belongs to the gate, not to a fresh PIN entry.
            errorMessage: didSubmitPIN ? model.biometricErrorMessage : nil,
            isBusy: model.biometricAccessState == .authorizing,
            accessory: model.biometricSignInPermanentlyUnavailable
                ? .none
                : .biometric(
                    symbolName: model.biometricSymbolName,
                    label: "Use \(model.biometricDisplayName)",
                    action: {
                        pin = ""
                        didSubmitPIN = false
                        usePIN = false
                    }
                ),
            onFilled: { submitted in
                pin = ""
                Task {
                    _ = await model.retrySignInWithPIN(submitted)
                    // Reveal the error only after this attempt resolves — flipping the flag
                    // before the await would flash the stale biometric-cancel message (and its
                    // error haptic) the moment the fourth digit lands.
                    didSubmitPIN = true
                }
            }
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
            // A fresh entry must not inherit the previous attempt's failure state — red dots
            // over digits the user is still typing read as "already wrong".
            if !value.isEmpty { didSubmitPIN = false }
        }
    }
}

struct KitBiometricGateView: View {
    let symbolName: String
    let title: String
    let message: String
    let errorMessage: String?
    let isAuthorizing: Bool
    let buttonTitle: String
    let authenticate: () async -> Void
    var secondaryTitle: String? = nil
    var secondaryAction: (() async -> Void)? = nil

    var body: some View {
        ZStack {
            KitAuthBackground()

            VStack(spacing: 0) {
                Spacer(minLength: 24)
                KitAuthLogoBadge()
                Spacer(minLength: 16)

                Text(title)
                    .font(.title2.bold())
                    .foregroundStyle(KitColor.primaryText)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(KitColor.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
                    .padding(.top, 6)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(12)
                        .background(.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 32)
                        .padding(.top, 14)
                }

                Spacer(minLength: 24)

                Image(systemName: symbolName)
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(KitColor.green)
                    .accessibilityHidden(true)

                Spacer(minLength: 24)

                Button {
                    Task { await authenticate() }
                } label: {
                    Group {
                        if isAuthorizing {
                            ProgressView().tint(.white)
                        } else {
                            Label(buttonTitle, systemImage: symbolName)
                                .font(.body.weight(.semibold))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(KitColor.green, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isAuthorizing)
                .opacity(isAuthorizing ? 0.7 : 1)
                .padding(.horizontal, 32)

                if let secondaryTitle, let secondaryAction {
                    Button(secondaryTitle) {
                        Task { await secondaryAction() }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KitColor.green)
                    .disabled(isAuthorizing)
                    .padding(.top, 16)
                    .frame(minHeight: 44)
                }

                Spacer(minLength: 40)
            }
            .frame(maxWidth: 430)
            .frame(maxWidth: .infinity)
        }
    }
}
