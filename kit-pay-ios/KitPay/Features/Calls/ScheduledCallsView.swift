import SwiftUI

extension AppModel {
    var callManagementUIReady: Bool {
        isSignedIn && profile != nil && !requiresBiometricSignIn && accountSetupStep == nil
            && communicationAccessGranted && !communicationSurfacesConcealed
            && capabilities?.supportsFeature("calls") == true
    }
    var callSchedulingUIReady: Bool {
        callManagementUIReady && capabilities?.supportsFeature("calls_scheduling") == true
    }
    var callInvitationUIReady: Bool {
        callManagementUIReady && capabilities?.supportsFeature("calls_invite_links") == true
    }
}

struct ScheduledCallsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if model.callSchedulingUIReady {
                    ScheduledCallListContent().id(model.profile?.id)
                } else {
                    ContentUnavailableView("Scheduled calls unavailable", systemImage: "calendar",
                        description: Text("Complete call setup to manage scheduled calls."))
                }
            }
            .navigationTitle("Scheduled calls")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private struct ScheduledCallListContent: View {
    @EnvironmentObject private var model: AppModel
    @State private var schedules: [ScheduledCallDTO] = []
    @State private var nextCursor: String?
    @State private var seenCursors: Set<String> = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showCreate = false
    @State private var pendingCreation: CreateScheduledCallRequest?

    var body: some View {
        List {
            Section {
                Button { showCreate = true } label: {
                    Label(pendingCreation == nil ? "Schedule a call" : "Check schedule creation", systemImage: "calendar.badge.plus")
                }
                .disabled(!model.isOnline)
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            if !model.isOnline { Text("Reconnect to update scheduled calls.").foregroundStyle(.secondary) }
            if schedules.isEmpty && !isLoading {
                ContentUnavailableView("No scheduled calls", systemImage: "calendar",
                    description: Text("Choose a time and Kit Pay will ring everyone invited, including you."))
            }
            ForEach(schedules) { schedule in
                NavigationLink {
                    ScheduledCallDetailView(schedule: schedule) { updated in replace(updated) }
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Label(schedule.displayTitle, systemImage: schedule.type == .video ? "video" : "phone")
                        if let date = schedule.startDate { Text(date, format: .dateTime.day().month().hour().minute()).font(.subheadline) }
                        Text("\(schedule.status.label) · \(schedule.myResponse.label)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if isLoading { ProgressView() }
            if nextCursor != nil {
                Button("Load more") { Task { await load(reset: false) } }.disabled(isLoading || !model.isOnline)
            }
        }
        .task(id: model.isOnline) { if model.isOnline { await load(reset: true) } }
        .refreshable { await load(reset: true) }
        .sheet(isPresented: $showCreate) {
            ScheduledCallEditor(schedule: nil, pendingCreation: $pendingCreation) { replace($0) }
                .environmentObject(model)
        }
    }

    private func replace(_ schedule: ScheduledCallDTO) {
        schedules.removeAll { $0.id == schedule.id }
        schedules.append(schedule)
        schedules.sort { $0.startsAt > $1.startsAt }
    }

    @MainActor private func load(reset: Bool) async {
        guard !isLoading, model.isOnline else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        let cursor = reset ? nil : nextCursor
        do {
            let page = try await model.withCallAccountSession(feature: "calls_scheduling") { try await $0.scheduledCalls(cursor: cursor) }
            try Task.checkCancellation()
            guard page.page.limit == 50, page.items.count <= 50, let hasMore = page.page.hasMore else { throw APIClientError.invalidResponse }
            if hasMore {
                guard let next = page.page.nextCursor, !next.isEmpty, next.count <= 2048,
                      reset || (!seenCursors.contains(next) && cursor != next) else { throw APIClientError.invalidResponse }
            }
            if reset { schedules = []; seenCursors = [] }
            for schedule in page.items { replace(schedule) }
            nextCursor = hasMore ? page.page.nextCursor : nil
            if let nextCursor { seenCursors.insert(nextCursor) }
        } catch is CancellationError {
            return
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct ScheduledCallDetailView: View {
    @EnvironmentObject private var model: AppModel
    @State var schedule: ScheduledCallDTO
    let onChange: (ScheduledCallDTO) -> Void
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var showEdit = false
    @State private var confirmCancel = false
    @State private var shareLink: CallInviteLinkDTO?
    @State private var unusedCreation: CreateScheduledCallRequest?

    var body: some View {
        Form {
            Section {
                Text(schedule.displayTitle).font(.headline)
                if let date = schedule.startDate { Text(date, format: .dateTime.weekday().day().month().hour().minute()) }
                Text(TimeZone.current.localizedName(for: .generic, locale: .current) ?? TimeZone.current.identifier)
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Status", value: schedule.status.label)
                LabeledContent("Your response", value: schedule.myResponse.label)
                Text("Kit Pay rings everyone still invited at the scheduled time, including the organizer.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("People") {
                ForEach(schedule.participants) { participant in
                    LabeledContent(participant.name, value: participant.response.label)
                }
            }
            if schedule.status.isPending || schedule.status == .started {
                Section {
                    if schedule.myResponse != .accepted {
                        Button("Accept invitation") { Task { await respond(.accepted) } }
                    }
                    if schedule.myResponse != .declined {
                        Button("Decline invitation", role: .destructive) { Task { await respond(.declined) } }
                    }
                }
                .disabled(busy || !model.isOnline)
            }
            if schedule.isOrganizer(model.profile?.id) && schedule.status.isPending {
                Section {
                    Button("Edit schedule") { showEdit = true }
                    if model.capabilities?.supportsFeature("calls_invite_links") == true {
                        if let link = shareLink, let url = link.validatedShareURL {
                            ShareLink(item: url) { Label("Share invitation", systemImage: "square.and.arrow.up") }
                            Button("Revoke invitation link", role: .destructive) { Task { await revoke(link) } }
                        } else {
                            Button("Create invitation link") { Task { await createLink() } }
                        }
                        Text("Only people already invited can use this link.").font(.footnote).foregroundStyle(.secondary)
                    }
                    Button("Cancel scheduled call", role: .destructive) { confirmCancel = true }
                }
                .disabled(busy || !model.isOnline)
            }
            if busy { ProgressView() }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        }
        .navigationTitle("Call details")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .refreshable { await refresh() }
        .sheet(isPresented: $showEdit) {
            ScheduledCallEditor(schedule: schedule, pendingCreation: $unusedCreation) { update($0) }.environmentObject(model)
        }
        .confirmationDialog("Cancel this scheduled call for everyone?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Cancel scheduled call", role: .destructive) { Task { await cancel() } }
        }
    }

    private func update(_ updated: ScheduledCallDTO) {
        if schedule.revision != updated.revision { shareLink = nil }
        schedule = updated
        onChange(updated)
    }

    @MainActor private func perform(_ operation: @Sendable @escaping (APIClient) async throws -> ScheduledCallDTO) async {
        guard !busy else { return }
        busy = true; errorMessage = nil
        defer { busy = false }
        do { update(try await model.withCallAccountSession(feature: "calls_scheduling", operation)) }
        catch is CancellationError { return }
        catch { errorMessage = error.localizedDescription }
    }
    @MainActor private func refresh() async {
        let id = schedule.id
        await perform { try await $0.scheduledCall(id: id) }
    }
    @MainActor private func respond(_ response: ScheduledCallResponse) async {
        let id = schedule.id
        await perform { try await $0.respondToScheduledCall(id: id, response: response) }
    }
    @MainActor private func cancel() async {
        let id = schedule.id, revision = schedule.revision
        await perform { try await $0.cancelScheduledCall(id: id, revision: revision) }
    }
    @MainActor private func createLink() async {
        guard !busy else { return }
        busy = true; errorMessage = nil
        defer { busy = false }
        let id = schedule.id
        do {
            let link = try await model.withCallAccountSession(feature: "calls_invite_links") { try await $0.createScheduledCallInviteLink(id: id) }
            guard link.validatedShareURL != nil else { throw APIClientError.invalidResponse }
            shareLink = link
        } catch is CancellationError { return }
        catch { errorMessage = error.localizedDescription }
    }
    @MainActor private func revoke(_ link: CallInviteLinkDTO) async {
        guard !busy else { return }
        busy = true; errorMessage = nil
        defer { busy = false }
        do {
            try await model.withCallAccountSession(feature: "calls_invite_links") { try await $0.revokeCallInviteLink(id: link.id) }
            shareLink = nil
        } catch is CancellationError { return }
        catch { errorMessage = error.localizedDescription }
    }
}

private struct ScheduledCallEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let schedule: ScheduledCallDTO?
    @Binding var pendingCreation: CreateScheduledCallRequest?
    let onSave: (ScheduledCallDTO) -> Void
    @State private var title = ""
    @State private var type: ScheduledCallType = .voice
    @State private var startsAt = Date().addingTimeInterval(3600)
    @State private var recipients: [CallRecipientChoice] = []
    @State private var showPeople = false
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var initialized = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title (optional)", text: $title)
                    if schedule == nil {
                        Picker("Call type", selection: $type) { ForEach(ScheduledCallType.allCases, id: \.self) { Text($0.label).tag($0) } }
                    }
                    DatePicker("Starts", selection: $startsAt, displayedComponents: [.date, .hourAndMinute])
                    Text(TimeZone.current.localizedName(for: .generic, locale: .current) ?? TimeZone.current.identifier)
                        .font(.caption).foregroundStyle(.secondary)
                    Button { showPeople = true } label: {
                        Label(recipients.isEmpty ? "Choose people" : "\(recipients.count) people selected", systemImage: "person.2")
                    }
                    ForEach(recipients) { Text($0.name) }
                }
                .disabled(busy || pendingCreation != nil)
                Section {
                    Text("Kit Pay will ring everyone invited at this time, including you. Invitees can accept or decline ahead of time.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if pendingCreation != nil && !busy {
                        Text("The creation request is saved while this screen is open. Retry to check the same schedule.")
                            .font(.footnote)
                    }
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                    if busy { ProgressView("Saving…") }
                }
            }
            .navigationTitle(schedule == nil ? "Schedule a call" : "Edit schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(pendingCreation == nil ? "Save" : "Retry") { Task { await save() } }
                        .disabled(busy || !model.isOnline)
                }
            }
            .onAppear { initialize() }
            .sheet(isPresented: $showPeople) { CallRecipientPicker(selection: $recipients).environmentObject(model) }
            .interactiveDismissDisabled(busy)
        }
    }

    private func initialize() {
        guard !initialized else { return }
        initialized = true
        if let pendingCreation {
            title = pendingCreation.title ?? ""
            type = pendingCreation.type
            startsAt = CallSchedulingPolicy.date(pendingCreation.startsAt) ?? startsAt
            recipients = pendingCreation.recipientUserIds.map { id in
                CallRecipientChoice(id: id, name: model.callContacts.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }?.name ?? "Invited person")
            }
        } else if let schedule {
            title = schedule.title ?? ""
            type = schedule.type
            startsAt = schedule.startDate ?? startsAt
            recipients = schedule.participants.filter { $0.userId.caseInsensitiveCompare(schedule.organizerUserId) != .orderedSame }
                .map { CallRecipientChoice(id: $0.userId, name: $0.name) }
        }
    }

    @MainActor private func save() async {
        guard !busy else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanTitle.count <= 160 else { errorMessage = "Use a title of 160 characters or fewer."; return }
        guard let ids = CallSchedulingPolicy.recipientIDs(recipients, excluding: model.profile?.id) else {
            errorMessage = "Choose 1–20 different people."; return
        }
        // An uncertain create keeps the same command and UUID even after its start time passes.
        guard pendingCreation != nil || CallSchedulingPolicy.validNewStart(startsAt) else {
            errorMessage = "Choose a future time within the next year."; return
        }
        let wasCreationRetry = pendingCreation != nil
        busy = true; errorMessage = nil
        defer { busy = false }
        do {
            let saved: ScheduledCallDTO
            if let schedule {
                let request = UpdateScheduledCallRequest(revision: schedule.revision, recipientUserIds: ids,
                    startsAt: CallSchedulingPolicy.timestamp(startsAt), title: cleanTitle.isEmpty ? nil : cleanTitle)
                saved = try await model.withCallAccountSession(feature: "calls_scheduling") {
                    try await $0.updateScheduledCall(id: schedule.id, request: request)
                }
            } else {
                let request = pendingCreation ?? CreateScheduledCallRequest(clientScheduleId: UUID().uuidString.lowercased(),
                    recipientUserIds: ids, type: type, startsAt: CallSchedulingPolicy.timestamp(startsAt),
                    title: cleanTitle.isEmpty ? nil : cleanTitle, conversationId: nil)
                pendingCreation = request
                saved = try await model.withCallAccountSession(feature: "calls_scheduling") { try await $0.createScheduledCall(request) }
                pendingCreation = nil
            }
            onSave(saved)
            dismiss()
        } catch is CancellationError { return }
        catch {
            // A definite first-attempt rejection can be corrected. Once a response has been
            // lost, preserve the command until the server confirms its result.
            if !wasCreationRetry, let failure = error as? APIErrorPayload,
               let status = failure.httpStatus, (400 ... 499).contains(status), status != 408, status != 429 {
                pendingCreation = nil
            }
            errorMessage = error.localizedDescription
        }
    }
}
