import XCTest

#if canImport(UIKit)
    @testable import KitPay
#endif

/// One verification per foreground session, and no frame of a legible balance before the gate.
///
/// Owner report, 1.0.17 build 105: biometric verification on the pay screen and the home screen
/// *"should verify once, and the background has to be blurred until verified successfully"*.
/// These cases pin both halves — what a proof covers and, just as importantly, what voids it —
/// because "verify once" is only safe if a proof can never outlive its foreground session, its
/// account epoch or its user.
///
/// Runs on Linux through `.github/scripts/tests/run_foreground_verification_linux_gate.sh`.
final class ForegroundVerificationPolicyTests: XCTestCase {
    private static let account = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private static let otherAccount = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
    private static let user = "3f0a5d2e-1111-4c33-9a77-0123456789ab"

    private func proof(
        foregroundEpoch: UInt64 = 4,
        accountEpoch: UUID = account,
        userID: String = user
    ) -> ForegroundVerificationPolicy.Verification {
        ForegroundVerificationPolicy.Verification(
            foregroundEpoch: foregroundEpoch,
            accountEpoch: accountEpoch,
            userID: userID
        )
    }

    private func isVerified(
        _ verification: ForegroundVerificationPolicy.Verification?,
        foregroundEpoch: UInt64 = 4,
        accountEpoch: UUID = account,
        userID: String? = user
    ) -> Bool {
        ForegroundVerificationPolicy.isVerified(
            verification,
            foregroundEpoch: foregroundEpoch,
            accountEpoch: accountEpoch,
            userID: userID
        )
    }

    // MARK: What a proof covers

    func testAProofCoversTheRestOfItsForegroundSession() {
        XCTAssertTrue(isVerified(proof()))
    }

    func testTheSameProofServesHomeAndThePayScreen() {
        // The policy is intentionally purpose-blind: the face that unlocked the app is the face
        // Home and the pay screen were both about to ask for.
        let verification = proof()
        XCTAssertTrue(isVerified(verification))
        XCTAssertFalse(
            ForegroundVerificationPolicy.requiresPrompt(
                unlockEnabled: true,
                verification: verification,
                foregroundEpoch: 4,
                accountEpoch: Self.account,
                userID: Self.user
            ),
            "a second prompt on the next screen is the defect the owner reported"
        )
    }

    func testTheUserIdComparisonIsCaseInsensitiveBecauseUUIDCasingIsNotIdentity() {
        XCTAssertTrue(isVerified(proof(userID: Self.user.uppercased())))
    }

    // MARK: What voids it

    func testATripThroughTheBackgroundVoidsTheProof() {
        XCTAssertFalse(
            isVerified(proof(foregroundEpoch: 4), foregroundEpoch: 5),
            "the background is the one thing that ends a foreground session's proof"
        )
    }

    func testAProofFromALaterSessionCannotAuthoriseAnEarlierOne() {
        // The epoch only moves forward, but a suspended LocalAuthentication response resolving
        // out of order must not be able to look current either way round.
        XCTAssertFalse(isVerified(proof(foregroundEpoch: 9), foregroundEpoch: 4))
    }

    func testANewAccountEpochVoidsTheProof() {
        XCTAssertFalse(
            isVerified(proof(accountEpoch: Self.otherAccount)),
            "a sign-out, a sign-in or a session change must not inherit a proof"
        )
    }

    func testAnotherUserCannotUseThisProof() {
        XCTAssertFalse(isVerified(proof(userID: UUID().uuidString)))
    }

    func testThereIsNoProofWithoutAUser() {
        XCTAssertFalse(isVerified(proof(), userID: nil))
        XCTAssertFalse(isVerified(proof(), userID: ""))
        XCTAssertFalse(isVerified(nil))
    }

    // MARK: Prompting

    func testNothingIsPromptedWhenAppUnlockIsSwitchedOff() {
        XCTAssertFalse(
            ForegroundVerificationPolicy.requiresPrompt(
                unlockEnabled: false,
                verification: nil,
                foregroundEpoch: 4,
                accountEpoch: Self.account,
                userID: Self.user
            ),
            "with no app lock configured there is nothing to prompt for"
        )
    }

    func testAFirstVisitOfAForegroundSessionPrompts() {
        XCTAssertTrue(
            ForegroundVerificationPolicy.requiresPrompt(
                unlockEnabled: true,
                verification: nil,
                foregroundEpoch: 4,
                accountEpoch: Self.account,
                userID: Self.user
            )
        )
        XCTAssertTrue(
            ForegroundVerificationPolicy.requiresPrompt(
                unlockEnabled: true,
                verification: proof(foregroundEpoch: 3),
                foregroundEpoch: 4,
                accountEpoch: Self.account,
                userID: Self.user
            ),
            "coming back from the background must ask again"
        )
    }

    // MARK: The blur

    func testUnverifiedContentIsBlurredRedactedAndInert() {
        XCTAssertEqual(ForegroundVerificationPolicy.blurRadius(isVerified: false),
                       ForegroundVerificationPolicy.blurRadius)
        XCTAssertGreaterThanOrEqual(
            ForegroundVerificationPolicy.blurRadius,
            20,
            "a balance must not be legible through it at arm's length"
        )
        XCTAssertTrue(ForegroundVerificationPolicy.contentIsRedacted(isVerified: false))
        XCTAssertFalse(
            ForegroundVerificationPolicy.contentIsInteractive(isVerified: false),
            "a blurred balance the customer can still tap through to is not a gate"
        )
    }

    func testVerifiedContentIsSharpAndLive() {
        XCTAssertEqual(ForegroundVerificationPolicy.blurRadius(isVerified: true), 0)
        XCTAssertFalse(ForegroundVerificationPolicy.contentIsRedacted(isVerified: true))
        XCTAssertTrue(ForegroundVerificationPolicy.contentIsInteractive(isVerified: true))
    }

    func testLockingIsInstantaneousSoThereIsNoFlashOfAClearBalance() {
        XCTAssertEqual(
            ForegroundVerificationPolicy.animationDuration(wasVerified: true, isVerified: false),
            0,
            "animating the lock renders intermediate frames of a legible balance"
        )
        XCTAssertEqual(
            ForegroundVerificationPolicy.animationDuration(wasVerified: false, isVerified: false),
            0
        )
        XCTAssertEqual(
            ForegroundVerificationPolicy.animationDuration(wasVerified: true, isVerified: true),
            0,
            "an unchanged state must not re-run the reveal on every render"
        )
    }

    func testOnlyTheRevealIsAnimated() {
        XCTAssertGreaterThan(
            ForegroundVerificationPolicy.animationDuration(wasVerified: false, isVerified: true),
            0
        )
        XCTAssertLessThanOrEqual(
            ForegroundVerificationPolicy.animationDuration(wasVerified: false, isVerified: true),
            0.4,
            "the customer has already proved who they are; do not make them wait to see it"
        )
    }

    static var allTests = [
        ("testAProofCoversTheRestOfItsForegroundSession",
         testAProofCoversTheRestOfItsForegroundSession),
        ("testTheSameProofServesHomeAndThePayScreen", testTheSameProofServesHomeAndThePayScreen),
        ("testTheUserIdComparisonIsCaseInsensitiveBecauseUUIDCasingIsNotIdentity",
         testTheUserIdComparisonIsCaseInsensitiveBecauseUUIDCasingIsNotIdentity),
        ("testATripThroughTheBackgroundVoidsTheProof", testATripThroughTheBackgroundVoidsTheProof),
        ("testAProofFromALaterSessionCannotAuthoriseAnEarlierOne",
         testAProofFromALaterSessionCannotAuthoriseAnEarlierOne),
        ("testANewAccountEpochVoidsTheProof", testANewAccountEpochVoidsTheProof),
        ("testAnotherUserCannotUseThisProof", testAnotherUserCannotUseThisProof),
        ("testThereIsNoProofWithoutAUser", testThereIsNoProofWithoutAUser),
        ("testNothingIsPromptedWhenAppUnlockIsSwitchedOff",
         testNothingIsPromptedWhenAppUnlockIsSwitchedOff),
        ("testAFirstVisitOfAForegroundSessionPrompts", testAFirstVisitOfAForegroundSessionPrompts),
        ("testUnverifiedContentIsBlurredRedactedAndInert",
         testUnverifiedContentIsBlurredRedactedAndInert),
        ("testVerifiedContentIsSharpAndLive", testVerifiedContentIsSharpAndLive),
        ("testLockingIsInstantaneousSoThereIsNoFlashOfAClearBalance",
         testLockingIsInstantaneousSoThereIsNoFlashOfAClearBalance),
        ("testOnlyTheRevealIsAnimated", testOnlyTheRevealIsAnimated),
    ]
}
