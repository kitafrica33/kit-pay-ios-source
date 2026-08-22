import SwiftUI
import UIKit

/// Passive status used by recipient pickers. Contact discovery starts at app
/// launch and on address-book changes, so users never need to manually refresh.
struct ContactSyncStatusView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        switch model.contactSyncState {
        case .idle:
            EmptyView()
        case .requestingPermission:
            statusCard(icon: "person.crop.circle.badge.questionmark") {
                Text("Waiting for Contacts access")
                ProgressView()
            }
        case .denied:
            Button(action: openSettings) {
                statusCard(icon: "person.crop.circle.badge.exclamationmark") {
                    Text("Contacts access is off")
                    Text("Open Settings to find people on Kit Pay")
                        .font(.caption)
                        .foregroundStyle(KitColor.secondaryText)
                }
            }
            .buttonStyle(.plain)
        case .syncing(let progress):
            statusCard(icon: "arrow.triangle.2.circlepath") {
                Text(progressTitle(progress.phase))
                if let fraction = progress.fractionCompleted {
                    ProgressView(value: fraction)
                        .tint(KitColor.green)
                        .accessibilityValue(Text(fraction, format: .percent))
                } else {
                    ProgressView().tint(KitColor.green)
                }
            }
        case let .synced(uploaded, matched, limitedAccess):
            if limitedAccess {
                Button(action: openSettings) {
                    statusCard(icon: "person.crop.circle.badge.checkmark") {
                        Text("Selected contacts stay synced")
                        Text("Found \(matched) on Kit Pay · Manage access")
                            .font(.caption)
                            .foregroundStyle(KitColor.secondaryText)
                    }
                }
                .buttonStyle(.plain)
            } else {
                statusCard(icon: "checkmark.icloud") {
                    Text("Contacts are up to date")
                    Text("Checked \(uploaded.formatted()) · Found \(matched) on Kit Pay")
                        .font(.caption)
                        .foregroundStyle(KitColor.secondaryText)
                }
            }
        case .failed(let message):
            Button { model.retryAutomaticContactSync() } label: {
                statusCard(icon: "arrow.clockwise.circle") {
                    Text("Contact sync paused — tap to retry")
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(KitColor.secondaryText)
                        .lineLimit(2)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func statusCard<Content: View>(
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(KitColor.green)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 5) {
                content()
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(KitColor.primaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .contentShape(Rectangle())
        .kitGlass(cornerRadius: 18, tint: KitColor.paleGreen, shadow: false)
    }

    private func progressTitle(_ phase: ContactSyncPhase) -> String {
        switch phase {
        case .preparing: "Reading contacts…"
        case .uploading: "Syncing contacts…"
        case .finalizing: "Finishing contact sync…"
        case .refreshing: "Checking who is on Kit Pay…"
        case .complete: "Updating contact list…"
        }
    }

    private func openSettings() {
        guard let settings = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(settings)
    }
}

struct ContactSyncProgressBanner: View {
    let state: AutomaticContactSyncState

    var body: some View {
        if case .syncing(let progress) = state {
            VStack(spacing: 4) {
                if let fraction = progress.fractionCompleted {
                    ProgressView(value: fraction).tint(KitColor.green)
                } else {
                    ProgressView().tint(KitColor.green)
                }
                Text(label(for: progress.phase))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(KitColor.secondaryText)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial)
            .accessibilityElement(children: .combine)
        } else if state == .requestingPermission {
            ProgressView("Preparing contacts…")
                .font(.caption)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
        }
    }

    private func label(for phase: ContactSyncPhase) -> String {
        switch phase {
        case .preparing: "Reading contacts"
        case .uploading: "Syncing contacts"
        case .finalizing: "Finalizing contacts"
        case .refreshing: "Checking Kit Pay membership"
        case .complete: "Contacts synced"
        }
    }
}
