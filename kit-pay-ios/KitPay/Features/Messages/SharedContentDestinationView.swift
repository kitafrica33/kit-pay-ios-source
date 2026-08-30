import SwiftUI

/// The one question the share extension cannot answer: which chat.
///
/// Everything else has already happened by the time this appears — the files are in Kit Pay's own
/// container after the customer returns from the extension. Choosing here does not send anything;
/// it opens that chat with the share already attached to the composer, so the last word on what
/// goes out, and whether to say something with it, still belongs to the person sending it.
struct SharedContentDestinationView: View {
    let batch: SharedInboxBatch
    let onChoose: (Conversation) -> Void
    let onCancel: () -> Void

    @EnvironmentObject private var model: AppModel
    @State private var query = ""

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Send to")
                .navigationBarTitleDisplayMode(.inline)
                .background(KitColor.canvas)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                    }
                }
        }
        .tint(KitColor.green)
    }

    @ViewBuilder
    private var content: some View {
        let destinations = self.destinations

        List {
            Section {
                sharePreview
                if let requestedDestinationNote {
                    Label(requestedDestinationNote, systemImage: "clock.arrow.circlepath")
                        .font(.footnote)
                        .foregroundStyle(KitColor.secondaryText)
                }
            } header: {
                Text("Shared with Kit Pay")
            } footer: {
                Text("Attachments are encrypted end to end when you send them.")
            }

            if destinations.isEmpty {
                Section {
                    ContentUnavailableView(
                        trimmedQuery.isEmpty ? "No chats yet" : "No matches",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text(
                            trimmedQuery.isEmpty
                                ? "Start a chat in Kit Pay first, then share into it."
                                : "Try another name."
                        )
                    )
                }
            } else {
                Section("Chats") {
                    ForEach(destinations) { destination in
                        destinationRow(destination)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(KitColor.canvas)
        .searchable(text: $query, prompt: "Search chats")
    }

    // MARK: What is being shared

    private var sharePreview: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(previewSymbols, id: \.self) { symbol in
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .semibold))
                }
            }
            .foregroundStyle(KitColor.green)

            VStack(alignment: .leading, spacing: 3) {
                Text(SharedInboxPolicy.summary(
                    itemCount: batch.items.count,
                    hasText: batch.text != nil
                ))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(KitColor.primaryText)

                if let detail = previewDetail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(KitColor.secondaryText)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var previewSymbols: [String] {
        var symbols: [String] = []
        for item in batch.items {
            let symbol = KitChatMediaKind(mediaType: item.mediaType).symbolName
            if !symbols.contains(symbol) { symbols.append(symbol) }
        }
        if batch.text != nil, !symbols.contains("text.bubble.fill") {
            symbols.append("text.bubble.fill")
        }
        return symbols.isEmpty ? ["doc.fill"] : symbols
    }

    /// The most useful second line: the filename when there is exactly one file, the shared link or
    /// text when there is no file, and nothing at all when a count already says it.
    private var previewDetail: String? {
        if batch.items.count == 1 { return batch.items[0].displayName }
        if batch.items.isEmpty { return batch.text }
        return nil
    }

    private var requestedDestinationNote: String? {
        guard let destination = batch.destination else { return nil }
        if destination.kind == .contact {
            return "Starting a chat with \(destination.displayName) when connected. You can choose another chat below."
        }
        return "That selected chat is no longer available. Choose another chat below."
    }

    // MARK: Destinations

    private struct SharedContentDestination: Identifiable {
        let id: String
        let conversation: Conversation
        let displayName: String
        let avatarURL: String?
        let verification: AccountVerificationDesignation?
        let isGroup: Bool
        let subtitle: String
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every chat the customer could put this in, most recently active first — groups included,
    /// because a group chat is exactly where a photo worth sharing usually belongs.
    private var destinations: [SharedContentDestination] {
        let directory = model.contactDirectory
        let currentUserID = model.profile?.id
        return ConversationListPolicy
            .ordered(model.state.conversations, pinnedIds: model.pinnedConversationIds)
            .compactMap { conversation -> SharedContentDestination? in
                guard !model.isReadOnlyAppReviewDemoConversation(conversation.id) else {
                    return nil
                }
                let identity = ConversationContactPresentationPolicy.presentation(
                    for: conversation,
                    currentUserID: currentUserID,
                    contacts: directory
                )
                guard model.sharedInboxConversationIsEligible(conversation) else { return nil }
                return SharedContentDestination(
                    id: conversation.id,
                    conversation: conversation,
                    displayName: identity.displayName,
                    avatarURL: identity.avatarURL,
                    verification: identity.verification,
                    isGroup: conversation.isGroup,
                    subtitle: conversation.isGroup
                        ? "\(conversation.participantUserIds.count) members"
                        : "Chat on Kit Pay"
                )
            }
            .filter { destination in
                trimmedQuery.isEmpty
                    || destination.displayName.localizedStandardContains(trimmedQuery)
            }
    }

    private func destinationRow(_ destination: SharedContentDestination) -> some View {
        Button {
            onChoose(destination.conversation)
        } label: {
            HStack(spacing: 12) {
                if destination.isGroup {
                    GroupAvatarView(
                        title: destination.displayName,
                        photoURL: destination.avatarURL,
                        size: 44
                    )
                } else {
                    RemoteAvatarView(
                        name: destination.displayName,
                        avatarURL: destination.avatarURL,
                        size: 44
                    )
                }
                VStack(alignment: .leading, spacing: 3) {
                    VerifiedAccountNameLabel(designation: destination.verification) {
                        Text(destination.displayName)
                            .font(.headline)
                            .foregroundStyle(KitColor.primaryText)
                            .lineLimit(1)
                    }
                    Text(destination.subtitle)
                        .font(.caption)
                        .foregroundStyle(KitColor.secondaryText)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(KitColor.secondaryText.opacity(0.6))
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(destination.displayName)
        .accessibilityHint("Opens this chat with the shared items attached")
    }
}
