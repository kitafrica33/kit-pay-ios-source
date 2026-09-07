import ImageIO
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
    func testCameraPhotoPreparationBoundsPixelsAndDoesNotUpscaleSmallImages() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let large = UIGraphicsImageRenderer(size: CGSize(width: 4_096, height: 2_048), format: format)
            .image { context in
                UIColor.systemBlue.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 4_096, height: 2_048))
            }
        let prepared = try XCTUnwrap(AttachmentImageDecoder.secureJPEG(from: large))
        XCTAssertEqual(prepared.preview.size, CGSize(width: 2_048, height: 1_024))
        XCTAssertEqual(prepared.preview.scale, 1)
        XCTAssertLessThanOrEqual(prepared.data.count, 2 * 1_024 * 1_024)
        let small = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20), format: format)
            .image { context in
                UIColor.systemGreen.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
            }
        let smallPrepared = try XCTUnwrap(AttachmentImageDecoder.secureJPEG(from: small))
        XCTAssertEqual(smallPrepared.preview.size, CGSize(width: 40, height: 20))
        XCTAssertNil(AttachmentImageDecoder.secureJPEG(from: UIImage()))
    }

    @MainActor
    func testNormalPhotoEncodingStillStripsLocationMetadata() throws {
        let sourceImage = try XCTUnwrap(makeImage().cgImage)
        let encoded = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            encoded as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, sourceImage, [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 1.0,
                                            kCGImagePropertyGPSLatitudeRef: "N"],
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(encoded as CFData, nil))
        let originalMetadata = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertNotNil(originalMetadata[kCGImagePropertyGPSDictionary])
        let prepared = try XCTUnwrap(AttachmentImageDecoder.secureJPEG(from: encoded as Data))
        let sanitized = try XCTUnwrap(CGImageSourceCreateWithData(prepared.data as CFData, nil))
        let metadata = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(sanitized, 0, nil) as? [CFString: Any])
        XCTAssertNil(metadata[kCGImagePropertyGPSDictionary])
        XCTAssertLessThanOrEqual(prepared.data.count, 2 * 1_024 * 1_024)
    }

    @MainActor
    func testCompactPNGFileCanGrowIntoACompleteJPEGWithoutLosingPixels() async throws {
        // A 32 x 24 RGB PNG with no metadata, compressed to 93 bytes. A valid JPEG needs
        // more bytes even at its lowest quality; the former source-sized cap rejected it.
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAACAAAAAYCAIAAAAUMWhjAAAAJElEQVR4nGOQSzlBU8QwasGoBaMWjFowasGoBaMWjFowNCwAAHrE3i5WUu6cAAAAAElFTkSuQmCC"
        ))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("original.png")
        let outputURL = directory.appendingPathComponent("prepared.jpg")
        try png.write(to: sourceURL)
        let byteCount = try AttachmentImageDecoder.secureJPEGFile(
            from: sourceURL, to: outputURL,
            maximumOutputBytes: KitChatMediaLimits.imageEncodeTargetBytes
        )
        let jpeg = try Data(contentsOf: outputURL)
        let decoded = try XCTUnwrap(UIImage(data: jpeg)?.cgImage)
        XCTAssertEqual(byteCount, jpeg.count)
        XCTAssertGreaterThan(byteCount, png.count)
        XCTAssertLessThanOrEqual(byteCount, KitChatMediaLimits.imageEncodeTargetBytes)
        XCTAssertEqual(decoded.width, 32)
        XCTAssertEqual(decoded.height, 24)
        XCTAssertEqual(try Data(contentsOf: sourceURL), png)

        let job = LocalMediaPreprocessingJob(
            kind: .imageJPEG,
            sources: [.init(storageKey: UUID().uuidString.lowercased(), mediaType: "image/png",
                            fileSize: png.count, duration: nil)],
            outputStorageKey: UUID().uuidString.lowercased(), outputMediaType: "image/jpeg"
        )
        let reusable = await MediaPreprocessingPolicy.isValidPublishedOutput(at: outputURL, for: job)
        XCTAssertTrue(reusable)
        var oversized = jpeg
        oversized.append(Data(repeating: 0, count: KitChatMediaLimits.imageEncodeTargetBytes + 1 - jpeg.count))
        XCTAssertEqual(oversized.count, KitChatMediaLimits.imageEncodeTargetBytes + 1)
        try oversized.write(to: outputURL)
        let rewrittenByteCount = try Data(contentsOf: outputURL).count
        XCTAssertEqual(rewrittenByteCount, oversized.count, "the regression must replace the actual file bytes")
        print("[KitPayJPEGReuse] PNG: \(png.count); JPEG: \(jpeg.count); "
              + "allowance: \(KitChatMediaLimits.imageEncodeTargetBytes); rewritten: \(rewrittenByteCount)")
        let acceptsOversized = await MediaPreprocessingPolicy.isValidPublishedOutput(at: outputURL, for: job)
        XCTAssertFalse(acceptsOversized, "restart reuse must obey the same reserved JPEG allowance")

        let exactAllowance = Data(oversized.prefix(KitChatMediaLimits.imageEncodeTargetBytes))
        try exactAllowance.write(to: outputURL)
        XCTAssertEqual(try Data(contentsOf: outputURL).count, KitChatMediaLimits.imageEncodeTargetBytes)
        let acceptsExactAllowance = await MediaPreprocessingPolicy.isValidPublishedOutput(at: outputURL, for: job)
        XCTAssertTrue(acceptsExactAllowance, "a complete JPEG at the exact allowance must remain reusable")

        try jpeg.write(to: outputURL)
        XCTAssertEqual(try Data(contentsOf: outputURL), jpeg)
        let acceptsRestored = await MediaPreprocessingPolicy.isValidPublishedOutput(at: outputURL, for: job)
        XCTAssertTrue(acceptsRestored, "restoring valid bytes at the same URL must permit reuse again")
    }

    func testImageReservationRejectsAnAggregateThatCannotAccommodateJPEGGrowth() throws {
        let batch = try makeImageBudgetBatch(sizes: [93, 200 * 1_024 * 1_024, 56 * 1_024 * 1_024 - 1_024])
        let jobs: [LocalMediaPreprocessingJob?] = [imageBudgetJob(for: batch.items[0]), nil, nil]
        XCTAssertTrue(batch.isStructurallyValid)
        XCTAssertFalse(ImagePreprocessingBudgetPolicy.fits(batch: batch, preprocessingJobs: jobs))
        XCTAssertNil(LocalMediaRecordPolicy.queuedOutgoing(
            batch: batch, messageID: UUID(), conversationID: UUID().uuidString.lowercased(), now: Date(),
            localStorageKinds: [.protectedFile, .protectedFile, .protectedFile], preprocessingJobs: jobs
        ))
        XCTAssertEqual(batch.items[0].plaintextByteSize, 93, "reservation must not relabel original bytes")

        // A batch persisted by an older build has no reservation marker. Its authoritative
        // completion gate must still reject growth beyond the envelope without losing inputs.
        let messageID = UUID()
        let conversationID = UUID().uuidString.lowercased()
        let records = try batch.items.enumerated().map { index, item in
            try XCTUnwrap(LocalMediaRecordPolicy.queuedOutgoing(
                id: item.attachmentID, messageID: messageID, conversationID: conversationID,
                mediaType: item.mediaType, fileSize: item.plaintextByteSize,
                localStorageKey: item.localStorageKey, storesInline: false, now: Date(),
                localStorageKind: .protectedFile, originalSources: jobs[index]?.sources,
                preprocessingJob: jobs[index]
            ))
        }
        var legacy = LocalMessage(
            id: messageID, conversationId: conversationID, senderId: UUID().uuidString.lowercased(),
            body: "Photos", createdAt: Date(), sentAt: nil, state: .queued, failureReason: nil,
            isOutgoing: true, pendingMediaBatch: batch, localMediaRecords: records
        )
        XCTAssertFalse(LocalMediaRecordPolicy.completePreprocessing(
            &legacy, attachmentID: batch.items[0].attachmentID,
            expectedJob: try XCTUnwrap(jobs[0]), outputByteCount: KitChatMediaLimits.imageEncodeTargetBytes
        ))
        XCTAssertEqual(legacy.pendingMediaBatch, batch)
        XCTAssertEqual(legacy.localMediaRecords, records)
    }

    func testImageReservationIncludesTheExactEncodedCaptionBudget() throws {
        let base = try makeImageBudgetBatch(sizes: Array(repeating: 93, count: 8))
        let remaining = try XCTUnwrap(KitMediaMessageV2Descriptor.remainingEncodedCaptionBudget(
            forItems: base.placeholderDescriptorItems()
        ))
        let caption = String(repeating: "é", count: remaining / 6)
            + String(repeating: "x", count: remaining % 6)
        XCTAssertLessThanOrEqual(caption.utf8.count, KitMediaMessageV2Descriptor.maximumCaptionUTF8Bytes)
        let batch = KitMediaMessageV2OutboundBatch(items: base.items, caption: caption)
        XCTAssertTrue(batch.isStructurallyValid)
        XCTAssertFalse(ImagePreprocessingBudgetPolicy.fits(
            batch: batch, preprocessingJobs: batch.items.map { imageBudgetJob(for: $0) }
        ), "larger decimal size fields must not push a queued caption beyond its wire budget")
        XCTAssertEqual(batch.caption, caption, "reservation cannot truncate the customer's caption")
    }

    func testReservedImageJobsCanCompleteInEveryOrderAndRejectOversizedRecovery() throws {
        let batch = try makeImageBudgetBatch(sizes: [93, 128, 192])
        let jobs = batch.items.map { imageBudgetJob(for: $0) }
        XCTAssertTrue(ImagePreprocessingBudgetPolicy.fits(batch: batch, preprocessingJobs: jobs))
        for order in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]] {
            let messageID = UUID()
            let conversationID = UUID().uuidString.lowercased()
            let records = try XCTUnwrap(LocalMediaRecordPolicy.queuedOutgoing(
                batch: batch, messageID: messageID, conversationID: conversationID, now: Date(),
                localStorageKinds: [.protectedFile, .protectedFile, .protectedFile], preprocessingJobs: jobs
            ))
            var message = LocalMessage(
                id: messageID, conversationId: conversationID, senderId: UUID().uuidString.lowercased(),
                body: "Photos", createdAt: Date(), sentAt: nil, state: .queued, failureReason: nil,
                isOutgoing: true, pendingMediaBatch: batch, localMediaRecords: records
            )
            XCTAssertFalse(LocalMediaRecordPolicy.completePreprocessing(
                &message, attachmentID: batch.items[0].attachmentID, expectedJob: jobs[0],
                outputByteCount: KitChatMediaLimits.imageEncodeTargetBytes + 1
            ))
            XCTAssertEqual(message.pendingMediaBatch, batch)
            for index in order {
                XCTAssertTrue(LocalMediaRecordPolicy.completePreprocessing(
                    &message, attachmentID: batch.items[index].attachmentID, expectedJob: jobs[index],
                    outputByteCount: KitChatMediaLimits.imageEncodeTargetBytes
                ))
                XCTAssertEqual(message.pendingMediaBatch?.isStructurallyValid, true)
                XCTAssertEqual(message.localMediaRecords?[index].originalSources, jobs[index].sources)
            }
        }
    }

    private func makeImageBudgetBatch(sizes: [Int]) throws -> KitMediaMessageV2OutboundBatch {
        try KitMediaMessageV2OutboundBatch.queued(
            attachments: sizes.map { size in
                let id = UUID().uuidString.lowercased()
                return .init(attachmentID: id, mediaType: "image/jpeg", plaintextByteSize: size,
                             localStorageKey: id)
            },
            rawCaption: nil, keyMaterialFactory: { Data(repeating: 7, count: 64) }
        )
    }

    private func imageBudgetJob(for item: KitMediaMessageV2OutboundBatch.Item) -> LocalMediaPreprocessingJob {
        LocalMediaPreprocessingJob(
            kind: .imageJPEG,
            sources: [.init(storageKey: item.localStorageKey, mediaType: "image/png",
                            fileSize: item.plaintextByteSize, duration: nil)],
            outputStorageKey: UUID().uuidString.lowercased(), outputMediaType: "image/jpeg"
        )
    }

    @MainActor
    private func makeImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24)).image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        }
    }
}
