import Foundation
import XCTest
@testable import KitPay

final class LegalURLPolicyTests: XCTestCase {
    func testPrivacyPresentationUsesOnlyCanonicalTrustedPolicyURL() {
        let presentation = KitPrivacyPolicyPresentation.canonical

        XCTAssertEqual(presentation.title, "Privacy policy")
        XCTAssertEqual(
            presentation.url.absoluteString,
            "https://pay.kit.africa/privacy"
        )
        XCTAssertTrue(KitLegalURLPolicy.isTrustedPrivacyPolicyURL(presentation.url))
    }

    func testPrivacyPolicyRejectsDowngradesAndAmbiguousDestinations() throws {
        let rejectedValues = [
            "http://pay.kit.africa/privacy",
            "https://pay.kit.africa.evil.test/privacy",
            "https://user@pay.kit.africa/privacy",
            "https://user:password@pay.kit.africa/privacy",
            "https://pay.kit.africa:443/privacy",
            "https://pay.kit.africa/privacy/",
            "https://pay.kit.africa/%70rivacy",
            "https://pay.kit.africa/Privacy",
            "https://pay.kit.africa/privacy?next=evil",
            "https://pay.kit.africa/privacy#other",
        ]

        for value in rejectedValues {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertFalse(
                KitLegalURLPolicy.isTrustedPrivacyPolicyURL(url),
                "Expected the privacy policy to reject \(value)"
            )
        }
    }

    func testReleaseIdentityAcceptsExactSemanticVersionAndPositiveBuild() throws {
        let release = try XCTUnwrap(
            KitLegalReleaseIdentity(versionName: "0.2.3", buildNumber: "11")
        )

        XCTAssertEqual(release.displayName, "Version 0.2.3 (11)")
        XCTAssertEqual(release.sourceTag, "v0.2.3-build11")
    }

    func testReleaseIdentityRejectsMalformedOrInjectableValues() {
        let malformedValues: [(String, String)] = [
            ("0.2", "11"),
            ("0.2.3/other", "11"),
            ("0.2.3", "0"),
            ("0.2.3", "01"),
            ("0.2.3", "11?next=evil"),
            (" 0.2.3", "11"),
            ("0.2.3\n", "11"),
        ]

        for (version, build) in malformedValues {
            XCTAssertNil(
                KitLegalReleaseIdentity(versionName: version, buildNumber: build),
                "Expected malformed release \(version) (\(build)) to be rejected"
            )
        }
    }

    func testSourceRemainsUnavailableWithoutApprovedPublishedRelease() throws {
        let release = try XCTUnwrap(
            KitLegalReleaseIdentity(versionName: "0.2.3", buildNumber: "11")
        )
        let presentation = KitOpenSourceLicencePresentation.make(release: release)

        XCTAssertEqual(presentation.correspondingSource, .unavailable)
        XCTAssertNil(presentation.correspondingSource.url)
        XCTAssertTrue(presentation.licenceNotice.contains("LibSignalClient"))
        XCTAssertTrue(presentation.licenceNotice.contains("AGPL-3.0-only"))
        XCTAssertTrue(presentation.warrantyNotice.contains("WITHOUT ANY WARRANTY"))
        XCTAssertFalse(presentation.licenceNotice.contains("Kit Pay for iOS is free software"))
    }

    func testExactApprovedPublicSourceReleaseCanBePresented() throws {
        let release = try XCTUnwrap(
            KitLegalReleaseIdentity(versionName: "0.2.3", buildNumber: "11")
        )
        let url = try XCTUnwrap(
            URL(
                string: "https://github.com/kitafrica33/kit-pay-ios-source/"
                    + "releases/tag/v0.2.3-build11"
            )
        )

        XCTAssertTrue(
            KitLegalURLPolicy.isTrustedCorrespondingSourceURL(url, for: release)
        )
        let presentation = KitOpenSourceLicencePresentation.make(
            release: release,
            publishedSourceURL: url
        )
        XCTAssertEqual(presentation.correspondingSource, .published(url))
    }

    func testSourcePolicyRejectsPrivateWrongVersionAndAmbiguousDestinations() throws {
        let release = try XCTUnwrap(
            KitLegalReleaseIdentity(versionName: "0.2.3", buildNumber: "11")
        )
        let rejectedValues = [
            "http://github.com/kitafrica33/kit-pay-ios-source/releases/tag/v0.2.3-build11",
            "https://github.com.evil.test/kitafrica33/kit-pay-ios-source/releases/tag/v0.2.3-build11",
            "https://user@github.com/kitafrica33/kit-pay-ios-source/releases/tag/v0.2.3-build11",
            "https://github.com:443/kitafrica33/kit-pay-ios-source/releases/tag/v0.2.3-build11",
            "https://github.com/kitafrica33/kit-pay-ios/releases/tag/v0.2.3-build11",
            "https://github.com/kitafrica33/kit-pay-ios-source/releases/tag/v0.2.2-build11",
            "https://github.com/kitafrica33/kit-pay-ios-source/releases/tag/v0.2.3-build10",
            "https://github.com/kitafrica33/kit-pay-ios-source/releases/tag/v0.2.3-build11/",
            "https://github.com/kitafrica33/kit-pay-ios-source/releases/tag/v0.2.3-build11?next=evil",
            "https://github.com/kitafrica33/kit-pay-ios-source/releases/tag/v0.2.3-build11#files",
        ]

        for value in rejectedValues {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertFalse(
                KitLegalURLPolicy.isTrustedCorrespondingSourceURL(url, for: release),
                "Expected the source policy to reject \(value)"
            )
        }
    }

    func testRequiredLegalDocumentsAreBundledWithTheApplication() throws {
        let resources = KitLegalTextResources.bundled(in: .main)
        let notices = try XCTUnwrap(resources.thirdPartyNotices)
        let fullAGPL = try XCTUnwrap(resources.fullAGPL)

        XCTAssertTrue(notices.contains("LibSignalClient 0.97.4"))
        XCTAssertTrue(notices.contains("LiveKit Swift Client SDK 2.16.0"))
        XCTAssertTrue(notices.contains("Swift Protobuf 1.38.1"))
        XCTAssertTrue(fullAGPL.contains("GNU AFFERO GENERAL PUBLIC LICENSE"))
        XCTAssertTrue(fullAGPL.contains("Version 3, 19 November 2007"))
        XCTAssertTrue(fullAGPL.contains("WITHOUT ANY WARRANTY"))
    }
}
