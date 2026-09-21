"""Source contract for the chat-scroll dead stop.

Background: `docs/status/ios-chat-scroll-2026-09-21.md`.

`AppStoreScreenshotUITests/testLongHistoryVerticalBubbleDragsPreserveReadingPosition`
failed on the 2 000-message fixture with `("0.0") is not greater than ("90.0")`: a
170-point, 3.5-second drag that starts inside a bubble moved the timeline by exactly
nothing. The device log shows why — the first pan sample after touch-down arrived
106 ms in on a short thread but 644 ms in on the long one, and in the failing pass no
sample arrived at all before the finger lifted, so neither the swipe-to-reply pan nor
the scroll view's own pan ever reached its ~10-point slop.

The cost was `ConversationView.correctedProjection`: a filter + correction fold + sort
over every message the account holds, allocated fresh on each read, and read about
fifteen times per `body` (once per visible bubble through the context menu, twice more
through `onChange(of: messages)` deep array comparisons). Memoising it per published
state generation is the fix, and it is trivial to undo by accident — a future edit that
reads `model.state.messages` straight from `correctedProjection` restores the freeze
without failing any behavioural test. There is no Swift toolchain on the CI's Linux
stage and the native suite cannot construct a `ConversationView`, so this reads the
source the way the other contracts in this directory do. The memo's own behaviour is
covered by `KitPayTests/ConversationProjectionCacheTests.swift`, which also runs on
Linux through `run_conversation_projection_linux_gate.sh`.
"""

from __future__ import annotations

import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[3]
MESSAGES_VIEW = ROOT / "KitPay/Features/Messages/MessagesView.swift"
APP_MODEL = ROOT / "KitPay/App/AppModel.swift"
CACHE = ROOT / "KitPay/Core/ConversationProjectionCache.swift"
CACHE_TESTS = ROOT / "KitPayTests/ConversationProjectionCacheTests.swift"
LINUX_GATE = ROOT / ".github/scripts/tests/run_conversation_projection_linux_gate.sh"


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


class ConversationTimelineProjectionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.messages_view = MESSAGES_VIEW.read_text(encoding="utf-8")
        self.app_model = APP_MODEL.read_text(encoding="utf-8")

    # --- the memo exists and survives a render ---------------------------------------

    def test_the_projection_cache_type_ships(self) -> None:
        # assertTrue, not assertIn: a failure must not echo an 11k-line file.
        self.assertTrue(CACHE.exists(), "KitPay/Core/ConversationProjectionCache.swift is missing")
        self.assertTrue(CACHE_TESTS.exists(), "The memo must keep its own unit tests")
        self.assertTrue(LINUX_GATE.exists(), "The memo must stay provable without a Mac")
        source = CACHE.read_text(encoding="utf-8")
        self.assertTrue(
            "final class ConversationProjectionCache" in source,
            "The memo must be a reference type: a struct in @State cannot record a fold",
        )
        self.assertTrue(
            "import UIKit" not in source and "import SwiftUI" not in source,
            "The memo must stay Foundation-only so the Linux gate can compile it",
        )

    def test_the_cache_is_held_in_state_so_it_outlives_one_body(self) -> None:
        pattern = (
            r"@State\s+private\s+var\s+timelineProjectionCache\s*=\s*\n?\s*"
            r"ConversationProjectionCache<"
        )
        self.assertTrue(
            re.search(pattern, self.messages_view),
            "timelineProjectionCache must be @State. A local or a computed property is "
            "rebuilt with the struct on every render, which memoises nothing",
        )

    # --- the screen actually reads through it ----------------------------------------

    def test_corrected_projection_reads_through_the_memo(self) -> None:
        body = declaration_body(
            self.messages_view,
            "private var correctedProjection: (messages: [LocalMessage], editedAt: [UUID: Date])",
        )
        self.assertTrue(
            "timelineProjectionCache.projection(" in body,
            "correctedProjection must answer from the memo; folding per read is what "
            "starved the main thread of touch handling on long threads",
        )
        for input_name in ("stateGeneration: model.stateGeneration",
                           "conversationID: conversationID",
                           "scheduledMessageIDs: waiting"):
            self.assertTrue(
                input_name in body,
                f"The memo key must carry {input_name}: a key that misses an input "
                "serves a stale timeline",
            )

    def test_corrected_projection_does_no_folding_of_its_own(self) -> None:
        body = declaration_body(
            self.messages_view,
            "private var correctedProjection: (messages: [LocalMessage], editedAt: [UUID: Date])",
        )
        for banned in ("model.state.messages", ".sort", "MessageEditAggregationPolicy"):
            self.assertTrue(
                banned not in body,
                f"correctedProjection must not touch {banned} directly — that work belongs "
                "inside the memo's build closure, where it runs once per state generation",
            )

    def test_the_fold_itself_survives_untouched(self) -> None:
        body = declaration_body(
            self.messages_view,
            "private func correctedProjectionFold(",
        )
        for required in (
            "model.state.messages.filter",
            "MessageEditAggregationPolicy.appliedEdits(in: visible)",
            "MessageEditAggregationPolicy.suppressedMessageIDs(in: visible)",
            "projected.sort { $0.timelineDate < $1.timelineDate }",
        ):
            self.assertTrue(
                required in body,
                f"The fold must keep {required}: memoising must not change what the "
                "timeline shows, only how often it is computed",
            )

    # --- the key's generation really moves -------------------------------------------

    def test_every_state_publish_bumps_the_generation(self) -> None:
        pattern = (
            r"@Published\s+private\(set\)\s+var\s+state:\s*PersistedState\s*=\s*\.empty\s*\{\s*\n"
            r"\s*didSet\s*\{\s*stateGeneration\s*&\+=\s*1\s*\}"
        )
        self.assertTrue(
            re.search(pattern, self.app_model),
            "AppModel.state must bump stateGeneration in didSet. The model writes `state` "
            "from about twenty call sites, so anything a writer has to remember to do is "
            "a stale timeline waiting to happen",
        )
        self.assertTrue(
            re.search(r"private\(set\)\s+var\s+stateGeneration:\s*UInt64", self.app_model),
            "stateGeneration must be a readable UInt64 the view can key a memo on",
        )

    def test_the_generation_is_not_a_second_publisher(self) -> None:
        match = re.search(r"([^\n]*)\n[^\n]*var stateGeneration: UInt64", self.app_model)
        self.assertTrue(match is not None, "stateGeneration is missing")
        window = self.app_model[max(0, match.start() - 400) : match.end()]
        self.assertTrue(
            "@Published private(set) var stateGeneration" not in window,
            "stateGeneration must not be @Published: it moves in lockstep with `state`, "
            "which already drives the render, so a second publisher only doubles the "
            "invalidations the fix set out to remove",
        )

    # --- the readers that made the fold expensive ------------------------------------

    def test_the_screen_still_reads_the_projection_from_many_places(self) -> None:
        """The memo is load-bearing precisely because these reads are everywhere."""
        reads = len(re.findall(r"(?<![A-Za-z0-9_.])messages(?![A-Za-z0-9_(])", self.messages_view))
        self.assertTrue(
            reads > 5,
            "If the screen stopped reading `messages` widely this contract would be moot; "
            "check the fix is still needed before deleting it",
        )

    def test_bubble_context_menus_no_longer_imply_a_fold_per_row(self) -> None:
        body = declaration_body(self.messages_view, "private func forwardPayloadItems(")
        self.assertTrue(
            re.search(r"messages\s*\n?\s*\.filter", body),
            "forwardPayloadItems reads the projection; it is called once per visible bubble "
            "from the context menu, which is why the projection must be memoised",
        )
