import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import KitPay

final class ChatMediaSelectionTests: XCTestCase {
    @MainActor
    func testProviderPreviewNeverMakesAPendingSelectionDurable() throws {
        let id = UUID()
        let acceptedAt = Date(timeIntervalSince1970: 100)
        let pending = ChatStagedAttachment(
            preparing: id, kind: .image, displayName: "Photo", acceptedAt: acceptedAt
        )
        let visible = pending.replacingPreview(makeImage())
        XCTAssertEqual(visible.id, id)
        XCTAssertEqual(visible.acceptedAt, acceptedAt)
        XCTAssertNotNil(visible.previewImage)
        XCTAssertTrue(visible.isPreparing)
        XCTAssertNil(visible.draftMediaAttachment, "A thumbnail alone must never become sendable/restart-durable")
    }

    @MainActor
    func testRefreshingAThumbnailPreservesTheSharedBatchAndPreprocessingIdentity() throws {
        let id = UUID()
        let sharedID = UUID()
        let url = URL(fileURLWithPath: "/test/protected.heic")
        let attachment = ChatStagedAttachment(
            id: id, kind: .image, localFileURL: url, byteCount: 100,
            mediaType: "image/jpeg", displayName: "Shared photo", previewImage: nil,
            clientMessageID: sharedID, originalMediaType: "image/heic",
            preprocessingOutputStorageKey: "reserved-output"
        )
        let updated = attachment.replacingPreview(makeImage())
        XCTAssertEqual(updated.id, id)
        XCTAssertEqual(updated.localFileURL, url)
        XCTAssertEqual(updated.clientMessageID, sharedID)
        XCTAssertEqual(updated.originalMediaType, "image/heic")
        XCTAssertEqual(updated.preprocessingOutputStorageKey, "reserved-output")
        XCTAssertEqual(updated.byteCount, 100)
        XCTAssertFalse(updated.isPreparing)
    }

    @MainActor
    func testPhotoProviderImportOwnsItsBytesBeforeTheProviderSourceDisappears() async throws {
        let bytes = try XCTUnwrap(makeImage().jpegData(compressionQuality: 0.8))
        let source = try ChatMediaTempFiles.writeTemporaryFile(data: bytes, mediaType: "image/jpeg")
        defer { ChatMediaTempFiles.removeTemporaryFile(source) }
        let provider = try XCTUnwrap(NSItemProvider(contentsOf: source))
        let item = KitChatPickedItem(provider: provider)
        XCTAssertFalse(item.isVideo)
        let imported = try await item.importOriginal()
        defer {
            try? FileManager.default.removeItem(at: imported.url.deletingLastPathComponent())
        }
        XCTAssertNotEqual(imported.url, source)
        XCTAssertEqual(imported.byteCount, bytes.count)
        XCTAssertEqual(imported.mediaType, "image/jpeg")
        ChatMediaTempFiles.removeTemporaryFile(source)
        XCTAssertEqual(try Data(contentsOf: imported.url), bytes)
    }

    @MainActor
    private func makeImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24)).image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        }
    }
}
