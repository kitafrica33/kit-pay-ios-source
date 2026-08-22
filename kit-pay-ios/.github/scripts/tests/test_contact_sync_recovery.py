from __future__ import annotations

import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[3]


def declaration_body(path: pathlib.Path, declaration: str) -> str:
    source = path.read_text(encoding="utf-8")
    start = source.index(declaration)
    opening_brace = source.index("{", start)
    depth = 0
    for index in range(opening_brace, len(source)):
        character = source[index]
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return source[start : index + 1]
    raise AssertionError(f"Unterminated declaration: {declaration}")


class ContactSyncRecoverySourceContractTests(unittest.TestCase):
    def test_every_contact_backed_recipient_picker_embeds_recovery(self) -> None:
        surfaces = {
            "KitPay/Features/Messages/MessagesView.swift": [
                "private struct NewMessageSheet",
            ],
            "KitPay/Features/Calls/CallsView.swift": [
                "private struct NewCallSheet",
            ],
            "KitPay/Features/Home/WalletFlowViews.swift": [
                "struct SendMoneyView",
                "struct RequestMoneyView",
            ],
            "KitPay/Features/Calls/ActiveCallView.swift": [
                "private struct ActiveCallParticipantSheet",
            ],
            "KitPay/Features/Profile/CommunicationPrivacyView.swift": [
                "private struct CommunicationBlockPickerView",
            ],
        }

        for relative_path, declarations in surfaces.items():
            path = ROOT / relative_path
            for declaration in declarations:
                with self.subTest(surface=declaration):
                    body = declaration_body(path, declaration)
                    self.assertIn("ContactSyncRecoveryView(", body)

    def test_recovery_view_is_actionable_accessible_and_failure_only(self) -> None:
        path = ROOT / "KitPay/Features/Home/ContactSyncButton.swift"
        body = declaration_body(path, "struct ContactSyncRecoveryView")

        self.assertIn("UIApplication.openSettingsURLString", body)
        self.assertIn("model.retryAutomaticContactSync()", body)
        self.assertIn('.accessibilityLabel("Open Contacts settings")', body)
        self.assertIn('.accessibilityLabel("Retry contact sync")', body)
        self.assertIn(".accessibilityIdentifier(recovery?.accessibilityIdentifier", body)
        self.assertNotIn("case .requestingPermission", body)
        self.assertNotIn("case .syncing", body)
        self.assertNotIn("case .synced", body)
        self.assertNotIn("ProgressView", body)

    def test_recovery_accessibility_identifiers_are_stable(self) -> None:
        policy = (ROOT / "KitPay/Core/ContactSynchronizer.swift").read_text(
            encoding="utf-8"
        )
        self.assertIn('"contact-sync-recovery.open-settings"', policy)
        self.assertIn('"contact-sync-recovery.retry"', policy)


if __name__ == "__main__":
    unittest.main()
