"""Source-level guards for durable financial-to-chat hand-offs."""

from __future__ import annotations

import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[3]
APP_MODEL = ROOT / "KitPay/App/AppModel.swift"


def swift_function(source: str, marker: str) -> str:
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start : index + 1]
    raise AssertionError(f"unterminated Swift function: {marker}")


class FinancialChatReceiptRecoverySourceContract(unittest.TestCase):
    def setUp(self) -> None:
        self.source = APP_MODEL.read_text(encoding="utf-8")

    def test_payment_request_create_drains_after_both_confirmation_paths(self) -> None:
        create = swift_function(
            self.source,
            "func createPaymentRequestWithDurableChatReceipt(",
        )

        self.assertEqual(create.count("try await confirmPaymentRequestChatReceipt("), 2)
        self.assertEqual(create.count("await recoverAndDrainFinancialChatReceipts()"), 2)

    def test_acknowledged_payment_request_fallback_stays_account_bound(self) -> None:
        queue = swift_function(self.source, "func queuePaymentRequest(")

        self.assertIn("let ownsDestinationWallet = state.wallets.contains", queue)
        self.assertIn("} else if ownsDestinationWallet, let share =", queue)
        self.assertIn("$0.currency == request.currency", queue)


if __name__ == "__main__":
    unittest.main()
