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


class IOSMediaDiagnosticsSourceContractTests(unittest.TestCase):
    def test_accepted_deletion_recovery_clears_diagnostics_before_retiring_markers(self) -> None:
        body = declaration_body(
            ROOT / "KitPay/App/AppModel.swift",
            "private func resumeAcceptedAccountDeletionCleanupBeforeRestore()",
        )

        self.assertIn(
            "LocalMediaPerformanceMonitor.shared.suspendRecordingAndClearReport()",
            body,
        )
        final_clear = body.index(
            "guard LocalMediaPerformanceMonitor.shared.clearReport()"
        )
        attempt_retirement = body.index(
            "accountDeletionAttempts.completeIfCurrent(deletionAttempt)"
        )
        accepted_retirement = body.index(
            "acceptedAccountDeletionPurges.completeIfCurrent(pending)"
        )
        self.assertLess(final_clear, attempt_retirement)
        self.assertLess(final_clear, accepted_retirement)

    def test_preawait_media_loader_scope_is_carried_to_diagnostic_creation(self) -> None:
        body = declaration_body(
            ROOT / "KitPay/App/AppModel.swift",
            "func loadProtectedLocalMediaFile(",
        )

        capture = body.index(
            "let mediaDiagnosticsScope = LocalMediaPerformanceMonitor.shared.captureProducerScope()"
        )
        first_suspension = body.index("await store.snapshot()")
        diagnostic_begin = body.index(
            "LocalMediaPerformanceMonitor.shared.beginRecipientHydration("
        )
        scope_use = body.index("producerScope: mediaDiagnosticsScope", diagnostic_begin)
        self.assertLess(capture, first_suspension)
        self.assertLess(diagnostic_begin, scope_use)

    def test_deferred_upload_carries_scope_captured_before_account_work(self) -> None:
        coordinator = ROOT / "KitPay/Core/SecureMessagingCoordinator.swift"
        prepare = declaration_body(coordinator, "func prepareDeferredMessage(")
        capture = prepare.index(
            "let mediaDiagnosticsProducerScope = await LocalMediaPerformanceMonitor.shared"
        )
        first_account_read = prepare.index("let snapshot = await store.snapshot()")
        self.assertLess(capture, first_account_read)
        self.assertEqual(
            prepare.count(
                "mediaDiagnosticsProducerScope: mediaDiagnosticsProducerScope"
            ),
            2,
        )

        upload = declaration_body(coordinator, "private func uploadDeferredMediaDescriptor(")
        self.assertIn(
            "mediaDiagnosticsProducerScope: LocalMediaDiagnosticProducerScope?",
            upload,
        )
        self.assertEqual(upload.count("producerScope: mediaDiagnosticsProducerScope"), 3)


if __name__ == "__main__":
    unittest.main()
