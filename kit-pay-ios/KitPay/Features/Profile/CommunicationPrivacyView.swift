import SwiftUI

struct CommunicationPrivacyView: View {
    @EnvironmentObject private var model: AppModel
    @State private var pendingUnblock: CommunicationBlockedPerson?
    @State private var showBlockPicker = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                introduction

                if model.appReviewDemoIsActive {
                    Label(
                        "Privacy changes are disabled for this read-only App Review account.",
                        systemImage: "eye.fill"
                    )
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(KitColor.secondaryText)
                }

                if let errorMessage = model.communicationPrivacyErrorMessage {
                    errorCard(errorMessage)
                }

                preferenceCard
                    .disabled(!model.appReviewDemoMutationsAllowed)
                callsCard
                blockedAccountsCard
                    .disabled(!model.appReviewDemoMutationsAllowed)
            }
            .padding(18)
        }
        .background(KitColor.canvas.ignoresSafeArea())
        .navigationTitle("Communication privacy")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.loadCommunicationPrivacy() }
        .task {
            if !model.hasUsableCommunicationPrivacyProjection {
                await model.loadCommunicationPrivacy()
            }
        }
        .confirmationDialog(
            "Unblock \(pendingUnblock?.displayName ?? "this account")?",
            isPresented: Binding(
                get: { pendingUnblock != nil },
                set: { if !$0 { pendingUnblock = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Unblock") {
                guard let person = pendingUnblock else { return }
                pendingUnblock = nil
                Task { _ = await model.setCommunicationBlocked(false, userID: person.userId) }
            }
            Button("Cancel", role: .cancel) { pendingUnblock = nil }
        } message: {
            Text("You will be able to message and call each other again.")
        }
        .sheet(isPresented: $showBlockPicker) {
            CommunicationBlockPickerView()
                .environmentObject(model)
                .presentationBackground(.ultraThinMaterial)
        }
    }

    private var introduction: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(KitColor.green)
                .frame(width: 46, height: 46)
                .background(KitColor.paleGreen.opacity(0.34), in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text("Choose how people find you")
                    .font(.headline)
                    .foregroundStyle(KitColor.primaryText)
                Text("These choices apply across every device signed in to your Kit Pay account, except where a setting says it is limited to this iPhone.")
                    .font(.subheadline)
                    .foregroundStyle(KitColor.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(17)
        .kitGlass(cornerRadius: 24, shadow: false)
    }

    private var preferenceCard: some View {
        VStack(spacing: 0) {
            // The same three controls, in the same words, that account setup offered — so a user
            // returning here recognizes the choice they already made rather than a new one.
            discoveryToggle(
                .phoneNumber,
                isOn: model.communicationPreferences?.phoneDiscoverable ?? false
            ) { enabled in
                Task { await model.setPhoneDiscoverable(enabled) }
            }

            Divider().padding(.leading, 68)

            // Device-local, and deliberately not gated on the server projection: it governs
            // whether *this* iPhone uploads its address book, so it must stay usable offline and
            // while the preferences request is in flight.
            discoveryToggle(
                .contacts,
                isOn: model.contactDiscoveryEnabled,
                requiresServerPreferences: false
            ) { enabled in
                Task { await model.setContactDiscoveryEnabled(enabled) }
            }

            Divider().padding(.leading, 68)

            discoveryToggle(
                .messageRequests,
                isOn: model.communicationPreferences?.directMessageRequestsEnabled ?? false
            ) { enabled in
                Task { await model.setDirectMessageRequestsEnabled(enabled) }
            }

            if model.messagingRealtimeAvailable {
                Divider().padding(.leading, 68)

                privacyToggle(
                    title: "Show my online status",
                    subtitle: "People you chat with can see when you are online or typing. Turning this off also hides their status on this device.",
                    systemName: "dot.radiowaves.left.and.right",
                    isOn: model.communicationPreferences?.messagingPresenceVisible ?? false
                ) { enabled in
                    Task { await model.setMessagingPresenceVisible(enabled) }
                }
            }
        }
        .overlay {
            if model.isLoadingCommunicationPrivacy && model.communicationPreferences == nil {
                ProgressView("Loading privacy choices")
                    .padding()
                    .background(.ultraThinMaterial, in: Capsule())
                    // The device-local toggles in this card stay usable while the server
                    // projection loads, so the spinner must not swallow their taps.
                    .allowsHitTesting(false)
            }
        }
        .kitGlass(cornerRadius: 26, shadow: false)
    }

    private var callsCard: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "phone.down.fill")
                .font(.headline)
                .foregroundStyle(.orange)
                .frame(width: 42, height: 42)
                .background(.orange.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text("Control unwanted calls")
                    .font(.headline)
                    .foregroundStyle(KitColor.primaryText)
                Text("Block an account below or from Contact info to stop messages and calls in both directions.")
                    .font(.subheadline)
                    .foregroundStyle(KitColor.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(17)
        .kitGlass(cornerRadius: 24, shadow: false)
    }

    private var blockedAccountsCard: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Blocked accounts")
                        .font(.headline)
                        .foregroundStyle(KitColor.primaryText)
                    Text("Blocked accounts cannot find, message, or call you.")
                        .font(.caption)
                        .foregroundStyle(KitColor.secondaryText)
                }
                Spacer()
                if model.isLoadingCommunicationPrivacy {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Refreshing blocked accounts")
                }
            }
            .padding(17)

            if model.hasUsableCommunicationPrivacyProjection
                && model.communicationBlockedPeople.isEmpty {
                Divider().padding(.leading, 17)
                Label("No blocked accounts", systemImage: "checkmark.shield.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KitColor.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(17)
            } else {
                ForEach(Array(model.communicationBlockedPeople.enumerated()), id: \.element.userId) {
                    index, person in
                    if index > 0 || model.hasUsableCommunicationPrivacyProjection {
                        Divider().padding(.leading, 75)
                    }
                    blockedPersonRow(person)
                }
            }

            Divider().padding(.leading, 17)
            Button { showBlockPicker = true } label: {
                HStack(spacing: 13) {
                    Image(systemName: "person.crop.circle.badge.minus")
                        .font(.headline)
                        .foregroundStyle(.red)
                        .frame(width: 46, height: 46)
                        .background(.red.opacity(0.1), in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Block an account")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(KitColor.primaryText)
                        Text(blockCandidateSummary)
                            .font(.caption)
                            .foregroundStyle(KitColor.secondaryText)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 17)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .disabled(!model.hasUsableCommunicationPrivacyProjection)
            .opacity(model.hasUsableCommunicationPrivacyProjection ? 1 : 0.55)
            .accessibilityHint("Choose a synced Kit Pay contact to block")
        }
        .kitGlass(cornerRadius: 26, shadow: false)
    }

    private var blockCandidateSummary: String {
        switch model.communicationBlockCandidates.count {
        case 0: "No available synced contacts"
        case 1: "1 synced contact available"
        case let count: "\(count.formatted()) synced contacts available"
        }
    }

    private func blockedPersonRow(_ person: CommunicationBlockedPerson) -> some View {
        HStack(spacing: 13) {
            RemoteAvatarView(
                name: person.displayName,
                avatarURL: person.avatarURL,
                size: 46,
                verification: person.verification
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(person.displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(KitColor.primaryText)
                    .lineLimit(1)
                if let detail = person.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(KitColor.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if model.communicationPrivacyMutation == .unblock(person.userId) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Unblocking \(person.displayName)")
            } else {
                Button("Unblock") { pendingUnblock = person }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KitColor.green)
                    .disabled(model.isCommunicationPrivacyBusy || !model.isOnline)
                    .accessibilityLabel("Unblock \(person.displayName)")
                    .accessibilityHint("Allows messages and calls with this account again")
            }
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 12)
    }

    private func discoveryToggle(
        _ control: AccountDiscoveryControl,
        isOn: Bool,
        requiresServerPreferences: Bool = true,
        changed: @escaping (Bool) -> Void
    ) -> some View {
        privacyToggle(
            title: control.title,
            subtitle: control.subtitle,
            systemName: control.systemImage,
            isOn: isOn,
            requiresServerPreferences: requiresServerPreferences,
            changed: changed
        )
        .accessibilityIdentifier(control.accessibilityIdentifier)
    }

    private func privacyToggle(
        title: String,
        subtitle: String,
        systemName: String,
        isOn: Bool,
        requiresServerPreferences: Bool = true,
        changed: @escaping (Bool) -> Void
    ) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: changed)) {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: systemName)
                    .font(.headline)
                    .foregroundStyle(KitColor.green)
                    .frame(width: 42, height: 42)
                    .background(KitColor.paleGreen.opacity(0.28), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(KitColor.primaryText)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(KitColor.secondaryText)
                }
            }
        }
        .tint(KitColor.green)
        .disabled(
            !model.appReviewDemoMutationsAllowed
                || (requiresServerPreferences && (
                    model.communicationPreferences == nil
                        || model.isCommunicationPrivacyBusy
                        || !model.isOnline
                ))
        )
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityHint(subtitle)
        .padding(17)
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: model.isOnline ? "exclamationmark.triangle.fill" : "wifi.slash")
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(KitColor.primaryText)
            Spacer(minLength: 8)
            if model.isOnline {
                Button("Retry") { Task { await model.loadCommunicationPrivacy() } }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KitColor.green)
                    .disabled(model.isCommunicationPrivacyBusy)
            }
        }
        .padding(15)
        .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .contain)
    }
}

private struct CommunicationBlockPickerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var pendingBlock: CommunicationBlockCandidate?

    private var candidates: [CommunicationBlockCandidate] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return model.communicationBlockCandidates }
        return model.communicationBlockCandidates.filter { candidate in
            candidate.displayName.localizedCaseInsensitiveContains(trimmedQuery)
                || candidate.detail?.localizedCaseInsensitiveContains(trimmedQuery) == true
        }
    }

    var body: some View {
        let visibleCandidates = candidates
        NavigationStack {
            Group {
                if visibleCandidates.isEmpty {
                    ContentUnavailableView(
                        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "No accounts available"
                            : "No matching accounts",
                        systemImage: "person.crop.circle.badge.minus",
                        description: Text(
                            query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? "Sync a Kit Pay contact, then return here to block the account."
                                : "Try another name, phone number or @tag."
                        )
                    )
                } else {
                    List(visibleCandidates) { candidate in
                        Button { pendingBlock = candidate } label: {
                            HStack(spacing: 13) {
                                RemoteAvatarView(
                                    name: candidate.displayName,
                                    avatarURL: candidate.avatarURL,
                                    size: 46,
                                    verification: candidate.verification
                                )
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(candidate.displayName)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(KitColor.primaryText)
                                        .lineLimit(1)
                                    if let detail = candidate.detail {
                                        Text(detail)
                                            .font(.caption)
                                            .foregroundStyle(KitColor.secondaryText)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 8)
                                if model.communicationPrivacyMutation == .block(candidate.userId) {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text("Block")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.red)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isCommunicationPrivacyBusy || !model.isOnline)
                        .accessibilityLabel("Block \(candidate.displayName)")
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(KitColor.canvas.ignoresSafeArea())
            .safeAreaInset(edge: .top, spacing: 0) {
                ContactSyncRecoveryView(horizontalPadding: 16, verticalPadding: 8)
            }
            .navigationTitle("Block an account")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Name, phone or @tag")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            await model.loadCommunicationPrivacy()
                            await model.loadContactDirectory()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(model.isCommunicationPrivacyBusy || !model.isOnline)
                    .accessibilityLabel("Refresh contacts and blocked accounts")
                }
            }
            .task { await model.loadContactDirectory() }
            .safeAreaInset(edge: .bottom) {
                if let errorMessage = model.communicationPrivacyErrorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background(.ultraThinMaterial)
                }
            }
            .confirmationDialog(
                "Block \(pendingBlock?.displayName ?? "this account")?",
                isPresented: Binding(
                    get: { pendingBlock != nil },
                    set: { if !$0 { pendingBlock = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Block", role: .destructive) {
                    guard let candidate = pendingBlock else { return }
                    pendingBlock = nil
                    Task {
                        _ = await model.setCommunicationBlocked(
                            true,
                            userID: candidate.userId
                        )
                    }
                }
                Button("Cancel", role: .cancel) { pendingBlock = nil }
            } message: {
                Text("You will no longer be able to message or call each other. You can unblock this account at any time.")
            }
        }
    }
}
