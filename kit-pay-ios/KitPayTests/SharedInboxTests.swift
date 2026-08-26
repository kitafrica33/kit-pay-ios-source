import XCTest
@testable import KitPay

/// What crosses the boundary between the system share sheet and Kit Pay.
///
/// The share extension is a separate process with its own copy of these rules, so the constants it
/// relies on are pinned here to the ones the app actually enforces. A wire change that forgot the
/// extension would otherwise only be discovered by a customer whose share went nowhere.
final class SharedInboxTests: XCTestCase {
    private let accountID = "10000000-0000-4000-8000-000000000001"
    private let otherAccountID = "20000000-0000-4000-8000-000000000002"

    // MARK: The two copies of the contract agree

    func testShareLimitsMatchTheLimitsTheAppEnforces() {
        XCTAssertEqual(
            SharedInboxPolicy.maximumBytes,
            SecureMediaAttachmentCipher.maximumPlaintextBytes,
            "A share the extension accepted must be a share the wire can carry"
        )
        XCTAssertEqual(
            SharedInboxPolicy.maximumItems,
            ConversationAttachmentStagingPolicy.maximumStagedAttachments,
            "A share the extension accepted must fit in the composer it lands in"
        )
    }

    func testShareAllowlistMatchesTheWireAllowlist() {
        XCTAssertEqual(
            SharedInboxPolicy.allowedMediaTypes,
            SecureMessagingWire.allowedAttachmentMediaTypes
        )
    }

    func testHandoffLinkUsesTheSchemeTheAppIsRegisteredFor() {
        XCTAssertEqual(KitShareHandoffLink.url?.scheme, KitDeepLink.scheme)
        XCTAssertNotNil(KitShareHandoffLink.url)
        XCTAssertTrue(KitShareHandoffLink.matches(KitShareHandoffLink.url!))
        XCTAssertTrue(KitShareHandoffLink.matches(URL(string: "KitWallet://SHARE")!))
        XCTAssertFalse(KitShareHandoffLink.matches(URL(string: "kitwallet://verify?token=x")!))
        XCTAssertFalse(KitShareHandoffLink.matches(URL(string: "https://kit.africa/share")!))
    }

    /// The hand-off must not be able to reach a pre-authentication screen, and a verification link
    /// must not be able to open the share inbox.
    func testHandoffLinkIsNotADeepLink() {
        XCTAssertNil(KitDeepLink.parse(KitShareHandoffLink.url!))
    }

    /// The app group is named in three places — this constant and both entitlement files. Locking
    /// the value here makes a rename fail in CI rather than silently in the customer's container.
    func testAppGroupIdentifierIsTheOneBothTargetsAreEntitledFor() {
        XCTAssertEqual(KitAppGroup.identifier, "group.africa.kit.pay.ios")
    }

    // MARK: What a shared file travels as

    func testKnownMediaTypesAreKeptExactly() {
        XCTAssertEqual(SharedInboxPolicy.normalizedMediaType("application/pdf"), "application/pdf")
        XCTAssertEqual(SharedInboxPolicy.normalizedMediaType("VIDEO/MP4"), "video/mp4")
        XCTAssertEqual(
            SharedInboxPolicy.normalizedMediaType("text/plain; charset=utf-8"),
            "text/plain"
        )
    }

    /// A photo straight off the camera is HEIC, which the wire does not carry — but the app
    /// re-encodes every shared image, so it stays an image here instead of being demoted to an
    /// opaque blob the recipient cannot open.
    func testCameraNativeImagesStayImages() {
        XCTAssertEqual(SharedInboxPolicy.normalizedMediaType("image/heic"), "image/heic")
        XCTAssertEqual(KitChatMediaKind(mediaType: "image/heic"), .image)
    }

    func testAnythingElseTravelsAsADocument() {
        XCTAssertEqual(
            SharedInboxPolicy.normalizedMediaType("application/x-made-up"),
            "application/octet-stream"
        )
        XCTAssertEqual(SharedInboxPolicy.normalizedMediaType(nil), "application/octet-stream")
        XCTAssertEqual(SharedInboxPolicy.normalizedMediaType("   "), "application/octet-stream")
    }

    // MARK: Names from another app are not trusted

    func testStoredNameIsOursAndKeepsOnlyTheExtension() {
        let id = UUID()
        XCTAssertEqual(
            SharedInboxPolicy.storageFileName(id: id, suggestedName: "Quarterly Report.PDF"),
            "\(id.uuidString).pdf"
        )
        XCTAssertEqual(
            SharedInboxPolicy.storageFileName(id: id, suggestedName: "../../../etc/passwd"),
            id.uuidString
        )
        XCTAssertEqual(
            SharedInboxPolicy.storageFileName(id: id, suggestedName: nil),
            id.uuidString
        )
    }

    func testAFileNameThatCouldLeaveTheBatchIsRefused() {
        XCTAssertTrue(SharedInboxPolicy.isSafeFileName("photo.jpg"))
        XCTAssertFalse(SharedInboxPolicy.isSafeFileName(""))
        XCTAssertFalse(SharedInboxPolicy.isSafeFileName(".."))
        XCTAssertFalse(SharedInboxPolicy.isSafeFileName("nested/photo.jpg"))
        XCTAssertFalse(SharedInboxPolicy.isSafeFileName("..\\photo.jpg"))
    }

    func testDisplayNameFallsBackToWhatTheFileIs() {
        XCTAssertEqual(
            SharedInboxPolicy.displayName(suggestedName: "Report.pdf", mediaType: "application/pdf"),
            "Report.pdf"
        )
        XCTAssertEqual(
            SharedInboxPolicy.displayName(suggestedName: nil, mediaType: "image/jpeg"),
            "Photo"
        )
        XCTAssertEqual(
            SharedInboxPolicy.displayName(suggestedName: "  ", mediaType: "video/mp4"),
            "Video"
        )
        XCTAssertEqual(
            SharedInboxPolicy.displayName(suggestedName: nil, mediaType: "application/zip"),
            "Document"
        )
        XCTAssertEqual(
            SharedInboxPolicy.displayName(suggestedName: "a/b:c", mediaType: "application/pdf"),
            "a-b-c",
            "A separator in a name must never read as a path"
        )
    }

    // MARK: Text

    func testSharedTextIsTrimmedAndBounded() {
        XCTAssertNil(SharedInboxPolicy.normalizedText("   \n "))
        XCTAssertNil(SharedInboxPolicy.normalizedText(nil))
        XCTAssertEqual(SharedInboxPolicy.normalizedText("  hello  "), "hello")
        let long = String(repeating: "a", count: SharedInboxPolicy.maximumTextCharacters + 500)
        XCTAssertEqual(
            SharedInboxPolicy.normalizedText(long)?.count,
            SharedInboxPolicy.maximumTextCharacters
        )
    }

    // MARK: What the picker says

    func testSummaryCountsWhatIsActuallyThere() {
        XCTAssertEqual(SharedInboxPolicy.summary(itemCount: 0, hasText: false), "Nothing to send")
        XCTAssertEqual(SharedInboxPolicy.summary(itemCount: 0, hasText: true), "Text ready to send")
        XCTAssertEqual(SharedInboxPolicy.summary(itemCount: 1, hasText: false), "1 item ready to send")
        XCTAssertEqual(
            SharedInboxPolicy.summary(itemCount: 1, hasText: true),
            "1 item and text ready to send"
        )
        XCTAssertEqual(SharedInboxPolicy.summary(itemCount: 3, hasText: false), "3 items ready to send")
        XCTAssertEqual(
            SharedInboxPolicy.summary(itemCount: 3, hasText: true),
            "3 items and text ready to send"
        )
    }

    // MARK: Nothing forgotten is kept

    func testASharedFileNobodyDeliveredIsRetired() {
        let now = Date()
        XCTAssertFalse(SharedInboxPolicy.isExpired(receivedAt: now, now: now))
        XCTAssertFalse(
            SharedInboxPolicy.isExpired(
                receivedAt: now.addingTimeInterval(-SharedInboxPolicy.retention + 60),
                now: now
            )
        )
        XCTAssertTrue(
            SharedInboxPolicy.isExpired(
                receivedAt: now.addingTimeInterval(-SharedInboxPolicy.retention),
                now: now
            )
        )
    }

    /// A device whose clock moved backwards must not turn an old share into a fresh one.
    func testAShareStampedFarInTheFutureIsAlsoRetired() {
        let now = Date()
        XCTAssertTrue(
            SharedInboxPolicy.isExpired(
                receivedAt: now.addingTimeInterval(SharedInboxPolicy.retention * 2),
                now: now
            )
        )
    }

    // MARK: The container round trip

    func testActiveAccountBindingRoundTripsAndClears() throws {
        let store = SharedInboxStore(containerURL: try makeContainer())
        XCTAssertNil(store.activeAccountID())
        XCTAssertTrue(store.setActiveAccountID(accountID.uppercased()))
        XCTAssertEqual(store.activeAccountID(), accountID)
        store.clearActiveAccount()
        XCTAssertNil(store.activeAccountID())
        XCTAssertFalse(store.setActiveAccountID("not-an-account"))
    }

    func testAStagedBatchIsReadBackExactlyAsItWasWritten() throws {
        let store = SharedInboxStore(containerURL: try makeContainer())
        let batchID = UUID()
        let item = try store.stage(
            data: Data("hello".utf8),
            suggestedName: "note.txt",
            mediaType: "text/plain",
            batchID: batchID
        )
        try store.finishBatch(
            id: batchID,
            items: [item],
            text: nil,
            ownerAccountID: accountID,
            receivedAt: Date()
        )

        let batches = store.pendingBatches(forAccountID: accountID)
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches.first?.items.count, 1)
        XCTAssertEqual(batches.first?.items.first?.displayName, "note.txt")
        XCTAssertEqual(batches.first?.items.first?.mediaType, "text/plain")
        XCTAssertEqual(try store.data(for: item, in: batchID), Data("hello".utf8))
    }

    /// The manifest is written last. A batch interrupted between copying the files and publishing
    /// them is never handed to a chat — it is cleaned up instead.
    func testABatchWithoutAManifestIsNeverDelivered() throws {
        let store = SharedInboxStore(containerURL: try makeContainer())
        let batchID = UUID()
        _ = try store.stage(
            data: Data("hello".utf8),
            suggestedName: "note.txt",
            mediaType: "text/plain",
            batchID: batchID
        )
        XCTAssertTrue(store.pendingBatches(forAccountID: accountID).isEmpty)
    }

    func testATextOnlyShareIsDeliverableWithoutAnyFiles() throws {
        let store = SharedInboxStore(containerURL: try makeContainer())
        let batchID = UUID()
        try store.finishBatch(
            id: batchID,
            items: [],
            text: "https://kit.africa",
            ownerAccountID: accountID,
            receivedAt: Date()
        )
        XCTAssertEqual(
            store.pendingBatches(forAccountID: accountID).first?.text,
            "https://kit.africa"
        )
    }

    func testAShareFromAnotherAccountIsPurgedInsteadOfDelivered() throws {
        let store = SharedInboxStore(containerURL: try makeContainer())
        let batchID = UUID()
        try store.finishBatch(
            id: batchID,
            items: [],
            text: "private to the first account",
            ownerAccountID: accountID,
            receivedAt: Date()
        )

        XCTAssertTrue(store.pendingBatches(forAccountID: otherAccountID).isEmpty)
        XCTAssertTrue(
            store.pendingBatches(forAccountID: accountID).isEmpty,
            "a cross-account batch must be destroyed, not left for a later account switch"
        )
    }

    func testAShareOfNothingIsRefused() throws {
        let store = SharedInboxStore(containerURL: try makeContainer())
        XCTAssertThrowsError(
            try store.finishBatch(
                id: UUID(),
                items: [],
                text: "   ",
                ownerAccountID: accountID,
                receivedAt: Date()
            )
        ) { error in
            XCTAssertEqual(error as? SharedInboxError, .empty)
        }
    }

    func testAnEmptyFileIsNotStaged() throws {
        let store = SharedInboxStore(containerURL: try makeContainer())
        XCTAssertThrowsError(
            try store.stage(
                data: Data(),
                suggestedName: "empty.bin",
                mediaType: nil,
                batchID: UUID()
            )
        ) { error in
            XCTAssertEqual(error as? SharedInboxError, .unreadable)
        }
    }

    func testTheSizeCapIsTheSameOnBothSidesOfTheHandoff() {
        XCTAssertFalse(SharedInboxPolicy.fits(0))
        XCTAssertTrue(SharedInboxPolicy.fits(1))
        XCTAssertTrue(SharedInboxPolicy.fits(SharedInboxPolicy.maximumBytes))
        XCTAssertFalse(SharedInboxPolicy.fits(SharedInboxPolicy.maximumBytes + 1))
        XCTAssertEqual(
            KitChatMediaLimits.fits(SharedInboxPolicy.maximumBytes, kind: .video),
            SharedInboxPolicy.fits(SharedInboxPolicy.maximumBytes)
        )
    }

    func testDeliveringABatchRemovesItsPlaintext() throws {
        let store = SharedInboxStore(containerURL: try makeContainer())
        let batchID = UUID()
        let item = try store.stage(
            data: Data("hello".utf8),
            suggestedName: "note.txt",
            mediaType: "text/plain",
            batchID: batchID
        )
        try store.finishBatch(
            id: batchID,
            items: [item],
            text: nil,
            ownerAccountID: accountID,
            receivedAt: Date()
        )
        store.remove(batchID: batchID)
        XCTAssertTrue(store.pendingBatches(forAccountID: accountID).isEmpty)
        XCTAssertThrowsError(try store.data(for: item, in: batchID))
    }

    func testStaleBatchesAreRemovedWhenTheInboxIsRead() throws {
        let store = SharedInboxStore(containerURL: try makeContainer())
        let batchID = UUID()
        let item = try store.stage(
            data: Data("hello".utf8),
            suggestedName: "note.txt",
            mediaType: "text/plain",
            batchID: batchID
        )
        try store.finishBatch(
            id: batchID,
            items: [item],
            text: nil,
            ownerAccountID: accountID,
            receivedAt: Date().addingTimeInterval(-SharedInboxPolicy.retention - 60)
        )
        XCTAssertTrue(store.pendingBatches(forAccountID: accountID).isEmpty)
        XCTAssertThrowsError(try store.data(for: item, in: batchID))
    }

    /// Two shares before the app is opened are two shares, delivered in the order they happened.
    func testBatchesComeBackOldestFirst() throws {
        let store = SharedInboxStore(containerURL: try makeContainer())
        let older = UUID()
        let newer = UUID()
        try store.finishBatch(
            id: newer,
            items: [],
            text: "second",
            ownerAccountID: accountID,
            receivedAt: Date()
        )
        try store.finishBatch(
            id: older,
            items: [],
            text: "first",
            ownerAccountID: accountID,
            receivedAt: Date().addingTimeInterval(-120)
        )
        XCTAssertEqual(
            store.pendingBatches(forAccountID: accountID).map(\.text),
            ["first", "second"]
        )
    }

    /// A manifest naming a file outside its own batch directory must not be readable, whatever put
    /// it there.
    func testAManifestCannotPointOutsideItsOwnBatch() throws {
        let store = SharedInboxStore(containerURL: try makeContainer())
        let escaping = SharedInboxItem(
            id: UUID(),
            fileName: "../manifest.json",
            mediaType: "application/octet-stream",
            displayName: "escape",
            byteCount: 12
        )
        XCTAssertThrowsError(try store.data(for: escaping, in: UUID())) { error in
            XCTAssertEqual(error as? SharedInboxError, .unreadable)
        }
    }

    func testAStagedFileWhoseSizeChangedIsNotRead() throws {
        let store = SharedInboxStore(containerURL: try makeContainer())
        let batchID = UUID()
        let item = try store.stage(
            data: Data("hello".utf8),
            suggestedName: "note.txt",
            mediaType: "text/plain",
            batchID: batchID
        )
        let fileURL = try XCTUnwrap(store.rootURL)
            .appendingPathComponent(batchID.uuidString, isDirectory: true)
            .appendingPathComponent(item.fileName, isDirectory: false)
        try Data("changed after the manifest was made".utf8).write(to: fileURL)

        XCTAssertThrowsError(try store.data(for: item, in: batchID)) { error in
            XCTAssertEqual(error as? SharedInboxError, .unreadable)
        }
    }

    func testAStagedSymlinkIsNeverFollowed() throws {
        let container = try makeContainer()
        let store = SharedInboxStore(containerURL: container)
        let batchID = UUID()
        let item = try store.stage(
            data: Data("placeholder".utf8),
            suggestedName: "note.txt",
            mediaType: "text/plain",
            batchID: batchID
        )
        let target = container.appendingPathComponent("outside.txt")
        try Data("another account's bytes".utf8).write(to: target)
        let fileURL = try XCTUnwrap(store.rootURL)
            .appendingPathComponent(batchID.uuidString, isDirectory: true)
            .appendingPathComponent(item.fileName, isDirectory: false)
        try FileManager.default.removeItem(at: fileURL)
        try FileManager.default.createSymbolicLink(at: fileURL, withDestinationURL: target)

        XCTAssertThrowsError(try store.data(for: item, in: batchID)) { error in
            XCTAssertEqual(error as? SharedInboxError, .unreadable)
        }
    }

    // MARK: Helpers

    private func makeContainer() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-inbox-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
