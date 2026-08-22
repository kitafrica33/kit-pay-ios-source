import SwiftUI

/// End-to-end encrypted iCloud chat backup settings: manual backup, auto-backup
/// frequency (daily/weekly/monthly), media inclusion, and restore.
struct ChatBackupSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var latestRemoteBackup: MessageBackupSummary?
    @State private var isCheckingRemote = false
    @State private var showsRestoreConfirmation = false
    @State private var showsDeleteConfirmation = false
    @State private var restoreCompleted = false

    private var preferences: MessageBackupPreferences { model.messageBackupPreferences }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                explainerCard
                backupNowCard
                scheduleCard
                restoreCard
                deleteCard
            }
            .padding(18)
        }
        .background(KitColor.canvas.ignoresSafeArea())
        .navigationTitle("Chats & backup")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshRemoteSummary() }
    }

    private var explainerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "lock.icloud.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(KitColor.green)
                Text("End-to-end encrypted")
                    .font(.headline)
                    .foregroundStyle(KitColor.navy)
            }
            Text(
                "Backups are encrypted on this iPhone before they reach iCloud. The key lives only in your iCloud Keychain — neither Kit nor Apple can read your messages."
            )
            .font(.footnote)
            .foregroundStyle(KitColor.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .kitGlass(cornerRadius: 24, tint: KitColor.paleGreen, shadow: false)
    }

    private var backupNowCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Last backup")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(KitColor.secondaryText)
                if let lastBackupAt = preferences.lastBackupAt {
                    Text(lastBackupAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(KitColor.navy)
                    if let bytes = preferences.lastBackupByteSize,
                       let count = preferences.lastBackupMessageCount {
                        Text("\(count) messages · \(ChatMediaBytes.label(bytes))")
                            .font(.caption)
                            .foregroundStyle(KitColor.secondaryText)
                    }
                } else {
                    Text("Never backed up on this iPhone")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(KitColor.navy)
                }
            }

            Button {
                Task {
                    if await model.backUpMessagesNow() {
                        await refreshRemoteSummary()
                    }
                }
            } label: {
                Group {
                    if model.isBackingUpMessages {
                        HStack(spacing: 10) {
                            ProgressView().tint(.white)
                            Text("Encrypting & uploading…")
                        }
                    } else {
                        Label("Back up now", systemImage: "icloud.and.arrow.up.fill")
                    }
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(KitColor.green, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(
                model.isBackingUpMessages
                    || model.isRestoringMessages
                    || model.isDeletingMessageBackup
                    || !model.isOnline
            )
            .opacity(
                model.isBackingUpMessages
                    || model.isRestoringMessages
                    || model.isDeletingMessageBackup
                    || !model.isOnline ? 0.6 : 1
            )

            if !model.isOnline {
                Label("Connect to the internet to back up.", systemImage: "wifi.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .kitGlass(cornerRadius: 24, shadow: false)
    }

    private var scheduleCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Automatic backups")
                .font(.headline)
                .foregroundStyle(KitColor.navy)
            Picker("Frequency", selection: Binding(
                get: { preferences.frequency },
                set: { frequency in Task { await model.setMessageBackupFrequency(frequency) } }
            )) {
                ForEach(MessageBackupFrequency.allCases, id: \.self) { frequency in
                    Text(frequency.displayName).tag(frequency)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.isDeletingMessageBackup)

            Toggle(isOn: Binding(
                get: { preferences.includesMedia },
                set: { includes in Task { await model.setMessageBackupIncludesMedia(includes) } }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Include photos & voice notes")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(KitColor.navy)
                    Text("Large videos and documents are always re-downloaded, not backed up.")
                        .font(.caption)
                        .foregroundStyle(KitColor.secondaryText)
                }
            }
            .tint(KitColor.green)
            .disabled(model.isDeletingMessageBackup)

            if preferences.frequency != .off {
                Label(
                    "Backups run \(preferences.frequency.displayName.lowercased()) when Kit Pay is online.",
                    systemImage: "clock.arrow.circlepath"
                )
                .font(.caption)
                .foregroundStyle(KitColor.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .kitGlass(cornerRadius: 24, shadow: false)
    }

    private var restoreCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Restore")
                .font(.headline)
                .foregroundStyle(KitColor.navy)

            if isCheckingRemote {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Checking iCloud…")
                        .font(.subheadline)
                        .foregroundStyle(KitColor.secondaryText)
                }
            } else if let remote = latestRemoteBackup {
                VStack(alignment: .leading, spacing: 3) {
                    Text("iCloud backup from \(remote.deviceName)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(KitColor.navy)
                    Text(
                        "\(remote.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(remote.messageCount) messages · \(ChatMediaBytes.label(remote.byteSize))"
                    )
                    .font(.caption)
                    .foregroundStyle(KitColor.secondaryText)
                }

                Button {
                    showsRestoreConfirmation = true
                } label: {
                    Group {
                        if model.isRestoringMessages {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Restoring…")
                            }
                        } else if restoreCompleted {
                            Label("Restored", systemImage: "checkmark.circle.fill")
                        } else {
                            Label("Restore messages", systemImage: "icloud.and.arrow.down")
                        }
                    }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(KitColor.green)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .kitGlass(cornerRadius: 18, shadow: false)
                }
                .buttonStyle(.plain)
                .disabled(
                    model.isRestoringMessages
                        || model.isBackingUpMessages
                        || model.isDeletingMessageBackup
                        || restoreCompleted
                        || !model.isOnline
                )
            } else {
                Text("No backup found in this iCloud account yet.")
                    .font(.subheadline)
                    .foregroundStyle(KitColor.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .kitGlass(cornerRadius: 24, shadow: false)
        .confirmationDialog(
            "Restore messages from iCloud?",
            isPresented: $showsRestoreConfirmation,
            titleVisibility: .visible
        ) {
            Button("Restore") {
                Task {
                    restoreCompleted = await model.restoreMessagesFromBackup()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Messages already on this iPhone are kept; the backup only fills in what's missing.")
        }
    }

    private var deleteCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete encrypted backup")
                .font(.headline)
                .foregroundStyle(KitColor.navy)
            Text(
                "Deletes the encrypted iCloud record and its iCloud Keychain key. Chats on this iPhone stay here, and automatic backups turn off."
            )
            .font(.footnote)
            .foregroundStyle(KitColor.secondaryText)

            Button(role: .destructive) {
                showsDeleteConfirmation = true
            } label: {
                Group {
                    if model.isDeletingMessageBackup {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Deleting…")
                        }
                    } else {
                        Label("Delete backup & key", systemImage: "trash")
                    }
                }
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .kitGlass(cornerRadius: 18, shadow: false)
            }
            .buttonStyle(.plain)
            .disabled(
                model.isDeletingMessageBackup
                    || model.isBackingUpMessages
                    || model.isRestoringMessages
                    || !model.isOnline
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .kitGlass(cornerRadius: 24, shadow: false)
        .confirmationDialog(
            "Delete your encrypted chat backup?",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete backup & key", role: .destructive) {
                Task {
                    if await model.deleteMessageBackup() {
                        latestRemoteBackup = nil
                        restoreCompleted = false
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone. Chats already stored on this iPhone will not be deleted.")
        }
    }

    private func refreshRemoteSummary() async {
        guard let userID = model.profile?.id,
              model.isOnline,
              !model.isDeletingMessageBackup
        else { return }
        isCheckingRemote = true
        defer { isCheckingRemote = false }
        let summary = try? await MessageBackupManager.shared.latestBackupSummary(
            forUserID: userID
        )
        guard model.profile?.id == userID, !model.isDeletingMessageBackup else { return }
        latestRemoteBackup = summary
    }
}
