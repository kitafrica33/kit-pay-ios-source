import SwiftUI

/// Picks the minute a message or payment request should leave the device.
///
/// The common answers are one tap; the picker underneath is for everything else. It is the same
/// sheet for composing a new schedule and for editing one, so "Send Later" and "Edit Schedule"
/// cannot drift into two slightly different experiences.
struct ScheduleSendSheet: View {
    let title: String
    let confirmTitle: String
    let preview: String?
    /// Prefilled when an existing schedule is being edited.
    let initialDate: Date?
    let onSchedule: (Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: Date = ScheduledSendPolicy.defaultSuggestion(now: Date())
    @State private var now: Date = Date()

    private var quickChoices: [ScheduledSendChoice] {
        ScheduledSendPolicy.quickChoices(now: now, calendar: AppPresentationClock.calendar)
    }

    private var canSchedule: Bool {
        ScheduledSendPolicy.isSchedulable(selection, now: now)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let preview, !preview.isEmpty {
                        Text(preview)
                            .font(.subheadline)
                            .foregroundStyle(KitColor.primaryText)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(
                                KitColor.paleGreen,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                            )
                    }

                    if !quickChoices.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Quick picks")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(KitColor.secondaryText)
                            HStack(spacing: 8) {
                                ForEach(quickChoices) { choice in
                                    Button {
                                        withAnimation(.snappy(duration: 0.22)) {
                                            selection = choice.date
                                        }
                                    } label: {
                                        Text(choice.title)
                                            .font(.footnote.weight(.semibold))
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(
                                        isSelected(choice.date) ? .white : KitColor.primaryText
                                    )
                                    .background(
                                        isSelected(choice.date)
                                            ? AnyShapeStyle(KitColor.green)
                                            : AnyShapeStyle(.thinMaterial),
                                        in: Capsule()
                                    )
                                    .accessibilityAddTraits(
                                        isSelected(choice.date) ? [.isSelected] : []
                                    )
                                }
                            }
                        }
                    }

                    DatePicker(
                        "Send on",
                        selection: $selection,
                        in: ScheduledSendPolicy.earliestSelectableDate(now: now)
                            ... ScheduledSendPolicy.latestSelectableDate(now: now),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.graphical)
                    .tint(KitColor.green)

                    Label(
                        ScheduledSendPolicy.offlineFootnote,
                        systemImage: "wifi.exclamationmark"
                    )
                    .font(.footnote)
                    .foregroundStyle(KitColor.secondaryText)
                }
                .padding(16)
            }
            .background(KitColor.canvas)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmTitle) {
                        onSchedule(selection)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!canSchedule)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text(
                    ScheduledSendPolicy.label(
                        for: selection,
                        now: now,
                        calendar: AppPresentationClock.calendar,
                        time: Self.timeLabel,
                        day: Self.dayLabel
                    )
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(canSchedule ? KitColor.green : .orange)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
            }
        }
        .presentationDetents([.large])
        .onAppear {
            now = AppPresentationClock.now
            selection = initialDate
                ?? ScheduledSendPolicy.defaultSuggestion(
                    now: now,
                    calendar: AppPresentationClock.calendar
                )
        }
    }

    private func isSelected(_ date: Date) -> Bool {
        AppPresentationClock.calendar.isDate(selection, equalTo: date, toGranularity: .minute)
    }

    static func timeLabel(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func dayLabel(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}

/// The block of not-yet-sent items pinned under the conversation timeline.
///
/// It sits below everything that has actually happened, separated by its own heading, so nothing
/// here can be mistaken for a message the other person has received.
struct ScheduledSendSection: View {
    let items: [ScheduledChatItem]
    let isOnline: Bool
    let failureReason: (UUID) -> String?
    let onSendNow: (ScheduledChatItem) -> Void
    let onEditSchedule: (ScheduledChatItem) -> Void
    let onCancel: (ScheduledChatItem) -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "clock.badge.checkmark")
                Text(items.count == 1 ? "Scheduled" : "Scheduled · \(items.count)")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(KitColor.secondaryText)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 6)

            ForEach(items) { item in
                ScheduledChatCard(
                    item: item,
                    isOnline: isOnline,
                    failureReason: failureReason(item.id),
                    onSendNow: { onSendNow(item) },
                    onEditSchedule: { onEditSchedule(item) },
                    onCancel: { onCancel(item) }
                )
                .transition(
                    .asymmetric(
                        insertion: .scale(scale: 0.94, anchor: .bottomTrailing)
                            .combined(with: .opacity),
                        removal: .opacity
                    )
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .animation(.snappy(duration: 0.28), value: items)
    }
}

/// One waiting item. Deliberately not a chat bubble: a dashed outline and a muted surface read as
/// "not sent yet" at a glance, without needing the label to be read first.
struct ScheduledChatCard: View {
    let item: ScheduledChatItem
    let isOnline: Bool
    let failureReason: String?
    let onSendNow: () -> Void
    let onEditSchedule: () -> Void
    let onCancel: () -> Void

    @State private var pulse = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
    }

    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: item.isPaymentRequest ? "arrow.down.left.circle.fill" : "clock.fill")
                    .font(.footnote)
                    .foregroundStyle(indicatorColor)
                    .opacity(pulse ? 0.55 : 1)
                Text(statusLabel(now: now))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(indicatorColor)
                Spacer(minLength: 8)
            }

            Text(item.preview)
                .font(.subheadline)
                .foregroundStyle(KitColor.primaryText)
                .lineLimit(4)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let footnote = footnote(now: now) {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(KitColor.secondaryText)
            }
        }
        .padding(12)
        .frame(maxWidth: 300, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    indicatorColor.opacity(0.45),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
        }
        .contextMenu {
            Button {
                onSendNow()
            } label: {
                Label("Send now", systemImage: "paperplane.fill")
            }
            Button {
                onEditSchedule()
            } label: {
                Label("Edit schedule", systemImage: "calendar.badge.clock")
            }
            Button(role: .destructive) {
                onCancel()
            } label: {
                Label(
                    item.isPaymentRequest ? "Cancel request" : "Cancel message",
                    systemImage: "trash"
                )
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(statusLabel(now: now)). \(item.preview)")
        .accessibilityHint("Long press for send now, edit schedule, or cancel.")
        .onAppear {
            guard failureReason == nil else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private var indicatorColor: Color {
        failureReason == nil ? KitColor.green : .orange
    }

    private func statusLabel(now: Date) -> String {
        if failureReason != nil {
            return item.isPaymentRequest ? "Request not sent" : "Not sent"
        }
        guard ScheduledSendPolicy.isPending(scheduledAt: item.scheduledAt, now: now) else {
            return "Sending…"
        }
        let label = ScheduledSendPolicy.label(
            for: item.scheduledAt,
            now: now,
            calendar: AppPresentationClock.calendar,
            time: ScheduleSendSheet.timeLabel,
            day: ScheduleSendSheet.dayLabel
        )
        return item.isPaymentRequest ? "Request · \(label)" : label
    }

    private func footnote(now: Date) -> String? {
        if let failureReason { return failureReason }
        guard !isOnline,
              !ScheduledSendPolicy.isPending(scheduledAt: item.scheduledAt, now: now)
        else { return nil }
        return ScheduledSendPolicy.offlineFootnote
    }
}

// MARK: - Server-side scheduled payments

@MainActor
final class ChatScheduledPaymentsViewModel: ObservableObject {
    @Published private(set) var items: [ScheduledPaymentDTO] = []
    @Published private(set) var isLoading = false
    @Published private(set) var cancellingID: String?
    @Published var errorMessage: String?

    private let api: any ScheduledPaymentServicing

    init(api: any ScheduledPaymentServicing = APIClient.shared) {
        self.api = api
    }

    func load(conversationID: String, enabled: Bool, isOnline: Bool) async {
        guard enabled, isOnline, !isLoading else {
            if !enabled { items = [] }
            return
        }
        guard let canonicalConversationID = ScheduledPaymentValidation.canonicalUUID(
            conversationID
        ) else {
            items = []
            errorMessage = ChatScheduledPaymentError.invalidConversation.errorDescription
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        let previous = items
        do {
            var fetched: [ScheduledPaymentDTO] = []
            for status in [
                ScheduledPaymentStatus.scheduled,
                .queued,
                .processing,
            ] {
                fetched.append(contentsOf: try await loadPages(
                    conversationID: canonicalConversationID,
                    status: status
                ))
            }

            let fetchedIDs = Set(fetched.map { $0.id.lowercased() })
            var exact: [ScheduledPaymentDTO] = []
            for known in previous where !fetchedIDs.contains(known.id.lowercased()) {
                // A list page can be truncated, or a schedule can transition while the three
                // status pages are loading. Re-read every locally known omission exactly before
                // removing it from the chat.
                if let refreshed = try? await api.scheduledPayment(id: known.id) {
                    exact.append(refreshed)
                }
            }
            items = ChatScheduledPaymentCollectionPolicy.reconcile(
                previous: previous,
                fetched: fetched,
                exact: exact,
                conversationID: canonicalConversationID
            )
        } catch {
            // A transient refresh must never make an already-confirmed schedule disappear.
            items = previous
            errorMessage = Self.message(for: error)
        }
    }

    private func loadPages(
        conversationID: String,
        status: ScheduledPaymentStatus
    ) async throws -> [ScheduledPaymentDTO] {
        var result: [ScheduledPaymentDTO] = []
        var before: String?
        var seenCursors: Set<String> = []
        for _ in 0..<100 {
            let response = try await api.scheduledPayments(
                conversationID: conversationID,
                status: status,
                before: before,
                limit: 100
            )
            guard response.isStructurallyValid,
                  response.items.allSatisfy({
                      $0.conversationId?.caseInsensitiveCompare(conversationID) == .orderedSame
                          && $0.knownStatus == status
                  })
            else { throw ChatScheduledPaymentError.invalidResponse }
            result.append(contentsOf: response.items)
            guard response.hasMore, let cursor = response.nextBefore else { return result }
            guard seenCursors.insert(cursor).inserted else {
                throw ChatScheduledPaymentError.invalidResponse
            }
            before = cursor
        }
        throw ChatScheduledPaymentError.invalidResponse
    }

    func upsert(_ payment: ScheduledPaymentDTO, conversationID: String) {
        guard payment.isStructurallyValid,
              payment.conversationId?.caseInsensitiveCompare(conversationID) == .orderedSame
        else { return }
        if payment.knownStatus?.isTerminal == true {
            items.removeAll { $0.id.caseInsensitiveCompare(payment.id) == .orderedSame }
            return
        }
        if let index = items.firstIndex(where: {
            $0.id.caseInsensitiveCompare(payment.id) == .orderedSame
        }) {
            items[index] = payment
        } else {
            items.append(payment)
        }
        items.sort { ($0.scheduledDate ?? .distantFuture) < ($1.scheduledDate ?? .distantFuture) }
    }

    func cancel(_ payment: ScheduledPaymentDTO, conversationID: String, isOnline: Bool) async {
        guard isOnline, cancellingID == nil else {
            if !isOnline { errorMessage = "Connect to cancel this scheduled payment." }
            return
        }
        cancellingID = payment.id
        errorMessage = nil
        defer { cancellingID = nil }
        do {
            let latest = try await api.scheduledPayment(id: payment.id)
            guard latest.isStructurallyValid,
                  latest.conversationId?.caseInsensitiveCompare(conversationID) == .orderedSame,
                  latest.knownStatus == .scheduled
            else { throw ChatScheduledPaymentError.notCancellable }
            let cancelled = try await api.cancelScheduledPayment(
                id: latest.id,
                idempotencyKey: "ios-scheduled-payment-cancel-\(latest.id)"
            )
            guard cancelled.isStructurallyValid,
                  cancelled.id.caseInsensitiveCompare(latest.id) == .orderedSame,
                  cancelled.knownStatus == .cancelled
            else { throw ChatScheduledPaymentError.invalidResponse }
            items.removeAll { $0.id.caseInsensitiveCompare(latest.id) == .orderedSame }
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    private static func message(for error: Error) -> String {
        if let known = error as? ChatScheduledPaymentError {
            return known.errorDescription ?? "Kit Pay could not update this scheduled payment."
        }
        let raw = (error as? APIErrorPayload)?.message ?? error.localizedDescription
        return CustomerFacingPaymentCopy.neutralizedServiceMessage(raw)
    }
}

private enum ChatScheduledPaymentError: LocalizedError {
    case invalidResponse
    case invalidConversation
    case notCancellable

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Kit Pay could not verify the scheduled payment. Refresh and try again."
        case .invalidConversation:
            "This conversation is no longer available."
        case .notCancellable:
            "This payment has already started and can no longer be cancelled."
        }
    }
}

enum ChatScheduledPaymentCollectionPolicy {
    static func reconcile(
        previous: [ScheduledPaymentDTO],
        fetched: [ScheduledPaymentDTO],
        exact: [ScheduledPaymentDTO],
        conversationID: String
    ) -> [ScheduledPaymentDTO] {
        var byID: [String: ScheduledPaymentDTO] = [:]
        for candidate in previous + fetched + exact {
            guard candidate.isStructurallyValid,
                  candidate.conversationId?.caseInsensitiveCompare(conversationID) == .orderedSame
            else { continue }
            let id = candidate.id.lowercased()
            if candidate.knownStatus?.isTerminal == true {
                byID[id] = nil
            } else {
                byID[id] = candidate
            }
        }
        return byID.values.sorted {
            if $0.scheduledDate != $1.scheduledDate {
                return ($0.scheduledDate ?? .distantFuture) < ($1.scheduledDate ?? .distantFuture)
            }
            return $0.id < $1.id
        }
    }
}

struct ScheduledPaymentSection: View {
    let items: [ScheduledPaymentDTO]
    let recipientName: String
    let isOnline: Bool
    let cancellingID: String?
    let errorMessage: String?
    let onCancel: (ScheduledPaymentDTO) -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "building.columns.fill")
                Text(items.count == 1 ? "Scheduled payment" : "Scheduled payments · \(items.count)")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(KitColor.secondaryText)
            .frame(maxWidth: .infinity, alignment: .center)

            ForEach(items) { payment in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(statusTitle(payment), systemImage: statusSymbol(payment))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(KitColor.green)
                        Spacer()
                        if cancellingID == payment.id { ProgressView().controlSize(.small) }
                    }
                    Text(KitMoney.formatted(
                        payment.amount,
                        currency: payment.currency
                    ))
                    .font(.title3.bold())
                    Text("To \(recipientName) · \(scheduledLabel(payment))")
                        .font(.caption)
                        .foregroundStyle(KitColor.secondaryText)
                    if let note = payment.note, !note.isEmpty {
                        Text(note).font(.subheadline).foregroundStyle(KitColor.secondaryText)
                    }
                    Text("Kit will send this from the server even if this iPhone is offline.")
                        .font(.caption2)
                        .foregroundStyle(KitColor.secondaryText)
                }
                .padding(14)
                .frame(maxWidth: 300, alignment: .leading)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(KitColor.green.opacity(0.38), lineWidth: 1)
                }
                .contextMenu {
                    if payment.knownStatus == .scheduled {
                        Button(role: .destructive) { onCancel(payment) } label: {
                            Label("Cancel payment", systemImage: "xmark.circle")
                        }
                        .disabled(!isOnline || cancellingID != nil)
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: 300, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func statusTitle(_ payment: ScheduledPaymentDTO) -> String {
        switch payment.knownStatus {
        case .scheduled: "Scheduled"
        case .queued: "Queued securely"
        case .processing: "Sending"
        case .completed: "Completed"
        case .failed: "Not sent"
        case .cancelled: "Cancelled"
        case nil: "Scheduled payment"
        }
    }

    private func statusSymbol(_ payment: ScheduledPaymentDTO) -> String {
        switch payment.knownStatus {
        case .queued, .processing: "arrow.triangle.2.circlepath"
        default: "clock.badge.checkmark"
        }
    }

    private func scheduledLabel(_ payment: ScheduledPaymentDTO) -> String {
        guard let date = payment.scheduledDate else { return "scheduled" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
