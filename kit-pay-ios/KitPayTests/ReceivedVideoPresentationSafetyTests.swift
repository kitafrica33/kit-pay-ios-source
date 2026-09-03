import Foundation
import XCTest
@testable import KitPay

@MainActor
final class ReceivedVideoPresentationSafetyTests: XCTestCase {
    func testCanceledFarPageCannotPublishOverItsReplacementLoad() async {
        let loader = GalleryPageLoader()
        let items = [makeItem(index: 0), makeItem(index: 1), makeItem(index: 2)]
        let firstLoad = NonCooperativeGalleryLoad()
        let replacementLoad = NonCooperativeGalleryLoad()

        loader.configure { _ in await firstLoad.value() }
        loader.ensureLoaded(items[0])
        await firstLoad.waitUntilStarted()

        loader.cancelLoadsFar(from: 2, items: items)
        guard case .idle = loader.state(for: items[0].id) else {
            return XCTFail("Moving two pages away must evict the first load")
        }

        loader.configure { _ in await replacementLoad.value() }
        loader.ensureLoaded(items[0])
        await replacementLoad.waitUntilStarted()

        // The first loader deliberately ignores task cancellation. Its late result must neither
        // replace the new request nor clear the new request's loading state.
        firstLoad.finish(byte: 1)
        await drainTasks()
        guard case .loading = loader.state(for: items[0].id) else {
            return XCTFail("A stale canceled load replaced the current page request")
        }

        replacementLoad.finish(byte: 2)
        await drainTasks()
        guard case let .loaded(loaded) = loader.state(for: items[0].id) else {
            return XCTFail("The replacement page load did not publish")
        }
        XCTAssertEqual(loaded.data, Data([2]))
        loader.cancelAllAndRelease()
    }

    func testGalleryDismissalRejectsLateLoadAndReleasesPublishedStates() async {
        let loader = GalleryPageLoader()
        let item = makeItem(index: 0)
        let pendingLoad = NonCooperativeGalleryLoad()

        loader.configure { _ in await pendingLoad.value() }
        loader.ensureLoaded(item)
        await pendingLoad.waitUntilStarted()

        loader.cancelAllAndRelease()
        XCTAssertTrue(loader.states.isEmpty)

        // Completion after dismissal cannot repopulate the off-screen StateObject with bytes or
        // a protected-original access lease.
        pendingLoad.finish(byte: 3)
        await drainTasks()
        XCTAssertTrue(loader.states.isEmpty)

        // The same StateObject remains safe if SwiftUI reuses it for a later appearance.
        loader.configure { _ in
            SecureMediaLoadPolicy.LoadedItem(
                data: Data([4]),
                mediaType: "image/jpeg",
                caption: nil
            )
        }
        loader.ensureLoaded(item)
        await drainTasks()
        guard case let .loaded(loaded) = loader.state(for: item.id) else {
            return XCTFail("The loader did not recover after dismissal cleanup")
        }
        XCTAssertEqual(loaded.data, Data([4]))
        loader.cancelAllAndRelease()
    }

    func testPageDeactivationDuringPendingPictureInPictureRetainsTeardownUntilStop() {
        var intent = ChatVideoPictureInPictureLifecycleIntent()
        intent.willStart()

        XCTAssertEqual(
            intent.terminalStopRequested(isPictureInPictureActive: false),
            .waitForTransition
        )
        XCTAssertTrue(
            ChatVideoPictureInPictureHandoffPolicy.shouldRetainTeardown(
                ownerMatches: true,
                hasController: true,
                startRequested: intent.startRequested,
                stopRequested: intent.stopRequested,
                isActive: false,
                alreadyRetained: false
            ),
            "The canonical playback file and protected-original lease must survive pending PiP"
        )

        XCTAssertTrue(intent.didStart(), "A terminal page change must stop a late PiP start")
        XCTAssertTrue(
            ChatVideoPictureInPictureHandoffPolicy.shouldRetainTeardown(
                ownerMatches: true,
                hasController: true,
                startRequested: intent.startRequested,
                stopRequested: intent.stopRequested,
                isActive: true,
                alreadyRetained: true
            )
        )
        XCTAssertTrue(intent.transitionFinished())
    }

    private func makeItem(index: Int) -> KitGalleryItem {
        KitGalleryItem(
            messageID: UUID(),
            mediaID: UUID(),
            itemIndex: nil,
            conversationID: "conversation-\(index)",
            mediaType: "video/mp4",
            plaintextByteSize: 1,
            thumbnailKey: "thumbnail-\(index)",
            isOutgoing: false,
            createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
            senderName: "Sender"
        )
    }

    private func drainTasks() async {
        for _ in 0 ..< 20 { await Task.yield() }
    }
}

@MainActor
private final class NonCooperativeGalleryLoad {
    private var continuation: CheckedContinuation<SecureMediaLoadPolicy.LoadedItem, Never>?
    private var started = false

    func value() async -> SecureMediaLoadPolicy.LoadedItem {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started = true
        }
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func finish(byte: UInt8) {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(
            returning: SecureMediaLoadPolicy.LoadedItem(
                data: Data([byte]),
                mediaType: "image/jpeg",
                caption: nil
            )
        )
    }
}
