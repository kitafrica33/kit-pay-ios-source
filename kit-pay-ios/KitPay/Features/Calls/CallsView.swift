import SwiftUI

struct CallsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showNewCall = false
    @State private var missedOnly = false

    private var canStartNewCall: Bool {
        model.appReviewDemoMutationsAllowed
            && model.mayCreateCall
            && model.hasUsableCommunicationPrivacyProjection
    }

    private var allCalls: [CallRecord] {
        model.state.calls
            .sorted { $0.startedAt > $1.startedAt }
    }

    private var calls: [CallRecord] {
        allCalls
            .filter {
                !missedOnly
                    || ConversationCallPresentationPolicy.presentation(for: $0).isMissed
            }
    }

    var body: some View {
        NavigationStack {
            Group {
                if allCalls.isEmpty {
                    ContentUnavailableView {
                        Label("No calls", systemImage: "phone")
                    } description: {
                        Text("Call history is saved on this device and remains visible offline.")
                    } actions: {
                        Button("New call") { showNewCall = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canStartNewCall)
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 9) {
                            Picker("Filter", selection: $missedOnly) {
                                Text("All").tag(false)
                                Text("Missed").tag(true)
                            }
                            .pickerStyle(.segmented)
                            .padding(.bottom, 8)
                            if calls.isEmpty {
                                ContentUnavailableView {
                                    Label("No missed calls", systemImage: "checkmark.circle")
                                } description: {
                                    Text("Missed calls will appear here.")
                                } actions: {
                                    Button("Show all calls") { missedOnly = false }
                                        .buttonStyle(.borderedProminent)
                                }
                                .padding(.vertical, 48)
                            } else {
                                ForEach(calls) { call in callRow(call) }
                            }
                        }
                        .padding(14)
                    }
                    .rootTabBarScrollClearance()
                }
            }
            .background(KitColor.canvas)
            .navigationTitle("Calls")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ConnectivityPill(
                        isOnline: model.isOnline,
                        queuedCount: model.queuedCount,
                        inBar: true
                    )
                }
                ToolbarItem(placement: .topBarTrailing) {
                    GlassIconButton(systemName: "phone.badge.plus", inBar: true) {
                        showNewCall = true
                    }
                        .disabled(!canStartNewCall)
                        .accessibilityLabel("New call")
                        .accessibilityHint("Choose a Kit Pay contact for an audio or video call")
                }
            }
            .refreshable { await model.refresh(userInitiated: true) }
            .sheet(isPresented: $showNewCall) {
                NewCallSheet()
                    .environmentObject(model)
            }
        }
    }

    private func callRow(_ call: CallRecord) -> some View {
        let presentation = ConversationCallPresentationPolicy.presentation(for: call)
        let isReadOnlyPreview = model.isReadOnlyAppReviewDemoCall(call.id)
        let recipientUserID = call.participantUserIds.first(where: {
            $0.caseInsensitiveCompare(model.profile?.id ?? "") != .orderedSame
        })
        let recipientCommunicationAllowed = model.communicationPrivacyAllowsOutbound(
            to: recipientUserID
        )
        let canRedial = !isReadOnlyPreview
            && model.mayCreateCall
            && recipientCommunicationAllowed
        return HStack(spacing: 13) {
            RemoteAvatarView(
                name: call.name,
                avatarURL: model.contactAvatarURL(forUserID: recipientUserID),
                size: 56
            )
            VStack(alignment: .leading, spacing: 5) {
                Text(call.name)
                    .font(.headline)
                    .foregroundStyle(presentation.isMissed ? .red : KitColor.primaryText)
                HStack(spacing: 5) {
                    Image(systemName: presentation.isOutgoing ? "arrow.up.right" : "arrow.down.left")
                    Text(
                        isReadOnlyPreview
                            ? "Read-only App Review preview"
                            : call.state == .queued
                                ? "Waiting for connection"
                                : AppPresentationClock.abbreviatedDateAndShortTime(call.startedAt)
                    )
                }
                .font(.subheadline)
                .foregroundStyle(call.state == .queued ? .orange : KitColor.secondaryText)
            }
            Spacer()
            if call.state == .queued {
                Image(systemName: "icloud.and.arrow.up")
                    .foregroundStyle(.orange)
            } else {
                GlassIconButton(systemName: call.isVideoCall ? "video" : "phone") {
                    guard let recipient = recipientUserID else { return }
                    Task {
                        await model.queueCall(
                            recipientId: recipient,
                            name: call.name,
                            video: call.isVideoCall
                        )
                    }
                }
                .disabled(!canRedial)
                .opacity(canRedial ? 1 : 0.48)
                .accessibilityLabel(
                    "\(call.isVideoCall ? "Video" : "Voice") call \(call.name)"
                )
                .accessibilityValue(
                    canRedial ? "" : "Unavailable"
                )
            }
        }
        .padding(12)
        .kitGlass(cornerRadius: 22, shadow: false)
    }
}

private struct CallKitUserSearchTaskKey: Hashable {
    let query: String
    let isOnline: Bool
}

private struct NewCallSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var directoryResults: [KitUserSearchResultDTO] = []
    @State private var directoryResultQuery: String?
    @State private var directorySearchID: UUID?
    @State private var directorySearchQuery: String?

    var body: some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = trimmed.isEmpty
            ? model.callContacts
            : model.callContacts.filter { model.callContactMatches($0, query: trimmed) }
        let savedKitContacts = matches.filter(\.isKitUser)
        let inviteContacts = matches.filter { !$0.isKitUser }
        let remoteQuery = KitUserDirectorySearch.remoteQuery(from: query)
        let currentDirectoryResults = directoryResultQuery == remoteQuery
            ? directoryResults
            : []
        let remoteContacts = remoteQuery == nil ? [] : KitUserDirectorySearch.addressableContacts(
            from: currentDirectoryResults,
            excludingUserID: model.profile?.id,
            excludingRecipientIDs: Set(savedKitContacts.map { $0.id.lowercased() })
        )
        let remoteCallContacts = CallLifecyclePolicy.contactOptions(
            remote: remoteContacts,
            history: [],
            context: model.phoneIdentityContext,
            excludingUserId: model.profile?.id,
            remoteAlreadyOrdered: true
        )
        let kitContacts = savedKitContacts + remoteCallContacts
        let isSearchingDirectory = directorySearchID != nil
            && directorySearchQuery == remoteQuery

        NavigationStack {
            Form {
                Section {
                    TextField("Search contacts", text: $query)
                        .textInputAutocapitalization(.never)
                }

                ContactSyncRecoveryView()

                if isSearchingDirectory && kitContacts.isEmpty {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Searching Kit Pay…")
                                .foregroundStyle(KitColor.secondaryText)
                        }
                    }
                } else if kitContacts.isEmpty && inviteContacts.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No contacts found",
                            systemImage: "person.crop.circle.badge.questionmark",
                            description: Text(model.isOnline
                                ? "Allow Contacts access to find people you know on Kit Pay."
                                : "Reconnect to load contacts, or redial a contact from call history.")
                        )
                    }
                }

                if !kitContacts.isEmpty {
                    Section("On Kit Pay") {
                        ForEach(kitContacts) { contact in
                            contactRow(contact)
                        }
                    }
                }

                if !inviteContacts.isEmpty {
                    Section("Invite to Kit Pay") {
                        ForEach(inviteContacts) { contact in
                            HStack(spacing: 12) {
                                AvatarView(name: contact.name, size: 42)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(contact.name).font(.headline)
                                    Text(contact.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(KitColor.secondaryText)
                                }
                                Spacer()
                                ShareLink(item: "Join me on Kit Pay so we can call securely.") {
                                    Image(systemName: "person.badge.plus")
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .accessibilityLabel("Invite \(contact.name)")
                            }
                        }
                    }
                }
                Section {
                    Text(!model.mayCreateCall
                         ? "Calls are not currently available for this account."
                         : model.isOnline
                            ? "Choose voice or video beside a Kit Pay contact."
                            : "Keep Kit Pay running. It will retry when you return to the app and internet access is restored. Quitting Kit Pay discards the pending attempt.")
                        .font(.footnote)
                }
            }
            .navigationTitle("New call")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task { await model.loadCallContacts() }
            .task(id: CallKitUserSearchTaskKey(query: query, isOnline: model.isOnline)) {
                await searchDirectory()
            }
        }
    }

    private func contactRow(_ contact: CallableContact) -> some View {
        HStack(spacing: 12) {
            RemoteAvatarView(
                name: contact.name,
                avatarURL: contact.source?.avatarURL,
                size: 42
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(contact.name).font(.headline)
                Text(contact.subtitle)
                    .font(.caption)
                    .foregroundStyle(KitColor.secondaryText)
            }
            Spacer()
            callButton(contact, video: false)
            callButton(contact, video: true)
        }
    }

    private func callButton(_ contact: CallableContact, video: Bool) -> some View {
        Button {
            Task {
                // Clearing first makes "no new error" unambiguous even when a retry fails
                // with the same message as before.
                model.lastError = nil
                await model.queueCall(recipientId: contact.id, name: contact.name, video: video)
                if model.lastError == nil {
                    dismiss()
                }
            }
        } label: {
            Image(systemName: video ? "video" : "phone")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(
            !model.appReviewDemoMutationsAllowed
                || !model.mayCreateCall
                || !model.communicationPrivacyAllowsOutbound(to: contact.id)
        )
        .accessibilityLabel("\(video ? "Video" : "Voice") call \(contact.name)")
    }

    @MainActor
    private func searchDirectory() async {
        guard let requestedQuery = KitUserDirectorySearch.remoteQuery(from: query) else {
            directorySearchID = nil
            directorySearchQuery = nil
            directoryResultQuery = nil
            directoryResults = []
            return
        }

        let requestID = UUID()
        directorySearchID = requestID
        directorySearchQuery = requestedQuery
        directoryResultQuery = nil
        directoryResults = []
        defer {
            if directorySearchID == requestID {
                directorySearchID = nil
                directorySearchQuery = nil
            }
        }
        guard model.isSignedIn, model.isOnline else { return }

        do {
            try await Task.sleep(nanoseconds: 350_000_000)
            let results = try await model.searchKitUsers(query: requestedQuery)
            try Task.checkCancellation()
            guard directorySearchID == requestID,
                  KitUserDirectorySearch.remoteQuery(from: query) == requestedQuery
            else { return }
            directoryResults = results
            directoryResultQuery = requestedQuery
        } catch is CancellationError {
            return
        } catch {
            guard directorySearchID == requestID,
                  KitUserDirectorySearch.remoteQuery(from: query) == requestedQuery
            else { return }
            directoryResults = []
            directoryResultQuery = requestedQuery
        }
    }
}
