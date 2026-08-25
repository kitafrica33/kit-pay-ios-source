import SwiftUI

typealias AbuseReportSubmitter = @Sendable (
    _ request: CreateAbuseReportRequest,
    _ idempotencyKey: String
) async throws -> AbuseReportReceipt

@MainActor
final class AbuseReportViewModel: ObservableObject {
    @Published private(set) var isSubmitting = false
    @Published private(set) var receipt: AbuseReportReceipt?
    @Published var errorMessage: String?

    private let submitter: AbuseReportSubmitter
    private let attemptStore: AbuseReportAttemptStore

    init(
        submitter: @escaping AbuseReportSubmitter = { request, idempotencyKey in
            try await APIClient.shared.submitAbuseReport(
                request,
                idempotencyKey: idempotencyKey
            )
        },
        attemptStore: AbuseReportAttemptStore = .shared
    ) {
        self.submitter = submitter
        self.attemptStore = attemptStore
    }

    @discardableResult
    func submit(
        _ request: CreateAbuseReportRequest,
        reporterAccountID: String,
        reportingAvailable: Bool,
        isOnline: Bool
    ) async -> Bool {
        guard !isSubmitting else { return false }
        guard reportingAvailable else {
            errorMessage = "Reporting is temporarily unavailable."
            return false
        }
        guard isOnline else {
            errorMessage = "Connect to the internet to submit this report."
            return false
        }

        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            let attempt = try await attemptStore.attempt(
                for: request,
                accountID: reporterAccountID
            )
            let receipt = try await submitter(request, attempt.idempotencyKey)
            guard receipt.confirms(request) else { throw APIClientError.invalidResponse }
            self.receipt = receipt
            // A validated server receipt is definitive even if local cleanup fails. Keeping a
            // stale marker is safe: a later identical submission replays the same server report.
            // Most importantly, cleanup is never attempted before this confirmation boundary.
            _ = try? await attemptStore.completeIfCurrent(attempt)
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = AbuseReportErrorCopy.message(for: error)
            return false
        }
    }
}

struct AbuseReportView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var flow = AbuseReportViewModel()

    let reportedName: String
    let context: AbuseReportContext
    let target: AbuseReportTarget
    let messages: [LocalMessage]

    @State private var reason: AbuseReportReason?
    @State private var details = ""
    @State private var selectedMessageIDs: Set<String> = []
    @State private var consentsToSelectedPlaintext = false
    @State private var pendingRequest: CreateAbuseReportRequest?
    @State private var showConfirmation = false

    private var candidates: [AbuseReportMessageCandidate] {
        AbuseReportMessageSelectionPolicy.candidates(
            from: messages,
            context: context,
            targetMessageID: target.messageID
        )
    }

    private var selectedCandidates: [AbuseReportMessageCandidate] {
        candidates
            .filter { selectedMessageIDs.contains($0.id) }
            .sorted {
                if $0.createdAt == $1.createdAt { return $0.id < $1.id }
                return $0.createdAt < $1.createdAt
            }
    }

    private var targetCandidate: AbuseReportMessageCandidate? {
        candidates.first(where: { $0.isReportTarget })
    }

    private var reportingAvailable: Bool {
        AbuseReportContract.isAvailable(features: model.capabilities?.features)
    }

    private var canReview: Bool {
        reason != nil
            && !flow.isSubmitting
            && reportingAvailable
            && reporterAccountIsCurrent
            && model.isOnline
            && (selectedMessageIDs.isEmpty || consentsToSelectedPlaintext)
    }

    private var reporterAccountIsCurrent: Bool {
        CommunicationPrivacyIdentifier.canonicalUUID(model.profile?.id) == context.currentUserID
    }

    var body: some View {
        Group {
            if let receipt = flow.receipt {
                successView(receipt)
            } else {
                reportForm
            }
        }
        .background(KitColor.canvas.ignoresSafeArea())
        .navigationTitle(target.type == .message ? "Report message" : "Report account")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(flow.isSubmitting)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(flow.receipt == nil ? "Cancel" : "Done") { dismiss() }
                    .disabled(flow.isSubmitting)
            }
        }
        .confirmationDialog(
            "Send this report to Kit Pay?",
            isPresented: $showConfirmation,
            titleVisibility: .visible
        ) {
            Button("Send report", role: .destructive) {
                guard let pendingRequest, reporterAccountIsCurrent else {
                    self.pendingRequest = nil
                    flow.errorMessage = "Sign in again before submitting this report."
                    return
                }
                Task {
                    _ = await flow.submit(
                        pendingRequest,
                        reporterAccountID: context.currentUserID,
                        reportingAvailable: reportingAvailable,
                        isOnline: model.isOnline
                    )
                    self.pendingRequest = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingRequest = nil }
        } message: {
            Text(confirmationMessage)
        }
        .onChange(of: selectedMessageIDs) { _, _ in
            // Consent describes the exact current selection. Any edit requires a fresh opt-in.
            consentsToSelectedPlaintext = false
        }
    }

    private var reportForm: some View {
        Form {
            Section {
                Text("Report \(reportedName)")
                    .font(.headline)
                Text(
                    "Your report goes to authorized Kit Pay moderators. Reporting does not block this account; use Block account separately if you want to stop messages and calls."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section("Reason") {
                Picker("Choose a reason", selection: $reason) {
                    Text("Choose a reason").tag(nil as AbuseReportReason?)
                    ForEach(AbuseReportReason.allCases) { reason in
                        Text(reason.title).tag(reason as AbuseReportReason?)
                    }
                }
            }

            Section {
                TextEditor(text: $details)
                    .frame(minHeight: 110)
                    .onChange(of: details) { _, value in
                        let limited = AbuseReportContract.limitedNote(value)
                        if limited != value { details = limited }
                    }
                    .accessibilityLabel("Optional report details")
                Text("\(details.unicodeScalars.count)/\(AbuseReportContract.maximumNoteCharacters)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } header: {
                Text("Details (optional)")
            } footer: {
                Text("Write only information you want Kit Pay moderators to read.")
            }

            if target.messageID != nil {
                Section("Reported message") {
                    Label(targetPlaintextDisclosure, systemImage: "lock.doc.fill")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if candidates.isEmpty {
                    Text("No delivered text messages are available to share.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(candidates) { candidate in
                        messageRow(candidate)
                    }
                }
            } header: {
                Text("Message context (optional)")
            } footer: {
                Text(
                    "Kit Pay's servers cannot decrypt your chat. No messages are selected automatically. You may choose up to five delivered text messages; attachments, payment events and all other history stay private."
                )
            }

            if !selectedMessageIDs.isEmpty {
                Section {
                    ForEach(selectedCandidates) { candidate in
                        exactPlaintextDisclosure(candidate)
                    }
                } header: {
                    Text("Exact plaintext to share")
                } footer: {
                    Text(
                        "Every character shown above will be sent to authorized moderators if you consent and submit. Nothing is shortened or hidden."
                    )
                }

                Section("Plaintext sharing consent") {
                    Toggle(isOn: $consentsToSelectedPlaintext) {
                        Text(
                            "I agree to share the \(selectedMessageIDs.count) selected message\(selectedMessageIDs.count == 1 ? "" : "s") as readable text with authorized moderators."
                        )
                    }
                }
            }

            if !reportingAvailable {
                Label("Reporting is temporarily unavailable.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if !reporterAccountIsCurrent {
                Label("Sign in again before submitting this report.", systemImage: "person.crop.circle.badge.exclamationmark")
                    .foregroundStyle(.orange)
            } else if !model.isOnline {
                Label("Connect to the internet to submit a report.", systemImage: "wifi.slash")
                    .foregroundStyle(.orange)
            }

            if let errorMessage = flow.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }

            Section {
                Button {
                    prepareConfirmation()
                } label: {
                    HStack {
                        Spacer()
                        if flow.isSubmitting { ProgressView() }
                        Text(flow.isSubmitting ? "Submitting…" : "Review and send")
                            .font(.headline)
                        Spacer()
                    }
                }
                .disabled(!canReview)
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func messageRow(_ candidate: AbuseReportMessageCandidate) -> some View {
        let isSelected = selectedMessageIDs.contains(candidate.id)
        let canSelect = AbuseReportMessageSelectionPolicy.canSelect(
            candidate,
            selectedIDs: selectedMessageIDs,
            candidates: candidates
        )
        return Button {
            if isSelected {
                selectedMessageIDs.remove(candidate.id)
            } else if canSelect {
                selectedMessageIDs.insert(candidate.id)
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? KitColor.green : .secondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(candidate.isOutgoing ? "You" : reportedName)
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text(candidate.createdAt, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if candidate.isReportTarget {
                        Label("Reported message", systemImage: "exclamationmark.bubble.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                    }
                    Text(verbatim: candidate.plaintext)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(isSelected || candidate.isReportTarget ? nil : 3)
                        .multilineTextAlignment(.leading)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canSelect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(isSelected ? "Remove" : "Share") \(candidate.isReportTarget ? "reported " : "")message from \(candidate.isOutgoing ? "you" : reportedName)"
        )
        .accessibilityValue(candidate.plaintext)
    }

    private var confirmationMessage: String {
        if selectedMessageIDs.isEmpty {
            if target.messageID != nil {
                return "Moderators will receive the selected reason, any details you wrote, and the reported message ID. The message plaintext and attachments will not be sent."
            }
            return "Moderators will receive the selected reason and any details you wrote. No message plaintext or attachments will be sent."
        }
        let targetCopy: String
        if let targetCandidate,
           !selectedMessageIDs.contains(targetCandidate.id) {
            targetCopy = " The reported message ID will be sent without that message's plaintext."
        } else if target.messageID != nil, targetCandidate == nil {
            targetCopy = " The reported message ID will be sent without that message's plaintext."
        } else {
            targetCopy = ""
        }
        return "Moderators will receive the selected reason, any details you wrote, and \(selectedMessageIDs.count) explicitly selected message\(selectedMessageIDs.count == 1 ? "" : "s") as plaintext.\(targetCopy) No other chat history or attachments will be sent."
    }

    private var targetPlaintextDisclosure: String {
        guard let targetMessageID = target.messageID else { return "" }
        guard let targetCandidate else {
            return "The reported message ID \(targetMessageID) will be sent without plaintext. This message is not eligible for readable sharing from this device."
        }
        if selectedMessageIDs.contains(targetCandidate.id) {
            return consentsToSelectedPlaintext
                ? "The reported message ID and the exact plaintext shown below will be sent."
                : "The reported message ID will be sent, but its plaintext will not be sent unless you explicitly consent below."
        }
        return "The reported message ID will be sent without plaintext unless you select the row labeled Reported message and explicitly consent below."
    }

    private func exactPlaintextDisclosure(
        _ candidate: AbuseReportMessageCandidate
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(candidate.isOutgoing ? "You" : reportedName)
                    .font(.caption.weight(.semibold))
                if candidate.isReportTarget {
                    Text("Reported message")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.red)
                }
                Spacer()
                Text(candidate.createdAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: candidate.plaintext)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Exact plaintext selected from \(candidate.isOutgoing ? "you" : reportedName)"
        )
        .accessibilityValue(candidate.plaintext)
    }

    private func prepareConfirmation() {
        guard let reason, canReview else { return }
        do {
            let selectedMessages = try AbuseReportMessageSelectionPolicy.payloads(
                selectedIDs: selectedMessageIDs,
                candidates: candidates
            )
            pendingRequest = try CreateAbuseReportRequest(
                context: context,
                target: target,
                reason: reason,
                reporterNote: details,
                selectedMessages: selectedMessages,
                shareSelectedMessagePlaintext: consentsToSelectedPlaintext
            )
            flow.errorMessage = nil
            showConfirmation = true
        } catch {
            pendingRequest = nil
            flow.errorMessage = "Review the report details and try again."
        }
    }

    private func successView(_ receipt: AbuseReportReceipt) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 52, weight: .semibold))
                .foregroundStyle(KitColor.green)
            Text("Report received")
                .font(.title2.bold())
            Text(
                "Thank you. Kit Pay's moderation team received your report. You can also block this account from Contact info."
            )
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            Text("Reference \(receipt.id)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 17))
                .tint(KitColor.navy)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
