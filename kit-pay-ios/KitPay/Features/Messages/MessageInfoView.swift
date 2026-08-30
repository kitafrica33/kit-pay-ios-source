import SwiftUI

/// What happened to a message after it left the composer.
///
/// A direct chat gets three lines, because there is only one person to report on. A group gets one
/// row per member, because "delivered" across thirty people is an average nobody asked for — the
/// question is always *who*, and tapping a name answers *when* for that person alone.
struct MessageInfoView: View {
    let conversationID: String
    let serverMessageID: String
    /// Resolved by the conversation that opened this, so a person is called what this phone's own
    /// address book calls them rather than whatever the server last knew.
    let nameForUserID: (String) -> String
    let avatarURLForUserID: (String) -> String?
    let verificationForUserID: (String) -> AccountVerificationDesignation?

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .loading
    @State private var expandedUserIDs: Set<String> = []

    private enum Phase {
        case loading
        case loaded(MessageDeliveryInfo)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Message info")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Loading message info")
        case .failed(let message):
            VStack(spacing: 16) {
                Image(systemName: "info.circle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Try again") {
                    phase = .loading
                    Task { await load() }
                }
                .buttonStyle(.bordered)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let info):
            List {
                Section {
                    momentRow(
                        title: "Sent",
                        systemImage: "checkmark",
                        moment: info.sentAt
                    )
                }
                if info.recipients.count == 1, let only = info.recipients.first {
                    Section {
                        momentRow(
                            title: "Delivered",
                            systemImage: "checkmark.circle",
                            moment: only.deliveredAt
                        )
                        momentRow(
                            title: "Read",
                            systemImage: "eye",
                            moment: only.readAt
                        )
                    }
                } else {
                    Section {
                        ForEach(info.recipients) { recipient in
                            recipientRow(recipient, sentAt: info.sentAt)
                        }
                    } header: {
                        Text("Read by \(info.readCount) of \(info.recipients.count)")
                    } footer: {
                        Text("Tap somebody to see when the message reached them.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
    }

    private func momentRow(title: String, systemImage: String, moment: Date?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(moment == nil ? .secondary : Color.accentColor)
                .frame(width: 20)
            Text(title)
            Spacer(minLength: 12)
            Text(moment.map { MessageDeliveryMomentFormatter.label(for: $0) } ?? "Not yet")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func recipientRow(_ recipient: MessageDeliveryRecipient, sentAt: Date) -> some View {
        let name = displayName(for: recipient)
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    if expandedUserIDs.contains(recipient.userID) {
                        expandedUserIDs.remove(recipient.userID)
                    } else {
                        expandedUserIDs.insert(recipient.userID)
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    RemoteAvatarView(
                        name: name,
                        avatarURL: avatarURLForUserID(recipient.userID),
                        size: 40
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        VerifiedAccountNameLabel(
                            designation: verificationForUserID(recipient.userID)
                        ) {
                            Text(name)
                                .font(.body)
                                .foregroundStyle(.primary)
                        }
                        Text(summary(for: recipient))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(
                            .degrees(expandedUserIDs.contains(recipient.userID) ? 0 : -90)
                        )
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expandedUserIDs.contains(recipient.userID) {
                VStack(spacing: 8) {
                    momentRow(title: "Sent", systemImage: "checkmark", moment: sentAt)
                    momentRow(
                        title: "Delivered",
                        systemImage: "checkmark.circle",
                        moment: recipient.deliveredAt
                    )
                    momentRow(title: "Read", systemImage: "eye", moment: recipient.readAt)
                }
                .font(.callout)
                .padding(.leading, 52)
            }
        }
        .padding(.vertical, 2)
        .accessibilityHint("Shows when this message reached \(name)")
    }

    /// The furthest the message got with this person, said in one line.
    private func summary(for recipient: MessageDeliveryRecipient) -> String {
        if let readAt = recipient.readAt {
            return "Read · \(MessageDeliveryMomentFormatter.label(for: readAt))"
        }
        if let deliveredAt = recipient.deliveredAt {
            return "Delivered · \(MessageDeliveryMomentFormatter.label(for: deliveredAt))"
        }
        return "Not delivered yet"
    }

    /// This phone's own name for somebody, falling back to the server's only when the address book
    /// has nothing — a group can contain people who were never saved as contacts.
    private func displayName(for recipient: MessageDeliveryRecipient) -> String {
        let local = nameForUserID(recipient.userID)
        let unknown = local.isEmpty || local == "Kit Pay user"
        return unknown ? recipient.serverName : local
    }

    private func load() async {
        let result = await model.messageDeliveryInfo(
            conversationID: conversationID,
            serverMessageID: serverMessageID
        )
        switch result {
        case .success(let info):
            phase = .loaded(info)
        case .failure(let error):
            phase = .failed(
                (error as? LocalizedError)?.errorDescription
                    ?? "Kit could not load the details for this message."
            )
        }
    }
}
