import SafariServices
import SwiftUI

enum KitMerchantHelpURLPolicy {
    static let canonicalURLString = "https://pay.kit.africa/merchant-help"

    static var canonicalURL: URL {
        let url = URL(string: canonicalURLString)!
        precondition(isTrustedMerchantHelpURL(url))
        return url
    }

    static func isTrustedMerchantHelpURL(_ url: URL) -> Bool {
        guard url.baseURL == nil,
              url.absoluteString == url.absoluteString.trimmingCharacters(
                in: .whitespacesAndNewlines
              ),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "pay.kit.africa",
              components.percentEncodedHost?.lowercased() == "pay.kit.africa",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil
        else { return false }
        return components.percentEncodedPath == "/merchant-help"
    }
}

struct MerchantAccountHelpLinks: View {
    @State private var webDestination: MerchantHelpWebDestination?

    var body: some View {
        Button {
            webDestination = MerchantHelpWebDestination(
                url: KitMerchantHelpURLPolicy.canonicalURL
            )
        } label: {
            Label("Click here to learn more", systemImage: "safari.fill")
                .font(.subheadline.weight(.semibold))
        }
        .sheet(item: $webDestination) { destination in
            MerchantHelpSafariView(url: destination.url)
                .ignoresSafeArea()
        }

        NavigationLink {
            MerchantAccountEducationView()
        } label: {
            Label("View the in-app setup guide", systemImage: "list.number")
                .font(.subheadline)
        }
    }
}

struct MerchantAccountEducationView: View {
    var body: some View {
        List {
            Section {
                Label {
                    Text(
                        "Merchant payments need an active Kit Pay business wallet before "
                            + "a merchant account can be created."
                    )
                } icon: {
                    Image(systemName: "storefront.circle.fill")
                        .foregroundStyle(KitColor.green)
                }
            }

            Section("Set-up order") {
                setupStep(
                    number: 1,
                    title: "Business wallet",
                    detail: "Create an active Kit Pay business wallet for settlement."
                )
                setupStep(
                    number: 2,
                    title: "Merchant account",
                    detail: "Select that wallet, then create the merchant account linked to it."
                )
                setupStep(
                    number: 3,
                    title: "Payment QR codes",
                    detail: "Create signed QR codes after Kit confirms the merchant account."
                )
            }

            Section("How settlement works") {
                Text(
                    "The merchant account identifies your business for QR payments. "
                        + "The selected business wallet receives the resulting settlements. "
                        + "A merchant account does not replace the business wallet."
                )
                Text(
                    "If no business wallet is listed, set up a business wallet on your "
                        + "Kit Pay account before returning to merchant setup."
                )
            }
        }
        .navigationTitle("Merchant account setup")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func setupStep(number: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(KitColor.green, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number), \(title). \(detail)")
    }
}

private struct MerchantHelpWebDestination: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct MerchantHelpSafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.preferredControlTintColor = UIColor(KitColor.green)
        controller.dismissButtonStyle = .done
        return controller
    }

    func updateUIViewController(
        _ uiViewController: SFSafariViewController,
        context: Context
    ) {}
}
