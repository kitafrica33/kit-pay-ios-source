import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[3]


class ClaimNotificationLivenessSourceContract(unittest.TestCase):
    def test_authoritative_capability_commit_wakes_durable_claim_routes(self) -> None:
        source = (ROOT / "KitPay/App/AppModel.swift").read_text(encoding="utf-8")
        start = source.index("    private func reloadCapabilities() async -> Bool {")
        end = source.index(
            "    private func capabilitiesContextIsCurrent(",
            start,
        )
        body = source[start:end]
        commit = body.index("capabilities = discovered")
        publish = body.index("await publishLatestState()", commit)
        replay = body.index(
            "await ClaimablePaymentNotificationActionDispatcher.shared.replayPending()",
            publish,
        )
        success = body.index("return true", replay)
        failure = body.index("} catch {", success)

        self.assertLess(commit, publish)
        self.assertLess(publish, replay)
        self.assertLess(replay, success)
        self.assertLess(success, failure)

    def test_group_claim_uses_group_authority_before_standalone_claim_lookup(self) -> None:
        source = (ROOT / "KitPay/App/AppModel.swift").read_text(encoding="utf-8")
        start = source.index(
            "    private func handleClaimablePaymentNotificationAction("
        )
        end = source.index(
            "    private func queueMessageNotificationReply(",
            start,
        )
        body = source[start:end]
        group_branch = body.index("if let groupPaymentID = action.groupPaymentID")
        group_lookup = body.index("try await api.groupPayment(id: groupPaymentID)")
        claim_lookup = body.index("try await api.transferAcceptance(transferId: action.claimID)")
        group_body = body[group_branch:claim_lookup]

        self.assertLess(group_branch, group_lookup)
        self.assertLess(group_lookup, claim_lookup)
        self.assertIn("return requestConversationNavigation(", group_body)
        self.assertNotIn("walletClaimNavigationRequest", group_body)


if __name__ == "__main__":
    unittest.main()
