from __future__ import annotations

import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[3]
KIT_PAY = ROOT / "KitPay"
THEME = KIT_PAY / "Design/KitTheme.swift"


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


def invocations(source: str, marker: str) -> list[str]:
    calls: list[str] = []
    search_from = 0
    while True:
        start = source.find(marker, search_from)
        if start < 0:
            return calls
        opening_parenthesis = start + len(marker) - 1
        depth = 0
        for index in range(opening_parenthesis, len(source)):
            character = source[index]
            if character == "(":
                depth += 1
            elif character == ")":
                depth -= 1
                if depth == 0:
                    calls.append(source[start : index + 1])
                    search_from = index + 1
                    break
        else:
            raise AssertionError(f"Unterminated invocation: {marker}")


class VerificationBadgePlacementSourceContractTests(unittest.TestCase):
    def test_remote_avatar_has_no_verification_api_or_overlay(self) -> None:
        body = declaration_body(THEME, "struct RemoteAvatarView")

        self.assertNotIn("verification", body)
        self.assertNotIn("VerifiedAccountBadge", body)
        self.assertEqual(
            body.count(".overlay"),
            1,
            "RemoteAvatarView may retain only its neutral hairline ring overlay",
        )
        self.assertIn('.accessibilityLabel("Profile photo for \\(name)")', body)

    def test_no_remote_avatar_call_can_supply_verification(self) -> None:
        calls: list[tuple[pathlib.Path, str]] = []
        for path in KIT_PAY.rglob("*.swift"):
            source = path.read_text(encoding="utf-8")
            calls.extend((path, call) for call in invocations(source, "RemoteAvatarView("))

        self.assertGreater(len(calls), 20)
        for path, call in calls:
            with self.subTest(path=path.relative_to(ROOT)):
                self.assertNotIn("verification:", call)

    def test_account_badge_can_only_be_constructed_by_name_label(self) -> None:
        sources = "\n".join(
            path.read_text(encoding="utf-8") for path in KIT_PAY.rglob("*.swift")
        )
        label = declaration_body(THEME, "struct VerifiedAccountNameLabel")
        badge = declaration_body(THEME, "private struct VerifiedAccountBadge")

        self.assertIn("private struct VerifiedAccountBadge", THEME.read_text(encoding="utf-8"))
        self.assertEqual(sources.count("VerifiedAccountBadge("), 1)
        self.assertEqual(label.count("VerifiedAccountBadge("), 1)
        self.assertIn(".accessibilityElement(children: .combine)", label)
        self.assertIn(".fixedSize()", badge)
        self.assertIn(".layoutPriority(1)", badge)
        body_start = label.index("var body: some View")
        self.assertLess(
            label.index("nameContent", body_start),
            label.index("VerifiedAccountBadge(", body_start),
        )

    def test_every_migrated_identity_surface_uses_name_adjacent_badges(self) -> None:
        minimum_labels_by_surface = {
            "KitPay/Features/Calls/ActiveCallView.swift": 6,
            "KitPay/Features/Calls/CallsView.swift": 2,
            "KitPay/Features/Home/WalletFlowViews.swift": 5,
            "KitPay/Features/Messages/ForwardMessagesView.swift": 1,
            "KitPay/Features/Messages/GroupCreateView.swift": 2,
            "KitPay/Features/Messages/GroupProfileView.swift": 2,
            "KitPay/Features/Messages/MessageInfoView.swift": 1,
            "KitPay/Features/Messages/MessagesView.swift": 7,
            "KitPay/Features/Messages/SharedContentDestinationView.swift": 1,
            "KitPay/Features/Profile/CommunicationPrivacyView.swift": 2,
            "KitPay/Features/Profile/ProfileView.swift": 1,
        }

        for relative_path, minimum_count in minimum_labels_by_surface.items():
            source = (ROOT / relative_path).read_text(encoding="utf-8")
            with self.subTest(surface=relative_path):
                self.assertGreaterEqual(
                    source.count("VerifiedAccountNameLabel("), minimum_count
                )

    def test_heuristic_beneficiary_matches_never_grant_public_badges(self) -> None:
        bank_row = declaration_body(
            ROOT / "KitPay/Features/Home/BankTransferView.swift",
            "private func beneficiaryRow",
        )
        mobile_avatar = declaration_body(
            ROOT / "KitPay/Features/Home/MobileMoneyView.swift",
            "private func savedAccountAvatar",
        )

        self.assertNotIn("VerifiedAccountNameLabel", bank_row)
        self.assertNotIn("verification:", bank_row)
        self.assertNotIn("VerifiedAccountNameLabel", mobile_avatar)
        self.assertNotIn("verification:", mobile_avatar)

    def test_group_call_titles_cannot_borrow_one_members_badge(self) -> None:
        resolver = declaration_body(
            ROOT / "KitPay/App/AppModel.swift",
            "private func callParticipantVerification",
        )

        self.assertIn("remoteUserIds.count == 1", resolver)

    def test_support_avatar_uses_non_tick_artwork_but_sender_name_keeps_seal(self) -> None:
        support = ROOT / "KitPay/Features/Support/SupportView.swift"
        avatar = declaration_body(support, "private struct SupportSenderAvatarView")
        bubble = declaration_body(support, "private struct SupportMessageBubble")

        self.assertIn('Image(systemName: "lifepreserver.fill")', avatar)
        self.assertNotIn('Image(systemName: "checkmark.seal.fill")', avatar)
        self.assertLess(
            bubble.index("Text(senderName)"),
            bubble.index('Image(systemName: "checkmark.seal.fill")'),
        )

    def test_first_sighting_verification_reaches_the_displayed_name(self) -> None:
        forward = (
            ROOT / "KitPay/Features/Messages/ForwardMessagesView.swift"
        ).read_text(encoding="utf-8")
        messages = (ROOT / "KitPay/Features/Messages/MessagesView.swift").read_text(
            encoding="utf-8"
        )

        self.assertIn("verification: presentation.verification", forward)
        self.assertIn("designation: recipientPresentation.verification", messages)
        self.assertIn(
            "designation: verification ?? contact?.verification?.designation", messages
        )


if __name__ == "__main__":
    unittest.main()
