"""Execute the share controller's initial authorization/retry boundary without UIKit.

The Swift harness extracts the production methods verbatim apart from access control and
Objective-C selectors. UI objects, broker replies and the provider work after authorization
are test doubles. It does not validate UIKit, Keychain or biometric hardware behavior.
"""

from __future__ import annotations

import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT / "KitPayShare/ShareViewController.swift"


def declaration(source: str, marker: str) -> str:
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        if source[end] == "{":
            depth += 1
        elif source[end] == "}":
            depth -= 1
        end += 1
    return source[start:end]


def host_method(source: str) -> str:
    return re.sub(r"#selector\((\w+)\)", r'"\1"', source).replace("@objc ", "").replace("private ", "")


class InitialShareAuthorizationRetryTests(unittest.TestCase):
    def test_retry_is_limited_to_initial_authorization_and_does_not_send(self):
        source = SOURCE.read_text()
        collection = declaration(source, "private func collectShare()")
        boundary = collection.index("        var items: [SharedInboxItem]")
        authorization = collection[:boundary]
        self.assertIn("try await authorizeInitialShare()", authorization)
        self.assertIn("presentInitialAuthorizationFailure(error)", authorization)
        self.assertNotIn("presentInitialAuthorizationFailure", collection[boundary:])
        self.assertEqual(source.count("presentInitialAuthorizationFailure(error)"), 1)
        self.assertIn("!Task.isCancelled, !hasFinished, !hasLeftShareSheet", authorization)
        retry = declaration(source, "@objc private func retryInitialAuthorization()")
        for forbidden in ("sendTapped", "enqueue", "DirectShareSendCoordinator", "boundedPayload", "load("):
            self.assertNotIn(forbidden, retry + authorization)
        self.assertNotIn("initialShareOwner =", retry)
        self.assertNotIn("extensionContext", retry)
        self.assertIn("!hasPresentedFailure", declaration(source, "override func viewDidAppear"))

    def test_retry_preserves_the_existing_provider_and_cancellation_boundaries(self):
        source = SOURCE.read_text()
        collection = declaration(source, "private func collectShare()")
        self.assertLess(collection.index("try await authorizeInitialShare()"), collection.index("try boundedPayload()"))
        self.assertIn("pendingShare = pending", collection)
        self.assertIn("presentPicker(for: pending)", collection)
        self.assertIn("collectionTask?.cancel()", declaration(source, "override func viewDidDisappear"))
        authorization = declaration(source, "private func authorizeInitialShare()")
        self.assertLess(authorization.index("try await MessagingProcessBroker.shared.authorizeShare()"),
                        authorization.index("try Task.checkCancellation()"))

    def test_production_authorization_and_retry_methods(self):
        swiftc = os.environ.get("SWIFTC") or shutil.which("swiftc")
        if not swiftc:
            self.skipTest("A Swift compiler is needed for the extracted controller regression.")
        source = SOURCE.read_text()
        methods = [declaration(source, marker) for marker in (
            "private struct InitialShareOwner:",
            "private func authorizeInitialShare()",
            "private func present(failure:",
            "private func presentInitialAuthorizationFailure(",
            "@objc private func retryInitialAuthorization()",
            "@objc private func cancel()",
            "private func setControlsEnabled(",
        )]
        collection = declaration(source, "private func collectShare()")
        # Keep the exact production authorization/catch/suggestion code. Provider handling
        # is a sentinel after the real boundary; no copied authorization algorithm is tested.
        collection = collection[:collection.index("        var items: [SharedInboxItem]")] + """
        providerReads += 1
        collectedInput = extensionContext?.input
        pendingShare = PendingShare()
        isCollecting = false
    }
"""
        generated = SWIFT_STUBS + "\n".join(host_method(method) for method in methods + [collection]) + SWIFT_CASES
        with tempfile.TemporaryDirectory(prefix="kit-share-initial-retry-") as directory:
            root = Path(directory)
            swift = root / "main.swift"
            swift.write_text(generated)
            binary = root / "initial-retry"
            built = subprocess.run([swiftc, "-swift-version", "6", "-parse-as-library", str(swift), "-o", str(binary)],
                                   text=True, capture_output=True, timeout=120)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            result = subprocess.run([str(binary)], text=True, capture_output=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("10 initial share retry scenarios passed", result.stdout)


SWIFT_STUBS = r'''
import Foundation

enum Color { case secondaryLabel, systemRed }
enum Event { case allEvents, touchUpInside }
struct UIImage { init(systemName: String) {} }
@MainActor final class Control {
    var isHidden = false, isEnabled = true, isUserInteractionEnabled = true, isAnimating = false
    var text: String?, textColor: Color?, tintColor: Color?, image: UIImage?
    var title = "", actions: [String] = []
    func startAnimating() { isAnimating = true }
    func stopAnimating() { isAnimating = false }
    func removeTarget(_ target: AnyObject?, action: String?, for event: Event) { actions = [] }
    func addTarget(_ target: AnyObject, action: String, for event: Event) { actions.append(action) }
}
struct INSendMessageIntent { let conversationIdentifier: String? }
@MainActor final class Context {
    var intent: Any?, input = "original caption and provider references", cancelled = false
    func cancelRequest(withError: Error) { cancelled = true }
}
typealias SharedInboxDestination = String
enum ShareSuggestions {
    static func destination(conversationIdentifier: String?, accountID: String,
                            destinations: [String]) -> String? { destinations.first { $0 == conversationIdentifier } }
}
enum SharedInboxError: LocalizedError {
    case empty
    var errorDescription: String? { "No supported items." }
}
@MainActor final class Store {
    var removed: [UUID] = []
    func remove(batchID: UUID) { removed.append(batchID) }
}
@MainActor final class MessagingProcessBroker {
    static let shared = MessagingProcessBroker()
    struct Scope: Sendable {
        let generation: UUID, accountID: String, sessionID: String, sharingGeneration: UUID
    }
    struct ApprovedDirectory: Sendable {
        let generation: UUID, accountID: String, sessionID: String, destinations: [String]
    }
    enum Failure: LocalizedError {
        case accountChanged
        var errorDescription: String? { "Sharing is locked or your account changed. Unlock Kit Pay and share again." }
    }
    var scopeValue: Scope?, reply: ApprovedDirectory?, calls = 0, suspended = false
    var continuation: CheckedContinuation<ApprovedDirectory, Error>?
    func scope() throws -> Scope { guard let scopeValue else { throw Failure.accountChanged }; return scopeValue }
    func authorizeShare() async throws -> ApprovedDirectory {
        calls += 1
        if suspended { return try await withCheckedThrowingContinuation { continuation = $0 } }
        guard let reply else { throw Failure.accountChanged }
        return reply
    }
    func reset(scope: Scope? = nil) {
        scopeValue = scope; reply = nil; calls = 0; suspended = false; continuation = nil
    }
}
@MainActor final class Controller {
    struct PendingShare {}
    let store = Store()
    let cancelButton = Control(), titleLabel = Control(), spinner = Control(), statusSymbol = Control()
    let summaryLabel = Control(), messageLabel = Control(), searchBar = Control(), tableView = Control()
    let emptyLabel = Control(), actionButton = Control(), secondaryActionButton = Control()
    var extensionContext: Context? = Context()
    var initialShareOwner: InitialShareOwner?, pendingShare: PendingShare?, batchIDBeingStaged: UUID?
    var hasInitialAuthorizationFailure = false, hasPresentedFailure = false, hasFinished = false
    var hasLeftShareSheet = false, hasPublishedBatch = false, isCommittingSend = false, isCollecting = false
    var hasRequestedDestination = false, destinations: [String] = [], filteredDestinations: [String] = []
    var requestedDestination: String?, collectionTask: Task<Void, Never>?, sendTask: Task<Void, Never>?
    var providerReads = 0, collectedInput: String?
    func configureActionButton(title: String, filled: Bool) { actionButton.title = title }
    func configureSecondaryButton(title: String) { secondaryActionButton.title = title }
'''

SWIFT_CASES = r'''
}
@main struct RetryRegression {
    @MainActor static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError(message) }
    }
    @MainActor static func main() async throws {
        let broker = MessagingProcessBroker.shared
        let generation = UUID(), sharingGeneration = UUID()
        let scope = MessagingProcessBroker.Scope(generation: generation, accountID: "account-a",
            sessionID: "session-a", sharingGeneration: sharingGeneration)
        let approved = MessagingProcessBroker.ApprovedDirectory(generation: generation, accountID: "account-a",
            sessionID: "session-a", destinations: ["updated-chat"])

        // 1: Failure alone never retries, reads providers or offers Send.
        broker.reset(scope: scope)
        let controller = Controller()
        controller.isCollecting = true
        await controller.collectShare()
        require(broker.calls == 1 && controller.providerReads == 0, "initial denial crossed provider boundary")
        require(controller.hasInitialAuthorizationFailure && controller.hasPresentedFailure, "missing retry state")
        require(controller.actionButton.title == "Retry" && controller.actionButton.actions == ["retryInitialAuthorization"], "wrong primary action")
        require(controller.secondaryActionButton.actions == ["cancel"], "Close must cancel initial input")
        require(controller.store.removed.count == 1 && controller.batchIDBeingStaged == nil, "failed staging retained")

        // 2: Explicit retry checks the broker again and cannot override hard denial.
        controller.retryInitialAuthorization()
        let deniedTask = controller.collectionTask!
        require(controller.isCollecting && !controller.hasPresentedFailure && controller.spinner.isAnimating,
                "retry did not reset collection UI")
        require(controller.actionButton.isHidden && !controller.cancelButton.isHidden && controller.cancelButton.isEnabled,
                "retry must hide actions while retaining Cancel")
        controller.retryInitialAuthorization()
        await deniedTask.value
        require(broker.calls == 2 && controller.providerReads == 0, "hard denial bypass or duplicate retry")
        require(controller.hasInitialAuthorizationFailure, "repeat denial cannot be retried")

        // 3: Fresh approval can renew sharing permission and directory for the same owner.
        broker.scopeValue = .init(generation: generation, accountID: "account-a", sessionID: "session-a", sharingGeneration: UUID())
        broker.reply = approved
        controller.retryInitialAuthorization()
        let acceptedTask = controller.collectionTask!
        await acceptedTask.value
        require(broker.calls == 3 && controller.providerReads == 1, "retry must authorize before collecting once")
        require(controller.collectedInput == controller.extensionContext?.input, "original handoff changed")
        require(controller.destinations == ["updated-chat"] && controller.pendingShare != nil, "fresh directory not used")
        require(!controller.hasPresentedFailure && !controller.hasInitialAuthorizationFailure && !controller.isCollecting,
                "failure flags remained after successful retry")
        controller.retryInitialAuthorization()
        require(broker.calls == 3, "successful collection reauthorized automatically")

        // 4–6: Captured account, session and broker generation are individually immutable.
        for changed in [
            MessagingProcessBroker.ApprovedDirectory(generation: generation, accountID: "account-b", sessionID: "session-a", destinations: []),
            MessagingProcessBroker.ApprovedDirectory(generation: generation, accountID: "account-a", sessionID: "session-b", destinations: []),
            MessagingProcessBroker.ApprovedDirectory(generation: UUID(), accountID: "account-a", sessionID: "session-a", destinations: []),
        ] {
            broker.reset(scope: scope)
            let mismatched = Controller()
            await mismatched.collectShare()
            broker.reply = changed
            mismatched.retryInitialAuthorization()
            let task = mismatched.collectionTask!
            await task.value
            require(mismatched.providerReads == 0 && mismatched.pendingShare == nil, "changed owner was accepted")
            require(mismatched.hasInitialAuthorizationFailure, "changed owner did not fail closed")
        }

        // 7–8: Cancellation or dismissal during suspended approval cannot read providers or reopen UI.
        for cancel in [true, false] {
            broker.reset(scope: scope)
            broker.suspended = true
            let dismissed = Controller()
            dismissed.isCollecting = true
            let task = Task { await dismissed.collectShare() }
            dismissed.collectionTask = task
            for _ in 0..<1000 { if broker.continuation != nil { break }; await Task.yield() }
            require(broker.continuation != nil, "authorization did not suspend")
            if cancel { dismissed.cancel() } else { dismissed.hasLeftShareSheet = true }
            broker.continuation!.resume(returning: approved)
            await task.value
            require(dismissed.providerReads == 0 && !dismissed.hasPresentedFailure, "dismissed collection resumed")
            require(!dismissed.isCollecting && dismissed.batchIDBeingStaged == nil, "dismissed staging survived")
        }

        // 9: Provider/content errors retain Close only and cannot enter the authorization retry path.
        broker.reset(scope: scope)
        let invalid = Controller()
        invalid.hasInitialAuthorizationFailure = true
        invalid.present(failure: "Invalid provider content")
        invalid.retryInitialAuthorization()
        require(broker.calls == 0 && invalid.collectionTask == nil, "content failure triggered authorization retry")
        require(invalid.actionButton.title == "Close" && invalid.actionButton.actions == ["cancel"], "content failure offered retry")
        // 10: A locked first attempt may have no readable scope. Fresh approval establishes
        // the first owner without reading or replacing the host's original input early.
        broker.reset()
        let locked = Controller()
        await locked.collectShare()
        require(locked.initialShareOwner == nil && locked.providerReads == 0, "locked attempt captured unauthorized input")
        broker.reply = approved
        locked.retryInitialAuthorization()
        let unlockedTask = locked.collectionTask!
        await unlockedTask.value
        require(broker.calls == 2 && locked.providerReads == 1, "locked initial failure could not recover explicitly")
        require(locked.initialShareOwner?.accountID == "account-a" && locked.initialShareOwner?.sessionID == "session-a",
                "fresh approved owner was not retained")
        print("10 initial share retry scenarios passed")
    }
}
'''


if __name__ == "__main__":
    unittest.main()
