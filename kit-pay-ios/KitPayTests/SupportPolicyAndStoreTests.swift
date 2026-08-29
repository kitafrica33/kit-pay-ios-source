import Foundation
import XCTest

@testable import KitPay

/// In-memory persistence seam with switchable fault injection, so the store's verified-write,
/// verified-removal, and purge guarantees are pinned without a live Keychain.
private final class MockDraftPersistence: SupportDraftPersistence, @unchecked Sendable {
    struct Failure: Error {}

    var storage: [String: Data] = [:]
    var failData = false
    var failSet = false
    var failRemove = false
    /// Simulates the dangerous case: `remove` reports success but the record survives.
    var removeSilentlyKeepsData = false

    func data(for account: String) throws -> Data? {
        if failData { throw Failure() }
        return storage[account]
    }

    func set(_ data: Data, for account: String) throws {
        if failSet { throw Failure() }
        storage[account] = data
    }

    func remove(_ account: String) throws {
        if failRemove { throw Failure() }
        if !removeSilentlyKeepsData { storage[account] = nil }
    }
}

@MainActor
final class SupportPolicyAndStoreTests: XCTestCase {
    private let accountID = "11111111-1111-1111-1111-111111111111"
    private let ticketThread = "22222222-2222-2222-2222-222222222222"
    private let messageID = "33333333-3333-3333-3333-333333333333"

    private func makeStore() -> (SupportDraftStore, MockDraftPersistence) {
        let persistence = MockDraftPersistence()
        return (SupportDraftStore(persistence: persistence), persistence)
    }

    private func makeDraft(message: String = "I need help with a transfer.") -> SupportComposerDraft {
        SupportComposerDraft(
            accountID: accountID,
            thread: ticketThread,
            phase: .draft,
            message: message,
            clientMessageID: messageID
        )
    }

    // MARK: - Safe-close policy

    func testClosePolicyReportsNoObstacleWhenClean() {
        XCTAssertNil(
            SupportClosePolicy.obstacle(
                cleanupBlocked: false,
                pendingReplay: false,
                storageError: false,
                composerText: "",
                pendingPayment: false
            )
        )
        // Whitespace-only text is not unsent content.
        XCTAssertNil(
            SupportClosePolicy.obstacle(
                cleanupBlocked: false,
                pendingReplay: false,
                storageError: false,
                composerText: "   \n\t ",
                pendingPayment: false
            )
        )
    }

    func testClosePolicyOrdersObstaclesBySeverity() {
        // Blocked accepted-cleanup dominates everything.
        XCTAssertEqual(
            SupportClosePolicy.obstacle(
                cleanupBlocked: true,
                pendingReplay: true,
                storageError: true,
                composerText: "draft",
                pendingPayment: false
            ),
            .cleanupBlocked
        )
        // A frozen envelope resolves only by verbatim replay; it outranks storage and drafts.
        XCTAssertEqual(
            SupportClosePolicy.obstacle(
                cleanupBlocked: false,
                pendingReplay: true,
                storageError: true,
                composerText: "draft",
                pendingPayment: false
            ),
            .pendingReplay
        )
        XCTAssertEqual(
            SupportClosePolicy.obstacle(
                cleanupBlocked: false,
                pendingReplay: false,
                storageError: true,
                composerText: "draft",
                pendingPayment: false
            ),
            .storageError
        )
        XCTAssertEqual(
            SupportClosePolicy.obstacle(
                cleanupBlocked: false,
                pendingReplay: false,
                storageError: false,
                composerText: "draft",
                pendingPayment: false
            ),
            .unsentDraft
        )
    }

    func testClosePolicyCountsOverlongTextAsUnsentDraft() {
        // Text the send normalizer would reject is still content a plain close would lose.
        let overlong = String(repeating: "a", count: SupportContract.messageMaximumLength + 10)
        XCTAssertEqual(
            SupportClosePolicy.obstacle(
                cleanupBlocked: false,
                pendingReplay: false,
                storageError: false,
                composerText: overlong,
                pendingPayment: false
            ),
            .unsentDraft
        )
    }

    // MARK: - Draft store: verified writes

    func testSaveThenLoadRoundTrips() throws {
        let (store, _) = makeStore()
        let draft = makeDraft()
        try store.save(draft)
        XCTAssertEqual(try store.load(accountID: accountID, thread: ticketThread), draft)
    }

    func testSaveSurfacesPersistenceWriteFailure() {
        let (store, persistence) = makeStore()
        persistence.failSet = true
        XCTAssertThrowsError(try store.save(makeDraft())) { error in
            XCTAssertEqual(error as? SupportDraftStoreError, .unverifiedWrite)
        }
    }

    // MARK: - Draft store: verified clears (the close policy depends on these surfacing)

    func testClearOfAbsentRecordSucceeds() {
        // The autosave empty path clears repeatedly; an absent record must not be an error.
        let (store, _) = makeStore()
        XCTAssertNoThrow(try store.clear(accountID: accountID, thread: ticketThread))
    }

    func testClearSurfacesRemoveFailure() throws {
        let (store, persistence) = makeStore()
        try store.save(makeDraft())
        persistence.failRemove = true
        XCTAssertThrowsError(try store.clear(accountID: accountID, thread: ticketThread)) {
            XCTAssertEqual($0 as? SupportDraftStoreError, .unverifiedRemoval)
        }
    }

    func testClearSurfacesSilentlySurvivingRecord() throws {
        // remove() "succeeds" but the read-back still finds data: the clear is NOT verified,
        // so it must throw — a caller that discards a draft on this path would otherwise let
        // the content resurrect after the ticket is closed.
        let (store, persistence) = makeStore()
        try store.save(makeDraft())
        persistence.removeSilentlyKeepsData = true
        XCTAssertThrowsError(try store.clear(accountID: accountID, thread: ticketThread)) {
            XCTAssertEqual($0 as? SupportDraftStoreError, .unverifiedRemoval)
        }
        persistence.removeSilentlyKeepsData = false
        XCTAssertNoThrow(try store.clear(accountID: accountID, thread: ticketThread))
        XCTAssertNil(try store.load(accountID: accountID, thread: ticketThread))
    }

    func testClearRejectsInvalidNamespaces() {
        let (store, _) = makeStore()
        // The reserved index suffix and arbitrary strings can never address a record.
        XCTAssertThrowsError(
            try store.clear(accountID: accountID, thread: SupportDraftStore.indexThreadKey)
        )
        XCTAssertThrowsError(try store.clear(accountID: accountID, thread: "../escape"))
        XCTAssertThrowsError(try store.clear(accountID: "not-a-uuid", thread: ticketThread))
    }

    // MARK: - Draft store: account purge

    func testPurgeRemovesIndexedRecordsNewTicketRecordAndIndex() throws {
        let (store, persistence) = makeStore()
        try store.save(makeDraft())
        try store.save(
            SupportComposerDraft(
                accountID: accountID,
                thread: SupportDraftStore.newTicketThreadKey,
                phase: .draft,
                categoryKey: "payments",
                subject: "Transfer stuck",
                message: "It never arrived.",
                clientMessageID: messageID
            )
        )
        XCTAssertFalse(persistence.storage.isEmpty)
        try store.purgeAccount(accountID: accountID)
        XCTAssertTrue(persistence.storage.isEmpty)
    }

    func testPurgeThrowsWhenIndexUnreadable() throws {
        // An unenumerable index must keep the account-deletion cleanup blocked and retried,
        // never silently leave plaintext behind.
        let (store, persistence) = makeStore()
        try store.save(makeDraft())
        persistence.failData = true
        XCTAssertThrowsError(try store.purgeAccount(accountID: accountID))
    }
}
