import Contacts
import ContactsUI
import ImageIO
import PhotosUI
import SwiftUI
import UIKit

enum ConversationListFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case unread

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .unread: "Unread"
        }
    }
}

enum ConversationListFilterPolicy {
    static func apply(
        _ filter: ConversationListFilter,
        to conversations: [Conversation]
    ) -> [Conversation] {
        conversations.filter { includes($0, in: filter) }
    }

    static func includes(
        _ conversation: Conversation,
        in filter: ConversationListFilter
    ) -> Bool {
        switch filter {
        case .all:
            true
        case .unread:
            conversation.unreadCount > 0
        }
    }
}

struct MessagesView: View {
    @EnvironmentObject private var model: AppModel
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

    private var allConversations: [Conversation] {
        model.state.conversations
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var conversations: [Conversation] {
        ConversationListFilterPolicy.apply(selectedFilter, to: allConversations)
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if allConversations.isEmpty {
                    ContentUnavailableView {
                        Label(
                            "No chats yet",
                            systemImage: "message"
                        )
                    } description: {
                        Text(CustomerFacingMessagingCopy.encryptionAssurance)
                    } actions: {
                        Button("New message") { openNewMessage() }
                            .buttonStyle(.borderedProminent)
                    }
                } else if conversations.isEmpty {
                    ContentUnavailableView {
                        Label(emptyFilterTitle, systemImage: emptyFilterSymbol)
                    } description: {
                        Text(emptyFilterDescription)
                    } actions: {
                        Button("Show all chats") { selectedFilter = .all }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(conversations) { conversation in
                                NavigationLink(value: conversation) {
                                    conversationRow(conversation)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, RootTabBarLayoutPolicy.pageBottomPadding)
                    }
                    .rootTabBarScrollClearance()
                }
            }
            .background(KitColor.canvas)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
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
                        .kitGlass(cornerRadius: 22, shadow: false)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 9)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Search chats, contacts, and messages")

                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(ConversationListFilter.allCases) { filter in
                                filterButton(filter)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)
                    }
                    .scrollIndicators(.hidden)
                }
                .background(KitColor.canvas)
            }
            .navigationTitle("Chats")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ConnectivityPill(
                        isOnline: model.isOnline,
                        queuedCount: model.queuedCount,
                        inBar: true
                    )
                }
                ToolbarItem(placement: .topBarTrailing) {
                    GlassIconButton(systemName: "square.and.pencil", inBar: true) {
                        openNewMessage()
                    }
                }
            }
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
        }
        .onChange(of: navigationPath) { _, path in
            isConversationPresented = !path.isEmpty
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

    private var emptyFilterTitle: String {
        switch selectedFilter {
        case .all: "No chats yet"
        case .unread: "No unread chats"
        }
    }

    private var emptyFilterSymbol: String {
        switch selectedFilter {
        case .all: "message"
        case .unread: "checkmark.circle"
        }
    }

    private var emptyFilterDescription: String {
        switch selectedFilter {
        case .all:
            CustomerFacingMessagingCopy.encryptionAssurance
        case .unread:
            "You are caught up. New messages will appear here."
        }
    }

    private func filterButton(_ filter: ConversationListFilter) -> some View {
        let isSelected = selectedFilter == filter
        return Button {
            selectedFilter = filter
        } label: {
            Text(filter.title)
                .font(.subheadline.weight(isSelected ? .bold : .semibold))
                .foregroundStyle(isSelected ? KitColor.green : KitColor.primaryText)
                .padding(.horizontal, 15)
                .frame(minHeight: 44)
                .kitGlass(
                    cornerRadius: 22,
                    tint: isSelected ? KitColor.green : .white,
                    shadow: false
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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

    private func conversationRow(_ conversation: Conversation) -> some View {
        let identity = ConversationContactPresentationPolicy.presentation(
            for: conversation,
            currentUserID: model.profile?.id,
            contacts: model.contactDirectory
        )
        let last = model.state.messages
            .filter { $0.conversationId == conversation.id }
            .max { $0.createdAt < $1.createdAt }
        let activeCallLabel = ConversationCallIndicatorPolicy.label(
            for: conversation.id,
            activeCall: callMedia.activeCall,
            isConnected: callMedia.state == .connected,
            hasRemoteParticipant: callTransport.hasRemoteParticipant
        )
        return HStack(spacing: 13) {
            RemoteAvatarView(
                name: identity.displayName,
                avatarURL: identity.avatarURL,
                size: 58
            )
            VStack(alignment: .leading, spacing: 5) {
                Text(identity.displayName)
                    .font(.headline)
                    .foregroundStyle(KitColor.primaryText)
                    .lineLimit(1)
                if let activeCallLabel {
                    Label(
                        activeCallLabel,
                        systemImage: callMedia.activeCall?.video == true ? "video.fill" : "phone.fill"
                    )
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(KitColor.green)
                        .lineLimit(1)
                } else {
                    Text(
                        last.map { ChatMessagePresentationPolicy.previewText(for: $0) }
                            ?? "End-to-end encrypted"
                    )
                        .font(.subheadline)
                        .foregroundStyle(last?.state == .failed ? .red : KitColor.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 7) {
                Text(conversation.updatedAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(KitColor.secondaryText)
                if conversation.unreadCount > 0 {
                    Text("\(conversation.unreadCount)")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .frame(minWidth: 22, minHeight: 22)
                        .background(KitColor.green, in: Circle())
                } else if let last, last.isOutgoing {
                    Image(systemName: deliveryIcon(last.state))
                        .font(.caption.bold())
                        .foregroundStyle(last.state == .failed ? .red : KitColor.green)
                }
            }
        }
        .padding(12)
        .kitGlass(cornerRadius: 22, shadow: false)
    }
}

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
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var attachedImage: UIImage?
    @State private var attachedImageData: Data?
    @State private var attachedImageMediaType: String?
    @State private var isLoadingAttachment = false
    @State private var attachmentLoadGeneration = 0
    @State private var isSending = false
    @State private var didRestoreDraft = false
    @State private var draftWriteVersion: ConversationDraftWriteVersion?
    @State private var immediateDraftPersistenceTask: Task<Void, Never>?
    @State private var showPaymentRequest = false
    @State private var showContactProfile = false
    @State private var chatPaymentApproval: ChatPaymentApproval?
    @State private var resolvingPaymentRequestID: String?
    @State private var incomingSoundPolicy: VisibleConversationSoundPolicy
    @StateObject private var paymentFlow = WalletFlowModel()
    @StateObject private var chatPaymentRequests = PaymentRequestsViewModel()
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
        isLoadingAttachment || !trimmedDraft.isEmpty || attachedImage != nil
    }

    private var canSendMessage: Bool {
        let hasPhoto = attachedImage != nil
            && attachedImageData != nil
            && attachedImageMediaType != nil
        return model.secureMessagingAvailable
            && recipientCommunicationAllowed
            && !isSending
            && !isLoadingAttachment
            && (hasPhoto || !trimmedDraft.isEmpty)
    }

    private var paymentRequestPolicy: PaymentRequestPolicy {
        PaymentRequestPolicy(
            features: model.capabilities?.features,
            currentUserId: model.profile?.id,
            ownedWalletIds: Set(model.state.wallets.map(\.id))
        )
    }

    private var incomingPaymentEvents: [(message: LocalMessage, descriptor: KitPaymentMessage)] {
        timelineItems.compactMap { item in
            guard case .payment(let message, let descriptor) = item,
                  !message.isOutgoing,
                  descriptor.isRequest
            else { return nil }
            return (message, descriptor)
        }
    }

    private var incomingPaymentRequestLoadID: String {
        let descriptorMessageIDs = incomingPaymentEvents.map {
            $0.message.id.uuidString.lowercased()
        }
        return "\(model.isOnline):\(descriptorMessageIDs.joined(separator: ","))"
    }

    var body: some View {
        let draftPersistenceTaskKey = ConversationDraftPersistenceTaskKey(
            conversationID: conversation.id,
            body: draft,
            writeVersion: draftWriteVersion,
            didRestore: didRestoreDraft,
            isSending: isSending
        )
        VStack(spacing: 0) {
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
                            Text(paymentError)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity)
                                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                        }
                        ForEach(timelineItems) { item in
                            switch item {
                            case .message(let message):
                                bubble(message)
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
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: timelineItems.last?.id) { _, _ in
                    scrollToBottom(using: scrollProxy)
                }
            }
            .background(chatBackground)

            VStack(spacing: 8) {
                if let attachedImage {
                    HStack(spacing: 10) {
                        Image(uiImage: attachedImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 68, height: 68)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Photo attached").font(.subheadline.bold())
                            Text(model.isOnline
                                ? "End-to-end encrypted before upload."
                                : "Saved securely. Sends when you reconnect.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            attachmentLoadGeneration &+= 1
                            isLoadingAttachment = false
                            self.attachedImage = nil
                            attachedImageData = nil
                            attachedImageMediaType = nil
                            selectedPhotoItem = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("Remove attached photo")
                    }
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(.white.opacity(0.55), lineWidth: 0.7)
                            .allowsHitTesting(false)
                    }
                }

                HStack(alignment: .bottom, spacing: 8) {
                    Menu {
                        Button {
                            isComposerFocused = false
                            showPhotoPicker = true
                        } label: {
                            Label("Photo", systemImage: "photo")
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
                    .disabled(!recipientCommunicationAllowed || isSending)

                    HStack(alignment: .bottom, spacing: 4) {
                        TextField(
                            recipientIsBlocked
                                ? "You blocked this account"
                                : !model.hasUsableCommunicationPrivacyProjection
                                    ? "Preparing chat"
                                    : "Message",
                            text: $draft,
                            axis: .vertical
                        )
                        .lineLimit(1...5)
                        .focused($isComposerFocused)
                        .disabled(
                            !model.secureMessagingAvailable
                                || !recipientCommunicationAllowed
                                || isSending
                        )
                        .padding(.leading, 14)
                        .padding(.vertical, 10)

                        if !showsSendButton {
                            Button(action: {}) {
                                Image(systemName: "mic.fill")
                                    .font(.headline)
                                    .frame(width: 40, height: 40)
                            }
                            .disabled(true)
                            .foregroundStyle(.secondary.opacity(0.62))
                            .accessibilityLabel("Voice notes coming soon")
                            .accessibilityValue("Disabled")
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
                                    Image(systemName: attachedImage == nil ? "paperplane.fill" : "lock.fill")
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
                            attachedImage == nil
                                ? "Send message"
                                : "Send encrypted photo"
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.82)))
                    }
                }
                .animation(.snappy(duration: 0.22), value: showsSendButton)
            }
            .padding(12)
            .background(.ultraThinMaterial)
            .overlay(alignment: .top) {
                Divider()
                    .opacity(0.35)
                    .allowsHitTesting(false)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
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
                KitGlassControlGroup(
                    spacing: ConversationHeaderLayoutPolicy.callControlSpacing
                ) {
                    chatCallToolbarButton(video: false)
                    chatCallToolbarButton(video: true)
                }
            }
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $selectedPhotoItem,
            matching: .images
        )
        .onChange(of: selectedPhotoItem) { _, item in
            attachmentLoadGeneration &+= 1
            let generation = attachmentLoadGeneration
            guard let item else {
                isLoadingAttachment = false
                attachedImage = nil
                attachedImageData = nil
                attachedImageMediaType = nil
                return
            }
            Task { await loadPhoto(item, generation: generation) }
        }
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
        .sheet(isPresented: $showContactProfile) {
            ConversationContactProfileView(
                name: recipientDisplayName,
                contact: recipientContact,
                avatarURL: recipientPresentation.avatarURL,
                userID: recipientUserID,
                startAudioCall: { queueCall(video: false) },
                startVideoCall: { queueCall(video: true) }
            )
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
                    isOnline: model.isOnline
                )
                guard paid else { return false }

                if let paymentRecipientUserID,
                   let paidDescriptor = approval.descriptor.changingAction(to: .paid) {
                    _ = await model.queueMessage(
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
        .task(id: incomingPaymentRequestLoadID) {
            guard paymentRecipientUserID != nil,
                  model.isOnline,
                  !incomingPaymentEvents.isEmpty
            else { return }
            await chatPaymentRequests.load(isOnline: true)
            validateLoadedChatPaymentRequests()
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
        .onChange(of: messages) { _, updatedMessages in
            if incomingSoundPolicy.consume(
                updatedMessages,
                appIsActive: scenePhase == .active
            ) {
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
            if !isSending { persistDraftImmediately() }
        }
    }

    private var chatBackground: some View {
        KitChatWallpaperView()
    }

    private func bubble(_ message: LocalMessage) -> some View {
        HStack {
            if message.isOutgoing { Spacer(minLength: 52) }
            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 5) {
                if let pending = message.pendingAttachment {
                    PendingSecurePhotoMessageView(message: message)
                    if let caption = pending.caption {
                        Text(caption)
                            .foregroundStyle(message.isOutgoing ? .white : KitColor.primaryText)
                    }
                } else if let descriptor = KitMediaMessageDescriptor.parse(message.body) {
                    SecurePhotoMessageView(
                        message: message,
                        descriptor: descriptor
                    )
                    if let caption = descriptor.caption {
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
            if !message.isOutgoing { Spacer(minLength: 52) }
        }
    }

    private func paymentBubble(
        _ message: LocalMessage,
        descriptor: KitPaymentMessage
    ) -> some View {
        HStack {
            if message.isOutgoing { Spacer(minLength: 52) }
            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 5) {
                paymentMessageContent(message: message, descriptor: descriptor)
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

    private func paymentMessageContent(
        message: LocalMessage,
        descriptor: KitPaymentMessage
    ) -> some View {
        let authoritativeRequest = authoritativeRequest(for: descriptor)
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

        return VStack(alignment: .leading, spacing: 8) {
            Label(presentation.title, systemImage: descriptor.isRequest ? "banknote" : "checkmark.circle.fill")
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
            } else {
                Text(presentation.statusText)
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
        for (_, descriptor) in incomingPaymentEvents {
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

    private func sendDraft() {
        guard canSendMessage else { return }
        let submittedDraft = draft
        let submittedImageData = attachedImageData
        let submittedMediaType = attachedImageMediaType
        let persistenceVersion = model.nextConversationDraftWriteVersion()
        immediateDraftPersistenceTask?.cancel()
        immediateDraftPersistenceTask = nil
        draftWriteVersion = persistenceVersion
        isSending = true
        isComposerFocused = false
        Task {
            let draftWasSaved = await model.persistConversationDraft(
                submittedDraft,
                conversationId: conversation.id,
                writeVersion: persistenceVersion
            )
            guard draftWasSaved else {
                if model.isSignedIn, !Task.isCancelled {
                    model.lastError = CustomerFacingMessagingCopy.draftSaveFailure
                    if scenePhase == .active { isComposerFocused = true }
                }
                isSending = false
                return
            }
            let clearVersion = model.nextConversationDraftWriteVersion()
            let queued: Bool
            if let submittedImageData, let submittedMediaType {
                queued = await model.queueImageMessage(
                    conversationId: conversation.id,
                    title: recipientDisplayName,
                    recipientId: recipientUserID,
                    imageData: submittedImageData,
                    mediaType: submittedMediaType,
                    caption: submittedDraft,
                    draftClearVersion: clearVersion
                )
            } else {
                queued = await model.queueMessage(
                    conversationId: conversation.id,
                    title: recipientDisplayName,
                    recipientId: recipientUserID,
                    body: submittedDraft,
                    draftClearVersion: clearVersion
                )
            }
            if queued {
                draftWriteVersion = clearVersion
                if draft == submittedDraft { draft = "" }
                attachedImage = nil
                attachedImageData = nil
                attachedImageMediaType = nil
                selectedPhotoItem = nil
            }
            isSending = false
        }
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

    @MainActor
    private func loadPhoto(_ item: PhotosPickerItem, generation: Int) async {
        guard generation == attachmentLoadGeneration else { return }
        isLoadingAttachment = true
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  data.count <= 32 * 1_024 * 1_024,
                  let prepared = AttachmentImageDecoder.secureJPEG(from: data)
            else { throw AttachmentSelectionError.invalidImage }
            guard generation == attachmentLoadGeneration else { return }
            attachedImage = prepared.preview
            attachedImageData = prepared.data
            attachedImageMediaType = "image/jpeg"
            isLoadingAttachment = false
        } catch {
            guard generation == attachmentLoadGeneration else { return }
            selectedPhotoItem = nil
            attachedImage = nil
            attachedImageData = nil
            attachedImageMediaType = nil
            isLoadingAttachment = false
            model.lastError = error.localizedDescription
        }
    }

    private func scrollToBottom(using proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(ConversationScrollAnchor.bottom, anchor: .bottom)
        }
    }
}

private enum ConversationScrollAnchor: Hashable {
    case bottom
}

private enum AttachmentImageDecoder {
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
            if encoded.count <= SecureMediaAttachmentCipher.maximumPlaintextBytes {
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
    let startAudioCall: () -> Void
    let startVideoCall: () -> Void

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

    var errorDescription: String? {
        "Choose a valid image that can be prepared securely at 10 MB or less."
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct SecurePhotoMessageView: View {
    @EnvironmentObject private var model: AppModel
    let message: LocalMessage
    let descriptor: KitMediaMessageDescriptor
    @State private var image: UIImage?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var retryGeneration = 0

    init(message: LocalMessage, descriptor: KitMediaMessageDescriptor) {
        self.message = message
        self.descriptor = descriptor
        _image = State(initialValue: message.attachmentData.flatMap { UIImage(data: $0) })
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 224, height: 168)
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            } else {
                Button {
                    retryGeneration &+= 1
                } label: {
                    VStack(spacing: 9) {
                        if isLoading {
                            ProgressView()
                                .tint(message.isOutgoing ? .white : KitColor.green)
                        } else {
                            Image(systemName: model.isOnline ? "photo.badge.arrow.down" : "photo.fill")
                                .font(.title2)
                        }
                        Text(errorMessage ?? (model.isOnline
                            ? "Loading encrypted photo…"
                            : "Photo available when online"))
                            .font(.caption)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(message.isOutgoing ? .white : KitColor.secondaryText)
                    .frame(width: 224, height: 132)
                    .background(
                        (message.isOutgoing ? Color.white.opacity(0.09) : KitColor.paleGreen.opacity(0.24)),
                        in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
            }
        }
        .overlay {
            SecurePhotoBubbleTopAndSideBorder(cornerRadius: 15)
                .stroke(
                    .white.opacity(message.isOutgoing ? 0.52 : 0.72),
                    style: StrokeStyle(
                        lineWidth: SecurePhotoBubbleBorderPolicy.lineWidth,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                .padding(SecurePhotoBubbleBorderPolicy.lineWidth / 2)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("End-to-end encrypted photo")
        .task(id: "\(descriptor.storageKey):\(model.isOnline):\(retryGeneration)") {
            await loadIfNeeded()
        }
    }

    @MainActor
    private func loadIfNeeded() async {
        guard image == nil, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let data = try await model.loadSecureImage(
                conversationId: message.conversationId,
                descriptorText: message.body
            )
            guard let decoded = UIImage(data: data) else {
                throw SecureMediaAttachmentError.invalidImage
            }
            image = decoded
        } catch {
            if !model.isOnline {
                errorMessage = "Photo available when online"
            } else {
                errorMessage = "Tap to retry"
            }
        }
    }
}

private struct PendingSecurePhotoMessageView: View {
    let message: LocalMessage

    var body: some View {
        Group {
            if let data = message.attachmentData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 224, height: 168)
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            } else {
                Label("Photo queued", systemImage: "photo.fill")
                    .font(.caption.weight(.semibold))
                    .frame(width: 224, height: 132)
            }
        }
        .overlay {
            SecurePhotoBubbleTopAndSideBorder(cornerRadius: 15)
                .stroke(
                    .white.opacity(message.isOutgoing ? 0.52 : 0.72),
                    style: StrokeStyle(
                        lineWidth: SecurePhotoBubbleBorderPolicy.lineWidth,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                .padding(SecurePhotoBubbleBorderPolicy.lineWidth / 2)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("End-to-end encrypted photo queued to send")
    }
}

private struct SecurePhotoBubbleTopAndSideBorder: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = min(cornerRadius, min(rect.width / 2, rect.height / 2))
        var path = Path()

        if SecurePhotoBubbleBorderPolicy.edges.contains(.left) {
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        }
        if SecurePhotoBubbleBorderPolicy.edges.contains(.top) {
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + radius, y: rect.minY),
                control: CGPoint(x: rect.minX, y: rect.minY)
            )
            path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        }
        if SecurePhotoBubbleBorderPolicy.edges.contains(.right) {
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.minY + radius),
                control: CGPoint(x: rect.maxX, y: rect.minY)
            )
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }

        return path
    }
}

enum ChatMessagePresentationPolicy {
    static let paymentRequestPreview = "💰 Payment request"
    static let paymentPreview = "💸 Payment"

    static func previewText(for message: LocalMessage) -> String {
        presentation(for: message).previewText
    }

    /// Text exposed to local global search. Wire descriptors are represented only by friendly,
    /// provider-neutral labels; photos remain excluded exactly as they were before this policy.
    static func searchableText(for message: LocalMessage) -> String? {
        presentation(for: message).searchableText
    }

    private static func presentation(
        for message: LocalMessage
    ) -> (previewText: String, searchableText: String?) {
        if let pending = message.pendingAttachment {
            return (photoPreview(caption: pending.caption), nil)
        }

        if let payment = KitPaymentMessage.parse(message.body) {
            let label = payment.action == .request ? paymentRequestPreview : paymentPreview
            let searchable = payment.note.map { "\(label) · \($0)" } ?? label
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
            return (photoPreview(caption: media.caption), nil)
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

    private static func photoPreview(caption: String?) -> String {
        guard let caption else { return "Photo" }
        return "Photo · \(caption)"
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
