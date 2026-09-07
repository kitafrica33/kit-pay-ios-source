import SwiftUI

/// The same explicit selection feeds scheduled calls and the existing group-call pipeline.
struct CallRecipientPicker: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: [CallRecipientChoice]
    @State private var query = ""
    @State private var remoteResults: [KitUserSearchResultDTO] = []
    @State private var remoteResultQuery: String?
    @State private var searching = false

    private var contacts: [CallableContact] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = model.callContacts.filter { $0.isKitUser && (trimmed.isEmpty || model.callContactMatches($0, query: trimmed)) }
        let remote = KitUserDirectorySearch.addressableContacts(
            from: remoteResultQuery == KitUserDirectorySearch.remoteQuery(from: query) ? remoteResults : [],
            excludingUserID: model.profile?.id,
            excludingRecipientIDs: Set(saved.map { $0.id.lowercased() })
        )
        return saved + CallLifecyclePolicy.contactOptions(remote: remote, history: [],
            context: model.phoneIdentityContext, excludingUserId: model.profile?.id, remoteAlreadyOrdered: true)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Search contacts", text: $query)
                        .textInputAutocapitalization(.never)
                    Text("Choose 1–20 people. \(selection.count) selected.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ContactSyncRecoveryView()
                if !selection.isEmpty {
                    Section("Selected") {
                        ForEach(selection) { choice in
                            Button { selection.removeAll { $0.id == choice.id } } label: {
                                HStack {
                                    Text(choice.name).foregroundStyle(KitColor.primaryText)
                                    Spacer()
                                    Image(systemName: "minus.circle").foregroundStyle(.red)
                                }
                            }
                            .accessibilityLabel("Remove \(choice.name)")
                        }
                    }
                }
                Section("On Kit Pay") {
                    if searching { ProgressView("Searching Kit Pay…") }
                    if contacts.isEmpty && !searching { Text("No contacts found").foregroundStyle(.secondary) }
                    ForEach(contacts) { contact in
                        let selected = selection.contains { $0.id.caseInsensitiveCompare(contact.id) == .orderedSame }
                        Button {
                            if selected {
                                selection.removeAll { $0.id.caseInsensitiveCompare(contact.id) == .orderedSame }
                            } else if selection.count < 20 {
                                selection.append(CallRecipientChoice(id: contact.id.lowercased(), name: contact.name))
                            }
                        } label: {
                            HStack(spacing: 12) {
                                RemoteAvatarView(name: contact.name, avatarURL: contact.source?.avatarURL, size: 40)
                                VStack(alignment: .leading) {
                                    VerifiedAccountNameLabel(designation: contact.source?.verification?.designation) {
                                        Text(contact.name).foregroundStyle(KitColor.primaryText)
                                    }
                                    Text(contact.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            }
                        }
                        .disabled(!selected && (selection.count >= 20 || !model.callReadinessAllowsRecipientAction(contact.id)))
                        .accessibilityValue(selected ? "Selected" : "Not selected")
                    }
                }
            }
            .navigationTitle("Choose people")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await model.loadCallContacts() }
            .task(id: "\(query):\(model.isOnline):\(model.profile?.id ?? "")") { await search() }
        }
    }

    @MainActor private func search() async {
        remoteResults = []
        remoteResultQuery = nil
        guard model.isSignedIn, model.isOnline,
              let requested = KitUserDirectorySearch.remoteQuery(from: query) else {
            searching = false
            return
        }
        let accountID = model.profile?.id
        searching = true
        do {
            try await Task.sleep(nanoseconds: 350_000_000)
            let results = try await model.searchKitUsers(query: requested)
            try Task.checkCancellation()
            guard requested == KitUserDirectorySearch.remoteQuery(from: query), accountID == model.profile?.id else { return }
            remoteResults = results
            remoteResultQuery = requested
            searching = false
        } catch {
            guard !Task.isCancelled, requested == KitUserDirectorySearch.remoteQuery(from: query) else { return }
            searching = false
        }
    }
}

struct GroupCallSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var recipients: [CallRecipientChoice] = []
    @State private var showPeople = false
    @State private var isStarting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { showPeople = true } label: {
                        Label(recipients.isEmpty ? "Choose people" : "\(recipients.count) people selected", systemImage: "person.2")
                    }
                    ForEach(recipients) { Text($0.name) }
                }
                Section {
                    Button { Task { await start(video: false) } } label: { Label("Voice call", systemImage: "phone") }
                    Button { Task { await start(video: true) } } label: { Label("Video call", systemImage: "video") }
                }
                .disabled(isStarting || CallSchedulingPolicy.recipientIDs(recipients, excluding: model.profile?.id) == nil)
                if isStarting { ProgressView("Starting call…") }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle("Group call")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .sheet(isPresented: $showPeople) { CallRecipientPicker(selection: $recipients).environmentObject(model) }
            .onChange(of: model.isSignedIn) { _, signedIn in if !signedIn { dismiss() } }
            .onChange(of: model.profile?.id) { _, _ in dismiss() }
            .onChange(of: model.communicationSurfacesConcealed) { _, concealed in if concealed { dismiss() } }
            .interactiveDismissDisabled(isStarting)
        }
    }

    @MainActor private func start(video: Bool) async {
        guard !isStarting, let ids = CallSchedulingPolicy.recipientIDs(recipients, excluding: model.profile?.id) else { return }
        isStarting = true
        errorMessage = nil
        model.lastError = nil
        let accountID = model.profile?.id
        await model.queueGroupCall(recipientIDs: ids, name: recipients.map(\.name).joined(separator: ", "), video: video)
        guard accountID == model.profile?.id, model.isSignedIn else { return }
        isStarting = false
        if let error = model.lastError { errorMessage = error } else { dismiss() }
    }
}
