"""Source contract: verify once per foreground session, and blur what is behind the gate.

Background: `docs/status/ios-chat-media-2026-09-21.md`.

Owner report against 1.0.17 build 105, item 4: biometric verification on the pay screen
and the home screen *"should verify once, and the background has to be blurred until
verified successfully"*.

Build 105 asked more than once and showed the wallet instead of blurring it:

1.  `homeDidResignActive` locked Home **unconditionally**, so opening Messages and coming
    straight back was a second Face ID prompt without the app ever leaving the foreground.
2.  The returning-sign-in proof only unlocked Home if Home happened to be the selected tab,
    so unlocking the app into any other tab bought nothing.
3.  `authorizePaymentRequestSubmission` prompted every single time, a third prompt.
4.  `HomeView` *replaced* its content with the gate, so the "background" the owner wanted
    blurred was not the wallet at all -- it was an opaque auth background.

The fix is one `ForegroundVerificationPolicy.Verification` per foreground session, shared
by app unlock, Home and the pay screen, voided only by a trip through the background, an
account-epoch change or a different user. The policy itself is pure Foundation and carries
an XCTest suite that runs on Linux through `run_foreground_verification_linux_gate.sh`;
what that suite *cannot* see is whether the app is wired to it, which is what this reads.

Note that none of this loosens the payment step-up: `authorizeFinancialStepUp`, the
server-verified signature behind an actual transfer, is deliberately left asking every
time. The owner's rule is that biometrics gate payments, not that they gate looking.
"""

from __future__ import annotations

import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[3]
POLICY = ROOT / "KitPay/Core/ForegroundVerificationPolicy.swift"
POLICY_TESTS = ROOT / "KitPayTests/ForegroundVerificationPolicyTests.swift"
APP_MODEL = ROOT / "KitPay/App/AppModel.swift"
HOME_VIEW = ROOT / "KitPay/Features/Home/HomeView.swift"
SECURITY_VIEW = ROOT / "KitPay/Features/Profile/SecurityView.swift"
LINUX_GATE = ROOT / ".github/scripts/tests/run_foreground_verification_linux_gate.sh"
PROJECT = ROOT / "KitPay.xcodeproj/project.pbxproj"


def declaration_body(source: str, declaration: str) -> str:
    """Return the brace-balanced body that follows `declaration` in `source`."""
    start = source.index(declaration)
    opening = source.index("{", start)
    depth = 0
    for index in range(opening, len(source)):
        character = source[index]
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return source[opening + 1 : index]
    raise AssertionError(f"unbalanced braces after {declaration!r}")


def squashed(text: str) -> str:
    """Collapse every run of whitespace so a contract survives Swift line wrapping."""
    return " ".join(text.split())


class ForegroundVerificationPolicyShipsTests(unittest.TestCase):
    """The policy is decidable off-device, and the app actually compiles it."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.policy = POLICY.read_text()
        cls.project = PROJECT.read_text()
        cls.gate = LINUX_GATE.read_text()

    def test_the_policy_is_foundation_only_so_it_runs_without_a_mac(self) -> None:
        for framework in ("SwiftUI", "UIKit", "LocalAuthentication", "Combine"):
            self.assertFalse(
                re.search(rf"^import {framework}$", self.policy, re.M),
                f"ForegroundVerificationPolicy imports {framework}; the rule that decides "
                f"whether a balance is legible must be testable on Linux, not only on a Mac",
            )

    def test_the_policy_and_its_tests_run_in_the_linux_gate(self) -> None:
        for path in ("KitPay/Core/ForegroundVerificationPolicy.swift",
                     "KitPayTests/ForegroundVerificationPolicyTests.swift"):
            self.assertIn(
                path,
                self.gate,
                f"{path} is not compiled by run_foreground_verification_linux_gate.sh",
            )

    def test_the_policy_and_its_tests_are_compiled_into_the_targets(self) -> None:
        # A Swift file that is not in project.pbxproj is a file Xcode never builds, which is
        # the quietest way for a fix to ship as a no-op.
        for path, phase in (
            ("KitPay/Core/ForegroundVerificationPolicy.swift", "app"),
            ("KitPayTests/ForegroundVerificationPolicyTests.swift", "tests"),
        ):
            self.assertIn(
                f"path = {path};",
                self.project,
                f"{path} has no PBXFileReference, so the {phase} target never sees it",
            )
            name = path.rsplit("/", 1)[1]
            self.assertIn(
                f"{name} in Sources */,",
                self.project,
                f"{path} is referenced but not in a Sources build phase",
            )

    def test_every_policy_test_is_in_the_allTests_table(self) -> None:
        # swift-corelibs-XCTest discovers nothing by reflection: a case missing from the
        # table simply never runs, on Linux, silently.
        source = POLICY_TESTS.read_text()
        declared = set(re.findall(r"^    func (test\w+)\(\)", source, re.M))
        listed = set(re.findall(r'\("(test\w+)",', source))
        self.assertEqual(
            declared,
            listed,
            "allTests and the declared cases disagree; the difference never runs on Linux",
        )
        self.assertGreaterEqual(len(declared), 10)


class OneVerificationPerForegroundSessionTests(unittest.TestCase):
    """Three prompts became one, and only the background ends it."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.app_model = APP_MODEL.read_text()

    def body(self, declaration: str) -> str:
        return squashed(declaration_body(self.app_model, declaration))

    def test_home_access_is_granted_by_a_foreground_proof(self) -> None:
        self.assertIn(
            "|| foregroundSessionVerified",
            self.body("var homeAccessGranted: Bool"),
            "Home ignores a verification the customer has already given this session",
        )

    def test_leaving_the_home_tab_no_longer_locks_a_verified_session(self) -> None:
        body = self.body("func homeDidResignActive()")
        self.assertIn(
            "guard !foregroundSessionVerified else { return }",
            body,
            "build 105's defect: Messages-and-back was a second Face ID prompt",
        )
        # The guard has to come before the lock, or it does nothing at all.
        self.assertLess(
            body.index("guard !foregroundSessionVerified"),
            body.index("homeBiometricState = .locked"),
            "the session guard must precede the lock it is meant to prevent",
        )

    def test_opening_home_does_not_re_prompt_a_verified_session(self) -> None:
        body = self.body("func homeDidBecomeActive() async")
        self.assertIn("guard !foregroundSessionVerified else {", body)
        self.assertLess(
            body.index("foregroundSessionVerified"),
            body.index("authenticateBiometrically(for: .home)"),
            "the proof must be consulted before the prompt, not after it",
        )

    def test_the_pay_screen_accepts_the_session_proof(self) -> None:
        body = self.body("func authorizePaymentRequestSubmission() async -> Bool")
        self.assertIn(
            "guard !foregroundSessionVerified else { return true }",
            body,
            "the pay screen was the third prompt of a single foreground session",
        )

    def test_a_successful_biometric_check_records_the_proof(self) -> None:
        # Without this the session is never verified and every screen prompts as before.
        self.assertIn(
            "recordForegroundVerification()",
            self.body("func authenticateBiometrically("),
            "nothing records the proof, so nothing can honour it",
        )

    def test_the_background_is_the_only_thing_that_ends_a_session(self) -> None:
        call_sites = [
            line
            for line in self.app_model.splitlines()
            if "endForegroundVerification()" in line and "private func" not in line
        ]
        self.assertEqual(
            len(call_sites),
            1,
            "a verification must expire on a real background transition and nowhere else; "
            f"found {len(call_sites)} call sites",
        )
        self.assertIn(
            "endForegroundVerification()",
            self.body("func applicationDidEnterBackgroundSecurely()"),
            "the one expiry must be the background transition",
        )

    def test_the_epoch_only_moves_forward(self) -> None:
        body = self.body("private func endForegroundVerification()")
        self.assertIn("foregroundEpoch &+= 1", body)
        self.assertIn("foregroundVerification = nil", body)
        # assertTrue, not assertNotIn: a failure must not echo an 11k-line file.
        self.assertFalse(
            "foregroundEpoch = 0" in self.app_model.replace(
                "var foregroundEpoch: UInt64 = 0", ""
            ),
            "something resets foregroundEpoch; a stale proof from session 0 would look "
            "current again",
        )

    def test_a_proof_cannot_be_forged_from_outside_the_model(self) -> None:
        for declaration in ("var foregroundEpoch: UInt64",
                            "var foregroundVerification: ForegroundVerificationPolicy"):
            self.assertTrue(
                re.search(
                    rf"@Published private\(set\) {re.escape(declaration)}", self.app_model
                ),
                f"{declaration} must be @Published private(set); a view that can write it "
                f"can unlock the wallet without a face",
            )

    def test_signing_out_drops_the_proof(self) -> None:
        # Two teardown sites plus the expiry helper. Each must clear the verification, or the
        # next account inherits the last one's unlocked session.
        self.assertGreaterEqual(
            self.app_model.count("foregroundVerification = nil"),
            3,
            "an account teardown that leaves the proof behind hands it to the next user",
        )

    def test_the_payment_step_up_still_asks_every_time(self) -> None:
        body = self.body("func authorizeFinancialStepUp(")
        self.assertNotIn(
            "foregroundSessionVerified",
            body,
            "the owner's rule is that biometrics gate payments; the server-verified step-up "
            "behind an actual transfer must never be waived by a look-at-the-wallet proof",
        )


class LockedHomeIsBlurredTests(unittest.TestCase):
    """The wallet is what gets blurred -- not replaced by a different screen."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.home = HOME_VIEW.read_text()
        cls.body = squashed(declaration_body(cls.home, "var body: some View"))
        cls.gate_view = declaration_body(
            SECURITY_VIEW.read_text(), "struct KitBiometricGateView: View"
        )

    def test_home_blurs_its_content_instead_of_swapping_it(self) -> None:
        self.assertIn(
            "homeContent .blur(radius: ForegroundVerificationPolicy.blurRadius(",
            self.body,
            "the owner asked for the background to be blurred; build 105 replaced it",
        )
        self.assertNotRegex(
            self.body,
            r"if .*isUnlocked \{ homeContent",
            "a conditional swap is the defect: there is no blurred background to see",
        )

    def test_the_blur_is_the_policys_and_not_a_number_typed_into_a_view(self) -> None:
        # A radius chosen in the view is a radius no test can hold to account.
        numeric = re.findall(r"\.blur\(radius:\s*([0-9.]+)", self.body)
        self.assertEqual(
            numeric, [], f"HomeView hard-codes a blur radius {numeric}; use the policy"
        )

    def test_locked_content_is_redacted_inert_and_silent(self) -> None:
        for expectation, why in (
            (
                "redacted( reason: ForegroundVerificationPolicy.contentIsRedacted(",
                "a blur alone still shows the shape of a balance",
            ),
            (
                "allowsHitTesting( ForegroundVerificationPolicy.contentIsInteractive(",
                "a blurred wallet that still takes taps is not locked",
            ),
            (
                "accessibilityHidden(!isUnlocked)",
                "VoiceOver would happily read the balance straight through the blur",
            ),
        ):
            self.assertIn(expectation, self.body, why)

    def test_the_reveal_is_animated_and_the_lock_is_not(self) -> None:
        self.assertIn(
            "ForegroundVerificationPolicy.animationDuration( wasVerified: false,",
            self.body,
            "the duration must come from the policy, which returns 0 for locking so that "
            "no intermediate frame of a legible balance is ever rendered",
        )

    def test_the_gate_sits_over_the_blur_rather_than_hiding_it(self) -> None:
        self.assertIn(
            "backdrop: .blurredContent",
            self.body,
            "the default opaque auth background would conceal the very blur the owner asked "
            "for -- Home must pass the material backdrop",
        )
        self.assertIn(
            ".fill(.ultraThinMaterial)",
            squashed(self.gate_view),
            "the blurredContent backdrop must be a material overlay, not a tinted rectangle",
        )

    def test_a_cancelled_check_leaves_a_retry_button_and_the_reason(self) -> None:
        # Cancelling Face ID must not strand the customer on a blurred screen with no way back.
        self.assertIn('buttonTitle: "Open Home"', self.body)
        self.assertIn("errorMessage: model.biometricErrorMessage", self.body)
        self.assertIn(
            "authenticate: { await model.homeDidBecomeActive() }",
            self.body,
            "the retry button must run the same check that just failed",
        )


if __name__ == "__main__":
    unittest.main()
