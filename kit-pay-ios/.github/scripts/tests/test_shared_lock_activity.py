"""Source contract guarding the 0xdead10cc termination fixed for build 103.

TestFlight 1.0.17 (102) was killed by RunningBoard: `EXC_CRASH (SIGKILL)`, termination reason
`RUNNINGBOARD 0xdead10cc`, no faulted thread. That code means the process was suspended while
it still held a file lock on a file in a shared app-group container. The log's only running
application work was a background outbox flush encoding the persisted state inside
`MessagingProcessBroker.withLock`, which holds `flock(LOCK_EX)` on
`<app group>/MessagingBroker/transaction.lock`.

The fix keeps an activity assertion open for exactly as long as the file lock is held, so the
process cannot be suspended in that window. `SharedLockActivityTests` exercises the behaviour
natively; this pins the shape, because the pieces are in three targets, the broker file must
stay usable from `APPLICATION_EXTENSION_API_ONLY` extensions, and none of it can be checked on
the Linux stage of CI.
"""

from __future__ import annotations

import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[3]
BROKER = ROOT / "KitPay/Core/MessagingProcessBroker.swift"
APP = ROOT / "KitPay/App/KitPayApp.swift"
SOURCE_ROOT = ROOT / "KitPay"
SHARE = ROOT / "KitPayShare/ShareViewController.swift"


class SharedLockActivityContractTests(unittest.TestCase):

    @classmethod
    def setUpClass(cls) -> None:
        cls.broker = BROKER.read_text(encoding="utf-8")
        cls.app = APP.read_text(encoding="utf-8")

    def test_locked_section_takes_and_releases_an_activity_assertion(self) -> None:
        body = self.broker.split("func withLock<T>", 1)
        self.assertEqual(len(body), 2, "MessagingProcessBroker.withLock is missing")
        body = body[1]
        begin = body.find("SharedLockActivity.begin()")
        release = body.find("defer { endSharedLockActivity() }")
        descriptor = body.find("Darwin.open(")
        unlock = body.find("defer { flock(fd, LOCK_UN) }")
        self.assertNotEqual(begin, -1, "withLock must begin a SharedLockActivity assertion")
        self.assertNotEqual(release, -1, "withLock must end the assertion in a defer")
        self.assertLess(begin, descriptor, "the assertion must precede the lock descriptor")
        self.assertLess(release, unlock, "the assertion's defer must outlive flock(LOCK_UN)")

    def test_every_flock_call_site_is_the_guarded_one(self) -> None:
        for path in SOURCE_ROOT.rglob("*.swift"):
            source = path.read_text(encoding="utf-8")
            if "flock(" not in source:
                continue
            self.assertEqual(
                path,
                BROKER,
                f"{path} takes a file lock outside the assertion in MessagingProcessBroker",
            )

    def test_broker_stays_usable_from_app_extensions(self) -> None:
        self.assertTrue(
            re.search(r"^import UIKit$", self.broker, re.M) is None,
            "MessagingProcessBroker is compiled into APPLICATION_EXTENSION_API_ONLY targets",
        )
        self.assertTrue(
            "enum SharedLockActivity" in self.broker,
            "SharedLockActivity lives beside the lock it protects",
        )
        self.assertTrue(
            "provider?() ?? {}" in self.broker,
            "an uninstalled provider must still return a balanced end handler",
        )

    def test_the_app_installs_a_background_task_backed_assertion_first(self) -> None:
        init_body = self.app.split("    init() {", 1)
        self.assertEqual(len(init_body), 2, "KitPayApp.init is missing")
        init_body = init_body[1]
        install = init_body.find("SharedLockActivity.install {")
        self.assertNotEqual(install, -1, "the app must install the assertion provider")
        self.assertLess(
            install,
            init_body.find("KitCaptureTemporaryFileStore.removeAbandonedFiles()"),
            "the assertion must be installed before any other launch work",
        )
        self.assertTrue(
            "UIApplication.shared.beginBackgroundTask(" in init_body
            and "UIApplication.shared.endBackgroundTask(" in init_body,
            "the app's assertion is a UIKit background task, begun and ended",
        )

    def test_each_target_installs_exactly_one_provider_of_its_own_kind(self) -> None:
        """The app's UIKit provider and the extension's ProcessInfo provider, and no third.

        `SharedLockActivity.install` replaces the provider process-wide, so a second installer
        inside one target would silently retire the first. Two targets are two processes.
        """
        installers = sorted(
            path
            for path in list(SOURCE_ROOT.rglob("*.swift")) + [SHARE]
            if "SharedLockActivity.install" in path.read_text(encoding="utf-8")
        )
        self.assertEqual(
            installers,
            sorted([APP, SHARE]),
            "one installer in the app, one in the share extension, and nowhere else",
        )
        self.assertIn(
            "static func installExpiringActivityProvider",
            self.broker,
            "the extension-safe provider ships beside the lock, not in the extension",
        )

    def test_the_share_extension_installs_an_extension_safe_assertion(self) -> None:
        """KitPayShare compiles the broker and takes the same flock, so it needs the same cover.

        The extension is suspended far more aggressively than the app: the share sheet is torn
        down the moment the customer taps Send, and `DirectShareSendCoordinator.enqueue` journals
        the message inside `withLock` on the way out. With the no-op default provider that window
        is exactly the 0xdead10cc that killed 1.0.17 (102) — in the one process that cannot call
        `UIApplication.shared.beginBackgroundTask` at all.
        """
        share = SHARE.read_text(encoding="utf-8")
        did_load = share.split("override func viewDidLoad() {", 1)
        self.assertEqual(len(did_load), 2, "ShareViewController.viewDidLoad is missing")
        did_load = did_load[1]
        install = did_load.find("SharedLockActivity.installExpiringActivityProvider()")
        self.assertNotEqual(
            install, -1, "the share extension must install an assertion provider at load"
        )
        self.assertLess(
            install,
            did_load.find("buildInterface()"),
            "the assertion must be installed before any work that can reach the broker",
        )
        self.assertNotIn(
            "UIApplication.shared",
            share,
            "APPLICATION_EXTENSION_API_ONLY removes UIApplication.shared",
        )

    def test_the_extension_provider_holds_its_activity_for_the_whole_locked_section(self) -> None:
        """`performExpiringActivity` asserts only while its block runs, so the block must wait.

        A provider that returned as soon as the activity started would assert nothing: the
        block would finish before `flock(LOCK_EX)` was even taken.
        """
        body = self.broker.split("static func installExpiringActivityProvider", 1)
        self.assertEqual(len(body), 2, "the extension-safe provider is missing")
        body = body[1]
        self.assertIn(
            "performExpiringActivity", body, "extensions assert through ProcessInfo, not UIKit"
        )
        wait = body.find("release.wait()")
        signal = body.find("return { release.signal() }")
        self.assertNotEqual(wait, -1, "the activity block must outlive the locked section")
        self.assertNotEqual(signal, -1, "ending the assertion must release the activity block")
        self.assertLess(wait, signal, "the block waits; the returned handler releases it")

    def test_a_refused_activity_never_blocks_the_locked_section(self) -> None:
        """An expired or refused assertion must not stall the caller or pin a worker thread."""
        body = self.broker.split("static func installExpiringActivityProvider", 1)[1]
        self.assertIn(
            "guard !expired else { return }",
            body,
            "an expired activity returns instead of waiting to be released",
        )
        self.assertIn(
            "granted.wait(timeout:",
            body,
            "a block that is never scheduled must not hold the caller for ever",
        )


if __name__ == "__main__":
    unittest.main()
