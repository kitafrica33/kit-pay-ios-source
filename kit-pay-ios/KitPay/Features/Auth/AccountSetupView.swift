import PhotosUI
import SwiftUI
import UIKit

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

/// The last step of registration: confirm the verified legal name, optionally choose a display
/// name, `@username` and photo, and say who is allowed to find you.
///
/// The legal name is shown, never edited — it comes off the identity document and is what governs
/// payments and compliance. Everything else on this screen is the *chosen* identity, and once the
/// legal name is verified none of it is mandatory.
private struct ProfileSetupView: View {
    @EnvironmentObject private var model: AppModel
    @State private var name = ""
    @State private var tag = ""
    @State private var initialized = false
    @State private var nameEdited = false
    @State private var tagEdited = false
    @State private var validationError: String?
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var preparedAvatarJPEG: Data?
    @State private var preparedAvatarPreview: UIImage?
    @State private var isPreparingPhoto = false
    @State private var photoLoadGeneration = 0
    @State private var phoneDiscoverable = true
    @State private var messageRequestsEnabled = true
    @State private var contactDiscoveryEnabled = true

    private var verifiedLegalName: String? { model.profile?.verifiedLegalName }
    private var usernameIsOptional: Bool { model.profile?.usernameRequired == false }
    private var showsPhotoPicker: Bool { model.capabilities?.enablesProfileAvatars == true }

    private var title: String {
        verifiedLegalName == nil ? "Set up your profile" : "Choose how you appear"
    }

    private var subtitle: String {
        verifiedLegalName == nil
            ? "Choose the display name and unique @username people will see when they pay or message you."
            : "Your identity is verified. Everything below is optional — it only changes how other people see you."
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    if let verifiedLegalName {
                        verifiedIdentityCard(verifiedLegalName)
                    }

                    if showsPhotoPicker {
                        photoCard
                    }

                    chosenIdentityCard
                    discoverabilityCard

                    if let validationError {
                        Label(validationError, systemImage: "exclamationmark.triangle.fill")
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
                                Text(usernameIsOptional ? "Finish setup" : "Save profile")
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 18))
                    .tint(KitColor.green)
                    .disabled(model.isCompletingAccountSetup || isPreparingPhoto)

                    Text("You can change all of this later in \(AccountDiscoveryControl.settingsLocation).")
                        .font(.caption)
                        .foregroundStyle(KitColor.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(24)
            }
            .background(KitAuthBackground())
            .onAppear(perform: initializeFromProfile)
            .onChange(of: model.profile) { _, _ in initializeFromProfile() }
            .onChange(of: selectedPhotoItem) { _, item in
                photoLoadGeneration &+= 1
                let generation = photoLoadGeneration
                guard let item else {
                    isPreparingPhoto = false
                    return
                }
                Task { await preparePhoto(item, generation: generation) }
            }
            .onDisappear {
                photoLoadGeneration &+= 1
                isPreparingPhoto = false
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            KitAuthLogoBadge(size: 72)
                .frame(maxWidth: .infinity)
            Text(title)
                .font(.largeTitle.bold())
                .foregroundStyle(KitColor.primaryText)
            Text(subtitle)
                .foregroundStyle(KitColor.secondaryText)
        }
    }

    private func verifiedIdentityCard(_ legalName: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(KitColor.green)
                .frame(width: 42, height: 42)
                .background(KitColor.paleGreen.opacity(0.3), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Verified legal name")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(KitColor.secondaryText)
                    .textCase(.uppercase)
                Text(legalName)
                    .font(.headline)
                    .foregroundStyle(KitColor.primaryText)
                Text("Taken from your verified ID. Kit Pay uses it for payments and security checks, and it is never replaced by a username.")
                    .font(.caption)
                    .foregroundStyle(KitColor.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(17)
        .kitGlass(cornerRadius: 24, tint: KitColor.paleGreen, shadow: false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Verified legal name, \(legalName)")
    }

    private var photoCard: some View {
        // `photoPickerTitle` is resolved here rather than inside the picker's label builder: that
        // closure is `@Sendable`, so reading main-actor model state from within it is a data race.
        let hasExistingPhoto = model.profile?.avatarURL != nil
        let pickerTitle = hasExistingPhoto || preparedAvatarJPEG != nil
            ? "Change photo"
            : "Add a photo"

        return VStack(spacing: 12) {
            ZStack {
                if let preparedAvatarPreview {
                    Image(uiImage: preparedAvatarPreview)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 96, height: 96)
                        .clipShape(Circle())
                } else {
                    RemoteAvatarView(
                        name: displayNamePreview,
                        avatarURL: model.profile?.avatarURL,
                        size: 96
                    )
                }
                if isPreparingPhoto {
                    Circle().fill(.black.opacity(0.32)).frame(width: 96, height: 96)
                    ProgressView().tint(.white)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                preparedAvatarJPEG == nil
                    ? (hasExistingPhoto ? "Your current profile photo" : "No profile photo yet")
                    : "Selected profile photo"
            )

            PhotosPicker(
                selection: $selectedPhotoItem,
                matching: .images,
                preferredItemEncoding: .automatic
            ) {
                Label(pickerTitle, systemImage: "photo.badge.plus")
                    .font(.subheadline.weight(.semibold))
            }
            .disabled(isPreparingPhoto || model.isCompletingAccountSetup)

            Text(
                hasExistingPhoto && preparedAvatarJPEG == nil
                    ? "This is the photo already on your account. Keep it, or pick a new one."
                    : "Kit Pay crops your photo to a square and optimizes it before upload."
            )
            .font(.caption)
            .foregroundStyle(KitColor.secondaryText)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(17)
        .kitGlass(cornerRadius: 24, shadow: false)
    }

    private var chosenIdentityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verifiedLegalName == nil ? "Your profile" : "Your public profile")
                .font(.headline)
                .foregroundStyle(KitColor.primaryText)

            labelledField(
                title: "Display name",
                caption: verifiedLegalName == nil
                    ? "Shown to people who pay or message you."
                    : "Optional. Leave it empty to be shown as \(verifiedLegalName ?? "")."
            ) {
                TextField(
                    verifiedLegalName ?? "Display name",
                    text: $name
                )
                .textContentType(.name)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .onChange(of: name) { _, _ in
                    nameEdited = true
                    validationError = nil
                }
            }

            labelledField(
                title: usernameIsOptional ? "Username (optional)" : "Username",
                caption: usernameIsOptional
                    ? "A public @handle people can use to find you. Skip it and nobody can look you up by handle."
                    : "3–32 lowercase letters, numbers, or underscores."
            ) {
                HStack(spacing: 4) {
                    Text("@").foregroundStyle(.secondary)
                    TextField("username", text: $tag)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: tag) { _, value in
                            tagEdited = true
                            let normalized = normalizeProfileTag(value)
                            if normalized != value { tag = normalized }
                            validationError = nil
                        }
                }
            }
        }
        .padding(17)
        .kitGlass(cornerRadius: 24, shadow: false)
    }

    private var discoverabilityCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Who can find you")
                .font(.headline)
                .foregroundStyle(KitColor.primaryText)
                .padding(.bottom, 6)

            setupToggle(.phoneNumber, isOn: $phoneDiscoverable)
            Divider()
            setupToggle(.contacts, isOn: $contactDiscoveryEnabled)
            if !usernameIsOptional || !normalizeProfileTag(tag).isEmpty {
                Divider()
                setupToggle(.messageRequests, isOn: $messageRequestsEnabled)
            }
        }
        .padding(17)
        .kitGlass(cornerRadius: 24, shadow: false)
    }

    private func setupToggle(
        _ control: AccountDiscoveryControl,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: control.systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KitColor.green)
                    .frame(width: 34, height: 34)
                    .background(KitColor.paleGreen.opacity(0.28), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(control.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(KitColor.primaryText)
                    Text(control.subtitle)
                        .font(.caption)
                        .foregroundStyle(KitColor.secondaryText)
                }
            }
        }
        .tint(KitColor.green)
        .padding(.vertical, 8)
        .accessibilityIdentifier(control.accessibilityIdentifier)
        .accessibilityLabel(control.title)
        .accessibilityHint(control.subtitle)
    }

    private func labelledField<Content: View>(
        title: String,
        caption: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(KitColor.secondaryText)
            content()
                .padding(14)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
            Text(caption)
                .font(.caption2)
                .foregroundStyle(KitColor.secondaryText)
        }
    }

    private var displayNamePreview: String {
        let typed = normalizeProfileName(name)
        if !typed.isEmpty { return typed }
        return verifiedLegalName ?? model.profile?.name ?? "Kit Pay"
    }

    private func initializeFromProfile() {
        guard !initialized, let profile = model.profile else { return }
        if !nameEdited && !isPlaceholderProfileName(profile.name ?? "") {
            // A display name equal to the verified legal name is not a *chosen* name — leaving the
            // field empty keeps "shown as my legal name" the honest default.
            let existing = normalizeProfileName(profile.name ?? "")
            name = existing.caseInsensitiveCompare(profile.verifiedLegalName ?? "") == .orderedSame
                ? ""
                : existing
        }
        if !tagEdited, let chosen = profile.chosenUsername {
            tag = chosen
        }
        contactDiscoveryEnabled = model.contactDiscoveryEnabled
        phoneDiscoverable = model.communicationPreferences?.phoneDiscoverable ?? true
        messageRequestsEnabled = model.communicationPreferences?
            .directMessageRequestsEnabled ?? true
        initialized = true
    }

    private func save() {
        let normalizedName = normalizeProfileName(name)
        let normalizedTag = normalizeProfileTag(tag)
        if let error = profileIdentityValidationError(
            name: normalizedName,
            tag: normalizedTag,
            verifiedLegalName: verifiedLegalName,
            usernameRequired: !usernameIsOptional
        ) {
            validationError = error
            return
        }
        validationError = nil
        let requestedName = normalizedName.isEmpty ? nil : normalizedName
        let requestedTag = normalizedTag.isEmpty ? nil : normalizedTag
        let requestedContactDiscovery = contactDiscoveryEnabled
        let discovery = PendingAccountDiscoveryChoice(
            phoneDiscoverable: phoneDiscoverable,
            directMessageRequestsEnabled: messageRequestsEnabled
        )
        Task {
            // Contact matching is device-local, so it takes effect immediately; the two
            // server-backed choices are queued until the session is authorized to send them.
            await model.setContactDiscoveryEnabled(requestedContactDiscovery)
            await model.completeProfile(
                displayName: requestedName,
                username: requestedTag,
                avatarJPEG: preparedAvatarJPEG,
                discovery: discovery
            )
        }
    }

    @MainActor
    private func preparePhoto(_ item: PhotosPickerItem, generation: Int) async {
        guard generation == photoLoadGeneration else { return }
        isPreparingPhoto = true
        validationError = nil
        do {
            guard let sourceData = try await item.loadTransferable(type: Data.self),
                  sourceData.count <= ProfileAvatarImagePreparer.maximumInputBytes
            else { throw ProfileAvatarImageError.invalidImage }
            let prepared = await Task.detached(priority: .userInitiated) {
                ProfileAvatarImagePreparer.prepareJPEG(from: sourceData)
            }.value
            guard let prepared else { throw ProfileAvatarImageError.invalidImage }
            guard generation == photoLoadGeneration else { return }
            preparedAvatarJPEG = prepared
            preparedAvatarPreview = UIImage(data: prepared)
            isPreparingPhoto = false
        } catch {
            guard generation == photoLoadGeneration else { return }
            selectedPhotoItem = nil
            preparedAvatarJPEG = nil
            preparedAvatarPreview = nil
            isPreparingPhoto = false
            validationError = error.localizedDescription
        }
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
