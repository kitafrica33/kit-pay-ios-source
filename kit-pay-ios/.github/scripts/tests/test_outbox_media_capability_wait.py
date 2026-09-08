"""Run production outbox wait policy and its native XCTest cases without UIKit.

The host compiles the real command/message declarations, KITMEDIA2 batch model, policy
methods and selected native tests. A second harness executes AppModel's foreground
preparation and whole-command mutation methods with controllable transport/store/UI
stand-ins. Source checks cover both preparation paths and the coordinator's fresh
preflight. These tests do not typecheck the complete native app or exercise live transport.
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
APP_MODEL = ROOT / "KitPay/App/AppModel.swift"
POLICY = ROOT / "KitPay/Core/OutboxPolicy.swift"
MODELS = ROOT / "KitPay/Core/Models.swift"
NATIVE_TESTS = ROOT / "KitPayTests/OutboxPolicyTests.swift"


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


def production_declarations() -> str:
    models = MODELS.read_text()
    policy = POLICY.read_text()
    crypto = (ROOT / "KitPay/Core/SecureMessagingCrypto.swift").read_text()
    validation = (ROOT / "KitPay/Core/SecureMessagingSendValidation.swift").read_text()
    declarations = [HOST_STUBS]
    declarations += [declaration(models, marker) for marker in (
        "enum OfflineCommandKind:", "enum OfflineCommandFailureDisposition:",
        "struct OfflineCommand:", "enum MessageDeliveryState:",
        "struct LocalMessage:", "struct LocalPendingAttachment:",
    )]
    declarations += [declaration(crypto, marker) for marker in (
        "struct SecureMessagingOutboundEnvelope:", "struct SecureMessagingCommittedFanout:",
    )]
    declarations += [declaration(validation, "enum SecureMessagingExchangeError:"),
                     declaration(policy, "enum MessagingSendSchedulingPolicy {")]
    constants = re.findall(
        r"    static let (?:mediaMessageWaitingReason|maximumBackoffDelay|maximumServerRequestedDelay)[^\n]*", policy
    )
    if len(constants) != 3:
        raise AssertionError("The production retry and wait constants must be extracted.")
    methods = [declaration(policy, marker) for marker in (
        "static func mediaCapabilityWaitingReason(",
        "static func isMediaMessageCapabilityUnavailable(",
        "static func shouldRecheckMediaCapability(",
        "static func unmarkedMediaCapabilityWaitingIDs(",
        "static func markKnownUnavailableMediaBatches(",
        "static func clearMediaCapabilityWaitingReason(",
        "static func readyCommands(", "static func nextWakeDate(",
        "private static func orderedStreamHeads(", "static func scheduleRetry(",
    )]
    declarations += ["enum OutboxPolicy {", *constants, *methods, "}"]
    return "\n".join(declarations) + "\n"


class OutboxMediaCapabilityWaitTests(unittest.TestCase):
    def test_legacy_reason_repair_is_account_scoped_and_before_fifo_selection(self):
        source = APP_MODEL.read_text()
        flush = declaration(source, "func flushOutbox(")
        repair = declaration(flush, "if capabilities?.enablesMessagingMediaMessageV2 == false,")
        self.assertIn("unmarkedMediaCapabilityWaitingIDs(in: state", repair)
        self.assertIn("state = try await commitAuthenticatedMutation(", repair)
        for fence in ("accountEpoch: expectedAccountEpoch", "userID: expectedUserID",
                      "sessionID: expectedSessionID"):
            self.assertIn(fence, repair)
        self.assertIn("markKnownUnavailableMediaBatches(in: &persisted", repair)
        self.assertIn("catch { return }", repair)
        self.assertLess(flush.index(repair), flush.index("let commands = OutboxPolicy.readyCommands("))
        scoped = declaration(source, "private func commitAuthenticatedMutation(")
        self.assertGreaterEqual(scoped.count("outboxContextIsCurrent("), 2)
        self.assertIn("persisted.profile?.id", scoped)
        self.assertIn("persisted.communicationOwnerUserID", scoped)

    def test_both_preparation_paths_clear_and_refresh_before_exact_command_failure_handling(self):
        source = APP_MODEL.read_text()
        flush = declaration(source, "func flushOutbox(")
        foreground = declaration(source, "private func prepareOutboxMedia(")
        # This block is the inline/background preparation, following the foreground worker fork.
        background = declaration(flush, "if command.secureMessageFanout == nil {")
        for body in (foreground, background):
            denied = body[body.index("if capabilities?.enablesMessagingMediaMessageV2 == false,"):
                          body.index("if OutboxPolicy.mediaCapabilityWaitingReason(for: activeCommand) != nil {")]
            self.assertIn("!OutboxPolicy.shouldRecheckMediaCapability(for: activeCommand, at: Date())", denied)
            self.assertIn("pendingMediaBatch?.isStructurallyValid == true", denied)
            self.assertIn("throw SecureMessagingExchangeError.mediaMessageCapabilityUnavailable", denied)
            clearing = declaration(body, "if OutboxPolicy.mediaCapabilityWaitingReason(for: activeCommand) != nil {")
            self.assertIn("let waitingCommand = activeCommand", clearing)
            self.assertIn("state = try await commitOutboxMutation(", clearing)
            self.assertIn("command: waitingCommand", clearing)
            self.assertIn("clearMediaCapabilityWaitingReason(for: waitingCommand, in: &persisted)", clearing)
            self.assertIn("$0.id == waitingCommand.id && $0.kind == waitingCommand.kind", clearing)
            self.assertIn("throw CancellationError()", clearing)
            self.assertIn("activeCommand = refreshed", clearing)
            self.assertLess(body.index(denied), body.index(clearing))
            self.assertLess(body.index(clearing), body.index("SecureMessagingActivationBinding.withAuthenticatedScope("))
            self.assertIn("SecureMessagingExchangeCoordinator.shared.prepareDeferredMessage(", body)
        self.assertIn("let commandID = command.id", foreground)
        self.assertIn("commandID: commandID, forUserID: userID", foreground)
        for body in (foreground, flush):
            self.assertIn("catch is CancellationError", body)
            failure_tail = body[body.index("} catch is CancellationError"):]
            handler = failure_tail[failure_tail.index("await handleOutboxFailure("):]
            self.assertRegex(handler, r"^await handleOutboxFailure\(\s*activeCommand,")
        # Whole-value containment deliberately rejects the original command after reason clearing.
        commit = declaration(source, "private func commitOutboxMutation(")
        self.assertIn("guard persisted.outbox.contains(expectedCommand) else { throw CancellationError() }", commit)
        self.assertIn("try await commitAuthenticatedMutation(", commit)
        final_post = flush.index("SecureMessagingExchangeCoordinator.shared.sendQueuedMessage(")
        after_preparation = flush[flush.index(background) + len(background):final_post]
        self.assertIn("reloadOutboxStateIfCurrent(", after_preparation)
        self.assertIn("activeCommand = preparedCommand", after_preparation)
        self.assertIn("communicationPrivacyDecision(for: activeCommand)", after_preparation)
        self.assertIn("OutboxPolicy.readyCommands(", after_preparation)
        self.assertIn(".contains(activeCommand)", after_preparation)
        self.assertIn("ProtectedCommunicationAdmissionGate.shared.permits(", after_preparation)

    def test_due_retry_uses_fresh_authenticated_coordinator_preflight_before_upload(self):
        coordinator = (ROOT / "KitPay/Core/SecureMessagingCoordinator.swift").read_text()
        preparing = declaration(coordinator, "private func prepareDeferredMessageInCurrentScope(")
        batch = preparing[preparing.index("} else if message.pendingMediaBatch != nil {"):]
        fresh = batch.index("async let capabilitiesRequest = transport.capabilities()")
        roster = batch.index("async let rosterRequest = transport.messagingDeviceRoster(")
        admission = batch.index("guard MessagingMediaMessageV2CapabilityPolicy.admitsComposition(")
        upload = batch.index("batchUploadAndRenewal: while true")
        self.assertLess(fresh, admission)
        self.assertLess(roster, admission)
        self.assertLess(admission, upload)
        self.assertIn("throw SecureMessagingExchangeError.mediaMessageCapabilityUnavailable", batch[admission:upload])
        self.assertIn("claimMessagingScope(forUserID: local)", preparing)
        self.assertIn("try await requireExactPendingProjection(", preparing)

    def test_wait_is_retry_metadata_and_never_a_message_failure(self):
        source = APP_MODEL.read_text()
        failure = declaration(source, "private func handleOutboxFailure(")
        self.assertIn("let waitingForMediaCapability = OutboxPolicy.isMediaMessageCapabilityUnavailable(error)", failure)
        retry = failure[failure.index("case .retry("):failure.index("case .awaitSession:")]
        self.assertIn("state = try await commitOutboxMutation(", retry)
        self.assertIn("waitingForMediaCapability: waitingForMediaCapability", retry)
        self.assertNotIn("failureReason =", retry)
        policy = POLICY.read_text()
        clear = declaration(policy, "static func clearMediaCapabilityWaitingReason(")
        classify = declaration(policy, "static func markKnownUnavailableMediaBatches(")
        for mutation in (clear, classify):
            self.assertNotIn(".messages", mutation)
            self.assertNotIn("nextAttemptAt =", mutation)
            self.assertNotIn("secureMessageFanout =", mutation)
        metadata = (ROOT / "KitPay/Features/Messages/MessagesView.swift").read_text()
        self.assertEqual(metadata.count("model.outboxWaitingReason(for: message.id)"), 2)
        projection = declaration(source, "func outboxWaitingReason(for messageID:")
        self.assertIn("OutboxPolicy.mediaCapabilityWaitingReason(for: command)", projection)
        coordinator = (ROOT / "KitPay/Core/SecureMessagingCoordinator.swift").read_text()
        preparing = declaration(coordinator, "private func prepareDeferredMessageInCurrentScope(")
        self.assertIn("message.failureReason == nil", preparing)

    def test_production_policy_with_native_regressions(self):
        swiftc = os.environ.get("SWIFTC") or shutil.which("swiftc")
        if not swiftc:
            self.skipTest("A Swift compiler is needed for extracted outbox regressions.")
        native = NATIVE_TESTS.read_text()
        test_names = re.findall(r"    func (testMediaCapability\w+)\(", native) + [
            "testUnsealedUploadDoesNotDelayLaterTextOrAnotherConversation",
            "testInFlightMediaAloneDoesNotSpinImmediateWakeTimer",
            "testSealedCiphertextKeepsRetryOrderingEvenWithStaleUploadReservation",
            "testMediaReservationCannotHideCallTerminationOrScheduledWake",
            "testMessagesRemainFIFOWithinConversationAcrossRetryBackoff",
        ]
        self.assertEqual(len(test_names), 14)
        native_methods = "\n".join(declaration(native, "func " + name + "(") for name in test_names)
        helpers = "\n".join(declaration(native, marker) for marker in (
            "private func mediaCapabilityState(", "private func mediaCapabilityFanout(",
            "private func command(", "private func message(",
        ))
        registrations = ",\n".join(f'("{name}", OutboxPolicyTests.{name})' for name in test_names)
        generated = production_declarations()
        generated += "final class OutboxPolicyTests: XCTestCase, @unchecked Sendable {\n"
        generated += "private let now = Date(timeIntervalSince1970: 1_800_000_000)\n"
        generated += native_methods + "\n" + helpers + "\n}\n"
        generated += "XCTMain([testCase([\n" + registrations + "\n])])\n"
        with tempfile.TemporaryDirectory(prefix="kit-outbox-media-wait-") as directory:
            path = Path(directory)
            swift = path / "main.swift"
            swift.write_text(generated)
            binary = path / "outbox-media-wait"
            built = subprocess.run([
                swiftc, "-swift-version", "6", str(swift),
                str(ROOT / "KitPay/Core/MediaMessageV2Models.swift"), "-o", str(binary)
            ], text=True, capture_output=True, timeout=120)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            result = subprocess.run([str(binary)], text=True, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("Executed 14 tests, with 0 failures", result.stdout)

    def test_foreground_preparation_recovers_without_refreshing_cached_false(self):
        swiftc = os.environ.get("SWIFTC") or shutil.which("swiftc")
        if not swiftc:
            self.skipTest("A Swift compiler is needed for extracted AppModel regressions.")
        source = APP_MODEL.read_text()
        preparing = declaration(source, "private func prepareOutboxMedia(")
        mutation = declaration(source, "private func commitOutboxMutation(")
        failure = declaration(source, "private func handleOutboxFailure(")
        retry = failure[failure.index("case .retry("):failure.index("case .awaitSession:")]
        retry_mutation = declaration(retry, "state = try await commitOutboxMutation(")
        generated = production_declarations() + PREPARATION_STUBS
        generated += preparing + "\n" + mutation + "\n" + PREPARATION_FAILURE_PREFIX
        generated += retry_mutation + PREPARATION_FAILURE_SUFFIX + PREPARATION_CASES
        with tempfile.TemporaryDirectory(prefix="kit-outbox-capability-recovery-") as directory:
            path = Path(directory)
            swift = path / "main.swift"
            swift.write_text(generated)
            binary = path / "outbox-capability-recovery"
            built = subprocess.run([
                swiftc, "-swift-version", "6", "-parse-as-library", str(swift),
                str(ROOT / "KitPay/Core/MediaMessageV2Models.swift"), "-o", str(binary)
            ], text=True, capture_output=True, timeout=120)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            result = subprocess.run([str(binary)], text=True, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("8 foreground capability recovery scenarios passed", result.stdout)


HOST_STUBS = """
import Foundation
import XCTest

struct UserProfile { let id: String }
enum CallTerminationKind: String, Codable { case hangup }
struct ScheduledPaymentRequestPayload: Codable, Hashable {}
struct SecureMessagingRosterDevice: Codable, Hashable {}
struct LocalMediaRecord: Codable, Hashable {}
struct SecureMessagingRetainedMessageMetadata: Codable, Hashable {}
struct PersistedState {
    var profile: UserProfile?
    var outbox: [OfflineCommand] = []
    var messages: [LocalMessage] = []
    static var empty: PersistedState { PersistedState() }
}
"""


PREPARATION_STUBS = r'''
struct HostCapabilities { let enablesMessagingMediaMessageV2: Bool }
struct ProtectedCommunicationAdmissionLease {}
@MainActor final class ProtectedCommunicationAdmissionGate {
    static let shared = ProtectedCommunicationAdmissionGate()
    func permits(_ lease: ProtectedCommunicationAdmissionLease) -> Bool { true }
}
@MainActor final class UIApplication {
    enum State { case active }
    static let shared = UIApplication()
    var applicationState = State.active
}
enum LocalMediaRecordPolicy {
    static func markRetryPending(_ message: inout LocalMessage, now: Date) {}
}
@MainActor enum SecureMessagingActivationBinding {
    @TaskLocal static var generation: UUID?
    @TaskLocal static var session: String?
    static func withAuthenticatedScope(
        accountGeneration: UUID, sessionID: String,
        commitAdmission: ProtectedCommunicationAdmissionLease,
        operation: @MainActor () async throws -> Bool
    ) async throws -> Bool {
        try await $generation.withValue(accountGeneration) {
            try await $session.withValue(sessionID) { try await operation() }
        }
    }
}

// Controllable boundary for the coordinator's existing authenticated fresh preflight.
// No network, cryptography or real upload is performed by this stand-in.
@MainActor final class SecureMessagingExchangeCoordinator {
    enum Reply { case supported, unavailable, transportFailure }
    static let shared = SecureMessagingExchangeCoordinator()
    weak var model: PreparationModel?
    var reply = Reply.supported
    var suspendDiscovery = false
    var discovery: CheckedContinuation<Void, Never>?
    var discoveryCalls = 0, prepared = 0
    var observedWaitingReason: String?
    func reset(for model: PreparationModel, reply: Reply = .supported) {
        self.model = model; self.reply = reply; suspendDiscovery = false
        discovery = nil; discoveryCalls = 0; prepared = 0; observedWaitingReason = nil
    }
    func prepareDeferredMessage(commandID: UUID, forUserID userID: String) async throws -> Bool {
        guard let model,
              let generation = SecureMessagingActivationBinding.generation,
              let session = SecureMessagingActivationBinding.session,
              await model.outboxContextIsCurrent(accountEpoch: generation, userID: userID, sessionID: session),
              let command = model.persisted.outbox.first(where: { $0.id == commandID })
        else { throw CancellationError() }
        observedWaitingReason = command.lastFailureReason
        discoveryCalls += 1
        if suspendDiscovery {
            await withCheckedContinuation { discovery = $0 }
            discovery = nil
        }
        try Task.checkCancellation()
        // An old transport failure can arrive after replacement too. AppModel must fence
        // retry bookkeeping even when the transport reports a normal capability error.
        if reply == .unavailable { throw SecureMessagingExchangeError.mediaMessageCapabilityUnavailable }
        if reply == .transportFailure { throw URLError(.notConnectedToInternet) }
        guard await model.outboxContextIsCurrent(accountEpoch: generation, userID: userID, sessionID: session),
              let index = model.persisted.outbox.firstIndex(of: command)
        else { throw CancellationError() }
        model.persisted.outbox[index].secureMessageFanout = SecureMessagingCommittedFanout(
            clientMessageID: command.messageId!.uuidString.lowercased(),
            conversationID: command.conversationId!, rosterRevision: "unchanged-roster",
            replyToMessageID: nil, rosterDevices: [], envelopes: [
                .init(recipientDeviceID: "original-device", envelopeType: "message", ciphertext: Data([1, 2, 3]))
            ]
        )
        prepared += 1
        return true
    }
}

@MainActor final class PreparationModel {
    enum PrivacyDecision { case allowed }
    var state: PersistedState
    var persisted: PersistedState
    var accountEpoch = UUID(), userID = "current-user", sessionID = "original-session"
    var isOnline = true, secureMessagingReleasePermitted = true
    var isSubmittingAccountDeletion = false, messagingGroupsEnabled = true
    var capabilities: HostCapabilities? = .init(enablesMessagingMediaMessageV2: false)
    var lastError: String?
    var retryCommits = 0, rejectedRetries = 0
    init(_ state: PersistedState) { self.state = state; persisted = state }
    func communicationPrivacyDecision(for command: OfflineCommand) -> PrivacyDecision { .allowed }
    func isGroupMessagingCommand(_ command: OfflineCommand) -> Bool { false }
    func outboxContextIsCurrent(accountEpoch: UUID, userID: String, sessionID: String) async -> Bool {
        !Task.isCancelled && self.accountEpoch == accountEpoch
            && self.userID == userID && self.sessionID == sessionID
            && persisted.profile?.id == userID
    }
    func reloadOutboxStateIfCurrent(accountEpoch: UUID, userID: String, sessionID: String) async -> Bool {
        guard await outboxContextIsCurrent(accountEpoch: accountEpoch, userID: userID, sessionID: sessionID)
        else { return false }
        state = persisted
        return true
    }
    func commitAuthenticatedMutation(
        accountEpoch: UUID, userID: String, sessionID: String,
        _ mutation: (inout PersistedState) throws -> Void
    ) async throws -> PersistedState {
        guard await outboxContextIsCurrent(accountEpoch: accountEpoch, userID: userID, sessionID: sessionID)
        else { throw CancellationError() }
        try mutation(&persisted)
        return persisted
    }
    func runReadyWorker() async {
        guard let command = OutboxPolicy.readyCommands(state.outbox, at: Date()).first else { return }
        await prepareOutboxMedia(command, reportFailures: false, accountEpoch: accountEpoch,
                                 userID: userID, sessionID: sessionID, admission: .init())
    }
'''


PREPARATION_FAILURE_PREFIX = r'''
    private func handleOutboxFailure(
        _ command: OfflineCommand, error: Error, reportFailure: Bool,
        accountEpoch expectedAccountEpoch: UUID, userID expectedUserID: String,
        sessionID expectedSessionID: String
    ) async {
        guard await outboxContextIsCurrent(accountEpoch: expectedAccountEpoch,
            userID: expectedUserID, sessionID: expectedSessionID) else { return }
        let retryAfter: TimeInterval? = nil
        let waitingForMediaCapability = OutboxPolicy.isMediaMessageCapabilityUnavailable(error)
        do {
'''


PREPARATION_FAILURE_SUFFIX = r'''
            retryCommits += 1
        } catch {
            rejectedRetries += 1
        }
    }
}
'''


PREPARATION_CASES = r'''
@main struct PreparationRegression {
    @MainActor static func require(_ condition: @autoclosure () -> Bool, _ reason: String) {
        if !condition() { fatalError(reason) }
    }
    @MainActor static func fixture(priorAttempt: Bool = true) throws -> PreparationModel {
        let now = Date()
        let id = UUID(uuidString: "06000000-0000-4000-8000-000000000001")!
        let command = OfflineCommand(id: id, kind: .secureMessage, createdAt: now.addingTimeInterval(-60),
            nextAttemptAt: now.addingTimeInterval(-1), attemptCount: priorAttempt ? 1 : 0,
            conversationId: "original-conversation", messageId: id, recipientUserIds: ["original-peer"],
            lastFailureReason: OutboxPolicy.mediaMessageWaitingReason)
        var batch = try KitMediaMessageV2OutboundBatch.queued(attachments: [
            .init(attachmentID: "07000000-0000-4000-8000-000000000001", mediaType: "image/jpeg",
                plaintextByteSize: 128, localStorageKey: "08000000-0000-4000-8000-000000000001"),
            .init(attachmentID: "07000000-0000-4000-8000-000000000002", mediaType: "image/jpeg",
                plaintextByteSize: 128, localStorageKey: "08000000-0000-4000-8000-000000000002"),
        ], rawCaption: "original caption", keyMaterialFactory: { Data(repeating: 7, count: 64) })
        batch.items[0] = batch.items[0].uploaded(storageKey: "09000000-0000-4000-8000-000000000001",
            ciphertextByteSize: 192, ciphertextSHA256: String(repeating: "a", count: 64))!
        let message = LocalMessage(id: id, conversationId: command.conversationId!, senderId: "current-user",
            body: "original caption", createdAt: command.createdAt, sentAt: nil, state: .queued,
            failureReason: nil, isOutgoing: true, pendingMediaBatch: batch)
        var state = PersistedState.empty
        state.profile = .init(id: "current-user"); state.outbox = [command]; state.messages = [message]
        return PreparationModel(state)
    }
    @MainActor static func main() async throws {
        let coordinator = SecureMessagingExchangeCoordinator.shared
        // 1. First known-false denial is local and writes the ordinary bounded wait.
        let initial = try fixture(priorAttempt: false)
        let originalMessages = initial.state.messages
        coordinator.reset(for: initial)
        await initial.runReadyWorker()
        require(coordinator.discoveryCalls == 0 && coordinator.prepared == 0, "initial denial made transport work")
        require(initial.retryCommits == 1 && initial.state.outbox[0].attemptCount == 1, "initial wait was not persisted")
        require(initial.state.outbox[0].lastFailureReason == OutboxPolicy.mediaMessageWaitingReason, "missing durable wait")
        require(initial.state.messages == originalMessages, "initial denial rewrote batch/checkpoints")
        // 2. An unrelated flush before the deadline does no discovery and changes no command.
        let waiting = initial.state.outbox
        await initial.runReadyWorker()
        require(coordinator.discoveryCalls == 0 && initial.state.outbox == waiting, "future backoff performed discovery")
        // 3. Fresh support at the due retry recovers while the AppModel cache remains false.
        initial.persisted.outbox[0].nextAttemptAt = Date().addingTimeInterval(-1)
        initial.state = initial.persisted
        await initial.runReadyWorker()
        require(initial.capabilities?.enablesMessagingMediaMessageV2 == false, "test refreshed cached capability")
        require(coordinator.discoveryCalls == 1 && coordinator.prepared == 1, "cached false stranded due retry")
        require(coordinator.observedWaitingReason == nil, "preparation retained the stale wait marker")
        require(initial.state.outbox[0].secureMessageFanout != nil && initial.state.outbox[0].lastFailureReason == nil,
                "fresh support did not reach prepared state")
        require(initial.state.outbox[0].id == waiting[0].id && initial.state.outbox[0].recipientUserIds == waiting[0].recipientUserIds,
                "recovery changed retry identity or recipients")
        // 4. A fresh denial reinstates the marker under the refreshed whole-command fence.
        let denied = try fixture()
        let deniedMessages = denied.state.messages
        coordinator.reset(for: denied, reply: .unavailable)
        await denied.runReadyWorker()
        require(coordinator.discoveryCalls == 1 && coordinator.prepared == 0, "fresh denial crossed preparation gate")
        require(denied.retryCommits == 1 && denied.rejectedRetries == 0 && denied.state.outbox[0].attemptCount == 2,
                "reason clearing left a stale command in failure bookkeeping")
        require(denied.state.outbox[0].lastFailureReason == OutboxPolicy.mediaMessageWaitingReason,
                "fresh denial did not restore wait presentation")
        require(denied.state.outbox[0].nextAttemptAt > Date() && denied.state.outbox[0].nextAttemptAt <= Date().addingTimeInterval(20),
                "fresh denial did not use bounded backoff")
        require(denied.state.messages == deniedMessages, "fresh denial altered key/checkpoint state")
        await denied.runReadyWorker()
        require(coordinator.discoveryCalls == 1, "fresh denial spun an immediate retry")
        // 5. A normal transport error clears the capability label and keeps the same retry.
        let offline = try fixture()
        coordinator.reset(for: offline, reply: .transportFailure)
        await offline.runReadyWorker()
        require(offline.retryCommits == 1 && offline.rejectedRetries == 0 && offline.state.outbox[0].attemptCount == 2,
                "ordinary failure used the pre-clear command")
        require(offline.state.outbox[0].lastFailureReason == nil, "ordinary failure retained a false capability label")
        // 6. Cancellation during discovery never prepares or schedules a retry from its reply.
        let cancelled = try fixture()
        coordinator.reset(for: cancelled)
        coordinator.suspendDiscovery = true
        let cancelledTask = Task { await cancelled.runReadyWorker() }
        for _ in 0..<1000 { if coordinator.discovery != nil { break }; await Task.yield() }
        require(coordinator.discovery != nil, "cancellation fixture did not suspend discovery")
        cancelledTask.cancel()
        coordinator.discovery!.resume()
        await cancelledTask.value
        require(coordinator.prepared == 0 && cancelled.retryCommits == 0 && cancelled.rejectedRetries == 0,
                "cancelled discovery prepared or retried")
        require(cancelled.persisted.outbox[0].attemptCount == 1, "cancellation changed retry identity")
        // 7–8. A late denial from the old account/session cannot write successor state.
        for accountChanged in [true, false] {
            let replaced = try fixture()
            coordinator.reset(for: replaced, reply: .unavailable)
            coordinator.suspendDiscovery = true
            let oldTask = Task { await replaced.runReadyWorker() }
            for _ in 0..<1000 { if coordinator.discovery != nil { break }; await Task.yield() }
            require(coordinator.discovery != nil, "replacement fixture did not suspend discovery")
            if accountChanged {
                replaced.accountEpoch = UUID(); replaced.userID = "successor-user"
                replaced.persisted.profile = .init(id: "successor-user")
            } else {
                replaced.sessionID = "successor-session"
            }
            replaced.persisted.outbox[0].lastFailureReason = "successor-owned reason"
            replaced.persisted.outbox[0].recipientUserIds = ["successor-peer"]
            replaced.state = replaced.persisted
            let successorCommands = replaced.persisted.outbox, successorMessages = replaced.persisted.messages
            coordinator.discovery!.resume()
            await oldTask.value
            require(coordinator.prepared == 0 && replaced.retryCommits == 0 && replaced.rejectedRetries == 0,
                    "late old-context denial reached successor mutation")
            require(replaced.persisted.outbox == successorCommands && replaced.state.outbox == successorCommands
                    && replaced.persisted.messages == successorMessages, "late reply rewrote successor state")
        }
        print("8 foreground capability recovery scenarios passed")
    }
}
'''


if __name__ == "__main__":
    unittest.main()
