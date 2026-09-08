"""Keep the KITMEDIA2 withdrawal guard scoped to batches and before draft commit."""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[3]


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


class MediaBatchCapabilityWiringTests(unittest.TestCase):
    def setUp(self):
        self.source = (ROOT / "KitPay/App/AppModel.swift").read_text()

    def test_single_attachment_paths_remain_independent_of_media_v2(self):
        for marker in ("func queueMediaMessage(", "func queueDirectMediaMessage("):
            body = declaration(self.source, marker)
            self.assertNotIn("messagingMediaMessageLocalQueueEnabled", body)
            self.assertNotIn("enablesMessagingMediaMessageV2", body)
        direct = declaration(self.source, "func queueDirectMediaMessage(")
        self.assertIn("return await queueMediaMessage(", direct)

    def test_batch_rejects_withdrawal_before_file_parking_and_rechecks_before_commit(self):
        batch = declaration(self.source, "func queueMediaMessageBatch(")
        guard = "guard messagingMediaMessageLocalQueueEnabled else {"
        self.assertEqual(batch.count(guard), 2)
        first, second = batch.index(guard), batch.rindex(guard)
        self.assertLess(first, batch.index("await "))
        self.assertLess(first, batch.index("SecureMediaFileCache.shared.insertIfAbsent("))
        self.assertGreater(second, batch.rindex("drafts.append("))
        self.assertLess(second, batch.index("KitMediaMessageV2OutboundBatch.queued("))
        self.assertLess(second, batch.index("queueDeferredMediaBatch("))
        for offset in (first, second):
            denial = declaration(batch[offset:], guard)
            self.assertIn("Your selection is saved", denial)
            self.assertIn("return false", denial)
            self.assertNotIn("rollbackParks()", denial)
            self.assertNotIn("clear", denial)

    def test_batch_snapshot_uses_authenticated_media_capability_in_current_scope(self):
        feature = declaration(self.source, "var messagingMediaMessageLocalQueueEnabled:")
        self.assertIn("secureMessagingLocalQueueAvailable", feature)
        self.assertIn(".mediaMessages", feature)
        self.assertIn("capabilities.map(\\.enablesMessagingMediaMessageV2)", feature)
        self.assertIn("in: messagingDeferredFeatureScope", feature)
        self.assertIn("mediaMessages: discovered.enablesMessagingMediaMessageV2", self.source)


if __name__ == "__main__":
    unittest.main()
