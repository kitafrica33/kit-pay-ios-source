import XCTest

#if canImport(UIKit)
    @testable import KitPay
#endif

/// The regression for the owner's 2026-09-21 device report on 1.0.17 (105).
///
/// On a *signed-in* handset every share ended in one sentence:
///
///     Nothing was sent. Sharing is locked or your account changed.
///     Unlock Kit Pay and share again. Tap Retry to check sharing access again.
///
/// The share extension believed the messaging session sat behind the app's lock state. It does
/// not any more: biometrics are a payment control. These tests pin the decision down to inputs
/// an extension can actually observe, and pin the copy down to sentences that are true.
final class ShareAuthorizationPolicyTests: XCTestCase {

    /// A signed-in account whose recipients the app has published: the owner's phone.
    private func signedIn(
        isHardDenied: Bool = false,
        hasMatchingDirectory: Bool = true,
        capturedOwnerMatches: Bool = true
    ) -> ShareAuthorizationPolicy.Input {
        ShareAuthorizationPolicy.Input(
            hasAuthority: true,
            hasSession: true,
            isHardDenied: isHardDenied,
            hasMatchingDirectory: hasMatchingDirectory,
            capturedOwnerMatches: capturedOwnerMatches
        )
    }

    // MARK: The reported defect

    /// Build 105's exact situation: signed in, recipients published, Kit Pay locked behind
    /// Face ID and not in the foreground. It refused. It must now allow.
    func testSignedInLockedBackgroundedAppMayShare() {
        XCTAssertNil(ShareAuthorizationPolicy.decide(signedIn()))
    }

    /// There is no input that can express "the app is locked", so no caller can accidentally
    /// re-introduce the gate. `Mirror` is used deliberately: it fails if a stored property is
    /// added, not merely if one is read.
    func testInputCarriesNoLockBiometricOrForegroundSignal() {
        let labels = Mirror(reflecting: signedIn()).children.compactMap(\.label).sorted()
        XCTAssertEqual(
            labels,
            ["capturedOwnerMatches", "hasAuthority", "hasMatchingDirectory", "hasSession", "isHardDenied"]
        )
        let forbidden = ["lock", "biometr", "faceid", "touchid", "unlock", "foreground", "passcode", "authenticat"]
        for label in labels {
            let lowered = label.lowercased()
            for term in forbidden {
                XCTAssertFalse(lowered.contains(term), "\(label) re-introduces a \(term) gate")
            }
        }
    }

    /// No refusal may tell a signed-in customer to unlock anything, and the one sentence the
    /// owner was shown may never be produced again by any refusal.
    func testNoRefusalAsksTheCustomerToUnlockKitPay() {
        let reported = "Sharing is locked or your account changed. Unlock Kit Pay and share again."
        for refusal in ShareAuthorizationPolicy.Refusal.allCases {
            let message = ShareAuthorizationPolicy.message(for: refusal)
            XCTAssertNotEqual(message, reported)
            let lowered = message.lowercased()
            XCTAssertFalse(lowered.contains("unlock"), "\(refusal) still says unlock: \(message)")
            XCTAssertFalse(lowered.contains("is locked"), "\(refusal) still says locked: \(message)")
            XCTAssertFalse(lowered.contains("face id"), "\(refusal) still mentions Face ID: \(message)")
            XCTAssertFalse(lowered.contains("authenticate"), "\(refusal) still asks to authenticate: \(message)")
            XCTAssertFalse(message.isEmpty)
            XCTAssertTrue(message.hasSuffix("."), "\(refusal) is not a sentence: \(message)")
        }
    }

    /// Build 105 collapsed six conditions into one sentence, so the report could not name the
    /// one that tripped. Every refusal now has its own.
    func testEveryRefusalHasItsOwnSentence() {
        let messages = ShareAuthorizationPolicy.Refusal.allCases.map(ShareAuthorizationPolicy.message(for:))
        XCTAssertEqual(Set(messages).count, ShareAuthorizationPolicy.Refusal.allCases.count)
    }

    // MARK: The surviving refusals

    func testSignedOutIsTheOnlyMissingAuthorityAnswer() {
        XCTAssertEqual(
            ShareAuthorizationPolicy.decide(
                ShareAuthorizationPolicy.Input(
                    hasAuthority: false, hasSession: false,
                    isHardDenied: false, hasMatchingDirectory: false
                )
            ),
            .signedOut
        )
        XCTAssertEqual(
            ShareAuthorizationPolicy.decide(
                ShareAuthorizationPolicy.Input(
                    hasAuthority: true, hasSession: false,
                    isHardDenied: false, hasMatchingDirectory: true
                )
            ),
            .signedOut
        )
    }

    /// A real revocation — sign-out, privacy withdrawal, account deletion — still closes
    /// sharing, and it outranks a directory that has not been cleaned up yet.
    func testHardDenialStillRevokesSharing() {
        XCTAssertEqual(ShareAuthorizationPolicy.decide(signedIn(isHardDenied: true)), .revoked)
        XCTAssertEqual(
            ShareAuthorizationPolicy.decide(signedIn(isHardDenied: true, hasMatchingDirectory: false)),
            .revoked
        )
    }

    /// Nothing published yet is a different, recoverable state: opening the app fixes it.
    func testMissingDirectoryIsNotPreparedRatherThanAccountChanged() {
        XCTAssertEqual(ShareAuthorizationPolicy.decide(signedIn(hasMatchingDirectory: false)), .notPrepared)
    }

    /// "Account changed" now means exactly one thing: the account really changed under a sheet
    /// that had already captured the previous one.
    func testAccountChangedSurvivesOnlyForARealOwnerChange() {
        XCTAssertEqual(ShareAuthorizationPolicy.decide(signedIn(capturedOwnerMatches: false)), .sessionReplaced)
        XCTAssertTrue(ShareAuthorizationPolicy.message(for: .sessionReplaced).contains("different Kit Pay account"))
    }

    // MARK: Retry

    /// Retry re-reads the container, so it is worth offering for anything a customer fixes by
    /// opening Kit Pay — and is pointless, and was actively misleading in build 105, for a
    /// sheet whose account has been replaced.
    func testRetryIsOfferedOnlyWhereItCanChangeTheAnswer() {
        XCTAssertTrue(ShareAuthorizationPolicy.allowsRetry(.signedOut))
        XCTAssertTrue(ShareAuthorizationPolicy.allowsRetry(.revoked))
        XCTAssertTrue(ShareAuthorizationPolicy.allowsRetry(.notPrepared))
        XCTAssertFalse(ShareAuthorizationPolicy.allowsRetry(.sessionReplaced))
    }

    /// The decision is a pure function of its input: the same container answers the same way
    /// however many times an extension is respawned, and whatever the app is doing.
    func testDecisionIsTotalAndStableAcrossEveryInputCombination() {
        var seen: [ShareAuthorizationPolicy.Input: ShareAuthorizationPolicy.Refusal?] = [:]
        for flags in 0..<32 {
            let input = ShareAuthorizationPolicy.Input(
                hasAuthority: flags & 1 != 0,
                hasSession: flags & 2 != 0,
                isHardDenied: flags & 4 != 0,
                hasMatchingDirectory: flags & 8 != 0,
                capturedOwnerMatches: flags & 16 != 0
            )
            let first = ShareAuthorizationPolicy.decide(input)
            XCTAssertEqual(first, ShareAuthorizationPolicy.decide(input))
            seen[input] = first
        }
        XCTAssertEqual(seen.count, 32)
        XCTAssertEqual(seen.values.filter { $0 == nil }.count, 1,
                       "exactly one container state shares: signed in, undenied, prepared, same owner")
    }

    static var allTests = [
        ("testSignedInLockedBackgroundedAppMayShare", testSignedInLockedBackgroundedAppMayShare),
        ("testInputCarriesNoLockBiometricOrForegroundSignal", testInputCarriesNoLockBiometricOrForegroundSignal),
        ("testNoRefusalAsksTheCustomerToUnlockKitPay", testNoRefusalAsksTheCustomerToUnlockKitPay),
        ("testEveryRefusalHasItsOwnSentence", testEveryRefusalHasItsOwnSentence),
        ("testSignedOutIsTheOnlyMissingAuthorityAnswer", testSignedOutIsTheOnlyMissingAuthorityAnswer),
        ("testHardDenialStillRevokesSharing", testHardDenialStillRevokesSharing),
        ("testMissingDirectoryIsNotPreparedRatherThanAccountChanged", testMissingDirectoryIsNotPreparedRatherThanAccountChanged),
        ("testAccountChangedSurvivesOnlyForARealOwnerChange", testAccountChangedSurvivesOnlyForARealOwnerChange),
        ("testRetryIsOfferedOnlyWhereItCanChangeTheAnswer", testRetryIsOfferedOnlyWhereItCanChangeTheAnswer),
        ("testDecisionIsTotalAndStableAcrossEveryInputCombination", testDecisionIsTotalAndStableAcrossEveryInputCombination),
    ]
}
