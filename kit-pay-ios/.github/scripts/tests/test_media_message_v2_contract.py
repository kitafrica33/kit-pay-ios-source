"""Structural guards for the KITMEDIA2 media-message-v2 source (contract v0.4, 449925d9…).

Behaviour is pinned by `KitPayTests/MediaMessageV2ContractTests.swift` (which also runs on Linux
via `.github/scripts/tests/run_media_v2_linux_gate.sh`). This suite pins what a Swift test cannot:
that the deliberately duplicated pieces of `MediaMessageV2Models.swift` never drift from their
v1 originals in `MessagingAPIModels.swift`, that the v2 path stays off platform trims, that the
file stays Foundation-only (Linux-compilable), and that both new files remain registered in the
Xcode project.
"""

from __future__ import annotations

import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[3]
V2_MODELS = ROOT / "KitPay/Core/MediaMessageV2Models.swift"
V1_MODELS = ROOT / "KitPay/Core/MessagingAPIModels.swift"
MODELS = ROOT / "KitPay/Core/Models.swift"
V2_TESTS = ROOT / "KitPayTests/MediaMessageV2ContractTests.swift"
WIRE_GLUE_TESTS = ROOT / "KitPayTests/MediaMessageV2WireGlueTests.swift"
PBXPROJ = ROOT / "KitPay.xcodeproj/project.pbxproj"
LINUX_GATE = ROOT / ".github/scripts/tests/run_media_v2_linux_gate.sh"
LINUX_MAIN = ROOT / ".github/scripts/tests/media_v2_linux_gate/main.swift"


def function_body(source: str, signature_marker: str) -> list[str]:
    """Lines between a function's opening line and its matching close, indentation-stripped."""
    lines = source.splitlines()
    for index, line in enumerate(lines):
        if signature_marker in line:
            indent = len(line) - len(line.lstrip())
            closing = " " * indent + "}"
            for end in range(index + 1, len(lines)):
                if lines[end] == closing:
                    return [body.strip() for body in lines[index + 1 : end]]
            raise AssertionError(f"unterminated function for {signature_marker!r}")
    raise AssertionError(f"{signature_marker!r} not found")


def set_literal(source: str, declaration_marker: str) -> set[str]:
    """String elements of a `Set<String> = [ ... ]` literal starting at the marker line."""
    lines = source.splitlines()
    for index, line in enumerate(lines):
        if declaration_marker in line:
            elements: set[str] = set()
            for element_line in lines[index + 1 :]:
                stripped = element_line.strip()
                if stripped.startswith("]"):
                    return elements
                match = re.fullmatch(r'"([^"]+)",?', stripped)
                if match:
                    elements.add(match.group(1))
            raise AssertionError(f"unterminated set literal for {declaration_marker!r}")
    raise AssertionError(f"{declaration_marker!r} not found")


class MediaMessageV2SourceContract(unittest.TestCase):
    def setUp(self) -> None:
        self.v2 = V2_MODELS.read_text(encoding="utf-8")
        self.v1 = V1_MODELS.read_text(encoding="utf-8")
        self.models = MODELS.read_text(encoding="utf-8")

    def test_media_loader_cache_writes_are_owned_inserts(self) -> None:
        """The identity-addressed loader must park downloaded plaintext with the atomic
        non-overwriting insert and, on a failed post-write revalidation, remove the entry only
        when its own insert created it (`.stored`) — a plain `store` would clobber a concurrent
        owner's copy, and an unconditional remove would unwind an entry it never created.
        Behavior of the primitive itself is pinned by SecureMediaFileCacheTests."""
        app_model = (ROOT / "KitPay/App/AppModel.swift").read_text(encoding="utf-8")
        start = app_model.index("func loadSecureMediaItem(")
        end = app_model.index("func queueDirectMessage(", start)
        loader = app_model[start:end]
        self.assertEqual(loader.count("insertIfAbsent("), 2)
        self.assertEqual(loader.count("if insertion == .stored {"), 2)
        self.assertNotIn("SecureMediaFileCache.shared.store(", loader)

    def test_percent_encode_bodies_are_identical(self) -> None:
        """§4: v2 percent-encoding MUST byte-match v1's percentEncode; the body is duplicated
        so the v2 core stays Foundation-only, so drift here silently forks the wire format."""
        v2_body = function_body(self.v2, "func percentEncode(_ value: String) -> String {")
        v1_body = function_body(self.v1, "func percentEncode(_ value: String) -> String {")
        self.assertEqual(v2_body, v1_body)

    def test_allowed_media_types_match_wire_list(self) -> None:
        v2_types = set_literal(self.v2, "allowedAttachmentMediaTypes: Set<String> = [")
        v1_types = set_literal(self.v1, "allowedAttachmentMediaTypes: Set<String> = [")
        self.assertEqual(v2_types, v1_types)
        self.assertEqual(len(v2_types), 22)

    def test_v2_core_never_uses_platform_trim(self) -> None:
        """§4 cap rule: only the explicit six-codepoint helpers may trim on the v2 path.
        (Comments may — and do — mention the forbidden APIs to warn against them.)"""
        code_lines = [
            line for line in self.v2.splitlines() if not line.lstrip().startswith("//")
        ]
        for line in code_lines:
            self.assertNotIn("whitespacesAndNewlines", line, f"platform trim in code: {line!r}")
            self.assertNotIn(".trimmingCharacters", line, f"platform trim in code: {line!r}")
        for escape in ("0009", "000A", "000B", "000C", "000D", "0020"):
            self.assertIn(f'"\\u{{{escape}}}"', self.v2,
                          f"six-codepoint set must spell U+{escape} explicitly")

    def test_v2_core_is_foundation_only(self) -> None:
        """The Linux contract gate compiles this file with a stock toolchain; any UIKit/Crypto
        import would break it (and would be a sign policy code is growing UI tendrils)."""
        imports = re.findall(r"^import\s+(\S+)", self.v2, flags=re.MULTILINE)
        self.assertEqual(imports, ["Foundation"])

    def test_descriptor_confinement_constants_present(self) -> None:
        for constant in (
            'prefix = "KITMEDIA2:"',
            "maximumDescriptorUTF8Bytes = 7_680",
            "maximumCaptionUTF8Bytes = 2_048",
            "minimumAttachmentCount = 2",
            "maximumAttachmentCount = 8",
            "keyMaterialBytes = 64",
            'featureKey = "messaging_media_message_v2"',
            'profile = "kit-media-v2"',
        ) :
            self.assertIn(constant, self.v2)

    def test_project_registration(self) -> None:
        text = PBXPROJ.read_text(encoding="utf-8")
        self.assertIn("path = KitPay/Core/MediaMessageV2Models.swift", text)
        self.assertIn("path = KitPayTests/MediaMessageV2ContractTests.swift", text)
        self.assertIn("path = KitPayTests/MediaMessageV2WireGlueTests.swift", text)
        self.assertTrue(WIRE_GLUE_TESTS.is_file())
        # One PBXBuildFile + one Sources-phase mention; one PBXFileReference + one group child
        # + the PBXBuildFile back-reference.
        self.assertEqual(text.count("A41000000000000000000001"), 2)
        self.assertEqual(text.count("B41000000000000000000001"), 3)
        self.assertEqual(text.count("A42000000000000000000001"), 2)
        self.assertEqual(text.count("B42000000000000000000001"), 3)
        self.assertEqual(text.count("A42000000000000000000002"), 2)
        self.assertEqual(text.count("B42000000000000000000002"), 3)

    def test_content_binding_intercepts_the_v2_prefix(self) -> None:
        """The kind() dispatcher must strict-parse v2-prefixed bodies BEFORE the plain-text
        fallthrough, or `encrypted` smuggles a raw descriptor — every attachment key — into a
        rendered text bubble. Behaviour is pinned by MediaMessageV2WireGlueTests; this pins
        that the branch physically stays inside the shared dispatcher."""
        body = function_body(
            self.v1,
            "static func kind(",
        )
        joined = "\n".join(body)
        self.assertIn("KitMediaMessageV2Descriptor.prefix", joined)
        self.assertIn("KitMediaMessageV2Descriptor.parse(plaintext)", joined)
        # The v2 interception must come before the v1/plain-text tail.
        self.assertLess(
            joined.index("KitMediaMessageV2Descriptor.prefix"),
            joined.index("KitMediaMessageDescriptor.attachments(for: plaintext)"),
        )

    def test_send_request_enforces_canonical_multi_row_order(self) -> None:
        """§5: multi-row sends must hit the wire in ascending-id order with lowercase digests
        and at most 8 rows; the guard lives in SendEncryptedMessageRequest so no future call
        site can skip it."""
        body = "\n".join(function_body(self.v1, "struct SendEncryptedMessageRequest"))
        self.assertIn("KitMediaMessageV2Descriptor.isCanonicalOuterOrder(", body)
        self.assertIn("KitMediaMessageV2Descriptor.maximumAttachmentCount", body)
        self.assertIn("SecureMessagingWirePolicy.isLowercaseSHA256($0.ciphertextSha256)", body)

    def test_user_authored_text_guard_does_not_block_the_media_family(self) -> None:
        """Contract §4 rule 6 / starter milestone: a VALIDATED media message is first-class for
        downstream product logic, and the starter milestone gates on allowsUserAuthoredText —
        so that policy must never learn a KITMEDIA prefix. Family blocking of typed/pasted/
        edited input belongs at the composer call sites via KitMediaMessageFamilyPolicy."""
        body = "\n".join(function_body(self.v1, "static func allowsUserAuthoredText("))
        self.assertNotIn("KITMEDIA", body)
        self.assertIn(
            "static func blocksUserAuthoredText(_ text: String) -> Bool",
            self.v2,
        )

    def test_capabilities_decode_isolates_the_media_message_block(self) -> None:
        """§6: `protocols.messaging.media_message` must decode tolerantly (the `try?` realtime
        precedent) so a malformed advertisement disables only the multi-attachment path, while
        the legacy `rich_media` field keeps its strict decode; and the enablement accessor must
        AND the features key with the coherent block, so either leg failing keeps it off."""
        dto = "\n".join(function_body(self.models, "struct MessagingProtocolCapabilityDTO"))
        self.assertIn('case mediaMessage = "media_message"', dto)
        self.assertIn("mediaMessage = try? values.decodeIfPresent(", dto)
        self.assertIn("richMedia = try values.decodeIfPresent(", dto)
        accessor = "\n".join(
            function_body(self.models, "var enablesMessagingMediaMessageV2: Bool {")
        )
        self.assertIn(
            "supportsFeature(MessagingMediaMessageV2CapabilityPolicy.featureKey)", accessor
        )
        self.assertIn("supportsIOSV2 == true", accessor)

    def test_sender_admission_gate_is_atomic(self) -> None:
        """§6: sender admission is one question — server feature+profile, unanimous roster
        attestation, at least one recipient peer (never a vacuous allSatisfy), per-item §4
        envelope plus the per-item v1 rich-media/extended-size keys, and the aggregate ceiling —
        so no call site can pair a fresh answer for one leg with a stale answer for another."""
        body = "\n".join(function_body(self.v1, "static func admitsComposition("))
        self.assertIn("enablesMessagingMediaMessageV2 == true", body)
        self.assertIn("!recipientUserIDs.isEmpty", body)
        self.assertIn("MessagingRosterCapabilityPolicy.supports(", body)
        self.assertIn("MessagingRichMediaCapabilityPolicy.supportsAcrossRoster(", body)
        self.assertIn(
            "MessagingRichMediaCapabilityPolicy.supportsPlaintextByteSizeAcrossRoster(", body
        )
        self.assertIn("maximumAggregateCiphertextBytes", body)

    def test_linux_gate_compiles_production_sources(self) -> None:
        gate = LINUX_GATE.read_text(encoding="utf-8")
        for path in (
            "KitPay/Core/MediaMessageV2Models.swift",
            "KitPayTests/MediaMessageV2ContractTests.swift",
            ".github/scripts/tests/media_v2_linux_gate/main.swift",
        ):
            self.assertIn(path, gate)
        self.assertIn("MediaMessageV2ContractTests.allTests", LINUX_MAIN.read_text(encoding="utf-8"))
        self.assertIn("static var allTests", V2_TESTS.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
