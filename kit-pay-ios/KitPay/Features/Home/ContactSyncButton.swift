import SwiftUI
import UIKit

/// Contact discovery is automatic, so recipient pickers stay quiet unless the
/// user can take a concrete recovery action.
struct ContactSyncRecoveryView: View {
    @EnvironmentObject private var model: AppModel
    private let horizontalPadding: CGFloat
    private let verticalPadding: CGFloat

    init(horizontalPadding: CGFloat = 0, verticalPadding: CGFloat = 0) {
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
    }

    @ViewBuilder
    var body: some View {
        let recovery = ContactSyncRecoveryPresentation.presentation(for: model.contactSyncState)
        switch recovery {
        case .openSettings:
            Button(action: openSettings) {
                recoveryCard(icon: "person.crop.circle.badge.exclamationmark") {
                    Text("Contacts access is off")
                    Text("Open Settings to find people on Kit Pay")
                        .font(.caption)
                        .foregroundStyle(KitColor.secondaryText)
                }
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Open Contacts settings")
            .accessibilityHint("Allow Kit Pay to access contacts, then return to this screen.")
            .accessibilityIdentifier(recovery?.accessibilityIdentifier ?? "")
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
        case .retry(let message):
            Button { model.retryAutomaticContactSync() } label: {
                recoveryCard(icon: "arrow.clockwise.circle") {
                    Text("Contact sync paused — tap to retry")
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(KitColor.secondaryText)
                        .lineLimit(2)
                }
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Retry contact sync")
            .accessibilityHint("Attempts to refresh contacts again.")
            .accessibilityIdentifier(recovery?.accessibilityIdentifier ?? "")
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
        case nil:
            EmptyView()
        }
    }

    private func recoveryCard<Content: View>(
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
