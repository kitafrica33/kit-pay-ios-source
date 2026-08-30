import SwiftUI

// MARK: - Public forwarding payload

/// What is being forwarded, captured at menu time from the source conversation. Media rides
/// as pure identity: the bytes AND the MIME/caption facts they travel with are resolved
/// together by the authoritative loader at send time, never captured here — captured wire
/// text or facts could outlive the row that vouched for them.
enum ForwardPayloadItem: Identifiable, Equatable {
    case text(id: UUID, body: String)
    case media(id: UUID, sourceConversationID: String)

    var id: UUID {
        switch self {
        case let .text(id, _): id
        case let .media(id, _): id
        }
    }
}

// MARK: - Private target/model helpers

/// One selectable forward destination. `recipientUserID` is always a canonical
/// lowercase user UUID: rows that cannot resolve a single Kit Pay recipient
/// (group/ambiguous rosters, malformed contacts) are never offered.
private struct ForwardTargetRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case conversation(Conversation)
        case contact(WalletContactDTO)
    }

    let id: String
    let kind: Kind
    let displayName: String
    let subtitle: String
    let avatarURL: String?
    let verification: AccountVerificationDesignation?
    let recipientUserID: String
}

private struct ForwardTargetFailure: Identifiable, Equatable {
    let id: String
    let name: String
    let reason: String
}

private struct ForwardSendingProgress: Equatable {
    var targetIndex: Int
    var targetCount: Int
    var targetName: String
    var completedUnits: Int
    var totalUnits: Int
}

private enum ForwardPhase: Equatable {
    case picking
    case sending(ForwardSendingProgress)
    case success(chatCount: Int)
    case failures(sent: Int, successfulTargets: Int, failures: [ForwardTargetFailure])

    var isSending: Bool {
        if case .sending = self { return true }
        return false
    }
}

private struct ForwardPayloadSummary {
    let icons: [String]
    let text: String
    let includesRichMedia: Bool
}

// MARK: - Forward sheet

struct ForwardMessagesView: View {
    /// Chronological items to forward (1...N).
    let items: [ForwardPayloadItem]
    /// Called after the sheet finishes (dismissed or sent). sentCount = number of messages
    /// successfully queued across all targets (0 = cancelled/failed).
    let onComplete: (_ sentCount: Int) -> Void

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var selectedRowIDs: Set<String> = []
    @State private var showCapNotice = false
    @State private var phase: ForwardPhase = .picking
    @State private var didComplete = false
    @State private var totalSentSoFar = 0

    private static let maxTargets = 5

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .picking:
                    pickerList
                case let .sending(progress):
                    sendingView(progress)
                case let .success(chatCount):
                    successView(chatCount: chatCount)
                case let .failures(sent, successfulTargets, failures):
                    failureView(sent: sent, successfulTargets: successfulTargets, failures: failures)
                }
            }
            .navigationTitle("Forward to")
            .navigationBarTitleDisplayMode(.inline)
            .background(KitColor.canvas)
        }
        .tint(KitColor.green)
        .interactiveDismissDisabled(phase.isSending)
        .onDisappear {
            // Covers swipe-to-dismiss; `completeAndDismiss` has already run for
            // every explicit exit and keeps this a no-op in those cases.
            guard !didComplete else { return }
            didComplete = true
            onComplete(totalSentSoFar)
        }
    }

    // MARK: Picker

    private var pickerList: some View {
        let rows = eligibleRows()
        let identityContext = model.phoneIdentityContext
        let visibleChats = rows.chats.filter { matchesQuery($0, context: identityContext) }
        let visibleContacts = rows.contacts.filter { matchesQuery($0, context: identityContext) }
        let summary = payloadSummary

        return List {
            Section {
                HStack(spacing: 12) {
                    HStack(spacing: 6) {
                        ForEach(summary.icons, id: \.self) { icon in
                            Image(systemName: icon)
                                .font(.system(size: 15, weight: .semibold))
                        }
                    }
                    .foregroundStyle(KitColor.green)
                    Text(summary.text)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(KitColor.primaryText)
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Forwarding \(summary.text)")
            } header: {
                Text("Forwarding")
            } footer: {
                if summary.includesRichMedia {
                    Text("Voice notes, videos, and documents can only be forwarded to recipients on the latest Kit Pay")
                }
            }

            if visibleChats.isEmpty && visibleContacts.isEmpty {
                Section {
                    ContentUnavailableView(
                        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "No chats yet"
                            : "No matches",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text(
                            query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? "Start a chat with a Kit Pay contact first, then forward messages here."
                                : "Try another name, phone, or @kittag."
                        )
                    )
                }
            }

            if !visibleChats.isEmpty {
                Section("Chats") {
                    ForEach(visibleChats) { row in
                        targetRow(row)
                    }
                }
            }

            if !visibleContacts.isEmpty {
                Section("Contacts") {
                    ForEach(visibleContacts) { row in
                        targetRow(row)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(KitColor.canvas)
        .searchable(text: $query, prompt: "Name, phone or @kittag")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { completeAndDismiss(0) }
            }
        }
        .safeAreaInset(edge: .bottom) { forwardBar }
    }

    private func targetRow(_ row: ForwardTargetRow) -> some View {
        let isSelected = selectedRowIDs.contains(row.id)
        return Button {
            toggleSelection(row.id)
        } label: {
            HStack(spacing: 12) {
                RemoteAvatarView(
                    name: row.displayName,
                    avatarURL: row.avatarURL,
                    size: 44
                )
                VStack(alignment: .leading, spacing: 3) {
                    VerifiedAccountNameLabel(designation: row.verification) {
                        Text(row.displayName)
                            .font(.headline)
                            .foregroundStyle(KitColor.primaryText)
                    }
                    Text(row.subtitle)
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
        .accessibilityLabel(row.displayName)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint("Toggles forwarding to this chat")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var forwardBar: some View {
        VStack(spacing: 8) {
            if showCapNotice {
                Text("You can forward to up to \(Self.maxTargets) chats at a time.")
                    .font(.footnote)
                    .foregroundStyle(KitColor.secondaryText)
                    .transition(.opacity)
            }
            if !model.secureMessagingAvailable {
                Text("Secure messaging is unavailable right now.")
                    .font(.footnote)
                    .foregroundStyle(KitColor.secondaryText)
            }
            Button {
                startForwarding()
            } label: {
                Text(forwardButtonTitle)
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(KitColor.green)
            .disabled(
                selectedRowIDs.isEmpty
                    || items.isEmpty
                    || !model.secureMessagingAvailable
            )
            .accessibilityLabel(forwardButtonTitle)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .kitGlass(cornerRadius: 24, shadow: false)
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private var forwardButtonTitle: String {
        switch selectedRowIDs.count {
        case 0, 1: "Forward"
        default: "Forward to \(selectedRowIDs.count) chats"
        }
    }

    // MARK: Sending / summary phases

    private func sendingView(_ progress: ForwardSendingProgress) -> some View {
        VStack(spacing: 16) {
            ProgressView(
                value: Double(progress.completedUnits),
                total: Double(max(progress.totalUnits, 1))
            )
            .progressViewStyle(.linear)
            .tint(KitColor.green)
            Text("Forwarding \(progress.targetIndex) of \(progress.targetCount)…")
                .font(.headline)
                .foregroundStyle(KitColor.primaryText)
            Text(progress.targetName)
                .font(.subheadline)
                .foregroundStyle(KitColor.secondaryText)
        }
        .padding(28)
        .kitGlass(cornerRadius: 28)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KitColor.canvas)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Forwarding \(progress.targetIndex) of \(progress.targetCount), to \(progress.targetName)"
        )
    }

    private func successView(chatCount: Int) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52, weight: .semibold))
                .foregroundStyle(KitColor.green)
            Text("Forwarded to \(chatCount) \(chatCount == 1 ? "chat" : "chats")")
                .font(.headline)
                .foregroundStyle(KitColor.primaryText)
        }
        .padding(28)
        .kitGlass(cornerRadius: 28)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KitColor.canvas)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Forwarded to \(chatCount) \(chatCount == 1 ? "chat" : "chats")")
    }

    private func failureView(
        sent: Int,
        successfulTargets: Int,
        failures: [ForwardTargetFailure]
    ) -> some View {
        List {
            if successfulTargets > 0 {
                Section {
                    Label(
                        "Forwarded to \(successfulTargets) \(successfulTargets == 1 ? "chat" : "chats")",
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(KitColor.green)
                    .font(.subheadline.weight(.semibold))
                }
            }
            Section {
                ForEach(failures) { failure in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Couldn't forward to \(failure.name)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(KitColor.primaryText)
                        Text(failure.reason)
                            .font(.caption)
                            .foregroundStyle(KitColor.secondaryText)
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Couldn't forward to \(failure.name). \(failure.reason)")
                }
            } header: {
                Text("Not forwarded")
            } footer: {
                if sent > 0 {
                    Text("\(sent) \(sent == 1 ? "message was" : "messages were") queued and will keep sending, even offline.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(KitColor.canvas)
        .safeAreaInset(edge: .bottom) {
            Button {
                completeAndDismiss(sent)
            } label: {
                Text("Done")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(KitColor.green)
            .padding(.horizontal, 28)
            .padding(.vertical, 10)
        }
    }

    // MARK: Payload summary

    private var payloadSummary: ForwardPayloadSummary {
        var messageCount = 0
        var mediaCounts: [KitChatMediaKind: Int] = [:]
        var icons: [String] = []
        var includesRichMedia = false
        for item in items {
            switch item {
            case .text:
                messageCount += 1
                if !icons.contains("text.bubble.fill") { icons.append("text.bubble.fill") }
            case let .media(itemID, sourceConversationID):
                // Label from the identity-resolved current row; an entry whose source row is
                // gone (or no longer a forwardable v1 attachment) labels as a generic document.
                let kind = model.secureMediaForwardKind(
                    messageID: itemID,
                    conversationId: sourceConversationID
                ) ?? .document
                mediaCounts[kind, default: 0] += 1
                if kind != .image { includesRichMedia = true }
                if !icons.contains(kind.symbolName) { icons.append(kind.symbolName) }
            }
        }
        var parts: [String] = []
        for kind in KitChatMediaKind.allCases {
            if let count = mediaCounts[kind], count > 0 {
                parts.append(pluralized(count, kind.previewLabel.lowercased()))
            }
        }
        if messageCount > 0 { parts.append(pluralized(messageCount, "message")) }
        return ForwardPayloadSummary(
            icons: icons,
            text: parts.isEmpty ? "Nothing to forward" : parts.joined(separator: ", "),
            includesRichMedia: includesRichMedia
        )
    }

    private func pluralized(_ count: Int, _ singular: String) -> String {
        "\(count) \(count == 1 ? singular : singular + "s")"
    }

    // MARK: Target resolution

    /// Every eligible destination, before search filtering. Chats keep one row per
    /// recipient (most recent conversation wins) and blocked/outbound-denied
    /// recipients never appear. Contacts are deduplicated against every eligible
    /// conversation — not only the ones matching the current search — so a person
    /// never shows up twice.
    private func eligibleRows() -> (chats: [ForwardTargetRow], contacts: [ForwardTargetRow]) {
        let directory = model.communicationContactDirectory
        let currentUserID = model.profile?.id

        var chats: [ForwardTargetRow] = []
        var coveredRecipientIDs: Set<String> = []
        let orderedConversations = model.state.conversations.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id < rhs.id
        }
        for conversation in orderedConversations {
            guard !model.isReadOnlyAppReviewDemoConversation(conversation.id) else { continue }
            let presentation = ConversationContactPresentationPolicy.presentation(
                for: conversation,
                currentUserID: currentUserID,
                contacts: directory
            )
            // Forwarding queues against one expected recipient, so only direct
            // conversations with a resolvable, sendable recipient are offered.
            guard let recipientUserID = presentation.recipientUserID,
                  model.communicationPrivacyAllowsOutbound(to: recipientUserID),
                  !model.isCommunicationBlocked(userID: recipientUserID),
                  coveredRecipientIDs.insert(recipientUserID).inserted
            else { continue }
            chats.append(
                ForwardTargetRow(
                    id: "chat:\(conversation.id)",
                    kind: .conversation(conversation),
                    displayName: presentation.displayName,
                    subtitle: presentation.contact?.phone.forwardingNilIfBlank ?? "Chat on Kit Pay",
                    avatarURL: presentation.avatarURL,
                    verification: presentation.verification,
                    recipientUserID: recipientUserID
                )
            )
        }

        // `communicationContactDirectory` already excludes recipients that
        // outbound privacy denies, so no additional block filtering is needed.
        let sections = KitUserDirectorySearch.sections(
            localContacts: directory,
            remoteResults: [],
            query: "",
            context: model.phoneIdentityContext,
            excludingUserID: currentUserID
        )
        var contacts: [ForwardTargetRow] = []
        var seenRecipientIDs = coveredRecipientIDs
        for contact in sections.kitPay {
            guard let recipientUserID = ContactRecipientDirectory.recipientUserId(for: contact),
                  seenRecipientIDs.insert(recipientUserID).inserted
            else { continue }
            contacts.append(
                ForwardTargetRow(
                    id: "contact:\(recipientUserID)",
                    kind: .contact(contact),
                    displayName: contact.name,
                    subtitle: contact.phone.forwardingNilIfBlank ?? "Kit Pay member",
                    avatarURL: contact.avatarURL,
                    verification: contact.verification?.designation,
                    recipientUserID: recipientUserID
                )
            )
        }
        return (chats, contacts)
    }

    private func matchesQuery(_ row: ForwardTargetRow, context: PhoneIdentityContext) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        switch row.kind {
        case .conversation:
            return row.displayName.localizedStandardContains(trimmed)
                || row.subtitle.localizedStandardContains(trimmed)
        case let .contact(contact):
            return ContactRecipientDirectory.matches(contact, query: query, context: context)
        }
    }

    private func existingDirectConversation(with recipientUserID: String) -> Conversation? {
        guard let localUserID = forwardCanonicalUserID(model.profile?.id) else { return nil }
        let directParticipants = Set([localUserID, recipientUserID])
        return model.state.conversations
            .filter { conversation in
                // A two-member GROUP must never absorb a forward addressed to the person.
                !conversation.isGroup
                    && Set(conversation.participantUserIds.compactMap {
                        forwardCanonicalUserID($0)
                    }) == directParticipants
            }
            .max { $0.updatedAt < $1.updatedAt }
    }

    // MARK: Selection

    private func toggleSelection(_ id: String) {
        if selectedRowIDs.contains(id) {
            selectedRowIDs.remove(id)
            if selectedRowIDs.count < Self.maxTargets {
                withAnimation(.snappy(duration: 0.2)) { showCapNotice = false }
            }
        } else if selectedRowIDs.count < Self.maxTargets {
            selectedRowIDs.insert(id)
        } else {
            withAnimation(.snappy(duration: 0.2)) { showCapNotice = true }
        }
    }

    // MARK: Send engine

    private func startForwarding() {
        guard case .picking = phase, !items.isEmpty else { return }
        let rows = eligibleRows()
        let targets = (rows.chats + rows.contacts).filter { selectedRowIDs.contains($0.id) }
        guard !targets.isEmpty else { return }
        Task { @MainActor in
            await forward(to: targets)
        }
    }

    /// Processes targets sequentially and items in order within each target.
    /// A failed item never aborts the remaining items or targets. Media is
    /// loaded once per item (cache-first, re-download-capable) and deliberately
    /// re-encrypted per destination conversation — storage keys are never
    /// reused across conversations.
    @MainActor
    private func forward(to targets: [ForwardTargetRow]) async {
        let totalUnits = targets.count * items.count
        var completedUnits = 0
        var totalSent = 0
        var successfulTargets = 0
        var failures: [ForwardTargetFailure] = []

        targetLoop: for (index, target) in targets.enumerated() {
            func publishProgress() {
                phase = .sending(
                    ForwardSendingProgress(
                        targetIndex: index + 1,
                        targetCount: targets.count,
                        targetName: target.displayName,
                        completedUnits: completedUnits,
                        totalUnits: totalUnits
                    )
                )
            }
            publishProgress()

            var pendingItems = items
            var sentForTarget = 0
            var itemFailureReasons: [String] = []
            let recipientUserID = target.recipientUserID
            let conversationID: String
            let title: String

            switch target.kind {
            case let .conversation(conversation):
                conversationID = conversation.id
                title = conversation.title

            case let .contact(contact):
                title = contact.name
                let firstTextIndex = pendingItems.firstIndex {
                    if case .text = $0 { return true }
                    return false
                }
                if let firstTextIndex,
                   case let .text(_, body) = pendingItems[firstTextIndex] {
                    // A bare contact needs a server-issued conversation first;
                    // the first text item creates (or idempotently replays) it.
                    let result = await model.queueDirectMessageResult(
                        recipientId: recipientUserID,
                        title: title,
                        body: body,
                        clientMessageID: UUID()
                    )
                    completedUnits += 1
                    if let result {
                        conversationID = result.conversation.id
                        pendingItems.remove(at: firstTextIndex)
                        sentForTarget += 1
                        totalSent += 1
                        publishProgress()
                    } else {
                        completedUnits += max(0, pendingItems.count - 1)
                        failures.append(
                            ForwardTargetFailure(
                                id: target.id,
                                name: target.displayName,
                                reason: model.lastError ?? "Couldn't start this chat."
                            )
                        )
                        continue targetLoop
                    }
                } else if let existing = existingDirectConversation(with: recipientUserID) {
                    // Media-only payload: there is no direct-media-thread API,
                    // so reuse the newest existing direct conversation.
                    conversationID = existing.id
                } else {
                    completedUnits += pendingItems.count
                    failures.append(
                        ForwardTargetFailure(
                            id: target.id,
                            name: target.displayName,
                            reason: "Needs an existing chat. Send them a message first, then forward."
                        )
                    )
                    continue targetLoop
                }
            }

            for item in pendingItems {
                publishProgress()
                switch item {
                case let .text(_, body):
                    let queued = await model.queueMessage(
                        conversationId: conversationID,
                        title: title,
                        recipientId: recipientUserID,
                        body: body,
                        clientMessageID: UUID(),
                        draftClearVersion: nil
                    )
                    if queued {
                        sentForTarget += 1
                        totalSent += 1
                    } else {
                        itemFailureReasons.append(model.lastError ?? "Couldn't forward this message.")
                    }

                case let .media(itemID, sourceConversationID):
                    do {
                        // Re-resolved for EVERY destination: each load revalidates account
                        // ownership and the full current source row and returns the bytes
                        // together with the MIME type and caption they belong to (the loader's
                        // own caches make repeats cheap). One earlier load is never authority
                        // for the rest of the fan-out — a source deleted or replaced mid-loop
                        // stops forwarding at the next target instead of replaying stale
                        // plaintext from a memo.
                        let loadedMedia = try await model.loadSecureMediaItem(
                            messageID: itemID,
                            conversationId: sourceConversationID,
                            itemIndex: nil
                        )
                        let queued = await model.queueMediaMessage(
                            conversationId: conversationID,
                            title: title,
                            recipientId: recipientUserID,
                            mediaData: loadedMedia.data,
                            mediaType: loadedMedia.mediaType,
                            caption: loadedMedia.caption,
                            submittedDraftBody: nil,
                            draftClearVersion: nil
                        )
                        if queued {
                            sentForTarget += 1
                            totalSent += 1
                        } else {
                            let kind = KitChatMediaKind(mediaType: loadedMedia.mediaType)
                            itemFailureReasons.append(
                                model.lastError
                                    ?? "Couldn't forward this \(kind.previewLabel.lowercased())."
                            )
                        }
                    } catch let urlError as URLError where urlError.code == .notConnectedToInternet {
                        itemFailureReasons.append("Available when online.")
                    } catch is SecureMediaAttachmentError {
                        itemFailureReasons.append("This attachment can't be forwarded.")
                    } catch {
                        itemFailureReasons.append(error.localizedDescription)
                    }
                }
                completedUnits += 1
            }

            if sentForTarget > 0 { successfulTargets += 1 }
            if let reason = itemFailureReasons.first {
                failures.append(
                    ForwardTargetFailure(
                        id: target.id,
                        name: target.displayName,
                        reason: reason
                    )
                )
            }
        }

        totalSentSoFar = totalSent
        if failures.isEmpty {
            phase = .success(chatCount: successfulTargets)
            try? await Task.sleep(nanoseconds: 800_000_000)
            completeAndDismiss(totalSent)
        } else {
            phase = .failures(
                sent: totalSent,
                successfulTargets: successfulTargets,
                failures: failures
            )
        }
    }

    // MARK: Completion

    @MainActor
    private func completeAndDismiss(_ sentCount: Int) {
        guard !didComplete else { return }
        didComplete = true
        totalSentSoFar = sentCount
        dismiss()
        onComplete(sentCount)
    }
}

// MARK: - File-private helpers

private func forwardCanonicalUserID(_ rawValue: String?) -> String? {
    guard let rawValue,
          let id = UUID(uuidString: rawValue.trimmingCharacters(in: .whitespacesAndNewlines))
    else { return nil }
    return id.uuidString.lowercased()
}

private extension String {
    var forwardingNilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
