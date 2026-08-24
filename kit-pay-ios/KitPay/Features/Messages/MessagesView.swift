import Contacts
import ContactsUI
import ImageIO
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum ConversationListFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case unread
    case pinned

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .unread: "Unread"
        case .pinned: "Pinned"
        }
    }
}

enum ConversationListFilterPolicy {
    static func apply(
        _ filter: ConversationListFilter,
        to conversations: [Conversation],
        pinnedIDs: Set<String> = []
    ) -> [Conversation] {
        conversations.filter { includes($0, in: filter, pinnedIDs: pinnedIDs) }
    }

    static func includes(
        _ conversation: Conversation,
        in filter: ConversationListFilter,
        pinnedIDs: Set<String> = []
    ) -> Bool {
        switch filter {
        case .all:
            true
        case .unread:
            conversation.unreadCount > 0
        case .pinned:
            pinnedIDs.contains(conversation.id)
        }
    }
}

struct MessagesView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.rootTabBarClearance) private var rootTabBarClearance
    @StateObject private var callMedia = CallMediaCoordinator.shared
    @ObservedObject private var callTransport = CallMediaCoordinator.shared.media
    @Binding var isConversationPresented: Bool
    @State private var navigationPath: [Conversation] = []
    @State private var showNewMessage = false
    @State private var newMessageContact: WalletContactDTO?
    @State private var newMessagePresentationID = UUID()
    @State private var queuedNewMessageConversation: Conversation?
    @State private var showGlobalSearch = false
    @State private var pendingSearchConversation: Conversation?
    @State private var pendingSearchContact: WalletContactDTO?
    @State private var selectedFilter: ConversationListFilter = .all
    @State private var showBackupSettings = false
    @State private var isSelectingChats = false
    @State private var selectedConversationIDs: Set<String> = []
    @State private var confirmDeleteConversationIDs: Set<String>?

    private var allConversations: [Conversation] {
        ConversationListPolicy.ordered(
            model.state.conversations,
            pinnedIds: model.pinnedConversationIds
        )
    }

    private var conversations: [Conversation] {
        ConversationListFilterPolicy.apply(
            selectedFilter,
            to: allConversations,
            pinnedIDs: model.pinnedConversationIds
        )
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            chatList
                .background(KitColor.canvas)
                .safeAreaInset(edge: .top, spacing: 0) { listHeader }
                // The root tab bar is a floating overlay that reserves no safe area, so the
                // selection capsule pads itself by the published clearance to float just above
                // the glass menu instead of landing underneath it.
                .overlay(alignment: .bottom) {
                    if isSelectingChats {
                        chatSelectionActionBar
                            .padding(.bottom, rootTabBarClearance > 0 ? rootTabBarClearance : 6)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .navigationTitle(isSelectingChats ? "Select chats" : "Chats")
                // Inline keeps the title up in the bar: the large collapsing variant scrolls
                // beneath the pinned opaque search header and reads as a hidden title.
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { listToolbar }
                .navigationDestination(for: Conversation.self) { conversation in
                    ConversationView(conversation: conversation)
                        .id(conversation.id)
                        .onAppear { isConversationPresented = true }
                        .onDisappear { isConversationPresented = false }
                }
                .sheet(
                    isPresented: $showNewMessage,
                    onDismiss: finishNewMessagePresentation
                ) {
                    let presentationID = newMessagePresentationID
                    NewMessageSheet(initialContact: newMessageContact) { conversation in
                        guard showNewMessage,
                              newMessagePresentationID == presentationID
                        else { return }
                        queuedNewMessageConversation = conversation
                        showNewMessage = false
                    }
                }
                .sheet(isPresented: $showBackupSettings) {
                    NavigationStack { ChatBackupSettingsView() }
                        .environmentObject(model)
                        .presentationBackground(.ultraThinMaterial)
                }
                .fullScreenCover(
                    isPresented: $showGlobalSearch,
                    onDismiss: finishGlobalSearch
                ) {
                    MessageGlobalSearchView(
                        selectConversation: { conversation in
                            pendingSearchConversation = conversation
                            showGlobalSearch = false
                        },
                        selectContact: { contact in
                            if let conversation = existingDirectConversation(for: contact) {
                                pendingSearchConversation = conversation
                            } else {
                                pendingSearchContact = contact
                            }
                            showGlobalSearch = false
                        }
                    )
                    .environmentObject(model)
                }
                .confirmationDialog(
                    deleteChatsTitle,
                    isPresented: Binding(
                        get: { confirmDeleteConversationIDs != nil },
                        set: { if !$0 { confirmDeleteConversationIDs = nil } }
                    ),
                    titleVisibility: .visible
                ) {
                    Button("Delete from this iPhone", role: .destructive) {
                        if let ids = confirmDeleteConversationIDs {
                            Task {
                                await model.deleteConversationsLocally(ids)
                                finishChatSelection()
                            }
                        }
                        confirmDeleteConversationIDs = nil
                    }
                    Button("Cancel", role: .cancel) { confirmDeleteConversationIDs = nil }
                } message: {
                    Text("Messages stay end-to-end encrypted for the other person. This only removes them from this iPhone.")
                }
        }
        .onChange(of: navigationPath) { _, path in
            isConversationPresented = !path.isEmpty
            // Opening a chat the active filter would hide (a brand-new chat under "Unread",
            // a chat that was just read) must not make it vanish from the list on return.
            if let current = path.last,
               !ConversationListFilterPolicy.includes(
                   current,
                   in: selectedFilter,
                   pinnedIDs: model.pinnedConversationIds
               ) {
                selectedFilter = .all
            }
        }
        .onChange(of: model.messageConversationNavigationRequest) { _, _ in
            applyMessageNotificationNavigation()
        }
        .onChange(of: model.state.conversations) { _, _ in
            applyMessageNotificationNavigation()
        }
        .onAppear {
            isConversationPresented = !navigationPath.isEmpty
            applyMessageNotificationNavigation()
        }
        .onDisappear { isConversationPresented = false }
    }

    private var deleteChatsTitle: String {
        let count = confirmDeleteConversationIDs?.count ?? 0
        return count == 1 ? "Delete this chat?" : "Delete \(count) chats?"
    }

    // MARK: List content

    @ViewBuilder
    private var chatList: some View {
        // One pass over messages/contacts per render instead of per row keeps taps responsive
        // in long histories (the old per-row scan was the source of the delayed-tap defect).
        let lastByConversation = latestMessagesByConversation()
        let visibleConversations = conversations

        if model.state.conversations.isEmpty {
            // A fresh device with no chats is exactly when the iCloud restore offer matters most.
            VStack(spacing: 0) {
                if let backup = model.availableBackupToRestore {
                    restoreBanner(backup)
                        .padding(.horizontal, 14)
                        .padding(.top, 6)
                }
                ContentUnavailableView {
                    Label(
                        model.secureMessagingAvailable ? "No chats yet" : "Messages temporarily unavailable",
                        systemImage: model.secureMessagingAvailable ? "message" : "lock.fill"
                    )
                } description: {
                    Text("Messages are end-to-end encrypted.")
                } actions: {
                    Button("New message") { openNewMessage() }
                        .buttonStyle(.borderedProminent)
                }
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if let backup = model.availableBackupToRestore {
                        restoreBanner(backup)
                            .padding(.horizontal, 14)
                            .padding(.top, 6)
                            .padding(.bottom, 10)
                    }

                    filterChips
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)

                    if visibleConversations.isEmpty {
                        emptyFilterState
                            .padding(.top, 40)
                    } else {
                        ForEach(visibleConversations) { conversation in
                            let identity = ConversationContactPresentationPolicy.presentation(
                                for: conversation,
                                currentUserID: model.profile?.id,
                                contacts: model.contactDirectory
                            )
                            let context = ChatRowContext(
                                lastMessage: lastByConversation[conversation.id],
                                displayName: identity.displayName,
                                avatarURL: identity.avatarURL,
                                isPinned: model.pinnedConversationIds.contains(conversation.id),
                                isMuted: model.mutedConversationIds.contains(conversation.id),
                                isSelecting: isSelectingChats,
                                isSelected: selectedConversationIDs.contains(conversation.id),
                                activeCallLabel: ConversationCallIndicatorPolicy.label(
                                    for: conversation.id,
                                    activeCall: callMedia.activeCall,
                                    isConnected: callMedia.state == .connected,
                                    hasRemoteParticipant: callTransport.hasRemoteParticipant
                                ),
                                isVideoCall: callMedia.activeCall?.video == true
                            )
                            chatRow(conversation, context: context)
                            if conversation.id != visibleConversations.last?.id {
                                Divider()
                                    .padding(.leading, 80)
                                    .opacity(0.45)
                            }
                        }
                    }
                }
                .padding(.bottom, RootTabBarLayoutPolicy.pageBottomPadding)
            }
            .rootTabBarScrollClearance()
        }
    }

    private var filterChips: some View {
        HStack(spacing: 8) {
            ForEach(ConversationListFilter.allCases) { filter in
                let selected = selectedFilter == filter
                Button {
                    withAnimation(.snappy(duration: 0.2)) { selectedFilter = filter }
                } label: {
                    HStack(spacing: 5) {
                        Text(filter.title)
                        if filter == .unread, totalUnreadConversations > 0 {
                            Text("\(totalUnreadConversations)")
                                .font(.caption2.bold())
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(selected ? KitColor.navy : KitColor.secondaryText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background {
                        if selected {
                            Capsule().fill(KitColor.paleGreen)
                        }
                    }
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(.white.opacity(selected ? 0.75 : 0.5), lineWidth: 0.7)
                            .allowsHitTesting(false)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(filter.title) chats")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer()
        }
    }

    private var emptyFilterState: some View {
        Group {
            switch selectedFilter {
            case .all:
                EmptyView()
            case .unread:
                ContentUnavailableView(
                    "You're all caught up",
                    systemImage: "checkmark.message",
                    description: Text("No unread chats right now.")
                )
            case .pinned:
                ContentUnavailableView(
                    "No pinned chats",
                    systemImage: "pin",
                    description: Text("Touch and hold a chat to pin it to the top.")
                )
            }
        }
    }

    private func restoreBanner(_ backup: MessageBackupSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "lock.icloud.fill")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(KitColor.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Restore your chats")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(KitColor.navy)
                    Text("Encrypted backup from \(backup.deviceName) · \(backup.messageCount) messages")
                        .font(.caption)
                        .foregroundStyle(KitColor.secondaryText)
                }
                Spacer(minLength: 6)
            }
            HStack(spacing: 10) {
                Button {
                    Task { _ = await model.restoreMessagesFromBackup() }
                } label: {
                    Group {
                        if model.isRestoringMessages {
                            ProgressView().tint(.white)
                        } else {
                            Text("Restore")
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(KitColor.green, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(model.isRestoringMessages)

                Button("Not now") {
                    model.availableBackupToRestore = nil
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(KitColor.secondaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .kitGlass(cornerRadius: 22, tint: KitColor.paleGreen, shadow: false)
    }

    // MARK: Header (search + live call)

    private var listHeader: some View {
        VStack(spacing: 8) {
            Button {
                showGlobalSearch = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Search")
                        .font(.body)
                    Spacer()
                }
                .foregroundStyle(KitColor.secondaryText)
                .padding(.horizontal, 15)
                .frame(height: 44)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(.white.opacity(0.68), lineWidth: 0.7)
                        .allowsHitTesting(false)
                }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search chats, contacts, and messages")

            // The app-wide full-width call strip (CallOverlayWindow) is the single in-call
            // indicator; a second pill here would stack two banners on this screen.
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 9)
        .background(KitColor.canvas)
    }

    @ToolbarContentBuilder
    private var listToolbar: some ToolbarContent {
        if isSelectingChats {
            ToolbarItem(placement: .topBarLeading) {
                Text("\(selectedConversationIDs.count) selected")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KitColor.secondaryText)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { finishChatSelection() }
                    .font(.body.weight(.semibold))
            }
        } else {
            ToolbarItem(placement: .topBarLeading) {
                ConnectivityPill(
                    isOnline: model.isOnline,
                    queuedCount: model.queuedCount,
                    inBar: true
                )
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button {
                        withAnimation(.snappy(duration: 0.22)) { isSelectingChats = true }
                    } label: {
                        Label("Select chats", systemImage: "checkmark.circle")
                    }
                    Button {
                        showBackupSettings = true
                    } label: {
                        Label("Chats & backup", systemImage: "lock.icloud")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(KitColor.navy)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .accessibilityLabel("Chat options")
                GlassIconButton(systemName: "square.and.pencil", inBar: true) {
                    openNewMessage()
                }
            }
        }
    }

    // MARK: Rows

    private struct ChatRowContext {
        let lastMessage: LocalMessage?
        let displayName: String
        let avatarURL: String?
        let isPinned: Bool
        let isMuted: Bool
        let isSelecting: Bool
        let isSelected: Bool
        let activeCallLabel: String?
        let isVideoCall: Bool
    }

    @ViewBuilder
    private func chatRow(_ conversation: Conversation, context: ChatRowContext) -> some View {
        if context.isSelecting {
            Button {
                toggleChatSelection(conversation.id)
            } label: {
                chatRowContent(conversation, context: context)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(context.isSelected ? .isSelected : [])
        } else {
            NavigationLink(value: conversation) {
                chatRowContent(conversation, context: context)
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button {
                    Task { await model.togglePinnedConversation(conversation.id) }
                } label: {
                    Label(
                        context.isPinned ? "Unpin" : "Pin",
                        systemImage: context.isPinned ? "pin.slash" : "pin"
                    )
                }
                if conversation.unreadCount > 0 {
                    Button {
                        Task { await model.markConversationsRead([conversation.id]) }
                    } label: {
                        Label("Mark as read", systemImage: "checkmark.message")
                    }
                }
                Button {
                    Task { await model.toggleMutedConversation(conversation.id) }
                } label: {
                    Label(
                        context.isMuted ? "Unmute" : "Mute",
                        systemImage: context.isMuted ? "bell" : "bell.slash"
                    )
                }
                Button {
                    withAnimation(.snappy(duration: 0.22)) {
                        isSelectingChats = true
                        selectedConversationIDs = [conversation.id]
                    }
                } label: {
                    Label("Select", systemImage: "checkmark.circle")
                }
                Divider()
                Button(role: .destructive) {
                    confirmDeleteConversationIDs = [conversation.id]
                } label: {
                    Label("Delete chat", systemImage: "trash")
                }
            }
        }
    }

    private func chatRowContent(_ conversation: Conversation, context: ChatRowContext) -> some View {
        HStack(spacing: 12) {
            if context.isSelecting {
                Image(systemName: context.isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(context.isSelected ? KitColor.green : KitColor.secondaryText.opacity(0.5))
                    .accessibilityHidden(true)
            }

            RemoteAvatarView(
                name: context.displayName,
                avatarURL: context.avatarURL,
                size: 52
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(context.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(KitColor.navy)
                        .lineLimit(1)
                    if context.isMuted {
                        Image(systemName: "bell.slash.fill")
                            .font(.caption2)
                            .foregroundStyle(KitColor.secondaryText.opacity(0.75))
                            .accessibilityLabel("Muted")
                    }
                    Spacer(minLength: 6)
                    Text(chatListTimestamp(conversation.updatedAt))
                        .font(.caption)
                        .foregroundStyle(
                            conversation.unreadCount > 0 ? KitColor.green : KitColor.secondaryText
                        )
                }

                HStack(spacing: 5) {
                    if let activeCallLabel = context.activeCallLabel {
                        Image(systemName: context.isVideoCall ? "video.fill" : "phone.fill")
                            .font(.caption2)
                            .foregroundStyle(KitColor.green)
                        Text(activeCallLabel)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(KitColor.green)
                            .lineLimit(1)
                    } else {
                        if let last = context.lastMessage, last.isOutgoing {
                            Image(systemName: deliveryIcon(last.state))
                                .font(.caption2.bold())
                                .foregroundStyle(last.state == .failed ? .red : KitColor.green)
                        }
                        if let symbol = context.lastMessage.flatMap({
                            KitChatMessagePreview.symbolName(for: $0.body)
                        }) {
                            Image(systemName: symbol)
                                .font(.caption2)
                                .foregroundStyle(KitColor.secondaryText)
                        }
                        Text(
                            context.lastMessage.map {
                                ChatMessagePresentationPolicy.previewText(for: $0)
                            }
                                ?? "End-to-end encrypted"
                        )
                        .font(.subheadline)
                        .foregroundStyle(
                            context.lastMessage?.state == .failed ? .red : KitColor.secondaryText
                        )
                        .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    if context.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(KitColor.secondaryText.opacity(0.7))
                            .accessibilityLabel("Pinned")
                    }
                    if conversation.unreadCount > 0 {
                        Text("\(conversation.unreadCount)")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .frame(minWidth: 20, minHeight: 20)
                            .background(KitColor.green, in: Capsule())
                            .accessibilityLabel("\(conversation.unreadCount) unread")
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    private var chatSelectionActionBar: some View {
        HStack(spacing: 4) {
            chatSelectionAction(title: "Read", systemImage: "checkmark.message") {
                let ids = selectedConversationIDs
                Task {
                    await model.markConversationsRead(ids)
                    finishChatSelection()
                }
            }
            chatSelectionAction(title: "Pin", systemImage: "pin") {
                // Uniform action: pin everything selected; already-pinned chats stay pinned.
                let ids = selectedConversationIDs.subtracting(model.pinnedConversationIds)
                Task {
                    for id in ids { await model.togglePinnedConversation(id) }
                    finishChatSelection()
                }
            }
            chatSelectionAction(title: "Mute", systemImage: "bell.slash") {
                let ids = selectedConversationIDs.subtracting(model.mutedConversationIds)
                Task {
                    for id in ids { await model.toggleMutedConversation(id) }
                    finishChatSelection()
                }
            }
            chatSelectionAction(title: "Delete", systemImage: "trash", role: .destructive) {
                confirmDeleteConversationIDs = selectedConversationIDs
            }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(.white.opacity(0.6), lineWidth: 0.7)
                .allowsHitTesting(false)
        }
        .shadow(color: KitColor.navy.opacity(0.12), radius: 16, y: 6)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .disabled(selectedConversationIDs.isEmpty)
        .opacity(selectedConversationIDs.isEmpty ? 0.55 : 1)
    }

    private func chatSelectionAction(
        title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                Text(title)
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(role == .destructive ? .red : KitColor.navy)
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Helpers

    private var totalUnreadConversations: Int {
        model.state.conversations.reduce(0) { $0 + ($1.unreadCount > 0 ? 1 : 0) }
    }

    private func latestMessagesByConversation() -> [String: LocalMessage] {
        var latest: [String: LocalMessage] = [:]
        latest.reserveCapacity(model.state.conversations.count)
        for message in model.state.messages {
            if let current = latest[message.conversationId],
               current.createdAt >= message.createdAt {
                continue
            }
            latest[message.conversationId] = message
        }
        return latest
    }

    private func contactsByRecipientID() -> [String: WalletContactDTO] {
        var byRecipient: [String: WalletContactDTO] = [:]
        byRecipient.reserveCapacity(model.contactDirectory.count)
        for contact in model.contactDirectory {
            guard let recipientID = ContactRecipientDirectory.recipientUserId(for: contact),
                  byRecipient[recipientID] == nil
            else { continue }
            byRecipient[recipientID] = contact
        }
        return byRecipient
    }

    private func remoteContact(
        for conversation: Conversation,
        contactsByRecipientID: [String: WalletContactDTO]
    ) -> WalletContactDTO? {
        let localUserID = canonicalUserID(model.profile?.id)
        return conversation.participantUserIds
            .compactMap { canonicalUserID($0) }
            .first { $0 != localUserID }
            .flatMap { contactsByRecipientID[$0] }
    }

    private func toggleChatSelection(_ conversationID: String) {
        if selectedConversationIDs.contains(conversationID) {
            selectedConversationIDs.remove(conversationID)
        } else {
            selectedConversationIDs.insert(conversationID)
        }
    }

    private func finishChatSelection() {
        withAnimation(.snappy(duration: 0.22)) {
            isSelectingChats = false
            selectedConversationIDs = []
        }
    }

    private func applyMessageNotificationNavigation() {
        guard let request = model.messageConversationNavigationRequest,
              let conversation = MessageNotificationConversationPolicy.conversation(
                  id: request.conversationID,
                  in: model.state.conversations
              )
        else { return }
        showNewMessage = false
        newMessageContact = nil
        newMessagePresentationID = UUID()
        queuedNewMessageConversation = nil
        showGlobalSearch = false
        pendingSearchConversation = nil
        pendingSearchContact = nil
        navigationPath = [conversation]
        isConversationPresented = true
        model.consumeMessageConversationNavigationRequest(request.id)
    }

    private func openNewMessage(contact: WalletContactDTO? = nil) {
        newMessagePresentationID = UUID()
        queuedNewMessageConversation = nil
        newMessageContact = contact
        showNewMessage = true
    }

    private func finishNewMessagePresentation() {
        newMessageContact = nil
        guard let conversation = queuedNewMessageConversation else { return }
        queuedNewMessageConversation = nil
        navigationPath = [conversation]
    }

    private func finishGlobalSearch() {
        if let conversation = pendingSearchConversation {
            pendingSearchConversation = nil
            pendingSearchContact = nil
            navigationPath.append(conversation)
            return
        }
        if let contact = pendingSearchContact {
            pendingSearchContact = nil
            openNewMessage(contact: contact)
        }
    }

    private func existingDirectConversation(for contact: WalletContactDTO) -> Conversation? {
        guard let localUserID = canonicalUserID(model.profile?.id),
              let recipientUserID = ContactRecipientDirectory.recipientUserId(for: contact)
        else { return nil }
        let directParticipants = Set([localUserID, recipientUserID])
        return model.state.conversations
            .filter { conversation in
                Set(conversation.participantUserIds.compactMap { canonicalUserID($0) })
                    == directParticipants
            }
            .max { $0.updatedAt < $1.updatedAt }
    }
}

private func chatListTimestamp(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) {
        return date.formatted(date: .omitted, time: .shortened)
    }
    if calendar.isDateInYesterday(date) {
        return "Yesterday"
    }
    if let weekAgo = calendar.date(byAdding: .day, value: -6, to: Date()), date >= weekAgo {
        return date.formatted(.dateTime.weekday(.abbreviated))
    }
    return date.formatted(date: .numeric, time: .omitted)
}

// MARK: - Global search

private struct MessageGlobalSearchView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var debouncedQuery = ""
    @FocusState private var searchIsFocused: Bool

    let selectConversation: (Conversation) -> Void
    let selectContact: (WalletContactDTO) -> Void

    var body: some View {
        let liveQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryIsSettled = liveQuery == debouncedQuery
        let results = queryIsSettled ? makeResults() : .empty
        VStack(spacing: 0) {
            searchHeader
            Divider().opacity(0.35)

            if liveQuery.nilIfBlank == nil {
                ContentUnavailableView(
                    "Search Kit Pay",
                    systemImage: "magnifyingglass",
                    description: Text("Find Kit Pay contacts, chats, and messages on this iPhone.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !queryIsSettled {
                ProgressView("Searching")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if results.isEmpty {
                ContentUnavailableView.search(text: debouncedQuery)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !results.contacts.isEmpty {
                            resultSectionTitle("Contacts")
                            ForEach(results.contacts) { contact in
                                Button { selectContact(contact) } label: {
                                    contactResultRow(contact)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        if !results.chats.isEmpty {
                            resultSectionTitle("Chats")
                            ForEach(results.chats) { hit in
                                Button { selectConversation(hit.conversation) } label: {
                                    chatResultRow(hit)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        if !results.messages.isEmpty {
                            resultSectionTitle("Messages")
                            ForEach(results.messages) { hit in
                                Button { selectConversation(hit.conversation) } label: {
                                    messageResultRow(hit)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .background(KitColor.canvas.ignoresSafeArea())
        .task {
            await Task.yield()
            searchIsFocused = true
        }
        .task(id: query) {
            do {
                try await Task.sleep(for: .milliseconds(220))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            debouncedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private var searchHeader: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 42, height: 42)
                    .contentShape(Circle())
            }
            .accessibilityLabel("Back to chats")

            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(KitColor.secondaryText)
                TextField("Search", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($searchIsFocused)
                    .submitLabel(.search)
                if !query.isEmpty {
                    Button {
                        query = ""
                        debouncedQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(KitColor.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 13)
            .frame(height: 44)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(.white.opacity(0.68), lineWidth: 0.7)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial)
    }

    private func makeResults() -> MessageGlobalSearchResults {
        guard let searchQuery = debouncedQuery.nilIfBlank else { return .empty }

        var seenRecipientIDs: Set<String> = []
        let communicationContacts = model.communicationContactDirectory
        let presentationContacts = model.contactDirectory
        let contactSections = ContactRecipientDirectory.sectionsFromOrdered(
            communicationContacts,
            query: searchQuery,
            context: model.phoneIdentityContext
        )
        let contacts = contactSections.kitPay.filter { contact in
            guard let recipientID = ContactRecipientDirectory.recipientUserId(for: contact) else {
                return false
            }
            return seenRecipientIDs.insert(recipientID).inserted
        }

        var latestMessageByConversation: [String: LocalMessage] = [:]
        latestMessageByConversation.reserveCapacity(model.state.conversations.count)
        for message in model.state.messages {
            if let current = latestMessageByConversation[message.conversationId],
               current.createdAt >= message.createdAt {
                continue
            }
            latestMessageByConversation[message.conversationId] = message
        }

        var seenConversationIDs: Set<String> = []
        let chats = model.state.conversations
            .sorted { $0.updatedAt > $1.updatedAt }
            .compactMap { conversation -> MessageGlobalChatHit? in
                let identity = ConversationContactPresentationPolicy.presentation(
                    for: conversation,
                    currentUserID: model.profile?.id,
                    contacts: presentationContacts
                )
                let lastMessage = latestMessageByConversation[conversation.id]
                let matchesIdentity = globalSearchMatches(
                    identity.displayName,
                    query: searchQuery
                )
                let matchesPreview = lastMessage.flatMap {
                    ChatMessagePresentationPolicy.searchableText(for: $0)
                }.map {
                    globalSearchMatches($0, query: searchQuery)
                } ?? false
                guard matchesIdentity || matchesPreview else { return nil }
                guard seenConversationIDs.insert(conversation.id).inserted else { return nil }
                return MessageGlobalChatHit(
                    conversation: conversation,
                    displayName: identity.displayName,
                    avatarURL: identity.avatarURL,
                    lastMessage: lastMessage
                )
            }

        let conversationsByID = Dictionary(
            model.state.conversations.map { ($0.id, $0) },
            uniquingKeysWith: { first, second in
                first.updatedAt >= second.updatedAt ? first : second
            }
        )
        var seenMessageIDs: Set<UUID> = []
        let messages = model.state.messages
            .filter { message in
                guard let searchableText = ChatMessagePresentationPolicy.searchableText(
                    for: message
                ) else { return false }
                return globalSearchMatches(searchableText, query: searchQuery)
            }
            .sorted { $0.createdAt > $1.createdAt }
            .compactMap { message -> MessageGlobalMessageHit? in
                guard seenMessageIDs.insert(message.id).inserted,
                      let conversation = conversationsByID[message.conversationId]
                else { return nil }
                let identity = ConversationContactPresentationPolicy.presentation(
                    for: conversation,
                    currentUserID: model.profile?.id,
                    contacts: presentationContacts
                )
                return MessageGlobalMessageHit(
                    message: message,
                    conversation: conversation,
                    displayName: identity.displayName,
                    avatarURL: identity.avatarURL
                )
            }

        return MessageGlobalSearchResults(
            contacts: contacts,
            chats: chats,
            messages: messages
        )
    }

    private func resultSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.title3.bold())
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 22)
            .padding(.bottom, 8)
    }

    private func contactResultRow(_ contact: WalletContactDTO) -> some View {
        let contactTag = contact.tag?.nilIfBlank
        return HStack(spacing: 13) {
            RemoteAvatarView(name: contact.name, avatarURL: contact.avatarURL, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(contact.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(contactTag.map { "@\($0)" } ?? contact.phone)
                    .font(.caption)
                    .foregroundStyle(KitColor.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    private func chatResultRow(_ hit: MessageGlobalChatHit) -> some View {
        HStack(spacing: 13) {
            RemoteAvatarView(
                name: hit.displayName,
                avatarURL: hit.avatarURL,
                size: 52
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(hit.displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(
                    hit.lastMessage.map {
                        ChatMessagePresentationPolicy.previewText(for: $0)
                    }
                        ?? "End-to-end encrypted"
                )
                    .font(.subheadline)
                    .foregroundStyle(KitColor.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(hit.conversation.updatedAt.formatted(date: .abbreviated, time: .omitted))
                .font(.caption)
                .foregroundStyle(KitColor.secondaryText)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    private func messageResultRow(_ hit: MessageGlobalMessageHit) -> some View {
        HStack(alignment: .top, spacing: 13) {
            RemoteAvatarView(
                name: hit.displayName,
                avatarURL: hit.avatarURL,
                size: 48
            )
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(hit.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(hit.message.createdAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(KitColor.secondaryText)
                }
                Text(
                    (hit.message.isOutgoing ? "You: " : "")
                        + (
                            ChatMessagePresentationPolicy.searchableText(for: hit.message)
                                ?? ChatMessagePresentationPolicy.previewText(for: hit.message)
                        )
                )
                    .font(.subheadline)
                    .foregroundStyle(KitColor.secondaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

private struct MessageGlobalSearchResults {
    let contacts: [WalletContactDTO]
    let chats: [MessageGlobalChatHit]
    let messages: [MessageGlobalMessageHit]

    static let empty = MessageGlobalSearchResults(contacts: [], chats: [], messages: [])

    var isEmpty: Bool { contacts.isEmpty && chats.isEmpty && messages.isEmpty }
}

private struct MessageGlobalChatHit: Identifiable {
    let conversation: Conversation
    let displayName: String
    let avatarURL: String?
    let lastMessage: LocalMessage?

    var id: String { conversation.id }
}

private struct MessageGlobalMessageHit: Identifiable {
    let message: LocalMessage
    let conversation: Conversation
    let displayName: String
    let avatarURL: String?

    var id: UUID { message.id }
}

private func globalSearchMatches(_ value: String, query: String) -> Bool {
    let foldedValue = value.folding(
        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
        locale: Locale(identifier: "en_US_POSIX")
    )
    let foldedQuery = query.folding(
        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
        locale: Locale(identifier: "en_US_POSIX")
    )
    return foldedValue.contains(foldedQuery)
}

enum ConversationHeaderLayoutPolicy {
    static let navigationControlDiameter: CGFloat = KitControlMetrics.barControlDiameter
    /// The profile photo's Liquid Glass lens is a true circle of exactly this diameter, matching
    /// the call controls beside it and the system back button before it.
    static let avatarControlDiameter: CGFloat = navigationControlDiameter
    static let avatarImageDiameter: CGFloat = 36
    static let baseIdentitySpacing: CGFloat = 8
    /// Separation between the profile photo and the name.
    static let identitySpacing: CGFloat = KitControlMetrics.identitySpacing(
        base: baseIdentitySpacing
    )
    /// The name truncates with an ellipsis rather than being clipped by the bar. Sized so the
    /// back button, photo, name, and the call capsule all fit a compact iPhone without the
    /// toolbar having to shrink or drop the trailing controls.
    static let maximumNameWidth: CGFloat = 160
    static let nameLineLimit = 1
    /// The audio and video controls are separate circular lenses with a deliberately compact gap.
    static let callControlSpacing: CGFloat = KitControlMetrics.controlSpacing

    /// Narrowest iPhone width Kit Pay supports on iOS 17.
    static let narrowestSupportedBarWidth: CGFloat = 375

    /// Space the bar needs for its own margins and the system back button before the identity and
    /// call controls are laid out.
    static let barChromeAllowance: CGFloat = 46

    /// Everything the bar must fit alongside the name.
    static var reservedBarWidth: CGFloat {
        barChromeAllowance
            + avatarControlDiameter
            + identitySpacing
            + (navigationControlDiameter * 2)
            + callControlSpacing
    }
}

enum SecurePhotoBubbleBorderEdge: Hashable {
    case left
    case right
    case top
    case bottom
}

enum SecurePhotoBubbleBorderPolicy {
    static let edges: Set<SecurePhotoBubbleBorderEdge> = [.left, .right, .top]
    static let lineWidth: CGFloat = 0.5
}

private struct ChatPaymentApproval: Identifiable {
    let request: PaymentRequestDTO
    let descriptor: KitPaymentMessage

    var id: String { request.id }
}

private struct ConversationDraftPersistenceTaskKey: Hashable {
    let conversationID: String
    let body: String
    let writeVersion: ConversationDraftWriteVersion?
    let didRestore: Bool
    let isSending: Bool
}

struct ConversationView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    let conversation: Conversation
    @State private var draft = ""
    @State private var showPhotoPicker = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var stagedAttachments: [ChatStagedAttachment] = []
    @State private var isLoadingAttachment = false
    @State private var attachmentLoadGeneration = 0
    @State private var isSending = false
    @State private var didRestoreDraft = false
    @State private var draftWriteVersion: ConversationDraftWriteVersion?
    @State private var immediateDraftPersistenceTask: Task<Void, Never>?
    @State private var showPaymentRequest = false
    @State private var showSendMoney = false
    @State private var showContactProfile = false
    @State private var chatPaymentApproval: ChatPaymentApproval?
    @State private var resolvingPaymentRequestID: String?
    @State private var showCameraCapture = false
    @State private var showVideoNoteCamera = false
    @State private var showDocumentImporter = false
    @State private var isSelectingMessages = false
    @State private var selectedMessageIDs: Set<UUID> = []
    @State private var showDeleteMessagesConfirmation = false
    @State private var forwardItems: [ForwardPayloadItem] = []
    @State private var showForwardSheet = false
    @State private var isNearLatestMessage = true
    @State private var unseenIncomingCount = 0
    @State private var cameraPullProgress: CGFloat = 0
    @State private var didTriggerCameraPull = false
    @State private var conversationContentHeight: CGFloat = 0
    @State private var conversationViewportHeight: CGFloat = 0
    @State private var pendingScrollTargetMessageID: UUID?
    @State private var galleryTarget: ConversationGalleryTarget?
    @State private var editorSession: MediaEditorSession?
    @State private var isSearchingMessages = false
    @State private var messageSearchQuery = ""
    @State private var searchMatchIndex = 0
    @FocusState private var isSearchFieldFocused: Bool
    @State private var incomingSoundPolicy: VisibleConversationSoundPolicy
    @StateObject private var paymentFlow = WalletFlowModel()
    /// Separate model for in-chat transfers so a draft payment request and a draft transfer
    /// can never share contacts, errors, or submission state.
    @StateObject private var sendMoneyFlow = WalletFlowModel()
    @StateObject private var chatPaymentRequests = PaymentRequestsViewModel()
    @StateObject private var chatTransfers = ChatTransfersViewModel()
    @State private var transferReverseTarget: ChatTransferReverseTarget?
    @State private var transferRejectTarget: ChatTransferRejectTarget?
    @StateObject private var voiceRecorder = VoiceNoteRecorder()
    @FocusState private var isComposerFocused: Bool

    init(conversation: Conversation) {
        self.conversation = conversation
        _incomingSoundPolicy = State(
            initialValue: VisibleConversationSoundPolicy(conversationID: conversation.id)
        )
    }

    private var messages: [LocalMessage] {
        model.state.messages
            .filter { $0.conversationId == conversation.id }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private var timelineItems: [ConversationTimelineItem] {
        ConversationTimelinePolicy.items(
            for: conversation,
            allConversations: model.state.conversations,
            currentUserID: model.profile?.id,
            messages: messages,
            calls: model.state.calls,
            dateSeparatorsRelativeTo: Date(),
            calendar: .autoupdatingCurrent,
            locale: .autoupdatingCurrent
        )
    }

    private var recipientPresentation: ConversationContactPresentation {
        ConversationContactPresentationPolicy.presentation(
            for: conversation,
            currentUserID: model.profile?.id,
            contacts: model.contactDirectory
        )
    }

    private var recipientUserID: String? {
        recipientPresentation.recipientUserID
    }

    private var paymentRecipientUserID: String? {
        ConversationTimelinePolicy.paymentRecipientUserID(
            for: conversation,
            currentUserID: model.profile?.id
        )
    }

    private var recipientContact: WalletContactDTO? {
        recipientPresentation.contact
    }

    private var recipientDisplayName: String {
        recipientPresentation.displayName
    }

    private var paymentRecipientName: String {
        recipientDisplayName
    }

    private var recipientIsBlocked: Bool {
        model.isCommunicationBlocked(userID: recipientUserID)
    }

    private var recipientCommunicationAllowed: Bool {
        model.communicationPrivacyAllowsOutbound(to: recipientUserID)
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var showsSendButton: Bool {
        isLoadingAttachment || !trimmedDraft.isEmpty || !stagedAttachments.isEmpty
    }

    private var canSendMessage: Bool {
        let hasAttachment = !stagedAttachments.isEmpty
        return model.secureMessagingAvailable
            && recipientCommunicationAllowed
            && !isSending
            && !isLoadingAttachment
            && (hasAttachment || !trimmedDraft.isEmpty)
    }

    private var cameraPullIsEligible: Bool {
        ConversationCameraPullPolicy.isEligible(
            contentHeight: conversationContentHeight,
            viewportHeight: conversationViewportHeight,
            isSelectingMessages: isSelectingMessages,
            isSearchingMessages: isSearchingMessages,
            isRecordingVoiceNote: voiceRecorder.isRecording,
            isComposerFocused: isComposerFocused
        )
    }

    private var paymentRequestPolicy: PaymentRequestPolicy {
        PaymentRequestPolicy(
            features: model.capabilities?.features,
            currentUserId: model.profile?.id,
            ownedWalletIds: Set(model.state.wallets.map(\.id))
        )
    }

    private var paymentRequestEvents: [(message: LocalMessage, descriptor: KitPaymentMessage)] {
        timelineItems.compactMap { item in
            guard case .payment(let message, let descriptor) = item,
                  descriptor.isRequest
            else { return nil }
            return (message, descriptor)
        }
    }

    private var incomingPaymentEvents: [(message: LocalMessage, descriptor: KitPaymentMessage)] {
        paymentRequestEvents.filter { !$0.message.isOutgoing }
    }

    private var incomingPaymentRequestLoadID: String {
        let descriptorMessageIDs = paymentRequestEvents.map {
            $0.message.id.uuidString.lowercased()
        }
        return "\(model.isOnline):\(descriptorMessageIDs.joined(separator: ","))"
    }

    /// The signed-in user and this conversation's peer — the only accounts a transfer event in
    /// this thread may bind to.
    private var transferPartyBinding: KitTransferPartyBinding? {
        KitTransferPartyBinding(
            currentUserID: model.profile?.id,
            peerUserID: paymentRecipientUserID
        )
    }

    private var transferAcceptanceEnabled: Bool {
        TransferAcceptancePolicy(features: model.capabilities?.features).acceptanceEnabled
    }

    /// Reloads transfer-acceptance authority whenever the set of transfer events changes (a new
    /// transfer arriving, a RESPONSE landing — which is exactly when a pending bubble's buttons
    /// go stale), capabilities arrive, or connectivity returns.
    private var transferEventLoadID: String {
        let transferMessageIDs = timelineItems.compactMap { item -> String? in
            guard case .payment(let message, let descriptor) = item,
                  descriptor.action.isTransferEvent
            else { return nil }
            return message.id.uuidString.lowercased()
        }
        return "\(model.isOnline):\(transferAcceptanceEnabled):\(transferMessageIDs.joined(separator: ","))"
    }

    private var conversationHasTransferEvents: Bool {
        timelineItems.contains { item in
            guard case .payment(_, let descriptor) = item else { return false }
            return descriptor.action == .transfer
        }
    }

    private var conversationTransferIDs: [String] {
        timelineItems.compactMap { item in
            guard case .payment(_, let descriptor) = item,
                  descriptor.action == .transfer
            else { return nil }
            return descriptor.paymentRequestId
        }
    }

    var body: some View {
        conversationLifecycle
    }

    private var conversationLayout: some View {
        // One pass per render; selection mode falls back to individual bubbles so every
        // message stays individually checkable.
        let albumMembership: [UUID: ChatMediaAlbumMembership] =
            isSelectingMessages ? [:] : ChatMediaAlbumPolicy.membership(for: messages)
        return VStack(spacing: 0) {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(spacing: 9) {
                        Label(
                            CustomerFacingMessagingCopy.encryptionAssurance,
                            systemImage: "lock.fill"
                        )
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(KitColor.secondaryText)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(maxWidth: 320)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(CustomerFacingMessagingCopy.encryptionAssurance)
                        if let paymentError = chatPaymentRequests.errorMessage {
                            paymentErrorBanner(paymentError)
                        }
                        if let transferError = chatTransfers.errorMessage {
                            paymentErrorBanner(transferError)
                        }
                        ForEach(timelineItems) { item in
                            switch item {
                            case .message(let message):
                                if case .leader(let album) = albumMembership[message.id] {
                                    albumBubble(album)
                                } else if albumMembership[message.id] != .follower {
                                    bubble(message)
                                }
                            case .payment(let message, let descriptor):
                                paymentBubble(message, descriptor: descriptor)
                            case .call(let call):
                                callBubble(call)
                            case .dateSeparator(let separator):
                                dateSeparator(separator)
                            }
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(ConversationScrollAnchor.bottom)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        GeometryReader { contentGeometry in
                            Color.clear.preference(
                                key: ConversationScrollMetricsKey.self,
                                value: ConversationScrollMetrics(
                                    contentHeight: contentGeometry.size.height,
                                    contentMaxY: contentGeometry
                                        .frame(in: .named("conversationScroll")).maxY
                                )
                            )
                        }
                    )
                }
                .coordinateSpace(name: "conversationScroll")
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .background(
                    GeometryReader { viewportGeometry in
                        Color.clear
                            .onAppear {
                                conversationViewportHeight = viewportGeometry.size.height
                            }
                            .onChange(of: viewportGeometry.size.height) { _, height in
                                conversationViewportHeight = height
                            }
                    }
                )
                .onPreferenceChange(ConversationScrollMetricsKey.self) { metrics in
                    handleScrollMetrics(metrics)
                }
                .onChange(of: timelineItems.last?.id) { _, _ in
                    // A message the user just sent always snaps to the latest position; an
                    // incoming message must never yank them away from what they are reading.
                    if messages.last?.isOutgoing == true || isNearLatestMessage {
                        scrollToBottom(using: scrollProxy)
                    }
                }
                .onChange(of: pendingScrollTargetMessageID) { _, target in
                    guard let target else { return }
                    withAnimation(.easeOut(duration: 0.25)) {
                        scrollProxy.scrollTo(
                            "message:\(target.uuidString.lowercased())",
                            anchor: .center
                        )
                    }
                    pendingScrollTargetMessageID = nil
                }
                .overlay(alignment: .bottom) {
                    if cameraPullIsEligible, cameraPullProgress > 2 {
                        cameraPullIndicator
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !isNearLatestMessage {
                        jumpToLatestButton(scrollProxy)
                    }
                }
                .animation(.snappy(duration: 0.2), value: isNearLatestMessage)
                // Playing a bubble's media would tear the audio session out from under the
                // live recorder and destroy the in-progress note.
                .allowsHitTesting(!voiceRecorder.isRecording)
            }
            .background(chatBackground)

            if isSelectingMessages {
                messageSelectionBar
            } else if isSearchingMessages {
                messageSearchBar
            } else {
                composer
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar { conversationToolbar }
    }

    private var conversationMediaPickers: some View {
        conversationLayout
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $selectedPhotoItems,
            maxSelectionCount: ConversationAttachmentStagingPolicy.maximumStagedAttachments,
            matching: .any(of: [.images, .videos])
        )
        .onChange(of: selectedPhotoItems) { _, items in
            guard !items.isEmpty else { return }
            attachmentLoadGeneration &+= 1
            let generation = attachmentLoadGeneration
            Task { await loadPickedLibraryItems(items, generation: generation) }
        }
        .fullScreenCover(isPresented: $showCameraCapture) {
            KitCameraView { output in
                showCameraCapture = false
                handleCameraOutput(output)
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showVideoNoteCamera) {
            KitCameraView(startInVideoMode: true) { output in
                showVideoNoteCamera = false
                handleCameraOutput(output)
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(item: $editorSession) { session in
            KitMediaEditorView(input: session.input) { output in
                editorSession = nil
                handleEditorOutput(output, original: session.input)
            }
        }
        .fileImporter(
            isPresented: $showDocumentImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                stageDocument(url)
            }
        }
    }

    private var conversationSheets: some View {
        conversationMediaPickers
        .sheet(isPresented: $showPaymentRequest) {
            NavigationStack {
                RequestMoneyView(
                    flow: paymentFlow,
                    preselectedContact: recipientContact,
                    preselectedRecipientUserID: paymentRecipientUserID,
                    locksRecipientSelection: true,
                    shareCreatedRequest: { request in
                        guard let paymentRecipientUserID else { return false }
                        return await model.queuePaymentRequest(
                            request,
                            recipientId: paymentRecipientUserID,
                            title: paymentRecipientName,
                            conversationId: conversation.id
                        )
                    }
                )
                .environmentObject(model)
            }
            .presentationBackground(.ultraThinMaterial)
        }
        .sheet(isPresented: $showSendMoney) {
            NavigationStack {
                SendMoneyView(
                    flow: sendMoneyFlow,
                    preselectedContact: recipientContact,
                    preselectedRecipientUserID: paymentRecipientUserID,
                    locksRecipientSelection: true,
                    shareTransferInChat: { transaction in
                        guard let paymentRecipientUserID else { return false }
                        return await model.queueTransferChatEvent(
                            transaction: transaction,
                            recipientId: paymentRecipientUserID,
                            title: recipientDisplayName,
                            conversationId: conversation.id
                        )
                    }
                )
                .environmentObject(model)
            }
            .presentationBackground(.ultraThinMaterial)
        }
        .sheet(isPresented: $showContactProfile) {
            ConversationContactProfileView(
                name: recipientDisplayName,
                contact: recipientContact,
                avatarURL: recipientPresentation.avatarURL,
                userID: recipientUserID,
                conversationID: conversation.id,
                startAudioCall: { queueCall(video: false) },
                startVideoCall: { queueCall(video: true) },
                searchChat: {
                    showContactProfile = false
                    beginMessageSearch()
                },
                showMessageInChat: { messageID in
                    showContactProfile = false
                    if galleryItems.contains(where: { $0.messageID == messageID }) {
                        // Give the sheet a beat to dismiss before presenting the cover.
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 350_000_000)
                            galleryTarget = ConversationGalleryTarget(id: messageID)
                        }
                    } else {
                        pendingScrollTargetMessageID = messageID
                    }
                }
            )
            .presentationBackground(.ultraThinMaterial)
        }
        .fullScreenCover(item: $galleryTarget) { target in
            KitMediaGalleryView(
                items: galleryItems,
                initialItemID: target.id,
                loadData: { item in
                    try await model.loadSecureMedia(
                        conversationId: item.conversationID,
                        descriptorText: item.descriptorText
                    )
                },
                showInChat: { item in
                    pendingScrollTargetMessageID = item.messageID
                },
                onDismiss: { galleryTarget = nil }
            )
            .environmentObject(model)
        }
        .sheet(isPresented: $showForwardSheet) {
            ForwardMessagesView(items: forwardItems) { sentCount in
                showForwardSheet = false
                forwardItems = []
                if sentCount > 0 { finishMessageSelection() }
            }
            .environmentObject(model)
            .presentationBackground(.ultraThinMaterial)
        }
        .sheet(item: $transferReverseTarget) { target in
            TransferReverseApprovalView(
                descriptor: target.descriptor,
                recipientName: recipientDisplayName,
                isSubmitting: chatTransfers.actionTransferId != nil,
                errorMessage: chatTransfers.errorMessage
            ) { reason, pin in
                guard transferAcceptanceEnabled else { return false }
                let reversed = await chatTransfers.reverse(
                    target.descriptor,
                    binding: transferPartyBinding,
                    reason: reason,
                    acceptanceEnabled: transferAcceptanceEnabled,
                    pin: pin,
                    isOnline: model.isOnline,
                    authorize: model.authorizeFinancialStepUp
                )
                guard reversed else { return false }
                await queueTransferResponse(
                    target.descriptor,
                    action: .reversed,
                    reason: reason
                )
                await model.refresh()
                return true
            }
            .environmentObject(model)
            .presentationBackground(.ultraThinMaterial)
        }
        .sheet(item: $transferRejectTarget) { target in
            TransferRejectApprovalView(
                descriptor: target.descriptor,
                isSubmitting: chatTransfers.actionTransferId != nil,
                errorMessage: chatTransfers.errorMessage
            ) { reason in
                guard transferAcceptanceEnabled else { return false }
                let rejected = await chatTransfers.reject(
                    target.descriptor,
                    binding: transferPartyBinding,
                    reason: reason,
                    acceptanceEnabled: transferAcceptanceEnabled,
                    isOnline: model.isOnline
                )
                guard rejected else { return false }
                await queueTransferResponse(
                    target.descriptor,
                    action: .rejected,
                    reason: reason
                )
                await model.refresh()
                return true
            }
            .presentationBackground(.ultraThinMaterial)
        }
        .sheet(item: $chatPaymentApproval) { approval in
            PaymentRequestPINView(
                request: approval.request,
                isSubmitting: chatPaymentRequests.actionRequestId == approval.request.id,
                errorMessage: chatPaymentRequests.errorMessage
            ) { pin in
                guard let wallet = model.selectedWallet else { return false }
                let paid = await chatPaymentRequests.pay(
                    approval.request,
                    from: wallet,
                    pin: pin,
                    policy: paymentRequestPolicy,
                    isOnline: model.isOnline,
                    authorize: model.authorizeFinancialStepUp
                )
                guard paid else { return false }
                if let paymentRecipientUserID,
                   let paidDescriptor = approval.descriptor.changingAction(to: .paid) {
                    _ = await model.queuePaymentEvent(
                        conversationId: conversation.id,
                        title: recipientDisplayName,
                        recipientId: paymentRecipientUserID,
                        body: paidDescriptor.encoded
                    )
                }
                await model.refresh()
                await chatPaymentRequests.load(isOnline: model.isOnline)
                return true
            }
            .presentationBackground(.ultraThinMaterial)
        }
    }

    private var conversationDeleteConfirmation: some View {
        conversationSheets
        .confirmationDialog(
            selectedMessageIDs.count == 1 ? "Delete this message?" : "Delete \(selectedMessageIDs.count) messages?",
            isPresented: $showDeleteMessagesConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete from this iPhone", role: .destructive) {
                let ids = selectedMessageIDs
                Task {
                    await model.deleteMessagesLocally(ids, conversationId: conversation.id)
                    finishMessageSelection()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes them from this iPhone only.")
        }
    }

    private var conversationTasks: some View {
        let draftPersistenceTaskKey = ConversationDraftPersistenceTaskKey(
            conversationID: conversation.id,
            body: draft,
            writeVersion: draftWriteVersion,
            didRestore: didRestoreDraft,
            isSending: isSending
        )
        return conversationDeleteConfirmation
        .task(id: messages.last?.serverMessageId) {
            await model.markConversationRead(conversation.id)
        }
        .task(id: incomingPaymentRequestLoadID) {
            guard paymentRecipientUserID != nil,
                  model.isOnline,
                  !paymentRequestEvents.isEmpty
            else { return }
            await chatPaymentRequests.load(isOnline: true)
            validateLoadedChatPaymentRequests()
        }
        .task(id: transferEventLoadID) {
            guard paymentRecipientUserID != nil,
                  model.isOnline,
                  conversationHasTransferEvents,
                  transferAcceptanceEnabled
            else { return }
            await chatTransfers.load(
                isOnline: true,
                transferIds: conversationTransferIDs
            )
            await documentObservedAutoReversals()
        }
        .task(id: draftPersistenceTaskKey) {
            guard draftPersistenceTaskKey.didRestore,
                  !draftPersistenceTaskKey.isSending,
                  let writeVersion = draftPersistenceTaskKey.writeVersion
            else { return }
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
                try Task.checkCancellation()
            } catch {
                return
            }
            _ = await model.persistConversationDraft(
                draftPersistenceTaskKey.body,
                conversationId: draftPersistenceTaskKey.conversationID,
                writeVersion: writeVersion
            )
        }
    }

    private var conversationLifecycle: some View {
        conversationTasks
        .onAppear {
            if !didRestoreDraft {
                draftWriteVersion = model.nextConversationDraftWriteVersion()
                draft = model.conversationDraft(for: conversation.id)
                didRestoreDraft = true
            }
            incomingSoundPolicy.beginVisibility(with: messages)
            model.setConversationVisible(
                conversation.id,
                visible: scenePhase == .active
            )
        }
        .onChange(of: messages) { previousMessages, updatedMessages in
            if isSelectingMessages {
                // Messages can vanish underneath a selection (remote deletion, account
                // refresh); acting on stale IDs must be impossible.
                selectedMessageIDs.formIntersection(Set(updatedMessages.map(\.id)))
            }
            if !isNearLatestMessage {
                let previousIDs = Set(previousMessages.map(\.id))
                let arrived = updatedMessages.filter {
                    !$0.isOutgoing && !previousIDs.contains($0.id)
                }.count
                if arrived > 0 { unseenIncomingCount += arrived }
            }
            if incomingSoundPolicy.consume(
                updatedMessages,
                appIsActive: scenePhase == .active
            ), !model.mutedConversationIds.contains(conversation.id) {
                IncomingMessageSoundPlayer.shared.play()
            }
        }
        .onChange(of: draft) { _, value in
            immediateDraftPersistenceTask?.cancel()
            immediateDraftPersistenceTask = nil
            let bounded = ConversationDraftPolicy.boundedBody(value)
            if bounded != value {
                draft = bounded
                return
            }
            draftWriteVersion = model.nextConversationDraftWriteVersion()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                incomingSoundPolicy.beginVisibility(with: messages)
                model.setConversationVisible(conversation.id, visible: true)
            } else {
                incomingSoundPolicy.endVisibility()
                model.setConversationVisible(conversation.id, visible: false)
                persistDraftImmediately()
            }
        }
        .onDisappear {
            incomingSoundPolicy.endVisibility()
            model.setConversationVisible(conversation.id, visible: false)
            attachmentLoadGeneration &+= 1
            isLoadingAttachment = false
            isComposerFocused = false
            voiceRecorder.cancel()
            if !isSending { persistDraftImmediately() }
        }
    }

    private func paymentErrorBanner(_ message: String) -> some View {
        Text(message)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.red)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                Color.red.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 14)
            )
    }

    @ToolbarContentBuilder
    private var conversationToolbar: some ToolbarContent {
        if isSelectingMessages {
            ToolbarItem(placement: .topBarLeading) {
                Text("\(selectedMessageIDs.count) selected")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KitColor.secondaryText)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { finishMessageSelection() }
                    .font(.body.weight(.semibold))
            }
        } else {
            ToolbarItem(placement: .topBarLeading) {
                Button { showContactProfile = true } label: {
                    // Nothing sits under the photo but the Liquid Glass: no material card, no
                    // colour wash, and no ring of our own. The lens is an exact square of
                    // `avatarControlDiameter`, so it renders as a true circle around the photo.
                    ConversationAvatarView(
                        name: recipientDisplayName,
                        avatarURL: recipientPresentation.avatarURL,
                        size: ConversationHeaderLayoutPolicy.avatarImageDiameter
                    )
                    .kitBarControlGlass(
                        diameter: ConversationHeaderLayoutPolicy.avatarControlDiameter
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(recipientDisplayName)'s profile")
            }
            // The name lives in the principal slot rather than beside the photo. A leading bar
            // item is squeezed to whatever the bar has left once the trailing controls are placed,
            // and the name was being compressed to nothing instead of truncating. The principal
            // slot is measured against the whole bar, so the name always appears and falls back to
            // an ellipsis when it is too long.
            ToolbarItem(placement: .principal) {
                Button { showContactProfile = true } label: {
                    Text(recipientDisplayName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(ConversationHeaderLayoutPolicy.nameLineLimit)
                        .truncationMode(.tail)
                        .frame(
                            maxWidth: ConversationHeaderLayoutPolicy.maximumNameWidth,
                            alignment: .leading
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(recipientDisplayName)'s profile")
            }
            ToolbarItem(placement: .topBarTrailing) {
                // Two lenses only: a third would push the name below its 150pt readable
                // minimum on the narrowest supported bar. Search lives in the contact sheet.
                KitGlassControlGroup(
                    spacing: ConversationHeaderLayoutPolicy.callControlSpacing
                ) {
                    chatCallToolbarButton(video: false)
                    chatCallToolbarButton(video: true)
                }
            }
        }
    }

    // MARK: Composer

    @ViewBuilder
    private var composer: some View {
        VStack(spacing: 8) {
            if stagedAttachments.count == 1 {
                stagedAttachmentChip(stagedAttachments[0])
            } else if stagedAttachments.count > 1 {
                stagedAttachmentRow
            }
            if let recorderError = voiceRecorder.errorMessage {
                Label(recorderError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if voiceRecorder.isRecording {
                recordingBar
            } else {
                composerRow
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider()
                .opacity(0.35)
                .allowsHitTesting(false)
        }
    }

    private var composerRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Menu {
                Button {
                    isComposerFocused = false
                    showPhotoPicker = true
                } label: {
                    Label("Photo & video library", systemImage: "photo.on.rectangle")
                }
                if KitCameraView.isCameraAvailable {
                    Button {
                        isComposerFocused = false
                        showCameraCapture = true
                    } label: {
                        Label("Camera", systemImage: "camera")
                    }
                    Button {
                        isComposerFocused = false
                        showVideoNoteCamera = true
                    } label: {
                        Label("Video note", systemImage: "video.badge.waveform")
                    }
                }
                Button {
                    isComposerFocused = false
                    showDocumentImporter = true
                } label: {
                    Label("Document", systemImage: "doc")
                }
                Button { openSendMoney() } label: {
                    Label("Send money", systemImage: "arrow.up.circle")
                }
                Button { openPaymentRequest() } label: {
                    Label("Payment request", systemImage: "banknote")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.headline.bold())
                    .foregroundStyle(KitColor.green)
                    .frame(width: 42, height: 42)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Attachments and payments")

            HStack(alignment: .bottom, spacing: 4) {
                TextField(
                    model.secureMessagingAvailable ? "Message" : "Messages temporarily unavailable",
                    text: $draft,
                    axis: .vertical
                )
                .lineLimit(1...5)
                .focused($isComposerFocused)
                .disabled(!model.secureMessagingAvailable || isSending)
                .padding(.leading, 14)
                .padding(.vertical, 10)

                if !showsSendButton {
                    Button {
                        isComposerFocused = false
                        Task { await voiceRecorder.start() }
                    } label: {
                        Image(systemName: "mic.fill")
                            .font(.headline)
                            .frame(width: 40, height: 40)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(KitColor.green)
                    .disabled(!model.secureMessagingAvailable)
                    .opacity(model.secureMessagingAvailable ? 1 : 0.5)
                    .accessibilityLabel("Record a voice note")
                    .transition(.opacity.combined(with: .scale(scale: 0.82)))
                }
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(.white.opacity(0.55), lineWidth: 0.7)
                    .allowsHitTesting(false)
            }

            if showsSendButton {
                Button(action: sendDraft) {
                    Group {
                        if isLoadingAttachment || isSending {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: stagedAttachments.isEmpty ? "paperplane.fill" : "lock.fill")
                                .font(.headline.bold())
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(KitColor.green, in: Circle())
                }
                .disabled(!canSendMessage)
                .opacity(canSendMessage ? 1 : 0.55)
                .accessibilityLabel(
                    stagedAttachments.isEmpty
                        ? "Send message"
                        : model.isOnline
                            ? "Send \(stagedAttachments.count == 1 ? "encrypted \(stagedAttachments[0].kind.previewLabel.lowercased())" : "\(stagedAttachments.count) encrypted attachments")"
                            : "Queue \(stagedAttachments.count == 1 ? "encrypted \(stagedAttachments[0].kind.previewLabel.lowercased())" : "\(stagedAttachments.count) encrypted attachments") to send when connected"
                )
                .transition(.opacity.combined(with: .scale(scale: 0.82)))
            }
        }
        .animation(.snappy(duration: 0.22), value: showsSendButton)
    }

    private var recordingBar: some View {
        HStack(spacing: 12) {
            Button {
                voiceRecorder.cancel()
            } label: {
                Image(systemName: "trash.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Discard recording")

            HStack(spacing: 10) {
                Circle()
                    .fill(.red)
                    .frame(width: 9, height: 9)
                    .opacity(Int(voiceRecorder.elapsed * 2) % 2 == 0 ? 1 : 0.25)
                Text(recordingTimeLabel)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(KitColor.navy)
                RecorderLevelWave(level: voiceRecorder.level)
                    .frame(maxWidth: .infinity)
                    .frame(height: 24)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(KitColor.green.opacity(0.4), lineWidth: 0.8)
                    .allowsHitTesting(false)
            }

            Button(action: sendVoiceNote) {
                Group {
                    if isSending {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.headline.bold())
                    }
                }
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(KitColor.green, in: Circle())
            }
            .disabled(isSending)
            .accessibilityLabel("Send voice note")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording voice note, \(recordingTimeLabel)")
    }

    private var recordingTimeLabel: String {
        let seconds = Int(voiceRecorder.elapsed)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func stagedAttachmentChip(_ attachment: ChatStagedAttachment) -> some View {
        HStack(spacing: 10) {
            if let preview = attachment.previewImage {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 62, height: 62)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                Image(systemName: attachment.kind.symbolName)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(KitColor.green)
                    .frame(width: 62, height: 62)
                    .background(KitColor.paleGreen.opacity(0.4), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(attachment.displayName)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Text(model.isOnline
                    ? "\(attachment.byteLabel) · End-to-end encrypted before upload."
                    : "\(attachment.byteLabel) · Will send securely when connected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                removeStagedAttachment(attachment.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
            }
            .accessibilityLabel("Remove attachment")
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.55), lineWidth: 0.7)
                .allowsHitTesting(false)
        }
    }

    /// Compact tiles when several attachments are staged at once.
    private var stagedAttachmentRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(stagedAttachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if let preview = attachment.previewImage {
                                Image(uiImage: preview)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                Image(systemName: attachment.kind.symbolName)
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(KitColor.green)
                            }
                        }
                        .frame(width: 62, height: 62)
                        .background(KitColor.paleGreen.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        Button {
                            removeStagedAttachment(attachment.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.body)
                                .foregroundStyle(.white, .black.opacity(0.55))
                        }
                        .padding(3)
                        .accessibilityLabel("Remove \(attachment.displayName)")
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(attachment.displayName)
                }
            }
            .padding(.vertical, 2)
        }
        .frame(height: 68)
    }

    private func removeStagedAttachment(_ id: UUID) {
        stagedAttachments.removeAll { $0.id == id }
        if stagedAttachments.isEmpty {
            attachmentLoadGeneration &+= 1
            isLoadingAttachment = false
            selectedPhotoItems = []
        }
    }

    // MARK: In-chat search

    private var messageSearchMatches: [UUID] {
        ConversationMessageSearchPolicy.matchingMessageIDs(
            query: messageSearchQuery,
            messages: messages
        )
    }

    private var currentSearchMatchID: UUID? {
        let matches = messageSearchMatches
        guard !matches.isEmpty else { return nil }
        return matches[min(max(0, searchMatchIndex), matches.count - 1)]
    }

    private var messageSearchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("Search messages & documents", text: $messageSearchQuery)
                    .focused($isSearchFieldFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { stepSearchMatch(-1) }
                if !messageSearchQuery.isEmpty {
                    Button {
                        messageSearchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(.white.opacity(0.55), lineWidth: 0.7)
                    .allowsHitTesting(false)
            }

            if !messageSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(searchMatchCounterLabel)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }

            Button { stepSearchMatch(-1) } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 42)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(KitColor.green)
            .disabled(messageSearchMatches.count < 2)
            .opacity(messageSearchMatches.count < 2 ? 0.4 : 1)
            .accessibilityLabel("Previous match")

            Button { stepSearchMatch(1) } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 42)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(KitColor.green)
            .disabled(messageSearchMatches.count < 2)
            .opacity(messageSearchMatches.count < 2 ? 0.4 : 1)
            .accessibilityLabel("Next match")

            Button("Done") { finishMessageSearch() }
                .font(.body.weight(.semibold))
                .foregroundStyle(KitColor.green)
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider()
                .opacity(0.35)
                .allowsHitTesting(false)
        }
        .onChange(of: messageSearchQuery) { _, _ in
            let matches = messageSearchMatches
            // Start from the most recent match, the same place the eye starts.
            searchMatchIndex = max(0, matches.count - 1)
            if let latest = matches.last {
                pendingScrollTargetMessageID = latest
            }
        }
    }

    private var searchMatchCounterLabel: String {
        let matches = messageSearchMatches
        guard !matches.isEmpty else { return "0 results" }
        return "\(min(searchMatchIndex, matches.count - 1) + 1) of \(matches.count)"
    }

    private func stepSearchMatch(_ delta: Int) {
        let matches = messageSearchMatches
        guard !matches.isEmpty else { return }
        searchMatchIndex = (searchMatchIndex + delta + matches.count) % matches.count
        pendingScrollTargetMessageID = matches[searchMatchIndex]
    }

    private func finishMessageSearch() {
        withAnimation(.snappy(duration: 0.22)) {
            isSearchingMessages = false
        }
        messageSearchQuery = ""
        searchMatchIndex = 0
        isSearchFieldFocused = false
    }

    private var messageSelectionBar: some View {
        HStack(spacing: 4) {
            Button {
                copySelectedMessages()
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Copy")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(KitColor.navy)
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!selectionHasCopyableText)

            Button {
                forwardItems = forwardPayloadItems(for: selectedMessageIDs)
                guard !forwardItems.isEmpty else { return }
                showForwardSheet = true
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "arrowshape.turn.up.right")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Forward")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(KitColor.navy)
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(forwardPayloadItems(for: selectedMessageIDs).isEmpty)

            Button(role: .destructive) {
                showDeleteMessagesConfirmation = true
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "trash")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Delete")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider().opacity(0.35).allowsHitTesting(false)
        }
        .disabled(selectedMessageIDs.isEmpty)
        .opacity(selectedMessageIDs.isEmpty ? 0.55 : 1)
    }

    private var selectionHasCopyableText: Bool {
        messages.contains { message in
            guard selectedMessageIDs.contains(message.id) else { return false }
            let descriptor = KitMediaMessageDescriptor.parse(message.body)
            return descriptor == nil || descriptor?.caption?.isEmpty == false
        }
    }

    private var chatBackground: some View {
        KitChatWallpaperView()
    }

    // MARK: Bubbles

    @ViewBuilder
    private func bubble(_ message: LocalMessage) -> some View {
        let descriptor = KitMediaMessageDescriptor.parse(message.body)
        let mediaKind = descriptor.map { KitChatMediaKind(mediaType: $0.mediaType) }
        let isSelected = selectedMessageIDs.contains(message.id)

        HStack(alignment: .center, spacing: 8) {
            if isSelectingMessages {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(isSelected ? KitColor.green : KitColor.secondaryText.opacity(0.5))
                    .accessibilityHidden(true)
            }
            if message.isOutgoing { Spacer(minLength: 44) }
            bubbleBody(message, descriptor: descriptor, mediaKind: mediaKind)
                .overlay {
                    if isSearchingMessages, currentSearchMatchID == message.id {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(KitColor.green, lineWidth: 2)
                            .allowsHitTesting(false)
                    }
                }
                // While selecting, taps must toggle selection — not open viewers or players.
                .allowsHitTesting(!isSelectingMessages)
                .contextMenu {
                    if !isSelectingMessages {
                        if let copyText = copyableText(for: message) {
                            Button {
                                UIPasteboard.general.string = copyText
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                        }
                        if !forwardPayloadItems(for: [message.id]).isEmpty {
                            Button {
                                forwardItems = forwardPayloadItems(for: [message.id])
                                showForwardSheet = true
                            } label: {
                                Label("Forward", systemImage: "arrowshape.turn.up.right")
                            }
                        }
                        Button {
                            withAnimation(.snappy(duration: 0.22)) {
                                isSelectingMessages = true
                                selectedMessageIDs = [message.id]
                                isComposerFocused = false
                            }
                        } label: {
                            Label("Select", systemImage: "checkmark.circle")
                        }
                        Divider()
                        Button(role: .destructive) {
                            selectedMessageIDs = [message.id]
                            showDeleteMessagesConfirmation = true
                        } label: {
                            Label("Delete for me", systemImage: "trash")
                        }
                    }
                }
            if !message.isOutgoing { Spacer(minLength: 44) }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard isSelectingMessages else { return }
            toggleMessageSelection(message.id)
        }
        .accessibilityAddTraits(isSelectingMessages && isSelected ? .isSelected : [])
    }

    /// One grid bubble for a run of consecutive captionless photos/videos. Tapping any cell
    /// opens the shared gallery at that item.
    private func albumBubble(_ album: ChatMediaAlbum) -> some View {
        let isOutgoing = album.items[0].isOutgoing
        let closingMessage = messages.first { $0.id == album.items[album.items.count - 1].messageID }
        return HStack(alignment: .center, spacing: 8) {
            if isOutgoing { Spacer(minLength: 44) }
            VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 0) {
                ChatMediaAlbumGridView(
                    album: album,
                    isOutgoing: isOutgoing,
                    cachedData: { item in
                        messages.first(where: { $0.id == item.messageID })?.attachmentData
                    },
                    onTap: { item in openGallery(at: item.messageID) }
                )
                .padding(.top, 3)
                .padding(.horizontal, 3)
                if let closingMessage {
                    messageMetadata(closingMessage)
                        .padding(.horizontal, 12)
                        .padding(.top, 5)
                        .padding(.bottom, 7)
                }
            }
            .background(
                isOutgoing ? AnyShapeStyle(KitColor.navy) : AnyShapeStyle(.ultraThinMaterial),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            if !isOutgoing { Spacer(minLength: 44) }
        }
    }

    /// Chronological photos/videos of this conversation for the shared gallery pager.
    private var galleryItems: [KitGalleryItem] {
        messages.compactMap { message in
            guard message.pendingAttachment == nil,
                  let descriptor = KitMediaMessageDescriptor.parse(message.body)
            else { return nil }
            let kind = KitChatMediaKind(mediaType: descriptor.mediaType)
            guard kind == .image || kind == .video else { return nil }
            return KitGalleryItem(
                messageID: message.id,
                conversationID: conversation.id,
                descriptorText: message.body,
                mediaType: descriptor.mediaType,
                isOutgoing: message.isOutgoing,
                createdAt: message.createdAt,
                senderName: message.isOutgoing ? "You" : recipientDisplayName
            )
        }
    }

    private func openGallery(at messageID: UUID) {
        guard galleryItems.contains(where: { $0.messageID == messageID }) else { return }
        galleryTarget = ConversationGalleryTarget(id: messageID)
    }

    @ViewBuilder
    private func bubbleBody(
        _ message: LocalMessage,
        descriptor: KitMediaMessageDescriptor?,
        mediaKind: KitChatMediaKind?
    ) -> some View {
        if let descriptor, let mediaKind, mediaKind == .image || mediaKind == .video {
            // Edge-to-edge media with a very slim frame at the top, left, and right;
            // the caption/time footer keeps regular padding below.
            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 0) {
                SecureMediaMessageView(
                    message: message,
                    descriptor: descriptor,
                    openGallery: { openGallery(at: $0) }
                )
                    .padding(.top, 3)
                    .padding(.horizontal, 3)
                if let caption = descriptor.caption, !caption.isEmpty {
                    Text(caption)
                        .foregroundStyle(message.isOutgoing ? .white : KitColor.navy)
                        .padding(.horizontal, 12)
                        .padding(.top, 7)
                }
                messageMetadata(message)
                    .padding(.horizontal, 12)
                    .padding(.top, 5)
                    .padding(.bottom, 7)
            }
            .background(
                message.isOutgoing ? AnyShapeStyle(KitColor.navy) : AnyShapeStyle(.ultraThinMaterial),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
        } else {
            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 5) {
                if let pending = message.pendingAttachment {
                    PendingSecureMediaMessageView(message: message, attachment: pending)
                    if KitChatMediaKind(mediaType: pending.mediaType) != .document,
                       let caption = pending.caption, !caption.isEmpty {
                        Text(caption)
                            .foregroundStyle(message.isOutgoing ? .white : KitColor.primaryText)
                    }
                } else if let descriptor {
                    SecureMediaMessageView(message: message, descriptor: descriptor)
                    if mediaKind != .document,
                       let caption = descriptor.caption, !caption.isEmpty {
                        Text(caption)
                            .foregroundStyle(message.isOutgoing ? .white : KitColor.primaryText)
                    }
                } else {
                    Text(ChatMessagePresentationPolicy.previewText(for: message))
                        .foregroundStyle(message.isOutgoing ? .white : KitColor.primaryText)
                }
                messageMetadata(message)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                message.isOutgoing ? AnyShapeStyle(KitColor.navy) : AnyShapeStyle(.ultraThinMaterial),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
        }
    }

    private func bubbleTimeRow(_ message: LocalMessage) -> some View {
        HStack(spacing: 4) {
            Text(message.createdAt.formatted(date: .omitted, time: .shortened))
            if message.isOutgoing { Image(systemName: deliveryIcon(message.state)) }
        }
        .font(.caption2)
        .foregroundStyle(message.isOutgoing ? .white.opacity(0.72) : .secondary)
    }

    private func copyableText(for message: LocalMessage) -> String? {
        if let descriptor = KitMediaMessageDescriptor.parse(message.body) {
            return descriptor.caption?.nilIfBlank
        }
        return message.body.nilIfBlank
    }

    private func copySelectedMessages() {
        let texts = messages
            .filter { selectedMessageIDs.contains($0.id) }
            .compactMap(copyableText(for:))
        guard !texts.isEmpty else { return }
        UIPasteboard.general.string = texts.joined(separator: "\n")
        finishMessageSelection()
    }

    /// Messages the forward sheet can carry: delivered text and media with a durable
    /// descriptor. Still-uploading and failed media cannot be re-encrypted for a new
    /// conversation yet, so they are skipped.
    private func forwardPayloadItems(for ids: Set<UUID>) -> [ForwardPayloadItem] {
        messages
            .filter { ids.contains($0.id) }
            .compactMap { message in
                guard message.pendingAttachment == nil, message.state != .failed else {
                    return nil
                }
                if KitMediaMessageDescriptor.parse(message.body) != nil {
                    return .media(
                        id: message.id,
                        sourceConversationID: conversation.id,
                        descriptorText: message.body
                    )
                }
                guard let body = message.body.nilIfBlank,
                      KitPaymentMessage.parse(body) == nil
                else { return nil }
                return .text(id: message.id, body: body)
            }
    }

    private func toggleMessageSelection(_ id: UUID) {
        if selectedMessageIDs.contains(id) {
            selectedMessageIDs.remove(id)
        } else {
            selectedMessageIDs.insert(id)
        }
    }

    private func finishMessageSelection() {
        withAnimation(.snappy(duration: 0.22)) {
            isSelectingMessages = false
            selectedMessageIDs = []
        }
    }

    private func paymentBubble(
        _ message: LocalMessage,
        descriptor: KitPaymentMessage
    ) -> some View {
        HStack {
            if message.isOutgoing { Spacer(minLength: 52) }
            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 5) {
                paymentEventContent(message: message, descriptor: descriptor)
                messageMetadata(message)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                message.isOutgoing ? AnyShapeStyle(KitColor.navy) : AnyShapeStyle(.ultraThinMaterial),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            if !message.isOutgoing { Spacer(minLength: 52) }
        }
    }

    private func messageMetadata(_ message: LocalMessage) -> some View {
        HStack(spacing: 4) {
            Text(message.createdAt.formatted(date: .omitted, time: .shortened))
            if message.isOutgoing,
               message.state == .failed,
               model.canRetryMessage(message.id) {
                Button {
                    Task { await model.retryFailedMessage(message.id) }
                } label: {
                    Image(systemName: deliveryIcon(message.state))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Retry sending message")
                .accessibilityHint(message.failureReason ?? "Attempts this message again")
            } else if message.isOutgoing {
                Image(systemName: deliveryIcon(message.state))
            }
        }
        .font(.caption2)
        .foregroundStyle(message.isOutgoing ? .white.opacity(0.72) : .secondary)
    }

    private func dateSeparator(_ separator: ConversationTimelineDateSeparator) -> some View {
        Text(separator.label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.orange.opacity(0.11), in: Capsule())
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(separator.accessibilityLabel)
    }

    /// Routes every KITPAY1 chat event to its renderer: requests/paid keep the existing card,
    /// transfers and their responses use the acceptance-aware card.
    @ViewBuilder
    private func paymentEventContent(
        message: LocalMessage,
        descriptor: KitPaymentMessage
    ) -> some View {
        switch descriptor.action {
        case .request, .paid, .declined, .cancelled:
            paymentMessageContent(message: message, descriptor: descriptor)
        case .transfer, .sent, .accepted, .rejected, .reversed, .expired:
            transferMessageContent(message: message, descriptor: descriptor)
        }
    }

    private func transferMessageContent(
        message: LocalMessage,
        descriptor: KitPaymentMessage
    ) -> some View {
        let binding = transferPartyBinding
        let authoritativeTransfer = chatTransfers.authoritativeTransfer(
            for: descriptor,
            binding: binding
        )
        let presentation = KitTransferMessagePresentationPolicy.presentation(
            for: descriptor,
            isOutgoing: message.isOutgoing,
            authoritativeTransfer: authoritativeTransfer,
            localOutcome: KitTransferThreadStatePolicy.latestLocalOutcome(
                forTransferID: descriptor.paymentRequestId,
                transferIsOutgoing: message.isOutgoing,
                messages: messages
            ),
            binding: binding,
            acceptanceEnabled: transferAcceptanceEnabled,
            isOnline: model.isOnline
        )
        let foreground = message.isOutgoing ? Color.white : KitColor.primaryText
        let secondary = message.isOutgoing
            ? Color.white.opacity(0.76)
            : KitColor.secondaryText
        let isActing = chatTransfers.actionTransferId == descriptor.paymentRequestId

        return VStack(alignment: .leading, spacing: 8) {
            Label(
                presentation.title,
                systemImage: transferEventSymbol(for: descriptor, isOutgoing: message.isOutgoing)
            )
            .font(.caption.bold())
            .foregroundStyle(message.isOutgoing ? Color.white.opacity(0.82) : KitColor.green)
            Text("\(descriptor.currencyCode) \(descriptor.decimalAmount)")
                .font(.title3.bold())
                .foregroundStyle(foreground)
            // The transfer's own note, or — on response receipts — the documented reason
            // (e.g. why a payment was reversed).
            if let note = descriptor.note {
                Text(note)
                    .font(.subheadline)
                    .foregroundStyle(secondary)
            }
            if let reason = descriptor.reason ?? authoritativeTransfer?.reason {
                Text("Reason: \(reason)")
                    .font(.subheadline)
                    .foregroundStyle(secondary)
            }
            if !presentation.statusText.isEmpty {
                Text(presentation.statusText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(secondary)
            }

            if presentation.showsAccept || presentation.showsReject {
                HStack(spacing: 8) {
                    if presentation.showsAccept {
                        Button {
                            Task { await acceptTransfer(descriptor) }
                        } label: {
                            if isActing {
                                ProgressView()
                                    .tint(message.isOutgoing ? .white : KitColor.green)
                                    .frame(maxWidth: .infinity)
                            } else {
                                Label("Accept", systemImage: "checkmark.circle.fill")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(KitSecondaryButtonStyle())
                        .disabled(chatTransfers.actionTransferId != nil)
                    }
                    if presentation.showsReject {
                        Button {
                            transferRejectTarget = ChatTransferRejectTarget(
                                descriptor: descriptor
                            )
                        } label: {
                            Label("Decline", systemImage: "xmark.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(KitSecondaryButtonStyle())
                        .disabled(chatTransfers.actionTransferId != nil)
                    }
                }
            }
            if presentation.showsReverse {
                Button {
                    transferReverseTarget = ChatTransferReverseTarget(descriptor: descriptor)
                } label: {
                    if isActing {
                        ProgressView()
                            .tint(message.isOutgoing ? .white : KitColor.green)
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("Reverse", systemImage: "arrow.uturn.backward")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(KitSecondaryButtonStyle())
                .disabled(chatTransfers.actionTransferId != nil)
            }
        }
        .frame(maxWidth: 270, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func transferEventSymbol(
        for descriptor: KitPaymentMessage,
        isOutgoing: Bool
    ) -> String {
        switch descriptor.action {
        case .transfer:
            isOutgoing ? "arrow.up.circle.fill" : "arrow.down.circle.fill"
        case .sent:
            "checkmark.circle.fill"
        case .accepted:
            "checkmark.circle.fill"
        case .rejected:
            "xmark.circle"
        case .reversed:
            "arrow.uturn.backward.circle"
        case .expired:
            "clock.arrow.circlepath"
        case .request, .paid, .declined, .cancelled:
            "banknote"
        }
    }

    /// Recipient accepts a pending transfer, then tells the sender inside the conversation.
    private func acceptTransfer(_ descriptor: KitPaymentMessage) async {
        guard transferAcceptanceEnabled else { return }
        let accepted = await chatTransfers.accept(
            descriptor,
            binding: transferPartyBinding,
            acceptanceEnabled: transferAcceptanceEnabled,
            isOnline: model.isOnline
        )
        guard accepted else { return }
        await queueTransferResponse(descriptor, action: .accepted, reason: nil)
        await model.refresh()
    }

    /// When the acceptance window lapsed server-side, the SENDER's device documents the
    /// auto-reversal in the conversation exactly once: the receipt's message id derives
    /// deterministically from the transfer id, so retries and multiple devices converge on one
    /// chat event stating that the payment was reversed and why.
    private func documentObservedAutoReversals() async {
        guard let binding = transferPartyBinding,
              let paymentRecipientUserID
        else { return }
        for message in messages where message.isOutgoing {
            guard let descriptor = KitPaymentMessage.parse(message.body),
                  descriptor.action == .transfer,
                  let transfer = chatTransfers.authoritativeTransfer(
                      for: descriptor,
                      binding: binding
                  ),
                  transfer.knownStatus == .expired
            else { continue }
            let receiptID = TransferAcceptanceWindowPolicy.autoReversalReceiptMessageID(
                forTransferID: descriptor.paymentRequestId
            )
            guard !messages.contains(where: { $0.id == receiptID }),
                  let receipt = KitPaymentMessage(
                      action: .expired,
                      paymentRequestId: descriptor.paymentRequestId,
                      amountMinor: descriptor.amountMinor,
                      currencyCode: descriptor.currencyCode,
                      currencyScale: descriptor.currencyScale,
                      note: nil,
                      reason: ChatTransfersViewModel.autoReversalReceiptReason(transfer.reason)
                  )
            else { continue }
            _ = await model.queuePaymentEvent(
                conversationId: conversation.id,
                title: recipientDisplayName,
                recipientId: paymentRecipientUserID,
                body: receipt.encoded,
                clientMessageID: receiptID
            )
        }
    }

    /// The response event is best-effort: the money already moved authoritatively, and the
    /// other side's bubble also resolves against the server, so a failed queue only loses the
    /// cosmetic receipt.
    private func queueTransferResponse(
        _ descriptor: KitPaymentMessage,
        action: KitPaymentMessageAction,
        reason: String?
    ) async {
        guard let paymentRecipientUserID,
              let receiptID = TransferAcceptanceWindowPolicy.resolutionReceiptMessageID(
                  forTransferID: descriptor.paymentRequestId,
                  action: action
              ),
              let response = KitPaymentMessage(
                  action: action,
                  paymentRequestId: descriptor.paymentRequestId,
                  amountMinor: descriptor.amountMinor,
                  currencyCode: descriptor.currencyCode,
                  currencyScale: descriptor.currencyScale,
                  note: nil,
                  reason: ChatTransfersViewModel.canonicalReason(reason)
              )
        else { return }
        _ = await model.queuePaymentEvent(
            conversationId: conversation.id,
            title: recipientDisplayName,
            recipientId: paymentRecipientUserID,
            body: response.encoded,
            clientMessageID: receiptID
        )
    }

    private func paymentMessageContent(
        message: LocalMessage,
        descriptor: KitPaymentMessage
    ) -> some View {
        let authoritativeRequest = authoritativeRequest(for: descriptor)
        let localOutcome = descriptor.isRequest
            ? KitPaymentRequestThreadStatePolicy.latestLocalOutcome(
                forRequestID: descriptor.paymentRequestId,
                requestIsOutgoing: message.isOutgoing,
                messages: messages
            )
            : nil
        let presentation = KitPaymentMessagePresentationPolicy.presentation(
            for: descriptor,
            isOutgoing: message.isOutgoing,
            authoritativeRequest: authoritativeRequest,
            sourceWallet: model.selectedWallet,
            policy: paymentRequestPolicy,
            isOnline: model.isOnline
        )
        let foreground = message.isOutgoing ? Color.white : KitColor.primaryText
        let secondary = message.isOutgoing
            ? Color.white.opacity(0.76)
            : KitColor.secondaryText
        let outcomeTitle: String? = switch localOutcome?.action {
        case .some(.paid): "Payment request · Paid"
        case .some(.declined): "Payment request · Declined"
        case .some(.cancelled): "Payment request · Cancelled"
        case .none: nil
        default: "Payment request · Closed"
        }
        let canCancel = descriptor.isRequest
            && message.isOutgoing
            && localOutcome == nil
            && authoritativeRequest.map { paymentRequestPolicy.canCancel($0) } == true
            && model.isOnline
        let canDecline = descriptor.isRequest
            && !message.isOutgoing
            && localOutcome == nil
            && model.secureMessagingAvailable

        return VStack(alignment: .leading, spacing: 8) {
            Label(
                outcomeTitle ?? presentation.title,
                systemImage: descriptor.isRequest ? "banknote" : "checkmark.circle.fill"
            )
                .font(.caption.bold())
                .foregroundStyle(message.isOutgoing ? Color.white.opacity(0.82) : KitColor.green)
            Text("\(descriptor.currencyCode) \(descriptor.decimalAmount)")
                .font(.title3.bold())
                .foregroundStyle(foreground)
            if let note = descriptor.note {
                Text(note)
                    .font(.subheadline)
                    .foregroundStyle(secondary)
            }

            if localOutcome == nil && (presentation.showsPayAction || canDecline) {
                HStack(spacing: 8) {
                    if presentation.showsPayAction {
                        Button {
                            Task { await prepareChatPayment(descriptor) }
                        } label: {
                            if resolvingPaymentRequestID == descriptor.paymentRequestId {
                                ProgressView()
                                    .tint(message.isOutgoing ? .white : KitColor.green)
                                    .frame(maxWidth: .infinity)
                            } else {
                                Label(
                                    "Pay \(descriptor.currencyCode) \(descriptor.decimalAmount)",
                                    systemImage: "lock.shield.fill"
                                )
                                .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(KitSecondaryButtonStyle())
                        .disabled(
                            chatPaymentRequests.isLoading
                                || chatPaymentRequests.actionRequestId != nil
                                || resolvingPaymentRequestID != nil
                        )
                    }
                    if canDecline {
                        Button("Decline") {
                            Task { await declineChatPaymentRequest(descriptor) }
                        }
                        .buttonStyle(KitSecondaryButtonStyle())
                        .disabled(isSending)
                    }
                }
            } else if canCancel {
                Button("Cancel request") {
                    Task { await cancelChatPaymentRequest(descriptor) }
                }
                .buttonStyle(KitSecondaryButtonStyle())
                .disabled(chatPaymentRequests.actionRequestId != nil)
            } else {
                Text(outcomeTitle == nil ? presentation.statusText : "Closed")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(secondary)
            }
        }
        .frame(maxWidth: 270, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func authoritativeRequest(for descriptor: KitPaymentMessage) -> PaymentRequestDTO? {
        guard case .match(let request) = KitPaymentRequestResolutionPolicy.resolve(
            descriptor,
            in: chatPaymentRequests.items
        ) else { return nil }
        return request
    }

    private func validateLoadedChatPaymentRequests() {
        guard paymentRecipientUserID != nil,
              !chatPaymentRequests.isLoading,
              chatPaymentRequests.errorMessage == nil
        else { return }
        for (message, descriptor) in incomingPaymentEvents {
            guard KitPaymentRequestThreadStatePolicy.latestLocalOutcome(
                forRequestID: descriptor.paymentRequestId,
                requestIsOutgoing: message.isOutgoing,
                messages: messages
            ) == nil else { continue }
            switch KitPaymentRequestResolutionPolicy.resolve(
                descriptor,
                in: chatPaymentRequests.items
            ) {
            case .match:
                continue
            case .missing:
                chatPaymentRequests.errorMessage = "A chat payment request is not available in your account. It cannot be paid."
            case .mismatch:
                chatPaymentRequests.errorMessage = "A chat payment request does not match Kit Pay's amount or currency. It cannot be paid."
            }
            return
        }
    }

    @MainActor
    private func prepareChatPayment(_ descriptor: KitPaymentMessage) async {
        guard paymentRecipientUserID != nil,
              descriptor.isRequest,
              resolvingPaymentRequestID == nil
        else { return }
        guard model.isOnline else {
            chatPaymentRequests.errorMessage = "Connect to the internet to pay this request. Payments cannot be queued offline."
            return
        }

        resolvingPaymentRequestID = descriptor.paymentRequestId
        defer { resolvingPaymentRequestID = nil }
        guard let request = await chatPaymentRequests.resolveChatRequest(
            descriptor,
            isOnline: model.isOnline
        ),
              let wallet = model.selectedWallet,
              paymentRequestPolicy.canPay(request, from: wallet)
        else {
            if chatPaymentRequests.errorMessage == nil {
                chatPaymentRequests.errorMessage = "This request is not eligible for payment from this account."
            }
            return
        }
        chatPaymentApproval = ChatPaymentApproval(request: request, descriptor: descriptor)
    }

    private func declineChatPaymentRequest(_ descriptor: KitPaymentMessage) async {
        guard descriptor.isRequest,
              let paymentRecipientUserID,
              let declined = descriptor.changingAction(to: .declined)
        else { return }
        _ = await model.queuePaymentEvent(
            conversationId: conversation.id,
            title: recipientDisplayName,
            recipientId: paymentRecipientUserID,
            body: declined.encoded
        )
    }

    private func cancelChatPaymentRequest(_ descriptor: KitPaymentMessage) async {
        guard descriptor.isRequest,
              let paymentRecipientUserID,
              let request = authoritativeRequest(for: descriptor),
              paymentRequestPolicy.canCancel(request)
        else { return }
        let cancelled = await chatPaymentRequests.cancel(
            request,
            policy: paymentRequestPolicy,
            isOnline: model.isOnline
        )
        guard cancelled,
              let receipt = descriptor.changingAction(to: .cancelled)
        else { return }
        _ = await model.queuePaymentEvent(
            conversationId: conversation.id,
            title: recipientDisplayName,
            recipientId: paymentRecipientUserID,
            body: receipt.encoded
        )
    }

    private func callBubble(_ call: CallRecord) -> some View {
        let presentation = ConversationCallPresentationPolicy.presentation(for: call)
        let callbackAvailable = presentation.callbackEnabled
            && model.mayCreateCall
            && recipientUserID != nil
            && recipientCommunicationAllowed
        let accessibilityLabel = "\(presentation.title), \(callSubtitle(call, presentation: presentation))"

        return HStack {
            if presentation.isOutgoing { Spacer(minLength: 52) }
            if callbackAvailable {
                Button {
                    queueCall(video: call.isVideoCall)
                } label: {
                    callBubbleCard(
                        call,
                        presentation: presentation,
                        callbackAvailable: true
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityHint("Calls \(recipientDisplayName) back")
            } else {
                callBubbleCard(
                    call,
                    presentation: presentation,
                    callbackAvailable: false
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityLabel)
            }

            if !presentation.isOutgoing { Spacer(minLength: 52) }
        }
    }

    private func callBubbleCard(
        _ call: CallRecord,
        presentation: ConversationCallPresentation,
        callbackAvailable: Bool
    ) -> some View {
        let foreground = presentation.isOutgoing ? Color.white : KitColor.primaryText
        let secondary = presentation.isOutgoing
            ? Color.white.opacity(0.72)
            : KitColor.secondaryText
        let callbackSymbol: String = if presentation.callbackEnabled {
            call.isVideoCall ? "video.fill" : "phone.fill"
        } else if call.state == .queued {
            "icloud.and.arrow.up"
        } else {
            "waveform"
        }
        let callbackColor: Color = if call.state == .queued {
            .orange
        } else if presentation.callbackEnabled && !callbackAvailable {
            secondary
        } else {
            KitColor.green
        }

        return HStack(spacing: 12) {
            Image(systemName: presentation.symbolName)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(presentation.isMissed ? Color.red : KitColor.green)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(presentation.isMissed ? Color.red : foreground)
                Text(callSubtitle(call, presentation: presentation))
                    .font(.caption2)
                    .foregroundStyle(secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            Image(systemName: callbackSymbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(callbackColor)
                .kitCircularGlass(
                    diameter: ConversationHeaderLayoutPolicy.navigationControlDiameter,
                    interactive: callbackAvailable,
                    shadow: false
                )
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: 300, alignment: .leading)
        .background(
            presentation.isOutgoing
                ? AnyShapeStyle(KitColor.navy.opacity(0.94))
                : AnyShapeStyle(.ultraThinMaterial),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(presentation.isOutgoing ? 0.22 : 0.6), lineWidth: 0.7)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
    }

    private func callSubtitle(
        _ call: CallRecord,
        presentation: ConversationCallPresentation
    ) -> String {
        var values: [String] = []
        if let status = presentation.statusText { values.append(status) }
        values.append(call.startedAt.formatted(date: .omitted, time: .shortened))
        if let duration = presentation.durationSeconds, duration > 0 {
            values.append(ConversationCallPresentationPolicy.durationText(duration))
        }
        return values.joined(separator: " · ")
    }

    private func queueCall(video: Bool) {
        guard let recipientUserID else {
            model.lastError = "This conversation does not have one unambiguous Kit Pay recipient."
            return
        }
        Task {
            await model.queueCall(
                recipientId: recipientUserID,
                name: recipientDisplayName,
                video: video
            )
        }
    }

    private func beginMessageSearch() {
        withAnimation(.snappy(duration: 0.22)) {
            isSearchingMessages = true
            isComposerFocused = false
        }
        // Focus after the search bar has mounted (and any sheet has dismissed).
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            isSearchFieldFocused = true
        }
    }

    private func chatCallToolbarButton(video: Bool) -> some View {
        Button { queueCall(video: video) } label: {
            Image(systemName: video ? "video" : "phone")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(KitColor.green)
                .kitBarControlGlass(
                    diameter: ConversationHeaderLayoutPolicy.navigationControlDiameter
                )
        }
        .buttonStyle(.plain)
        .disabled(!recipientCommunicationAllowed)
        .opacity(recipientCommunicationAllowed ? 1 : 0.48)
        .accessibilityLabel(video ? "Video call" : "Audio call")
    }

    // MARK: Sending

    private func sendDraft() {
        guard canSendMessage else { return }
        let submittedDraft = draft
        let submittedText = submittedDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Typed text must never impersonate a payment event: the KITPAY1 wire is written only
        // by the payment flows themselves (a pasted descriptor could forge "Accepted · Final").
        if SecureMessageReservedPrefixPolicy.beginsWithReservedPrefix(
            submittedText,
            prefix: KitPaymentMessage.prefix
        ) {
            model.lastError = "Messages can't start with Kit Pay's reserved payment prefix."
            return
        }
        let submittedAttachments = stagedAttachments
        let persistenceVersion = model.nextConversationDraftWriteVersion()
        immediateDraftPersistenceTask?.cancel()
        immediateDraftPersistenceTask = nil
        draftWriteVersion = persistenceVersion
        isSending = true
        isComposerFocused = false
        Task {
            // Draft persistence is best-effort bookkeeping. The message pipeline has its own
            // durability, so a failed draft write (for example a brand-new conversation that
            // has not been persisted yet) must never block the send itself.
            _ = await model.persistConversationDraft(
                submittedDraft,
                conversationId: conversation.id,
                writeVersion: persistenceVersion
            )
            let clearVersion = model.nextConversationDraftWriteVersion()
            let allQueued: Bool
            if submittedAttachments.isEmpty {
                allQueued = await model.queueMessage(
                    conversationId: conversation.id,
                    title: recipientDisplayName,
                    recipientId: recipientUserID,
                    body: submittedDraft,
                    draftClearVersion: clearVersion
                )
            } else {
                allQueued = await sendStagedAttachments(
                    submittedAttachments,
                    text: submittedText,
                    submittedDraft: submittedDraft,
                    clearVersion: clearVersion
                )
            }
            if allQueued {
                draftWriteVersion = clearVersion
                if draft == submittedDraft { draft = "" }
            }
            isSending = false
        }
    }

    /// Queues every staged attachment and returns whether everything, including any typed
    /// text, ended up durably queued.
    private func sendStagedAttachments(
        _ attachments: [ChatStagedAttachment],
        text: String,
        submittedDraft: String,
        clearVersion: ConversationDraftWriteVersion
    ) async -> Bool {
        // A single non-document attachment carries the typed text as its caption. Documents
        // keep the filename in the caption (the wire descriptor has no filename field), and
        // multi-attachment sends stay captionless so photo runs can group into one album;
        // both send the typed text as a separate follow-up message.
        let textRidesOnMedia = attachments.count == 1 && attachments[0].kind != .document
        var queuedAllMedia = true
        for attachment in attachments {
            let caption: String? = if attachment.kind == .document {
                attachment.displayName
            } else if textRidesOnMedia {
                text.nilIfBlank
            } else {
                nil
            }
            let queued = await model.queueMediaMessage(
                conversationId: conversation.id,
                title: recipientDisplayName,
                recipientId: recipientUserID,
                mediaData: attachment.data,
                mediaType: attachment.mediaType,
                caption: caption,
                submittedDraftBody: textRidesOnMedia ? submittedDraft : nil,
                draftClearVersion: textRidesOnMedia ? clearVersion : nil
            )
            if queued {
                // Durably queued: unstage it even if a later attachment fails, so a retry
                // can never duplicate this one.
                stagedAttachments.removeAll { $0.id == attachment.id }
            } else {
                queuedAllMedia = false
            }
        }
        if stagedAttachments.isEmpty { selectedPhotoItems = [] }
        guard queuedAllMedia else { return false }
        if textRidesOnMedia { return true }
        guard let followUp = text.nilIfBlank else { return true }
        let textQueued = await model.queueMessage(
            conversationId: conversation.id,
            title: recipientDisplayName,
            recipientId: recipientUserID,
            body: followUp,
            draftClearVersion: clearVersion
        )
        if !textQueued {
            model.lastError =
                "The attachments were queued, but the message text was not. Your draft is still here."
        }
        return textQueued
    }

    private func persistDraftImmediately() {
        guard didRestoreDraft, !isSending else { return }
        let currentDraft = draft
        let writeVersion = model.nextConversationDraftWriteVersion()
        draftWriteVersion = writeVersion
        immediateDraftPersistenceTask?.cancel()
        immediateDraftPersistenceTask = Task {
            _ = await model.persistConversationDraft(
                currentDraft,
                conversationId: conversation.id,
                writeVersion: writeVersion
            )
        }
    }

    private func sendVoiceNote() {
        guard let recording = voiceRecorder.finish() else { return }
        isSending = true
        Task {
            let queued = await model.queueMediaMessage(
                conversationId: conversation.id,
                title: conversation.title,
                recipientId: recipientUserID,
                mediaData: recording.data,
                mediaType: VoiceNoteRecorder.Recording.mediaType,
                caption: nil
            )
            if !queued {
                // Never drop a recorded note on a failed send — stage it so the user can retry.
                stageAttachment(ChatStagedAttachment(
                    kind: .voice,
                    data: recording.data,
                    mediaType: VoiceNoteRecorder.Recording.mediaType,
                    displayName: "Voice note",
                    previewImage: nil
                ))
            }
            isSending = false
        }
    }

    private func openPaymentRequest() {
        guard recipientCommunicationAllowed else {
            model.lastError = recipientIsBlocked
                ? "Unblock this account before sending a payment request."
                : "Communication privacy is still loading. Refresh and try again."
            return
        }
        guard paymentRequestPolicy.paymentRequestsEnabled, model.isOnline else {
            model.lastError = model.isOnline
                ? "Payment requests are not available for this account."
                : "Connect to the internet to create a payment request."
            return
        }
        guard model.secureMessagingAvailable else {
            model.lastError = CustomerFacingMessagingCopy.paymentRequestShareFailure
            return
        }
        guard paymentRecipientUserID != nil else {
            model.lastError = "Payment requests are available only in a one-to-one Kit Pay chat."
            return
        }
        isComposerFocused = false
        paymentFlow.errorMessage = nil
        paymentFlow.useSyncedContacts(model.contactDirectory)
        showPaymentRequest = true
    }

    /// Opens the standard transfer flow with this chat's recipient already selected, the same
    /// way payment requests start from the conversation.
    private func openSendMoney() {
        guard recipientCommunicationAllowed else {
            model.lastError = recipientIsBlocked
                ? "Unblock this account before sending money."
                : "Communication privacy is still loading. Refresh and try again."
            return
        }
        guard model.capabilities?.features?["wallets"] == true,
              model.capabilities?.features?["internal_transfers"] == true
        else {
            model.lastError = "Sending money is not available for this account."
            return
        }
        guard model.isOnline else {
            model.lastError = "Connect to the internet to send money."
            return
        }
        guard paymentRecipientUserID != nil else {
            model.lastError = "Sending money is available only in a one-to-one Kit Pay chat."
            return
        }
        isComposerFocused = false
        sendMoneyFlow.errorMessage = nil
        sendMoneyFlow.useSyncedContacts(model.contactDirectory)
        showSendMoney = true
    }

    // MARK: Attachment staging

    /// Every capture flows through the creative editor before staging.
    private func handleCameraOutput(_ output: KitCameraOutput?) {
        guard let output else { return }
        let input: KitMediaEditorInput
        switch output {
        case .photo(let image):
            input = .photo(image)
        case .video(let url, let mediaType):
            input = .video(url, mediaType: mediaType)
        }
        // Give the camera cover a beat to dismiss before presenting the editor cover.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            editorSession = MediaEditorSession(input: input)
        }
    }

    private func handleEditorOutput(
        _ output: KitMediaEditorOutput?,
        original: KitMediaEditorInput
    ) {
        let originalVideoURL: URL? = if case .video(let url, _) = original { url } else { nil }
        switch output {
        case .photo(let image):
            stageCameraPhoto(image)
            if let originalVideoURL {
                try? FileManager.default.removeItem(at: originalVideoURL)
            }
        case .video(let url, _):
            // stageCapturedVideo reads and then deletes the file it is handed.
            stageCapturedVideo(url)
            if let originalVideoURL, originalVideoURL != url {
                try? FileManager.default.removeItem(at: originalVideoURL)
            }
        case nil:
            if let originalVideoURL {
                try? FileManager.default.removeItem(at: originalVideoURL)
            }
        }
    }

    /// Appends one more attachment, keeping the staged set within the cap.
    private func stageAttachment(_ attachment: ChatStagedAttachment) {
        guard stagedAttachments.count < ConversationAttachmentStagingPolicy.maximumStagedAttachments
        else {
            model.lastError = "You can attach up to \(ConversationAttachmentStagingPolicy.maximumStagedAttachments) files per message."
            return
        }
        stagedAttachments.append(attachment)
    }

    @MainActor
    private func loadPickedLibraryItems(_ items: [PhotosPickerItem], generation: Int) async {
        guard generation == attachmentLoadGeneration else { return }
        isLoadingAttachment = true
        var failedCount = 0
        for item in items {
            guard generation == attachmentLoadGeneration else { return }
            let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw AttachmentSelectionError.invalidImage
                }
                guard generation == attachmentLoadGeneration else { return }
                if isVideo {
                    guard KitChatMediaLimits.fits(data.count, kind: .video) else {
                        throw AttachmentSelectionError.fileTooLarge
                    }
                    stageAttachment(ChatStagedAttachment(
                        kind: .video,
                        data: data,
                        mediaType: libraryVideoMediaType(for: item),
                        displayName: "Video",
                        previewImage: nil
                    ))
                } else {
                    guard data.count <= 64 * 1_024 * 1_024,
                          let prepared = AttachmentImageDecoder.secureJPEG(from: data)
                    else { throw AttachmentSelectionError.invalidImage }
                    guard generation == attachmentLoadGeneration else { return }
                    stageAttachment(ChatStagedAttachment(
                        kind: .image,
                        data: prepared.data,
                        mediaType: "image/jpeg",
                        displayName: "Photo",
                        previewImage: prepared.preview
                    ))
                }
            } catch {
                failedCount += 1
                model.lastError = error.localizedDescription
            }
        }
        guard generation == attachmentLoadGeneration else { return }
        selectedPhotoItems = []
        isLoadingAttachment = false
        if failedCount > 0, items.count > 1 {
            model.lastError = failedCount == items.count
                ? "The selected items could not be attached."
                : "\(failedCount) of \(items.count) selected items could not be attached."
        }
    }

    private func libraryVideoMediaType(for item: PhotosPickerItem) -> String {
        if item.supportedContentTypes.contains(where: { $0.conforms(to: .quickTimeMovie) }) {
            return "video/quicktime"
        }
        return "video/mp4"
    }

    private func stageCameraPhoto(_ image: UIImage) {
        guard let jpeg = image.jpegData(compressionQuality: 0.9),
              let prepared = AttachmentImageDecoder.secureJPEG(from: jpeg)
        else {
            model.lastError = AttachmentSelectionError.invalidImage.localizedDescription
            return
        }
        stageAttachment(ChatStagedAttachment(
            kind: .image,
            data: prepared.data,
            mediaType: "image/jpeg",
            displayName: "Photo",
            previewImage: prepared.preview
        ))
    }

    private func stageCapturedVideo(_ url: URL) {
        attachmentLoadGeneration &+= 1
        let generation = attachmentLoadGeneration
        isLoadingAttachment = true
        Task { @MainActor in
            defer {
                try? FileManager.default.removeItem(at: url)
                if generation == attachmentLoadGeneration { isLoadingAttachment = false }
            }
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try Data(contentsOf: url)
                }.value
                guard generation == attachmentLoadGeneration else { return }
                guard KitChatMediaLimits.fits(data.count, kind: .video) else {
                    throw AttachmentSelectionError.fileTooLarge
                }
                let mediaType = url.pathExtension.lowercased() == "mp4"
                    ? "video/mp4"
                    : "video/quicktime"
                stageAttachment(ChatStagedAttachment(
                    kind: .video,
                    data: data,
                    mediaType: mediaType,
                    displayName: "Video note",
                    previewImage: nil
                ))
            } catch {
                guard generation == attachmentLoadGeneration else { return }
                model.lastError = (error as? LocalizedError)?.errorDescription
                    ?? "The video note could not be read."
            }
        }
    }

    private func stageDocument(_ url: URL) {
        let secured = url.startAccessingSecurityScopedResource()
        attachmentLoadGeneration &+= 1
        let generation = attachmentLoadGeneration
        isLoadingAttachment = true
        Task { @MainActor in
            defer {
                if secured { url.stopAccessingSecurityScopedResource() }
                if generation == attachmentLoadGeneration { isLoadingAttachment = false }
            }
            do {
                if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                   !KitChatMediaLimits.fits(size, kind: .document) {
                    throw AttachmentSelectionError.fileTooLarge
                }
                let data = try await Task.detached(priority: .userInitiated) {
                    try Data(contentsOf: url)
                }.value
                guard generation == attachmentLoadGeneration else { return }
                guard KitChatMediaLimits.fits(data.count, kind: .document) else {
                    throw data.isEmpty
                        ? AttachmentSelectionError.invalidDocument
                        : AttachmentSelectionError.fileTooLarge
                }
                let declaredType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                let mediaType = declaredType.flatMap {
                    SecureMessagingWire.allowedAttachmentMediaTypes.contains($0.lowercased())
                        ? $0.lowercased()
                        : nil
                } ?? "application/octet-stream"
                stageAttachment(ChatStagedAttachment(
                    kind: .document,
                    data: data,
                    mediaType: mediaType,
                    displayName: url.lastPathComponent,
                    previewImage: nil
                ))
            } catch {
                guard generation == attachmentLoadGeneration else { return }
                model.lastError = (error as? LocalizedError)?.errorDescription
                    ?? "This document could not be read."
            }
        }
    }

    private func scrollToBottom(using proxy: ScrollViewProxy) {
        unseenIncomingCount = 0
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(ConversationScrollAnchor.bottom, anchor: .bottom)
        }
    }

    // MARK: Reading position, jump-to-latest, and the pull-past-the-end camera

    private func handleScrollMetrics(_ metrics: ConversationScrollMetrics) {
        if conversationContentHeight != metrics.contentHeight {
            conversationContentHeight = metrics.contentHeight
        }
        guard conversationViewportHeight > 0 else { return }
        let distanceFromLatest = metrics.contentMaxY - conversationViewportHeight
        let nearLatest = distanceFromLatest < ConversationCameraPullPolicy.nearLatestDistance
        if nearLatest != isNearLatestMessage {
            isNearLatestMessage = nearLatest
            if nearLatest { unseenIncomingCount = 0 }
        }

        guard cameraPullIsEligible else {
            if cameraPullProgress != 0 { cameraPullProgress = 0 }
            return
        }
        let overscroll = max(0, -distanceFromLatest)
        if cameraPullProgress != overscroll {
            cameraPullProgress = overscroll
        }
        if overscroll >= ConversationCameraPullPolicy.triggerDistance {
            if !didTriggerCameraPull {
                didTriggerCameraPull = true
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                showCameraCapture = true
            }
        } else if overscroll < ConversationCameraPullPolicy.rearmDistance {
            didTriggerCameraPull = false
        }
    }

    private var cameraPullIndicator: some View {
        let progress = min(1, cameraPullProgress / ConversationCameraPullPolicy.triggerDistance)
        return VStack(spacing: 6) {
            Image(systemName: "camera.fill")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(KitColor.green)
                .frame(width: 46, height: 46)
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(KitColor.green, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .scaleEffect(0.6 + 0.4 * progress)
            Text(progress >= 1 ? "Release for camera" : "Keep pulling for camera")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(KitColor.secondaryText)
        }
        .opacity(Double(progress))
        .padding(.bottom, 8)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func jumpToLatestButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            scrollToBottom(using: proxy)
        } label: {
            HStack(spacing: 6) {
                if unseenIncomingCount > 0 {
                    Text("\(unseenIncomingCount)")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(KitColor.green, in: Capsule())
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(KitColor.green)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(.white.opacity(0.55), lineWidth: 0.7)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        }
        .padding(.trailing, 14)
        .padding(.bottom, 10)
        .accessibilityLabel(
            unseenIncomingCount > 0
                ? "\(unseenIncomingCount) new messages, jump to latest"
                : "Jump to latest message"
        )
        .transition(.opacity.combined(with: .scale(scale: 0.86)))
    }
}

enum ConversationAttachmentStagingPolicy {
    /// A send can carry several photos/videos; the album grid groups them on arrival.
    static let maximumStagedAttachments = 8
}

/// Case- and diacritic-insensitive search across everything readable in one conversation:
/// text bodies, media captions, and document filenames (which travel in the caption field).
enum ConversationMessageSearchPolicy {
    static func matchingMessageIDs(query: String, messages: [LocalMessage]) -> [UUID] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return messages.compactMap { message in
            guard let text = searchableText(for: message),
                  text.range(
                      of: trimmed,
                      options: [.caseInsensitive, .diacriticInsensitive]
                  ) != nil
            else { return nil }
            return message.id
        }
    }

    static func searchableText(for message: LocalMessage) -> String? {
        if let pending = message.pendingAttachment {
            return pending.caption?.nilIfBlank
        }
        if let descriptor = KitMediaMessageDescriptor.parse(message.body) {
            return descriptor.caption?.nilIfBlank
        }
        guard KitPaymentMessage.parse(message.body) == nil else { return nil }
        return message.body.nilIfBlank
    }
}

/// How far past the last message the user must pull before the camera opens.
///
/// The distances are measured in CONTENT displacement, which iOS rubber-band damping roughly
/// halves relative to finger travel — a 60pt trigger needs about 120pt of actual pull, which is
/// a deliberate but easy gesture. (110pt required ~250pt of finger travel and read as broken.)
enum ConversationCameraPullPolicy {
    static let triggerDistance: CGFloat = 60
    /// Overscroll must fall back under this before another pull can fire.
    static let rearmDistance: CGFloat = 6
    /// Within this distance of the latest message the user counts as "caught up".
    static let nearLatestDistance: CGFloat = 56

    /// The indicator and camera launch must use this same gate so the UI never advertises an
    /// action that the current conversation interaction would reject.
    static func isEligible(
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        isSelectingMessages: Bool,
        isSearchingMessages: Bool,
        isRecordingVoiceNote: Bool,
        isComposerFocused: Bool
    ) -> Bool {
        viewportHeight > 0
            && contentHeight > viewportHeight
            && !isSelectingMessages
            && !isSearchingMessages
            && !isRecordingVoiceNote
            && !isComposerFocused
    }
}

private struct ConversationScrollMetrics: Equatable {
    var contentHeight: CGFloat = 0
    var contentMaxY: CGFloat = 0
}

private struct ConversationScrollMetricsKey: PreferenceKey {
    static var defaultValue = ConversationScrollMetrics()
    static func reduce(
        value: inout ConversationScrollMetrics,
        nextValue: () -> ConversationScrollMetrics
    ) {
        value = nextValue()
    }
}

/// Live input-level bars for the recording strip.
private struct RecorderLevelWave: View {
    let level: Float
    @State private var history: [Float] = Array(repeating: 0, count: 28)

    var body: some View {
        HStack(alignment: .center, spacing: 2.4) {
            ForEach(history.indices, id: \.self) { index in
                Capsule()
                    .fill(KitColor.green.opacity(0.75))
                    .frame(width: 2.6, height: 4 + CGFloat(history[index]) * 18)
            }
        }
        .onChange(of: level) { _, newLevel in
            history.removeFirst()
            history.append(newLevel)
        }
        .accessibilityHidden(true)
    }
}

private enum ConversationScrollAnchor: Hashable {
    case bottom
}

private struct ConversationGalleryTarget: Identifiable {
    let id: UUID
}

private struct MediaEditorSession: Identifiable {
    let id = UUID()
    let input: KitMediaEditorInput
}

private struct ChatTransferReverseTarget: Identifiable {
    let descriptor: KitPaymentMessage
    var id: String { descriptor.paymentRequestId }
}

private struct ChatTransferRejectTarget: Identifiable {
    let descriptor: KitPaymentMessage
    var id: String { descriptor.paymentRequestId }
}

enum AttachmentImageDecoder {
    struct PreparedImage {
        let preview: UIImage
        let data: Data
    }

    static func secureJPEG(from data: Data) -> PreparedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 2_048,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let preview = UIImage(cgImage: image)
        for quality in stride(
            from: CGFloat(0.9),
            through: CGFloat(0.5),
            by: CGFloat(-0.1)
        ) {
            guard let encoded = preview.jpegData(compressionQuality: quality) else { continue }
            if encoded.count <= KitChatMediaLimits.imageEncodeTargetBytes {
                return PreparedImage(preview: preview, data: encoded)
            }
        }
        return nil
    }
}

private struct ConversationContactProfileView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showSaveContact = false
    @State private var contactWasSaved = false
    @State private var showBlockConfirmation = false

    let name: String
    let contact: WalletContactDTO?
    let avatarURL: String?
    let userID: String?
    let conversationID: String
    let startAudioCall: () -> Void
    let startVideoCall: () -> Void
    /// Dismisses this sheet and opens the in-chat message search.
    let searchChat: () -> Void
    /// Dismisses this sheet and scrolls the conversation to the given message.
    let showMessageInChat: (UUID) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    VStack(spacing: 12) {
                        RemoteAvatarView(
                            name: displayName,
                            avatarURL: avatarURL ?? contact?.avatarURL,
                            size: 96
                        )
                            .kitCircularGlass(diameter: 116, interactive: false)

                        Text(displayName)
                            .font(.largeTitle.bold())
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.center)

                        if let subtitle {
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .textSelection(.enabled)
                        }
                    }

                    HStack(spacing: 12) {
                        profileAction(
                            title: "Audio",
                            systemName: "phone",
                            disabled: !communicationAllowed,
                            action: startAudioCall
                        )
                        profileAction(
                            title: "Video",
                            systemName: "video",
                            disabled: !communicationAllowed,
                            action: startVideoCall
                        )
                        profileAction(
                            title: "Search",
                            systemName: "magnifyingglass",
                            disabled: false,
                            action: searchChat
                        )
                    }

                    if canSaveToContacts {
                        Button { showSaveContact = true } label: {
                            Label("Save to Contacts", systemImage: "person.crop.circle.badge.plus")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(KitColor.green)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 15)
                                .kitGlass(cornerRadius: 22, shadow: false)
                        }
                        .buttonStyle(.plain)
                    }

                    VStack(spacing: 0) {
                        profileRow(
                            title: "Phone",
                            value: contact?.phone.nilIfBlank ?? "Available after contact sync"
                        )
                        Divider().padding(.leading, 18)
                        profileRow(
                            title: "Kit Pay account",
                            value: contact?.isKitUser == true ? "Active" : "Not confirmed"
                        )
                    }
                    .kitGlass(cornerRadius: 24, shadow: false)

                    NavigationLink {
                        ConversationMediaLibraryView(
                            conversationID: conversationID,
                            conversationTitle: displayName,
                            openGallery: { tappedMessageID in
                                showMessageInChat(tappedMessageID)
                            }
                        )
                        .environmentObject(model)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(KitColor.green)
                            Text("Media, audio & documents")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 15)
                        .kitGlass(cornerRadius: 24, shadow: false)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if canonicalUserID != nil {
                        communicationSafetyAction
                    }

                    if let privacyError = model.communicationPrivacyErrorMessage {
                        Text(privacyError)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                    }
                }
                .padding(22)
            }
            .background(KitColor.canvas.ignoresSafeArea())
            .navigationTitle("Contact info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showSaveContact) {
                if let phone = contact?.phone.nilIfBlank {
                    NewSystemContactView(name: displayName, phone: phone) { saved in
                        contactWasSaved = saved
                        showSaveContact = false
                    }
                    .ignoresSafeArea()
                }
            }
            .task {
                if canonicalUserID != nil, !model.hasUsableCommunicationPrivacyProjection {
                    await model.loadCommunicationPrivacy()
                }
            }
            .confirmationDialog(
                "Block \(displayName)?",
                isPresented: $showBlockConfirmation,
                titleVisibility: .visible
            ) {
                Button("Block", role: .destructive) {
                    guard let canonicalUserID else { return }
                    Task { _ = await model.setCommunicationBlocked(true, userID: canonicalUserID) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You will no longer be able to message or call each other. You can unblock this account at any time.")
            }
        }
    }

    private var canonicalUserID: String? {
        CommunicationPrivacyIdentifier.canonicalUUID(userID)
    }

    private var isBlocked: Bool {
        model.isCommunicationBlocked(userID: canonicalUserID)
    }

    private var communicationAllowed: Bool {
        model.communicationPrivacyAllowsOutbound(to: canonicalUserID)
    }

    private var communicationSafetyAction: some View {
        Button {
            guard let canonicalUserID else { return }
            if isBlocked {
                Task { _ = await model.setCommunicationBlocked(false, userID: canonicalUserID) }
            } else {
                showBlockConfirmation = true
            }
        } label: {
            HStack(spacing: 11) {
                if model.communicationPrivacyMutation == .block(canonicalUserID ?? "")
                    || model.communicationPrivacyMutation == .unblock(canonicalUserID ?? "") {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: isBlocked ? "person.crop.circle.badge.checkmark" : "hand.raised.fill")
                }
                Text(isBlocked ? "Unblock account" : "Block account")
                    .font(.body.weight(.semibold))
                Spacer()
            }
            .foregroundStyle(isBlocked ? KitColor.green : .red)
            .padding(17)
            .kitGlass(cornerRadius: 22, shadow: false)
        }
        .buttonStyle(.plain)
        .disabled(model.isCommunicationPrivacyBusy || !model.isOnline)
        .accessibilityLabel(isBlocked ? "Unblock \(displayName)" : "Block \(displayName)")
        .accessibilityHint(
            isBlocked
                ? "Allows messages and calls with this account again"
                : "Stops messages and calls in both directions"
        )
    }

    private var displayName: String {
        if contact?.contactId?.nilIfBlank != nil,
           let deviceName = contact?.name.nilIfBlank {
            return deviceName
        }
        return name.nilIfBlank ?? "Kit Pay user"
    }

    private var canSaveToContacts: Bool {
        contact?.contactId?.nilIfBlank == nil
            && contact?.phone.nilIfBlank != nil
            && !contactWasSaved
    }

    private var subtitle: String? {
        if let tag = contact?.tag?.nilIfBlank {
            return "@\(tag)"
        }
        return contact?.phone.nilIfBlank
    }

    private func profileAction(
        title: String,
        systemName: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            dismiss()
            action()
        } label: {
            VStack(spacing: 8) {
                Image(systemName: systemName)
                    .font(.system(size: 21, weight: .semibold))
                    .frame(width: 30, height: 30)
                Text(title).font(.caption.weight(.semibold))
            }
            .foregroundStyle(KitColor.green)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .kitGlass(cornerRadius: 22, shadow: false)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.48 : 1)
    }

    private func profileRow(title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 20)
            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.subheadline)
        .padding(18)
    }
}

private struct NewSystemContactView: UIViewControllerRepresentable {
    let name: String
    let phone: String
    let completion: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    func makeUIViewController(context: Context) -> UINavigationController {
        let newContact = CNMutableContact()
        if let components = PersonNameComponentsFormatter().personNameComponents(from: name) {
            newContact.namePrefix = components.namePrefix ?? ""
            newContact.givenName = components.givenName ?? name
            newContact.middleName = components.middleName ?? ""
            newContact.familyName = components.familyName ?? ""
            newContact.nameSuffix = components.nameSuffix ?? ""
            newContact.nickname = components.nickname ?? ""
        } else {
            newContact.givenName = name
        }
        newContact.phoneNumbers = [
            CNLabeledValue(
                label: CNLabelPhoneNumberMobile,
                value: CNPhoneNumber(stringValue: phone)
            ),
        ]
        let contactViewController = CNContactViewController(forNewContact: newContact)
        contactViewController.delegate = context.coordinator
        contactViewController.allowsActions = false
        return UINavigationController(rootViewController: contactViewController)
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}

    final class Coordinator: NSObject, CNContactViewControllerDelegate {
        let completion: (Bool) -> Void

        init(completion: @escaping (Bool) -> Void) {
            self.completion = completion
        }

        func contactViewController(
            _ viewController: CNContactViewController,
            didCompleteWith contact: CNContact?
        ) {
            completion(contact != nil)
        }
    }
}

private struct ConversationAvatarView: View {
    let name: String
    let avatarURL: String?
    let size: CGFloat

    private var validatedURL: URL? {
        guard let avatarURL,
              let url = URL(string: avatarURL),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false
        else { return nil }
        return url
    }

    var body: some View {
        Group {
            if let validatedURL {
                AsyncImage(url: validatedURL) { phase in
                    if case let .success(image) = phase {
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(width: size, height: size)
                            .clipShape(Circle())
                    } else {
                        AvatarView(name: name, size: size, showsRing: false)
                    }
                }
            } else {
                AvatarView(name: name, size: size, showsRing: false)
            }
        }
        .frame(width: size, height: size, alignment: .center)
        .clipShape(Circle())
    }
}

private enum AttachmentSelectionError: LocalizedError {
    case invalidImage
    case invalidDocument
    case fileTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            "Choose a valid image that can be prepared securely at 10 MB or less after optimization."
        case .invalidDocument:
            "This document could not be read."
        case .fileTooLarge:
            "Files can be up to \(KitChatMediaLimits.maximumTransferLabel)."
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum ChatMessagePresentationPolicy {
    static let paymentRequestPreview = "💰 Payment request"
    static let paymentPreview = "💸 Payment"
    static let heldPaymentPreview = "💸 Payment awaiting acceptance"

    static func previewText(for message: LocalMessage) -> String {
        presentation(for: message).previewText
    }

    /// Text exposed to local global search. Wire descriptors are represented only by friendly,
    /// provider-neutral labels; encrypted media remains excluded from search.
    static func searchableText(for message: LocalMessage) -> String? {
        presentation(for: message).searchableText
    }

    private static func presentation(
        for message: LocalMessage
    ) -> (previewText: String, searchableText: String?) {
        if let pending = message.pendingAttachment {
            return (
                mediaPreview(mediaType: pending.mediaType, caption: pending.caption),
                nil
            )
        }

        if let payment = KitPaymentMessage.parse(message.body) {
            let label = switch payment.action {
            case .request: paymentRequestPreview
            case .paid, .sent: paymentPreview
            case .declined: "↩️ Payment request declined"
            case .cancelled: "↩️ Payment request cancelled"
            case .transfer: heldPaymentPreview
            case .accepted: "✅ Payment accepted"
            case .rejected: "↩️ Payment declined and returned"
            case .reversed: "↩️ Payment reversed"
            case .expired: "↩️ Payment returned"
            }
            let searchableParts = [payment.note, payment.reason].compactMap { $0 }
            let searchable = searchableParts.isEmpty
                ? label
                : "\(label) · \(searchableParts.joined(separator: " · "))"
            return (label, searchable)
        }
        // A future or malformed encrypted payment card must never expose its wire representation.
        if SecureMessageReservedPrefixPolicy.beginsWithReservedPrefix(
            message.body,
            prefix: KitPaymentMessage.prefix
        ) {
            return (paymentPreview, paymentPreview)
        }

        if let media = KitMediaMessageDescriptor.parse(message.body) {
            return (mediaPreview(mediaType: media.mediaType, caption: media.caption), nil)
        }
        // Apply the same fail-closed presentation to unsupported media descriptor versions.
        if SecureMessageReservedPrefixPolicy.beginsWithReservedPrefix(
            message.body,
            prefix: KitMediaMessageDescriptor.prefix
        ) {
            return ("Photo", nil)
        }
        return (message.body, message.body)
    }

    private static func mediaPreview(mediaType: String, caption: String?) -> String {
        let label = KitChatMediaKind(mediaType: mediaType).previewLabel
        guard let caption, !caption.isEmpty else { return label }
        return "\(label) · \(caption)"
    }
}

struct NewMessageSubmissionKey: Equatable {
    let recipientUserID: String
    let body: String

    init?(recipientUserID: String, body: String) {
        guard let recipient = UUID(
            uuidString: recipientUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        ) else { return nil }
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        self.recipientUserID = recipient.uuidString.lowercased()
        self.body = body
    }
}

struct NewMessageSubmissionGate {
    private(set) var retainedClientMessageID: UUID?
    private(set) var retainedKey: NewMessageSubmissionKey?
    private(set) var inFlightClientMessageID: UUID?

    var isSubmitting: Bool { inFlightClientMessageID != nil }

    /// Reuses the retained id after an ambiguous failure, while rejecting concurrent taps.
    mutating func begin(
        key: NewMessageSubmissionKey,
        makeClientMessageID: () -> UUID = UUID.init
    ) -> UUID? {
        guard inFlightClientMessageID == nil else { return nil }
        let clientMessageID: UUID
        if retainedKey == key, let retainedClientMessageID {
            clientMessageID = retainedClientMessageID
        } else {
            clientMessageID = makeClientMessageID()
            retainedKey = key
        }
        retainedClientMessageID = clientMessageID
        inFlightClientMessageID = clientMessageID
        return clientMessageID
    }

    mutating func finish(clientMessageID: UUID, succeeded: Bool) {
        guard inFlightClientMessageID == clientMessageID else { return }
        inFlightClientMessageID = nil
        if succeeded {
            retainedClientMessageID = nil
            retainedKey = nil
        }
    }

    mutating func reset() {
        guard !isSubmitting else { return }
        retainedClientMessageID = nil
        retainedKey = nil
    }
}

private func canonicalUserID(_ rawValue: String?) -> String? {
    guard let rawValue,
          let id = UUID(uuidString: rawValue.trimmingCharacters(in: .whitespacesAndNewlines))
    else { return nil }
    return id.uuidString.lowercased()
}

private struct KitUserSearchTaskKey: Hashable {
    let query: String
    let isOnline: Bool
}

private struct NewMessageSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selectedContact: WalletContactDTO?
    @State private var message = ""
    @State private var isLoading = false
    @State private var directoryResults: [KitUserSearchResultDTO] = []
    @State private var directoryResultQuery: String?
    @State private var directorySearchID: UUID?
    @State private var directorySearchQuery: String?
    @State private var submissionGate = NewMessageSubmissionGate()

    let onQueued: (Conversation) -> Void

    init(
        initialContact: WalletContactDTO? = nil,
        onQueued: @escaping (Conversation) -> Void
    ) {
        _selectedContact = State(initialValue: initialContact)
        self.onQueued = onQueued
    }

    private var context: PhoneIdentityContext {
        model.phoneIdentityContext
    }

    var body: some View {
        let remoteQuery = KitUserDirectorySearch.remoteQuery(from: query)
        let currentDirectoryResults = directoryResultQuery == remoteQuery
            ? directoryResults
            : []
        let sections = KitUserDirectorySearch.sections(
            localContacts: model.communicationContactDirectory,
            remoteResults: currentDirectoryResults,
            query: query,
            context: context,
            excludingUserID: model.profile?.id
        )
        let isSearchingDirectory = directorySearchID != nil
            && directorySearchQuery == remoteQuery
        NavigationStack {
            Form {
                if let selectedContact {
                    Section("To") {
                        contactLabel(selectedContact, trailingText: selectedContact.tag?.nilIfEmpty)
                    }
                    Section("Message") {
                        TextField("Write a message", text: $message, axis: .vertical)
                            .lineLimit(3...8)
                            .disabled(submissionGate.isSubmitting)
                    }
                    Section {
                        Label(
                            CustomerFacingMessagingCopy.encryptionAssurance,
                            systemImage: "lock.fill"
                        )
                        .font(.footnote)
                    }
                } else {
                    ContactSyncRecoveryView()

                    if isSearchingDirectory && sections.kitPay.isEmpty {
                        Section {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Searching Kit Pay…")
                                    .foregroundStyle(KitColor.secondaryText)
                            }
                        }
                    } else if sections.kitPay.isEmpty && sections.invitations.isEmpty {
                        Section {
                            ContentUnavailableView(
                                query.isEmpty ? "No contacts yet" : "No matching contacts",
                                systemImage: query.isEmpty ? "person.crop.circle.badge.plus" : "magnifyingglass",
                                description: Text(query.isEmpty
                                    ? "Allow Contacts access to find people you know on Kit Pay."
                                    : "Try another name or phone number.")
                            )
                        }
                    }

                    if !sections.kitPay.isEmpty {
                        Section("On Kit Pay") {
                            ForEach(sections.kitPay) { contact in
                                Button {
                                    submissionGate.reset()
                                    selectedContact = contact
                                } label: {
                                    contactLabel(contact, trailingText: contact.tag?.nilIfEmpty)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if !sections.invitations.isEmpty {
                        Section("Invite to Kit Pay") {
                            ForEach(sections.invitations) { contact in
                                ShareLink(item: inviteText(for: contact)) {
                                    contactLabel(contact, trailingText: "Invite")
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .navigationTitle(selectedContact?.name ?? "New message")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $query,
                isPresented: .constant(selectedContact == nil),
                prompt: "Name, phone or @kittag"
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(selectedContact == nil ? "Cancel" : "Back") {
                        if selectedContact == nil {
                            dismiss()
                        } else {
                            submissionGate.reset()
                            selectedContact = nil
                            message = ""
                        }
                    }
                    .disabled(submissionGate.isSubmitting)
                }
                if let selectedContact {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            submit(to: selectedContact)
                        } label: {
                            if submissionGate.isSubmitting {
                                ProgressView()
                                    .accessibilityLabel("Sending message")
                            } else {
                                Text("Send")
                            }
                        }
                        .disabled(
                            submissionGate.isSubmitting
                                || !model.secureMessagingAvailable
                                || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                    }
                }
            }
            .interactiveDismissDisabled(submissionGate.isSubmitting)
            .task { await loadContacts() }
            .task(id: KitUserSearchTaskKey(query: query, isOnline: model.isOnline)) {
                await searchDirectory()
            }
        }
    }

    @MainActor
    private func submit(to contact: WalletContactDTO) {
        guard let key = NewMessageSubmissionKey(
            recipientUserID: contact.id,
            body: message
        ),
              let clientMessageID = submissionGate.begin(key: key)
        else { return }
        let submittedBody = message

        Task { @MainActor in
            let result = await model.queueDirectMessageResult(
                recipientId: contact.id,
                title: contact.name,
                body: submittedBody,
                clientMessageID: clientMessageID
            )
            submissionGate.finish(
                clientMessageID: clientMessageID,
                succeeded: result != nil
            )
            guard let result else { return }
            message = ""
            onQueued(result.conversation)
        }
    }

    private func contactLabel(_ contact: WalletContactDTO, trailingText: String?) -> some View {
        HStack(spacing: 12) {
            RemoteAvatarView(name: contact.name, avatarURL: contact.avatarURL, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(contact.name)
                    .font(.headline)
                    .foregroundStyle(KitColor.primaryText)
                Text(contact.phone.nilIfBlank ?? "Kit Pay member")
                    .font(.caption)
                    .foregroundStyle(KitColor.secondaryText)
            }
            Spacer()
            if let trailingText {
                Text(trailingText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(contact.isKitUser == true ? KitColor.green : KitColor.primaryText)
            }
        }
        .contentShape(Rectangle())
    }

    private func inviteText(for contact: WalletContactDTO) -> String {
        "Hi \(contact.name), join me on Kit Pay to message, call, and send money securely: https://pay.kit.africa"
    }

    @MainActor
    private func loadContacts() async {
        guard model.isSignedIn, model.isOnline, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        await model.loadContactDirectory()
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

private func deliveryIcon(_ state: MessageDeliveryState) -> String {
    switch state {
    case .queued, .encrypting: "clock"
    case .sending: "arrow.up.circle"
    case .sent: "checkmark"
    case .delivered: "checkmark.circle"
    case .read: "checkmark.circle.fill"
    case .failed: "exclamationmark.circle"
    case .received: "arrow.down"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
