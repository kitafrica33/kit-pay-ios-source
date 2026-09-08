"""Exercise the actual AppModel sharing-approval lifecycle without UIKit or Apple services.

The broker's cryptographic/CAS interleavings are covered by MessagingProcessBrokerTests.
Here only that dependency is doubled; production AppModel methods and its publication gate
are extracted without changing their control flow. Native Keychain/UI testing remains required.
"""

from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]
APP_MODEL = ROOT / "KitPay/App/AppModel.swift"


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


class SharedApprovalPublicationTests(unittest.TestCase):
    def test_routine_entry_points_defer_before_failed_approval_latch(self):
        source = APP_MODEL.read_text()
        for marker in (
            "private func publishSharedDestinationsIfPossible()",
            "private func updateSharedMessagingLockState()",
            "private func revokeSharedMessagingAccessIfUnavailable()",
        ):
            body = declaration(source, marker)
            self.assertLess(body.index("deferSharedMessagingPublicationDuringApproval()"),
                            body.index("sharedMessagingAccountEligible"))
        revoke = declaration(source, "private func revokeSharedMessagingAccess()")
        self.assertLess(revoke.index("sharedMessagingApprovalPublicationGate.invalidate()"),
                        revoke.index("setSharingEnabled(false"))
        background = declaration(source, "func applicationDidEnterBackgroundSecurely()")
        self.assertIn("sharedMessagingApprovalPublicationGate.operation != nil", background)
        self.assertLess(background.index("revokeSharedMessagingAccess()"),
                        background.index("biometricAccessState = .locked"))

    def test_successful_callers_publish_after_updating_their_local_biometric_state(self):
        source = APP_MODEL.read_text()
        approve = declaration(source, "private func approveSharedMessagingAfterBiometricProof(")
        self.assertNotIn("publishSharedDestinationsIfPossible()", approve)
        self.assertEqual(source.count("await approveSharedMessagingAfterBiometricProof("), 3)
        authenticate = declaration(source, "private func authenticateBiometrically(")
        self.assertLess(authenticate.index("await approveSharedMessagingAfterBiometricProof("),
                        authenticate.index("biometricAccessState = .authorized"))
        self.assertLess(authenticate.index("biometricAccessState = .authorized"),
                        authenticate.index("publishSharedDestinationsIfPossible()"))
        unlock = declaration(source, "func unlockSessionWithBiometrics()")
        self.assertLess(unlock.index("biometricAccessState = .authorized"),
                        unlock.index("publishSharedDestinationsIfPossible()"))
        self.assertLess(unlock.index("publishSharedDestinationsIfPossible()"),
                        unlock.index("await resumeAuthenticatedSessionIfNeeded()"))

    def test_actual_appmodel_approval_lifecycle(self):
        swiftc = os.environ.get("SWIFTC") or shutil.which("swiftc")
        if not swiftc:
            self.skipTest("A Swift compiler is required for the extracted AppModel regression.")
        source = APP_MODEL.read_text()
        credential = (ROOT / "KitPay/Core/MessagingBiometricCredential.swift").read_text()
        declarations = "\n".join((
            declaration(credential, "struct MessagingBiometricBinding:"),
            declaration(source, "struct SharedMessagingApprovalPublicationGate"),
        ))
        methods = "\n".join(declaration(source, marker).replace("private ", "") for marker in (
            "private var sharedMessagingAccountSecurityEligible:",
            "private var sharedMessagingAccountEligible:",
            "private func approveSharedMessagingAfterBiometricProof(",
            "private func revokeSharedMessagingAccess()",
            "private func revokeSharedMessagingAccessIfUnavailable()",
            "private func deferSharedMessagingPublicationDuringApproval()",
            "private func updateSharedMessagingLockState()",
        ))
        generated = "import Foundation\n" + declarations + STUBS + methods + SCENARIOS
        with tempfile.TemporaryDirectory(prefix="kit-share-approval-publication-") as directory:
            root = Path(directory)
            swift = root / "main.swift"
            swift.write_text(generated)
            binary = root / "approval-publication"
            result = subprocess.run(
                [swiftc, "-swift-version", "6", "-parse-as-library", str(swift), "-o", str(binary)],
                capture_output=True, text=True, timeout=120,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("17 AppModel approval scenarios passed", result.stdout)


STUBS = r'''
final class ApprovalBarrier: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false, released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func waitForStart() async {
        await withCheckedContinuation { continuation in
            condition.lock()
            if started { condition.unlock(); continuation.resume() }
            else { waiters.append(continuation); condition.unlock() }
        }
    }
    func suspend() {
        condition.lock()
        started = true
        let pending = waiters
        waiters.removeAll()
        condition.unlock()
        pending.forEach { $0.resume() }
        condition.lock()
        while !released { condition.wait() }
        condition.unlock()
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}
struct KitBiometricAuthenticationProof: Sendable {
    let shouldFail: Bool
    var enrollmentKeyID: String { String(repeating: "a", count: 64) }
    func confirmForSharing() throws {
        if shouldFail { throw MessagingProcessBroker.Failure.proofRejected }
    }
}
final class MessagingProcessBroker: @unchecked Sendable {
    static let shared = MessagingProcessBroker()
    enum Failure: Error { case accountChanged, proofRejected }
    private let lock = NSLock()
    private var binding: MessagingBiometricBinding?
    private var barrier = ApprovalBarrier()
    private var denials = 0, approvals = 0
    var denialCount: Int { lock.withLock { denials } }
    var approvalCount: Int { lock.withLock { approvals } }
    func reset(_ value: MessagingBiometricBinding) -> ApprovalBarrier {
        lock.withLock {
            binding = value; denials = 0; approvals = 0; barrier = ApprovalBarrier()
            return barrier
        }
    }
    func replaceBinding(_ value: MessagingBiometricBinding) { lock.withLock { binding = value } }
    func biometricBinding(accountID: String, sessionID: String) throws -> MessagingBiometricBinding {
        try lock.withLock {
            guard let binding, binding.accountID == accountID, binding.sessionID == sessionID
            else { throw Failure.accountChanged }
            return binding
        }
    }
    func approveBiometricSharing(binding: MessagingBiometricBinding, enrollmentKeyID: String,
                                 confirmPrivateKey: () throws -> Void) throws {
        let original = lock.withLock { (self.binding, denials, barrier) }
        original.2.suspend()
        try Task.checkCancellation()
        try confirmPrivateKey()
        try lock.withLock {
            guard self.binding == binding, self.binding == original.0, denials == original.1
            else { throw Failure.accountChanged }
            approvals += 1
        }
    }
    func setSharingEnabled(_ enabled: Bool, accountID: String?) throws {
        precondition(!enabled, "This fixture never grants sharing")
        lock.withLock { denials += 1 }
    }
    func suspendSharingForBiometricLock(accountID: String) throws {}
}
struct TestProfile { var id: String }
@MainActor final class Model {
    var accountEpoch = UUID(), profile: TestProfile?
    var isSignedIn = true, communicationAccessGranted = true, isSigningOut = false
    var isSubmittingAccountDeletion = false, acceptedAccountDeletionCleanupBlocked = false
    var unresolvedAccountDeletionAttemptBlocked = false, protectedLocalStateRecoveryBlocked = false
    var appReviewDemoMutationsAllowed = true, secureMessagingAvailable = true
    var hasUsableCommunicationPrivacyProjection = true, requiresBiometricSignIn = true
    var accountSetupStep: Int?, biometricSharingApprovalBlockedEpoch: UUID?, biometricErrorMessage: String?
    var sharedMessagingApprovalPublicationGate = SharedMessagingApprovalPublicationGate()
    func cancelSharedMessagingPresentationWork(revokeSuggestions: Bool = true) {}
'''


SCENARIOS = r'''
}
@main struct ApprovalRegression {
    @MainActor static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError(message) }
    }
    @MainActor static func fixture() -> (Model, MessagingBiometricBinding, ApprovalBarrier) {
        let binding = MessagingBiometricBinding(generation: UUID(),
            accountID: "10000000-0000-4000-8000-000000000001",
            sessionID: "20000000-0000-4000-8000-000000000002")
        let model = Model()
        model.profile = TestProfile(id: binding.accountID)
        return (model, binding, MessagingProcessBroker.shared.reset(binding))
    }
    @MainActor static func start(_ model: Model, _ binding: MessagingBiometricBinding,
                                failProof: Bool = false) -> Task<Void, Never> {
        let epoch = model.accountEpoch
        return Task {
            await model.approveSharedMessagingAfterBiometricProof(
                KitBiometricAuthenticationProof(shouldFail: failProof),
                binding: .success(binding), accountEpoch: epoch)
        }
    }
    @MainActor static func main() async {
        let broker = MessagingProcessBroker.shared

        // 1: A deliberate fresh proof can repair a prior failed-sharing latch. Routine
        // publications/property refreshes must not manufacture another security denial.
        do {
            let (model, binding, barrier) = fixture()
            model.biometricSharingApprovalBlockedEpoch = model.accountEpoch
            let task = start(model, binding)
            await barrier.waitForStart()
            require(model.deferSharedMessagingPublicationDuringApproval(), "publication was not deferred")
            model.revokeSharedMessagingAccessIfUnavailable()
            model.updateSharedMessagingLockState()
            require(broker.denialCount == 0, "routine refresh denied its own biometric repair")
            barrier.release()
            await task.value
            require(broker.approvalCount == 1, "current proof was not accepted")
            require(model.sharedMessagingApprovalPublicationGate.operation == nil, "success leaked in-flight state")
            require(model.biometricSharingApprovalBlockedEpoch == nil, "successful repair left sharing latched")
            require(!model.deferSharedMessagingPublicationDuringApproval(), "publication did not resume")
        }

        // 2–11: Each real nonbiometric gate closes immediately even while approval is pending.
        let invalidations: [(Model) -> Void] = [
            { $0.isSignedIn = false }, { $0.accountSetupStep = 1 },
            { $0.communicationAccessGranted = false }, { $0.isSigningOut = true },
            { $0.isSubmittingAccountDeletion = true }, { $0.acceptedAccountDeletionCleanupBlocked = true },
            { $0.unresolvedAccountDeletionAttemptBlocked = true }, { $0.protectedLocalStateRecoveryBlocked = true },
            { $0.secureMessagingAvailable = false }, { $0.hasUsableCommunicationPrivacyProjection = false },
        ]
        for invalidate in invalidations {
            let (model, binding, barrier) = fixture()
            let task = start(model, binding)
            await barrier.waitForStart()
            invalidate(model)
            require(model.deferSharedMessagingPublicationDuringApproval(), "invalid publication proceeded")
            require(broker.denialCount > 0 && model.sharedMessagingApprovalPublicationGate.operation == nil,
                    "security denial was deferred")
            barrier.release()
            await task.value
            require(broker.approvalCount == 0, "invalidated proof was accepted")
            require(model.sharedMessagingApprovalPublicationGate.operation == nil, "failure leaked suppression")
        }

        // 12: An account-lifetime change rejects publication and never marks its successor blocked.
        do {
            let (model, binding, barrier) = fixture()
            let task = start(model, binding)
            await barrier.waitForStart()
            model.accountEpoch = UUID()
            require(model.deferSharedMessagingPublicationDuringApproval(), "new epoch retained old publication")
            barrier.release(); await task.value
            require(broker.approvalCount == 0 && model.biometricSharingApprovalBlockedEpoch == nil,
                    "old completion mutated a replacement account lifetime")
        }

        // 13: The same account with a replacement session is still a different authority.
        do {
            let (model, binding, barrier) = fixture()
            let task = start(model, binding)
            await barrier.waitForStart()
            broker.replaceBinding(.init(generation: UUID(), accountID: binding.accountID,
                                        sessionID: UUID().uuidString.lowercased()))
            require(model.deferSharedMessagingPublicationDuringApproval(), "session replacement was missed")
            barrier.release(); await task.value
            require(broker.approvalCount == 0 && model.sharedMessagingApprovalPublicationGate.operation == nil,
                    "replacement session accepted old approval")
        }

        // 14: Cancellation clears suppression and preserves the durable denial.
        do {
            let (model, binding, barrier) = fixture()
            let task = start(model, binding)
            await barrier.waitForStart()
            task.cancel(); barrier.release(); await task.value
            require(broker.approvalCount == 0 && broker.denialCount > 0, "cancelled approval was accepted")
            require(model.sharedMessagingApprovalPublicationGate.operation == nil, "cancellation leaked suppression")
        }

        // 15: Final private-key confirmation failure retains an actionable sharing failure.
        do {
            let (model, binding, barrier) = fixture()
            let task = start(model, binding, failProof: true)
            await barrier.waitForStart()
            barrier.release(); await task.value
            require(broker.approvalCount == 0 && model.biometricSharingApprovalBlockedEpoch == model.accountEpoch,
                    "failed confirmation did not keep sharing closed")
            require(model.biometricErrorMessage != nil && model.sharedMessagingApprovalPublicationGate.operation == nil,
                    "failed confirmation lost error or retained in-flight state")
        }

        // 16: Real background/privacy invalidation uses revoke directly, without waiting for publication.
        do {
            let (model, binding, barrier) = fixture()
            let task = start(model, binding)
            await barrier.waitForStart()
            model.revokeSharedMessagingAccess()
            require(broker.denialCount > 0 && model.sharedMessagingApprovalPublicationGate.operation == nil,
                    "explicit revocation waited for approval")
            barrier.release(); await task.value
            require(broker.approvalCount == 0, "revoked foreground proof was accepted")
        }
        // 17: Completion rechecks actual security eligibility even if no publication/property
        // callback ran. A newly stored credential alone may never clear a prior sharing denial.
        do {
            let (model, binding, barrier) = fixture()
            model.biometricSharingApprovalBlockedEpoch = model.accountEpoch
            let task = start(model, binding)
            await barrier.waitForStart()
            model.appReviewDemoMutationsAllowed = false
            barrier.release(); await task.value
            require(model.biometricSharingApprovalBlockedEpoch == model.accountEpoch && broker.denialCount > 0,
                    "completion cleared denial after an unobserved security gate change")
            require(model.sharedMessagingApprovalPublicationGate.operation == nil, "rejected completion leaked suppression")
        }
        print("17 AppModel approval scenarios passed")
    }
}
'''


if __name__ == "__main__":
    unittest.main()
