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

    def test_capability_discovery_failure_does_not_abort_wallet_refresh(self) -> None:
        history = self.refresh.index("await refreshSelectedWalletTransactions(")
        capability_start = self.refresh.index("let capabilityRefreshTask = Task")
        capability_join = self.refresh.index("await capabilityRefreshTask.value")
        before_history = self.refresh[:history]

        self.assertLess(capability_start, history)
        self.assertLess(history, capability_join)
        self.assertIn("return await self.reloadCapabilities()", before_history)
        self.assertNotIn("guard await reloadCapabilities() else { return }", before_history)

    def test_cached_communication_assurance_cannot_block_bootstrap_or_history(self) -> None:
        bootstrap = self.refresh.index("try await api.bootstrap()")
        history = self.refresh.index("await refreshSelectedWalletTransactions(")
        first_communication_gate = self.refresh.index(
            "guard communicationAccessGranted else { return }"
        )

        self.assertIn("AuthenticatedProjectionRefreshPolicy.permits(", self.refresh[:bootstrap])
        self.assertNotIn(
            "communicationAccessGranted\n        else { return }",
            self.refresh[:bootstrap],
        )
        self.assertLess(bootstrap, history)
        self.assertLess(history, first_communication_gate)

    def test_wallet_history_refresh_is_account_and_session_fenced(self) -> None:
        helper = swift_function(
            self.source,
            "private func refreshSelectedWalletTransactions(",
        )

        self.assertIn("if let flight = walletHistoryRefreshFlight, flight.key == key", helper)
        self.assertIn("let task = Task { @MainActor [weak self] in", helper)
        self.assertIn("await task.value", helper)

        worker = swift_function(
            self.source,
            "private func performSelectedWalletTransactionsRefresh(",
        )
        self.assertIn("try await api.transactions(walletId: key.walletID)", worker)
        self.assertIn(
            "CustomerTransactionPresentationPolicy\n"
            "                .pageReplacement(for: firstPage, wallet: selectedWallet)",
            worker,
        )
        self.assertGreaterEqual(worker.count("callHistoryContextIsCurrent("), 2)
        self.assertGreaterEqual(
            worker.count("WalletIdentityResolver.identifiersMatch("),
            3,
        )
        self.assertIn("persisted.selectedWalletId,", worker)
        self.assertIn("persisted.transactions = transactions", worker)


if __name__ == "__main__":
    unittest.main()
