import SwiftUI

// MARK: - Member presentation

/// Display-only projection of one group member. Role strings are never
/// interpreted for permissions here — the caller gates every mutating closure.
struct GroupMemberPresentation: Identifiable, Equatable {
    let userID: String
    let displayName: String
    let isCurrentUser: Bool
    let role: String?          // "owner" | "admin" | nil(member) — display only
    /// Resolved by the caller from the contact directory; nil for members whose photo this
    /// device has never been given.
    var avatarURL: String?
    var id: String { userID }
}

// MARK: - View

/// Group info sheet. A pure UI shell — every mutation flows through an optional
/// closure that is non-nil only when the caller has already role-gated it.
struct GroupProfileView: View {
    let conversationID: String
    let title: String
    let members: [GroupMemberPresentation]
    /// Non-nil only when the current user may perform the action (role-gated by the caller).
    let renameGroup: ((String) async -> Bool)?
    let addMembers: (() -> Void)?
    let canRemoveMember: ((String) -> Bool)?
    let removeMember: ((String) async -> Bool)?   // userID
    let leaveGroup: (() async -> Bool)?
    /// Opens the shared media library for this conversation.
    let openMediaLibrary: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var memberQuery = ""
    @State private var showRenamePrompt = false
    @State private var renameDraft = ""
    @State private var isRenaming = false
    @State private var renameFailed = false
    @State private var memberPendingRemoval: GroupMemberPresentation?
    @State private var removingMemberID: String?
    @State private var removalFailed = false
    @State private var showLeaveConfirmation = false
    @State private var isLeaving = false
    @State private var leaveFailed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    header
                    membersSection
                    if addMembers != nil || openMediaLibrary != nil {
                        actionRows
                    }
                    if leaveGroup != nil {
                        leaveSection
                    }
                }
                .padding(22)
            }
            .background(KitColor.canvas.ignoresSafeArea())
            .navigationTitle("Group info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Rename group", isPresented: $showRenamePrompt) {
                TextField("Group name", text: $renameDraft)
                Button("Save") { submitRename() }
                    .disabled(!isValidGroupName(renameDraft))
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Group names are 1 to \(GroupCreatePolicy.nameRange.upperBound) Unicode characters and at most \(MessagingGroupTitlePolicy.maximumUTF8Bytes) UTF-8 bytes.")
            }
        }
        .tint(KitColor.green)
        .interactiveDismissDisabled(isRenaming || isLeaving || removingMemberID != nil)
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 12) {
            AvatarView(name: displayedTitle, size: 96)
                .kitCircularGlass(diameter: 116, interactive: false)
                .accessibilityLabel("Group avatar for \(displayedTitle)")

            if renameGroup != nil {
                Button {
                    renameDraft = displayedTitle
                    renameFailed = false
                    showRenamePrompt = true
                } label: {
                    HStack(spacing: 8) {
                        Text(displayedTitle)
                            .font(.largeTitle.bold())
                            .foregroundStyle(KitColor.primaryText)
                            .multilineTextAlignment(.center)
                        if isRenaming {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "pencil")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(KitColor.green)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isRenaming)
                .accessibilityLabel("Group name: \(displayedTitle)")
                .accessibilityHint("Renames the group")
            } else {
                Text(displayedTitle)
                    .font(.largeTitle.bold())
                    .foregroundStyle(KitColor.primaryText)
                    .multilineTextAlignment(.center)
            }

            if renameFailed {
                Text("The group name could not be changed. Try again.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

            Text("\(members.count) \(members.count == 1 ? "member" : "members")")
                .font(.subheadline)
                .foregroundStyle(KitColor.secondaryText)
        }
    }

    // MARK: Members

    private var membersSection: some View {
        let visibleMembers = filteredMembers
        return VStack(alignment: .leading, spacing: 10) {
            Text("Members")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(KitColor.secondaryText)
                .padding(.horizontal, 6)

            if isMemberSearchEnabled {
                memberSearchCapsule
            }

            VStack(spacing: 0) {
                if visibleMembers.isEmpty {
                    Text("No members match your search.")
                        .font(.subheadline)
                        .foregroundStyle(KitColor.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                } else {
                    ForEach(visibleMembers) { member in
                        memberRow(member)
                        if member != visibleMembers.last {
                            Divider().padding(.leading, 74)
                        }
                    }
                }
            }
            .kitGlass(cornerRadius: 24, shadow: false)
            .confirmationDialog(
                "Remove \(memberPendingRemoval?.displayName ?? "this member")?",
                isPresented: removalConfirmationBinding,
                titleVisibility: .visible,
                presenting: memberPendingRemoval
            ) { member in
                Button("Remove from group", role: .destructive) {
                    submitRemoval(of: member)
                }
                Button("Cancel", role: .cancel) {}
            } message: { member in
                Text("\(member.displayName) will no longer see new messages in this group.")
            }

            if removalFailed {
                Text("The member could not be removed. Try again.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
            }
        }
    }

    private var memberSearchCapsule: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(KitColor.secondaryText)
            TextField("Search members", text: $memberQuery)
                .font(.body)
                .foregroundStyle(KitColor.primaryText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityLabel("Search members")
            if !memberQuery.isEmpty {
                Button {
                    memberQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(KitColor.secondaryText)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear member search")
            }
        }
        .padding(.leading, 15)
        .padding(.trailing, memberQuery.isEmpty ? 15 : 0)
        .frame(height: 44)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(.white.opacity(0.68), lineWidth: 0.7)
                .allowsHitTesting(false)
        }
    }

    private func memberRow(_ member: GroupMemberPresentation) -> some View {
        HStack(spacing: 12) {
            RemoteAvatarView(name: member.displayName, avatarURL: member.avatarURL, size: 44)
            HStack(spacing: 8) {
                Text(member.displayName)
                    .font(.headline)
                    .foregroundStyle(KitColor.primaryText)
                    .lineLimit(1)
                if member.isCurrentUser {
                    Text("You")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(KitColor.secondaryText)
                }
            }
            Spacer(minLength: 10)
            if removingMemberID == member.userID {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Removing \(member.displayName)")
            } else if let roleLabel = roleLabel(for: member) {
                Text(roleLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(KitColor.green)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(KitColor.paleGreen, in: Capsule())
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 8)
        .frame(minHeight: 60)
        .contentShape(Rectangle())
        .contextMenu {
            if canRemove(member) {
                Button(role: .destructive) {
                    removalFailed = false
                    memberPendingRemoval = member
                } label: {
                    Label("Remove from group", systemImage: "person.badge.minus")
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(memberAccessibilityLabel(member))
        .accessibilityHint(canRemove(member) ? "Touch and hold to remove from the group" : "")
    }

    private func canRemove(_ member: GroupMemberPresentation) -> Bool {
        removeMember != nil
            && canRemoveMember?(member.userID) == true
            && !member.isCurrentUser
            && removingMemberID == nil
    }

    private func roleLabel(for member: GroupMemberPresentation) -> String? {
        let role = member.role?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch role {
        case "owner": return "Owner"
        case "admin": return "Admin"
        default: return nil
        }
    }

    private func memberAccessibilityLabel(_ member: GroupMemberPresentation) -> String {
        var parts = [member.displayName]
        if member.isCurrentUser { parts.append("you") }
        if let roleLabel = roleLabel(for: member) { parts.append(roleLabel) }
        return parts.joined(separator: ", ")
    }

    private var isMemberSearchEnabled: Bool {
        members.count > 12
    }

    private var filteredMembers: [GroupMemberPresentation] {
        let trimmed = memberQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isMemberSearchEnabled, !trimmed.isEmpty else { return members }
        return members.filter { $0.displayName.localizedStandardContains(trimmed) }
    }

    private var removalConfirmationBinding: Binding<Bool> {
        Binding(
            get: { memberPendingRemoval != nil },
            set: { if !$0 { memberPendingRemoval = nil } }
        )
    }

    // MARK: Actions

    private var actionRows: some View {
        VStack(spacing: 12) {
            if addMembers != nil {
                actionRow(title: "Add members", systemName: "person.badge.plus") {
                    addMembers?()
                }
            }
            if openMediaLibrary != nil {
                actionRow(title: "Media, audio & documents", systemName: "photo.on.rectangle.angled") {
                    openMediaLibrary?()
                }
            }
        }
    }

    private func actionRow(
        title: String,
        systemName: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(KitColor.green)
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 15)
            .frame(minHeight: 44)
            .kitGlass(cornerRadius: 24, shadow: false)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    // MARK: Leave group

    private var leaveSection: some View {
        VStack(spacing: 8) {
            Button {
                leaveFailed = false
                showLeaveConfirmation = true
            } label: {
                HStack(spacing: 11) {
                    if isLeaving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                    }
                    Text("Leave group")
                        .font(.body.weight(.semibold))
                    Spacer()
                }
                .foregroundStyle(.red)
                .padding(17)
                .frame(minHeight: 44)
                .kitGlass(cornerRadius: 22, shadow: false)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isLeaving)
            .accessibilityLabel("Leave group")
            .accessibilityHint("You will stop sending and receiving messages in this group")
            .confirmationDialog(
                "Leave \(displayedTitle)?",
                isPresented: $showLeaveConfirmation,
                titleVisibility: .visible
            ) {
                Button("Leave group", role: .destructive) { submitLeave() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You will no longer send or receive messages in this group.")
            }

            if leaveFailed {
                Text("You could not leave the group. Try again.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: Derived state

    private var displayedTitle: String {
        title
    }

    private func isValidGroupName(_ rawValue: String) -> Bool {
        GroupCreatePolicy.isValidName(rawValue)
    }

    // MARK: Mutations (closure-driven)

    @MainActor
    private func submitRename() {
        guard let renameGroup, !isRenaming else { return }
        let name = MessagingGroupTitlePolicy.normalized(renameDraft)
        guard GroupCreatePolicy.isValidName(name) else { return }
        guard name != displayedTitle else { return }
        isRenaming = true
        renameFailed = false
        Task { @MainActor in
            let renamed = await renameGroup(name)
            isRenaming = false
            if !renamed {
                renameFailed = true
            }
        }
    }

    @MainActor
    private func submitRemoval(of member: GroupMemberPresentation) {
        guard let removeMember,
              !member.isCurrentUser,
              removingMemberID == nil
        else { return }
        removingMemberID = member.userID
        removalFailed = false
        Task { @MainActor in
            let removed = await removeMember(member.userID)
            removingMemberID = nil
            if !removed { removalFailed = true }
        }
    }

    @MainActor
    private func submitLeave() {
        guard let leaveGroup, !isLeaving else { return }
        isLeaving = true
        leaveFailed = false
        Task { @MainActor in
            let left = await leaveGroup()
            isLeaving = false
            if left {
                dismiss()
            } else {
                leaveFailed = true
            }
        }
    }
}

/// Adds one contact at a time through the server-authoritative membership endpoint. Reopening the
/// sheet supports additional members while ensuring each response can replace the complete roster
/// atomically instead of presenting partial success for a client-side batch.
struct GroupMemberPickerView: View {
    let existingMemberUserIDs: Set<String>
    let addMember: (String) async -> Bool

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var addingUserID: String?
    @State private var addFailed = false

    var body: some View {
        NavigationStack {
            Group {
                if !model.hasUsableCommunicationPrivacyProjection {
                    ContentUnavailableView(
                        "Contacts unavailable",
                        systemImage: "hand.raised",
                        description: Text("Communication privacy is still loading. Try again shortly.")
                    )
                } else if eligibleContacts.isEmpty {
                    ContentUnavailableView(
                        "No contacts to add",
                        systemImage: "person.badge.plus",
                        description: Text("Everyone eligible in your contacts is already in this group.")
                    )
                } else {
                    List {
                        if addFailed {
                            Text("This person could not be added. Try again.")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                        Section("Contacts on Kit Pay") {
                            ForEach(visibleContacts) { contact in
                                contactRow(contact)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(KitColor.canvas)
            .navigationTitle("Add member")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Name, phone or @kittag")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(addingUserID != nil)
                }
            }
        }
        .tint(KitColor.green)
        .interactiveDismissDisabled(addingUserID != nil)
        .task {
            if !model.hasUsableCommunicationPrivacyProjection {
                await model.loadCommunicationPrivacy()
            }
        }
    }

    private var eligibleContacts: [WalletContactDTO] {
        GroupCreatePolicy.eligibleContacts(
            model.contactDirectory,
            currentUserID: model.profile?.id,
            allowsOutbound: { model.communicationPrivacyAllowsOutbound(to: $0) }
        ).filter { contact in
            guard let userID = ContactRecipientDirectory.recipientUserId(for: contact) else {
                return false
            }
            return !existingMemberUserIDs.contains(userID)
        }
    }

    private var visibleContacts: [WalletContactDTO] {
        eligibleContacts.filter {
            ContactRecipientDirectory.matches(
                $0,
                query: query,
                context: model.phoneIdentityContext
            )
        }
    }

    private func contactRow(_ contact: WalletContactDTO) -> some View {
        let userID = ContactRecipientDirectory.recipientUserId(for: contact)
        return Button {
            guard let userID, addingUserID == nil else { return }
            addingUserID = userID
            addFailed = false
            Task { @MainActor in
                let added = await addMember(userID)
                addingUserID = nil
                if added {
                    dismiss()
                } else {
                    addFailed = true
                }
            }
        } label: {
            HStack(spacing: 12) {
                RemoteAvatarView(name: contact.name, avatarURL: contact.avatarURL, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(contact.name)
                        .font(.headline)
                        .foregroundStyle(KitColor.primaryText)
                    Text(
                        contact.phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "Kit Pay member"
                            : contact.phone.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                        .font(.caption)
                        .foregroundStyle(KitColor.secondaryText)
                }
                Spacer()
                if addingUserID == userID {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(KitColor.green)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(addingUserID != nil || userID == nil)
        .accessibilityLabel("Add \(contact.name) to the group")
    }
}
