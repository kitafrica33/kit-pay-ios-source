"""Run the production picker request/import ownership and composer removal without UIKit.

Native ChatMediaImportCancellationTests additionally exercise an actual NSItemProvider.
This host regression substitutes provider delivery and the composer's persistence callback;
the cancellation bridge, generation state and removal method are extracted unchanged.
"""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]
PICKER = ROOT / "KitPay/Features/Messages/KitChatMediaPicker.swift"
VIEW = ROOT / "KitPay/Features/Messages/MessagesView.swift"


def declaration(source: str, marker: str) -> str:
    start = source.index(marker)
    end = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


class ChatPickerCancellationTests(unittest.TestCase):
    def test_picker_and_lifecycle_keep_the_runtime_ownership_checks(self):
        picker, view = PICKER.read_text(), VIEW.read_text()
        original = declaration(picker, "func importOriginal()")
        self.assertIn("originalRequest.isPending", original)
        self.assertIn("if !originalRequest.finish(.success", original)
        self.assertIn("destination.deletingLastPathComponent()", original)
        self.assertIn("return nil", declaration(picker, "func preview()"))
        self.assertIn("libraryImportState.begin(", view)
        self.assertIn("item.cancelImport()", view)
        worker = declaration(view, "private func importPickedLibraryItem(")
        self.assertIn("libraryImportState.finish(item.id, generation: generation)", worker)
        self.assertGreaterEqual(worker.count("composerAccountIsCurrent"), 4)
        self.assertGreaterEqual(worker.count("generation == attachmentLoadGeneration"), 4)
        self.assertIn("stagedAttachments.contains(where: { $0.id == item.id })", worker)
        disappearance = declaration(view, "private func handleConversationDisappearance()")
        self.assertIn("!composerAccountIsCurrent || shouldRetireAttachmentImportsOnDisappear", disappearance)
        self.assertLess(disappearance.index("libraryImportState.retire()"),
                        disappearance.index("attachmentLoadGeneration &+= 1"))

    def test_production_cancellation_and_composer_removal(self):
        swiftc = os.environ.get("SWIFTC") or shutil.which("swiftc")
        if not swiftc:
            self.skipTest("A Swift compiler is needed for the picker cancellation runtime regression.")
        picker, view = PICKER.read_text(), VIEW.read_text()
        helpers = "\n".join(declaration(picker, marker) for marker in (
            "final class KitChatProviderRequest<", "struct KitChatLibraryImportState",
        ))
        remove = declaration(view, "private func removeStagedAttachment(").replace("private func", "func", 1)
        source = "import Foundation\n" + helpers + STUBS + remove + CASES
        with tempfile.TemporaryDirectory(prefix="kit-chat-picker-cancellation-") as directory:
            swift = Path(directory) / "main.swift"
            binary = Path(directory) / "regression"
            swift.write_text(source)
            build = subprocess.run([swiftc, "-swift-version", "6", "-parse-as-library", str(swift), "-o", str(binary)],
                                   capture_output=True, text=True, timeout=120)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("8 picker cancellation scenarios and 100 completion races passed", result.stdout)


STUBS = r'''
struct StagedAttachment { let id: UUID }
@MainActor final class Composer {
    var isSending = false, isPreparingMediaEdit = false, isLoadingAttachment = true
    var attachmentLoadGeneration = 1
    var libraryImportState = KitChatLibraryImportState()
    var documentImportID: UUID?
    var stagedAttachments: [StagedAttachment] = []
    var removedFromManifest: [UUID] = []
    func persistDraftImmediately(removingMediaIDsAfterSuccess ids: [UUID]) { removedFromManifest += ids }
'''

CASES = r'''
}
final class Started: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func mark() { lock.withLock { value = true } }
    var ready: Bool { lock.withLock { value } }
}
@main struct PickerCancellationRegression {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError(message) }
    }
    @MainActor static func main() async throws {
        // 1: Execute the real removal method with one durable photo and one stalled provider.
        let composer = Composer(), readyID = UUID(), stalledID = UUID()
        let stalled = KitChatProviderRequest<Int>(), started = Started()
        let progress = Progress(totalUnitCount: 1)
        composer.stagedAttachments = [.init(id: readyID), .init(id: stalledID)]
        composer.libraryImportState.begin(generation: 1, cancellations: [stalledID: { stalled.cancel() }])
        let waiter = Task { () -> Bool in
            do { _ = try await stalled.load { started.mark(); return progress }; return false }
            catch { return error is CancellationError }
        }
        for _ in 0..<1000 { if started.ready { break }; await Task.yield() }
        require(started.ready, "provider did not start")
        composer.removeStagedAttachment(stalledID)
        require(!composer.isLoadingAttachment, "removing the stalled item left the + menu and Send busy")
        require(composer.stagedAttachments.map(\.id) == [readyID], "ready photo was removed")
        require(composer.removedFromManifest == [stalledID], "wrong recovery manifest removal")
        require(composer.attachmentLoadGeneration == 1, "remaining wanted attachments lost their generation")
        let wasCancelled = await waiter.value
        require(wasCancelled && progress.isCancelled, "provider waiter required a callback to cancel")

        // 2: A successor remains busy when the cancelled old worker finally completes.
        composer.attachmentLoadGeneration = 2
        let successor = KitChatProviderRequest<Int>()
        composer.libraryImportState.begin(generation: 2, cancellations: [stalledID: { successor.cancel() }])
        composer.isLoadingAttachment = true
        require(!composer.libraryImportState.finish(stalledID, generation: 1), "old completion owned successor")
        require(composer.isLoadingAttachment && composer.libraryImportState.isLoading && successor.isPending,
                "old callback cleared or cancelled successor")
        require(!stalled.finish(.success(7)), "late success must be rejected so callback disposes its file")
        composer.libraryImportState.retire()

        // 3: Remove one of two pending items without stopping the wanted item.
        let removedID = UUID(), keptID = UUID()
        let removed = KitChatProviderRequest<Int>(), kept = KitChatProviderRequest<Int>()
        composer.attachmentLoadGeneration = 3
        composer.stagedAttachments = [.init(id: readyID), .init(id: removedID), .init(id: keptID)]
        composer.libraryImportState.begin(generation: 3, cancellations: [
            removedID: { removed.cancel() }, keptID: { kept.cancel() },
        ])
        composer.removeStagedAttachment(removedID)
        require(composer.isLoadingAttachment && kept.isPending && !removed.isPending,
                "removal cancelled another wanted import")
        composer.removeStagedAttachment(keptID)
        require(!composer.isLoadingAttachment && composer.stagedAttachments.map(\.id) == [readyID],
                "last pending removal did not release the ready photo")

        // 4: A removed queued item cannot start a provider later; retirement revokes all work.
        let retired = KitChatProviderRequest<Int>()
        composer.libraryImportState.begin(generation: 4, cancellations: [stalledID: { retired.cancel() }])
        composer.libraryImportState.retire()
        do { _ = try await retired.load { fatalError("removed queued provider was started") }
             fatalError("retired provider accepted") }
        catch { require(error is CancellationError, "wrong retirement result") }
        require(!composer.libraryImportState.finish(stalledID, generation: 4), "retired completion accepted")

        // 5: Cancellation between waiter registration and returned Progress still cancels it.
        let during = KitChatProviderRequest<Int>(), duringProgress = Progress(totalUnitCount: 1)
        do { _ = try await during.load { during.cancel(); return duringProgress }
             fatalError("registration cancellation accepted") }
        catch { require(error is CancellationError, "wrong cancellation result") }
        require(duringProgress.isCancelled && !during.finish(.success(1)), "late Progress/result escaped cancellation")

        // 6: A preview-style API with no Progress still releases on task cancellation.
        let preview = KitChatProviderRequest<Int>(), previewStarted = Started()
        let previewWaiter = Task { () -> Bool in
            do { _ = try await preview.load { previewStarted.mark(); return nil }; return false }
            catch { return error is CancellationError }
        }
        for _ in 0..<1000 { if previewStarted.ready { break }; await Task.yield() }
        require(previewStarted.ready, "preview did not start")
        previewWaiter.cancel()
        let previewCancelled = await previewWaiter.value
        require(previewCancelled && !preview.finish(.success(1)), "preview cancellation needed callback")

        // 7: Success wins exactly once, including a synchronous provider callback.
        let completed = KitChatProviderRequest<Int>(), completedProgress = Progress(totalUnitCount: 1)
        let value = try await completed.load {
            require(completed.finish(.success(7)), "first completion lost")
            return completedProgress
        }
        require(value == 7 && !completed.finish(.success(8)), "duplicate provider callback accepted")
        completed.cancel()
        require(!completedProgress.isCancelled, "completed result was revoked")

        // 8: A Files import has no NSItemProvider cancellation object. Removing just that
        // pending document must still release Send/+ and invalidate its eventual copy callback.
        let documentComposer = Composer(), documentID = UUID()
        documentComposer.documentImportID = documentID
        documentComposer.stagedAttachments = [.init(id: readyID), .init(id: documentID)]
        let originalDocumentGeneration = documentComposer.attachmentLoadGeneration
        documentComposer.removeStagedAttachment(UUID())
        require(documentComposer.isLoadingAttachment && documentComposer.documentImportID == documentID,
                "removing an unrelated item released the pending document")
        documentComposer.removeStagedAttachment(documentID)
        require(!documentComposer.isLoadingAttachment && documentComposer.documentImportID == nil,
                "removed Files import left the composer busy")
        require(documentComposer.stagedAttachments.map(\.id) == [readyID], "Files removal discarded the ready photo")
        require(documentComposer.removedFromManifest == [documentID], "Files removal changed the wrong draft entry")
        require(documentComposer.attachmentLoadGeneration != originalDocumentGeneration,
                "removed document copy kept authority over subsequent imports")
        let successorDocumentRequest = KitChatProviderRequest<Int>()
        documentComposer.isLoadingAttachment = true
        documentComposer.libraryImportState.begin(
            generation: documentComposer.attachmentLoadGeneration,
            cancellations: [keptID: { successorDocumentRequest.cancel() }]
        )
        documentComposer.removeStagedAttachment(documentID)
        require(documentComposer.isLoadingAttachment && documentComposer.libraryImportState.isLoading
                && successorDocumentRequest.isPending,
                "duplicate document removal cleared the successor's import")
        documentComposer.libraryImportState.retire()

        // Race the real lock/continuation implementation, not a copy of its state machine.
        for _ in 0..<100 {
            let request = KitChatProviderRequest<Int>(), began = Started()
            let result = Task { () -> Bool in
                do {
                    let value = try await request.load { began.mark(); return Progress(totalUnitCount: 1) }
                    return value == 7
                } catch { return error is CancellationError }
            }
            for _ in 0..<1000 { if began.ready { break }; await Task.yield() }
            require(began.ready, "race request did not start")
            async let finish: Bool = Task.detached { request.finish(.success(7)) }.value
            async let cancel: Void = Task.detached { request.cancel() }.value
            _ = await (finish, cancel)
            let valid = await result.value
            require(valid, "completion/cancellation race returned invalid result")
        }
        print("8 picker cancellation scenarios and 100 completion races passed")
    }
}
'''


if __name__ == "__main__":
    unittest.main()
