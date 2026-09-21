"""Hold the share sheet independent of the app's lock state.

Owner device report, 1.0.17 build 105 (2026-09-21): on a *signed-in* handset every share
ended with

    Nothing was sent. Sharing is locked or your account changed.
    Unlock Kit Pay and share again. Tap Retry to check sharing access again.

That sentence was `MessagingProcessBroker.Failure.accountChanged`, and the conditions that
produced it included two that were nothing but the app's own screen lock: publication demanded
a `.biometryCurrentSet` Keychain credential, and the extension was refused unless it held a
process-local unlock lease it can never hold. Owner directive: biometric verification exists
for payments, not for chats.

These are source contracts over the production files plus one compiled run of the real
decision. Keychain ACLs, app groups and UIKit still need a device.
"""

from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]
BROKER = ROOT / "KitPay/Core/MessagingProcessBroker.swift"
POLICY = ROOT / "KitPay/Core/ShareAuthorizationPolicy.swift"
CONTROLLER = ROOT / "KitPayShare/ShareViewController.swift"
APP_MODEL = ROOT / "KitPay/App/AppModel.swift"

REPORTED = "Sharing is locked or your account changed. Unlock Kit Pay and share again."


def declaration(source: str, marker: str) -> str:
    start = source.index(marker)
    end = source.index("{", start) + 1
    depth = 1
    while depth:
        if source[end] == "{":
            depth += 1
        elif source[end] == "}":
            depth -= 1
        end += 1
    return source[start:end]


class ShareLockIndependenceTests(unittest.TestCase):
    def test_the_reported_sentence_is_gone_from_every_shipped_source(self):
        shipped = list((ROOT / "KitPay").rglob("*.swift")) + list((ROOT / "KitPayShare").rglob("*.swift"))
        self.assertTrue(shipped)
        offenders = []
        for path in shipped:
            code = "\n".join(
                line for line in path.read_text().splitlines() if not line.strip().startswith("//")
            )
            if REPORTED in code:
                offenders.append(str(path.relative_to(ROOT)))
        self.assertEqual(offenders, [], "build 105's refusal text is still shippable")

    def test_the_share_decision_reads_no_lock_biometric_or_foreground_signal(self):
        source = BROKER.read_text()
        forbidden = (
            "biometric", "Biometric", "authenticate", "Lease", "lease",
            "requiresBiometricUnlock", "KIT_SHARE_EXTENSION", "LAContext", "uptime",
        )
        for marker in ("func authorizeShare()", "func requireScopeLocked("):
            declared = declaration(source, marker)
            # Comments may explain what was removed; the code may not consult it.
            body = "\n".join(
                line for line in declared.splitlines() if not line.strip().startswith("//")
            )
            for term in forbidden:
                self.assertNotIn(term, body, f"{marker} consults {term} again")
            self.assertIn("ShareAuthorizationPolicy", body)

    def test_the_policy_input_cannot_express_a_lock(self):
        body = declaration(POLICY.read_text(), "struct Input:")
        for term in ("Lock", "lock", "biometr", "Biometr", "foreground", "Foreground",
                     "passcode", "Passcode", "unlock", "Unlock"):
            self.assertNotIn(term, body.replace("no separate unlock bit is consulted", ""),
                             f"the share decision gained a {term} input")

    def test_no_lock_state_path_can_write_a_denial_or_delete_the_directory(self):
        source = BROKER.read_text()
        # Each of these ran on an ordinary UI lock, a background restore, or an app-lock
        # settings change. Any one of them writing a denial re-creates the deadlock: the
        # denial also deletes destinations.secure, and only a publication can restore it.
        for marker in (
            "func suspendSharingForBiometricLock(",
            "func restoreBiometricSharingDestinations(",
            "func disableBiometricSharing(",
            "func approveBiometricSharing(",
            "func publishApprovedDestinations(",
        ):
            body = declaration(source, marker)
            self.assertNotIn("denySharingLocked()", body, f"{marker} still hard-denies sharing")
            self.assertNotIn("SharingDenial(", body, f"{marker} still writes a denial marker")

    def test_publication_and_enabling_require_no_biometric_credential(self):
        source = BROKER.read_text()
        self.assertNotIn("requireBiometricCredentialLocked", source)
        publish = declaration(source, "func publishApprovedDestinations(")
        self.assertIn("_ = requiresBiometricUnlock", publish)
        self.assertIn("authority.biometricCredential = nil", publish)
        enable = declaration(source, "func setSharingEnabled(")
        self.assertNotIn("Biometric", enable)

    def test_the_messaging_credential_stays_readable_after_first_unlock(self):
        source = BROKER.read_text()
        writer = declaration(source, "private func setSharedKeychainData(")
        self.assertIn("kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly", writer)
        self.assertNotIn("SecAccessControlCreateWithFlags", writer)
        self.assertNotIn("kSecAttrAccessControl", writer)
        reader = declaration(source, "private func sharedKeychainData(")
        for term in ("kSecUseAuthenticationContext", "kSecUseOperationPrompt", "LAContext"):
            self.assertNotIn(term, reader, "the extension's read would prompt for Face ID")
        query = declaration(source, "private func keychainQuery(")
        self.assertIn("kSecAttrAccessGroup", query, "the extension must read the shared group")

    def test_the_extension_never_tells_a_signed_in_customer_to_unlock(self):
        source = CONTROLLER.read_text()
        # Comments may quote the defect; the shipped strings may not repeat it.
        code = "\n".join(line for line in source.splitlines() if not line.strip().startswith("//"))
        for forbidden in ("Unlock Kit Pay", "Unlock sharing", "Authenticate to", "Face ID", "Touch ID"):
            self.assertNotIn(forbidden, code)
        failure = declaration(source, "private func presentInitialAuthorizationFailure(")
        self.assertIn("ShareAuthorizationPolicy.allowsRetry", failure)

    def test_a_failed_biometric_approval_no_longer_disables_sharing(self):
        body = declaration(APP_MODEL.read_text(), "private var sharedMessagingAccountEligible:")
        self.assertNotIn("biometricSharingApprovalBlockedEpoch", body)

    def test_the_extension_still_declares_the_shared_container_it_reads(self):
        for path in ("KitPayShare/Info.plist", "KitPayShare/KitPayShare.entitlements"):
            text = (ROOT / path).read_text()
            self.assertIn("africa.kit.pay.ios.messaging", text, path)
        self.assertIn("group.africa.kit.pay.ios",
                      (ROOT / "KitPayShare/KitPayShare.entitlements").read_text())

    def test_the_real_decision_allows_the_owners_container(self):
        swiftc = os.environ.get("SWIFTC") or shutil.which("swiftc")
        if not swiftc:
            self.skipTest("A Swift compiler is required to run the real share decision.")
        generated = POLICY.read_text() + DRIVER
        with tempfile.TemporaryDirectory(prefix="kit-share-lock-independence-") as directory:
            root = Path(directory)
            swift = root / "main.swift"
            swift.write_text(generated)
            binary = root / "share-decision"
            built = subprocess.run(
                [swiftc, "-swift-version", "5", "-parse-as-library", str(swift), "-o", str(binary)],
                capture_output=True, text=True, timeout=180,
            )
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("6 build-105 conditions resolved", result.stdout)


DRIVER = r'''
@main struct ShareDecisionRegression {
    static func require(_ value: Bool, _ message: String) { if !value { fatalError(message) } }

    /// The six conditions build 105 collapsed into one "Sharing is locked or your account
    /// changed" sentence. Two of them were the app's UI lock and must now be invisible here;
    /// the other four survive, each with its own answer.
    static func main() {
        typealias Policy = ShareAuthorizationPolicy
        let signedIn = Policy.Input(hasAuthority: true, hasSession: true,
                                    isHardDenied: false, hasMatchingDirectory: true)

        // 1 + 2: the app locked behind Face ID, and the app never foregrounded since boot.
        // Neither is expressible any more, so the same signed-in container shares.
        require(Policy.decide(signedIn) == nil, "a locked, backgrounded app still cannot share")

        // 3: no authority at all.
        require(Policy.decide(Policy.Input(hasAuthority: false, hasSession: false,
                                           isHardDenied: false, hasMatchingDirectory: false)) == .signedOut,
                "an empty container is not reported as signed out")
        // 4: an authority with no usable session.
        require(Policy.decide(Policy.Input(hasAuthority: true, hasSession: false,
                                           isHardDenied: false, hasMatchingDirectory: true)) == .signedOut,
                "a sessionless authority is not reported as signed out")
        // 5: a real revocation.
        require(Policy.decide(Policy.Input(hasAuthority: true, hasSession: true,
                                           isHardDenied: true, hasMatchingDirectory: true)) == .revoked,
                "a revocation no longer closes sharing")
        // 6: nothing published yet.
        require(Policy.decide(Policy.Input(hasAuthority: true, hasSession: true,
                                           isHardDenied: false, hasMatchingDirectory: false)) == .notPrepared,
                "an unpublished directory is not reported as unprepared")

        // The one surviving meaning of "account changed".
        require(Policy.decide(Policy.Input(hasAuthority: true, hasSession: true, isHardDenied: false,
                                           hasMatchingDirectory: true, capturedOwnerMatches: false))
                    == .sessionReplaced,
                "a replaced account is no longer detected")

        for refusal in Policy.Refusal.allCases {
            let message = Policy.message(for: refusal).lowercased()
            require(!message.contains("unlock"), "\(refusal) still asks for an unlock")
            require(!message.contains("is locked"), "\(refusal) still claims sharing is locked")
        }
        print("6 build-105 conditions resolved")
    }
}
'''


if __name__ == "__main__":
    unittest.main()
