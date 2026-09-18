"""Source contract guarding the chat-open crash fixed for build 101.

TestFlight 1.0.17 (100) died with EXC_BAD_ACCESS (SIGSEGV), "Thread stack size exceeded
due to excessive recursion", the moment a customer opened a chat. The crashing frames were
`swift_getTypeByMangledName` under `ConversationView.conversationLayout.getter`: the screen's
static SwiftUI type had grown a mangled name too deeply nested for the runtime demangler to
decode inside the 1 MB main-thread stack.

Two shapes produced that depth, and both are cheap to reintroduce by hand, so they are pinned
here rather than left to review. There is no Swift toolchain on the CI's Linux stage and the
native suite cannot construct a `ConversationView`, so this reads the source the way the other
placement contracts in this directory do.
"""

from __future__ import annotations

import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[3]
MESSAGES_VIEW = ROOT / "KitPay/Features/Messages/MessagesView.swift"

# Every composed stage of ConversationView, in the order the screen builds them. Each one wraps
# the previous stage in more modifiers, so an unbroken chain nests one enormous generic type.
STAGE_SEAMS = (
    "AnyView(conversationLayout)",
    "AnyView(conversationWithSharedReview)",
    "AnyView(conversationMediaPickers)",
    "AnyView(conversationSheets)",
    "AnyView(conversationDeleteConfirmation)",
    "AnyView(conversationTasks)",
    "AnyView(conversationLifecycle)",
)

ERASED_ROW_BUILDERS = ("timelineRow", "messageRow", "conversationFooter")


def declaration_body(source: str, declaration: str) -> str:
    """Return `declaration` plus its brace-balanced body."""
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


class ConversationViewTypeDepthTests(unittest.TestCase):
    def setUp(self) -> None:
        self.source = MESSAGES_VIEW.read_text(encoding="utf-8")

    def test_every_stage_seam_is_type_erased(self) -> None:
        for seam in STAGE_SEAMS:
            # assertIn would echo the whole 11k-line file into the failure report.
            self.assertTrue(
                seam in self.source,
                f"ConversationView must keep {seam}: an unerased stage chain re-nests the "
                "screen's type and reopens the chat-open stack overflow",
            )

    def test_timeline_row_builders_return_anyview(self) -> None:
        for builder in ERASED_ROW_BUILDERS:
            pattern = rf"(func|var) {builder}\b[^{{]*-> AnyView|var {builder}: AnyView"
            # assertRegex would echo the whole 11k-line file into the failure report.
            self.assertTrue(
                re.search(pattern, self.source),
                f"{builder} must return AnyView, not an opaque SwiftUI type",
            )

    def test_timeline_row_uses_no_viewbuilder_branches(self) -> None:
        """Explicit `return AnyView(...)` keeps `_ConditionalContent` out of a row entirely."""
        for builder in ERASED_ROW_BUILDERS:
            declaration = next(
                candidate
                for candidate in (f"private func {builder}(", f"private var {builder}: AnyView")
                if candidate in self.source
            )
            body = declaration_body(self.source, declaration)
            self.assertNotIn(
                "@ViewBuilder",
                body,
                f"{builder} must not be a @ViewBuilder: that restores the nested branches",
            )
            branches = len(re.findall(r"\bcase\b|\bif\b|\bguard\b", body))
            returns = len(re.findall(r"return (AnyView|messageRow)\(", body))
            self.assertGreaterEqual(
                returns,
                branches // 2,
                f"{builder} must return an erased view from every branch",
            )

    def test_timeline_foreach_delegates_instead_of_switching_inline(self) -> None:
        layout = declaration_body(self.source, "private var conversationLayout: some View")
        foreach = declaration_body(layout, "ForEach(renderedTimeline)")
        self.assertIn("timelineRow(", foreach)
        self.assertNotIn(
            "switch item",
            foreach,
            "Inlining the timeline switch back into the ForEach nests ~16 generic levels of "
            "_ConditionalContent inside the screen's type and crashes chat open",
        )

    def test_conversation_layout_keeps_its_branching_shallow(self) -> None:
        """A cheap ceiling on how much ViewBuilder branching one screen type may carry."""
        layout = declaration_body(self.source, "private var conversationLayout: some View")
        branches = len(re.findall(r"^\s*(?:\} else if |if |switch )", layout, re.MULTILINE))
        self.assertLessEqual(
            branches,
            12,
            "conversationLayout is accumulating ViewBuilder branches again; extract them into "
            "an AnyView-returning helper the way timelineRow does",
        )


if __name__ == "__main__":
    unittest.main()
