"""Source contract for the chat's media render path.

Background: `docs/status/ios-chat-media-2026-09-21.md`.

Owner report against 1.0.17 build 105: *"still some lagging between chats ... scrolling
through chat messages lags"*, and separately that swiping left and right through a
conversation's media is not smooth.

Three defects sat behind it, and all three are the kind that no behavioural test can
see — the app renders the right pixels either way, it just cannot render them at 60 Hz:

1.  Three chat surfaces called ImageIO **synchronously inside `body`**. A `body` that
    decodes is a `body` that blocks the main thread for the whole decode, so every row
    that came on screen stalled the run loop that was tracking the finger.
2.  They asked for far more pixels than they could draw — the photo bubble asked for
    3 072 px to fill 900, which is 37.7 MB of decoded pixels against a 64 MB cache, so
    a thread with three photos in it could not hold its own thumbnails and every scroll
    pass re-decoded what the pass before it had just evicted.
3.  Six whole-thread folds still ran per render in `conversationLayout`, on top of the
    projection memo that `test_conversation_timeline_projection.py` guards.

Every one of these reappears the instant someone writes the obvious code, and none of
them fails a behavioural test, so this reads the source the way the other contracts in
this directory do. The pure policies behind the fix carry their own XCTest suites, which
run on Linux through `run_chat_media_bucket_linux_gate.sh`.
"""

from __future__ import annotations

import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[3]
BUCKET = ROOT / "KitPay/Core/ChatMediaDisplayBucket.swift"
WAVEFORM = ROOT / "KitPay/Core/ChatWaveformShape.swift"
THUMBNAILS = ROOT / "KitPay/Features/Messages/ChatMediaThumbnails.swift"
MEDIA_VIEWS = ROOT / "KitPay/Features/Messages/ChatMediaViews.swift"
ALBUM_GRID = ROOT / "KitPay/Features/Messages/ChatMediaAlbumGridView.swift"
GALLERY = ROOT / "KitPay/Features/Messages/KitMediaGalleryView.swift"
MESSAGES_VIEW = ROOT / "KitPay/Features/Messages/MessagesView.swift"
PROJECTION_CACHE = ROOT / "KitPay/Core/ConversationProjectionCache.swift"
LINUX_GATE = ROOT / ".github/scripts/tests/run_chat_media_bucket_linux_gate.sh"
BUCKET_TESTS = ROOT / "KitPayTests/ChatMediaDisplayBucketTests.swift"
WAVEFORM_TESTS = ROOT / "KitPayTests/ChatWaveformShapeTests.swift"
LAYOUT_TESTS = ROOT / "KitPayTests/ConversationLayoutCacheTests.swift"
PROJECT = ROOT / "KitPay.xcodeproj/project.pbxproj"
UI_TESTS = ROOT / "KitPayUITests/AppStoreScreenshotUITests.swift"

#: `downsampledImage` and the ImageIO thumbnail entry points. A `body` that calls one of
#: these blocks the main thread for the decode.
SYNCHRONOUS_DECODERS = (
    "downsampledImage(",
    "CGImageSourceCreateThumbnailAtIndex(",
)


def without_detached_work(body: str) -> str:
    """Drop every `Task.detached { ... }` closure from `body`.

    A decode inside one is the *fix*, not the defect: it runs off the main thread. What
    must never reappear is a decode on the render path itself.
    """
    marker = "Task.detached"
    while True:
        start = body.find(marker)
        if start == -1:
            return body
        opening = body.index("{", start)
        depth = 0
        for index in range(opening, len(body)):
            if body[index] == "{":
                depth += 1
            elif body[index] == "}":
                depth -= 1
                if depth == 0:
                    body = body[:start] + body[index + 1 :]
                    break
        else:
            raise AssertionError("Unterminated Task.detached closure")


def squashed(text: str) -> str:
    """Collapse whitespace so a contract survives Swift line wrapping."""
    return " ".join(text.split())


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


class ChatMediaRenderCostTests(unittest.TestCase):
    def setUp(self) -> None:
        self.media_views = MEDIA_VIEWS.read_text(encoding="utf-8")
        self.thumbnails = THUMBNAILS.read_text(encoding="utf-8")
        self.album_grid = ALBUM_GRID.read_text(encoding="utf-8")
        self.gallery = GALLERY.read_text(encoding="utf-8")
        self.messages_view = MESSAGES_VIEW.read_text(encoding="utf-8")

    # --- the policies ship, and stay provable without a Mac ------------------------

    def test_the_display_bucket_and_waveform_ship_as_linux_provable_policies(self) -> None:
        for path in (BUCKET, WAVEFORM, BUCKET_TESTS, WAVEFORM_TESTS, LAYOUT_TESTS, LINUX_GATE):
            # assertTrue, not assertIn: a failure must not echo a source file.
            self.assertTrue(path.exists(), f"{path.relative_to(ROOT)} is missing")
        for path in (BUCKET, WAVEFORM):
            source = path.read_text(encoding="utf-8")
            self.assertTrue(
                "import UIKit" not in source and "import SwiftUI" not in source,
                f"{path.name} must stay Foundation-only so the Linux gate can compile it",
            )
        gate = LINUX_GATE.read_text(encoding="utf-8")
        for path in (BUCKET, WAVEFORM, PROJECTION_CACHE, BUCKET_TESTS, WAVEFORM_TESTS, LAYOUT_TESTS):
            self.assertIn(
                path.name,
                gate,
                f"{path.name} is not compiled by the Linux gate, so nothing proves it",
            )

    def test_the_new_policies_are_compiled_into_the_app(self) -> None:
        project = PROJECT.read_text(encoding="utf-8")
        for path in (BUCKET, WAVEFORM):
            self.assertIn(
                path.name,
                project,
                f"{path.name} is referenced by the app but not in the Xcode target",
            )

    # --- nothing decodes on the main thread ----------------------------------------

    def test_no_chat_bubble_decodes_inside_its_body(self) -> None:
        """The whole point of the fix: `body` reads the cache, `.task` fills it."""
        offenders = []
        for name, source in (
            ("ChatMediaViews.swift", self.media_views),
            ("ChatMediaAlbumGridView.swift", self.album_grid),
        ):
            for match in re.finditer(r"\n    (?:@ViewBuilder\n    )?(?:private )?var (\w*[Bb]ody|imageCell|thumbnail|itemContent)\b", source):
                declaration = match.group(0).strip("\n")
                body = without_detached_work(declaration_body(source, declaration))
                for decoder in SYNCHRONOUS_DECODERS:
                    if decoder in body:
                        offenders.append(f"{name}: {match.group(1)} calls {decoder}")
        self.assertEqual(
            offenders,
            [],
            "a body that decodes blocks the main thread for the whole ImageIO pass",
        )

    def test_the_thumbnail_store_offers_no_synchronous_decoder_to_tempt_a_body(self) -> None:
        store = declaration_body(self.thumbnails, "final class ChatMediaThumbnailStore")
        synchronous = [
            name
            for name in re.findall(r"\n    func (\w+)\((.*?)\) (async )?-> UIImage\?", store, re.S)
            for name, _, is_async in [name]
            if not is_async and not name.startswith(("cached", "bestCached"))
        ]
        self.assertEqual(
            synchronous,
            [],
            "a synchronous decoder on the store is an invitation to decode inside a body",
        )
        for signature in (
            "func decodedThumbnail(\n        forKey key: String,\n        maxPixel: CGFloat,\n        fromFileURL",
            "func decodedThumbnail(\n        forKey key: String,\n        maxPixel: CGFloat,\n        from data: Data?",
        ):
            self.assertTrue(
                signature in self.thumbnails,
                "the async decoders are the only entry points into a decode",
            )
        self.assertTrue(
            "Task.detached(priority: .userInitiated)" in self.thumbnails,
            "the decode must leave the main actor",
        )

    def test_one_decode_per_key_at_a_time(self) -> None:
        self.assertTrue(
            "private var inFlightDecodes: [NSString: Task<UIImage?, Never>]" in self.thumbnails,
            "without this, every surface showing one attachment starts its own ImageIO pass",
        )
        decoded = declaration_body(
            self.thumbnails,
            "private func decoded(",
        )
        self.assertIn("if let existing = inFlightDecodes[entry] { return await existing.value }", decoded)
        remove_all = declaration_body(self.thumbnails, "func removeAll()")
        self.assertIn(
            "task.cancel()",
            remove_all,
            "a sign-out must cancel decodes of the previous account's plaintext",
        )

    # --- nothing over-samples -------------------------------------------------------

    def test_every_bubble_sizes_its_request_through_the_bucket(self) -> None:
        for name, source in (
            ("ChatMediaViews.swift", self.media_views),
            ("ChatMediaAlbumGridView.swift", self.album_grid),
        ):
            # assertTrue, not assertIn: a failure must not echo a 2 000-line file.
            self.assertTrue(
                "ChatMediaDisplayBucket" in source,
                f"{name} must size its decodes through the shared policy",
            )
        for surface, constant in (
            ("SecureImageMessageView", "photoBubbleEdge"),
            ("SecureMediaBatchItemView", "albumItemEdge"),
            ("PendingSecureMediaMessageView", "albumItemEdge"),
        ):
            index = self.media_views.index(f"struct {surface}: View")
            window = self.media_views[index : index + 6000]
            self.assertIn(
                f"ChatMediaDisplayBucket.{constant}",
                window,
                f"{surface} must ask for what it draws, not for an arbitrary number",
            )
        self.assertFalse(
            "maxPixel: 1_024" in self.media_views,
            "1 024 points at 3x is 3 072 pixels: the build-105 defect",
        )

    def test_the_cache_key_is_a_rung_not_a_caller_supplied_float(self) -> None:
        cache_key = declaration_body(self.thumbnails, "private static func cacheKey(")
        self.assertIn("pixelSize(forMaxPixel: maxPixel)", cache_key)
        pixel_size = declaration_body(self.thumbnails, "static func pixelSize(")
        self.assertIn("ChatMediaDisplayBucket.pixels(", pixel_size)

    def test_the_waveform_is_arithmetic_not_arrays(self) -> None:
        index = self.media_views.index("struct VoiceNoteWaveform")
        body = self.media_views[index : index + 2500]
        self.assertIn("ChatWaveformShape", body)
        self.assertNotIn(
            "withUnsafeBytes(of:",
            body,
            "the seed bytes must not be re-copied into an array on every playback tick",
        )

    # --- the layout folds once ------------------------------------------------------

    def test_the_layout_derivation_is_memoised_and_held_in_state(self) -> None:
        self.assertTrue(
            "@State private var timelineLayoutCache = ConversationLayoutCache<ConversationLayoutDerivation>()"
            in self.messages_view,
            "a cache rebuilt per body is not a cache",
        )
        self.assertTrue(
            "struct ConversationLayoutDerivation" in self.messages_view,
            "the six folds must be derived together, or they fall back out of the memo one by one",
        )
        derivation = declaration_body(
            self.messages_view,
            "private func conversationLayoutDerivation(",
        )
        self.assertIn("timelineLayoutCache.derivation(for:", derivation)
        for fold in ("galleryItemsFold(", "separatorDay:", "localeIdentifier:"):
            self.assertIn(fold, derivation)

    def test_the_hot_reads_go_through_the_memo(self) -> None:
        for name in ("timelineItems", "reactionTallies", "galleryItems"):
            body = declaration_body(self.messages_view, f"    private var {name}: ")
            self.assertIn(
                "conversationLayoutDerivation(",
                body,
                f"`{name}` is read many times per body and must not re-fold the thread",
            )

    # --- swiping through a conversation's media ------------------------------------

    def test_a_page_that_is_still_loading_shows_the_thumbnail_the_chat_already_decoded(self) -> None:
        loading_page = " ".join(
            declaration_body(self.gallery, "private func loadingPage(").split()
        )
        self.assertIn(
            "ChatMediaThumbnailStore.shared.bestCachedThumbnail( forKey: item.thumbnailKey )",
            loading_page,
        )
        best = declaration_body(self.thumbnails, "func bestCachedThumbnail(")
        self.assertIn("ChatMediaDisplayBucket.ladder.reversed()", best)

    def test_the_pager_neither_reallocates_nor_formats_dates_per_render(self) -> None:
        pager = declaration_body(self.gallery, "private var pager: some View")
        self.assertNotIn(
            "Array(items.enumerated())",
            pager,
            "a `.page` TabView is not lazy; this allocates a pair array for every render",
        )
        self.assertIn("ForEach(items.indices, id: \\.self)", pager)
        label = declaration_body(self.gallery, "private func accessibilityLabel(")
        self.assertNotIn(
            "formatted(",
            label,
            "Date.formatted per page per render, across a non-lazy pager, on the main thread",
        )
        self.assertIn("itemLabels[item.id]", label)

    def test_tapping_a_photo_inside_an_album_opens_the_swipeable_gallery(self) -> None:
        """Build 105's dead end: several photos sent together could not be swiped through."""
        self.assertTrue(
            "var openGallery: ((UUID, Int?) -> Bool)? = nil" in self.media_views,
            "the multi-attachment bubble must be able to open the conversation gallery",
        )
        image_cell = declaration_body(self.media_views, "    private var imageCell: some View")
        self.assertIn(
            "if let openGallery, openGallery(message.id, itemIndex) { return }", image_cell
        )
        file_row = declaration_body(self.media_views, "    private var fileRow: some View")
        self.assertIn("kind == .video, let openGallery", file_row)
        self.assertTrue(
            "openGallery: { openGalleryItem(at: $0, itemIndex: $1) }" in self.messages_view,
            "the conversation must supply the hook, or the bubble silently keeps the dead end",
        )

    def test_tapping_a_queued_photo_or_video_also_opens_the_gallery(self) -> None:
        """The same dead end, one bubble along.

        `galleryItemsFold` has always counted queued photos and videos among the
        conversation's gallery items -- its very first branch reads `pendingAttachment`.
        Nothing routed a *tap* on one there, so the owner could swipe *onto* a queued
        photo from a sealed one but never start from it, and in a thread where the
        recent media is still uploading that is every photo on screen.
        """
        pending = declaration_body(
            self.media_views, "struct PendingSecureMediaMessageView: View"
        )
        self.assertTrue(
            "var openGallery: ((UUID) -> Bool)? = nil" in pending,
            "the queued bubble cannot open the gallery",
        )
        content = squashed(declaration_body(pending, "private var pendingContent: some View"))
        self.assertIn(
            "if let openGallery, openGallery(message.id) { return }",
            content,
            "a tap on the queued photo must open the gallery before the standalone viewer",
        )
        self.assertIn(
            "if kind == .image || kind == .video, let openGallery, "
            "openGallery(message.id) { return }",
            content,
            "a queued video belongs in the gallery beside the photos, and so does a queued "
            "photo that has not decoded its thumbnail yet -- build 105 sent every one of "
            "those taps to a standalone viewer with nowhere to swipe",
        )
        self.assertTrue(
            "PendingSecureMediaMessageView( message: message, attachment: pending, "
            "openGallery: { openGalleryItem(at: $0, itemIndex: nil) } )"
            in squashed(self.messages_view),
            "the conversation must supply the hook, or the bubble keeps the dead end",
        )
        opener = declaration_body(
            self.messages_view, "private func openGalleryItem(at messageID: UUID, itemIndex: Int?)"
        )
        self.assertIn(
            "return false",
            opener,
            "the hand-off must report a refusal, or a row the fold does not hold swallows "
            "the tap and the bubble opens nothing at all",
        )

    def test_the_gallery_index_matches_the_fold_that_builds_its_items(self) -> None:
        """Item 3 of an album must open item 3, even when the album mixes in documents."""
        fold = declaration_body(self.messages_view, "private func galleryItemsFold(")
        self.assertEqual(
            fold.count("items.enumerated().compactMap"),
            2,
            "both batch shapes must number their items before dropping the non-visual ones",
        )
        self.assertNotIn(
            "items.filter",
            fold,
            "filtering before enumerating renumbers the album, so item 3 would open item 2",
        )
        self.assertTrue(
            "descriptor.items" in self.media_views,
            "the sealed batch bubble must stack the descriptor's own item list",
        )
        item_stack = declaration_body(self.media_views, "    private func itemStack(")
        self.assertIn(
            "ForEach(Array(items.enumerated()), id: \\.element.attachmentID)",
            item_stack,
        )
        self.assertIn("itemIndex: index,", item_stack)


class ChatMediaUITestGestureTests(unittest.TestCase):
    """The two UI tests that measure the owner's report must measure the screen they claim to.

    Run 6ab15f28 is the reason this contract exists. A chat opens pinned to its newest
    message, and a deliberate upward pull from a pinned timeline is the product's camera
    gesture — `testChatBottomPullOpensCameraOnlyAfterADeliberateRelease` asserts exactly
    that. The mixed-media scroll test warmed up with `swipeUp`: the camera opened over
    the thread, iOS raised its Camera and Microphone prompts, and the twelve "timed"
    swipes that followed were synthesized into a camera preview while the timeline sat
    untouched at the bottom. The numbers were real; they measured the wrong screen. The
    assertion that caught it was an unrelated one, and only the hierarchy dump explained
    it, so pin the direction: history is upwards on screen, which is `swipeDown`.
    """

    def setUp(self) -> None:
        self.ui_tests = UI_TESTS.read_text(encoding="utf-8")

    def test_reading_history_never_pulls_up_on_a_pinned_timeline(self) -> None:
        scroll_test = declaration_body(
            self.ui_tests,
            "func testMixedMediaThreadScrollsAndRecordsSwipeWallClock()",
        )
        before_timed_passes = scroll_test[: scroll_test.index("for pass in 0 ..< 12")]
        self.assertNotIn(
            "swipeUp",
            before_timed_passes,
            "an upward pull on a timeline still pinned to its newest message opens the "
            "camera, and every later swipe is then measured against a camera preview",
        )
        self.assertIn(
            "timeline.swipeDown(velocity: .default)",
            before_timed_passes,
            "the warm-up has to move the timeline into history before the clock starts",
        )
        self.assertIn(
            "XCTAssertFalse(closeCamera.exists",
            scroll_test,
            "the test must prove the camera is not covering the thread it just timed",
        )
        self.assertIn(
            "if newest.isHittable { break }",
            scroll_test,
            "the way back has to stop at the newest row; one swipe past it is the "
            "camera pull again",
        )

    def test_the_lazy_row_search_scrolls_into_history_too(self) -> None:
        finder = declaration_body(
            self.ui_tests,
            "private static func firstHittable(",
        )
        self.assertIn("timeline.swipeDown(velocity: .default)", finder)
        self.assertNotIn("swipeUp", finder)

    def test_the_gallery_walk_turns_pages_by_a_deliberate_drag(self) -> None:
        gallery_test = declaration_body(
            self.ui_tests,
            "func testMediaGallerySwipesThroughTheConversationsMediaInOrder()",
        )
        for flick in ("app.swipeLeft()", "app.swipeRight()"):
            self.assertNotIn(
                flick,
                gallery_test,
                "a flick is short and fast, and a page that is still settling swallows "
                "it: run 6ab15f28 lost a step-back to exactly that, with nothing in the "
                "failure to say so",
            )
        self.assertEqual(
            gallery_test.count("Self.turnGalleryPage(app, forward:"),
            4,
            "every page turn -- headroom, forward walk, the step onto a photo before the "
            "zoom, and the walk back -- uses the held drag and reads where the gallery "
            "actually settled",
        )
        pager = squashed(
            declaration_body(
                self.ui_tests,
                "private static func pageGallery(_ app: XCUIApplication, forward: Bool)",
            )
        )
        self.assertIn(
            "from.press(forDuration: 0.05, thenDragTo: to, withVelocity: "
            "XCUIGestureVelocity(rawValue: 320), thenHoldForDuration: 0.3)",
            pager,
            "a drag that lifts with the synthesizer's release velocity still on it "
            "carries the pager past the page it was aimed at: run 6ab16c17 turned two "
            "pages in one gesture (item 96 -> 98). Hold, then lift.",
        )
        self.assertIn("dx: forward ? 0.85 : 0.15", pager)
        self.assertIn("dx: forward ? 0.15 : 0.85", pager)

    def test_a_page_turn_is_judged_by_where_the_gallery_settled(self) -> None:
        turn = squashed(
            declaration_body(self.ui_tests, "private static func turnGalleryPage(")
        )
        self.assertIn(
            "if let previous = settling, previous.index == position.index { return position }",
            turn,
            "the counter has to be read twice in agreement, or a reading taken while "
            "the pager is still animating becomes the destination",
        )
        self.assertIn("restoreGalleryChrome(app)", turn)
        gallery_test = declaration_body(
            self.ui_tests,
            "func testMediaGallerySwipesThroughTheConversationsMediaInOrder()",
        )
        self.assertEqual(
            gallery_test.count("media went past unseen"),
            2,
            "both walks must refuse a turn that skipped over an item, in either "
            "direction -- that is the owner's 'missing items'",
        )
        self.assertNotIn(
            "pinch(withScale",
            gallery_test,
            "a synthesized pinch cannot zoom in on a page that already fills the screen "
            "(run 6ab17461: maximum possible scale 0.84) -- the gallery's own double tap "
            "does, and it is what a reader uses",
        )
        self.assertIn(
            "anchor.doubleTap()",
            gallery_test,
            "zooming has to be exercised, not skipped",
        )
        for ordering in ("visited.sorted()", "walkedBack.sorted(by: >)"):
            self.assertIn(
                ordering,
                gallery_test,
                "walking in order is the assertion; how far one synthesized drag "
                "carries a scroll view is not the product's contract",
            )

    def test_a_hidden_chrome_cannot_be_reported_as_a_stuck_pager(self) -> None:
        poll = declaration_body(
            self.ui_tests,
            "private static func waitForGalleryPosition(",
        )
        self.assertIn(
            "restoreGalleryChrome(app)",
            poll,
            "a swipe the pager does not consume reaches the page's tap gesture and "
            "hides the counter, which is the only element that could report the "
            "position -- restore it before blaming the pager",
        )
        self.assertIn(
            'the counter now reads "',
            self.ui_tests,
            "every gallery swipe failure must say where the gallery actually is",
        )


if __name__ == "__main__":
    unittest.main()
