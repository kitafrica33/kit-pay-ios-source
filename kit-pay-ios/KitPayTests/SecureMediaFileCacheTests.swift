import XCTest
@testable import KitPay

/// Behavior of the cache's atomic non-overwriting insert — the primitive `loadSecureMediaItem`
/// relies on so that (a) no download ever clobbers bytes another path already parked under a
/// storage key, and (b) a failed post-download revalidation unwinds exactly the entry this
/// call created, never one that belongs to a concurrent loader, a pending-batch park, or a
/// forward duplication.
final class SecureMediaFileCacheTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var cache: SecureMediaFileCache!
    private let userID = UUID().uuidString

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KitPayTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        cache = SecureMediaFileCache(
            directoryURL: temporaryDirectory,
            keyAccount: "kit-pay-media-cache-key-tests-\(UUID().uuidString)"
        )
    }

    override func tearDown() async throws {
        try? await cache.purge(forUserID: userID)
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        cache = nil
        temporaryDirectory = nil
    }

    func testInsertIfAbsentNeverReplacesAnExistingEntry() async throws {
        let key = UUID().uuidString
        let first = Data("first writer's plaintext".utf8)
        let second = Data("second writer's plaintext".utf8)

        let firstOutcome = await cache.insertIfAbsent(first, forStorageKey: key, userID: userID)
        XCTAssertEqual(firstOutcome, .stored)

        let secondOutcome = await cache.insertIfAbsent(second, forStorageKey: key, userID: userID)
        XCTAssertEqual(secondOutcome, .alreadyPresent)
        let survivingBytes = await cache.data(forStorageKey: key, userID: userID)
        XCTAssertEqual(
            survivingBytes,
            first,
            "an insert must never replace the copy whose creator may still be mid-revalidation"
        )

        // Byte-identical content is still not an insertion: ownership stays with the creator,
        // so a racing loader that lost the insert holds no license to unwind the entry later.
        let identicalOutcome = await cache.insertIfAbsent(first, forStorageKey: key, userID: userID)
        XCTAssertEqual(identicalOutcome, .alreadyPresent)
    }

    func testInsertOutcomeIsTheDeletionLicenseAfterAFailedRevalidation() async throws {
        let key = UUID().uuidString
        let plaintext = Data("downloaded plaintext".utf8)

        // Two loaders raced the same download; exactly one created the entry.
        let creator = await cache.insertIfAbsent(plaintext, forStorageKey: key, userID: userID)
        let racer = await cache.insertIfAbsent(plaintext, forStorageKey: key, userID: userID)
        XCTAssertEqual(creator, .stored)
        XCTAssertEqual(racer, .alreadyPresent)

        // The racer's revalidation fails. Without the `.stored` license it leaves the entry
        // alone — this is the loader's exact consumption of the outcome — and the creator's
        // copy keeps serving the row it may just have vouched for.
        if racer == .stored {
            await cache.remove(forStorageKey: key, userID: userID)
        }
        let afterRacerFailure = await cache.data(forStorageKey: key, userID: userID)
        XCTAssertEqual(afterRacerFailure, plaintext)

        // The creator's revalidation fails: it unwinds exactly the entry it created, so no
        // orphaned plaintext survives a row that no longer resolves.
        if creator == .stored {
            await cache.remove(forStorageKey: key, userID: userID)
        }
        let afterCreatorFailure = await cache.data(forStorageKey: key, userID: userID)
        XCTAssertNil(afterCreatorFailure)
    }

    func testInsertRejectsKeysAndPayloadsTheCacheMustNotHold() async throws {
        let traversal = await cache.insertIfAbsent(
            Data("escape attempt".utf8),
            forStorageKey: "../outside-the-account-directory",
            userID: userID
        )
        XCTAssertEqual(traversal, .rejected, "storage keys must be server-issued UUIDs")

        let emptyKey = UUID().uuidString
        let empty = await cache.insertIfAbsent(Data(), forStorageKey: emptyKey, userID: userID)
        XCTAssertEqual(empty, .rejected)
        let nothingStored = await cache.data(forStorageKey: emptyKey, userID: userID)
        XCTAssertNil(nothingStored, "a rejected insert must leave nothing readable behind")

        let badAccount = await cache.insertIfAbsent(
            Data("plaintext".utf8),
            forStorageKey: UUID().uuidString,
            userID: "not-a-uuid"
        )
        XCTAssertEqual(badAccount, .rejected)
    }
}
