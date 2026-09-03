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


class OutgoingCallRingDeadlineSourceContractTests(unittest.TestCase):
    def test_deadline_is_monotonic_one_shot_and_never_extends_local_ceiling(self) -> None:
        policy = declaration_body(
            ROOT / "KitPay/Core/CallLifecycle.swift",
            "struct OutgoingCallRingDeadlineGate",
        )

        self.assertIn("static let provisionalLifetime: TimeInterval = 45", policy)
        self.assertIn("monotonicNow + Self.provisionalLifetime", policy)
        self.assertIn("min(", policy)
        self.assertIn("current.deadline.monotonicTime", policy)
        self.assertIn("func permitsSubmission(", policy)
        self.assertIn("answerAlreadyAccepted || !refinedDeadline.isExpired", policy)
        consume = policy.index("mutating func consumeExpired(")
        clear = policy.index("ticket = nil", consume)
        action = policy.index("return .endAuthenticated", clear)
        self.assertLess(clear, action)

    def test_attempt_arms_before_presentation_and_response_binds_before_promotion(self) -> None:
        app_model = ROOT / "KitPay/App/AppModel.swift"
        queue = declaration_body(app_model, "    func queueCall(")
        self.assertLess(
            queue.index("outgoingCallRingDeadlineGate.begin(attempt)"),
            queue.index("presentPendingOutgoing("),
        )

        accept = declaration_body(
            app_model,
            "    private func acceptEphemeralOutgoingCall(",
        )
        pre_arbitration = accept[: accept.index("        let mapped = mapCall(result.call)")]
        self.assertNotIn("outboxContextIsCurrent(", pre_arbitration)
        self.assertLess(
            accept.index("let responseRecord = CallLifecyclePolicy.mergingStartResponse("),
            accept.index("let responseDisposition = OutgoingCallStartResponsePolicy.disposition("),
        )
        self.assertLess(
            accept.index("outgoingCallRingDeadlineGate.promote("),
            accept.index("promotePendingOutgoing("),
        )
        self.assertIn("result.call.ringExpiresAt", accept)
        self.assertIn("result.call.serverTime ?? result.serverTime", accept)
        self.assertIn("answerAlreadyAccepted: responseAlreadyAnswered", accept)
        self.assertIn("responseRecord.answeredAt != nil", accept)
        self.assertIn("pendingCallAnswers.contains", accept)
        self.assertIn("caseInsensitiveCompare(handoff.callId)", accept)
        self.assertLess(
            accept.index("claimPendingCallAnswer(callId: result.call.id)"),
            accept.index("guard await outboxContextIsCurrent("),
        )
        self.assertLess(
            accept.index("guard responseDisposition != .terminal"),
            accept.index("promotePendingOutgoing("),
        )

        model_source = app_model.read_text(encoding="utf-8")
        self.assertGreaterEqual(
            model_source.count("outgoingCallRingDeadlineGate.permitsSubmission(for: attempt)"),
            2,
        )

    def test_expiry_rechecks_all_answer_evidence_and_uses_exact_end_path(self) -> None:
        app_model = ROOT / "KitPay/App/AppModel.swift"
        expiry = declaration_body(
            app_model,
            "    private func expireOutgoingCallRingDeadline(",
        )
        for evidence in (
            "media.presentedCallWasAnswered",
            "media.media.hasRemoteParticipant",
            "media.media.remoteParticipantConnectedAt",
            "matchingRecord?.state == .active",
            "matchingRecord?.answeredAt != nil",
        ):
            self.assertIn(evidence, expiry)
        self.assertIn("outgoingCallRingDeadlineGate.consumeExpired(", expiry)
        self.assertIn("media.requestEnd(callID: callID, lease: lease)", expiry)

        coordinator_end = declaration_body(
            ROOT / "KitPay/Core/CallMediaCoordinator.swift",
            "    func requestEnd(callID: String, lease: CallMediaAccountLease)",
        )
        self.assertIn("accountLeaseGate.accepts(lease)", coordinator_end)
        self.assertIn("activeAccountLease == lease", coordinator_end)
        self.assertIn("activeCall?.id.caseInsensitiveCompare(callID)", coordinator_end)
        self.assertIn("requestEnd()", coordinator_end)

    def test_every_local_lifecycle_exit_retires_deadline_ownership(self) -> None:
        app_model = ROOT / "KitPay/App/AppModel.swift"
        cancellation = declaration_body(
            app_model,
            "    private func cancelEphemeralOutgoingCall(",
        )
        answer = declaration_body(app_model, "    func handleCallAnswerSignal(")
        media_failure = declaration_body(app_model, "    func handleCallMediaFailure(")
        sign_out = declaration_body(app_model, "    private func performSignOut(")
        self.assertIn("cancelOutgoingCallRingDeadline(", cancellation)
        self.assertIn("cancelOutgoingCallRingDeadline(", answer)
        self.assertIn("guard media.applyCallAnswered", answer)
        self.assertIn("cancelOutgoingCallRingDeadline(", media_failure)
        self.assertIn("cancelOutgoingCallRingDeadline()", sign_out)
        model_source = app_model.read_text(encoding="utf-8")
        coordinator_source = (
            ROOT / "KitPay/Core/CallMediaCoordinator.swift"
        ).read_text(encoding="utf-8")
        self.assertIn("forName: .kitCallRemoteParticipantConnected", model_source)
        self.assertIn("name: .kitCallRemoteParticipantConnected", coordinator_source)
        self.assertIn("outgoingCallRingDeadlineTask?.cancel()", model_source)


if __name__ == "__main__":
    unittest.main()
