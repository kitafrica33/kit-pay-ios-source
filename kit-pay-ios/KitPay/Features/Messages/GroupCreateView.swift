import SwiftUI

// MARK: - Policy

/// Client-side group composition limits. The backend remains authoritative;
/// these bounds only keep the picker from submitting a group the server would
/// reject outright.
enum GroupCreatePolicy {
    static let minimumMembers = 1
    /// Other people selected by the creator; the creator occupies the remaining roster slot.
    static let maximumMembers = SecureMessagingWire.maximumGroupMembers - 1
    static let nameRange = MessagingGroupTitlePolicy.characterRange

    static func isValidName(_ value: String) -> Bool {
        MessagingGroupTitlePolicy.isValid(value)
    }

    /// Reuses the account-wide outbound privacy decision so blocked contacts and contacts whose
    /// privacy authority has not loaded cannot be added through a stale or partially loaded picker.
    static func eligibleContacts(
        _ contacts: [WalletContactDTO],
        currentUserID: String?,
        allowsOutbound: (String) -> Bool
    ) -> [WalletContactDTO] {
        let selfUserID = groupCreateCanonicalUserID(currentUserID)
        var seenUserIDs: Set<String> = []
        return contacts.filter { contact in
            guard let userID = ContactRecipientDirectory.recipientUserId(for: contact),
                  userID != selfUserID,
                  allowsOutbound(userID),
                  seenUserIDs.insert(userID).inserted
            else { return false }
            return true
        }
    }
}

// MARK: - Private helpers

/// A member the user has picked, captured at selection time so the chip row
/// stays stable even if the synced contact directory refreshes mid-flow.
private struct GroupCreateSelectedMember: Identifiable, Equatable {
    let userID: String
    let name: String
    let avatarURL: String?
    let verification: AccountVerificationDesignation?
    var id: String { userID }
}

private enum GroupCreateStep: Equatable {
    case members
    case name
}

// MARK: - View

/// Two-step group creation: pick 1...31 other Kit Pay users, then name the group.
/// A pure UI shell — the closure owns creation; this view never mutates AppModel.
struct GroupCreateView: View {
    /// Creates the group; returns the new conversation's id on success, nil on failure
    /// (the model surfaces its own error copy).
    let createGroup: (_ name: String, _ memberUserIDs: [String]) async -> String?
    /// Called with the created conversation id so the presenter can open it.
    let onCreated: (String) -> Void

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var step: GroupCreateStep = .members
    @State private var query = ""
    @State private var selectedMembers: [GroupCreateSelectedMember] = []
    @State private var showCapNotice = false
    @State private var groupName = ""
    @State private var isCreating = false
    @State private var creationFailed = false

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .members:
                    memberSelectionStep
                case .name:
                    nameStep
                }
            }
            .navigationTitle("New group")
            .navigationBarTitleDisplayMode(.inline)
            .background(KitColor.canvas)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(step == .members ? "Cancel" : "Back") {
                        if step == .members {
                            dismiss()
                        } else {
                            withAnimation(.snappy(duration: 0.2)) { step = .members }
                        }
                    }
                    .disabled(isCreating)
                }
            }
        }
        .tint(KitColor.green)
        .interactiveDismissDisabled(isCreating)
        .task {
            if !model.hasUsableCommunicationPrivacyProjection {
                await model.loadCommunicationPrivacy()
            }
        }
    }

    // MARK: Step 1 — member selection

    private var memberSelectionStep: some View {
        let eligible = eligibleContacts()
        let visibleContacts = eligible.filter {
            ContactRecipientDirectory.matches(
                $0,
                query: query,
                context: model.phoneIdentityContext
            )
        }
        return VStack(spacing: 0) {
            VStack(spacing: 10) {
                searchCapsule
                if !selectedMembers.isEmpty {
                    selectedMemberChips
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 9)
            .background(KitColor.canvas)

            if !model.hasUsableCommunicationPrivacyProjection {
                ContentUnavailableView(
                    "Contacts unavailable",
                    systemImage: "hand.raised",
                    description: Text("Communication privacy is still loading. Try again shortly.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if eligible.isEmpty {
                ContentUnavailableView(
                    "No contacts on Kit Pay yet",
                    systemImage: "person.2",
                    description: Text("Groups can only include people who already use Kit Pay. Invite your contacts first, then start a group.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleContacts.isEmpty {
                ContentUnavailableView(
                    "No matches",
                    systemImage: "magnifyingglass",
                    description: Text("Try another name, phone, or @kittag.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section("Contacts on Kit Pay") {
                        ForEach(visibleContacts) { contact in
                            contactRow(contact)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(KitColor.canvas)
            }
        }
        .safeAreaInset(edge: .bottom) { memberSelectionBar }
    }

    private var searchCapsule: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(KitColor.secondaryText)
            TextField("Name, phone or @kittag", text: $query)
                .font(.body)
                .foregroundStyle(KitColor.primaryText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityLabel("Search contacts")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(KitColor.secondaryText)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, 15)
        .padding(.trailing, query.isEmpty ? 15 : 0)
        .frame(height: 44)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(.white.opacity(0.68), lineWidth: 0.7)
                .allowsHitTesting(false)
        }
    }

    private var selectedMemberChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(selectedMembers) { member in
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            removeSelection(userID: member.userID)
                        }
                    } label: {
                        HStack(spacing: 7) {
                            RemoteAvatarView(
                                name: member.name,
                                avatarURL: member.avatarURL,
                                size: 28
                            )
                            VerifiedAccountNameLabel(designation: member.verification) {
                                Text(member.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(KitColor.primaryText)
                                    .lineLimit(1)
                            }
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(KitColor.secondaryText)
                                .accessibilityHidden(true)
                        }
                        .padding(.leading, 8)
                        .padding(.trailing, 10)
                        .frame(minHeight: 44)
                        .kitCapsuleGlass(interactive: false, shadow: false)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(member.name)
                    .accessibilityHint("Removes this person from the new group")
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
        .accessibilityLabel("Selected members")
    }

    private func contactRow(_ contact: WalletContactDTO) -> some View {
        let userID = ContactRecipientDirectory.recipientUserId(for: contact)
        let isSelected = userID.map(isSelected(userID:)) ?? false
        return Button {
            guard let userID else { return }
            toggleSelection(contact: contact, userID: userID)
        } label: {
            HStack(spacing: 12) {
                RemoteAvatarView(
                    name: contact.name,
                    avatarURL: contact.avatarURL,
                    size: 44
                )
                VStack(alignment: .leading, spacing: 3) {
                    VerifiedAccountNameLabel(
                        designation: contact.verification?.designation
                    ) {
                        Text(contact.name)
                            .font(.headline)
                            .foregroundStyle(KitColor.primaryText)
                    }
                    Text(contact.phone.groupCreateNilIfBlank ?? "Kit Pay member")
                        .font(.caption)
                        .foregroundStyle(KitColor.secondaryText)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isSelected ? KitColor.green : KitColor.secondaryText.opacity(0.5))
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(contact.name)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint("Toggles this contact's group membership")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var memberSelectionBar: some View {
        VStack(spacing: 8) {
            if showCapNotice {
                Text("You can add 1 to \(GroupCreatePolicy.maximumMembers) other people.")
                    .font(.footnote)
                    .foregroundStyle(KitColor.secondaryText)
                    .transition(.opacity)
            }
            Text(memberCountSummary)
                .font(.footnote)
                .foregroundStyle(KitColor.secondaryText)
            Button {
                withAnimation(.snappy(duration: 0.2)) { step = .name }
            } label: {
                Text("Next")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(KitPrimaryButtonStyle())
            .disabled(!memberSelectionIsValid)
            .opacity(memberSelectionIsValid ? 1 : 0.55)
            .accessibilityLabel("Next: name the group")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .kitGlass(cornerRadius: 24, shadow: false)
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    // MARK: Step 2 — group name

    private var nameStep: some View {
        ScrollView {
            VStack(spacing: 22) {
                AvatarView(
                    name: trimmedGroupName.isEmpty ? "New group" : trimmedGroupName,
                    size: 84
                )
                .kitCircularGlass(diameter: 102, interactive: false)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 8) {
                    TextField("Group name", text: $groupName)
                        .font(.body)
                        .foregroundStyle(KitColor.primaryText)
                        .submitLabel(.done)
                        .disabled(isCreating)
                        .padding(.horizontal, 18)
                        .frame(minHeight: 52)
                        .kitGlass(cornerRadius: 22, shadow: false)
                        .accessibilityLabel("Group name")
                    Text(nameHelperText)
                        .font(.caption)
                        .foregroundStyle(KitColor.secondaryText)
                        .padding(.horizontal, 6)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("\(selectedMembers.count) members")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(KitColor.primaryText)
                    Text(memberSummaryNames)
                        .font(.caption)
                        .foregroundStyle(KitColor.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .kitGlass(cornerRadius: 24, shadow: false)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(selectedMembers.count) members: \(memberSummaryNames)")

                if creationFailed {
                    Text("The group could not be created. Try again.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(22)
        }
        .background(KitColor.canvas)
        .onChange(of: groupName) { creationFailed = false }
        .safeAreaInset(edge: .bottom) { createBar }
    }

    private var createBar: some View {
        Button {
            submit()
        } label: {
            HStack(spacing: 10) {
                if isCreating {
                    ProgressView()
                        .tint(.white)
                }
                Text(isCreating ? "Creating group…" : "Create group")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(KitPrimaryButtonStyle())
        .disabled(isCreating || !nameIsValid || !memberSelectionIsValid)
        .opacity(nameIsValid || isCreating ? 1 : 0.55)
        .accessibilityLabel(isCreating ? "Creating group" : "Create group")
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .kitGlass(cornerRadius: 24, shadow: false)
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    // MARK: Derived state

    /// The user's synced contacts that resolve to an addressable and privacy-allowed Kit Pay
    /// account, deduplicated per recipient and never including the signed-in user.
    private func eligibleContacts() -> [WalletContactDTO] {
        GroupCreatePolicy.eligibleContacts(
            model.contactDirectory,
            currentUserID: model.profile?.id,
            allowsOutbound: { model.communicationPrivacyAllowsOutbound(to: $0) }
        )
    }

    private func isSelected(userID: String) -> Bool {
        selectedMembers.contains { $0.userID == userID }
    }

    private var memberSelectionIsValid: Bool {
        let eligibleUserIDs = Set(eligibleContacts().compactMap {
            ContactRecipientDirectory.recipientUserId(for: $0)
        })
        return (GroupCreatePolicy.minimumMembers ... GroupCreatePolicy.maximumMembers)
            .contains(selectedMembers.count)
            && selectedMembers.allSatisfy { eligibleUserIDs.contains($0.userID) }
    }

    private var memberCountSummary: String {
        if selectedMembers.count < GroupCreatePolicy.minimumMembers {
            return "Choose at least one other person (\(selectedMembers.count) selected)"
        }
        return "\(selectedMembers.count) of \(GroupCreatePolicy.maximumMembers) members selected"
    }

    private var memberSummaryNames: String {
        selectedMembers.map(\.name).joined(separator: ", ")
    }

    private var trimmedGroupName: String {
        groupName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nameIsValid: Bool {
        GroupCreatePolicy.isValidName(trimmedGroupName)
    }

    private var nameHelperText: String {
        let byteCount = trimmedGroupName.utf8.count
        let scalarCount = trimmedGroupName.unicodeScalars.count
        return "\(scalarCount)/\(GroupCreatePolicy.nameRange.upperBound) Unicode characters · \(byteCount)/\(MessagingGroupTitlePolicy.maximumUTF8Bytes) UTF-8 bytes"
    }

    // MARK: Selection

    private func toggleSelection(contact: WalletContactDTO, userID: String) {
        if isSelected(userID: userID) {
            withAnimation(.snappy(duration: 0.2)) {
                removeSelection(userID: userID)
            }
        } else if selectedMembers.count < GroupCreatePolicy.maximumMembers {
            withAnimation(.snappy(duration: 0.2)) {
                selectedMembers.append(
                    GroupCreateSelectedMember(
                        userID: userID,
                        name: contact.name,
                        avatarURL: contact.avatarURL,
                        verification: contact.verification?.designation
                    )
                )
            }
        } else {
            withAnimation(.snappy(duration: 0.2)) { showCapNotice = true }
        }
    }

    private func removeSelection(userID: String) {
        selectedMembers.removeAll { $0.userID == userID }
        if selectedMembers.count < GroupCreatePolicy.maximumMembers {
            showCapNotice = false
        }
    }

    // MARK: Creation

    @MainActor
    private func submit() {
        guard !isCreating, nameIsValid, memberSelectionIsValid else { return }
        let name = trimmedGroupName
        let memberUserIDs = selectedMembers.map(\.userID)
        isCreating = true
        creationFailed = false
        Task { @MainActor in
            let conversationID = await createGroup(name, memberUserIDs)
            isCreating = false
            if let conversationID {
                onCreated(conversationID)
                dismiss()
            } else {
                creationFailed = true
            }
        }
    }
}

// MARK: - File-private helpers

private func groupCreateCanonicalUserID(_ rawValue: String?) -> String? {
    guard let rawValue,
          let id = UUID(uuidString: rawValue.trimmingCharacters(in: .whitespacesAndNewlines))
    else { return nil }
    return id.uuidString.lowercased()
}

private extension String {
    var groupCreateNilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
