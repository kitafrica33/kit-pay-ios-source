import SwiftUI

/// The only customer support surface: authenticated, inside the app, and gated on the exact
/// typed `protocols.support` contract (`SupportGate`), never on the feature flag alone. There is
/// deliberately no web form, email address, or phone number anywhere in this flow — when the
/// gate fails closed the screen says support is unavailable rather than pointing at an external
/// channel.
///
/// Presentation is a SINGLE modal route (`SupportRoute`): exactly one sheet can exist at a time,
/// and the composer→thread transition is staged across the dismissal callback, so two sheet
/// presenters can never race each other.
struct SupportView: View {
    @EnvironmentObject private var model: AppModel

    var preferredCategoryKeys: [String] = []

    @State private var flow: SupportFlowBinding?
    @State private var tickets: [SupportTicketDTO] = []
    /// Distinguishes an authoritative empty list from "not loaded yet".
    @State private var ticketsLoaded = false
    @State private var isLoadingTickets = false
    @State private var ticketsError: String?
    /// AUTHORITATIVE continuation from the last validated index page: older requests exist
    /// exactly when the server's meta said so, and are reached only through the cursor the
    /// server issued — completeness is never inferred from page fullness.
    @State private var ticketsNextCursor: String?
    @State private var ticketsHaveMore = false
    @State private var isLoadingMoreTickets = false
    @State private var categoriesState: SupportLoadState<[SupportCategoryDTO]> = .idle
    /// The single active sheet.
    @State private var route: SupportRoute?
    /// Composer→thread handoff, presented by `presentStagedThread()` only after the composer
    /// sheet has fully dismissed — deterministic sequencing through one presenter.
    @State private var pendingThreadTicket: SupportTicketDTO?

    private var gate: SupportGateState { SupportGate.state(for: model.capabilities) }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if gate.isAvailable {
                    newRequestCard
                    ticketsCard
                } else {
                    unavailableCard
                }
            }
            .padding(18)
        }
        .background(KitColor.canvas.ignoresSafeArea())
        .navigationTitle("Help & support")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard gate.isAvailable else { return }
            await load()
        }
        .refreshable {
            guard gate.isAvailable else { return }
            await load()
        }
        .sheet(item: $route, onDismiss: presentStagedThread) { route in
            switch route {
            case .composer:
                NewSupportTicketSheet(
                    seedCategories: categoriesState.loadedValue ?? [],
                    preferredCategoryKeys: preferredCategoryKeys
                ) { ticket in
                    // Deterministic upsert: an idempotent replay racing a list refresh replaces
                    // the existing row instead of duplicating it.
                    tickets = SupportTicketListPolicy.upsert(ticket, into: tickets)
                    ticketsLoaded = true
                    pendingThreadTicket = ticket
                }
                .environmentObject(model)
            case .thread(let ticket):
                SupportTicketThreadSheet(ticket: ticket) { updated in
                    tickets = SupportTicketListPolicy.upsert(updated, into: tickets)
                }
                .environmentObject(model)
            }
        }
    }

    private func presentStagedThread() {
        guard let staged = pendingThreadTicket else { return }
        pendingThreadTicket = nil
        route = .thread(staged)
    }

    private var unavailableCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(KitColor.secondaryText)
                .frame(width: 68, height: 68)
                .background(.ultraThinMaterial, in: Circle())

            Text("Support isn't available yet")
                .font(.title3.bold())
                .foregroundStyle(KitColor.primaryText)

            Text(
                "Kit Pay support opens inside the app once it is enabled for your account. "
                    + "Check back after your next update."
            )
            .font(.subheadline)
            .foregroundStyle(KitColor.secondaryText)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(22)
        .kitGlass(cornerRadius: 28)
    }

    private var newRequestCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Message Kit Pay support", systemImage: "bubble.left.and.text.bubble.right")
                .font(.headline)
                .foregroundStyle(KitColor.primaryText)

            Text(supportPrivacyText)
                .font(.caption)
                .foregroundStyle(KitColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                route = .composer
            } label: {
                Label("New support request", systemImage: "plus.bubble")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 17))
            .tint(KitColor.navy)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .kitGlass(cornerRadius: 28)
    }

    /// Accurate processing disclosure: staff readability always; automated (AI) processing —
    /// including that a redacted copy may go to an approved AI provider — is stated exactly when
    /// the validated gate advertises it.
    private var supportPrivacyText: String {
        var text = "Start a request and Kit Pay support replies here, in the app. "
            + "Support conversations are readable by Kit Pay staff so they can help you; "
            + "they are not end-to-end encrypted."
        if gate.aiProcessingEnabled {
            text += " A redacted copy of your support messages may be sent to an approved AI "
                + "provider to prepare a first reply."
        }
        return text
    }

    private var ticketsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Your requests", systemImage: "tray.full")
                .font(.headline)
                .foregroundStyle(KitColor.primaryText)

            if let ticketsError {
                Label(ticketsError, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") {
                    Task { await load() }
                }
                .font(.footnote.weight(.semibold))
                .disabled(isLoadingTickets)
            }

            if isLoadingTickets && !ticketsLoaded {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Loading your support requests…")
                        .foregroundStyle(KitColor.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            } else if ticketsLoaded && tickets.isEmpty {
                Text("No support requests yet.")
                    .font(.subheadline)
                    .foregroundStyle(KitColor.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else if !tickets.isEmpty {
                VStack(spacing: 0) {
                    ForEach(tickets) { ticket in
                        Button {
                            route = .thread(ticket)
                        } label: {
                            ticketRow(ticket)
                        }
                        .buttonStyle(.plain)
                        if ticket.id != tickets.last?.id {
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                if ticketsHaveMore {
                    loadMoreControl
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .kitGlass(cornerRadius: 28)
    }

    /// Explicit continuation for older requests, shown exactly when the server's validated page
    /// meta said more exist. History is durable and reachable — never silently omitted.
    private var loadMoreControl: some View {
        Button {
            Task { await loadMoreTickets() }
        } label: {
            HStack(spacing: 8) {
                if isLoadingMoreTickets {
                    ProgressView()
                } else {
                    Label("Show older requests", systemImage: "clock.arrow.circlepath")
                }
            }
            .font(.footnote.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 12))
        .tint(KitColor.navy)
        .disabled(isLoadingTickets || isLoadingMoreTickets)
        .padding(.top, 6)
    }

    private func ticketRow(_ ticket: SupportTicketDTO) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(ticket.subject)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KitColor.primaryText)
                    .lineLimit(2)
                Text("\(ticket.category.name) · \(ticket.reference)")
                    .font(.caption)
                    .foregroundStyle(KitColor.secondaryText)
                    .lineLimit(1)
                if let updated = SupportRelativeTime.text(
                    from: ticket.lastMessageAt ?? ticket.createdAt
                ) {
                    Text(updated)
                        .font(.caption2)
                        .foregroundStyle(KitColor.secondaryText)
                }
            }
            Spacer()
            SupportStatusChip(ticket: ticket)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
    }

    /// On account replacement every piece of old-account state is purged and any presented sheet
    /// dismissed (route reset); the next load rebinds and loads under the new account. Persisted
    /// drafts stay under the original account's protected storage, untouched.
    @MainActor
    private func purgeStaleAccountState() {
        flow = nil
        tickets = []
        ticketsLoaded = false
        ticketsError = nil
        ticketsNextCursor = nil
        ticketsHaveMore = false
        categoriesState = .idle
        pendingThreadTicket = nil
        route = nil
    }

    /// Tickets and categories load and apply INDEPENDENTLY: either failing cannot discard the
    /// other's valid result.
    @MainActor
    private func load() async {
        if let flow, await SupportSessionScope.isCurrent(flow) == false {
            purgeStaleAccountState()
        }
        if flow == nil {
            do {
                flow = try await SupportSessionScope.captureFlow()
            } catch {
                ticketsError = SupportErrorText.describe(error)
                return
            }
        }
        await loadTickets()
        await loadCategories()
    }

    /// Loads the FIRST index page, replacing the list; the validated continuation from the
    /// response meta decides whether an explicit "older requests" control appears.
    @MainActor
    private func loadTickets() async {
        guard gate.isAvailable, let flow, !isLoadingTickets, !isLoadingMoreTickets else { return }
        isLoadingTickets = true
        defer { isLoadingTickets = false }
        do {
            let page = try await APIClientSessionBinding.$sessionID.withValue(flow.sessionID) {
                try await APIClient.shared.supportTickets()
            }
            try Task.checkCancellation()
            try SupportThreadPageValidator.validateTicketPage(
                page.items,
                requestedLimit: SupportContract.ticketsPageLimit,
                existingIDs: []
            )
            guard await SupportSessionScope.isCurrent(flow) else {
                purgeStaleAccountState()
                return
            }
            guard gate.isAvailable else { return }
            tickets = page.items
            ticketsLoaded = true
            ticketsNextCursor = page.nextCursor
            ticketsHaveMore = page.hasMore
            ticketsError = nil
        } catch is CancellationError {
            return
        } catch {
            // Stale results or errors from a superseded account must not touch this UI; a real
            // failure preserves the last known-good list and surfaces a safe error.
            guard await SupportSessionScope.isCurrent(flow) else {
                purgeStaleAccountState()
                return
            }
            ticketsError = SupportErrorText.describe(error)
        }
    }

    /// Appends the next validated index page through the cursor the server issued. Rows are
    /// cross-checked against every already-applied identifier, so a shifting window can never
    /// duplicate a ticket; a rejected page preserves the applied list and its continuation.
    @MainActor
    private func loadMoreTickets() async {
        guard gate.isAvailable, let flow, ticketsHaveMore, let cursor = ticketsNextCursor,
              !isLoadingTickets, !isLoadingMoreTickets
        else { return }
        isLoadingMoreTickets = true
        defer { isLoadingMoreTickets = false }
        do {
            let page = try await APIClientSessionBinding.$sessionID.withValue(flow.sessionID) {
                try await APIClient.shared.supportTickets(cursor: cursor)
            }
            try Task.checkCancellation()
            try SupportThreadPageValidator.validateTicketPage(
                page.items,
                requestedLimit: SupportContract.ticketsPageLimit,
                existingIDs: Set(tickets.map(\.id))
            )
            guard await SupportSessionScope.isCurrent(flow) else {
                purgeStaleAccountState()
                return
            }
            guard gate.isAvailable else { return }
            tickets.append(contentsOf: page.items)
            ticketsNextCursor = page.nextCursor
            ticketsHaveMore = page.hasMore
            ticketsError = nil
        } catch is CancellationError {
            return
        } catch {
            guard await SupportSessionScope.isCurrent(flow) else {
                purgeStaleAccountState()
                return
            }
            ticketsError = SupportErrorText.describe(error)
        }
    }

    @MainActor
    private func loadCategories() async {
        guard gate.isAvailable, let flow, !categoriesState.isLoading else { return }
        let previous = categoriesState
        categoriesState = .loading
        do {
            let items = try await APIClientSessionBinding.$sessionID.withValue(flow.sessionID) {
                try await APIClient.shared.supportCategories()
            }
            try Task.checkCancellation()
            try SupportThreadPageValidator.validateCategories(items)
            guard await SupportSessionScope.isCurrent(flow) else {
                purgeStaleAccountState()
                return
            }
            guard gate.isAvailable else {
                categoriesState = previous
                return
            }
            categoriesState = .loaded(items)
        } catch is CancellationError {
            categoriesState = previous
            return
        } catch {
            guard await SupportSessionScope.isCurrent(flow) else {
                purgeStaleAccountState()
                return
            }
            categoriesState = .failed(SupportErrorText.describe(error))
        }
    }
}

/// The single support modal. Exactly one case is ever presented at a time.
private enum SupportRoute: Identifiable {
    case composer
    case thread(SupportTicketDTO)

    var id: String {
        switch self {
        case .composer: "composer"
        case .thread(let ticket): "thread-\(ticket.id)"
        }
    }
}

/// Wrapper for presenting support as a sheet from screens that are not inside a
/// `NavigationStack` (for example the account-deletion flow).
struct SupportSheetView: View {
    @Environment(\.dismiss) private var dismiss

    var preferredCategoryKeys: [String] = []

    var body: some View {
        NavigationStack {
            SupportView(preferredCategoryKeys: preferredCategoryKeys)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

private struct SupportStatusChip: View {
    let ticket: SupportTicketDTO

    var body: some View {
        Text(ticket.isOpen ? "Open" : "Closed")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                (ticket.isOpen ? KitColor.green : Color.secondary).opacity(0.16),
                in: Capsule()
            )
            .foregroundStyle(ticket.isOpen ? KitColor.green : KitColor.secondaryText)
    }
}

/// New-request composer with a durable idempotency envelope.
///
/// Lifecycle phases, in order:
/// 1. RESTORATION (fields disabled, autosave suppressed): bind the account flow, then load and
///    atomically apply the persisted draft — subject, message, category, AND its idempotency
///    UUID — before any edit, autosave, or network call is possible. Unreadable protected state
///    blocks the composer behind an explicit retry instead of minting fresh idempotency
///    authority over an unknown prior submission.
/// 2. COMPOSING: edits autosave (verified writes) under the bound account.
/// 3. FROZEN (`pendingEnvelope != nil`): the exact normalized attempt + UUID is persisted with
///    `phase == .pendingReplay` BEFORE the POST. While frozen, edits and autosaves are
///    suppressed; retry replays the envelope verbatim. Only a DEFINITIVE server rejection
///    (`SupportContract.isDefinitiveRejection`) demotes it back to an editable draft (fresh
///    UUID); every ambiguous outcome keeps it frozen.
/// 4. ACCEPTED (authoritative validation passed): the envelope must be VERIFIABLY cleared
///    before the UUID rotates, the callback fires, or the sheet dismisses. A failed clear
///    enters blocked-cleanup: no rotation, no dismissal, no edits — only a cleanup retry —
///    so a surviving stale envelope can never be resurrected or reused with different content.
private struct NewSupportTicketSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    /// Stale-tolerant seed from the parent, used only while this sheet's own authoritative load
    /// is idle, loading, or failed. The sheet ALWAYS refreshes categories on open.
    let seedCategories: [SupportCategoryDTO]
    let preferredCategoryKeys: [String]
    let onCreated: (SupportTicketDTO) -> Void

    @State private var flow: SupportFlowBinding?
    @State private var categoriesState: SupportLoadState<[SupportCategoryDTO]> = .idle
    @State private var selectedCategoryKey: String?
    @State private var subject = ""
    @State private var message = ""
    @State private var isSubmitting = false
    @State private var submissionError: String?
    @State private var draftStorageError: String?
    /// True once restoration finished successfully; edits/autosave/network are gated on it.
    @State private var composerReady = false
    /// Restoration failed (unreadable protected state or no session): fields stay disabled and
    /// a retry re-runs restoration. Never overwrites unknown idempotency authority.
    @State private var restoreBlocked = false
    /// The frozen POST attempt (phase `.pendingReplay`), exactly as persisted.
    @State private var pendingEnvelope: SupportComposerDraft?
    /// Authoritatively accepted, but the envelope could not be verifiably cleared yet.
    @State private var cleanupBlocked = false
    @State private var acceptedTicket: SupportTicketDTO?
    /// Stable across retries of the same submission so the server replays instead of
    /// duplicating; persisted with the draft and rotated only after an accepted attempt's
    /// envelope is verifiably cleared (or a definitive rejection demotes it).
    @State private var clientMessageID = UUID()

    private var gate: SupportGateState { SupportGate.state(for: model.capabilities) }

    /// Authoritative once loaded — including an authoritative EMPTY list, which disables
    /// submission instead of falling back to a stale seed.
    private var availableCategories: [SupportCategoryDTO] {
        categoriesState.loadedValue ?? seedCategories
    }

    private var categoriesAuthoritativelyEmpty: Bool {
        categoriesState.loadedValue?.isEmpty == true
    }

    private var inputsFrozen: Bool {
        !composerReady || restoreBlocked || pendingEnvelope != nil || cleanupBlocked
            || isSubmitting
    }

    private var canSubmit: Bool {
        guard gate.isAvailable,
              model.appReviewDemoMutationsAllowed,
              flow != nil,
              composerReady,
              !restoreBlocked,
              !cleanupBlocked,
              draftStorageError == nil,
              !isSubmitting
        else { return false }
        if pendingEnvelope != nil { return true }
        return selectedCategoryKey.map { key in
            availableCategories.contains { $0.key == key }
        } == true
            && SupportContract.normalizedSubject(subject) != nil
            && SupportContract.normalizedMessageBody(message) != nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("What do you need help with?")
                        .font(.headline)
                        .foregroundStyle(KitColor.primaryText)

                    categoryPicker

                    TextField("Subject", text: $subject)
                        .autocorrectionDisabled(false)
                        .submitLabel(.next)
                        .disabled(inputsFrozen)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 50)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .accessibilityLabel("Support request subject")

                    TextField("Describe the problem…", text: $message, axis: .vertical)
                        .lineLimit(5 ... 12)
                        .disabled(inputsFrozen)
                        .padding(14)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .accessibilityLabel("Support request message")

                    Text(privacyText)
                        .font(.caption)
                        .foregroundStyle(KitColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    if !gate.isAvailable {
                        Label(
                            "Kit Pay support is not available right now. Your draft is kept on "
                                + "this screen so you can send it when support returns.",
                            systemImage: "exclamationmark.circle"
                        )
                        .font(.footnote)
                        .foregroundStyle(KitColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    if pendingEnvelope != nil, !cleanupBlocked {
                        Label(
                            "This request was sent but not confirmed. It's kept safely on this "
                                + "screen — retrying sends exactly the same request and won't "
                                + "create a duplicate.",
                            systemImage: "clock.badge.exclamationmark"
                        )
                        .font(.footnote)
                        .foregroundStyle(KitColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    if let draftStorageError {
                        Label(draftStorageError, systemImage: "lock.trianglebadge.exclamationmark")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                        if restoreBlocked {
                            Button("Try again") {
                                Task { await bindAndRestore() }
                            }
                            .font(.footnote.weight(.semibold))
                        }
                    }

                    if let submissionError {
                        Label(submissionError, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if cleanupBlocked {
                        cleanupBlockedCard
                    } else {
                        Button {
                            Task { await submit() }
                        } label: {
                            HStack(spacing: 10) {
                                if isSubmitting { ProgressView().tint(.white) }
                                Text(submitButtonTitle)
                                    .font(.headline)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 52)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.roundedRectangle(radius: 18))
                        .tint(KitColor.navy)
                        .disabled(!canSubmit)
                    }
                }
                .padding(18)
            }
            .background(KitColor.canvas.ignoresSafeArea())
            .navigationTitle("New request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSubmitting || cleanupBlocked)
                }
            }
            .interactiveDismissDisabled(isSubmitting || cleanupBlocked)
            .task {
                await bindAndRestore()
                await loadCategories()
                preselectCategory()
            }
            .onChange(of: subject) { _, value in
                if value.count > SupportContract.subjectMaximumLength {
                    subject = String(value.prefix(SupportContract.subjectMaximumLength))
                    return
                }
                autosaveDraft()
            }
            .onChange(of: message) { _, value in
                if value.count > SupportContract.messageMaximumLength {
                    message = String(value.prefix(SupportContract.messageMaximumLength))
                    return
                }
                autosaveDraft()
            }
            .onChange(of: selectedCategoryKey) { _, _ in autosaveDraft() }
        }
    }

    private var submitButtonTitle: String {
        if isSubmitting { return "Sending…" }
        if pendingEnvelope != nil { return "Retry send" }
        return "Send to Kit Support"
    }

    /// Delivered, but the envelope's verified removal failed: the only way forward is finishing
    /// the cleanup — no rotation, no dismissal, no edits — so the accepted envelope can never be
    /// overwritten or reused. (If the app exits here, the persisted envelope replays
    /// idempotently on next open and converges back to this same verified clear.)
    private var cleanupBlockedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                "Your request was delivered. Finish the secure cleanup of its saved copy on "
                    + "this device to continue.",
                systemImage: "checkmark.circle.trianglebadge.exclamationmark"
            )
            .font(.footnote)
            .foregroundStyle(KitColor.primaryText)
            .fixedSize(horizontal: false, vertical: true)

            Button {
                Task { await retryAcceptedCleanup() }
            } label: {
                Text("Finish cleanup")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 17))
            .tint(KitColor.navy)
        }
    }

    /// Accurate pre-submit disclosure: staff readability always; automated (AI) processing —
    /// including that a redacted copy may go to an approved AI provider — is stated exactly when
    /// the validated gate advertises it.
    private var privacyText: String {
        var text = "Kit Pay staff can read support messages to help you."
        if gate.aiProcessingEnabled {
            text += " A redacted copy of your support messages may be sent to an approved AI "
                + "provider to prepare a first reply."
        }
        text += " Never share your wallet PIN or a one-time code — Kit Support will not ask "
            + "for them."
        return text
    }

    /// Distinct idle / loading / loaded-empty / failed presentations: a failure is retryable
    /// instead of an indefinite spinner, and an authoritative empty list says so.
    @ViewBuilder
    private var categoryPicker: some View {
        if let failure = categoriesState.failureMessage, availableCategories.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry loading categories") {
                    Task { await loadCategories() }
                }
                .font(.footnote.weight(.semibold))
            }
        } else if categoriesAuthoritativelyEmpty {
            Label(
                "No support categories are available right now. Try again later; your draft "
                    + "stays on this screen.",
                systemImage: "tray"
            )
            .font(.footnote)
            .foregroundStyle(KitColor.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        } else if availableCategories.isEmpty {
            HStack(spacing: 10) {
                ProgressView()
                Text("Loading categories…")
                    .font(.subheadline)
                    .foregroundStyle(KitColor.secondaryText)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Category")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KitColor.secondaryText)
                Picker("Category", selection: $selectedCategoryKey) {
                    Text("Choose a category").tag(String?.none)
                    ForEach(availableCategories) { category in
                        Text(category.name).tag(String?.some(category.key))
                    }
                }
                .pickerStyle(.menu)
                .disabled(inputsFrozen)
                if let failure = categoriesState.failureMessage {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Retry loading categories") {
                        Task { await loadCategories() }
                    }
                    .font(.caption.weight(.semibold))
                }
            }
        }
    }

    private func preselectCategory() {
        guard composerReady, pendingEnvelope == nil, selectedCategoryKey == nil else { return }
        selectedCategoryKey = SupportContract.preferredCategory(
            in: availableCategories,
            hints: preferredCategoryKeys
        )?.key
    }

    /// RESTORATION phase: binds this sheet to the account it opened under and atomically applies
    /// that account's persisted draft — subject, message, category, AND idempotency UUID — while
    /// every edit path is still disabled, so a partially restored field set can never autosave
    /// under a fresh UUID. A restored `.pendingReplay` record freezes the composer for verbatim
    /// replay. Unreadable protected state blocks the composer behind an explicit retry — a fresh
    /// UUID over an unknown prior submission could duplicate a ticket.
    @MainActor
    private func bindAndRestore() async {
        guard !composerReady else { return }
        restoreBlocked = false
        if flow == nil {
            do {
                flow = try await SupportSessionScope.captureFlow()
            } catch {
                draftStorageError = SupportErrorText.describe(error)
                restoreBlocked = true
                return
            }
        }
        guard let flow else { return }
        do {
            if let draft = try SupportDraftStore.shared.load(
                accountID: flow.accountID,
                thread: SupportDraftStore.newTicketThreadKey
            ) {
                guard let restoredID = UUID(uuidString: draft.clientMessageID) else {
                    // `isValid` guarantees a canonical UUID; anything else is corruption.
                    throw SupportDraftStoreError.unreadable
                }
                subject = draft.subject ?? ""
                message = draft.message
                selectedCategoryKey = draft.categoryKey
                clientMessageID = restoredID
                if draft.phase == .pendingReplay {
                    pendingEnvelope = draft
                }
            }
            draftStorageError = nil
            composerReady = true
        } catch {
            draftStorageError = SupportErrorText.describe(error)
            restoreBlocked = true
        }
    }

    private var draftIsEmpty: Bool {
        subject.isEmpty && message.isEmpty && selectedCategoryKey == nil
    }

    /// Autosave runs ONLY while the composer is interactive: never before restoration completes
    /// (a half-restored field set must not overwrite the stored record), never while a frozen
    /// pending-replay envelope or a blocked cleanup owns the record, and never mid-submit.
    private func autosaveDraft() {
        guard composerReady, !restoreBlocked, pendingEnvelope == nil, !cleanupBlocked,
              !isSubmitting, let flow
        else { return }
        if draftIsEmpty {
            // A failed verified clear is surfaced, never swallowed: stale content may still be
            // durably stored and could resurrect into a later composer session.
            do {
                try SupportDraftStore.shared.clear(
                    accountID: flow.accountID,
                    thread: SupportDraftStore.newTicketThreadKey
                )
                draftStorageError = nil
            } catch {
                draftStorageError = SupportErrorText.describe(error)
            }
            return
        }
        do {
            try persistDraft(flow: flow)
            draftStorageError = nil
        } catch {
            draftStorageError = SupportErrorText.describe(error)
        }
    }

    private func persistDraft(flow: SupportFlowBinding) throws {
        try SupportDraftStore.shared.save(
            SupportComposerDraft(
                accountID: flow.accountID,
                thread: SupportDraftStore.newTicketThreadKey,
                phase: .draft,
                categoryKey: selectedCategoryKey,
                subject: subject,
                message: message,
                clientMessageID: clientMessageID.uuidString.lowercased()
            )
        )
    }

    /// Account replacement: this sheet belongs to the previous account, so its in-memory state
    /// is purged and the sheet dismissed. The persisted draft/envelope stays under the ORIGINAL
    /// account's protected storage, untouched. `composerReady` drops first so the field resets
    /// cannot trigger an autosave.
    @MainActor
    private func purgeStaleComposerState() {
        composerReady = false
        pendingEnvelope = nil
        acceptedTicket = nil
        cleanupBlocked = false
        subject = ""
        message = ""
        selectedCategoryKey = nil
        submissionError = nil
        draftStorageError = nil
        dismiss()
    }

    @MainActor
    private func submit() async {
        guard canSubmit, let flow else { return }
        guard await SupportSessionScope.isCurrent(flow) else {
            purgeStaleComposerState()
            return
        }
        let envelope: SupportComposerDraft
        if let pendingEnvelope {
            // Verbatim replay of the frozen attempt: same content, same idempotency key.
            envelope = pendingEnvelope
        } else {
            guard let selectedCategoryKey,
                  let attemptSubject = SupportContract.normalizedSubject(subject),
                  let attemptBody = SupportContract.normalizedMessageBody(message)
            else { return }
            let candidate = SupportComposerDraft(
                accountID: flow.accountID,
                thread: SupportDraftStore.newTicketThreadKey,
                phase: .pendingReplay,
                categoryKey: selectedCategoryKey,
                subject: attemptSubject,
                message: attemptBody,
                clientMessageID: clientMessageID.uuidString.lowercased()
            )
            // FREEZE before the network call: the exact normalized attempt + UUID must be
            // durably persisted (verified write) so an ambiguous outcome can always be replayed
            // verbatim. No proof, no POST.
            do {
                try SupportDraftStore.shared.save(candidate)
                draftStorageError = nil
            } catch {
                draftStorageError = SupportErrorText.describe(error)
                return
            }
            pendingEnvelope = candidate
            envelope = candidate
            subject = attemptSubject
            message = attemptBody
        }
        guard let attemptedCategoryKey = envelope.categoryKey,
              let attemptedSubject = envelope.subject,
              let attemptID = UUID(uuidString: envelope.clientMessageID)
        else {
            // A pending-replay envelope always carries these (`isValid`); anything else is
            // corruption and must not reach the network.
            draftStorageError = SupportErrorText.describe(SupportDraftStoreError.unreadable)
            return
        }
        isSubmitting = true
        submissionError = nil
        defer { isSubmitting = false }
        do {
            let ticket = try await APIClientSessionBinding.$sessionID.withValue(flow.sessionID) {
                try await APIClient.shared.openSupportTicket(
                    categoryKey: attemptedCategoryKey,
                    subject: attemptedSubject,
                    message: envelope.message,
                    clientMessageID: attemptID
                )
            }
            try Task.checkCancellation()
            // Authoritative-success pinning: the response must provably describe THIS attempt
            // (exact subject, exact category, the submitted message counted). A malformed or
            // unrelated replay response throws and the envelope stays frozen.
            try SupportThreadPageValidator.validateCreatedTicketAuthoritative(
                ticket,
                attemptedSubject: attemptedSubject,
                attemptedCategoryKey: attemptedCategoryKey
            )
            guard await SupportSessionScope.isCurrent(flow) else {
                purgeStaleComposerState()
                return
            }
            guard gate.isAvailable else { return }
            finalizeAcceptedSubmission(ticket, flow: flow)
        } catch is CancellationError {
            return
        } catch {
            guard await SupportSessionScope.isCurrent(flow) else {
                purgeStaleComposerState()
                return
            }
            if SupportContract.isDefinitiveRejection(error) {
                demoteRejectedEnvelope(flow: flow)
                submissionError = SupportErrorText.describe(error)
            } else {
                // Ambiguous outcome: the frozen envelope (already persisted) is the recovery
                // path — replaying it cannot create a duplicate.
                submissionError = SupportErrorText.describe(
                    SupportContractError.deliveryUnconfirmed
                )
            }
        }
    }

    /// Runs ONLY after authoritative validation. The success transition is gated on a VERIFIED
    /// removal of the accepted envelope: if the protected record cannot provably be cleared,
    /// the sheet enters blocked-cleanup — no key rotation, no dismissal, no callback, no edits —
    /// so a surviving stale envelope can never be resurrected or reused with different content.
    @MainActor
    private func finalizeAcceptedSubmission(_ ticket: SupportTicketDTO, flow: SupportFlowBinding) {
        do {
            try SupportDraftStore.shared.clear(
                accountID: flow.accountID,
                thread: SupportDraftStore.newTicketThreadKey
            )
        } catch {
            acceptedTicket = ticket
            cleanupBlocked = true
            draftStorageError = SupportErrorText.describe(error)
            return
        }
        completeAcceptedSubmission(ticket)
    }

    @MainActor
    private func completeAcceptedSubmission(_ ticket: SupportTicketDTO) {
        pendingEnvelope = nil
        acceptedTicket = nil
        cleanupBlocked = false
        draftStorageError = nil
        submissionError = nil
        clientMessageID = UUID()
        onCreated(ticket)
        dismiss()
    }

    @MainActor
    private func retryAcceptedCleanup() async {
        guard cleanupBlocked, let acceptedTicket, let flow, !isSubmitting else { return }
        guard await SupportSessionScope.isCurrent(flow) else {
            purgeStaleComposerState()
            return
        }
        do {
            try SupportDraftStore.shared.clear(
                accountID: flow.accountID,
                thread: SupportDraftStore.newTicketThreadKey
            )
        } catch {
            draftStorageError = SupportErrorText.describe(error)
            return
        }
        completeAcceptedSubmission(acceptedTicket)
    }

    /// A definitive rejection releases the frozen envelope: the server provably recorded nothing
    /// for this content under this key, so the attempt demotes to an editable draft under a
    /// FRESH key (replaying the old key could only ever collide with different content). If the
    /// demotion write fails, editing resumes but submission stays blocked until a later verified
    /// save; a crash before one restores the stale frozen envelope, whose verbatim replay
    /// converges to the same definitive verdict.
    @MainActor
    private func demoteRejectedEnvelope(flow: SupportFlowBinding) {
        guard pendingEnvelope != nil else { return }
        let rotated = UUID()
        let demoted = SupportComposerDraft(
            accountID: flow.accountID,
            thread: SupportDraftStore.newTicketThreadKey,
            phase: .draft,
            categoryKey: selectedCategoryKey,
            subject: subject,
            message: message,
            clientMessageID: rotated.uuidString.lowercased()
        )
        pendingEnvelope = nil
        clientMessageID = rotated
        do {
            try SupportDraftStore.shared.save(demoted)
            draftStorageError = nil
        } catch {
            draftStorageError = SupportErrorText.describe(error)
        }
    }

    @MainActor
    private func loadCategories() async {
        guard gate.isAvailable, let flow, !categoriesState.isLoading else { return }
        let previous = categoriesState
        categoriesState = .loading
        do {
            let items = try await APIClientSessionBinding.$sessionID.withValue(flow.sessionID) {
                try await APIClient.shared.supportCategories()
            }
            try Task.checkCancellation()
            try SupportThreadPageValidator.validateCategories(items)
            guard await SupportSessionScope.isCurrent(flow) else {
                purgeStaleComposerState()
                return
            }
            guard gate.isAvailable else {
                categoriesState = previous
                return
            }
            categoriesState = .loaded(items)
            // Reconcile a stale selection against the authoritative list — but never while a
            // frozen envelope owns the selected category (its replay identity is fixed).
            if pendingEnvelope == nil,
               let selectedCategoryKey,
               !items.contains(where: { $0.key == selectedCategoryKey }) {
                self.selectedCategoryKey = nil
            }
        } catch is CancellationError {
            categoriesState = previous
            return
        } catch {
            guard await SupportSessionScope.isCurrent(flow) else {
                purgeStaleComposerState()
                return
            }
            categoriesState = .failed(SupportErrorText.describe(error))
        }
    }
}

/// One ticket's message thread with a durable composer envelope (same four-phase lifecycle as
/// the new-request composer: restoration → composing → frozen pending-replay → verified-clear
/// success, with blocked-cleanup on a failed verified clear).
///
/// Concurrency model: every thread operation (initial load, window advance, send, close,
/// escalate) is SINGLE-FLIGHT behind one composite `busy` flag, and every state application —
/// success or error — is fenced by the captured account binding, the live gate, and
/// `threadGeneration`, which bumps on every thread-state write; an account replacement purges
/// all thread state and dismisses the sheet.
private struct SupportTicketThreadSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var ticket: SupportTicketDTO
    let onTicketUpdated: (SupportTicketDTO) -> Void

    @State private var flow: SupportFlowBinding?
    @State private var messages: [SupportMessageDTO] = []
    /// Newer messages exist beyond the loaded window. Always surfaced explicitly (banner +
    /// load-more control) — history is never silently omitted.
    @State private var hasMoreForward = false
    /// Bumped on EVERY thread-state write (messages, ticket) and on stale-state purges; every
    /// async application re-checks it so an older completion can never overwrite newer state.
    @State private var threadGeneration = 0
    @State private var isLoading = false
    @State private var isRefreshing = false
    @State private var isSending = false
    @State private var isUpdatingTicket = false
    @State private var consecutivePollFailures = 0
    @State private var threadError: String?
    @State private var composerText = ""
    @State private var closePrompt: SupportClosePrompt?
    @State private var draftStorageError: String?
    @State private var composerReady = false
    @State private var restoreBlocked = false
    @State private var pendingEnvelope: SupportComposerDraft?
    @State private var cleanupBlocked = false
    @State private var clientMessageID = UUID()
    /// The ticket's frozen payment attempt, if any — restored alongside the draft and updated
    /// only by the payment sheet's verified store transitions.
    @State private var pendingPayment: SupportPaymentEnvelope?
    /// A stored payment record exists but can't be read. Never blocks the thread; it surfaces a
    /// retryable notice and informs the close prompt.
    @State private var paymentStoreBlocked = false
    @State private var paymentSheet: SupportPaymentSheetPresentation?
    @State private var showMoneyIdentityVerification = false

    init(ticket: SupportTicketDTO, onTicketUpdated: @escaping (SupportTicketDTO) -> Void) {
        _ticket = State(initialValue: ticket)
        self.onTicketUpdated = onTicketUpdated
    }

    private var gate: SupportGateState { SupportGate.state(for: model.capabilities) }

    private var paymentsGate: SupportPaymentsGateState {
        SupportGate.paymentsState(for: model.capabilities)
    }

    /// The one flag that serializes every thread operation: nothing starts while anything else
    /// is in flight, so two operations can never interleave their reads and writes.
    private var busy: Bool { isLoading || isRefreshing || isSending || isUpdatingTicket }

    /// The sheet cannot be dismissed while a mutation is in flight (an in-flight failure could
    /// never report back) or while an accepted envelope awaits its verified cleanup.
    private var dismissLocked: Bool { isSending || isUpdatingTicket || cleanupBlocked }

    private var supportIdentityVerified: Bool {
        ticket.supportIdentity.isVerifiedOfficialSupport
    }

    /// Canonical draft namespace for this thread; nil fails closed (no draft persistence, no
    /// sending) rather than deriving a key from an unvalidated identifier.
    private var threadDraftKey: String? {
        SupportContract.canonicalTicketID(ticket.id)
    }

    private var composerFrozen: Bool {
        !composerReady || restoreBlocked || pendingEnvelope != nil || cleanupBlocked || isSending
    }

    private var canSend: Bool {
        guard gate.isAvailable,
              model.appReviewDemoMutationsAllowed,
              flow != nil,
              composerReady,
              !restoreBlocked,
              !cleanupBlocked,
              draftStorageError == nil,
              ticket.isOpen,
              threadDraftKey != nil,
              !busy
        else { return false }
        if pendingEnvelope != nil { return true }
        return SupportContract.normalizedMessageBody(composerText) != nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        // Lazy so a long thread renders incrementally instead of materializing
                        // every bubble at once.
                        LazyVStack(spacing: 12) {
                            readabilityNotice
                            if ticket.isOpen, ticket.assistantActive {
                                assistantHandoffNotice
                            }
                            if isLoading && messages.isEmpty {
                                ProgressView().padding(.vertical, 24)
                            }
                            ForEach(messages) { message in
                                SupportMessageBubble(message: message)
                                    .id(message.id)
                            }
                            if hasMoreForward {
                                loadMoreRow
                            }
                            if let threadError {
                                Label(threadError, systemImage: "exclamationmark.triangle.fill")
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if !ticket.isOpen {
                                closedNotice
                            }
                        }
                        .padding(16)
                    }
                    .onChange(of: messages.last?.id) { _, id in
                        guard let id else { return }
                        withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
                composerNotices
                if ticket.isOpen {
                    if !gate.isAvailable {
                        unavailableNotice
                    }
                    composerBar
                }
            }
            .background(KitColor.canvas.ignoresSafeArea())
            .navigationTitle(ticket.reference)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .disabled(dismissLocked)
                }
                if ticket.isOpen {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            if ticket.assistantActive {
                                Button {
                                    Task { await escalate() }
                                } label: {
                                    Label("Talk to a person", systemImage: "person.wave.2")
                                }
                            }
                            // Customer-INITIATED payment to the company beneficiary; appears
                            // only under the full payments advertisement, and never while an
                            // unresolved attempt exists (the pending notice owns that path).
                            if paymentsGate.isAvailable,
                               pendingPayment == nil,
                               !paymentStoreBlocked,
                               (flow != nil
                                   || model.moneyActionAccessRequirement == .verifyIdentity),
                               threadDraftKey != nil {
                                Button {
                                    openSupportPayment(nil)
                                } label: {
                                    Label("Send money to Kit Pay", systemImage: "banknote")
                                }
                            }
                            Button(role: .destructive) {
                                // The close policy decides which prompt appears: unresolved
                                // envelopes, storage failures, and unsent text each get their
                                // explicit resolution path before any close can run.
                                closePrompt = closePromptForCurrentState()
                            } label: {
                                Label("Close request", systemImage: "checkmark.circle")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .disabled(
                            busy
                                || cleanupBlocked
                                || !gate.isAvailable
                                || !model.appReviewDemoMutationsAllowed
                        )
                    }
                }
            }
            .interactiveDismissDisabled(dismissLocked)
            .confirmationDialog(
                closeDialogTitle,
                isPresented: Binding(
                    get: { closePrompt != nil },
                    set: { presented in if !presented { closePrompt = nil } }
                ),
                titleVisibility: .visible
            ) {
                closeDialogButtons
            } message: {
                Text(closeDialogMessage)
            }
            .sheet(item: $paymentSheet) { presentation in
                if let flow, let threadKey = threadDraftKey {
                    SupportPaymentSheet(
                        ticketID: threadKey,
                        flow: flow,
                        resume: presentation.envelope,
                        advertisedBeneficiaryName: paymentsGate.beneficiaryDisplayName,
                        onEnvelopeChange: { pendingPayment = $0 },
                        onCompleted: {
                            Task { await advanceThreadWindow(silently: true) }
                        }
                    )
                    .environmentObject(model)
                }
            }
            .fullScreenCover(isPresented: $showMoneyIdentityVerification) {
                NavigationStack {
                    KYCView()
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button {
                                    showMoneyIdentityVerification = false
                                } label: {
                                    Label("Close", systemImage: "xmark")
                                }
                                .accessibilityLabel("Close identity verification")
                            }
                        }
                }
                .environmentObject(model)
            }
            .task {
                // Restoration FIRST: the composer's persisted envelope must be bound before any
                // network activity can race it. Polling starts last and lives with the view.
                await bindAndRestore()
                await loadThread()
                await pollLoop()
            }
            .refreshable {
                consecutivePollFailures = 0
                await advanceThreadWindow()
            }
            .onChange(of: composerText) { _, value in
                if value.count > SupportContract.messageMaximumLength {
                    composerText = String(value.prefix(SupportContract.messageMaximumLength))
                    return
                }
                autosaveDraft()
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .kitRemoteWakeReceived)
            ) { _ in
                // A remote wake hints at new server state: reset the backoff and advance once,
                // foreground-only; the advance itself re-checks gate, binding, and busy.
                guard scenePhase == .active else { return }
                consecutivePollFailures = 0
                Task { await advanceThreadWindow(silently: true) }
            }
        }
    }

    /// Verified wording and the seal appear only when the server-provided identity passes the
    /// central verified-official predicate; anything partial or inconsistent renders the plain,
    /// unverified variant. When the validated gate advertises AI processing, that is disclosed
    /// here too — before anything is sent.
    private var readabilityNotice: some View {
        Label {
            Text(readabilityText)
        } icon: {
            // The verified seal wears support blue (never KYC green); the unverified variant
            // gets a plain info glyph with no verified colouring at all.
            Image(systemName: supportIdentityVerified ? "checkmark.seal.fill" : "info.circle")
                .foregroundStyle(
                    supportIdentityVerified
                        ? AnyShapeStyle(KitColor.verifiedBlue)
                        : AnyShapeStyle(KitColor.secondaryText)
                )
        }
        .font(.caption2)
        .foregroundStyle(KitColor.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    /// The AI-to-human hand-off, presented where the conversation happens: while the server
    /// says the assistant is active on an open ticket, the thread itself says so and offers the
    /// switch inline — not only behind the toolbar menu. `escalate()` re-checks the gate,
    /// binding, and busy state itself.
    private var assistantHandoffNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                "An automated assistant replies first here. You can switch to a person "
                    + "at any time.",
                systemImage: "sparkles"
            )
            .font(.caption2)
            .foregroundStyle(KitColor.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            Button {
                Task { await escalate() }
            } label: {
                Label("Talk to a person", systemImage: "person.wave.2")
                    .font(.caption.weight(.semibold))
            }
            .disabled(busy || !gate.isAvailable || !model.appReviewDemoMutationsAllowed)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var readabilityText: String {
        var text = (supportIdentityVerified ? "Verified Kit Support" : "Kit Pay support")
            + " · staff can read this conversation to help you; it is not "
            + "end-to-end encrypted."
        if gate.aiProcessingEnabled {
            text += " A redacted copy of these messages may be sent to an approved AI provider "
                + "to prepare a first reply."
        }
        return text
    }

    /// Explicit continuation for bounded pagination: when more history exists beyond the loaded
    /// window it is announced and loadable — never silently dropped.
    private var loadMoreRow: some View {
        VStack(spacing: 8) {
            Label(
                "More messages are in this conversation.",
                systemImage: "ellipsis.bubble"
            )
            .font(.footnote)
            .foregroundStyle(KitColor.secondaryText)
            Button {
                Task { await advanceThreadWindow() }
            } label: {
                if isRefreshing {
                    ProgressView()
                } else {
                    Text("Load more")
                        .font(.footnote.weight(.semibold))
                }
            }
            .disabled(busy)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    /// Composer-envelope state, shown even when the ticket is closed — a blocked cleanup must
    /// stay visible and finishable regardless of ticket status.
    @ViewBuilder
    private var composerNotices: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let draftStorageError {
                Label(draftStorageError, systemImage: "lock.trianglebadge.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                if restoreBlocked {
                    Button("Try again") {
                        Task { await bindAndRestore() }
                    }
                    .font(.footnote.weight(.semibold))
                }
            }
            if cleanupBlocked {
                Label(
                    "Your message was delivered. Finish the secure cleanup of its saved copy "
                        + "on this device to continue.",
                    systemImage: "checkmark.circle.trianglebadge.exclamationmark"
                )
                .font(.footnote)
                .foregroundStyle(KitColor.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                Button("Finish cleanup") {
                    Task { await retryAcceptedCleanup() }
                }
                .font(.footnote.weight(.semibold))
            } else if pendingEnvelope != nil {
                Label(
                    "This message was sent but not confirmed. It's kept safely here — retrying "
                        + "sends exactly the same message and won't create a duplicate.",
                    systemImage: "clock.badge.exclamationmark"
                )
                .font(.footnote)
                .foregroundStyle(KitColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
            // Payment state stays visible on CLOSED tickets too: the backend resolves payment
            // replays before its closed check, so resolution must remain reachable here.
            if paymentStoreBlocked {
                Label(
                    "A saved payment attempt can't be read on this device right now. "
                        + "Checking again is free and never charges you.",
                    systemImage: "banknote"
                )
                .font(.footnote)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                Button("Try again") {
                    restorePendingPayment()
                }
                .font(.footnote.weight(.semibold))
            } else if let pendingPayment {
                Label(
                    "A payment of \(pendingPaymentAmountText(pendingPayment)) to Kit Pay wasn't "
                        + "confirmed. It's kept safely here — confirming it again won't charge "
                        + "you twice.",
                    systemImage: "banknote"
                )
                .font(.footnote)
                .foregroundStyle(KitColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                if flow != nil || model.moneyActionAccessRequirement == .verifyIdentity {
                    Button("Review payment") {
                        openSupportPayment(pendingPayment)
                    }
                    .font(.footnote.weight(.semibold))
                    .disabled(busy)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    private func pendingPaymentAmountText(_ envelope: SupportPaymentEnvelope) -> String {
        KitMoney.formatted(
            envelope.amount,
            code: envelope.currencyCode,
            scale: envelope.currencyScale
        )
    }

    private var unavailableNotice: some View {
        Label(
            "Kit Pay support is not available right now. Your message stays here as a draft "
                + "until support returns.",
            systemImage: "exclamationmark.circle"
        )
        .font(.caption2)
        .foregroundStyle(KitColor.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    private var closedNotice: some View {
        Label(
            closedText,
            systemImage: "lock.circle"
        )
        .font(.footnote)
        .foregroundStyle(KitColor.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var closedText: String {
        if let closedAt = SupportRelativeTime.text(from: ticket.closed?.at) {
            return "This request was closed \(closedAt). Start a new request if you need more help."
        }
        return "This request is closed. Start a new request if you need more help."
    }

    private var composerBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message Kit Support…", text: $composerText, axis: .vertical)
                .lineLimit(1 ... 5)
                .disabled(composerFrozen)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
                .accessibilityLabel("Support message")

            Button {
                Task { await sendMessage() }
            } label: {
                if isSending {
                    ProgressView()
                        .frame(width: 44, height: 44)
                } else {
                    Image(
                        systemName: pendingEnvelope != nil
                            ? "arrow.clockwise.circle.fill"
                            : "arrow.up.circle.fill"
                    )
                    .font(.system(size: 32))
                    .frame(width: 44, height: 44)
                }
            }
            .disabled(!canSend)
            .tint(KitColor.navy)
            .accessibilityLabel(pendingEnvelope != nil ? "Retry send" : "Send message")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// This sheet's account binding, captured once for its lifetime. A later mismatch (account
    /// switch) throws instead of rebinding, so an old thread can never be read or written under
    /// a new account — while the composer draft stays persisted under the original account.
    @MainActor
    private func ensureFlow() async throws -> SupportFlowBinding {
        if let flow {
            guard await SupportSessionScope.isCurrent(flow) else {
                throw APIClientError.signedOut
            }
            return flow
        }
        let captured = try await SupportSessionScope.captureFlow()
        flow = captured
        return captured
    }

    /// Account replacement: every piece of thread state is purged, in-flight completions are
    /// fenced off by the generation bump, and the sheet is dismissed. `composerReady` drops
    /// first so the field resets cannot trigger an autosave; the persisted draft/envelope stays
    /// under the ORIGINAL account's protected storage.
    @MainActor
    private func purgeStaleThreadState() {
        threadGeneration += 1
        composerReady = false
        messages = []
        hasMoreForward = false
        pendingEnvelope = nil
        cleanupBlocked = false
        composerText = ""
        threadError = nil
        draftStorageError = nil
        consecutivePollFailures = 0
        pendingPayment = nil
        paymentStoreBlocked = false
        paymentSheet = nil
        dismiss()
    }

    // MARK: - Draft persistence

    /// RESTORATION phase (same contract as the new-request composer): atomically apply the
    /// persisted draft — message AND idempotency UUID — before any edit, autosave, or send is
    /// possible; a restored `.pendingReplay` freezes the composer for verbatim replay; an
    /// unreadable protected record blocks the composer behind an explicit retry.
    @MainActor
    private func bindAndRestore() async {
        guard !composerReady else { return }
        restoreBlocked = false
        if flow == nil {
            do {
                flow = try await SupportSessionScope.captureFlow()
            } catch {
                draftStorageError = SupportErrorText.describe(error)
                restoreBlocked = true
                return
            }
        }
        guard let flow else { return }
        guard let threadKey = threadDraftKey else {
            draftStorageError = SupportErrorText.describe(SupportDraftStoreError.unreadable)
            restoreBlocked = true
            return
        }
        restorePendingPayment()
        do {
            if let draft = try SupportDraftStore.shared.load(
                accountID: flow.accountID,
                thread: threadKey
            ) {
                guard let restoredID = UUID(uuidString: draft.clientMessageID) else {
                    // `isValid` guarantees a canonical UUID; anything else is corruption.
                    throw SupportDraftStoreError.unreadable
                }
                composerText = draft.message
                clientMessageID = restoredID
                if draft.phase == .pendingReplay {
                    pendingEnvelope = draft
                }
            }
            draftStorageError = nil
            composerReady = true
        } catch {
            draftStorageError = SupportErrorText.describe(error)
            restoreBlocked = true
        }
    }

    /// Restores this ticket's frozen payment attempt, independently of the draft: an unreadable
    /// record surfaces a retryable notice (and informs the close prompt) without freezing the
    /// composer — messaging must keep working even when the payment record is in a bad state.
    @MainActor
    private func restorePendingPayment() {
        guard let flow, let threadKey = threadDraftKey else { return }
        do {
            pendingPayment = try SupportPaymentStore.shared.load(
                accountID: flow.accountID,
                ticketID: threadKey
            )
            paymentStoreBlocked = false
        } catch {
            pendingPayment = nil
            paymentStoreBlocked = true
        }
    }

    /// Autosave runs ONLY while the composer is interactive (mirrors the new-request rules).
    private func autosaveDraft() {
        guard composerReady, !restoreBlocked, pendingEnvelope == nil, !cleanupBlocked,
              !isSending, let flow, let threadKey = threadDraftKey
        else { return }
        if composerText.isEmpty {
            // A failed verified clear is surfaced, never swallowed: stale content may still be
            // durably stored (it could resurrect into a later session), and the close policy
            // must treat storage as failed until a clear verifiably succeeds.
            do {
                try SupportDraftStore.shared.clear(accountID: flow.accountID, thread: threadKey)
                draftStorageError = nil
            } catch {
                draftStorageError = SupportErrorText.describe(error)
            }
            return
        }
        do {
            try persistDraft(flow: flow, threadKey: threadKey)
            draftStorageError = nil
        } catch {
            draftStorageError = SupportErrorText.describe(error)
        }
    }

    private func persistDraft(flow: SupportFlowBinding, threadKey: String) throws {
        try SupportDraftStore.shared.save(
            SupportComposerDraft(
                accountID: flow.accountID,
                thread: threadKey,
                phase: .draft,
                message: composerText,
                clientMessageID: clientMessageID.uuidString.lowercased()
            )
        )
    }

    // MARK: - Thread loading

    @MainActor
    private func loadThread() async {
        guard !busy else { return }
        guard gate.isAvailable else {
            threadError = SupportErrorText.describe(SupportContractError.supportUnavailable)
            return
        }
        isLoading = true
        threadError = nil
        let needsMore = await loadThreadCore()
        isLoading = false
        if needsMore {
            await advanceThreadWindow()
        }
    }

    /// Fetches and applies the validated snapshot; returns whether more history remains beyond
    /// the snapshot window.
    @MainActor
    private func loadThreadCore() async -> Bool {
        let expectedGeneration = threadGeneration
        do {
            let flow = try await ensureFlow()
            let snapshot = try await APIClientSessionBinding.$sessionID.withValue(flow.sessionID) {
                try await APIClient.shared.supportTicketSnapshot(id: ticket.id)
            }
            try Task.checkCancellation()
            // Full integrity validation before anything reaches state: bound ticket, exact
            // contiguity from position 1, bounded text, coherent senders.
            try SupportThreadPageValidator.validateMessagePage(
                snapshot.messages,
                boundTicketID: ticket.id,
                pageTicket: snapshot.ticket,
                afterPosition: 0,
                requestedLimit: SupportContract.snapshotMessagesLimit,
                existingIDs: [],
                existingMaxPosition: 0
            )
            // The server's continuation pair may only confirm, never steer: `has_more` must be
            // coherent with a cursor equal to the max validated delivered position.
            let deliveredMax = try SupportThreadPageValidator.validateSnapshotContinuation(
                messagesHasMore: snapshot.messagesHasMore,
                messagesNextAfterPosition: snapshot.messagesNextAfterPosition,
                validatedItems: snapshot.messages
            )
            // The refreshed ticket's message_count is the authoritative total: a count BELOW the
            // validated delivered window contradicts the payload and rejects the snapshot before
            // it can touch state; a count above it means more history remains even when the
            // window heuristics would say otherwise.
            let remaining = try SupportThreadPageValidator.forwardWindowRemaining(
                lastLoadedPosition: deliveredMax,
                ticket: snapshot.ticket
            )
            guard await SupportSessionScope.isCurrent(flow) else {
                purgeStaleThreadState()
                return false
            }
            guard gate.isAvailable, threadGeneration == expectedGeneration else { return false }
            threadGeneration += 1
            messages = snapshot.messages
            applyTicketUpdate(snapshot.ticket)
            hasMoreForward = snapshot.messagesHasMore || remaining
            threadError = nil
            return hasMoreForward
        } catch is CancellationError {
            return false
        } catch {
            if let flow, await SupportSessionScope.isCurrent(flow) == false {
                purgeStaleThreadState()
                return false
            }
            guard threadGeneration == expectedGeneration else { return false }
            threadError = SupportErrorText.describe(error)
            return false
        }
    }

    /// The single bounded, single-flight, generation-fenced continuation used by pull-refresh,
    /// the poll loop, the remote-wake handler, the explicit load-more control, and
    /// post-mutation catch-up. Fetches at most `maxAutoPagesPerCycle` exactly-contiguous
    /// validated pages past the loaded window; whether more remains is decided by the refreshed
    /// ticket's authoritative `message_count` (`forwardWindowRemaining`), never by page
    /// fullness, and a remainder leaves `hasMoreForward` set so it is announced, never silently
    /// dropped. A successful cycle clears any prior thread error.
    @MainActor
    @discardableResult
    private func advanceThreadWindow(silently: Bool = false) async -> Bool {
        guard !busy else { return true }
        guard gate.isAvailable else {
            if !silently {
                threadError = SupportErrorText.describe(SupportContractError.supportUnavailable)
            }
            return false
        }
        isRefreshing = true
        defer { isRefreshing = false }
        var expectedGeneration = threadGeneration
        do {
            let flow = try await ensureFlow()
            var pagesFetched = 0
            var moreRemaining = false
            while pagesFetched < SupportContract.maxAutoPagesPerCycle {
                let after = messages.map(\.position).max() ?? 0
                let page = try await APIClientSessionBinding.$sessionID
                    .withValue(flow.sessionID) {
                        try await APIClient.shared.supportMessages(
                            ticketID: ticket.id,
                            afterPosition: after
                        )
                    }
                try Task.checkCancellation()
                try SupportThreadPageValidator.validateMessagePage(
                    page.items,
                    boundTicketID: ticket.id,
                    pageTicket: page.ticket,
                    afterPosition: after,
                    requestedLimit: SupportContract.messagesPageLimit,
                    existingIDs: Set(messages.map(\.id)),
                    existingMaxPosition: after
                )
                // Authoritative remainder from the page's refreshed ticket, BEFORE the page is
                // applied: message_count below the validated delivered window rejects the page
                // as a whole; above it keeps the window advancing even for a short page (a
                // message that landed between the page query and the ticket refresh).
                let newMax = page.items.map(\.position).max() ?? after
                let remaining = try SupportThreadPageValidator.forwardWindowRemaining(
                    lastLoadedPosition: newMax,
                    ticket: page.ticket
                )
                guard await SupportSessionScope.isCurrent(flow) else {
                    purgeStaleThreadState()
                    return false
                }
                // Ordered application: if anything else wrote the thread since this page was
                // requested, drop the page instead of overwriting newer state.
                guard gate.isAvailable, threadGeneration == expectedGeneration else {
                    return false
                }
                if !page.items.isEmpty {
                    threadGeneration += 1
                    messages.append(contentsOf: page.items)
                }
                applyTicketUpdate(page.ticket)
                expectedGeneration = threadGeneration
                pagesFetched += 1
                moreRemaining = remaining
                if !moreRemaining { break }
            }
            hasMoreForward = moreRemaining
            threadError = nil
            return true
        } catch is CancellationError {
            return false
        } catch {
            if let flow, await SupportSessionScope.isCurrent(flow) == false {
                purgeStaleThreadState()
                return false
            }
            guard !silently, threadGeneration == expectedGeneration else { return false }
            threadError = SupportErrorText.describe(error)
            return false
        }
    }

    /// Foreground-only, bounded-backoff polling (`transport == "poll"`). Terminates for the
    /// sheet's lifetime when the gate withdraws, the ticket closes, or the account binding
    /// breaks (purging first); skips ticks while backgrounded, while any other thread operation
    /// is in flight, or while paused after repeated failures — a pull-to-refresh or a remote
    /// wake resets the counter and the backoff.
    @MainActor
    private func pollLoop() async {
        while !Task.isCancelled {
            let delay = SupportContract.pollDelaySeconds(
                consecutiveFailures: consecutivePollFailures
            )
            do {
                try await Task.sleep(nanoseconds: delay * 1_000_000_000)
            } catch {
                return
            }
            guard gate.isAvailable else { return }
            guard ticket.isOpen else { return }
            guard let flow else { continue }
            guard await SupportSessionScope.isCurrent(flow) else {
                purgeStaleThreadState()
                return
            }
            guard scenePhase == .active else { continue }
            guard !busy, !cleanupBlocked else { continue }
            guard consecutivePollFailures < SupportContract.maxConsecutivePollFailures else {
                continue
            }
            if await advanceThreadWindow(silently: true) {
                consecutivePollFailures = 0
            } else {
                guard await SupportSessionScope.isCurrent(flow) else { return }
                consecutivePollFailures += 1
                if consecutivePollFailures >= SupportContract.maxConsecutivePollFailures {
                    threadError = "Automatic updates are paused. Pull down to refresh."
                }
            }
        }
    }

    // MARK: - Mutations

    @MainActor
    private func sendMessage() async {
        guard await sendMessageCore() else { return }
        // The accepted message is shown via a validated contiguous window advance rather than a
        // blind append (a staff reply may have landed in between); runs after the send flag
        // clears so the single-flight guard admits it.
        await advanceThreadWindow()
    }

    /// Returns true only when the send was authoritatively accepted AND its envelope was
    /// verifiably cleared.
    @MainActor
    private func sendMessageCore() async -> Bool {
        guard canSend, let flow, let threadKey = threadDraftKey else { return false }
        guard await SupportSessionScope.isCurrent(flow) else {
            purgeStaleThreadState()
            return false
        }
        let envelope: SupportComposerDraft
        if let pendingEnvelope {
            // Verbatim replay of the frozen attempt: same content, same idempotency key.
            envelope = pendingEnvelope
        } else {
            guard let attemptBody = SupportContract.normalizedMessageBody(composerText) else {
                return false
            }
            let candidate = SupportComposerDraft(
                accountID: flow.accountID,
                thread: threadKey,
                phase: .pendingReplay,
                message: attemptBody,
                clientMessageID: clientMessageID.uuidString.lowercased()
            )
            // FREEZE before the network call: no durable proof, no POST.
            do {
                try SupportDraftStore.shared.save(candidate)
                draftStorageError = nil
            } catch {
                draftStorageError = SupportErrorText.describe(error)
                return false
            }
            pendingEnvelope = candidate
            envelope = candidate
            composerText = attemptBody
        }
        guard let attemptID = UUID(uuidString: envelope.clientMessageID) else {
            draftStorageError = SupportErrorText.describe(SupportDraftStoreError.unreadable)
            return false
        }
        isSending = true
        threadError = nil
        defer { isSending = false }
        let expectedGeneration = threadGeneration
        do {
            let sent = try await APIClientSessionBinding.$sessionID.withValue(flow.sessionID) {
                try await APIClient.shared.sendSupportMessage(
                    ticketID: ticket.id,
                    body: envelope.message,
                    clientMessageID: attemptID
                )
            }
            try Task.checkCancellation()
            // Authoritative-success pinning: the response must provably describe THIS send
            // (validated content, customer sender, exact attempted body). Anything less keeps
            // the envelope frozen.
            try SupportThreadPageValidator.validateSentMessageAuthoritative(
                sent,
                attemptedBody: envelope.message
            )
            guard await SupportSessionScope.isCurrent(flow) else {
                purgeStaleThreadState()
                return false
            }
            guard gate.isAvailable, threadGeneration == expectedGeneration else { return false }
            return finalizeAcceptedMessage(flow: flow, threadKey: threadKey)
        } catch is CancellationError {
            return false
        } catch {
            guard await SupportSessionScope.isCurrent(flow) else {
                purgeStaleThreadState()
                return false
            }
            guard threadGeneration == expectedGeneration else { return false }
            if SupportContract.isDefinitiveRejection(error) {
                demoteRejectedEnvelope(flow: flow, threadKey: threadKey)
                threadError = SupportErrorText.describe(error)
            } else {
                threadError = SupportErrorText.describe(
                    SupportContractError.deliveryUnconfirmed
                )
            }
            return false
        }
    }

    /// Success transition gated on VERIFIED envelope removal (same rule as ticket creation): a
    /// failed clear enters blocked-cleanup — no rotation, no emptying, no dismissal — so the
    /// accepted envelope can never be overwritten or reused with different content.
    @MainActor
    private func finalizeAcceptedMessage(flow: SupportFlowBinding, threadKey: String) -> Bool {
        do {
            try SupportDraftStore.shared.clear(accountID: flow.accountID, thread: threadKey)
        } catch {
            cleanupBlocked = true
            draftStorageError = SupportErrorText.describe(error)
            return false
        }
        pendingEnvelope = nil
        cleanupBlocked = false
        draftStorageError = nil
        clientMessageID = UUID()
        composerText = ""
        threadError = nil
        return true
    }

    @MainActor
    private func retryAcceptedCleanup() async {
        guard cleanupBlocked, !busy, let flow, let threadKey = threadDraftKey else { return }
        guard await SupportSessionScope.isCurrent(flow) else {
            purgeStaleThreadState()
            return
        }
        guard finalizeAcceptedMessage(flow: flow, threadKey: threadKey) else { return }
        await advanceThreadWindow()
    }

    /// Same definitive-rejection demotion contract as the new-request composer.
    @MainActor
    private func demoteRejectedEnvelope(flow: SupportFlowBinding, threadKey: String) {
        guard pendingEnvelope != nil else { return }
        let rotated = UUID()
        let demoted = SupportComposerDraft(
            accountID: flow.accountID,
            thread: threadKey,
            phase: .draft,
            message: composerText,
            clientMessageID: rotated.uuidString.lowercased()
        )
        pendingEnvelope = nil
        clientMessageID = rotated
        do {
            try SupportDraftStore.shared.save(demoted)
            draftStorageError = nil
        } catch {
            draftStorageError = SupportErrorText.describe(error)
        }
    }

    // MARK: - Safe close

    /// Close-time resolution prompt, chosen by `SupportClosePolicy` when the customer asks to
    /// close. Exactly one is presented; each resolves its obstacle before any close proceeds.
    private enum SupportClosePrompt: Equatable {
        case plain
        case cleanupBlocked
        case pendingReplay
        case storageError
        case unsentDraft
        case pendingPayment
    }

    private var currentCloseObstacle: SupportCloseObstacle? {
        SupportClosePolicy.obstacle(
            cleanupBlocked: cleanupBlocked,
            pendingReplay: pendingEnvelope != nil,
            storageError: draftStorageError != nil,
            composerText: composerText,
            pendingPayment: pendingPayment != nil || paymentStoreBlocked
        )
    }

    private func closePromptForCurrentState() -> SupportClosePrompt {
        switch currentCloseObstacle {
        case .none: .plain
        case .cleanupBlocked: .cleanupBlocked
        case .pendingReplay: .pendingReplay
        case .storageError: .storageError
        case .unsentDraft: .unsentDraft
        case .pendingPayment: .pendingPayment
        }
    }

    private var closeDialogTitle: String {
        switch closePrompt ?? .plain {
        case .plain: "Close this support request?"
        case .cleanupBlocked: "Finish secure cleanup first"
        case .pendingReplay: "Send your pending message first?"
        case .storageError: "Discard your draft?"
        case .unsentDraft: "You have an unsent message"
        case .pendingPayment: "A payment attempt is unresolved"
        }
    }

    private var closeDialogMessage: String {
        switch closePrompt ?? .plain {
        case .plain:
            "A closed request can't be reopened, but you can always start a new one."
        case .cleanupBlocked:
            "Your last message was delivered, but its saved copy on this device hasn't "
                + "finished secure cleanup. Finish that first — the request stays open until "
                + "cleanup succeeds."
        case .pendingReplay:
            "A message here was sent but not confirmed. Retrying sends exactly the same "
                + "message and won't create a duplicate; once it's delivered, the request "
                + "closes."
        case .storageError:
            "Your draft could not be safely saved on this device. Closing discards it after "
                + "a verified cleanup; if that cleanup fails, the request stays open."
        case .unsentDraft:
            "Closing now would discard it. You can send it first — the request closes right "
                + "after it's delivered."
        case .pendingPayment:
            paymentStoreBlocked
                ? "A saved payment attempt can't be read on this device right now. Closing is "
                    + "safe — it stays with this request, and resolving it later never charges "
                    + "you twice."
                : "A payment to Kit Pay wasn't confirmed yet. Closing is safe — it stays "
                    + "available on the closed request, and confirming it later never charges "
                    + "you twice."
        }
    }

    @ViewBuilder
    private var closeDialogButtons: some View {
        switch closePrompt ?? .plain {
        case .plain:
            Button("Close request", role: .destructive) {
                Task { await performClose() }
            }
        case .cleanupBlocked:
            Button("Finish cleanup") {
                Task { await retryAcceptedCleanup() }
            }
        case .pendingReplay:
            Button("Send message and close") {
                Task { await sendThenClose() }
            }
        case .storageError:
            Button("Discard draft and close", role: .destructive) {
                Task { await discardDraftThenClose() }
            }
        case .unsentDraft:
            Button("Send message and close") {
                Task { await sendThenClose() }
            }
            Button("Discard message and close", role: .destructive) {
                Task { await discardDraftThenClose() }
            }
        case .pendingPayment:
            if let pendingPayment,
               flow != nil || model.moneyActionAccessRequirement == .verifyIdentity {
                Button("Review payment") {
                    openSupportPayment(pendingPayment)
                }
            }
            Button("Close request anyway", role: .destructive) {
                Task { await performClose(acknowledgedPendingPayment: true) }
            }
        }
    }

    private func openSupportPayment(_ envelope: SupportPaymentEnvelope?) {
        switch model.moneyActionAccessRequirement {
        case .allowed:
            guard flow != nil else {
                model.lastError = "Wallet access is temporarily unavailable. Refresh and try again."
                return
            }
            paymentSheet = SupportPaymentSheetPresentation(envelope: envelope)
        case .readOnly:
            model.lastError = "This App Review preview is read-only."
        case .verifyIdentity:
            showMoneyIdentityVerification = true
        case .verifyDeviceIdentity:
            model.lastError = "Verify this iPhone before sending money."
        case .unlockSession, .unavailable:
            model.lastError = "Unlock this iPhone before sending money."
        }
    }

    /// A plain close may run ONLY when the close policy reports no obstacle — re-evaluated
    /// here, not just when the dialog was presented, so a state change in between (or any
    /// future call site) can never close over unresolved content. An obstacle re-presents the
    /// matching prompt instead. The single deliberate exception: an ACKNOWLEDGED pending
    /// payment, which is informational — closing is provably safe because the server resolves
    /// payment replays before its closed-ticket check and the attempt stays reachable on the
    /// closed thread.
    @MainActor
    private func performClose(acknowledgedPendingPayment: Bool = false) async {
        let obstacle = currentCloseObstacle
        guard obstacle == nil
            || (obstacle == .pendingPayment && acknowledgedPendingPayment)
        else {
            closePrompt = closePromptForCurrentState()
            return
        }
        guard await mutateTicketCore(.close) else { return }
        await advanceThreadWindow()
    }

    /// "Send message and close": resolves the composer first — a frozen envelope by verbatim
    /// replay (a 200 replay proves it committed while the ticket was open; a definitive
    /// rejection demotes it to an editable draft and aborts the close) or unsent text by a
    /// normal freeze-and-send. Only a verified accepted-and-cleared send lets the close run.
    @MainActor
    private func sendThenClose() async {
        guard await sendMessageCore() else { return }
        await performClose()
    }

    /// Explicit, customer-chosen discard: the persisted draft must VERIFIABLY clear before the
    /// close runs — a failed clear aborts the close and surfaces the storage error, so draft
    /// content can never silently outlive a closed ticket in protected storage. Frozen
    /// envelopes are never discardable (the pending-replay prompt owns them).
    @MainActor
    private func discardDraftThenClose() async {
        guard !busy, !cleanupBlocked, pendingEnvelope == nil, let flow,
              let threadKey = threadDraftKey
        else { return }
        guard await SupportSessionScope.isCurrent(flow) else {
            purgeStaleThreadState()
            return
        }
        do {
            try SupportDraftStore.shared.clear(accountID: flow.accountID, thread: threadKey)
        } catch {
            draftStorageError = SupportErrorText.describe(error)
            return
        }
        draftStorageError = nil
        composerText = ""
        clientMessageID = UUID()
        await performClose()
    }

    @MainActor
    private func escalate() async {
        guard await mutateTicketCore(.escalate) else { return }
        await advanceThreadWindow()
    }

    private enum SupportTicketMutation {
        case close
        case escalate
    }

    /// Shared close/escalate path: full gate + bound account before the request AND again before
    /// any state or callback update, with ACTION-SPECIFIC authoritative postconditions — a
    /// merely valid same-ID ticket is NOT success. Close requires actual closed status with
    /// coherent closure metadata; escalate requires the backend's hand-off postcondition (still
    /// open, assistant inactive). A wrong or stale 2xx throws in validation, preserving prior
    /// state with a safe error.
    @MainActor
    private func mutateTicketCore(_ mutation: SupportTicketMutation) async -> Bool {
        guard gate.isAvailable else {
            threadError = SupportErrorText.describe(SupportContractError.supportUnavailable)
            return false
        }
        guard !busy, model.appReviewDemoMutationsAllowed, let flow else { return false }
        guard await SupportSessionScope.isCurrent(flow) else {
            purgeStaleThreadState()
            return false
        }
        isUpdatingTicket = true
        threadError = nil
        defer { isUpdatingTicket = false }
        let expectedGeneration = threadGeneration
        do {
            let updated: SupportTicketDTO = try await APIClientSessionBinding.$sessionID
                .withValue(flow.sessionID) {
                    switch mutation {
                    case .close:
                        return try await APIClient.shared.closeSupportTicket(id: ticket.id)
                    case .escalate:
                        return try await APIClient.shared.escalateSupportTicket(id: ticket.id)
                    }
                }
            try Task.checkCancellation()
            switch mutation {
            case .close:
                try SupportThreadPageValidator.validateClosedTicketAuthoritative(
                    updated,
                    expectedID: ticket.id
                )
            case .escalate:
                try SupportThreadPageValidator.validateEscalatedTicketAuthoritative(
                    updated,
                    expectedID: ticket.id
                )
            }
            guard await SupportSessionScope.isCurrent(flow) else {
                purgeStaleThreadState()
                return false
            }
            guard gate.isAvailable, threadGeneration == expectedGeneration else { return false }
            applyTicketUpdate(updated)
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard await SupportSessionScope.isCurrent(flow) else {
                purgeStaleThreadState()
                return false
            }
            guard threadGeneration == expectedGeneration else { return false }
            threadError = SupportErrorText.describe(error)
            return false
        }
    }

    /// Every ticket write goes through here — validated upstream against the bound ticket ID —
    /// and bumps the generation so any racing completion drops its stale application.
    @MainActor
    private func applyTicketUpdate(_ updated: SupportTicketDTO) {
        threadGeneration += 1
        ticket = updated
        onTicketUpdated(updated)
    }
}

private struct SupportMessageBubble: View {
    let message: SupportMessageDTO

    private var isCustomer: Bool { message.sender.isCustomer }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // The ticket-scoped avatar renders on the support side only, and only for senders
            // that pass the verified-official predicate (`ticketScopedAvatar` is `.none`
            // otherwise) — customer bubbles carry no identity artwork in support threads.
            if !isCustomer {
                SupportSenderAvatarView(avatar: message.sender.ticketScopedAvatar)
            }
            bubbleColumn
        }
        .frame(maxWidth: .infinity, alignment: isCustomer ? .trailing : .leading)
    }

    private var bubbleColumn: some View {
        VStack(alignment: isCustomer ? .trailing : .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(senderName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(KitColor.secondaryText)
                // Seal only for senders that pass the central verified-official predicate
                // (allowlisted type + coherent metadata + official flag + designation); an
                // `official` flag alone (or any customer message) never earns one. Blue, not
                // green: verified SUPPORT identity must never look like KYC verification.
                if message.sender.isVerifiedOfficialSupport {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.caption2)
                        .foregroundStyle(KitColor.verifiedBlue)
                        .accessibilityLabel("Verified Kit Pay support")
                } else if !isCustomer {
                    // Defense in depth: the page validator rejects unknown/incoherent senders
                    // outright, so a non-customer bubble that is not verified renders an
                    // explicit non-support marker rather than passing as support.
                    Text("Unverified")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.16), in: Capsule())
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Unverified sender")
                }
                if message.sender.automated {
                    Text("Automated")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.14), in: Capsule())
                        .foregroundStyle(KitColor.secondaryText)
                }
            }

            // One bubble per message: any attachment renders inside the same bubble as the
            // text rather than as a second message. Viewing attachments is not supported in
            // this version (`SupportContract.attachmentsSupported`), so the label says exactly
            // that instead of implying access.
            VStack(alignment: .leading, spacing: 8) {
                if message.attachment != nil {
                    Label(
                        "Attachment — can't be viewed in this app version yet",
                        systemImage: "paperclip"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(
                        isCustomer ? Color.white.opacity(0.85) : KitColor.secondaryText
                    )
                    .fixedSize(horizontal: false, vertical: true)
                }
                Text(message.body)
                    .font(.subheadline)
                    .foregroundStyle(isCustomer ? Color.white : KitColor.primaryText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                isCustomer ? AnyShapeStyle(KitColor.navy) : AnyShapeStyle(.thinMaterial),
                in: RoundedRectangle(cornerRadius: 18)
            )
            .fixedSize(horizontal: false, vertical: true)

            if let when = SupportRelativeTime.text(from: message.createdAt) {
                Text(when)
                    .font(.caption2)
                    .foregroundStyle(KitColor.secondaryText)
            }
        }
    }

    private var senderName: String {
        if let alias = message.sender.agentAlias, !alias.isEmpty {
            return "\(message.sender.displayName) · \(alias)"
        }
        return message.sender.displayName
    }
}

/// The ticket-scoped avatar disc for a verified support-side sender: the official Kit Pay mark
/// for assistant/system senders, alias initials for human agents. Always locally drawn from the
/// validated sender payload (`SupportSenderDTO.ticketScopedAvatar`) — never a remote image and
/// never anyone's profile photo. `.none` (customers, unverified senders) renders nothing.
private struct SupportSenderAvatarView: View {
    let avatar: SupportSenderAvatar

    var body: some View {
        switch avatar {
        case .officialMark:
            disc {
                Image(systemName: "lifepreserver.fill")
                    .font(.system(size: 13, weight: .semibold))
            }
            .accessibilityLabel("Kit Pay official")
        case .initials(let initials):
            disc {
                Text(initials)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .accessibilityLabel("Support agent")
        case .none:
            EmptyView()
        }
    }

    private func disc(@ViewBuilder _ content: () -> some View) -> some View {
        ZStack {
            Circle().fill(KitColor.paleBlue)
            content()
                .foregroundStyle(KitColor.verifiedBlue)
        }
        .frame(width: 26, height: 26)
    }
}

enum SupportRelativeTime {
    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    static func text(from iso8601: String?) -> String? {
        guard let date = SupportDates.parse(iso8601) else { return nil }
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

enum SupportErrorText {
    static func describe(_ error: Error) -> String {
        if let payload = error as? APIErrorPayload {
            return payload.message
        }
        if let contract = error as? SupportContractError,
           let description = contract.errorDescription {
            return description
        }
        if let draft = error as? SupportDraftStoreError,
           let description = draft.errorDescription {
            return description
        }
        if let payment = error as? SupportPaymentStoreError,
           let description = payment.errorDescription {
            return description
        }
        if let client = error as? APIClientError,
           let description = client.errorDescription {
            return description
        }
        return "Support could not be reached safely. Check your connection and try again."
    }
}
