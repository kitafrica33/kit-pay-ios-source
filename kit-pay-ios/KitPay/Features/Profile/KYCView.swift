import SafariServices
import SwiftUI

struct KYCView: View {
    let isRequiredForSignIn: Bool

    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var consent = false
    @State private var verificationDestination: VerificationDestination?
    @State private var isLaunchingVerification = false

    init(isRequiredForSignIn: Bool = false) {
        self.isRequiredForSignIn = isRequiredForSignIn
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statusCard
                privacyCard
                if shouldOfferVerification {
                    if resumableVerificationURL == nil {
                        Toggle(isOn: $consent) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("I consent to identity verification").font(.headline)
                                Text("Didit processes identity and liveness evidence under the Kit privacy notice.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tint(KitColor.green)
                        .padding(18)
                        .kitGlass(cornerRadius: 24)
                    }

                    Button {
                        launchVerification()
                    } label: {
                        Group {
                            if isLaunchingVerification {
                                ProgressView().tint(.white)
                            } else {
                                Label(buttonTitle, systemImage: "person.text.rectangle")
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 18))
                    .tint(KitColor.green)
                    .disabled(
                        isLaunchingVerification
                            || (resumableVerificationURL == nil && !consent)
                            || !model.isOnline
                    )
                }
            }
            .padding(18)
        }
        .background(KitColor.canvas)
        .navigationTitle(isRequiredForSignIn ? "Verify this iPhone" : "Identity verification")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.isOnline) {
            if model.isOnline { await model.refreshKYC() }
        }
        .refreshable { await model.refreshKYC() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refreshKYC() } }
        }
        .sheet(item: $verificationDestination, onDismiss: {
            Task { await model.refreshKYC() }
        }) { destination in
            SafariView(url: destination.url).ignoresSafeArea()
        }
    }

    private func launchVerification() {
        guard !isLaunchingVerification else { return }
        if let resumableVerificationURL {
            verificationDestination = VerificationDestination(url: resumableVerificationURL)
            return
        }
        isLaunchingVerification = true
        Task {
            defer { isLaunchingVerification = false }
            if let url = await model.startKYC() {
                verificationDestination = VerificationDestination(url: url)
            }
        }
    }

    private var statusCard: some View {
        let status = displayedStatus
        return HStack(spacing: 16) {
            Image(systemName: statusIcon(status))
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(statusColor(status))
                .frame(width: 64, height: 64)
                .background(statusColor(status).opacity(0.13), in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text(statusTitle(status)).font(.title3.bold()).foregroundStyle(KitColor.primaryText)
                Text(statusDescription(status))
                    .font(.subheadline)
                    .foregroundStyle(KitColor.secondaryText)
            }
            Spacer()
        }
        .padding(18)
        .kitGlass(cornerRadius: 26)
    }

    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("What happens", systemImage: "lock.shield")
                .font(.headline)
                .foregroundStyle(KitColor.primaryText)
            Text(isRequiredForSignIn
                ? "Kit creates a short-lived Didit check for this sign-in and iPhone. The app reloads the signed server decision and never trusts status values returned by the browser."
                : "Kit creates a short-lived Didit session. The app opens Didit’s secure hosted page and then reloads only your authenticated Kit status. It never trusts status values in a browser callback.")
                .font(.subheadline)
                .foregroundStyle(KitColor.secondaryText)
            Link("Read the Kit privacy notice", destination: URL(string: "https://pay.kit.africa/privacy")!)
                .font(.subheadline.bold())
        }
        .padding(18)
        .kitGlass(cornerRadius: 26)
    }

    private var buttonTitle: String {
        if resumableVerificationURL != nil { return "Continue verification" }
        return model.kycStatus?.providerSession == nil ? "Start verification" : "Try verification again"
    }

    private var resumableVerificationURL: URL? {
        KYCVerificationURLPolicy.validatedURL(
            from: model.kycStatus?.providerSession?.verificationURL
        )
    }

    private var shouldOfferVerification: Bool {
        let status = displayedStatus.lowercased()
        guard !["verified", "approved"].contains(status) else { return false }
        if resumableVerificationURL != nil { return true }
        guard let sessionStatus = model.kycStatus?.providerSession?.status?.lowercased() else {
            return true
        }
        return ["declined", "expired", "abandoned", "kyc expired", "failed"].contains(sessionStatus)
    }

    private func statusTitle(_ status: String) -> String {
        return switch status.lowercased() {
        case "verified", "approved": isRequiredForSignIn ? "This iPhone is verified" : "Identity verified"
        case "pending", "in_review", "review": "Verification under review"
        case "rejected", "declined", "failed": "Verification needs attention"
        default: "Verify your identity"
        }
    }

    private func statusDescription(_ status: String) -> String {
        if model.kycStatus?.case?.decisionCode == "DIDIT_APPROVED_AWAITING_COMPLIANCE" {
            return "Didit approved your identity. Kit is awaiting compliance clearance."
        }
        return switch status.lowercased() {
        case "verified", "approved": isRequiredForSignIn
            ? "Your identity proof is bound to this sign-in on this iPhone."
            : "Your Kit identity checks are complete."
        case "pending", "in_review", "review": "Your submitted evidence is being reviewed."
        case "rejected", "declined", "failed": "Review the instructions and try again."
        default: "Complete a secure hosted check with Didit."
        }
    }

    private var displayedStatus: String {
        if isRequiredForSignIn {
            return model.kycStatus?.deviceVerification?.status
                ?? model.sessionAssurance?.deviceIdentity.status
                ?? "required"
        }
        return model.kycStatus?.status ?? model.profile?.kycStatus ?? "not_started"
    }

    private func statusIcon(_ status: String) -> String {
        switch status.lowercased() {
        case "verified", "approved": "checkmark.seal.fill"
        case "pending", "in_review", "review": "hourglass.circle.fill"
        case "rejected", "declined", "failed": "exclamationmark.triangle.fill"
        default: "person.badge.shield.checkmark"
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "verified", "approved": KitColor.green
        case "rejected", "declined", "failed": .red
        default: .orange
        }
    }
}

enum KYCVerificationURLPolicy {
    static func validatedURL(from raw: String?) -> URL? {
        guard let raw,
              let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "verify.didit.me",
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443,
              url.fragment == nil
        else { return nil }
        return url
    }
}

private struct VerificationDestination: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.preferredControlTintColor = UIColor(KitColor.green)
        controller.dismissButtonStyle = .done
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
