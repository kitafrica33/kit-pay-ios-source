import SwiftUI

struct LegalPrivacyView: View {
    @Environment(\.openURL) private var openURL
    @State private var activeDocument: LegalTextDocument?
    @State private var unavailableMessage: String?

    private let privacy = KitPrivacyPolicyPresentation.canonical
    private let openSource: KitOpenSourceLicencePresentation?
    private let resources: KitLegalTextResources

    init(bundle: Bundle = .main) {
        openSource = KitOpenSourceLicencePresentation.current(in: bundle)
        resources = KitLegalTextResources.bundled(in: bundle)
    }

    var body: some View {
        ZStack {
            glassBackdrop

            ScrollView {
                VStack(spacing: 18) {
                    hero
                    privacyCard
                    openSourceCard
                    noticesCard
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 20)
            }
        }
        .navigationTitle("Legal & privacy")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $activeDocument) { document in
            LegalTextDocumentView(document: document)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .alert(
            "Unable to open",
            isPresented: Binding(
                get: { unavailableMessage != nil },
                set: { if !$0 { unavailableMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(unavailableMessage ?? "Please try again.")
        }
    }

    private var glassBackdrop: some View {
        ZStack {
            KitColor.canvas.ignoresSafeArea()
            Circle()
                .fill(KitColor.green.opacity(0.18))
                .frame(width: 270, height: 270)
                .blur(radius: 70)
                .offset(x: 145, y: -310)
            Circle()
                .fill(KitColor.navy.opacity(0.14))
                .frame(width: 320, height: 320)
                .blur(radius: 85)
                .offset(x: -170, y: 330)
        }
        .allowsHitTesting(false)
    }

    private var hero: some View {
        HStack(spacing: 16) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(
                    LinearGradient(
                        colors: [KitColor.green, KitColor.navy],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: Circle()
                )
                .overlay {
                    Circle().stroke(.white.opacity(0.65), lineWidth: 0.8)
                }

            VStack(alignment: .leading, spacing: 5) {
                Text("Your rights, clearly explained")
                    .font(.title3.bold())
                    .foregroundStyle(KitColor.primaryText)
                Text("Privacy information, software notices and exact licence terms.")
                    .font(.subheadline)
                    .foregroundStyle(KitColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .kitGlass(cornerRadius: 26)
    }

    private var privacyCard: some View {
        glassSection(title: privacy.title, icon: "hand.raised.fill") {
            Text(privacy.subtitle)
                .font(.subheadline)
                .foregroundStyle(KitColor.secondaryText)

            Button {
                openPrivacyPolicy()
            } label: {
                externalLinkLabel(
                    title: "Read privacy policy",
                    detail: "pay.kit.africa/privacy"
                )
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the official Kit Pay privacy policy")
        }
    }

    @ViewBuilder
    private var openSourceCard: some View {
        if let openSource {
            glassSection(title: openSource.title, icon: "chevron.left.forwardslash.chevron.right") {
                Text(openSource.licenceIdentifier)
                    .font(.caption.bold())
                    .foregroundStyle(KitColor.green)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(KitColor.green.opacity(0.12), in: Capsule())

                Text(openSource.licenceNotice)
                    .font(.subheadline)
                    .foregroundStyle(KitColor.primaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Label(openSource.warrantyNotice, systemImage: "exclamationmark.shield")
                    .font(.footnote)
                    .foregroundStyle(KitColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Corresponding source for this exact version")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(KitColor.primaryText)
                    Text(openSource.release.displayName)
                        .font(.caption)
                        .foregroundStyle(KitColor.secondaryText)

                    if let sourceURL = openSource.correspondingSource.url {
                        Button {
                            openCorrespondingSource(sourceURL, release: openSource.release)
                        } label: {
                            externalLinkLabel(
                                title: "View exact source",
                                detail: sourceURL.absoluteString
                            )
                        }
                        .buttonStyle(.plain)
                    } else {
                        Label(
                            "A public source release has not been published for this build.",
                            systemImage: "clock.badge.exclamationmark"
                        )
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(
                            "Corresponding source is not yet available for this exact version"
                        )
                    }
                }
            }
        } else {
            glassSection(title: "Open-source software", icon: "exclamationmark.triangle.fill") {
                Text("This build does not contain a valid version identity, so its exact "
                    + "open-source presentation cannot be shown.")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var noticesCard: some View {
        glassSection(title: "Licence documents", icon: "doc.text.fill") {
            documentButton(
                title: "Third-party notices",
                subtitle: "Components, versions, copyright and licence terms",
                systemImage: "list.bullet.rectangle",
                text: resources.thirdPartyNotices
            )

            Divider()

            documentButton(
                title: "Full GNU AGPL v3",
                subtitle: "Complete AGPL-3.0-only text for LibSignalClient",
                systemImage: "doc.plaintext",
                text: resources.fullAGPL
            )
        }
    }

    private func glassSection<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(KitColor.primaryText)
                .symbolRenderingMode(.hierarchical)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .kitGlass(cornerRadius: 26)
    }

    private func externalLinkLabel(title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "safari.fill")
                .font(.headline)
                .foregroundStyle(KitColor.green)
                .frame(width: 38, height: 38)
                .background(.thinMaterial, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KitColor.primaryText)
                Text(verbatim: detail)
                    .font(.caption)
                    .foregroundStyle(KitColor.secondaryText)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Image(systemName: "arrow.up.right")
                .font(.caption.bold())
                .foregroundStyle(KitColor.secondaryText)
        }
        .contentShape(Rectangle())
    }

    private func documentButton(
        title: String,
        subtitle: String,
        systemImage: String,
        text: String?
    ) -> some View {
        Button {
            guard let text else {
                unavailableMessage = "This licence document is missing from this build."
                return
            }
            activeDocument = LegalTextDocument(title: title, text: text)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.headline)
                    .foregroundStyle(KitColor.green)
                    .frame(width: 38, height: 38)
                    .background(.thinMaterial, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(KitColor.primaryText)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(KitColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func openPrivacyPolicy() {
        guard KitLegalURLPolicy.isTrustedPrivacyPolicyURL(privacy.url) else {
            unavailableMessage = "The privacy policy address did not pass Kit Pay's safety checks."
            return
        }
        openURL(privacy.url) { accepted in
            if !accepted {
                unavailableMessage = "The privacy policy could not be opened on this device."
            }
        }
    }

    private func openCorrespondingSource(
        _ url: URL,
        release: KitLegalReleaseIdentity
    ) {
        guard KitLegalURLPolicy.isTrustedCorrespondingSourceURL(url, for: release) else {
            unavailableMessage = "The source address did not pass Kit Pay's safety checks."
            return
        }
        openURL(url) { accepted in
            if !accepted {
                unavailableMessage = "The source release could not be opened on this device."
            }
        }
    }
}

struct LegalTextDocument: Identifiable {
    let id = UUID()
    let title: String
    let text: String
}

private struct LegalTextDocumentView: View {
    @Environment(\.dismiss) private var dismiss
    let document: LegalTextDocument

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(verbatim: document.text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(KitColor.primaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .kitGlass(cornerRadius: 22, shadow: false)
                    .padding(16)
            }
            .background(KitColor.canvas)
            .navigationTitle(document.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        LegalPrivacyView()
    }
}
