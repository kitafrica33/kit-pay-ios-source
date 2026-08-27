import Foundation

enum KitLegalConstants {
    static let agplLicenceIdentifier = "AGPL-3.0-only"
    static let privacyPolicyURLString = "https://pay.kit.africa/privacy"
    static let privacyNoticeVersion = "kit-privacy-2026-08-20"
    static let approvedSourceRepositoryPath = "/kitafrica33/kit-pay-ios-source"
    static let correspondingSourceInfoKey = "KitCorrespondingSourceURL"
    static let fullLicenceResourceName = "AGPL-3.0-only"
    static let thirdPartyNoticesResourceName = "THIRD_PARTY_NOTICES"
}

struct KitLegalReleaseIdentity: Equatable {
    let versionName: String
    let buildNumber: String

    init?(versionName: String, buildNumber: String) {
        guard Self.matches(
            versionName,
            pattern: #"[0-9]+(?:\.[0-9]+){2}(?:[-+][A-Za-z0-9.-]+)?"#
        ), Self.matches(buildNumber, pattern: #"[1-9][0-9]*"#) else {
            return nil
        }

        self.versionName = versionName
        self.buildNumber = buildNumber
    }

    init?(bundle: Bundle) {
        guard let versionName = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String,
        let buildNumber = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        else {
            return nil
        }

        self.init(versionName: versionName, buildNumber: buildNumber)
    }

    var displayName: String {
        "Version \(versionName) (\(buildNumber))"
    }

    var sourceTag: String {
        "v\(versionName)-build\(buildNumber)"
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        guard !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              let expression = try? NSRegularExpression(pattern: pattern)
        else {
            return false
        }

        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = expression.firstMatch(in: value, range: range) else {
            return false
        }
        return match.range == range
    }
}

enum KitLegalURLPolicy {
    private static let privacyHost = "pay.kit.africa"
    private static let sourceHost = "github.com"

    static var privacyPolicyURL: URL {
        // This literal is covered by the same strict validation used for external values.
        URL(string: KitLegalConstants.privacyPolicyURLString)!
    }

    static func correspondingSourceURL(
        for release: KitLegalReleaseIdentity,
        candidate: URL?
    ) -> URL? {
        guard let candidate,
              isTrustedCorrespondingSourceURL(candidate, for: release)
        else {
            return nil
        }
        return candidate
    }

    static func isTrustedPrivacyPolicyURL(_ url: URL) -> Bool {
        guard let components = trustedHTTPSComponents(url, host: privacyHost) else {
            return false
        }
        return components.percentEncodedPath == "/privacy"
    }

    static func isTrustedCorrespondingSourceURL(
        _ url: URL,
        for release: KitLegalReleaseIdentity
    ) -> Bool {
        guard let components = trustedHTTPSComponents(url, host: sourceHost) else {
            return false
        }
        let expectedPath = KitLegalConstants.approvedSourceRepositoryPath
            + "/releases/tag/\(release.sourceTag)"
        return components.percentEncodedPath == expectedPath
    }

    private static func trustedHTTPSComponents(
        _ url: URL,
        host expectedHost: String
    ) -> URLComponents? {
        guard url.baseURL == nil,
              url.absoluteString == url.absoluteString.trimmingCharacters(
                in: .whitespacesAndNewlines
              ),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == expectedHost,
              components.percentEncodedHost?.lowercased() == expectedHost,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil
        else {
            return nil
        }
        return components
    }

}

struct KitPrivacyPolicyPresentation: Equatable {
    let title: String
    let subtitle: String
    let url: URL

    static var canonical: KitPrivacyPolicyPresentation {
        KitPrivacyPolicyPresentation(
            title: "Privacy policy",
            subtitle: "Learn how Kit Pay handles and protects your data",
            url: KitLegalURLPolicy.privacyPolicyURL
        )
    }
}

enum KitCorrespondingSourcePresentation: Equatable {
    case published(URL)
    case unavailable

    var url: URL? {
        guard case let .published(url) = self else { return nil }
        return url
    }
}

struct KitOpenSourceLicencePresentation: Equatable {
    let title: String
    let licenceIdentifier: String
    let licenceNotice: String
    let warrantyNotice: String
    let release: KitLegalReleaseIdentity
    let correspondingSource: KitCorrespondingSourcePresentation

    static func make(
        release: KitLegalReleaseIdentity,
        publishedSourceURL: URL? = nil
    ) -> KitOpenSourceLicencePresentation {
        let trustedSource = KitLegalURLPolicy.correspondingSourceURL(
            for: release,
            candidate: publishedSourceURL
        )

        return KitOpenSourceLicencePresentation(
            title: "Open-source software",
            licenceIdentifier: KitLegalConstants.agplLicenceIdentifier,
            licenceNotice: "Kit Pay for iOS includes LibSignalClient. LibSignalClient "
                + "and its covered code are licensed under the GNU Affero General "
                + "Public License, version 3 only (AGPL-3.0-only). Other bundled "
                + "components retain their respective licence terms.",
            warrantyNotice: "Open-source components are provided by their copyright "
                + "holders WITHOUT ANY WARRANTY, including implied warranties of "
                + "MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. Read the "
                + "bundled notices and licence text for the complete terms.",
            release: release,
            correspondingSource: trustedSource.map(
                KitCorrespondingSourcePresentation.published
            ) ?? .unavailable
        )
    }

    static func current(in bundle: Bundle = .main) -> KitOpenSourceLicencePresentation? {
        guard let release = KitLegalReleaseIdentity(bundle: bundle) else {
            return nil
        }
        let configuredValue = bundle.object(
            forInfoDictionaryKey: KitLegalConstants.correspondingSourceInfoKey
        ) as? String
        let configuredURL = configuredValue.flatMap(URL.init(string:))
        return make(release: release, publishedSourceURL: configuredURL)
    }
}

struct KitLegalTextResources: Equatable {
    let thirdPartyNotices: String?
    let fullAGPL: String?

    static func bundled(in bundle: Bundle = .main) -> KitLegalTextResources {
        KitLegalTextResources(
            thirdPartyNotices: loadText(
                named: KitLegalConstants.thirdPartyNoticesResourceName,
                in: bundle
            ),
            fullAGPL: loadText(
                named: KitLegalConstants.fullLicenceResourceName,
                in: bundle
            )
        )
    }

    private static func loadText(named name: String, in bundle: Bundle) -> String? {
        let candidates = [
            bundle.url(forResource: name, withExtension: "txt", subdirectory: "Legal"),
            bundle.url(forResource: name, withExtension: "txt"),
        ]

        for case let url? in candidates {
            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
            !data.isEmpty,
            data.count <= 2_000_000,
            let text = String(data: data, encoding: .utf8),
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                continue
            }
            return text
        }

        return nil
    }
}
