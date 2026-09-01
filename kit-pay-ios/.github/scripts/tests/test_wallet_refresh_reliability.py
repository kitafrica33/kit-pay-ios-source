"""Source-level guard for the independent wallet-history refresh lane."""

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


class WalletRefreshReliabilitySourceContract(unittest.TestCase):
    def setUp(self) -> None:
        self.source = APP_MODEL.read_text(encoding="utf-8")
        self.refresh = swift_function(
            self.source,
            "func refresh(userInitiated: Bool = false) async",
        )

    def test_wallet_history_does_not_wait_for_communication_work(self) -> None:
        history = self.refresh.index("await refreshSelectedWalletTransactions(")
        privacy = self.refresh.index("await loadCommunicationPrivacy()")
        messaging = self.refresh.index("await syncSecureMessagingIfPermitted(")

        self.assertLess(history, privacy)
        self.assertLess(history, messaging)
        self.assertNotIn("await flushOutbox()", self.refresh[:history])

    def test_wallet_history_refresh_is_account_and_session_fenced(self) -> None:
        helper = swift_function(
            self.source,
            "private func refreshSelectedWalletTransactions(",
        )

        self.assertIn("try await api.transactions(walletId: selectedWalletID).items", helper)
        self.assertGreaterEqual(helper.count("callHistoryContextIsCurrent("), 2)
        self.assertIn("persisted.selectedWalletId == selectedWalletID", helper)
        self.assertIn("persisted.transactions = transactions", helper)


if __name__ == "__main__":
    unittest.main()
