import Foundation

enum APIClientIdentity {
    private static let fallbackVersion = "1.0.0"

    static var currentHeader: String {
        "ios/\(currentAppVersion)"
    }

    /// The backend stores this value on the authenticated Device row and uses its revision for
    /// rich-media compatibility. Keep it identical to the version portion of the request header.
    static var currentAppVersion: String {
        appVersion(
            marketingVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String,
            buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }

    static func header(marketingVersion: String?, buildNumber: String?) -> String {
        "ios/\(appVersion(marketingVersion: marketingVersion, buildNumber: buildNumber))"
    }

    static func appVersion(marketingVersion: String?, buildNumber: String?) -> String {
        let rawVersion = marketingVersion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let twoComponentPattern = #"\A(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\z"#
        let threeComponentPattern = #"\A(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\z"#
        let version: String
        if rawVersion.range(of: threeComponentPattern, options: .regularExpression) != nil {
            version = rawVersion
        } else if rawVersion.range(of: twoComponentPattern, options: .regularExpression) != nil {
            // App Store Connect permits a two-component marketing version, while the backend's
            // installed-client contract is strict SemVer. Canonicalize 1.0 to 1.0.0 on the wire.
            version = "\(rawVersion).0"
        } else {
            version = fallbackVersion
        }

        let rawBuild = buildNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let validBuild = rawBuild.range(
            of: #"\A(?:0|[1-9][0-9]*)\z"#,
            options: .regularExpression
        ) != nil
        return validBuild ? "\(version)-r\(rawBuild)" : version
    }
}

