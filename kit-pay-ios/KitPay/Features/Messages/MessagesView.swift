import Contacts
import ContactsUI
import CoreTransferable
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
    @ObservedObject private var presence = KitPresenceCenter.shared
    @Binding var isConversationPresented: Bool
    @State private var navigationPath: [Conversation] = []
    @State private var showNewMessage = false
    @State private var newMessageContact: WalletContactDTO?
    @State private var newMessagePresentationID = UUID()
    @State private var queuedNewMessageConversation: Conversation?
    @State private var showGlobalSearch = false
    @State private var pendingSearchConversation: Conversation?
    @State private var pendingSearchMessageID: UUID?
    @State private var pendingSearchContact: WalletContactDTO?
    @State private var selectedFilter: ConversationListFilter = .all
    @State private var showBackupSettings = false
    @State private var showGroupCreate = false
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
                    .environmentObject(model)
                }
                .sheet(isPresented: $showBackupSettings) {
                    NavigationStack { ChatBackupSettingsView() }
                        .environmentObject(model)
                        .presentationBackground(.ultraThinMaterial)
                }
                .sheet(isPresented: $showGroupCreate) {
                    GroupCreateView(
                        createGroup: { name, memberUserIDs in
                            await model.createGroupConversation(
                                name: name,
                                memberUserIDs: memberUserIDs
                            )
                        },
                        onCreated: { conversationID in
                            showGroupCreate = false
                            if let created = model.state.conversations.first(where: {
                                $0.id.caseInsensitiveCompare(conversationID) == .orderedSame
                            }) {
                                navigationPath.append(created)
                            }
                        }
                    )
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
                            pendingSearchMessageID = nil
                            showGlobalSearch = false
                        },
                        selectMessage: { hit in
                            pendingSearchConversation = hit.conversation
                            pendingSearchMessageID = hit.message.id
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
        .onChange(of: model.pendingNewMessageComposeID) { _, _ in
            applyPendingNewMessageCompose()
        }
        .onChange(of: model.state.conversations) { _, _ in
            applyMessageNotificationNavigation()
        }
        .onAppear {
            // The Messages tab can be built lazily AFTER Home has already raised the request,
            // in which case onChange never fires for it — apply on appearance too.
            applyPendingNewMessageCompose()
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
        let resolvedActiveCallConversationID = model.resolvedConversationID(
            forActiveCall: callMedia.activeCall
        )

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
                                    resolvedConversationId: resolvedActiveCallConversationID,
                                    isConnected: callMedia.state == .connected,
                                    hasRemoteParticipant: callTransport.hasRemoteParticipant
                                ),
                                isVideoCall: callMedia.activeCall?.video == true,
                                typingLabel: presence.typingUserIDs(
                                    in: conversation.id
                                ).isEmpty ? nil : "typing…"
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
                    if model.messagingGroupsEnabled {
                        Button {
                            showGroupCreate = true
                        } label: {
                            Label("New group", systemImage: "person.3")
                        }
                    }
                    Button {
                        withAnimation(.snappy(duration: 0.22)) { isSelectingChats = true }
                    } label: {
                        Label("Select chats", systemImage: "checkmark.circle")
                    }
                    .disabled(!model.appReviewDemoMutationsAllowed)
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
                .disabled(!model.appReviewDemoMutationsAllowed)
                .accessibilityValue(
                    model.appReviewDemoMutationsAllowed ? "" : "Unavailable in read-only demo"
                )
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
        var typingLabel: String? = nil
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
            .disabled(model.isReadOnlyAppReviewDemoConversation(conversation.id))
            .accessibilityAddTraits(context.isSelected ? .isSelected : [])
        } else {
            Button {
                if context.activeCallLabel != nil {
                    CallOverlayWindowController.shared.reopenActiveCall()
                } else {
                    navigationPath.append(conversation)
                }
            } label: {
                chatRowContent(conversation, context: context)
            }
            .buttonStyle(.plain)
            .accessibilityHint(
                context.activeCallLabel == nil
                    ? "Opens this conversation"
                    : "Returns to the ongoing call"
            )
            .contextMenu {
                if model.isReadOnlyAppReviewDemoConversation(conversation.id) {
                    Label("Read-only App Review preview", systemImage: "eye.fill")
                } else {
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
    }

    private func chatRowContent(_ conversation: Conversation, context: ChatRowContext) -> some View {
        HStack(spacing: 12) {
            if context.isSelecting {
                Image(systemName: context.isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(context.isSelected ? KitColor.green : KitColor.secondaryText.opacity(0.5))
                    .accessibilityHidden(true)
            }

            if conversation.isGroup {
                GroupAvatarView(
                    title: context.displayName,
                    photoURL: context.avatarURL,
                    size: 52
                )
            } else {
                RemoteAvatarView(
                    name: context.displayName,
                    avatarURL: context.avatarURL,
                    size: 52
                )
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(context.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(KitColor.navy)
                        .lineLimit(1)
                    if model.isReadOnlyAppReviewDemoConversation(conversation.id) {
                        Image(systemName: "eye.fill")
                            .font(.caption2)
                            .foregroundStyle(KitColor.secondaryText)
                            .accessibilityLabel("Read-only App Review preview")
                    }
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
                        HStack(spacing: 5) {
                            Image(systemName: context.isVideoCall ? "video.fill" : "phone.fill")
                                .font(.caption2)
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                Text(
                                    ConversationCallIndicatorPolicy.label(
                                        for: conversation.id,
                                        activeCall: callMedia.activeCall,
                                        resolvedConversationId: model.resolvedConversationID(
                                            forActiveCall: callMedia.activeCall
                                        ),
                                        isConnected: callMedia.state == .connected,
                                        hasRemoteParticipant: callTransport.hasRemoteParticipant,
                                        elapsedSeconds: callMedia.presentedCallDurationSeconds()
                                    ) ?? activeCallLabel
                                )
                                .lineLimit(1)
                            }
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(KitColor.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(KitColor.green.opacity(0.11), in: Capsule())
                    } else if let typingLabel = context.typingLabel {
                        Text(typingLabel)
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
        guard !model.isReadOnlyAppReviewDemoConversation(conversationID) else { return }
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
        pendingSearchMessageID = nil
        pendingSearchContact = nil
        navigationPath = [conversation]
        isConversationPresented = true
        if request.messageID == nil {
            model.consumeMessageConversationNavigationRequest(request.id)
        }
    }

    private func openNewMessage(contact: WalletContactDTO? = nil) {
        guard model.appReviewDemoMutationsAllowed else {
            model.lastError = AppReviewDemoMutationPolicy.readOnlyMessage
            return
        }
        newMessagePresentationID = UUID()
        queuedNewMessageConversation = nil
        newMessageContact = contact
        showNewMessage = true
    }

    /// Opens the contact picker for a cross-tab compose request, consuming the request only
    /// after the presentation state is set so a consumed-but-unpresented ask cannot occur.
    private func applyPendingNewMessageCompose() {
        guard let requestID = model.pendingNewMessageComposeID else { return }
        newMessageContact = nil
        newMessagePresentationID = UUID()
        showNewMessage = true
        model.consumeNewMessageComposeRequest(requestID)
    }

    private func finishNewMessagePresentation() {
        newMessageContact = nil
        guard let conversation = queuedNewMessageConversation else { return }
        queuedNewMessageConversation = nil
        navigationPath = [conversation]
    }

    private func finishGlobalSearch() {
        if let conversation = pendingSearchConversation {
            let messageID = pendingSearchMessageID
            pendingSearchConversation = nil
            pendingSearchMessageID = nil
            pendingSearchContact = nil
            if let messageID {
                _ = model.requestConversationNavigation(
                    conversationID: conversation.id,
                    messageID: messageID
                )
            } else {
                navigationPath.append(conversation)
            }
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
                // A group that shrank to these two members is still a group thread and must
                // never masquerade as the direct conversation.
                !conversation.isGroup
                    && Set(conversation.participantUserIds.compactMap { canonicalUserID($0) })
                        == directParticipants
            }
            .max { $0.updatedAt < $1.updatedAt }
    }
}

private func chatListTimestamp(_ date: Date) -> String {
    let calendar = AppPresentationClock.calendar
    let now = AppPresentationClock.now
    if calendar.isDate(date, inSameDayAs: now) {
        return AppPresentationClock.shortTime(date)
    }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
       calendar.isDate(date, inSameDayAs: yesterday) {
        return "Yesterday"
    }
    if let weekAgo = calendar.date(byAdding: .day, value: -6, to: now), date >= weekAgo {
        return AppPresentationClock.abbreviatedWeekday(date)
    }
    return AppPresentationClock.numericDate(date)
}

// MARK: - Global search

private struct MessageGlobalSearchView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var debouncedQuery = ""
    @FocusState private var searchIsFocused: Bool

    let selectConversation: (Conversation) -> Void
    let selectMessage: (MessageGlobalMessageHit) -> Void
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
                                Button { selectMessage(hit) } label: {
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
            Text(AppPresentationClock.abbreviatedDate(hit.conversation.updatedAt))
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
                    Text(AppPresentationClock.abbreviatedDate(hit.message.createdAt))
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

/// What the schedule sheet is being opened for. `existingItem` is nil when the composer is
/// arranging a new send and set when an already-scheduled item is being moved.
private struct ChatScheduleRequest: Identifiable {
    let id: UUID
    let existingItem: ScheduledChatItem?
    let preview: String

    var title: String { existingItem == nil ? "Send later" : "Edit schedule" }
    var confirmTitle: String { existingItem == nil ? "Schedule" : "Save" }
}

private enum GroupProfileFollowUp {
    case addMember
    case mediaLibrary
    case leaveCompleted
}

struct ConversationView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismissConversation
    @StateObject private var callMedia = CallMediaCoordinator.shared
    @ObservedObject private var callTransport = CallMediaCoordinator.shared.media
    let conversation: Conversation
    @State private var draft = ""
    @State private var showPhotoPicker = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var stagedAttachments: [ChatStagedAttachment] = []
    @State private var isLoadingAttachment = false
    @State private var attachmentLoadGeneration = 0
    @State private var isSending = false
    @State private var scheduleRequest: ChatScheduleRequest?
    @State private var retryingMessageIDs: Set<UUID> = []
    @State private var didRestoreDraft = false
    @State private var draftWriteVersion: ConversationDraftWriteVersion?
    @State private var immediateDraftPersistenceTask: Task<Void, Never>?
    @State private var showPaymentRequest = false
    @State private var showSendMoney = false
    @State private var showContactProfile = false
    @State private var showGroupProfile = false
    @State private var showGroupMemberPicker = false
    @State private var showGroupMediaLibrary = false
    @State private var groupProfileFollowUp: GroupProfileFollowUp?
    @State private var abuseReportPresentation: ConversationAbuseReportPresentation?
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
    /// Claims the one non-animated jump each conversation needs after its lazy timeline has
    /// appeared. `defaultScrollAnchor` alone runs before restored messages and hydrated payment
    /// cards have necessarily reached their final size.
    @State private var latestPositionPolicy = ConversationLatestPositionPolicy()
    @State private var deferredLatestPositionRequest = 0
    @State private var cameraPullProgress: CGFloat = 0
    @State private var cameraPull = ConversationCameraPullGesture()
    /// Whether a finger is currently on the thread, as reported by the scroll view itself.
    /// Only the scroll view knows this once it has taken the drag over, which it always does.
    @State private var isConversationScrollInteracting = false
    @State private var conversationContentHeight: CGFloat = 0
    @State private var conversationViewportHeight: CGFloat = 0
    @State private var pendingScrollTargetMessageID: UUID?
    /// A notification, global result, or floating player can address one exact local message.
    /// The short-lived treatment confirms arrival without leaving a permanent selected state.
    @State private var highlightedMessageID: UUID?
    @State private var galleryTarget: ConversationGalleryTarget?
    @State private var editorSession: MediaEditorSession?
    @State private var reactionPickerTarget: LocalMessage?
    @State private var reactionDetailTarget: LocalMessage?
    /// The message whose delivery details are on screen. Held as its server identity rather than
    /// the row itself, so the sheet keeps asking about the same message even if the thread reloads
    /// underneath it.
    @State private var messageInfoTarget: MessageInfoTarget?
    /// The message the composer is currently answering. One choice for the whole composer, so a
    /// typed line, a photo and a voice note all answer whatever the user swiped.
    @State private var replyTarget: LocalMessage?
    /// The message whose wording is being corrected, chosen from its long-press menu.
    @State private var editTarget: LocalMessage?
    /// A correction is written in its own field rather than in the composer's, so half a sentence
    /// someone had already typed survives being interrupted — and so the draft store, which
    /// mirrors the composer, is never handed wording that belongs to a message already sent.
    @State private var editDraft = ""
    @State private var isSubmittingEdit = false
    /// Re-read on a timer so the edit affordance disappears when the fifteen minutes run out,
    /// rather than lingering until some unrelated redraw.
    @State private var editWindowNow = AppPresentationClock.now
    /// The share this conversation has already taken, so a redraw cannot stage it twice.
    @State private var appliedSharedDeliveryID: UUID?
    /// The exact draft that existed before shared text was appended. Re-routing removes the
    /// inserted span only when doing so cannot destroy wording the customer edited afterwards.
    @State private var appliedSharedOriginalDraft: String?
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
    @StateObject private var chatGroupPayments = ChatGroupPaymentsViewModel()
    @StateObject private var chatGroupPaymentRequests = ChatGroupPaymentRequestsViewModel()
    @StateObject private var chatScheduledPayments = ChatScheduledPaymentsViewModel()
    @StateObject private var chatScheduledGroupPayments = ChatScheduledGroupPaymentsViewModel()
    @ObservedObject private var presence = KitPresenceCenter.shared
    @State private var transferReverseTarget: ChatTransferReverseTarget?
    @State private var transferRejectTarget: ChatTransferRejectTarget?
    @State private var groupPaymentDeclineTarget: GroupPaymentDeclineTarget?
    @State private var groupPaymentReturnTarget: GroupPaymentReturnTarget?
    @State private var groupPaymentComposer: GroupPaymentComposerTarget?
    @State private var groupPaymentRequestComposer: GroupPaymentRequestComposerTarget?
    @State private var groupPaymentRequestContribution: GroupPaymentRequestContributionTarget?
    @State private var groupPaymentRequestCancellation: GroupPaymentRequestCancellationTarget?
    @StateObject private var voiceRecorder: VoiceNoteRecorder
    @FocusState private var isComposerFocused: Bool

    init(conversation: Conversation) {
        self.conversation = conversation
        _incomingSoundPolicy = State(
            initialValue: VisibleConversationSoundPolicy(conversationID: conversation.id)
        )
        // From the registry, not constructed here: the draft must survive this view being
        // torn down and remade, so a paused note is still waiting when the user comes back.
        _voiceRecorder = StateObject(
            wrappedValue: VoiceNoteDraftRegistry.shared.recorder(for: conversation.id)
        )
    }

    private var messages: [LocalMessage] { correctedProjection.messages }

    /// The thread as it currently reads, with every correction already applied.
    ///
    /// Applying the fold here rather than at each bubble is what keeps the whole screen honest
    /// about one thing at a time: quotes, search, selection, forwarding and the notification
    /// preview all read from this, so none of them can go on showing wording its author has
    /// already withdrawn. The correction rows themselves are dropped — they are instructions
    /// about a message, never messages.
    private var correctedProjection: (messages: [LocalMessage], editedAt: [UUID: Date]) {
        // A Send Later message is shown in its own section under the timeline, not inline: it has
        // not happened yet, and a bubble sitting among sent messages would read as if it had.
        let waiting = scheduledMessageIDs
        let visible = model.state.messages.filter {
            $0.conversationId == conversation.id && !waiting.contains($0.id)
        }
        let corrections = MessageEditAggregationPolicy.appliedEdits(in: visible)
        let instructions = MessageEditAggregationPolicy.suppressedMessageIDs(in: visible)
        var editedAt: [UUID: Date] = [:]
        var projected: [LocalMessage] = []
        projected.reserveCapacity(visible.count)
        for message in visible where !instructions.contains(message.id) {
            guard let serverMessageID = message.serverMessageId?.lowercased(),
                  let correction = corrections[serverMessageID]
            else {
                projected.append(message)
                continue
            }
            var corrected = message
            corrected.body = correction.body
            editedAt[message.id] = correction.editedAt
            projected.append(corrected)
        }
        projected.sort { $0.timelineDate < $1.timelineDate }
        return (projected, editedAt)
    }

    private var currentConversation: Conversation {
        model.state.conversations.first(where: {
            $0.id.caseInsensitiveCompare(conversation.id) == .orderedSame
        }) ?? conversation
    }

    private var scheduledItems: [ScheduledChatItem] {
        model.scheduledChatItems(
            conversationID: conversation.id,
            at: AppPresentationClock.now
        )
    }

    private var scheduledMessageIDs: Set<UUID> {
        Set(
            scheduledItems.compactMap {
                if case .message(let id) = $0.content { return id }
                return nil
            }
        )
    }

    private var scheduledPaymentsEnabled: Bool {
        !isReadOnlyAppReviewPreview
            && !isGroupConversation
            && ScheduledPaymentPolicy(capabilities: model.capabilities).chatEnabled
    }

    private var terminalScheduledPaymentIDs: Set<String> {
        Set(timelineItems.compactMap { item in
            guard case .scheduledPayment(_, let descriptor) = item else { return nil }
            return descriptor.scheduledPaymentID
        })
    }

    private var pendingScheduledPayments: [ScheduledPaymentDTO] {
        chatScheduledPayments.items.filter {
            !terminalScheduledPaymentIDs.contains($0.id.lowercased())
        }
    }

    private var scheduledPaymentLoadID: String {
        let terminal = terminalScheduledPaymentIDs.sorted().joined(separator: ",")
        return "\(model.isOnline):\(scheduledPaymentsEnabled):\(conversation.id.lowercased()):\(terminal)"
    }

    private var timelineItems: [ConversationTimelineItem] {
        ConversationTimelinePolicy.items(
            for: conversation,
            allConversations: model.state.conversations,
            currentUserID: model.profile?.id,
            messages: messages,
            calls: model.state.calls,
            dateSeparatorsRelativeTo: AppPresentationClock.now,
            calendar: AppPresentationClock.calendar,
            locale: AppPresentationClock.locale
        )
    }

    private var recipientPresentation: ConversationContactPresentation {
        ConversationContactPresentationPolicy.presentation(
            // Group identity can change while this screen and its full-screen profile remain
            // mounted. Resolve from the latest store projection so a newly attached group photo
            // replaces the generated avatar without requiring the chat to be closed and reopened.
            for: currentConversation,
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

    private func abuseReportContext(reportedUserID: String?) -> AbuseReportContext? {
        AbuseReportContext(
            currentUserID: model.profile?.id,
            reportedUserID: reportedUserID,
            conversation: currentConversation
        )
    }

    private var recipientCommunicationAllowed: Bool {
        // Group sends have no single peer to gate on; per-member policy runs server-side and
        // at the encrypted fanout. Blocking still bites in 1:1 threads.
        if isGroupConversation { return true }
        return model.communicationPrivacyAllowsOutbound(to: recipientUserID)
    }

    /// Existing group history remains readable when the rollout gate is absent or withdrawn,
    /// but every local mutation stays disabled until the server advertises the protocol again.
    private var conversationMessagingAvailable: Bool {
        guard MessagingGroupCapabilityPolicy.allowsConversationMutation(
            isGroup: isGroupConversation,
            groupCapabilityEnabled: model.messagingGroupsEnabled
        ) else { return false }
        return !isGroupConversation || currentUserIsGroupMember
    }

    private var currentUserIsGroupMember: Bool {
        guard let currentUserID = canonicalUserID(model.profile?.id) else { return false }
        return currentConversation.participantUserIds.contains {
            canonicalUserID($0) == currentUserID
        }
    }

    private var isReadOnlyAppReviewPreview: Bool {
        model.isReadOnlyAppReviewDemoConversation(conversation.id)
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var showsSendButton: Bool {
        isLoadingAttachment || !trimmedDraft.isEmpty || !stagedAttachments.isEmpty
    }

    private var canSendMessage: Bool {
        let hasAttachment = !stagedAttachments.isEmpty
        return !isReadOnlyAppReviewPreview
            && model.secureMessagingAvailable
            && conversationMessagingAvailable
            && recipientCommunicationAllowed
            && !isSending
            && !isLoadingAttachment
            && (hasAttachment || !trimmedDraft.isEmpty)
    }

    private var cameraPullIsEligible: Bool {
        !isReadOnlyAppReviewPreview && conversationMessagingAvailable
            && ConversationCameraPullPolicy.isEligible(
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
            features: isReadOnlyAppReviewPreview ? nil : model.capabilities?.features,
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
        !isReadOnlyAppReviewPreview
            && TransferAcceptancePolicy(features: model.capabilities?.features).acceptanceEnabled
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

    private var groupPaymentsEnabled: Bool {
        !isReadOnlyAppReviewPreview
            && isGroupConversation
            && GroupPaymentPolicy(features: model.capabilities?.features).groupPaymentsEnabled
    }

    /// Payments this thread announces, in the order they were announced.
    private var conversationGroupPaymentIDs: [String] {
        timelineItems.compactMap { item in
            guard case .groupPayment(_, let descriptor) = item else { return nil }
            return descriptor.groupPaymentId
        }
    }

    /// Re-reads group payment authority whenever a payment is announced or answered — which is
    /// exactly when a card's buttons and counts go stale — or when connectivity returns.
    private var groupPaymentLoadID: String {
        let eventIDs = timelineItems.compactMap { item -> String? in
            switch item {
            case .groupPayment(let message, _), .groupPaymentEvent(let message, _):
                return message.id.uuidString.lowercased()
            default:
                return nil
            }
        }
        return "\(model.isOnline):\(groupPaymentsEnabled):\(eventIDs.joined(separator: ","))"
    }

    private var groupPaymentRequestsEnabled: Bool {
        !isReadOnlyAppReviewPreview
            && isGroupConversation
            && GroupPaymentRequestPolicy(capabilities: model.capabilities).enabled
    }

    private var scheduledGroupPaymentsEnabled: Bool {
        !isReadOnlyAppReviewPreview
            && isGroupConversation
            && ScheduledGroupPaymentPolicy(capabilities: model.capabilities).enabled
    }

    private var scheduledGroupPaymentLoadID: String {
        let known = chatScheduledGroupPayments.items.map(\.id).sorted().joined(separator: ",")
        let terminal = timelineItems.compactMap { item -> String? in
            switch item {
            case .scheduledGroupPaymentOutcome(let message, _),
                 .groupPayment(let message, _):
                return message.id.uuidString.lowercased()
            default:
                return nil
            }
        }.joined(separator: ",")
        return "\(model.isOnline):\(scheduledGroupPaymentsEnabled):\(conversation.id.lowercased()):\(known):\(terminal)"
    }

    private var conversationGroupPaymentRequestIDs: [String] {
        timelineItems.compactMap { item in
            switch item {
            case .groupPaymentRequest(_, let descriptor),
                 .groupPaymentRequestEvent(_, let descriptor):
                return descriptor.requestID
            default:
                return nil
            }
        }
    }

    private var conversationGroupPaymentContributionReferences:
        [GroupPaymentRequestContributionReference] {
        timelineItems.compactMap { item in
            guard case .groupPaymentRequestEvent(_, let descriptor) = item,
                  descriptor.action == .contributed || descriptor.action == .completed,
                  let contributionID = descriptor.contributionID
            else { return nil }
            return GroupPaymentRequestContributionReference(
                requestID: descriptor.requestID,
                contributionID: contributionID,
                requiresExactRead: descriptor.action == .completed
            )
        }
    }

    private var groupPaymentRequestLoadID: String {
        let eventIDs = timelineItems.compactMap { item -> String? in
            switch item {
            case .groupPaymentRequest(let message, _),
                 .groupPaymentRequestEvent(let message, _):
                return message.id.uuidString.lowercased()
            default:
                return nil
            }
        }
        return "\(model.isOnline):\(groupPaymentRequestsEnabled):\(eventIDs.joined(separator: ","))"
    }

    /// Members of this group who could be paid: everyone but the account holder.
    private var groupPaymentMembers: [GroupPaymentDraftPolicy.Member] {
        let selfID = model.profile?.id.lowercased()
        return currentConversation.participantUserIds
            .map { $0.lowercased() }
            .filter { $0 != selfID }
            .map {
                GroupPaymentDraftPolicy.Member(
                    userId: $0,
                    name: participantDisplayName(for: $0)
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        conversationLifecycle
            // A voice note keeps playing after this screen is gone, so the floating bar needs to
            // be able to name it. Only this screen can turn a sender id into "You", a contact, or
            // a neutral fallback, so the resolver travels with the thread.
            .environment(
                \.voiceNoteChatContext,
                VoiceNoteChatContext(
                    conversationID: conversation.id,
                    conversationTitle: currentConversation.title,
                    displayName: { participantDisplayName(for: $0) }
                )
            )
    }

    // MARK: Presence & typing

    private var isGroupConversation: Bool { currentConversation.isGroup }

    /// "typing…" (or names in groups) — sourced from the realtime presence center; empty until
    /// the realtime transport is connected, never guessed.
    private var conversationTypingLabel: String? {
        guard model.messagingPresenceEnabled, presence.broadcastsPresence else { return nil }
        let selfID = model.profile?.id.lowercased()
        let typingIDs = presence.typingUserIDs(in: conversation.id)
            .filter { $0 != selfID }
        guard !typingIDs.isEmpty else { return nil }
        if isGroupConversation {
            return KitPresencePolicy.typingLabel(
                names: typingIDs.map { participantDisplayName(for: $0) }
            )
        }
        return "typing…"
    }

    private var presenceSubtitle: String? {
        if let typing = conversationTypingLabel { return typing }
        if isGroupConversation {
            let count = currentConversation.participantUserIds.count
            return "\(count) member\(count == 1 ? "" : "s")"
        }
        guard model.messagingPresenceEnabled, presence.broadcastsPresence else { return nil }
        guard let peer = recipientUserID else { return nil }
        return KitPresencePolicy.lastSeenLabel(
            for: presence.presenceState(for: peer),
            now: Date()
        )
    }

    private var presenceSubtitleIsLive: Bool {
        guard model.messagingPresenceEnabled, presence.broadcastsPresence else { return false }
        if conversationTypingLabel != nil { return true }
        return presence.isPeerOnline(recipientUserID)
    }

    /// Group lifecycle notices render as centered chips, mirroring the date separators.
    private func systemEventChip(_ event: KitSystemMessage) -> some View {
        Text(systemEventText(event))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(KitColor.secondaryText)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityLabel(systemEventText(event))
    }

    private func systemEventText(_ event: KitSystemMessage) -> String {
        let subject = participantDisplayName(for: event.subjectUserID)
        let actor = event.actorUserID.map { participantDisplayName(for: $0) }
        switch event.kind {
        case .memberAdded:
            if let actor, actor != subject {
                return "\(actor) added \(subject)"
            }
            return "\(subject) joined the group"
        case .memberRemoved:
            if let actor, actor != subject {
                return "\(actor) removed \(subject)"
            }
            return "\(subject) was removed"
        case .memberLeft:
            return "\(subject) left the group"
        }
    }

    /// The long-press menu for one message. Album members get the same menu their standalone
    /// siblings get, so a photo inside a run of photos can still be answered or reacted to.
    @ViewBuilder
    private func messageContextMenu(_ message: LocalMessage) -> some View {
        if !isSelectingMessages {
            if canReply(to: message) {
                Button {
                    beginReply(to: message)
                } label: {
                    Label("Reply", systemImage: "arrowshape.turn.up.left")
                }
            }
            if !isReadOnlyAppReviewPreview,
               conversationMessagingAvailable,
               message.serverMessageId != nil,
               model.messagingReactionsEnabled {
                ControlGroup {
                    ForEach(
                        MessageReactionAggregationPolicy.quickReactions,
                        id: \.self
                    ) { emoji in
                        Button(emoji) {
                            Task { await toggleReaction(emoji, on: message) }
                        }
                    }
                    Button {
                        reactionPickerTarget = message
                    } label: {
                        Label("More reactions", systemImage: "plus.circle")
                    }
                }
                .controlGroupStyle(.palette)
            }
            if canEdit(message) {
                Button {
                    beginEdit(message)
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
            }
            if let copyText = copyableText(for: message) {
                Button {
                    UIPasteboard.general.string = copyText
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
            if let infoTarget = deliveryInfoTarget(for: message) {
                Button {
                    messageInfoTarget = infoTarget
                } label: {
                    Label("Info", systemImage: "info.circle")
                }
            }
            if !isReadOnlyAppReviewPreview,
               !forwardPayloadItems(for: [message.id]).isEmpty {
                Button {
                    forwardItems = forwardPayloadItems(for: [message.id])
                    showForwardSheet = true
                } label: {
                    Label("Forward", systemImage: "arrowshape.turn.up.right")
                }
            }
            if !isReadOnlyAppReviewPreview {
                Button {
                    withAnimation(.snappy(duration: 0.22)) {
                        isSelectingMessages = true
                        selectedMessageIDs = [message.id]
                        isComposerFocused = false
                    }
                } label: {
                    Label("Select", systemImage: "checkmark.circle")
                }
                if AbuseReportContract.isAvailable(
                    features: model.capabilities?.features
                ),
                   let context = abuseReportContext(
                       reportedUserID: message.senderId
                   ),
                   let reportTarget = AbuseReportTarget.message(
                       message,
                       context: context
                   ) {
                    Divider()
                    Button(role: .destructive) {
                        abuseReportPresentation = ConversationAbuseReportPresentation(
                            context: context,
                            target: reportTarget,
                            reportedName: isGroupConversation
                                ? participantDisplayName(for: message.senderId)
                                : recipientDisplayName
                        )
                    } label: {
                        Label("Report message", systemImage: "exclamationmark.bubble")
                    }
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
    }

    // MARK: Delivery details

    /// The delivery details this message can be asked about, or nothing.
    ///
    /// Only messages this account sent, and only once the server has given one an identity: the
    /// server answers this question to the sender alone, so offering it on somebody else's message
    /// would promise an answer that is always a refusal.
    private func deliveryInfoTarget(for message: LocalMessage) -> MessageInfoTarget? {
        guard !isReadOnlyAppReviewPreview,
              conversationMessagingAvailable,
              model.secureMessagingAvailable,
              message.isOutgoing,
              let serverMessageID = message.serverMessageId
        else { return nil }
        return MessageInfoTarget(
            conversationID: conversation.id,
            serverMessageID: serverMessageID
        )
    }

    // MARK: Replies

    /// Whether this message can be answered right now. Beyond the message itself being an
    /// answerable one, the thread has to be in a state where anything can be sent at all.
    private func canReply(to message: LocalMessage) -> Bool {
        !isReadOnlyAppReviewPreview
            && !isSelectingMessages
            && conversationMessagingAvailable
            && model.secureMessagingAvailable
            && MessageReplyQuotePolicy.canReply(to: message)
    }

    private func beginReply(to message: LocalMessage) {
        guard canReply(to: message) else { return }
        withAnimation(.snappy(duration: 0.2)) {
            editTarget = nil
            replyTarget = message
        }
        editDraft = ""
        isComposerFocused = true
    }

    private func cancelReply() {
        withAnimation(.snappy(duration: 0.2)) { replyTarget = nil }
    }

    /// The quote drawn above `message`, resolved from history this device already holds.
    private func quote(for message: LocalMessage) -> MessageReplyQuote? {
        MessageReplyQuotePolicy.quote(
            for: message,
            in: messages,
            currentUserID: model.profile?.id,
            displayName: { participantDisplayName(for: $0) }
        )
    }

    /// "You", the sender's name, or — when this device cannot name them — the thread's own name.
    private func quoteAuthorLabel(_ quote: MessageReplyQuote) -> String {
        if quote.authorIsSelf { return "You" }
        return quote.authorName?.nilIfBlank
            ?? (isGroupConversation ? "Message" : recipientDisplayName)
    }

    /// Scrolls to the message a quote points at, when it is still in the loaded thread.
    private func jumpToQuoted(_ targetServerMessageID: String) {
        guard let target = messages.first(where: {
            $0.serverMessageId?.lowercased() == targetServerMessageID
        }) else { return }
        pendingScrollTargetMessageID = target.id
    }

    @ViewBuilder
    private func quotedBlock(for message: LocalMessage) -> some View {
        if let quote = quote(for: message) {
            QuotedMessagePreview(
                authorLabel: quoteAuthorLabel(quote),
                preview: quote.preview,
                accent: message.isOutgoing ? .white.opacity(0.9) : KitColor.green,
                textColor: message.isOutgoing ? .white : KitColor.primaryText,
                background: message.isOutgoing
                    ? Color.white.opacity(0.16)
                    : KitColor.green.opacity(0.10),
                onTap: { jumpToQuoted(quote.targetServerMessageID) }
            )
        }
    }

    /// The bar above the composer while an answer is being written.
    @ViewBuilder
    private var replyComposerBar: some View {
        if let target = replyTarget {
            let name = target.isOutgoing ? "You" : participantDisplayName(for: target.senderId)
            HStack(spacing: 8) {
                QuotedMessagePreview(
                    authorLabel: name,
                    preview: MessageReplyQuotePolicy.previewText(for: target),
                    accent: KitColor.green,
                    textColor: KitColor.primaryText,
                    background: .clear
                )
                Button {
                    cancelReply()
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(KitColor.secondaryText)
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .accessibilityLabel("Cancel reply")
            }
            .padding(.leading, 4)
            .padding(.trailing, 2)
            .background(
                KitColor.green.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: Edits

    /// Ticks while a correction is being written. Fifteen minutes is short enough that a stale
    /// composer is a real possibility, and long enough that a per-frame clock would be waste.
    private static let editWindowTicker = Timer
        .publish(every: 15, on: .main, in: .common)
        .autoconnect()

    /// Whether this message can still be reworded right now. Beyond the message itself being
    /// one's own recent words, the thread has to be in a state where anything can be sent at all.
    private func canEdit(
        _ message: LocalMessage,
        now: Date = AppPresentationClock.now
    ) -> Bool {
        !isReadOnlyAppReviewPreview
            && !isSelectingMessages
            && conversationMessagingAvailable
            && recipientCommunicationAllowed
            && model.messagingMessageEditsEnabled
            && MessageEditAggregationPolicy.canEdit(message, now: now)
    }

    private func beginEdit(_ message: LocalMessage) {
        guard canEdit(message) else { return }
        withAnimation(.snappy(duration: 0.2)) {
            // Answering and correcting are two different things to be doing with a message, and
            // the composer can only be doing one of them.
            replyTarget = nil
            editDraft = message.body
            editWindowNow = AppPresentationClock.now
            editTarget = message
        }
        isComposerFocused = true
    }

    private func cancelEdit() {
        withAnimation(.snappy(duration: 0.2)) { editTarget = nil }
        editDraft = ""
    }

    private var trimmedEditDraft: String {
        editDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmitEdit: Bool {
        guard let editTarget else { return false }
        return canEdit(editTarget, now: editWindowNow)
            && !isSubmittingEdit
            && !trimmedEditDraft.isEmpty
    }

    private func submitEdit() {
        guard let target = editTarget, canSubmitEdit else { return }
        guard let targetServerMessageID = target.serverMessageId?.lowercased() else { return }
        let replacement = trimmedEditDraft
        // Nothing to say: the wording is already what it was going to be.
        guard replacement != target.body else {
            cancelEdit()
            return
        }
        guard SecureMessageReservedPrefixPolicy.allowsUserAuthoredText(replacement) else {
            model.lastError = "Messages can't start with Kit Pay's reserved prefixes."
            return
        }
        guard let edit = KitMessageEdit(
            targetServerMessageID: targetServerMessageID,
            body: replacement
        ) else {
            model.lastError = "That wording is too long to send."
            return
        }
        isSubmittingEdit = true
        isComposerFocused = false
        Task {
            let queued = await model.queueEditEvent(
                conversationId: conversation.id,
                title: recipientDisplayName,
                recipientId: recipientUserID,
                edit: edit
            )
            isSubmittingEdit = false
            if queued { cancelEdit() }
        }
    }

    /// The bar above the composer while a correction is being written.
    @ViewBuilder
    private var editComposerBar: some View {
        if let target = editTarget {
            HStack(spacing: 8) {
                Image(systemName: "pencil")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(KitColor.green)
                    .padding(.leading, 8)
                QuotedMessagePreview(
                    authorLabel: "Edit message",
                    preview: MessageReplyQuotePolicy.previewText(for: target),
                    accent: KitColor.green,
                    textColor: KitColor.primaryText,
                    background: .clear
                )
                Button {
                    cancelEdit()
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(KitColor.secondaryText)
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .accessibilityLabel("Cancel edit")
            }
            .padding(.trailing, 2)
            .background(
                KitColor.green.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .onReceive(Self.editWindowTicker) { tick in
                editWindowNow = tick
                guard !MessageEditAggregationPolicy.canEdit(target, now: tick) else { return }
                // The server holds the authoritative clock and would refuse this now. Closing the
                // composer says so before the wording is typed out a second time.
                model.lastError = "That message can no longer be edited."
                cancelEdit()
            }
        }
    }

    /// A stripped-down composer row for corrections. Every "start something new" affordance —
    /// attachments, voice notes, payments, Send Later — is withdrawn, so no gesture can leave the
    /// mode by accident and end up sending the correction as a fresh message.
    private var editComposerRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Edit message", text: $editDraft, axis: .vertical)
                .lineLimit(1...5)
                .focused($isComposerFocused)
                .disabled(isSubmittingEdit)
                .padding(.leading, 14)
                .padding(.trailing, 10)
                .padding(.vertical, 10)
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(.white.opacity(0.55), lineWidth: 0.7)
                        .allowsHitTesting(false)
                }

            Button {
                submitEdit()
            } label: {
                Group {
                    if isSubmittingEdit {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "checkmark")
                            .font(.headline.bold())
                    }
                }
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(KitColor.green, in: Circle())
            }
            .disabled(!canSubmitEdit)
            .opacity(canSubmitEdit ? 1 : 0.55)
            .accessibilityLabel("Save the change")
        }
    }

    // MARK: Reactions

    /// Aggregated tallies keyed by the target's lowercase server message id.
    private var reactionTallies: [String: [MessageReactionTally]] {
        MessageReactionAggregationPolicy.tallies(
            in: messages,
            currentUserID: model.profile?.id
        )
    }

    /// How far the chip row rides up into the bubble it belongs to. The row reclaims the same
    /// amount of layout below it, so the chips read as part of the message rather than as a
    /// separate line under it.
    private static let reactionChipOverlap: CGFloat = 11

    private func reactionChips(
        _ tallies: [MessageReactionTally],
        for message: LocalMessage
    ) -> some View {
        HStack(spacing: 4) {
            ForEach(tallies) { tally in
                HStack(spacing: 4) {
                    Text(tally.emoji)
                        .font(.system(size: 15))
                    if tally.count > 1 {
                        Text("\(tally.count)")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(KitColor.primaryText)
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(.regularMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(
                            tally.includesCurrentUser
                                ? KitColor.green
                                : Color.white.opacity(0.4),
                            lineWidth: tally.includesCurrentUser ? 1.4 : 0.6
                        )
                        .allowsHitTesting(false)
                }
                // A soft rim lifts the chip off the bubble it overlaps, so the two stay legible
                // as one object with two parts rather than as a smudge.
                .shadow(color: .black.opacity(0.14), radius: 2.5, y: 1)
                .contentShape(Capsule())
                // Tap toggles; long-press ONLY opens the detail sheet. (The previous Button +
                // simultaneous long-press fired BOTH: the toggle mutated the user's reaction
                // while they were just looking at who reacted.) Tap is attached first so the
                // long-press recognizer cannot delay ordinary taps.
                .onTapGesture {
                    guard conversationMessagingAvailable else { return }
                    Task { await toggleReaction(tally.emoji, on: message) }
                }
                .onLongPressGesture {
                    reactionDetailTarget = message
                }
                .accessibilityLabel(
                    "\(tally.emoji), \(tally.count) reaction\(tally.count == 1 ? "" : "s")"
                        + (tally.includesCurrentUser ? ", including yours" : "")
                )
                .accessibilityAddTraits(.isButton)
            }
        }
        .padding(.horizontal, 10)
        // Drawn high, laid out low: the row overlaps the bubble's bottom edge and gives the
        // same distance back below, so nothing after it is pushed down.
        .offset(y: -Self.reactionChipOverlap)
        .padding(.bottom, -Self.reactionChipOverlap)
    }

    /// One reaction per person per message: tapping the emoji you already hold removes it;
    /// any other emoji replaces it. Sends ride the same offline-first encrypted queue as text.
    private func toggleReaction(_ emoji: String, on message: LocalMessage) async {
        guard conversationMessagingAvailable,
              let target = message.serverMessageId?.lowercased()
        else { return }
        let current = MessageReactionAggregationPolicy.currentUserReaction(
            to: target,
            in: messages,
            currentUserID: model.profile?.id
        )
        let operation: KitMessageReactionOperation = current == emoji ? .remove : .add
        guard let reaction = KitMessageReaction(
            operation: operation,
            targetServerMessageID: target,
            emoji: emoji
        ) else { return }
        _ = await model.queueReactionEvent(
            conversationId: conversation.id,
            title: recipientDisplayName,
            recipientId: recipientUserID,
            reaction: reaction
        )
    }

    /// Resolves a display name for a reactor or group member: "You", a synced contact's name,
    /// or a neutral fallback that never guesses.
    private func participantDisplayName(for userID: String) -> String {
        let canonical = userID.lowercased()
        if canonical == model.profile?.id.lowercased() { return "You" }
        if let contact = model.contactDirectory.first(where: {
            ContactRecipientDirectory.recipientUserId(for: $0) == canonical
        }) {
            return contact.name
        }
        if canonical == recipientUserID?.lowercased() { return recipientDisplayName }
        return "Kit Pay user"
    }

    private var conversationLayout: some View {
        // One pass per render for every whole-thread fold (albums, reaction suppression,
        // reaction tallies): computing these per bubble would be quadratic in long threads
        // and re-trigger on every keystroke.
        let projection = correctedProjection
        let timelineSnapshot = projection.messages
        let correctionDates = projection.editedAt
        let albumMembership: [UUID: ChatMediaAlbumMembership] =
            isSelectingMessages ? [:] : ChatMediaAlbumPolicy.membership(for: timelineSnapshot)
        let suppressedReactionIDs = MessageReactionAggregationPolicy.suppressedMessageIDs(
            in: timelineSnapshot
        )
        let hoistedTallies = MessageReactionAggregationPolicy.tallies(
            in: timelineSnapshot,
            currentUserID: model.profile?.id
        )
        // A sender's name heads a run of their messages rather than labelling every one of them.
        // Rows that render nothing are excluded, so a silent event by another member cannot make
        // the same person be introduced twice in a row.
        let namedSenderMessageIDs = ConversationSenderRunPolicy.namedMessageIDs(
            in: timelineItems,
            isGroup: isGroupConversation,
            isRendered: { message in
                rendersAsBubble(
                    message,
                    albumMembership: albumMembership,
                    suppressedReactionIDs: suppressedReactionIDs
                )
            }
        )
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
                                if let systemEvent = KitSystemMessage.parse(message.body) {
                                    // Only the coordinator authors system notices (no server
                                    // message id); an inbound peer-authored KITSYS1 body is a
                                    // forgery attempt and renders nothing — never a chip that
                                    // impersonates authoritative membership history.
                                    if message.serverMessageId == nil {
                                        systemEventChip(systemEvent)
                                    } else {
                                        EmptyView()
                                    }
                                } else if suppressedReactionIDs.contains(message.id)
                                    || SecureMessageReservedPrefixPolicy.beginsWithReservedPrefix(
                                        message.body,
                                        prefix: KitSystemMessage.prefix
                                    ) {
                                    // Reaction events render as chips on their target bubble;
                                    // malformed system wire stays invisible rather than raw.
                                    EmptyView()
                                } else if case .leader(let album) = albumMembership[message.id] {
                                    albumBubble(
                                        album,
                                        senderName: namedSenderMessageIDs.contains(message.id)
                                            ? participantDisplayName(for: message.senderId)
                                            : nil
                                    )
                                } else if albumMembership[message.id] != .follower {
                                    bubble(
                                        message,
                                        reactionTallies: hoistedTallies,
                                        showsSenderName: namedSenderMessageIDs.contains(message.id),
                                        editedAt: correctionDates[message.id]
                                    )
                                }
                            case .payment(let message, let descriptor):
                                paymentBubble(message, descriptor: descriptor)
                            case .scheduledPayment(let message, let descriptor):
                                scheduledPaymentReceipt(message, descriptor: descriptor)
                            case .scheduledGroupPaymentOutcome(_, let descriptor):
                                GroupPaymentOutcomeChip(
                                    text: descriptor.action == .failed
                                        ? "Scheduled group payment was not sent. No money moved."
                                        : "Scheduled group payment cancelled."
                                )
                            case .groupPayment(let message, let descriptor):
                                groupPaymentCard(message, descriptor: descriptor)
                            case .groupPaymentEvent(let message, let descriptor):
                                groupPaymentOutcome(message, descriptor: descriptor)
                            case .groupPaymentRequest(let message, let descriptor):
                                groupPaymentRequestCard(message, descriptor: descriptor)
                            case .groupPaymentRequestEvent(let message, let descriptor):
                                groupPaymentRequestOutcome(message, descriptor: descriptor)
                            case .call(let call):
                                callBubble(call)
                            case .dateSeparator(let separator):
                                dateSeparator(separator)
                            }
                        }
                        if !scheduledItems.isEmpty {
                            ScheduledSendSection(
                                items: scheduledItems,
                                isOnline: model.isOnline,
                                failureReason: { model.scheduledItemFailureReason($0) },
                                onSendNow: { item in
                                    Task { await model.sendScheduledItemNow(item.id) }
                                },
                                onEditSchedule: { item in
                                    scheduleRequest = ChatScheduleRequest(
                                        id: item.id,
                                        existingItem: item,
                                        preview: item.preview
                                    )
                                },
                                onCancel: { item in
                                    Task { await cancelScheduledItem(item) }
                                }
                            )
                        }
                        if !pendingScheduledPayments.isEmpty {
                            ScheduledPaymentSection(
                                items: pendingScheduledPayments,
                                recipientName: recipientDisplayName,
                                isOnline: model.isOnline,
                                cancellingID: chatScheduledPayments.cancellingID,
                                errorMessage: chatScheduledPayments.errorMessage,
                                onCancel: { payment in
                                    Task {
                                        await chatScheduledPayments.cancel(
                                            payment,
                                            conversationID: conversation.id,
                                            isOnline: model.isOnline
                                        )
                                    }
                                }
                            )
                        }
                        if !chatScheduledGroupPayments.items.isEmpty {
                            ScheduledGroupPaymentSection(
                                items: chatScheduledGroupPayments.items,
                                isOnline: model.isOnline,
                                actionID: chatScheduledGroupPayments.actionID,
                                errorMessage: chatScheduledGroupPayments.errorMessage,
                                onCancel: { schedule in
                                    Task {
                                        await chatScheduledGroupPayments.cancel(
                                            schedule,
                                            conversationID: conversation.id,
                                            enabled: scheduledGroupPaymentsEnabled,
                                            isOnline: model.isOnline
                                        )
                                    }
                                }
                            )
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
                // Where "the finger came up" comes from. On iOS 18 and later the scroll view says
                // so itself; below that, the drag gesture is the only thing there is.
                .modifier(
                    ConversationScrollInteractionReporter(
                        onInteractingChange: { interacting in
                            isConversationScrollInteracting = interacting
                            if interacting {
                                latestPositionPolicy.endOpeningSettling(
                                    conversationID: conversation.id
                                )
                            }
                        },
                        onRelease: releaseCameraPull
                    )
                )
                // Runs alongside the scroll rather than competing with it, and the minimum distance
                // keeps taps and the bubbles' own long-press menus out of it entirely. Kept for
                // iOS 17, where nothing else reports the release at all.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { _ in updateCameraPullArming() }
                        .onEnded { _ in releaseCameraPull() }
                )
                .task(id: openingPositionTaskID) {
                    guard ConversationLatestPositionPolicy.openingLayoutIsReady(
                        hasTimelineContent: !timelineItems.isEmpty,
                        contentHeight: conversationContentHeight,
                        viewportHeight: conversationViewportHeight
                    ) else { return }
                    // Geometry has now confirmed both the viewport and the LazyVStack's content,
                    // so the bottom anchor exists. Claiming before that layout pass made an early
                    // no-op permanent: the thread looked caught between offsets and the first
                    // upward drag only started working after a compensating downward drag.
                    await Task.yield()
                    guard !Task.isCancelled,
                          pendingScrollTargetMessageID == nil,
                          latestPositionPolicy.claimOpening(
                              conversationID: conversation.id,
                              hasTimelineContent: !timelineItems.isEmpty
                          )
                    else { return }
                    scrollToBottom(using: scrollProxy, animated: false)
                    // A second transaction after the first offset change lets SwiftUI settle the
                    // lazy rows and composer inset. It is non-animated and only occurs on entry.
                    await Task.yield()
                    guard !Task.isCancelled,
                          latestPositionPolicy.hasPositioned(conversationID: conversation.id)
                    else { return }
                    scrollToBottom(using: scrollProxy, animated: false)
                }
                .onChange(of: timelineItems.last?.id) { _, _ in
                    if latestPositionPolicy.shouldMaintainOpeningAnchor(
                        conversationID: conversation.id,
                        hasExplicitTarget: pendingScrollTargetMessageID != nil,
                        isInteracting: isConversationScrollInteracting
                    ) {
                        scrollToBottom(using: scrollProxy, animated: false)
                        return
                    }
                    // A message the user just sent always snaps to the latest position; an
                    // incoming message must never yank them away from what they are reading.
                    if ConversationLatestPositionPolicy.shouldFollowTimelineChange(
                        hasPositionedCurrentConversation: latestPositionPolicy.hasPositioned(
                            conversationID: conversation.id
                        ),
                        latestMessageIsOutgoing: latestTimelineMessageIsOutgoing,
                        isNearLatest: isNearLatestMessage
                    ) {
                        scrollToBottom(using: scrollProxy)
                    }
                }
                .onChange(of: chatGroupPayments.payments) { previous, updated in
                    guard previous != updated,
                          ConversationLatestPositionPolicy.shouldFollowPaymentHydration(
                              hasPositionedCurrentConversation: latestPositionPolicy.hasPositioned(
                                  conversationID: conversation.id
                              ),
                              isNearLatest: isNearLatestMessage,
                              isInteracting: isConversationScrollInteracting
                          )
                    else { return }
                    // The authoritative share list expands an existing card without changing its
                    // timeline id. Re-address the bottom after that layout pass so it does not
                    // grow over the composer or leave the thread feeling stuck.
                    deferredLatestPositionRequest &+= 1
                }
                .onChange(of: chatGroupPaymentRequests.requests) { previous, updated in
                    guard previous != updated,
                          ConversationLatestPositionPolicy.shouldFollowPaymentHydration(
                              hasPositionedCurrentConversation: latestPositionPolicy.hasPositioned(
                                  conversationID: conversation.id
                              ),
                              isNearLatest: isNearLatestMessage,
                              isInteracting: isConversationScrollInteracting
                          )
                    else { return }
                    deferredLatestPositionRequest &+= 1
                }
                .task(id: deferredLatestPositionRequest) {
                    guard deferredLatestPositionRequest > 0 else { return }
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    let maintainsOpening = latestPositionPolicy.shouldMaintainOpeningAnchor(
                        conversationID: conversation.id,
                        hasExplicitTarget: pendingScrollTargetMessageID != nil,
                        isInteracting: isConversationScrollInteracting
                    )
                    guard maintainsOpening
                        || ConversationLatestPositionPolicy.shouldFollowPaymentHydration(
                              hasPositionedCurrentConversation: latestPositionPolicy.hasPositioned(
                                  conversationID: conversation.id
                              ),
                              isNearLatest: isNearLatestMessage,
                              isInteracting: isConversationScrollInteracting
                          )
                    else { return }
                    scrollToBottom(using: scrollProxy, animated: false)
                }
                .onChange(of: pendingScrollTargetMessageID) { _, target in
                    guard let target else { return }
                    latestPositionPolicy.endOpeningSettling(conversationID: conversation.id)
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

            if isReadOnlyAppReviewPreview {
                appReviewReadOnlyFooter
            } else if isSelectingMessages {
                messageSelectionBar
            } else if isSearchingMessages {
                messageSearchBar
            } else if !conversationMessagingAvailable {
                groupMessagingReadOnlyFooter
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
                if let replacingID = session.replacingAttachmentID {
                    handleStagedVideoEditOutput(
                        output,
                        replacing: replacingID,
                        original: session.input
                    )
                } else {
                    handleEditorOutput(output, original: session.input)
                }
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
                    },
                    scheduleRequest: { draft in
                        await model.schedulePaymentRequest(
                            destinationWalletID: draft.destinationWalletID,
                            requestedFromUserID: draft.recipientUserID,
                            amount: draft.amount,
                            currencyCode: draft.currencyCode,
                            note: draft.note,
                            recipientName: draft.recipientName,
                            conversationID: conversation.id,
                            deliverAt: draft.deliverAt
                        )
                    }
                )
                .environmentObject(model)
            }
            .presentationBackground(.ultraThinMaterial)
        }
        .sheet(item: $scheduleRequest) { request in
            ScheduleSendSheet(
                title: request.title,
                confirmTitle: request.confirmTitle,
                preview: request.preview,
                initialDate: request.existingItem?.scheduledAt,
                onSchedule: { date in
                    if let item = request.existingItem {
                        Task { await model.rescheduleScheduledItem(item.id, to: date) }
                    } else {
                        sendDraft(deliverAt: date)
                    }
                }
            )
        }
        .sheet(isPresented: $showSendMoney) {
            NavigationStack {
                SendMoneyView(
                    flow: sendMoneyFlow,
                    preselectedContact: recipientContact,
                    preselectedRecipientUserID: paymentRecipientUserID,
                    conversationID: conversation.id,
                    locksRecipientSelection: true,
                    shareTransferInChat: { transaction in
                        guard let paymentRecipientUserID else { return false }
                        return await model.queueTransferChatEvent(
                            transaction: transaction,
                            recipientId: paymentRecipientUserID,
                            title: recipientDisplayName,
                            conversationId: conversation.id
                        )
                    },
                    scheduledPaymentCreated: { payment in
                        chatScheduledPayments.upsert(
                            payment,
                            conversationID: conversation.id
                        )
                    }
                )
                .environmentObject(model)
            }
            .presentationBackground(.ultraThinMaterial)
        }
        // Group info is a full screen, not a sheet: identity, membership, and the description
        // editor are substantive flows and follow the app-wide full-screen rule.
        .fullScreenCover(isPresented: $showGroupProfile, onDismiss: finishGroupProfilePresentation) {
            let group = currentConversation
            GroupProfileView(
                conversationID: group.id,
                title: group.title,
                groupDescription: group.groupDescription,
                photoURL: group.groupPhotoURL,
                members: group.participantUserIds.map { userID in
                    GroupMemberPresentation(
                        userID: userID,
                        displayName: participantDisplayName(for: userID),
                        isCurrentUser: userID.lowercased()
                            == model.profile?.id.lowercased(),
                        role: group.groupRole(for: userID)?.rawValue,
                        avatarURL: model.contactAvatarURL(forUserID: userID)
                    )
                },
                renameGroup: model.canRenameGroupConversation(group.id) ? { title in
                    await model.renameGroupConversation(group.id, title: title)
                } : nil,
                updateDescription: model.canEditGroupConversationIdentity(group.id) ? { text in
                    await model.updateGroupConversationDescription(
                        group.id,
                        description: text
                    )
                } : nil,
                updatePhoto: model.canEditGroupConversationIdentity(group.id) ? { jpeg in
                    await model.updateGroupConversationPhoto(group.id, jpegData: jpeg)
                } : nil,
                removePhoto: model.canEditGroupConversationIdentity(group.id) ? {
                    await model.removeGroupConversationPhoto(group.id)
                } : nil,
                addMembers: model.canAddGroupConversationMember(group.id) ? {
                    groupProfileFollowUp = .addMember
                    showGroupProfile = false
                } : nil,
                canRemoveMember: { memberUserID in
                    model.canRemoveGroupConversationMember(
                        memberUserID,
                        from: group.id
                    )
                },
                removeMember: { memberUserID in
                    await model.removeGroupConversationMember(
                        memberUserID,
                        from: group.id
                    )
                },
                leaveGroup: model.canLeaveGroupConversation(group.id) ? {
                    let left = await model.leaveGroupConversation(group.id)
                    if left { groupProfileFollowUp = .leaveCompleted }
                    return left
                } : nil,
                openMediaLibrary: {
                    groupProfileFollowUp = .mediaLibrary
                    showGroupProfile = false
                }
            )
            .environmentObject(model)
        }
        .sheet(isPresented: $showContactProfile, onDismiss: finishGroupProfilePresentation) {
            ConversationContactProfileView(
                name: recipientDisplayName,
                contact: recipientContact,
                avatarURL: recipientPresentation.avatarURL,
                userID: recipientUserID,
                conversation: conversation,
                messages: messages,
                isReadOnlyPreview: isReadOnlyAppReviewPreview,
                startAudioCall: { queueCall(video: false) },
                startVideoCall: { queueCall(video: true) },
                searchChat: {
                    showContactProfile = false
                    beginMessageSearch()
                },
                showMessageInChat: { messageID, itemIndex in
                    showContactProfile = false
                    if galleryItems.contains(where: {
                        $0.messageID == messageID && $0.itemIndex == itemIndex
                    }) {
                        // Give the sheet a beat to dismiss before presenting the cover.
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 350_000_000)
                            galleryTarget = ConversationGalleryTarget(
                                messageID: messageID,
                                itemIndex: itemIndex
                            )
                        }
                    } else {
                        pendingScrollTargetMessageID = messageID
                    }
                }
            )
            .environmentObject(model)
            .presentationBackground(.ultraThinMaterial)
        }
        .sheet(isPresented: $showGroupMemberPicker) {
            GroupMemberPickerView(
                existingMemberUserIDs: Set(currentConversation.participantUserIds),
                addMember: { memberUserID in
                    await model.addGroupConversationMember(
                        memberUserID,
                        to: conversation.id
                    )
                }
            )
            .environmentObject(model)
            .presentationBackground(.ultraThinMaterial)
        }
        .sheet(isPresented: $showGroupMediaLibrary) {
            NavigationStack {
                ConversationMediaLibraryView(
                    conversationID: conversation.id,
                    conversationTitle: currentConversation.title,
                    openGallery: { messageID, itemIndex in
                        showGroupMediaLibrary = false
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 350_000_000)
                            galleryTarget = ConversationGalleryTarget(
                                messageID: messageID,
                                itemIndex: itemIndex
                            )
                        }
                    }
                )
                .environmentObject(model)
                .environment(
                    \.voiceNoteChatContext,
                    VoiceNoteChatContext(
                        conversationID: conversation.id,
                        conversationTitle: currentConversation.title,
                        displayName: { participantDisplayName(for: $0) }
                    )
                )
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showGroupMediaLibrary = false }
                    }
                }
            }
            .presentationBackground(.ultraThinMaterial)
        }
        .sheet(item: $abuseReportPresentation) { presentation in
            NavigationStack {
                AbuseReportView(
                    reportedName: presentation.reportedName,
                    context: presentation.context,
                    target: presentation.target,
                    messages: messages
                )
                .environmentObject(model)
            }
            .presentationBackground(.ultraThinMaterial)
        }
        .fullScreenCover(item: $galleryTarget) { target in
            KitMediaGalleryView(
                items: galleryItems,
                initialItemID: target.messageID,
                initialItemIndex: target.itemIndex,
                loadData: { item in
                    // Identity-addressed: the model resolves the current persisted row and
                    // re-parses its descriptor at load time, so a gallery entry can never
                    // smuggle stale or forged wire text into the verifying open paths. The
                    // whole LoadedItem is returned so render/save/share facts stay bound to
                    // the same resolution as the bytes.
                    try await model.loadSecureMediaItem(
                        messageID: item.messageID,
                        conversationId: item.conversationID,
                        itemIndex: item.itemIndex
                    )
                },
                showInChat: { item in
                    pendingScrollTargetMessageID = item.messageID
                },
                restoreFromPictureInPicture: { identity in
                    galleryTarget = ConversationGalleryTarget(
                        messageID: identity.messageID,
                        itemIndex: identity.itemIndex
                    )
                },
                onDismiss: { galleryTarget = nil }
            )
            .environmentObject(model)
        }
        .sheet(item: $reactionPickerTarget) { target in
            ReactionPickerSheet { emoji in
                reactionPickerTarget = nil
                Task { await toggleReaction(emoji, on: target) }
            }
            .presentationDetents([.medium, .large])
            .presentationBackground(.ultraThinMaterial)
        }
        .sheet(item: $reactionDetailTarget) { target in
            ReactionDetailSheet(
                tallies: reactionTallies[target.serverMessageId?.lowercased() ?? ""] ?? [],
                nameForUserID: { participantDisplayName(for: $0) }
            )
            .presentationDetents([.medium])
            .presentationBackground(.ultraThinMaterial)
        }
        // A screen of its own rather than a half-height sheet: in a group this is a list of
        // everybody the message was addressed to, each opening into three moments, which is a page
        // of reading that a detent would spend the whole time being dragged out of the way.
        .fullScreenCover(item: $messageInfoTarget) { target in
            MessageInfoView(
                conversationID: target.conversationID,
                serverMessageID: target.serverMessageID,
                nameForUserID: { participantDisplayName(for: $0) },
                avatarURLForUserID: { model.contactAvatarURL(forUserID: $0) }
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
            .environmentObject(model)
            .presentationBackground(.ultraThinMaterial)
        }
        .sheet(item: $groupPaymentDeclineTarget) { target in
            GroupPaymentDeclineView(
                shareAmount: target.shareAmount,
                isSubmitting: chatGroupPayments.actionPaymentId != nil,
                errorMessage: chatGroupPayments.errorMessage
            ) { reason in
                let declined = await chatGroupPayments.rejectShare(
                    target.descriptor,
                    conversationID: conversation.id,
                    announcementSenderID: target.announcementSenderID,
                    reason: reason,
                    groupPaymentsEnabled: groupPaymentsEnabled,
                    isOnline: model.isOnline
                )
                guard declined else { return false }
                await queueGroupPaymentOutcome(target.descriptor, action: .rejected)
                await model.refresh()
                return true
            }
            .presentationBackground(.ultraThinMaterial)
        }
        .sheet(item: $groupPaymentReturnTarget) { target in
            GroupPaymentReturnView(
                pendingCount: target.pendingCount,
                isSubmitting: chatGroupPayments.actionPaymentId != nil,
                errorMessage: chatGroupPayments.errorMessage
            ) { reason, pin in
                let returned = await chatGroupPayments.reverseUnclaimed(
                    target.descriptor,
                    conversationID: conversation.id,
                    announcementSenderID: target.announcementSenderID,
                    reason: reason,
                    groupPaymentsEnabled: groupPaymentsEnabled,
                    pin: pin,
                    isOnline: model.isOnline,
                    authorize: model.authorizeFinancialStepUp
                )
                guard returned else { return false }
                await queueGroupPaymentOutcome(target.descriptor, action: .returned)
                await model.refresh()
                return true
            }
            .environmentObject(model)
            .presentationBackground(.ultraThinMaterial)
        }
        .sheet(item: $groupPaymentComposer) { composer in
            if let wallet = model.selectedWallet {
                GroupPaymentComposerView(
                    conversationId: conversation.id,
                    conversationTitle: conversation.title,
                    members: groupPaymentMembers,
                    wallet: wallet,
                    isSubmitting: chatGroupPayments.actionPaymentId != nil
                        || chatScheduledGroupPayments.actionID != nil,
                    errorMessage: chatGroupPayments.errorMessage
                        ?? chatScheduledGroupPayments.errorMessage,
                    submit: { body, pin in
                    let payment = await chatGroupPayments.send(
                        conversationId: conversation.id,
                        body: body,
                        idempotencyKey: composer.id,
                        groupPaymentsEnabled: groupPaymentsEnabled,
                        pin: pin,
                        isOnline: model.isOnline,
                        authorize: model.authorizeFinancialStepUp
                    )
                    guard let payment else { return nil }
                    // The money movement is already confirmed. Hand success back immediately so
                    // the composer closes once; posting its idempotent chat card and refreshing
                    // the wallet continue without leaving a live Send button over the thread.
                    Task { @MainActor in
                        var announced = await announceGroupPayment(payment)
                        // A refresh can repair a transient roster/session race. The deterministic
                        // client message id makes this one retry safe if the first queue actually
                        // committed before reporting failure.
                        await model.refresh()
                        if !announced {
                            announced = await announceGroupPayment(payment)
                        }
                        if !announced {
                            let message = "The payment was sent, but its chat card could not be "
                                + "added after retrying. Do not send it again; check Wallet "
                                + "activity and contact Kit Pay support with reference \(payment.id)."
                            chatGroupPayments.errorMessage = message
                            model.lastError = message
                        }
                    }
                    return payment
                    },
                    schedulePayment: scheduledGroupPaymentsEnabled ? { body, date, pin in
                        await chatScheduledGroupPayments.schedule(
                            conversationID: conversation.id,
                            draft: body,
                            wallet: wallet,
                            scheduledFor: date,
                            allowedRecipientIDs: Set(groupPaymentMembers.map(\.userId)),
                            pin: pin,
                            enabled: scheduledGroupPaymentsEnabled,
                            isOnline: model.isOnline,
                            authorize: model.authorizeFinancialStepUp
                        )
                    } : nil
                )
                .environmentObject(model)
                .presentationBackground(.ultraThinMaterial)
            }
        }
        .fullScreenCover(item: $groupPaymentRequestComposer) { composer in
            if let wallet = model.selectedWallet {
                GroupPaymentRequestComposerView(
                    conversationTitle: conversation.title,
                    wallet: wallet,
                    isSubmitting: chatGroupPaymentRequests.actionRequestID != nil,
                    errorMessage: chatGroupPaymentRequests.errorMessage
                ) { body in
                    guard let requesterUserID = model.profile?.id else { return nil }
                    let request = await chatGroupPaymentRequests.create(
                        conversationID: conversation.id,
                        requesterUserID: requesterUserID,
                        body: body,
                        idempotencyKey: composer.id,
                        enabled: groupPaymentRequestsEnabled,
                        isOnline: model.isOnline
                    )
                    guard let request else { return nil }
                    Task { @MainActor in
                        let announced = await announceGroupPaymentRequest(request)
                        await model.refresh()
                        if !announced {
                            model.lastError = "The request is active and will appear after the next secure sync. Do not create it again."
                        }
                    }
                    return request
                }
                .environmentObject(model)
            }
        }
        .fullScreenCover(item: $groupPaymentRequestContribution) { target in
            if let wallet = model.selectedWallet,
               let request = chatGroupPaymentRequests.requests[target.descriptor.requestID] {
                GroupPaymentRequestContributionView(
                    request: request,
                    wallet: wallet,
                    startsWithRemainingAmount: target.startsWithRemainingAmount,
                    isSubmitting: chatGroupPaymentRequests.actionRequestID != nil,
                    errorMessage: chatGroupPaymentRequests.errorMessage
                ) { amount, pin in
                    guard let currentUserID = model.profile?.id else { return nil }
                    let result = await chatGroupPaymentRequests.contribute(
                        descriptor: target.descriptor,
                        conversationID: conversation.id,
                        announcementSenderID: target.announcementSenderID,
                        currentUserID: currentUserID,
                        wallet: wallet,
                        amountInput: amount,
                        idempotencyKey: target.idempotencyKey,
                        pin: pin,
                        enabled: groupPaymentRequestsEnabled,
                        isOnline: model.isOnline,
                        authorize: model.authorizeFinancialStepUp
                    )
                    guard let result else { return nil }
                    Task { @MainActor in
                        await announceGroupPaymentRequestContribution(result)
                        await model.refresh()
                    }
                    return result
                }
                .environmentObject(model)
            }
        }
        .alert(item: $groupPaymentRequestCancellation) { target in
            Alert(
                title: Text("Close this request?"),
                message: Text("Contributions already received stay settled. No new contributions will be accepted."),
                primaryButton: .destructive(Text("Close request")) {
                    Task { @MainActor in
                        guard let request = await chatGroupPaymentRequests.cancel(
                            descriptor: target.descriptor,
                            conversationID: conversation.id,
                            announcementSenderID: target.announcementSenderID,
                            idempotencyKey: target.idempotencyKey,
                            enabled: groupPaymentRequestsEnabled,
                            isOnline: model.isOnline
                        ) else { return }
                        await announceGroupPaymentRequestTerminal(request, action: .cancelled)
                        await model.refresh()
                    }
                },
                secondaryButton: .cancel()
            )
        }
    }

    private func openConversationProfile() {
        if isGroupConversation {
            showGroupProfile = true
        } else {
            showContactProfile = true
        }
    }

    private func finishGroupProfilePresentation() {
        guard let followUp = groupProfileFollowUp else { return }
        groupProfileFollowUp = nil
        switch followUp {
        case .addMember:
            showGroupMemberPicker = true
        case .mediaLibrary:
            showGroupMediaLibrary = true
        case .leaveCompleted:
            dismissConversation()
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
            guard !isReadOnlyAppReviewPreview else { return }
            await model.markConversationRead(conversation.id)
        }
        .task(id: incomingPaymentRequestLoadID) {
            guard !isReadOnlyAppReviewPreview,
                  paymentRecipientUserID != nil,
                  model.isOnline,
                  !paymentRequestEvents.isEmpty
            else { return }
            await chatPaymentRequests.load(isOnline: true)
            validateLoadedChatPaymentRequests()
        }
        .task(id: transferEventLoadID) {
            guard !isReadOnlyAppReviewPreview,
                  paymentRecipientUserID != nil,
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
        .task(id: groupPaymentLoadID) {
            guard !isReadOnlyAppReviewPreview,
                  model.isOnline,
                  groupPaymentsEnabled,
                  !conversationGroupPaymentIDs.isEmpty
            else { return }
            await chatGroupPayments.load(
                isOnline: true,
                paymentIds: conversationGroupPaymentIDs
            )
        }
        .task(id: groupPaymentRequestLoadID) {
            guard !isReadOnlyAppReviewPreview,
                  model.isOnline,
                  groupPaymentRequestsEnabled,
                  !conversationGroupPaymentRequestIDs.isEmpty
            else { return }
            await chatGroupPaymentRequests.load(
                conversationID: conversation.id,
                requestIDs: conversationGroupPaymentRequestIDs,
                contributionReferences: conversationGroupPaymentContributionReferences,
                isOnline: true
            )
        }
        .task(id: scheduledGroupPaymentLoadID) {
            await chatScheduledGroupPayments.load(
                conversationID: conversation.id,
                enabled: scheduledGroupPaymentsEnabled,
                isOnline: model.isOnline
            )
        }
        .task(id: scheduledPaymentLoadID) {
            await chatScheduledPayments.load(
                conversationID: conversation.id,
                enabled: scheduledPaymentsEnabled,
                isOnline: model.isOnline
            )
        }
        .task(id: draftPersistenceTaskKey) {
            guard !isReadOnlyAppReviewPreview,
                  draftPersistenceTaskKey.didRestore,
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
            if !isReadOnlyAppReviewPreview, !didRestoreDraft {
                draftWriteVersion = model.nextConversationDraftWriteVersion()
                draft = model.conversationDraft(for: conversation.id)
                didRestoreDraft = true
            }
            incomingSoundPolicy.beginVisibility(with: messages)
            if !isReadOnlyAppReviewPreview {
                model.setConversationVisible(
                    conversation.id,
                    visible: scenePhase == .active
                )
            }
            applySharedInboxDeliveryIfNeeded()
            applyTargetedMessageNavigationIfNeeded()
        }
        .onChange(of: model.messageConversationNavigationRequest) { _, _ in
            applyTargetedMessageNavigationIfNeeded()
        }
        .onChange(of: messages) { _, _ in
            // A cold notification can navigate before its just-synced row reaches the published
            // projection. Keep the request pending and claim it when that exact row appears.
            applyTargetedMessageNavigationIfNeeded()
        }
        .task(id: highlightedMessageID) {
            guard let highlightedMessageID else { return }
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            guard !Task.isCancelled, self.highlightedMessageID == highlightedMessageID else {
                return
            }
            withAnimation(.easeOut(duration: 0.35)) {
                self.highlightedMessageID = nil
            }
        }
        .onChange(of: model.sharedInboxDelivery) { _, _ in
            applySharedInboxDeliveryIfNeeded()
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
            guard !isReadOnlyAppReviewPreview else { return }
            immediateDraftPersistenceTask?.cancel()
            immediateDraftPersistenceTask = nil
            let bounded = ConversationDraftPolicy.boundedBody(value)
            if bounded != value {
                draft = bounded
                return
            }
            draftWriteVersion = model.nextConversationDraftWriteVersion()
            // Throttled inside the presence center (≥4s between sends, auto-stop on idle);
            // never one event per keystroke, and a no-op until the realtime transport lands.
            // Requires composer focus: the programmatic draft RESTORE on appear also fires
            // this onChange and must never broadcast a false "typing…".
            if !value.isEmpty,
               isComposerFocused,
               conversationMessagingAvailable,
               recipientCommunicationAllowed {
                presence.recordLocalTyping(conversationID: conversation.id)
            } else {
                presence.stopLocalTyping(conversationID: conversation.id)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard !isReadOnlyAppReviewPreview else { return }
            if phase == .active {
                incomingSoundPolicy.beginVisibility(with: messages)
                model.setConversationVisible(conversation.id, visible: true)
            } else {
                incomingSoundPolicy.endVisibility()
                model.setConversationVisible(conversation.id, visible: false)
                persistDraftImmediately()
            }
        }
        .onChange(of: model.messagingGroupsEnabled) { _, enabled in
            guard isGroupConversation, !enabled else { return }
            stopReadOnlyGroupInteractions()
        }
        .onChange(of: currentUserIsGroupMember) { _, isMember in
            guard isGroupConversation, !isMember else { return }
            stopReadOnlyGroupInteractions()
        }
        .onDisappear {
            incomingSoundPolicy.endVisibility()
            if !isReadOnlyAppReviewPreview {
                model.setConversationVisible(conversation.id, visible: false)
            }
            attachmentLoadGeneration &+= 1
            isLoadingAttachment = false
            isComposerFocused = false
            // An ordinary interruption pauses the draft and keeps it; leaving the chat
            // must not cost the user what they already said. Discard stays explicit.
            voiceRecorder.suspend()
            if !voiceRecorder.hasDraft {
                VoiceNoteDraftRegistry.shared.release(conversation.id)
            }
            presence.stopLocalTyping(conversationID: conversation.id)
            if !isReadOnlyAppReviewPreview, !isSending { persistDraftImmediately() }
        }
    }

    private func applyTargetedMessageNavigationIfNeeded() {
        guard let request = model.messageConversationNavigationRequest,
              request.conversationID.caseInsensitiveCompare(conversation.id) == .orderedSame,
              let messageID = request.messageID,
              messages.filter({ $0.id == messageID }).count == 1
        else { return }
        pendingScrollTargetMessageID = messageID
        withAnimation(.easeIn(duration: 0.16)) {
            highlightedMessageID = messageID
        }
        model.consumeMessageConversationNavigationRequest(request.id)
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
                Button { openConversationProfile() } label: {
                    // Nothing sits under the photo but the Liquid Glass: no material card, no
                    // colour wash, and no ring of our own. The lens is an exact square of
                    // `avatarControlDiameter`, so it renders as a true circle around the photo.
                    ConversationAvatarView(
                        name: recipientDisplayName,
                        avatarURL: recipientPresentation.avatarURL,
                        size: ConversationHeaderLayoutPolicy.avatarImageDiameter,
                        isGroup: isGroupConversation
                    )
                    .kitBarControlGlass(
                        diameter: ConversationHeaderLayoutPolicy.avatarControlDiameter
                    )
                    .overlay(alignment: .bottomTrailing) {
                        if presence.isPeerOnline(recipientUserID) {
                            Circle()
                                .fill(KitColor.green)
                                .frame(width: 10, height: 10)
                                .overlay {
                                    Circle().stroke(.white, lineWidth: 1.5)
                                }
                                .accessibilityLabel("Online")
                        }
                    }
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
                Button { openConversationProfile() } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(recipientDisplayName)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(ConversationHeaderLayoutPolicy.nameLineLimit)
                            .truncationMode(.tail)
                        if let presenceSubtitle {
                            Text(presenceSubtitle)
                                .font(.caption2)
                                .foregroundStyle(
                                    presenceSubtitleIsLive ? KitColor.green : .secondary
                                )
                                .lineLimit(1)
                                .transition(.opacity)
                        }
                    }
                    .frame(
                        maxWidth: ConversationHeaderLayoutPolicy.maximumNameWidth,
                        alignment: .leading
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    "Open \(recipientDisplayName)'s profile"
                        + (presenceSubtitle.map { ", \($0)" } ?? "")
                )
            }
            ToolbarItem(placement: .topBarTrailing) {
                // Two lenses only: a third would push the name below its 150pt readable
                // minimum on the narrowest supported bar. Search lives in the contact sheet.
                // Group calls are not part of the calling product yet, so groups show none.
                if !isGroupConversation {
                    KitGlassControlGroup(
                        spacing: ConversationHeaderLayoutPolicy.callControlSpacing
                    ) {
                        chatCallToolbarButton(video: false)
                        chatCallToolbarButton(video: true)
                    }
                }
            }
        }
    }

    // MARK: Composer

    private var appReviewReadOnlyFooter: some View {
        Label("Read-only App Review preview", systemImage: "eye.fill")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(KitColor.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial)
            .overlay(alignment: .top) {
                Divider().opacity(0.35).allowsHitTesting(false)
            }
            .accessibilityHint("Sample content cannot send messages, payments, or calls")
    }

    private var groupMessagingReadOnlyFooter: some View {
        Label(
            currentUserIsGroupMember
                ? "Group messaging is unavailable right now. You can still read this conversation."
                : "You are no longer a member. You can still read this conversation.",
            systemImage: "lock.fill"
        )
        .font(.footnote.weight(.semibold))
        .foregroundStyle(KitColor.secondaryText)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider().opacity(0.35).allowsHitTesting(false)
        }
        .accessibilityLabel("Group conversation is read-only.")
    }

    private func stopReadOnlyGroupInteractions() {
        isComposerFocused = false
        voiceRecorder.suspend()
        presence.stopLocalTyping(conversationID: conversation.id)
        showPhotoPicker = false
        showCameraCapture = false
        showVideoNoteCamera = false
        showDocumentImporter = false
    }

    @ViewBuilder
    private var composer: some View {
        VStack(spacing: 8) {
            if let delivery = activeAppliedSharedDelivery {
                sharedInboxComposerBanner(delivery)
            }
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

            if voiceRecorder.hasDraft {
                recordingBar
            } else if editTarget != nil {
                editComposerBar
                editComposerRow
            } else {
                replyComposerBar
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

    private var activeAppliedSharedDelivery: SharedInboxDelivery? {
        guard let delivery = model.sharedInboxDelivery,
              appliedSharedDeliveryID == delivery.id,
              delivery.conversationID.caseInsensitiveCompare(conversation.id) == .orderedSame
        else { return nil }
        return delivery
    }

    private func sharedInboxComposerBanner(_ delivery: SharedInboxDelivery) -> some View {
        let hasDurableContent = model.sharedInboxHasDurablyQueuedContent(delivery.batch)
        return HStack(spacing: 10) {
            Image(systemName: !hasDurableContent
                ? "square.and.arrow.down.fill"
                : "checkmark.circle.fill")
                .foregroundStyle(KitColor.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(!hasDurableContent
                    ? "Shared from another app"
                    : "Part of this share is already queued")
                    .font(.caption.weight(.semibold))
                Text(!hasDurableContent
                    ? "Review it here, or choose another chat."
                    : "Send the remaining items here, or discard what remains.")
                    .font(.caption2)
                    .foregroundStyle(KitColor.secondaryText)
            }
            Spacer(minLength: 6)
            Menu {
                if !hasDurableContent {
                    Button {
                        returnAppliedShareToPicker(delivery)
                    } label: {
                        Label("Choose another chat", systemImage: "arrowshape.turn.up.left")
                    }
                }
                Button(role: .destructive) {
                    discardAppliedShare(delivery)
                } label: {
                    Label(
                        !hasDurableContent
                            ? "Remove shared items"
                            : "Discard items not queued",
                        systemImage: "trash"
                    )
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
            }
            .accessibilityLabel("Shared item options")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(KitColor.paleGreen.opacity(0.32), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
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
                if !isGroupConversation {
                    Button { openSendMoney() } label: {
                        Label("Send money", systemImage: "arrow.up.circle")
                    }
                    Button { openPaymentRequest() } label: {
                        Label("Payment request", systemImage: "banknote")
                    }
                } else {
                    if canSendGroupPayment {
                        Button { openGroupPayment() } label: {
                            Label("Pay the group", systemImage: "banknote.fill")
                        }
                    }
                    if canCreateGroupPaymentRequest {
                        Button { openGroupPaymentRequest() } label: {
                            Label("Request from group", systemImage: "chart.pie.fill")
                        }
                    }
                }
            } label: {
                Image(systemName: "plus")
                    .font(.headline.bold())
                    .foregroundStyle(KitColor.green)
                    .frame(width: 42, height: 42)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel(
                isGroupConversation && !canSendGroupPayment && !canCreateGroupPaymentRequest
                    ? "Attachments"
                    : "Attachments and payments"
            )

            HStack(alignment: .bottom, spacing: 4) {
                TextField(
                    model.secureMessagingAvailable && conversationMessagingAvailable
                        ? "Message"
                        : "Messages temporarily unavailable",
                    text: $draft,
                    axis: .vertical
                )
                .lineLimit(1...5)
                .focused($isComposerFocused)
                .disabled(!model.secureMessagingAvailable || !conversationMessagingAvailable || isSending)
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
                    .disabled(!model.secureMessagingAvailable || !conversationMessagingAvailable)
                    .opacity(model.secureMessagingAvailable && conversationMessagingAvailable ? 1 : 0.5)
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
                Button {
                    sendDraft()
                } label: {
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
                // Long press is the discoverable place people already look for send options.
                // The menu still offers "Send now" so the gesture never becomes a trap.
                .contextMenu {
                    Button {
                        sendDraft()
                    } label: {
                        Label("Send now", systemImage: "paperplane.fill")
                    }
                    Button {
                        openScheduleSheetForDraft()
                    } label: {
                        Label("Send later", systemImage: "clock")
                    }
                }
            }
        }
        .animation(.snappy(duration: 0.22), value: showsSendButton)
    }

    private var recordingBar: some View {
        HStack(spacing: 12) {
            Button {
                // The one deliberate way a draft dies.
                voiceRecorder.cancel()
                VoiceNoteDraftRegistry.shared.release(conversation.id)
            } label: {
                Image(systemName: "trash.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Discard recording")

            HStack(spacing: 10) {
                if voiceRecorder.isRecording {
                    Circle()
                        .fill(.red)
                        .frame(width: 9, height: 9)
                        .opacity(Int(voiceRecorder.elapsed * 2) % 2 == 0 ? 1 : 0.25)
                }
                Text(recordingTimeLabel)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(KitColor.navy)
                if voiceRecorder.isRecording {
                    RecorderLevelWave(level: voiceRecorder.level)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                } else {
                    Text(voiceRecorder.isPreviewing ? "Playing…" : "Paused")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                draftControl
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
        .accessibilityLabel(
            voiceRecorder.isRecording
                ? "Recording voice note, \(recordingTimeLabel)"
                : "Voice note draft, \(recordingTimeLabel)"
        )
    }

    /// The pause / listen-back / resume control for the phase the draft is in.
    @ViewBuilder
    private var draftControl: some View {
        switch voiceRecorder.phase {
        case .recording:
            Button {
                voiceRecorder.pause()
            } label: {
                Image(systemName: "pause.fill")
                    .font(.headline)
                    .foregroundStyle(KitColor.green)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Pause recording")
        case .paused:
            Button {
                voiceRecorder.beginPreview()
            } label: {
                Image(systemName: "play.fill")
                    .font(.headline)
                    .foregroundStyle(KitColor.green)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!voiceRecorder.hasPlayableSegments)
            .accessibilityLabel("Listen to the draft")
            Button {
                voiceRecorder.resume()
            } label: {
                Image(systemName: "mic.fill")
                    .font(.headline)
                    .foregroundStyle(KitColor.green)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(VoiceNoteDraftPolicy.capacityReached(voiceRecorder.elapsed))
            .accessibilityLabel("Resume recording")
        case .previewing:
            Button {
                voiceRecorder.endPreview()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.headline)
                    .foregroundStyle(KitColor.green)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop listening")
            Button {
                voiceRecorder.resume()
            } label: {
                Image(systemName: "mic.fill")
                    .font(.headline)
                    .foregroundStyle(KitColor.green)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(VoiceNoteDraftPolicy.capacityReached(voiceRecorder.elapsed))
            .accessibilityLabel("Resume recording")
        case .idle:
            EmptyView()
        }
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
            if attachment.kind == .video {
                Button {
                    beginTrimmingStagedVideo(attachment)
                } label: {
                    Image(systemName: "scissors")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(KitColor.green)
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                }
                .accessibilityLabel("Trim video")
            }
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
                    .overlay(alignment: .bottomLeading) {
                        if attachment.kind == .video {
                            Button {
                                beginTrimmingStagedVideo(attachment)
                            } label: {
                                Image(systemName: "scissors")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 24, height: 24)
                                    .background(.black.opacity(0.55), in: Circle())
                            }
                            .padding(3)
                            .accessibilityLabel("Trim \(attachment.displayName)")
                        }
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

    /// Removes only the attachment instances introduced by this handoff. Shared text is removed
    /// when it is still the exact appended span (plus any later suffix); if the customer edited
    /// inside that span, their current draft wins and remains in this chat.
    @discardableResult
    private func detachAppliedShareFromComposer(_ delivery: SharedInboxDelivery) -> Bool {
        attachmentLoadGeneration &+= 1
        let sharedItemIDs = Set(delivery.batch.items.map(\.id))
        stagedAttachments.removeAll { attachment in
            attachment.clientMessageID.map(sharedItemIDs.contains) == true
        }
        if stagedAttachments.isEmpty {
            isLoadingAttachment = false
            selectedPhotoItems = []
        }

        var removedSharedText = true
        if let sharedText = delivery.batch.text,
           let originalDraft = appliedSharedOriginalDraft {
            if let restored = SharedInboxPolicy.draftAfterRemovingShare(
                currentDraft: draft,
                originalDraft: originalDraft,
                sharedText: sharedText
            ) {
                draft = restored
            } else {
                removedSharedText = false
            }
        }
        appliedSharedDeliveryID = nil
        appliedSharedOriginalDraft = nil
        return removedSharedText
    }

    private func returnAppliedShareToPicker(_ delivery: SharedInboxDelivery) {
        guard !model.sharedInboxHasDurablyQueuedContent(delivery.batch) else { return }
        let removedSharedText = detachAppliedShareFromComposer(delivery)
        model.retrySharedInboxDelivery(delivery.id)
        if !removedSharedText {
            model.lastError =
                "Your edited text stays in this draft. Choose a chat for the original shared copy."
        }
    }

    private func discardAppliedShare(_ delivery: SharedInboxDelivery) {
        let removedSharedText = detachAppliedShareFromComposer(delivery)
        model.discardSharedInboxDelivery(delivery.id)
        if !removedSharedText {
            model.lastError = "Your edited text stays in this draft. The staged shared copy was removed."
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

    /// Defers to `copyableText(for:)` — the same predicate Copy itself runs — so the button can
    /// never be enabled for a selection Copy would put nothing on the pasteboard for: captionless
    /// media of either wire version, unparseable/future family bodies, pending batches without a
    /// caption.
    private var selectionHasCopyableText: Bool {
        messages.contains { message in
            selectedMessageIDs.contains(message.id) && copyableText(for: message) != nil
        }
    }

    private var chatBackground: some View {
        KitChatWallpaperView()
    }

    // MARK: Bubbles

    /// Would this message occupy a row of its own in the thread?
    ///
    /// This mirrors, exactly, the branches of the timeline's own `case .message` arm. Sender-name
    /// runs are computed from it, so a row that renders nothing — a reaction event, a forged
    /// system notice, a photo folded into an album — cannot break a run and make the same person
    /// be introduced twice in a row.
    private func rendersAsBubble(
        _ message: LocalMessage,
        albumMembership: [UUID: ChatMediaAlbumMembership],
        suppressedReactionIDs: Set<UUID>
    ) -> Bool {
        if KitSystemMessage.parse(message.body) != nil {
            return false
        }
        if suppressedReactionIDs.contains(message.id)
            || SecureMessageReservedPrefixPolicy.beginsWithReservedPrefix(
                message.body,
                prefix: KitSystemMessage.prefix
            ) {
            return false
        }
        return albumMembership[message.id] != .follower
    }

    @ViewBuilder
    private func bubble(
        _ message: LocalMessage,
        reactionTallies: [String: [MessageReactionTally]],
        showsSenderName: Bool,
        editedAt: Date? = nil
    ) -> some View {
        let descriptor = KitMediaMessageDescriptor.parse(message.body)
        let mediaKind = descriptor.map { KitChatMediaKind(mediaType: $0.mediaType) }
        let isSelected = selectedMessageIDs.contains(message.id)

        SwipeToReplyContainer(
            isEnabled: canReply(to: message),
            onReply: { beginReply(to: message) }
        ) {
        HStack(alignment: .center, spacing: 8) {
            if isSelectingMessages {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(isSelected ? KitColor.green : KitColor.secondaryText.opacity(0.5))
                    .accessibilityHidden(true)
            }
            if message.isOutgoing { Spacer(minLength: 44) }
            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 3) {
            // Only the first message of a run carries the name; the rest are plainly theirs.
            if isGroupConversation, !message.isOutgoing, showsSenderName {
                Text(participantDisplayName(for: message.senderId))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(KitColor.green)
                    .padding(.horizontal, 4)
            }
            bubbleBody(
                message,
                descriptor: descriptor,
                mediaKind: mediaKind,
                editedAt: editedAt
            )
                .overlay {
                    if (isSearchingMessages && currentSearchMatchID == message.id)
                        || highlightedMessageID == message.id {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(
                                KitColor.green,
                                lineWidth: highlightedMessageID == message.id ? 3 : 2
                            )
                            .shadow(
                                color: KitColor.green.opacity(
                                    highlightedMessageID == message.id ? 0.34 : 0
                                ),
                                radius: 8
                            )
                            .allowsHitTesting(false)
                    }
                }
                // While selecting, taps must toggle selection — not open viewers or players.
                .allowsHitTesting(!isSelectingMessages)
                .contextMenu { messageContextMenu(message) }
            if let serverID = message.serverMessageId?.lowercased(),
               let tallies = reactionTallies[serverID],
               !tallies.isEmpty {
                reactionChips(tallies, for: message)
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
    }

    /// One grid bubble for a run of consecutive captionless photos/videos. Tapping any cell
    /// opens the shared gallery at that item.
    /// `senderName` is non-nil only when this album heads a run of that member's messages.
    private func albumBubble(_ album: ChatMediaAlbum, senderName: String?) -> some View {
        let isOutgoing = album.items[0].isOutgoing
        let closingMessage = messages.first { $0.id == album.items[album.items.count - 1].messageID }
        // Swiping the whole run answers the photo it opens with; a single photo inside the run
        // can still be answered on its own from its long-press menu.
        let leadMessage = messages.first { $0.id == album.items[0].messageID }
        return SwipeToReplyContainer(
            isEnabled: leadMessage.map { canReply(to: $0) } ?? false,
            onReply: { leadMessage.map { beginReply(to: $0) } }
        ) {
        HStack(alignment: .center, spacing: 8) {
            if isOutgoing { Spacer(minLength: 44) }
            VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 0) {
                if let senderName, !isOutgoing {
                    Text(senderName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(KitColor.green)
                        .padding(.horizontal, 7)
                        .padding(.top, 6)
                }
                ChatMediaAlbumGridView(
                    album: album,
                    isOutgoing: isOutgoing,
                    onTap: { item in openGallery(at: item.messageID) },
                    cellMenu: { item in
                        guard let message = messages.first(where: { $0.id == item.messageID })
                        else { return AnyView(EmptyView()) }
                        return AnyView(messageContextMenu(message))
                    },
                    cellBadge: { item in
                        guard let message = messages.first(where: { $0.id == item.messageID }),
                              let serverID = message.serverMessageId?.lowercased(),
                              let tallies = reactionTallies[serverID],
                              !tallies.isEmpty
                        else { return AnyView(EmptyView()) }
                        return AnyView(albumReactionBadge(tallies, for: message))
                    }
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
    }

    /// Reaction chips for one photo inside an album, sized to sit in the corner of its cell.
    /// A crowded album shows the two leading emoji and a count for the rest.
    private func albumReactionBadge(
        _ tallies: [MessageReactionTally],
        for message: LocalMessage
    ) -> some View {
        let shown = tallies.prefix(2)
        let hidden = tallies.count - shown.count
        return HStack(spacing: 2) {
            ForEach(Array(shown)) { tally in
                Text(tally.emoji).font(.system(size: 12))
            }
            if hidden > 0 {
                Text("+\(hidden)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 5)
        .frame(height: 20)
        .background(.black.opacity(0.55), in: Capsule())
        .overlay {
            if tallies.contains(where: \.includesCurrentUser) {
                Capsule().stroke(KitColor.green, lineWidth: 1.2)
            }
        }
        .contentShape(Capsule())
        .onTapGesture { reactionDetailTarget = message }
        .accessibilityLabel(
            "\(tallies.reduce(0) { $0 + $1.count }) reactions"
        )
        .accessibilityAddTraits(.isButton)
    }

    /// Chronological photos/videos of this conversation for the shared gallery pager.
    ///
    /// A sealed KITMEDIA2 message contributes one entry per visual item — indexed by
    /// (message ID, item index) — while remaining one logical message with one bubble.
    /// Still-uploading rows and family bodies that fail both strict parses contribute
    /// nothing: the pager only ever addresses rows whose load path can verify them, and
    /// no entry carries descriptor text.
    private var galleryItems: [KitGalleryItem] {
        messages.flatMap { message -> [KitGalleryItem] in
            guard message.pendingAttachment == nil,
                  message.pendingMediaBatch == nil
            else { return [] }
            let senderName = message.isOutgoing
                ? "You"
                : isGroupConversation
                    ? participantDisplayName(for: message.senderId)
                    : recipientDisplayName
            if let descriptor = KitMediaMessageDescriptor.parse(message.body) {
                let kind = KitChatMediaKind(mediaType: descriptor.mediaType)
                guard kind == .image || kind == .video else { return [] }
                return [KitGalleryItem(
                    messageID: message.id,
                    itemIndex: nil,
                    conversationID: conversation.id,
                    mediaType: descriptor.mediaType,
                    plaintextByteSize: descriptor.plaintextByteSize,
                    thumbnailKey: descriptor.storageKey,
                    isOutgoing: message.isOutgoing,
                    createdAt: message.createdAt,
                    senderName: senderName
                )]
            }
            guard let batch = KitMediaMessageV2Descriptor.parse(message.body) else { return [] }
            return batch.items.enumerated().compactMap { index, item in
                let kind = KitChatMediaKind(mediaType: item.mediaType)
                guard kind == .image || kind == .video else { return nil }
                return KitGalleryItem(
                    messageID: message.id,
                    itemIndex: index,
                    conversationID: conversation.id,
                    mediaType: item.mediaType,
                    plaintextByteSize: item.plaintextByteSize,
                    thumbnailKey: item.storageKey,
                    isOutgoing: message.isOutgoing,
                    createdAt: message.createdAt,
                    senderName: senderName
                )
            }
        }
    }

    private func openGallery(at messageID: UUID) {
        openGalleryItem(at: messageID, itemIndex: nil)
    }

    private func openGalleryItem(at messageID: UUID, itemIndex: Int?) {
        guard galleryItems.contains(where: {
            $0.messageID == messageID && (itemIndex == nil || $0.itemIndex == itemIndex)
        }) else { return }
        galleryTarget = ConversationGalleryTarget(messageID: messageID, itemIndex: itemIndex)
    }

    @ViewBuilder
    private func bubbleBody(
        _ message: LocalMessage,
        descriptor: KitMediaMessageDescriptor?,
        mediaKind: KitChatMediaKind?,
        editedAt: Date? = nil
    ) -> some View {
        if let descriptor, let mediaKind, mediaKind == .image || mediaKind == .video {
            // Edge-to-edge media with a very slim frame at the top, left, and right;
            // the caption/time footer keeps regular padding below.
            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 0) {
                quotedBlock(for: message)
                    .padding(.horizontal, 5)
                    .padding(.top, 5)
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
                quotedBlock(for: message)
                if let pending = message.pendingAttachment {
                    PendingSecureMediaMessageView(message: message, attachment: pending)
                    if KitChatMediaKind(mediaType: pending.mediaType) != .document,
                       let caption = pending.caption, !caption.isEmpty {
                        Text(caption)
                            .foregroundStyle(message.isOutgoing ? .white : KitColor.primaryText)
                    }
                // One bubble for the whole multi-attachment message, in every phase: the items
                // stack inside it in display order, the shared caption renders once below them,
                // and the one status/retry row in `messageMetadata` speaks for the batch.
                } else if let batch = message.pendingMediaBatch {
                    SecureMediaBatchMessageView(message: message)
                    // Structural gate before the caption: a corrupt persisted batch renders
                    // only the damaged placeholder above, never its unvalidated caption bytes.
                    // A caption that passes is canonical — non-nil is the whole test, and its
                    // bytes render exactly as sent.
                    if batch.isStructurallyValid, let caption = batch.caption {
                        Text(caption)
                            .foregroundStyle(message.isOutgoing ? .white : KitColor.primaryText)
                    }
                } else if let mediaBatch = KitMediaMessageV2Descriptor.parse(message.body) {
                    SecureMediaBatchMessageView(message: message)
                    if let caption = mediaBatch.caption {
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
                messageMetadata(message, editedAt: editedAt)
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
            Text(AppPresentationClock.shortTime(message.createdAt))
            if message.isOutgoing { Image(systemName: deliveryIcon(message.state)) }
        }
        .font(.caption2)
        .foregroundStyle(message.isOutgoing ? .white.opacity(0.72) : .secondary)
    }

    /// What Copy puts on the pasteboard. For any media message that is only ever its caption —
    /// a descriptor is wire text carrying attachment keys, and an unparseable family body has
    /// no safe text at all (§4 rule 6).
    private func copyableText(for message: LocalMessage) -> String? {
        if let batch = message.pendingMediaBatch {
            // A batch that fails the structural gate has no trustworthy caption to copy; a
            // batch that passes has a canonical one whose bytes — including boundary scalars
            // Foundation trims would eat — must reach the pasteboard exactly as typed.
            guard batch.isStructurallyValid else { return nil }
            return batch.caption
        }
        switch KitMediaMessageFamilyPresentation.content(for: message.body) {
        case .text:
            guard SecureMessageReservedPrefixPolicy.allowsUserAuthoredText(message.body) else {
                return nil
            }
            return message.body.nilIfBlank
        case .mediaV1(let media):
            return media.caption?.nilIfBlank
        case .mediaV2(let media):
            // Validated by parse: non-nil is canonical, bytes preserved exactly.
            return media.caption
        case .confinedPlaceholder:
            return nil
        }
    }

    private func copySelectedMessages() {
        let texts = messages
            .filter { selectedMessageIDs.contains($0.id) }
            .compactMap(copyableText(for:))
        guard !texts.isEmpty else { return }
        UIPasteboard.general.string = texts.joined(separator: "\n")
        finishMessageSelection()
    }

    /// Messages the forward sheet can carry: delivered text and v1 media with a durable
    /// descriptor. Still-uploading and failed media cannot be re-encrypted for a new
    /// conversation yet, so they are skipped. Multi-attachment messages are not forwardable
    /// in this build — and no other KITMEDIA-family body, valid or not, may ever leave as
    /// forwarded *text*, because a descriptor is wire data carrying attachment keys.
    private func forwardPayloadItems(for ids: Set<UUID>) -> [ForwardPayloadItem] {
        messages
            .filter { ids.contains($0.id) }
            .compactMap { message in
                guard message.pendingAttachment == nil,
                      message.pendingMediaBatch == nil,
                      message.state != .failed
                else { return nil }
                if KitMediaMessageDescriptor.parse(message.body) != nil {
                    // Eligibility only — the payload carries pure identity, and the forward
                    // sheet resolves bytes and MIME/caption together at send time.
                    return .media(
                        id: message.id,
                        sourceConversationID: conversation.id
                    )
                }
                guard let body = message.body.nilIfBlank,
                      KitPaymentMessage.parse(body) == nil,
                      KitScheduledPaymentMessage.parse(body) == nil,
                      !KitMessageReaction.isReactionText(body),
                      !KitMediaMessageFamilyPolicy.isReservedFamilyText(body),
                      !SecureMessageReservedPrefixPolicy.beginsWithReservedPrefix(
                          body,
                          prefix: KitSystemMessage.prefix
                      )
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

    private func scheduledPaymentReceipt(
        _ message: LocalMessage,
        descriptor: KitScheduledPaymentMessage
    ) -> some View {
        let foreground = message.isOutgoing ? Color.white : KitColor.primaryText
        let secondary = message.isOutgoing
            ? Color.white.opacity(0.76)
            : KitColor.secondaryText
        let title: String = switch descriptor.action {
        case .completed: message.isOutgoing ? "Scheduled payment sent" : "Scheduled payment received"
        case .failed: "Scheduled payment not sent"
        case .cancelled: "Scheduled payment cancelled"
        }
        let symbol: String = switch descriptor.action {
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        }

        return HStack {
            if message.isOutgoing { Spacer(minLength: 52) }
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: symbol)
                    .font(.caption.bold())
                    .foregroundStyle(message.isOutgoing ? Color.white.opacity(0.84) : KitColor.green)
                Text(KitMoney.formatted(
                    descriptor.decimalAmount,
                    code: descriptor.currencyCode,
                    scale: descriptor.currencyScale
                ))
                .font(.title3.bold())
                .foregroundStyle(foreground)
                if let note = descriptor.note {
                    Text(note).font(.subheadline).foregroundStyle(secondary)
                }
                Text("Scheduled for \(descriptor.scheduledAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(secondary)
                if let reason = descriptor.reason, descriptor.action != .completed {
                    Text(reason).font(.caption2.weight(.semibold)).foregroundStyle(secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 290, alignment: .leading)
            .background(
                message.isOutgoing ? AnyShapeStyle(KitColor.navy) : AnyShapeStyle(.ultraThinMaterial),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .accessibilityElement(children: .combine)
            if !message.isOutgoing { Spacer(minLength: 52) }
        }
    }

    // MARK: Group payments

    /// The golden card, centred in the thread: every member sees the same announcement and only
    /// their own share underneath it.
    private func groupPaymentCard(
        _ message: LocalMessage,
        descriptor: KitGroupPaymentMessage
    ) -> some View {
        let payment = chatGroupPayments.authoritativePayment(
            for: descriptor,
            conversationID: conversation.id,
            announcementSenderID: message.senderId
        )
        return HStack {
            Spacer(minLength: 0)
            VStack(spacing: 4) {
                GroupPaymentCardView(
                    descriptor: descriptor,
                    payment: payment,
                    contradictsServer: chatGroupPayments.contradictsAuthoritativeState(
                        descriptor,
                        conversationID: conversation.id,
                        announcementSenderID: message.senderId
                    ),
                    isOutgoing: message.isOutgoing,
                    senderName: participantDisplayName(for: message.senderId),
                    displayName: { participantDisplayName(for: $0) },
                    isBusy: chatGroupPayments.actionPaymentId != nil,
                    accept: {
                        acceptGroupPaymentShare(
                            descriptor,
                            announcementSenderID: message.senderId
                        )
                    },
                    decline: {
                        groupPaymentDeclineTarget = GroupPaymentDeclineTarget(
                            descriptor: descriptor,
                            announcementSenderID: message.senderId,
                            shareAmount: shareAmountCopy(payment)
                        )
                    },
                    returnUnclaimed: {
                        groupPaymentReturnTarget = GroupPaymentReturnTarget(
                            descriptor: descriptor,
                            announcementSenderID: message.senderId,
                            pendingCount: payment?.pendingCount ?? 0
                        )
                    }
                )
                groupPaymentMetadata(message)
            }
            Spacer(minLength: 0)
        }
    }

    /// The card's own time row. `messageMetadata` colours itself for a navy bubble, which would be
    /// unreadable on pale gold.
    private func groupPaymentMetadata(_ message: LocalMessage) -> some View {
        HStack(spacing: 4) {
            Text(AppPresentationClock.shortTime(message.createdAt))
            if message.isOutgoing,
               message.state == .failed,
               conversationMessagingAvailable,
               model.canRetryMessage(
                   message.id,
                   conversationID: conversation.id,
                   recipientUserID: recipientUserID
               ) {
                Button {
                    retryFailedMessage(message)
                } label: {
                    Image(systemName: deliveryIcon(message.state))
                }
                .buttonStyle(.plain)
                .disabled(retryingMessageIDs.contains(message.id))
                .accessibilityLabel("Retry announcing this payment")
            } else if message.isOutgoing {
                Image(systemName: deliveryIcon(message.state))
            }
        }
        .font(.caption2)
        .foregroundStyle(KitColor.secondaryText)
    }

    /// "Ama took their share" — the small, centred line, sized like the date heading.
    @ViewBuilder
    private func groupPaymentOutcome(
        _ message: LocalMessage,
        descriptor: KitGroupPaymentMessage
    ) -> some View {
        if let text = GroupPaymentCopy.outcome(
            descriptor.action,
            actorName: participantDisplayName(for: message.senderId),
            isViewerActor: message.isOutgoing
        ) {
            GroupPaymentOutcomeChip(text: text)
        }
    }

    private func groupPaymentRequestCard(
        _ message: LocalMessage,
        descriptor: KitGroupPaymentRequestMessage
    ) -> some View {
        let request = chatGroupPaymentRequests.authoritativeRequest(
            for: descriptor,
            conversationID: conversation.id,
            announcementSenderID: message.senderId
        )
        return HStack {
            Spacer(minLength: 0)
            VStack(spacing: 4) {
                GroupPaymentRequestCardView(
                    request: request,
                    contradictsServer: chatGroupPaymentRequests.contradictsAuthoritativeState(
                        descriptor,
                        conversationID: conversation.id,
                        announcementSenderID: message.senderId
                    ),
                    senderName: participantDisplayName(for: message.senderId),
                    currentUserID: model.profile?.id,
                    displayName: { participantDisplayName(for: $0) },
                    isBusy: chatGroupPaymentRequests.actionRequestID != nil,
                    contribute: {
                        openGroupPaymentRequestContribution(
                            descriptor,
                            announcementSenderID: message.senderId,
                            payRemaining: false
                        )
                    },
                    payRemaining: {
                        openGroupPaymentRequestContribution(
                            descriptor,
                            announcementSenderID: message.senderId,
                            payRemaining: true
                        )
                    },
                    cancel: {
                        groupPaymentRequestCancellation = GroupPaymentRequestCancellationTarget(
                            descriptor: descriptor,
                            announcementSenderID: message.senderId
                        )
                    }
                )
                groupPaymentMetadata(message)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func groupPaymentRequestOutcome(
        _ message: LocalMessage,
        descriptor: KitGroupPaymentRequestMessage
    ) -> some View {
        if let text = chatGroupPaymentRequests.verifiedEventCopy(
            for: descriptor,
            conversationID: conversation.id,
            messageAuthorID: message.senderId,
            isViewerAuthor: message.isOutgoing,
            displayName: { participantDisplayName(for: $0) }
        ) {
            GroupPaymentOutcomeChip(text: text)
        }
    }

    private func openGroupPaymentRequestContribution(
        _ descriptor: KitGroupPaymentRequestMessage,
        announcementSenderID: String,
        payRemaining: Bool
    ) {
        guard groupPaymentRequestsEnabled,
              model.isOnline,
              model.selectedWallet != nil,
              chatGroupPaymentRequests.authoritativeRequest(
                  for: descriptor,
                  conversationID: conversation.id,
                  announcementSenderID: announcementSenderID
              ) != nil
        else {
            model.lastError = "This group request is not available for a contribution right now."
            return
        }
        chatGroupPaymentRequests.errorMessage = nil
        groupPaymentRequestContribution = GroupPaymentRequestContributionTarget(
            descriptor: descriptor,
            announcementSenderID: announcementSenderID,
            startsWithRemainingAmount: payRemaining
        )
    }

    private func announceGroupPaymentRequest(_ request: GroupPaymentRequestDTO) async -> Bool {
        guard let actorUserID = model.profile?.id,
              GroupPaymentRequestAuthorityPolicy.matchesContext(
                  request,
                  conversationID: conversation.id,
                  announcementSenderID: actorUserID
              ),
              let descriptor = KitGroupPaymentRequestMessage(requesting: request)
        else { return false }
        return await model.queueGroupPaymentRequestEvent(
            conversationId: conversation.id,
            title: conversation.title,
            descriptor: descriptor,
            clientMessageID: KitGroupPaymentRequestMessage.deterministicMessageID(
                requestID: request.id,
                action: .requested,
                actorUserID: actorUserID
            )
        )
    }

    private func announceGroupPaymentRequestContribution(
        _ result: GroupPaymentRequestContributionResultDTO
    ) async {
        guard let actorUserID = model.profile?.id,
              result.isStructurallyValid,
              result.contribution.contributorUserId.caseInsensitiveCompare(actorUserID)
                == .orderedSame
        else { return }
        let completed = result.request.knownStatus == .completed
        let descriptor = completed
            ? KitGroupPaymentRequestMessage(
                completing: result.contribution,
                requestID: result.request.id
            )
            : KitGroupPaymentRequestMessage(
                contributing: result.contribution,
                requestID: result.request.id
            )
        guard let descriptor else { return }
        _ = await model.queueGroupPaymentRequestEvent(
            conversationId: conversation.id,
            title: conversation.title,
            descriptor: descriptor,
            clientMessageID: KitGroupPaymentRequestMessage.deterministicMessageID(
                requestID: result.request.id,
                action: descriptor.action,
                contributionID: result.contribution.id,
                actorUserID: actorUserID
            )
        )
    }

    private func announceGroupPaymentRequestTerminal(
        _ request: GroupPaymentRequestDTO,
        action: KitGroupPaymentRequestMessageAction
    ) async {
        guard let actorUserID = model.profile?.id,
              let descriptor = KitGroupPaymentRequestMessage(
                  terminal: action,
                  requestID: request.id
              )
        else { return }
        _ = await model.queueGroupPaymentRequestEvent(
            conversationId: conversation.id,
            title: conversation.title,
            descriptor: descriptor,
            clientMessageID: KitGroupPaymentRequestMessage.deterministicMessageID(
                requestID: request.id,
                action: action,
                actorUserID: actorUserID
            )
        )
    }

    /// This member's own share, for the decline sheet's confirmation line.
    private func shareAmountCopy(_ payment: GroupPaymentDTO?) -> String {
        guard let payment, let share = payment.yourShare else { return "Your share" }
        return KitMoney.formatted(share.amount, currency: payment.currency)
    }

    private func acceptGroupPaymentShare(
        _ descriptor: KitGroupPaymentMessage,
        announcementSenderID: String
    ) {
        Task { @MainActor in
            let accepted = await chatGroupPayments.acceptShare(
                descriptor,
                conversationID: conversation.id,
                announcementSenderID: announcementSenderID,
                groupPaymentsEnabled: groupPaymentsEnabled,
                isOnline: model.isOnline
            )
            guard accepted else { return }
            await queueGroupPaymentOutcome(descriptor, action: .accepted)
            await model.refresh()
        }
    }

    /// Tells the group what just happened to one share, never how much it was.
    ///
    /// The chip's id is derived from the payment, the outcome and this member, so a retry after a
    /// flaky send cannot post "Ama took their share" twice.
    private func queueGroupPaymentOutcome(
        _ descriptor: KitGroupPaymentMessage,
        action: KitGroupPaymentMessageAction
    ) async {
        guard let outcome = KitGroupPaymentMessage(
            outcome: action,
            groupPaymentId: descriptor.groupPaymentId
        ), let actorUserId = model.profile?.id else { return }
        _ = await model.queueGroupPaymentEvent(
            conversationId: conversation.id,
            title: conversation.title,
            body: outcome.encoded,
            clientMessageID: KitGroupPaymentMessage.outcomeMessageID(
                groupPaymentId: descriptor.groupPaymentId,
                action: action,
                actorUserId: actorUserId
            )
        )
    }

    /// Posts the announcement once the server has confirmed the payment.
    ///
    /// The roster comes from what was actually created, not from the draft, and it is only carried
    /// when the server agrees on how many members are being paid — otherwise the card falls back to
    /// counts, which every member can read without learning who else was picked.
    private func announceGroupPayment(_ payment: GroupPaymentDTO) async -> Bool {
        guard let actorUserId = model.profile?.id,
              GroupPaymentAuthorityPolicy.matchesContext(
                  payment,
                  conversationID: conversation.id,
                  announcementSenderID: actorUserId
              )
        else {
            model.lastError = "The payment was confirmed, but Kit could not verify its group."
            return false
        }
        let confirmedRoster = payment.recipients.compactMap(\.userId)
        let roster = confirmedRoster.count == payment.recipientCount
            ? confirmedRoster
            : []
        guard let descriptor = KitGroupPaymentMessage(
            announcing: payment,
            recipientUserIds: roster
        ) else {
            model.lastError = "The payment was confirmed, but Kit could not prepare its chat card."
            return false
        }
        return await model.queueGroupPaymentEvent(
            conversationId: conversation.id,
            title: conversation.title,
            body: descriptor.encoded,
            clientMessageID: KitGroupPaymentMessage.outcomeMessageID(
                groupPaymentId: payment.id,
                action: .sent,
                actorUserId: actorUserId
            )
        )
    }

    private func messageMetadata(
        _ message: LocalMessage,
        editedAt: Date? = nil
    ) -> some View {
        HStack(spacing: 4) {
            // Beside the original time, never instead of it: the message still belongs to the
            // moment it was said, and the marker only admits it was reworded afterwards.
            if editedAt != nil {
                Text("Edited")
            }
            Text(AppPresentationClock.shortTime(message.createdAt))
            if message.isOutgoing,
               message.state == .failed,
               conversationMessagingAvailable,
               model.canRetryMessage(
                   message.id,
                   conversationID: conversation.id,
                   recipientUserID: recipientUserID
               ) {
                Button {
                    retryFailedMessage(message)
                } label: {
                    Image(systemName: deliveryIcon(message.state))
                }
                .buttonStyle(.plain)
                .disabled(retryingMessageIDs.contains(message.id))
                .accessibilityLabel("Retry sending message")
                .accessibilityHint(message.failureReason ?? "Attempts this message again")
            } else if message.isOutgoing {
                Image(systemName: deliveryIcon(message.state))
            }
        }
        .font(.caption2)
        .foregroundStyle(message.isOutgoing ? .white.opacity(0.72) : .secondary)
    }

    private func retryFailedMessage(_ message: LocalMessage) {
        guard retryingMessageIDs.insert(message.id).inserted else { return }
        Task { @MainActor in
            await model.retryFailedMessage(
                message.id,
                conversationID: conversation.id,
                recipientUserID: recipientUserID
            )
            retryingMessageIDs.remove(message.id)
        }
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
            Text(KitMoney.formatted(descriptor.decimalAmount, code: descriptor.currencyCode, scale: descriptor.currencyScale))
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

            if !isGroupConversation && (presentation.showsAccept || presentation.showsReject) {
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
            if !isGroupConversation && presentation.showsReverse {
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
            && !isGroupConversation
            && message.isOutgoing
            && localOutcome == nil
            && authoritativeRequest.map { paymentRequestPolicy.canCancel($0) } == true
            && model.isOnline
        let canDecline = descriptor.isRequest
            && !isGroupConversation
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
            Text(KitMoney.formatted(descriptor.decimalAmount, code: descriptor.currencyCode, scale: descriptor.currencyScale))
                .font(.title3.bold())
                .foregroundStyle(foreground)
            if let note = descriptor.note {
                Text(note)
                    .font(.subheadline)
                    .foregroundStyle(secondary)
            }

            if !isGroupConversation
                && localOutcome == nil
                && (presentation.showsPayAction || canDecline) {
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
                                    "Pay \(KitMoney.formatted(descriptor.decimalAmount, code: descriptor.currencyCode, scale: descriptor.currencyScale))",
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

    @ViewBuilder
    private func callBubble(_ call: CallRecord) -> some View {
        let presentation = ConversationCallPresentationPolicy.presentation(for: call)
        if currentLiveCallMatches(call) {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                callBubbleRow(
                    call,
                    presentation: presentation,
                    liveElapsedSeconds: liveCallElapsedSeconds(for: call, at: timeline.date)
                )
            }
        } else {
            callBubbleRow(call, presentation: presentation, liveElapsedSeconds: nil)
        }
    }

    private func callBubbleRow(
        _ call: CallRecord,
        presentation: ConversationCallPresentation,
        liveElapsedSeconds: Int?
    ) -> some View {
        let isLive = currentLiveCallMatches(call)
        let callbackAvailable = presentation.callbackEnabled
            && !isLive
            && !isReadOnlyAppReviewPreview
            && model.mayCreateCall
            && recipientUserID != nil
            && recipientCommunicationAllowed
        let subtitle = callSubtitle(
            call,
            presentation: presentation,
            liveElapsedSeconds: liveElapsedSeconds
        )
        let accessibilityLabel = "\(presentation.title), \(subtitle)"

        return HStack {
            if presentation.isOutgoing { Spacer(minLength: 52) }
            if isLive {
                Button {
                    CallOverlayWindowController.shared.reopenActiveCall()
                } label: {
                    callBubbleCard(
                        call,
                        presentation: presentation,
                        callbackAvailable: false,
                        isLive: true,
                        liveElapsedSeconds: liveElapsedSeconds
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityHint("Returns to the ongoing call")
            } else if callbackAvailable {
                Button {
                    queueCall(video: call.isVideoCall)
                } label: {
                    callBubbleCard(
                        call,
                        presentation: presentation,
                        callbackAvailable: true,
                        isLive: false,
                        liveElapsedSeconds: nil
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityHint("Calls \(recipientDisplayName) back")
            } else {
                callBubbleCard(
                    call,
                    presentation: presentation,
                    callbackAvailable: false,
                    isLive: false,
                    liveElapsedSeconds: nil
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
        callbackAvailable: Bool,
        isLive: Bool,
        liveElapsedSeconds: Int?
    ) -> some View {
        let foreground = presentation.isOutgoing && !isLive
            ? Color.white
            : KitColor.primaryText
        let secondary = presentation.isOutgoing && !isLive
            ? Color.white.opacity(0.72)
            : KitColor.secondaryText
        let callbackSymbol: String = if isLive {
            "arrow.up.left.and.arrow.down.right"
        } else if presentation.callbackEnabled {
            call.isVideoCall ? "video.fill" : "phone.fill"
        } else if call.state == .queued {
            "icloud.and.arrow.up"
        } else {
            "waveform"
        }
        let callbackColor: Color = if isLive {
            KitColor.green
        } else if call.state == .queued {
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
                Text(callSubtitle(
                    call,
                    presentation: presentation,
                    liveElapsedSeconds: liveElapsedSeconds
                ))
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
            isLive
                ? AnyShapeStyle(KitColor.green.opacity(0.16))
                : presentation.isOutgoing
                ? AnyShapeStyle(KitColor.navy.opacity(0.94))
                : AnyShapeStyle(.ultraThinMaterial),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(
                    isLive
                        ? KitColor.green.opacity(0.72)
                        : Color.white.opacity(presentation.isOutgoing ? 0.22 : 0.6),
                    lineWidth: isLive ? 1.2 : 0.7
                )
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
    }

    private func callSubtitle(
        _ call: CallRecord,
        presentation: ConversationCallPresentation,
        liveElapsedSeconds: Int? = nil
    ) -> String {
        if let liveElapsedSeconds {
            let duration = ConversationCallPresentationPolicy.durationText(liveElapsedSeconds)
            return "In call · \(duration)"
        }
        var values: [String] = []
        if let status = presentation.statusText { values.append(status) }
        values.append(AppPresentationClock.shortTime(call.startedAt))
        if let duration = presentation.durationSeconds, duration > 0 {
            values.append(ConversationCallPresentationPolicy.durationText(duration))
        }
        return values.joined(separator: " · ")
    }

    private func currentLiveCallMatches(_ call: CallRecord) -> Bool {
        guard let activeCall = callMedia.activeCall,
              activeCall.id.caseInsensitiveCompare(call.id) == .orderedSame
        else { return false }
        return ConversationCallIndicatorPolicy.isLive(
            for: conversation.id,
            activeCall: activeCall,
            resolvedConversationId: model.resolvedConversationID(forActiveCall: activeCall),
            isConnected: callMedia.state == .connected,
            hasRemoteParticipant: callTransport.hasRemoteParticipant
        )
    }

    private func liveCallElapsedSeconds(for call: CallRecord, at date: Date) -> Int? {
        guard currentLiveCallMatches(call) else { return nil }
        if let elapsed = callMedia.presentedCallDurationSeconds() {
            return elapsed
        }
        guard let answeredAt = call.answeredAt else { return nil }
        return max(0, Int(date.timeIntervalSince(answeredAt)))
    }

    private func queueCall(video: Bool) {
        guard !isReadOnlyAppReviewPreview else {
            model.lastError = "This App Review preview is read-only."
            return
        }
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
        .disabled(isReadOnlyAppReviewPreview || !recipientCommunicationAllowed)
        .opacity(isReadOnlyAppReviewPreview || !recipientCommunicationAllowed ? 0.48 : 1)
        .accessibilityLabel(video ? "Video call" : "Audio call")
    }

    // MARK: Sending

    /// Opens the Send Later picker for whatever is in the composer right now.
    private func openScheduleSheetForDraft() {
        guard !isReadOnlyAppReviewPreview, canSendMessage else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview: String
        if !stagedAttachments.isEmpty, text.isEmpty {
            preview = stagedAttachments.count == 1
                ? stagedAttachments[0].kind.previewLabel
                : "\(stagedAttachments.count) attachments"
        } else {
            preview = text
        }
        isComposerFocused = false
        scheduleRequest = ChatScheduleRequest(
            id: UUID(),
            existingItem: nil,
            preview: preview
        )
    }

    private func cancelScheduledItem(_ item: ScheduledChatItem) async {
        let restored = await model.cancelScheduledItem(item.id)
        // The words someone wrote come back to the composer rather than disappearing with the
        // schedule — cancelling a time should not also mean losing the message.
        guard let restored, !restored.isEmpty else { return }
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft = restored
        } else {
            draft += "\n" + restored
        }
    }

    private func sendDraft(deliverAt: Date? = nil) {
        guard !isReadOnlyAppReviewPreview else { return }
        guard canSendMessage else { return }
        let submittedDraft = draft
        let submittedText = submittedDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Typed text must never impersonate a payment event: the KITPAY1 wire is written only
        // by the payment flows themselves (a pasted descriptor could forge "Accepted · Final").
        if SecureMessageReservedPrefixPolicy.beginsWithReservedPrefix(
            submittedText,
            prefix: KitPaymentMessage.prefix
        ) || KitMessageReaction.isReactionText(submittedText)
            || SecureMessageReservedPrefixPolicy.beginsWithReservedPrefix(
                submittedText,
                prefix: KitSystemMessage.prefix
            ) {
            model.lastError = "Messages can't start with Kit Pay's reserved prefixes."
            return
        }
        let submittedAttachments = stagedAttachments
        // The answer is fixed at the moment Send is pressed. Anything the user swipes to
        // afterwards belongs to the next message, not to this one.
        let answering = replyTarget.flatMap { canReply(to: $0) ? $0 : nil }?
            .serverMessageId?
            .lowercased()
        let submittedSharedDelivery: SharedInboxDelivery? = model.sharedInboxDelivery.flatMap { delivery -> SharedInboxDelivery? in
            guard appliedSharedDeliveryID == delivery.id,
                  delivery.conversationID.caseInsensitiveCompare(conversation.id) == .orderedSame
            else { return nil }
            return delivery
        }
        // One shared-inbox delivery is one message whatever shape it takes — text-only, one
        // attachment with or without text, or a 2–8 batch — so its batch UUID is the sole
        // client identity for the send. The share extension can then hand the same batch
        // over twice without the conversation ever queueing it twice.
        let sharedBatchClientMessageID = submittedSharedDelivery?.batch.id
        let persistenceVersion = model.nextConversationDraftWriteVersion()
        immediateDraftPersistenceTask?.cancel()
        immediateDraftPersistenceTask = nil
        draftWriteVersion = persistenceVersion
        isSending = true
        isComposerFocused = false
        presence.stopLocalTyping(conversationID: conversation.id)
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
                    clientMessageID: sharedBatchClientMessageID,
                    draftClearVersion: clearVersion,
                    deliverAt: deliverAt,
                    replyToServerMessageID: answering
                )
            } else {
                allQueued = await sendStagedAttachments(
                    submittedAttachments,
                    text: submittedText,
                    submittedDraft: submittedDraft,
                    clearVersion: clearVersion,
                    sharedBatchClientMessageID: sharedBatchClientMessageID,
                    deliverAt: deliverAt,
                    replyToServerMessageID: answering
                )
            }
            if allQueued {
                draftWriteVersion = clearVersion
                if draft == submittedDraft { draft = "" }
                cancelReply()
                if let submittedSharedDelivery {
                    model.consumeSharedInboxDelivery(submittedSharedDelivery.id)
                    appliedSharedDeliveryID = nil
                    appliedSharedOriginalDraft = nil
                }
            }
            isSending = false
        }
    }

    /// Queues everything staged — attachments and typed text together — as exactly one message,
    /// and returns whether that one message ended up durably queued.
    ///
    /// One attachment sends the legacy single-attachment message with the typed text as its
    /// caption. For a document the caption otherwise carries the filename; typed text wins,
    /// because one send must never split into two messages and the v1 wire has no second text
    /// field — the filename simply does not survive when text rides along.
    ///
    /// Two to eight attachments send one KITMEDIA2 batch: one bubble, one shared caption, one
    /// queue/retry identity. The caption travels as the RAW submitted draft — the contract's
    /// six-codepoint boundary strip is the only normalization allowed, and a platform
    /// whitespace trim here would eat bytes (NBSP, U+0085, U+2028) every other client
    /// preserves. Nothing is unstaged unless the one queue commit succeeds, so a failed send
    /// keeps every staged byte and the draft exactly where they were.
    private func sendStagedAttachments(
        _ attachments: [ChatStagedAttachment],
        text: String,
        submittedDraft: String,
        clearVersion: ConversationDraftWriteVersion,
        sharedBatchClientMessageID: UUID?,
        deliverAt: Date? = nil,
        replyToServerMessageID: String? = nil
    ) async -> Bool {
        let queued: Bool
        if attachments.count == 1, let attachment = attachments.first {
            let caption = text.nilIfBlank
                ?? (attachment.kind == .document ? attachment.displayName : nil)
            queued = await model.queueMediaMessage(
                conversationId: conversation.id,
                title: recipientDisplayName,
                recipientId: recipientUserID,
                mediaData: attachment.data,
                mediaType: attachment.mediaType,
                caption: caption,
                // A shared-in delivery keeps its batch UUID as the message identity even
                // when it boiled down to a single attachment; only picker-only sends keep
                // the attachment's own (usually minted-at-queue) identity.
                clientMessageID: sharedBatchClientMessageID ?? attachment.clientMessageID,
                submittedDraftBody: submittedDraft,
                draftClearVersion: clearVersion,
                deliverAt: deliverAt,
                replyToServerMessageID: replyToServerMessageID
            )
        } else {
            // A share retained in the app-group inbox retries the whole batch under its
            // one source identity; ordinary picker sends let the queue mint the identity.
            queued = await model.queueMediaMessageBatch(
                conversationId: conversation.id,
                title: recipientDisplayName,
                recipientId: recipientUserID,
                attachments: attachments.map {
                    (mediaData: $0.data, mediaType: $0.mediaType)
                },
                rawCaption: submittedDraft,
                clientMessageID: sharedBatchClientMessageID,
                submittedDraftBody: submittedDraft,
                draftClearVersion: clearVersion,
                deliverAt: deliverAt,
                replyToServerMessageID: replyToServerMessageID
            )
        }
        if queued {
            stagedAttachments.removeAll { staged in
                attachments.contains { $0.id == staged.id }
            }
            if stagedAttachments.isEmpty { selectedPhotoItems = [] }
        }
        return queued
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
        guard !isReadOnlyAppReviewPreview else { return }
        let answering = replyTarget.flatMap { canReply(to: $0) ? $0 : nil }?
            .serverMessageId?
            .lowercased()
        isSending = true
        Task {
            // The only place the draft leaves the device: the segments are stitched, read
            // back, and handed to the encrypted send path.
            guard let recording = await voiceRecorder.finish() else {
                VoiceNoteDraftRegistry.shared.release(conversation.id)
                isSending = false
                return
            }
            VoiceNoteDraftRegistry.shared.release(conversation.id)
            let queued = await model.queueMediaMessage(
                conversationId: conversation.id,
                title: conversation.title,
                recipientId: recipientUserID,
                mediaData: recording.data,
                mediaType: VoiceNoteRecorder.Recording.mediaType,
                caption: nil,
                replyToServerMessageID: answering
            )
            if queued { cancelReply() }
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
        guard !isReadOnlyAppReviewPreview else {
            model.lastError = "This App Review preview is read-only."
            return
        }
        guard !isGroupConversation else {
            model.lastError = "Payment requests are available only in one-to-one Kit Pay chats."
            return
        }
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
        guard !isReadOnlyAppReviewPreview else {
            model.lastError = "This App Review preview is read-only."
            return
        }
        guard !isGroupConversation else {
            model.lastError = "Sending money is available only in one-to-one Kit Pay chats."
            return
        }
        guard recipientCommunicationAllowed else {
            model.lastError = recipientIsBlocked
                ? "Unblock this account before sending money."
                : "Communication privacy is still loading. Refresh and try again."
            return
        }
        guard model.capabilities?.supportsFeature("wallets") == true,
              model.capabilities?.supportsFeature("internal_transfers") == true
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

    /// Whether "Pay the group" belongs in this thread's menu at all.
    ///
    /// Hidden rather than shown-and-refused: there is nothing a member can do about a group with
    /// no one else in it, or an account without a wallet.
    private var canSendGroupPayment: Bool {
        groupPaymentsEnabled
            && conversationMessagingAvailable
            && !groupPaymentMembers.isEmpty
            && model.selectedWallet != nil
    }

    private var canCreateGroupPaymentRequest: Bool {
        groupPaymentRequestsEnabled
            && conversationMessagingAvailable
            && model.selectedWallet?.status == "active"
    }

    private func openGroupPayment() {
        guard canSendGroupPayment else {
            model.lastError = "Group payments are not available in this chat."
            return
        }
        guard model.isOnline else {
            model.lastError = "Connect to the internet to pay the group."
            return
        }
        isComposerFocused = false
        chatGroupPayments.errorMessage = nil
        groupPaymentComposer = GroupPaymentComposerTarget()
    }

    private func openGroupPaymentRequest() {
        guard canCreateGroupPaymentRequest else {
            model.lastError = "Group payment requests are not available in this chat."
            return
        }
        guard model.isOnline else {
            model.lastError = "Connect to the internet to create a group payment request."
            return
        }
        isComposerFocused = false
        chatGroupPaymentRequests.errorMessage = nil
        groupPaymentRequestComposer = GroupPaymentRequestComposerTarget()
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
        // A single picked video goes through the same trim editor a camera capture does —
        // including one still too large to send whole, which trimming is exactly the remedy
        // for. A mixed or multi selection stages as before; each staged video then carries
        // its own Trim affordance.
        if items.count == 1, let only = items.first,
           only.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
            await openLibraryVideoInEditor(only, generation: generation)
            return
        }
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

    /// Copies the picked video to an editor-owned protected temp file and opens the trim
    /// editor. File-backed on purpose: pulling a library video through Data would hold up to
    /// the whole file in memory before a single frame is shown.
    @MainActor
    private func openLibraryVideoInEditor(_ item: PhotosPickerItem, generation: Int) async {
        defer {
            if generation == attachmentLoadGeneration {
                selectedPhotoItems = []
                isLoadingAttachment = false
            }
        }
        do {
            guard let picked = try await item.loadTransferable(type: PickedLibraryVideo.self)
            else { throw AttachmentSelectionError.invalidImage }
            guard generation == attachmentLoadGeneration else {
                try? FileManager.default.removeItem(at: picked.url)
                return
            }
            let byteCount = (try? FileManager.default
                .attributesOfItem(atPath: picked.url.path)[.size] as? Int64) ?? 0
            guard ConversationAttachmentStagingPolicy.editableVideoSource(byteCount: byteCount)
            else {
                try? FileManager.default.removeItem(at: picked.url)
                throw AttachmentSelectionError.videoSourceTooLarge
            }
            let mediaType = libraryVideoMediaType(for: item)
            // Give the picker sheet a beat to dismiss before presenting the editor cover,
            // exactly as handleCameraOutput does between covers.
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard generation == attachmentLoadGeneration else {
                try? FileManager.default.removeItem(at: picked.url)
                return
            }
            editorSession = MediaEditorSession(input: .video(picked.url, mediaType: mediaType))
        } catch {
            guard generation == attachmentLoadGeneration else { return }
            model.lastError = (error as? LocalizedError)?.errorDescription
                ?? "The selected video could not be read."
        }
    }

    /// Writes a staged video back to a scratch file and opens the trim editor over it; the
    /// editor's output replaces the staged attachment in place. This is how a video from a
    /// multi-selection or the share extension gets its trim, without disturbing the
    /// transactional share-inbox staging.
    private func beginTrimmingStagedVideo(_ attachment: ChatStagedAttachment) {
        guard attachment.kind == .video, editorSession == nil else { return }
        do {
            let fileExtension = attachment.mediaType == "video/quicktime" ? "mov" : "mp4"
            let url = try KitCaptureTemporaryFileStore.makeFileURL(
                directoryPrefix: KitCaptureTemporaryFileStore.editorDirectoryPrefix,
                fileName: "staged.\(fileExtension)"
            )
            try attachment.data.write(to: url, options: [.atomic])
            try KitCaptureTemporaryFileStore.protectFile(at: url)
            editorSession = MediaEditorSession(
                input: .video(url, mediaType: attachment.mediaType),
                replacingAttachmentID: attachment.id
            )
        } catch {
            model.lastError = "That video could not be opened for trimming."
        }
    }

    /// Applies a staged-video trim: the edited file replaces the attachment's bytes, keeping
    /// its position, name, and identity in the staged set. Cancelling keeps the original.
    private func handleStagedVideoEditOutput(
        _ output: KitMediaEditorOutput?,
        replacing attachmentID: UUID,
        original: KitMediaEditorInput
    ) {
        let originalURL: URL? = if case .video(let url, _) = original { url } else { nil }
        guard case .video(let url, let mediaType) = output else {
            if let originalURL { try? FileManager.default.removeItem(at: originalURL) }
            return
        }
        if let originalURL, url == originalURL {
            // Untouched: the staged bytes are already exactly this file.
            try? FileManager.default.removeItem(at: originalURL)
            return
        }
        Task { @MainActor in
            defer {
                try? FileManager.default.removeItem(at: url)
                if let originalURL { try? FileManager.default.removeItem(at: originalURL) }
            }
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try Data(contentsOf: url)
                }.value
                guard KitChatMediaLimits.fits(data.count, kind: .video) else {
                    throw AttachmentSelectionError.fileTooLarge
                }
                guard let index = stagedAttachments.firstIndex(where: { $0.id == attachmentID })
                else { return }
                let existing = stagedAttachments[index]
                stagedAttachments[index] = ChatStagedAttachment(
                    kind: .video,
                    data: data,
                    mediaType: mediaType,
                    displayName: existing.displayName,
                    previewImage: existing.previewImage
                )
            } catch {
                model.lastError = (error as? LocalizedError)?.errorDescription
                    ?? "The trimmed video could not be read."
            }
        }
    }

    // MARK: Shares from other apps

    /// Places a share this chat was chosen for into the composer.
    ///
    /// The files are staged exactly as if they had been attached here, and any shared link or text
    /// goes into the draft — so the last decision, including whether to send at all, still belongs
    /// to the person who shared. Nothing is sent automatically.
    private func applySharedInboxDeliveryIfNeeded() {
        guard let delivery = model.sharedInboxDelivery,
              delivery.conversationID.caseInsensitiveCompare(conversation.id) == .orderedSame,
              appliedSharedDeliveryID != delivery.id,
              !isReadOnlyAppReviewPreview
        else { return }
        appliedSharedDeliveryID = delivery.id
        appliedSharedOriginalDraft = nil
        Task { @MainActor in
            await stageSharedInbox(delivery)
        }
    }

    @MainActor
    private func stageSharedInbox(_ delivery: SharedInboxDelivery) async {
        let batch = delivery.batch
        attachmentLoadGeneration &+= 1
        let generation = attachmentLoadGeneration
        isLoadingAttachment = true
        defer {
            if generation == attachmentLoadGeneration { isLoadingAttachment = false }
        }

        let availableSlots = ConversationAttachmentStagingPolicy.maximumStagedAttachments
            - stagedAttachments.count
        guard batch.items.count <= availableSlots else {
            model.lastError = availableSlots == 0
                ? "Remove an attachment from this draft before adding the shared items."
                : "This draft has room for only \(availableSlots) more shared items."
            retryUnappliedSharedInboxDelivery(delivery)
            return
        }

        // Prepare the entire batch before changing the composer. This is transactional: either
        // every file is present and valid, or no draft/attachment is changed and the protected
        // originals remain available for another attempt.
        var preparedAttachments: [ChatStagedAttachment] = []
        preparedAttachments.reserveCapacity(batch.items.count)
        for item in batch.items {
            guard generation == attachmentLoadGeneration else {
                retryUnappliedSharedInboxDelivery(delivery)
                return
            }
            let batchID = batch.id
            let data = try? await Task.detached(priority: .userInitiated) {
                try SharedInboxStore().data(for: item, in: batchID)
            }.value
            guard generation == attachmentLoadGeneration else {
                retryUnappliedSharedInboxDelivery(delivery)
                return
            }
            guard let data, let attachment = preparedSharedItem(item, data: data) else {
                model.lastError = "The shared items could not all be attached. Nothing was removed."
                retryUnappliedSharedInboxDelivery(delivery)
                return
            }
            preparedAttachments.append(attachment)
        }

        guard generation == attachmentLoadGeneration else {
            retryUnappliedSharedInboxDelivery(delivery)
            return
        }
        let originalDraft = draft
        if let text = batch.text {
            // Shared text joins the draft rather than replacing it: someone who was already part
            // way through a message must not lose it to a link they shared in.
            draft = SharedInboxPolicy.composerDraft(existingDraft: draft, sharedText: text)
        }
        appliedSharedOriginalDraft = draft == originalDraft ? nil : originalDraft
        stagedAttachments.append(contentsOf: preparedAttachments)
        // Keep the protected handoff until the exact text/attachments are durably in the outbox.
        // A view dismissal or process crash before Send can therefore re-stage this same batch.
    }

    /// Builds an attachment without mutating the composer. The caller commits a whole batch only
    /// after every item succeeds, preventing a partial share from deleting files that never
    /// appeared in the chat.
    private func preparedSharedItem(
        _ item: SharedInboxItem,
        data: Data
    ) -> ChatStagedAttachment? {
        guard !data.isEmpty, data.count == item.byteCount else { return nil }
        if item.mediaType.hasPrefix("image/"),
           SharedInboxPolicy.shouldDecodeSharedImage(byteCount: data.count),
           let prepared = AttachmentImageDecoder.secureJPEG(from: data) {
            // Every shared image is re-encoded, which is what lets a camera-native HEIC be shared
            // into a chat at all, and strips the location and device metadata with it. An image
            // too large to decode safely (or one ImageIO cannot parse) remains shareable below as
            // an opaque document instead of making an already-accepted handoff impossible.
            return ChatStagedAttachment(
                kind: .image,
                data: prepared.data,
                mediaType: "image/jpeg",
                displayName: item.displayName,
                previewImage: prepared.preview,
                clientMessageID: item.id
            )
        }
        let mediaType = item.mediaType.hasPrefix("image/")
            ? SharedInboxPolicy.fallbackMediaType
            : SecureMessagingWire.allowedAttachmentMediaTypes.contains(item.mediaType)
                ? item.mediaType
                : SharedInboxPolicy.fallbackMediaType
        let kind = KitChatMediaKind(mediaType: mediaType)
        guard KitChatMediaLimits.fits(data.count, kind: kind) else { return nil }
        return ChatStagedAttachment(
            kind: kind,
            data: data,
            mediaType: mediaType,
            displayName: item.displayName,
            previewImage: nil,
            clientMessageID: item.id
        )
    }

    private func retryUnappliedSharedInboxDelivery(_ delivery: SharedInboxDelivery) {
        appliedSharedDeliveryID = nil
        appliedSharedOriginalDraft = nil
        model.retrySharedInboxDelivery(delivery.id)
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

    private var latestTimelineMessageIsOutgoing: Bool {
        guard let item = timelineItems.last else { return false }
        switch item {
        case .message(let message),
             .payment(let message, _),
             .scheduledPayment(let message, _),
             .scheduledGroupPaymentOutcome(let message, _),
             .groupPayment(let message, _),
             .groupPaymentEvent(let message, _),
             .groupPaymentRequest(let message, _),
             .groupPaymentRequestEvent(let message, _):
            return message.isOutgoing
        case .call, .dateSeparator:
            return false
        }
    }

    private var openingPositionTaskID: String {
        let ready = ConversationLatestPositionPolicy.openingLayoutIsReady(
            hasTimelineContent: !timelineItems.isEmpty,
            contentHeight: conversationContentHeight,
            viewportHeight: conversationViewportHeight
        )
        return "\(conversation.id.lowercased()):\(timelineItems.last?.id ?? "empty"):\(ready)"
    }

    private func scrollToBottom(using proxy: ScrollViewProxy, animated: Bool = true) {
        unseenIncomingCount = 0
        let position = {
            proxy.scrollTo(ConversationScrollAnchor.bottom, anchor: .bottom)
        }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) { position() }
        } else {
            position()
        }
    }

    // MARK: Reading position, jump-to-latest, and the pull-past-the-end camera

    private func handleScrollMetrics(_ metrics: ConversationScrollMetrics) {
        let contentHeightChanged = conversationContentHeight != metrics.contentHeight
        if contentHeightChanged {
            conversationContentHeight = metrics.contentHeight
        }
        if contentHeightChanged,
           latestPositionPolicy.shouldMaintainOpeningAnchor(
               conversationID: conversation.id,
               hasExplicitTarget: pendingScrollTargetMessageID != nil,
               isInteracting: isConversationScrollInteracting
           ) {
            // Lazy rows, restored history and hydrated financial cards can all gain height after
            // the first anchor exists. Keep asking for the bottom until the user touches the
            // thread or chooses an exact navigation target.
            deferredLatestPositionRequest &+= 1
        }
        guard conversationViewportHeight > 0 else { return }
        let distanceFromLatest = metrics.contentMaxY - conversationViewportHeight
        let nearLatest = distanceFromLatest < ConversationCameraPullPolicy.nearLatestDistance
        if nearLatest != isNearLatestMessage {
            isNearLatestMessage = nearLatest
            if nearLatest { unseenIncomingCount = 0 }
        }

        // Each of these writes back into `@State`, so they are only made when they change
        // something: an unconditional write here re-runs layout, which re-delivers the metrics.
        guard cameraPullIsEligible else {
            if cameraPullProgress != 0 { cameraPullProgress = 0 }
            if cameraPull.isArmed { cameraPull.cancel() }
            return
        }
        let overscroll = max(0, -distanceFromLatest)
        if cameraPullProgress != overscroll {
            cameraPullProgress = overscroll
        }
        // Taking an armed pull back before letting go, for the case where the scroll view has
        // swallowed the drag gesture and its `onChanged` no longer arrives. Only ever read while
        // the finger is still down: the release itself also collapses the overscroll as the thread
        // bounces to rest, and disarming from that would swallow the camera just asked for.
        if isConversationScrollInteracting {
            cameraPull.dragged(progress: overscroll)
        }
        guard !cameraPull.isArmed,
              overscroll >= ConversationCameraPullPolicy.triggerDistance
        else { return }
        if cameraPull.overscrolled(to: overscroll) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    private func updateCameraPullArming() {
        guard cameraPull.isArmed else { return }
        cameraPull.dragged(progress: cameraPullProgress)
    }

    /// Opens the camera on the release the indicator promised, and only then.
    private func releaseCameraPull() {
        guard cameraPull.isArmed, cameraPull.released(), cameraPullIsEligible else { return }
        showCameraCapture = true
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
            Text(cameraPull.isArmed ? "Release for camera" : "Keep pulling for camera")
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

    /// The largest library video the trim editor will accept as a SOURCE. A disk/scratch guard,
    /// not a wire cap: the send cap still applies to the trimmed clip, and cutting a short
    /// window out of a long, heavy video is exactly what the editor is for.
    static let maximumEditableVideoSourceBytes: Int64 = 1_073_741_824

    static func editableVideoSource(byteCount: Int64) -> Bool {
        byteCount > 0 && byteCount <= maximumEditableVideoSourceBytes
    }
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
        if let batch = message.pendingMediaBatch {
            // Structurally invalid persisted batches have no searchable text at all; a valid
            // batch's caption is canonical and searches byte-exact (a Foundation trim would
            // mutate or drop contract-valid boundary scalars).
            guard batch.isStructurallyValid else { return nil }
            return batch.caption
        }
        // Any KITMEDIA body searches by its caption alone; the descriptor is wire text, and an
        // unparseable family body has no searchable text at all (§4 rule 6).
        switch KitMediaMessageFamilyPresentation.content(for: message.body) {
        case .mediaV1(let media):
            return media.caption?.nilIfBlank
        case .mediaV2(let media):
            // Validated by parse: non-nil is canonical, bytes preserved exactly.
            return media.caption
        case .confinedPlaceholder:
            return nil
        case .text(let body):
            guard KitPaymentMessage.parse(body) == nil,
                  !KitMessageReaction.isReactionText(body),
                  !SecureMessageReservedPrefixPolicy.beginsWithReservedPrefix(
                      body,
                      prefix: KitSystemMessage.prefix
                  )
            else { return nil }
            return body.nilIfBlank
        }
    }
}

/// Reports when a finger goes onto the thread and when it comes back off.
///
/// `DragGesture`'s `onEnded` is not delivered once a scroll view takes the drag over — and a pull
/// past the last message is a scroll, every time. So the release the indicator kept promising
/// ("Release for camera") never arrived and the camera never opened. iOS 18 publishes scroll
/// phases, which is the signal this gesture wanted all along; iOS 17 is left with the drag gesture,
/// which is all it has.
private struct ConversationScrollInteractionReporter: ViewModifier {
    let onInteractingChange: (Bool) -> Void
    let onRelease: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollPhaseChange { oldPhase, newPhase in
                let was = oldPhase.hasFingerDown
                let now = newPhase.hasFingerDown
                guard was != now else { return }
                onInteractingChange(now)
                if was { onRelease() }
            }
        } else {
            content
        }
    }
}

@available(iOS 18.0, *)
private extension ScrollPhase {
    /// The phases that mean the customer is still touching the thread. Deceleration and the
    /// rubber-band settle are both the aftermath of a release, not part of one.
    var hasFingerDown: Bool { self == .tracking || self == .interacting }
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

/// The pull-past-the-end camera gesture, as the two-step promise the indicator makes: pulling far
/// enough *arms* the camera ("Release for camera"), and the release opens it.
///
/// It used to open the moment the threshold was crossed — the chat was snatched away mid-drag,
/// while the label was still telling the customer to let go first, and a pull they wanted to take
/// back could not be taken back.
struct ConversationCameraPullGesture: Equatable {
    private(set) var isArmed = false

    /// Reports the pull distance. Returns true on the transition into the armed state, which is
    /// the single moment the haptic should fire.
    mutating func overscrolled(to overscroll: CGFloat) -> Bool {
        guard overscroll >= ConversationCameraPullPolicy.triggerDistance, !isArmed else {
            return false
        }
        isArmed = true
        return true
    }

    /// Reports the pull distance while the finger is still moving, which is the only place an
    /// armed pull is taken back.
    ///
    /// Deliberately not driven by the scroll metrics: the release *also* drops the overscroll back
    /// under the threshold as the list bounces to rest, so disarming from that would race
    /// `released()` and swallow the camera the customer just asked for. Reading it during the drag
    /// covers both cases that should cancel — pulling back before letting go, and an armed pull
    /// left over from a gesture that ended without ever delivering its release.
    mutating func dragged(progress: CGFloat) {
        guard isArmed, progress < ConversationCameraPullPolicy.rearmDistance else { return }
        isArmed = false
    }

    /// Returns true if this release is the one the indicator promised would open the camera.
    mutating func released() -> Bool {
        defer { isArmed = false }
        return isArmed
    }

    /// The conversation stopped accepting the gesture (selection, search, recording, composing).
    mutating func cancel() {
        isArmed = false
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

/// Keeps opening and layout-driven jumps deliberate. A conversation is positioned exactly once
/// on entry; later changes follow only while the customer is already reading the latest content.
/// This distinction is what lets a hydrated group-payment card grow without trapping the scroll,
/// while an incoming message still cannot pull somebody away from older history.
struct ConversationLatestPositionPolicy: Equatable {
    private(set) var positionedConversationID: String?
    private(set) var openingSettlingConversationID: String?

    mutating func claimOpening(
        conversationID: String,
        hasTimelineContent: Bool = true
    ) -> Bool {
        // An empty shell is not an opening position. Protected history commonly arrives on the
        // next render, and that first real row must retain the unconditional opening jump.
        guard hasTimelineContent else { return false }
        let canonical = conversationID.lowercased()
        guard positionedConversationID != canonical else { return false }
        positionedConversationID = canonical
        openingSettlingConversationID = canonical
        return true
    }

    func hasPositioned(conversationID: String) -> Bool {
        positionedConversationID == conversationID.lowercased()
    }

    mutating func endOpeningSettling(conversationID: String) {
        guard openingSettlingConversationID == conversationID.lowercased() else { return }
        openingSettlingConversationID = nil
    }

    func shouldMaintainOpeningAnchor(
        conversationID: String,
        hasExplicitTarget: Bool,
        isInteracting: Bool
    ) -> Bool {
        openingSettlingConversationID == conversationID.lowercased()
            && !hasExplicitTarget
            && !isInteracting
    }

    static func openingLayoutIsReady(
        hasTimelineContent: Bool,
        contentHeight: CGFloat,
        viewportHeight: CGFloat
    ) -> Bool {
        hasTimelineContent
            && contentHeight.isFinite
            && viewportHeight.isFinite
            && contentHeight > 0
            && viewportHeight > 0
    }

    static func shouldFollowTimelineChange(
        hasPositionedCurrentConversation: Bool,
        latestMessageIsOutgoing: Bool,
        isNearLatest: Bool
    ) -> Bool {
        hasPositionedCurrentConversation && (latestMessageIsOutgoing || isNearLatest)
    }

    static func shouldFollowPaymentHydration(
        hasPositionedCurrentConversation: Bool,
        isNearLatest: Bool,
        isInteracting: Bool
    ) -> Bool {
        hasPositionedCurrentConversation && isNearLatest && !isInteracting
    }
}

private enum ConversationScrollAnchor: Hashable {
    case bottom
}

private struct ConversationAbuseReportPresentation: Identifiable {
    let context: AbuseReportContext
    let target: AbuseReportTarget
    let reportedName: String

    var id: String { "\(context.reportedUserID):\(target.id)" }
}

private struct ConversationGalleryTarget: Identifiable {
    let messageID: UUID
    /// Which item of a multi-attachment message to land on; nil = the first visual entry.
    var itemIndex: Int? = nil

    /// Presentation identity is the exact (message, item) pair. Keyed on the message alone,
    /// `fullScreenCover(item:)` would treat two targets into the same multi-attachment message
    /// as one presentation and keep the previous item's page state on screen.
    var id: String {
        itemIndex.map { "\(messageID.uuidString):\($0)" } ?? messageID.uuidString
    }
}

/// The message the delivery-details sheet is asking about.
private struct MessageInfoTarget: Identifiable {
    let conversationID: String
    let serverMessageID: String

    var id: String { serverMessageID }
}

/// A library video received as a FILE, not as Data: the picker's copy lands directly in an
/// editor-owned protected scratch directory, so a heavy video never has to fit in memory just
/// to reach the trim editor. The receiver (the editor flow) owns and deletes the file.
private struct PickedLibraryVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let fileExtension = received.file.pathExtension.isEmpty
                ? "mov"
                : received.file.pathExtension.lowercased()
            let destination = try KitCaptureTemporaryFileStore.makeFileURL(
                directoryPrefix: KitCaptureTemporaryFileStore.editorDirectoryPrefix,
                fileName: "library.\(fileExtension)"
            )
            try FileManager.default.copyItem(at: received.file, to: destination)
            try KitCaptureTemporaryFileStore.protectFile(at: destination)
            return PickedLibraryVideo(url: destination)
        }
    }
}

private struct MediaEditorSession: Identifiable {
    let id = UUID()
    let input: KitMediaEditorInput
    /// When set, the editor's output replaces this staged attachment instead of staging a new
    /// one — the path a "Trim" tap on an already-staged video takes.
    var replacingAttachmentID: UUID? = nil
}

/// Full emoji picker for reactions, grouped by the curated catalog sections.
private struct ReactionPickerSheet: View {
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 44), spacing: 6)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                    ForEach(MessageReactionCatalog.sections, id: \.title) { section in
                        Section {
                            LazyVGrid(columns: columns, spacing: 6) {
                                ForEach(section.emojis, id: \.self) { emoji in
                                    Button {
                                        onPick(emoji)
                                    } label: {
                                        Text(emoji)
                                            .font(.system(size: 30))
                                            .frame(width: 44, height: 44)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("React with \(emoji)")
                                }
                            }
                        } header: {
                            Text(section.title)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(KitColor.secondaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                                .background(.ultraThinMaterial)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
            .navigationTitle("React")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

/// Who reacted with what, for one message.
private struct ReactionDetailSheet: View {
    let tallies: [MessageReactionTally]
    let nameForUserID: (String) -> String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(tallies) { tally in
                    Section {
                        ForEach(tally.reactorUserIDs, id: \.self) { userID in
                            Text(nameForUserID(userID))
                                .font(.body)
                        }
                    } header: {
                        Text("\(tally.emoji)  \(tally.count)")
                            .font(.headline)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Reactions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct ChatTransferReverseTarget: Identifiable {
    let descriptor: KitPaymentMessage
    var id: String { descriptor.paymentRequestId }
}

private struct ChatTransferRejectTarget: Identifiable {
    let descriptor: KitPaymentMessage
    var id: String { descriptor.paymentRequestId }
}

private struct GroupPaymentDeclineTarget: Identifiable {
    let descriptor: KitGroupPaymentMessage
    let announcementSenderID: String
    let shareAmount: String
    var id: String { descriptor.groupPaymentId }
}

private struct GroupPaymentReturnTarget: Identifiable {
    let descriptor: KitGroupPaymentMessage
    let announcementSenderID: String
    let pendingCount: Int
    var id: String { descriptor.groupPaymentId }
}

/// Holds the composer's idempotency key for as long as the sheet is open, so retrying after a
/// timeout resumes the same send instead of starting a second one.
private struct GroupPaymentComposerTarget: Identifiable {
    let id: String

    init(id: String = UUID().uuidString.lowercased()) {
        self.id = id
    }
}

private struct GroupPaymentRequestComposerTarget: Identifiable {
    let id: String

    init(id: String = UUID().uuidString.lowercased()) {
        self.id = id
    }
}

private struct GroupPaymentRequestContributionTarget: Identifiable {
    let descriptor: KitGroupPaymentRequestMessage
    let announcementSenderID: String
    let startsWithRemainingAmount: Bool
    let idempotencyKey: String

    var id: String { "\(descriptor.requestID):\(idempotencyKey)" }

    init(
        descriptor: KitGroupPaymentRequestMessage,
        announcementSenderID: String,
        startsWithRemainingAmount: Bool,
        idempotencyKey: String = UUID().uuidString.lowercased()
    ) {
        self.descriptor = descriptor
        self.announcementSenderID = announcementSenderID
        self.startsWithRemainingAmount = startsWithRemainingAmount
        self.idempotencyKey = idempotencyKey
    }
}

private struct GroupPaymentRequestCancellationTarget: Identifiable {
    let descriptor: KitGroupPaymentRequestMessage
    let announcementSenderID: String
    let idempotencyKey: String

    var id: String { descriptor.requestID }

    init(
        descriptor: KitGroupPaymentRequestMessage,
        announcementSenderID: String,
        idempotencyKey: String = UUID().uuidString.lowercased()
    ) {
        self.descriptor = descriptor
        self.announcementSenderID = announcementSenderID
        self.idempotencyKey = idempotencyKey
    }
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
    @State private var showAbuseReport = false

    let name: String
    let contact: WalletContactDTO?
    let avatarURL: String?
    let userID: String?
    let conversation: Conversation
    let messages: [LocalMessage]
    let isReadOnlyPreview: Bool
    let startAudioCall: () -> Void
    let startVideoCall: () -> Void
    /// Dismisses this sheet and opens the in-chat message search.
    let searchChat: () -> Void
    /// Dismisses this sheet and shows the given message in the conversation. A visual media
    /// item also carries its index within a multi-attachment message so the gallery opens on
    /// that exact item; ordinary rows pass nil and scroll by message ID.
    let showMessageInChat: (UUID, Int?) -> Void

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
                            disabled: isReadOnlyPreview || !communicationAllowed,
                            action: startAudioCall
                        )
                        profileAction(
                            title: "Video",
                            systemName: "video",
                            disabled: isReadOnlyPreview || !communicationAllowed,
                            action: startVideoCall
                        )
                        profileAction(
                            title: "Search",
                            systemName: "magnifyingglass",
                            disabled: false,
                            action: searchChat
                        )
                    }

                    if isReadOnlyPreview {
                        Label("Read-only App Review preview", systemImage: "eye.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(KitColor.secondaryText)
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
                            conversationID: conversation.id,
                            conversationTitle: displayName,
                            openGallery: { tappedMessageID, itemIndex in
                                showMessageInChat(tappedMessageID, itemIndex)
                            }
                        )
                        .environmentObject(model)
                        .environment(
                            \.voiceNoteChatContext,
                            VoiceNoteChatContext(
                                conversationID: conversation.id,
                                conversationTitle: displayName,
                                displayName: { senderUserID in
                                    senderUserID.lowercased() == model.profile?.id.lowercased()
                                        ? "You"
                                        : displayName
                                }
                            )
                        )
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

                    if accountReportingAvailable {
                        reportAction
                    }

                    if canonicalUserID != nil, !isReadOnlyPreview {
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
            .sheet(isPresented: $showAbuseReport) {
                if let reportContext {
                    NavigationStack {
                        AbuseReportView(
                            reportedName: displayName,
                            context: reportContext,
                            target: .account,
                            messages: messages
                        )
                        .environmentObject(model)
                    }
                    .presentationBackground(.ultraThinMaterial)
                }
            }
            .task {
                if !isReadOnlyPreview,
                   canonicalUserID != nil,
                   !model.hasUsableCommunicationPrivacyProjection {
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

    private var reportContext: AbuseReportContext? {
        AbuseReportContext(
            currentUserID: model.profile?.id,
            reportedUserID: canonicalUserID,
            conversation: conversation
        )
    }

    private var accountReportingAvailable: Bool {
        guard reportContext != nil,
              AbuseReportContract.isAvailable(features: model.capabilities?.features)
        else { return false }
        guard isReadOnlyPreview else { return true }
        return AppReviewDemoContent.isProvisionedReportingTarget(
            conversationID: conversation.id,
            peerID: canonicalUserID
        )
    }

    private var isBlocked: Bool {
        model.isCommunicationBlocked(userID: canonicalUserID)
    }

    private var communicationAllowed: Bool {
        model.communicationPrivacyAllowsOutbound(to: canonicalUserID)
    }

    private var reportAction: some View {
        Button { showAbuseReport = true } label: {
            HStack(spacing: 11) {
                Image(systemName: "exclamationmark.bubble.fill")
                Text("Report account")
                    .font(.body.weight(.semibold))
                Spacer()
            }
            .foregroundStyle(.red)
            .padding(17)
            .kitGlass(cornerRadius: 22, shadow: false)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Send a private report to Kit Pay moderators")
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
        !isReadOnlyPreview
            && contact?.contactId?.nilIfBlank == nil
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

/// A conversation row's photo, ringless because the row already sits inside a glass lens.
private struct ConversationAvatarView: View {
    let name: String
    let avatarURL: String?
    let size: CGFloat
    var isGroup = false

    var body: some View {
        if isGroup {
            GroupAvatarView(title: name, photoURL: avatarURL, size: size)
        } else {
            RemoteAvatarView(name: name, avatarURL: avatarURL, size: size, ringOpacity: nil)
        }
    }
}

private enum AttachmentSelectionError: LocalizedError {
    case invalidImage
    case invalidDocument
    case fileTooLarge
    case videoSourceTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            "Choose a valid image that can be prepared securely at 10 MB or less after optimization."
        case .invalidDocument:
            "This document could not be read."
        case .fileTooLarge:
            "Files can be up to \(KitChatMediaLimits.maximumTransferLabel)."
        case .videoSourceTooLarge:
            "That video is too large to edit here. Choose a shorter video."
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
        if let batch = message.pendingMediaBatch {
            // A corrupt persisted batch previews as the bare placeholder and never surfaces
            // its unvalidated caption or derives labels from unbounded items. A valid batch's
            // caption rides byte-exact — non-nil is canonical, no Foundation trim.
            guard batch.isStructurallyValid else {
                return (KitMediaMessageFamilyPresentation.genericAttachmentLabel, nil)
            }
            let label = KitMediaMessageFamilyPresentation.summaryLabel(
                forMediaTypes: batch.items.map(\.mediaType)
            )
            if let caption = batch.caption {
                return ("\(label) · \(caption)", caption)
            }
            return (label, nil)
        }

        if let reaction = KitMessageReaction.parse(message.body) {
            let label = reaction.operation == .add
                ? "Reacted \(reaction.emoji) to a message"
                : "Removed a reaction"
            return (label, nil)
        }
        // Malformed or future reaction wire text must never surface raw.
        if SecureMessageReservedPrefixPolicy.beginsWithReservedPrefix(
            message.body,
            prefix: KitMessageReaction.prefix
        ) {
            return ("Reaction", nil)
        }

        // Group lifecycle notices (and any future system wire) stay friendly in previews.
        if SecureMessageReservedPrefixPolicy.beginsWithReservedPrefix(
            message.body,
            prefix: KitSystemMessage.prefix
        ) {
            return ("Group updated", nil)
        }

        if let scheduled = KitScheduledPaymentMessage.parse(message.body),
           scheduled.isTrustedProjection(message) {
            let label = switch scheduled.action {
            case .completed:
                message.isOutgoing ? "⏱ Scheduled payment sent" : "⏱ Scheduled payment received"
            case .failed: "⚠️ Scheduled payment not sent"
            case .cancelled: "↩️ Scheduled payment cancelled"
            }
            let searchableParts = [scheduled.note, scheduled.reason].compactMap { $0 }
            return (
                label,
                searchableParts.isEmpty
                    ? label
                    : "\(label) · \(searchableParts.joined(separator: " · "))"
            )
        }
        if SecureMessageReservedPrefixPolicy.beginsWithReservedPrefix(
            message.body,
            prefix: KitScheduledPaymentMessage.prefix
        ) {
            return ("Scheduled payment", "Scheduled payment")
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

        // The whole KITMEDIA family routes through one policy so no version — parseable,
        // malformed, or future — can surface its wire text (§4 rule 6). Only a valid caption
        // is user prose: v2 captions join search, while the descriptor itself never does.
        switch KitMediaMessageFamilyPresentation.content(for: message.body) {
        case .mediaV1(let media):
            return (mediaPreview(mediaType: media.mediaType, caption: media.caption), nil)
        case .mediaV2(let media):
            // Validated by parse: non-nil is canonical, and search must see the exact bytes.
            return (
                KitMediaMessageFamilyPresentation.previewText(for: message.body),
                media.caption
            )
        case .confinedPlaceholder:
            return (KitMediaMessageFamilyPresentation.genericAttachmentLabel, nil)
        case .text(let body):
            return (body, body)
        }
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
                                || !model.appReviewDemoMutationsAllowed
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
        guard model.appReviewDemoMutationsAllowed else {
            model.lastError = AppReviewDemoMutationPolicy.readOnlyMessage
            return
        }
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
