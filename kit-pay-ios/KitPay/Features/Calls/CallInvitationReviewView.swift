import SwiftUI

struct CallInvitationReviewView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let intent: CallInvitationIntent
    @State private var inspection: CallInviteInspectionDTO?
    @State private var isLoading = false
    @State private var isSubmitting = false
    @State private var accepted = false
    @State private var errorMessage: String?

    private var accountIsCurrent: Bool {
        model.callInvitationUIReady && intent.accountID == model.profile?.id.lowercased()
    }

    var body: some View {
        NavigationStack {
            Group {
                if accountIsCurrent {
                    Form {
                        if isLoading { ProgressView("Loading invitation…") }
                        if let inspection {
                            Section {
                                if let schedule = inspection.scheduledCall {
                                    Label(schedule.displayTitle, systemImage: schedule.type == .video ? "video" : "phone")
                                    if let date = schedule.startDate { Text(date, format: .dateTime.weekday().day().month().hour().minute()) }
                                    Text(schedule.status.label).foregroundStyle(.secondary)
                                } else if let call = inspection.call {
                                    Label(call.name ?? "Call invitation", systemImage: call.type == "video" ? "video" : "phone")
                                    Text("You have been invited to join this call.").foregroundStyle(.secondary)
                                }
                            }
                            if let schedule = inspection.scheduledCall {
                                Section("People") { ForEach(schedule.participants) { Text($0.name) } }
                            }
                            Section {
                                if inspection.liveCallID != nil {
                                    Button("Join call") { Task { await join(inspection) } }
                                    Text("If another Kit Pay call is active, joining puts that call on hold when everyone supports it.")
                                        .font(.footnote).foregroundStyle(.secondary)
                                } else if let schedule = inspection.scheduledCall, schedule.status.isPending {
                                    if accepted {
                                        Label("Invitation accepted", systemImage: "checkmark.circle")
                                    } else {
                                        Button("Accept invitation") { Task { await respond(scheduleID: schedule.id) } }
                                    }
                                    Text("Kit Pay will ring you when the call starts.").font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                            .disabled(isSubmitting || !model.isOnline)
                        }
                        if isSubmitting { ProgressView() }
                        if let errorMessage {
                            Section {
                                Text(errorMessage).foregroundStyle(.red)
                                Button("Refresh invitation") { Task { await inspect() } }.disabled(isLoading || isSubmitting || !model.isOnline)
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("Invitation unavailable", systemImage: "phone")
                }
            }
            .navigationTitle("Call invitation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(isSubmitting) } }
            .task(id: intent.id) { await inspect() }
            .interactiveDismissDisabled(isSubmitting)
        }
    }

    @MainActor private func inspect() async {
        guard accountIsCurrent, !isLoading, !isSubmitting else { return }
        isLoading = true; errorMessage = nil; inspection = nil
        defer { isLoading = false }
        let token = intent.token
        do {
            let result = try await model.withCallAccountSession(feature: "calls_invite_links") { try await $0.inspectCallInvitation(token: token) }
            guard accountIsCurrent else { return }
            switch result.kind {
            case .call:
                guard result.call != nil, result.scheduledCall == nil else { throw APIClientError.invalidResponse }
            case .scheduledCall:
                guard let schedule = result.scheduledCall, result.call == nil,
                      schedule.status != .started || schedule.callId != nil else { throw APIClientError.invalidResponse }
            }
            inspection = result
            accepted = result.scheduledCall?.myResponse == .accepted
        } catch is CancellationError { return }
        catch { errorMessage = "This invitation could not be opened. It may have expired or changed, or this account may not be invited." }
    }

    @MainActor private func respond(scheduleID: String) async {
        guard accountIsCurrent, !isSubmitting else { return }
        isSubmitting = true; errorMessage = nil
        defer { isSubmitting = false }
        do {
            // Token redemption may turn into live acceptance when the schedule becomes due.
            // The RSVP endpoint cannot issue RTC credentials, even across that transition.
            _ = try await model.withCallAccountSession(feature: "calls_scheduling") {
                try await $0.respondToScheduledCall(id: scheduleID, response: .accepted)
            }
            guard accountIsCurrent else { return }
            accepted = true
        } catch is CancellationError { return }
        catch { errorMessage = error.localizedDescription }
    }

    @MainActor private func join(_ inspection: CallInviteInspectionDTO) async {
        guard accountIsCurrent, !isSubmitting, let callID = inspection.liveCallID else { return }
        isSubmitting = true; errorMessage = nil
        defer { isSubmitting = false }
        let token = intent.token
        let video = inspection.call?.type == "video" || inspection.scheduledCall?.type == .video
        let joined = await model.joinCallInvitation(expectedCallID: callID, video: video) { api, heldID, revision in
            try await api.joinCallInvitation(token: token, holdCallID: heldID, holdCallRevision: revision)
        }
        guard accountIsCurrent else { return }
        if joined { dismiss() }
        else { errorMessage = model.lastError ?? "The call could not be joined. Refresh the invitation and try again." }
    }
}
