import ImageIO
import PhotosUI
import SwiftUI
import UIKit

/// Pushed settings pages, addressed by value so the tab knows when a detail screen owns the
/// screen and the floating root menu can step aside.
enum ProfileDetailDestination: Hashable {
    case communicationPrivacy
    case identityVerification
    case security
    case chatBackup
    case legalPrivacy
    case accountDeletion
}

struct ProfileView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var isDetailPresented: Bool
    @State private var navigationPath: [ProfileDetailDestination] = []
    @State private var showSignOut = false
    @State private var showProfileEditor = false
    @State private var showProfileEmail = false

    init(isDetailPresented: Binding<Bool> = .constant(false)) {
        _isDetailPresented = isDetailPresented
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                VStack(spacing: 22) {
                    profileHeader
                    ConnectivityPill(isOnline: model.isOnline, queuedCount: model.queuedCount)
                    settingsCard(primaryRows)
                    settingsCard(secondaryRows)
                    Button(role: .destructive) { showSignOut = true } label: {
                        Label(
                            "Log out of this device",
                            systemImage: "rectangle.portrait.and.arrow.right"
                        )
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.roundedRectangle(radius: 18))
                }
                .padding(18)
            }
            .rootTabBarScrollClearance()
            .background(KitColor.canvas)
            .navigationTitle("Profile")
            .confirmationDialog("Log out of this device?", isPresented: $showSignOut) {
                Button("Log out", role: .destructive) { Task { await model.signOut() } }
            } message: {
                Text(
                    "This ends only this device's Kit Pay session. Your other signed-in "
                        + "devices stay connected, and encrypted message and call history "
                        + "remains available here."
                )
            }
            .sheet(isPresented: $showProfileEditor) {
                ProfileEditorView()
                    .environmentObject(model)
            }
            .sheet(isPresented: $showProfileEmail) {
                ProfileEmailView()
                    .environmentObject(model)
            }
            .navigationDestination(for: ProfileDetailDestination.self) { destination in
                detailView(destination)
            }
        }
        .onChange(of: navigationPath) { _, path in
            isDetailPresented = !path.isEmpty
        }
        .onAppear { isDetailPresented = !navigationPath.isEmpty }
        .onDisappear { isDetailPresented = false }
    }

    @ViewBuilder
    private func detailView(_ destination: ProfileDetailDestination) -> some View {
        switch destination {
        case .communicationPrivacy: CommunicationPrivacyView()
        case .identityVerification: KYCView()
        case .security: SecurityView()
        case .chatBackup: ChatBackupSettingsView()
        case .legalPrivacy: LegalPrivacyView()
        case .accountDeletion: AccountDeletionView()
        }
    }

    private var profileHeader: some View {
        HStack(spacing: 18) {
            RemoteAvatarView(
                name: model.profile?.name ?? "Kit Pay",
                avatarURL: model.profile?.avatarURL,
                size: 82
            )
            VStack(alignment: .leading, spacing: 5) {
                Text(model.profile?.name ?? "Kit Pay user")
                    .font(.title2.bold())
                    .foregroundStyle(KitColor.primaryText)
                Text(profileSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(KitColor.secondaryText)
                if kycAvailable {
                    Label(
                        kycLabel,
                        systemImage: kycVerified ? "checkmark.seal.fill" : "hourglass"
                    )
                    .font(.caption.bold())
                    .foregroundStyle(kycVerified ? KitColor.green : .orange)
                }
            }
            Spacer()
            GlassIconButton(systemName: "pencil") {
                showProfileEditor = true
            }
            .accessibilityLabel("Edit profile")
        }
        .padding(18)
        .kitGlass(cornerRadius: 28)
    }

    private func settingsCard(_ rows: [ProfileRow]) -> some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                settingsControl(row)
                .buttonStyle(.plain)
                if row.id != rows.last?.id { Divider().padding(.leading, 72) }
            }
        }
        .padding(.vertical, 5)
        .kitGlass(cornerRadius: 28)
    }

    @ViewBuilder
    private func settingsControl(_ row: ProfileRow) -> some View {
        switch row.destination {
        case .editProfile:
            Button { showProfileEditor = true } label: { settingsRow(row) }
        case .profileEmail where profileEmailPresentation.canAttach:
            Button { showProfileEmail = true } label: { settingsRow(row) }
        case .profileEmail:
            settingsRow(row, showsDisclosure: false)
        case .communicationPrivacy:
            NavigationLink(value: ProfileDetailDestination.communicationPrivacy) {
                settingsRow(row)
            }
        case .identityVerification where kycAvailable:
            NavigationLink(value: ProfileDetailDestination.identityVerification) {
                settingsRow(row)
            }
        case .identityVerification:
            settingsRow(row, showsDisclosure: false)
        case .security:
            NavigationLink(value: ProfileDetailDestination.security) { settingsRow(row) }
        case .chatBackup:
            NavigationLink(value: ProfileDetailDestination.chatBackup) { settingsRow(row) }
        case .legalPrivacy:
            NavigationLink(value: ProfileDetailDestination.legalPrivacy) { settingsRow(row) }
        case .accountDeletion:
            NavigationLink(value: ProfileDetailDestination.accountDeletion) { settingsRow(row) }
        }
    }

    private func settingsRow(_ row: ProfileRow, showsDisclosure: Bool = true) -> some View {
        HStack(spacing: 14) {
            Image(systemName: row.icon)
                .font(.headline)
                .foregroundStyle(KitColor.secondaryText)
                .frame(width: 44, height: 44)
                .background(.thinMaterial, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(.headline).foregroundStyle(KitColor.primaryText)
                Text(row.subtitle).font(.subheadline).foregroundStyle(KitColor.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
            if row.destination == .profileEmail, model.profile?.emailVerified == true {
                Image(systemName: "checkmark.seal.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(KitColor.green)
                    .accessibilityLabel("Verified")
            } else if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var profileSubtitle: String {
        let tag = model.profile?.tag.map { "@\($0)" }
        return [tag, model.profile?.phone].compactMap { $0 }.joined(separator: " · ")
    }

    private var kycVerified: Bool {
        ["verified", "approved"].contains(normalizedKYCStatus)
    }

    private var kycLabel: String {
        if kycVerified { return "Identity verified with Didit" }
        if ["pending", "in_review", "review"].contains(normalizedKYCStatus) {
            return "Didit verification in review"
        }
        return "Identity not verified"
    }

    private var normalizedKYCStatus: String {
        (model.kycStatus?.status ?? model.profile?.kycStatus ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private var kycAvailable: Bool {
        model.capabilities?.features?["kyc"] == true
    }

    private var identityVerificationTitle: String {
        guard kycAvailable else { return "Verify your identity with Didit" }
        if kycVerified { return "Identity verified with Didit" }
        if ["pending", "in_review", "review"].contains(normalizedKYCStatus) {
            return "Didit verification in review"
        }
        return "Verify your identity with Didit"
    }

    private var identityVerificationSubtitle: String {
        guard kycAvailable else {
            return "Didit verification is temporarily unavailable"
        }
        if kycVerified { return "Your identity checks are complete" }
        if ["pending", "in_review", "review"].contains(normalizedKYCStatus) {
            return "Tap to refresh your verification status"
        }
        return "Tap to start the secure identity check"
    }

    private var accountDeletionSubtitle: String {
        if AccountDeletionContract.protectedFlowAvailable(
            features: model.capabilities?.features
        ) {
            return "Request protected deletion of your account and eligible data"
        }
        return "Open the support-assisted account deletion request"
    }

    private var primaryRows: [ProfileRow] {
        [
            .init(
                title: "Edit profile",
                subtitle: "Change your display name, @tag and photo",
                icon: "pencil",
                destination: .editProfile
            ),
            .init(
                title: profileEmailPresentation.title,
                subtitle: profileEmailPresentation.subtitle,
                icon: "at",
                destination: .profileEmail
            ),
            .init(
                title: "Communication privacy",
                subtitle: "Discovery, messages, calls and blocks",
                icon: "hand.raised",
                destination: .communicationPrivacy
            ),
            .init(
                title: identityVerificationTitle,
                subtitle: identityVerificationSubtitle,
                icon: "person.text.rectangle",
                destination: .identityVerification
            ),
            .init(
                title: "Security",
                subtitle: "Wallet PIN, biometrics, authenticator and devices",
                icon: "shield.lefthalf.filled",
                destination: .security
            ),
            .init(
                title: "Chats & backup",
                subtitle: "Manage iCloud backup and restore",
                icon: "icloud.and.arrow.up",
                destination: .chatBackup
            )
        ]
    }

    private var secondaryRows: [ProfileRow] {
        [
            .init(
                title: "Legal & privacy",
                subtitle: "Privacy policy, licences and software notices",
                icon: "hand.raised.square",
                destination: .legalPrivacy
            ),
            .init(
                title: "Delete account",
                subtitle: accountDeletionSubtitle,
                icon: "person.crop.circle.badge.xmark",
                destination: .accountDeletion
            )
        ]
    }

    private var profileEmailPresentation: ProfileEmailPresentation {
        ProfileEmailPresentationPolicy.presentation(
            profile: model.profile,
            attachmentAvailable: model.emailRegistrationAvailable
        )
    }
}

private struct ProfileEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var tag = ""
    @State private var validationError: String?
    @State private var initialized = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var preparedAvatarJPEG: Data?
    @State private var preparedAvatarPreview: UIImage?
    @State private var isPreparingPhoto = false
    @State private var isSaving = false
    @State private var photoLoadGeneration = 0

    private var photoPickerTitle: String {
        model.profile?.avatarURL == nil && preparedAvatarJPEG == nil
            ? "Choose photo"
            : "Change photo"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 14) {
                        ZStack {
                            if let preparedAvatarPreview {
                                Image(uiImage: preparedAvatarPreview)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 112, height: 112)
                                    .clipShape(Circle())
                            } else {
                                RemoteAvatarView(
                                    name: name.isEmpty ? (model.profile?.name ?? "Kit Pay") : name,
                                    avatarURL: model.profile?.avatarURL,
                                    size: 112
                                )
                            }

                            if isPreparingPhoto {
                                Circle()
                                    .fill(.black.opacity(0.32))
                                    .frame(width: 112, height: 112)
                                ProgressView()
                                    .tint(.white)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            preparedAvatarJPEG == nil
                                ? "Current profile photo"
                                : "Selected profile photo"
                        )

                        PhotosPicker(
                            selection: $selectedPhotoItem,
                            matching: .images,
                            preferredItemEncoding: .automatic
                        ) {
                            // Resolved outside the picker's label builder: that closure is
                            // `@Sendable`, so reading main-actor model state from inside it is a
                            // data race the compiler can only warn about today.
                            Label(photoPickerTitle, systemImage: "photo.badge.plus")
                                .font(.headline)
                        }
                        .disabled(isPreparingPhoto || model.isUpdatingProfile)

                        if let preparedAvatarJPEG {
                            Label(
                                ByteCountFormatter.string(
                                    fromByteCount: Int64(preparedAvatarJPEG.count),
                                    countStyle: .file
                                ),
                                systemImage: "checkmark.circle.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(KitColor.green)
                        }
                    }
                    .padding(.vertical, 8)
                } header: {
                    Text("Profile photo")
                } footer: {
                    Text("Kit Pay crops your photo to a square and optimizes it for fast loading before upload.")
                }

                Section {
                    TextField("Username / display name", text: $name)
                        .textContentType(.name)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .onChange(of: name) { _, _ in validationError = nil }
                    HStack(spacing: 4) {
                        Text("@").foregroundStyle(.secondary)
                        TextField("unique_tag", text: $tag)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: tag) { _, value in
                                let normalized = normalizeProfileTag(value)
                                if normalized != value { tag = normalized }
                                validationError = nil
                            }
                    }
                } header: {
                    Text("Profile")
                } footer: {
                    Text("Your name and unique tag are visible to people who pay, message, or call you.")
                }

                if let validationError {
                    Section {
                        Label(validationError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Edit profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(model.isUpdatingProfile || isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        save()
                    } label: {
                        if model.isUpdatingProfile {
                            ProgressView()
                        } else {
                            Text("Save")
                        }
                    }
                    .disabled(model.isUpdatingProfile || isSaving || isPreparingPhoto)
                }
            }
            .interactiveDismissDisabled(model.isUpdatingProfile || isSaving)
            .onAppear(perform: initialize)
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

    private func initialize() {
        guard !initialized else { return }
        name = normalizeProfileName(model.profile?.name ?? "")
        tag = normalizeProfileTag(model.profile?.tag ?? "")
        initialized = true
    }

    private func save() {
        guard !isSaving, !model.isUpdatingProfile else { return }
        let normalizedName = normalizeProfileName(name)
        let normalizedTag = normalizeProfileTag(tag)
        if let error = profileIdentityValidationError(name: normalizedName, tag: normalizedTag) {
            validationError = error
            return
        }
        validationError = nil
        model.lastError = nil
        isSaving = true
        Task {
            defer { isSaving = false }
            if await model.updateProfile(
                name: normalizedName,
                tag: normalizedTag,
                avatarJPEG: preparedAvatarJPEG
            ) {
                dismiss()
            } else {
                validationError = model.lastError
                    ?? "Your profile could not be updated. Please try again."
            }
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

enum ProfileAvatarImagePreparer {
    static let outputPixels = 512
    static let maximumInputBytes = 32 * 1_024 * 1_024

    static func prepareJPEG(from data: Data) -> Data? {
        guard !data.isEmpty,
              data.count <= maximumInputBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 2_048,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else { return nil }

        let image = UIImage(cgImage: thumbnail)
        let side = CGFloat(outputPixels)
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = max(side / image.size.width, side / image.size.height)
        let drawSize = CGSize(
            width: image.size.width * scale,
            height: image.size.height * scale
        )
        let drawRect = CGRect(
            x: (side - drawSize.width) / 2,
            y: (side - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let square = UIGraphicsImageRenderer(
            size: CGSize(width: side, height: side),
            format: format
        ).image { context in
            context.cgContext.setFillColor(UIColor.white.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: side, height: side))
            image.draw(in: drawRect)
        }

        for quality in [0.9, 0.82, 0.74, 0.66, 0.58, 0.5, 0.4, 0.3, 0.2, 0.1] {
            guard let encoded = square.jpegData(compressionQuality: quality) else { continue }
            if encoded.count <= ProfileAvatarUploadPolicy.maximumBytes { return encoded }
        }
        return nil
    }
}

private enum ProfileAvatarImageError: LocalizedError {
    case invalidImage

    var errorDescription: String? {
        "Choose a valid photo that Kit Pay can optimize."
    }
}

private struct ProfileRow: Identifiable {
    var id: String { title }
    let title: String
    let subtitle: String
    let icon: String
    let destination: ProfileRowDestination
}

private enum ProfileRowDestination {
    case editProfile
    case profileEmail
    case communicationPrivacy
    case identityVerification
    case security
    case chatBackup
    case legalPrivacy
    case accountDeletion
}
