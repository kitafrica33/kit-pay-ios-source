import XCTest
import AVFoundation
import UIKit
@testable import KitPay

final class ChatMediaPolicyTests: XCTestCase {
    private func makeDescriptor(
        mediaType: String,
        plaintextByteSize: Int = 4_000,
        caption: String? = nil
    ) throws -> KitMediaMessageDescriptor {
        try KitMediaMessageDescriptor(
            attachmentID: "0a1b2c3d-0000-4000-8000-000000000001",
            storageKey: "0a1b2c3d-0000-4000-8000-000000000002",
            mediaType: mediaType,
            ciphertextByteSize: Int64(plaintextByteSize) + 64,
            ciphertextSHA256: String(repeating: "ab", count: 32),
            keyMaterial: Data(repeating: 7, count: SecureMediaAttachmentCipher.keyMaterialBytes),
            plaintextByteSize: plaintextByteSize,
            caption: caption
        )
    }

    func testEditableVideoSourceBoundIsADiskGuardAboveTheWireCap() {
        XCTAssertTrue(ConversationAttachmentStagingPolicy.editableVideoSource(byteCount: 1))
        XCTAssertTrue(
            ConversationAttachmentStagingPolicy.editableVideoSource(
                byteCount: ConversationAttachmentStagingPolicy.maximumEditableVideoSourceBytes
            )
        )
        XCTAssertFalse(
            ConversationAttachmentStagingPolicy.editableVideoSource(
                byteCount: ConversationAttachmentStagingPolicy.maximumEditableVideoSourceBytes + 1
            )
        )
        XCTAssertFalse(ConversationAttachmentStagingPolicy.editableVideoSource(byteCount: 0))
        // The trim editor may accept a source the wire would refuse whole — trimming is the
        // remedy — so the source bound must sit strictly above the transfer cap.
        XCTAssertGreaterThan(
            ConversationAttachmentStagingPolicy.maximumEditableVideoSourceBytes,
            Int64(SecureMediaAttachmentCipher.maximumPlaintextBytes)
        )
    }

    func testMediaKindClassificationFollowsMIMEPrefix() {
        XCTAssertEqual(KitChatMediaKind(mediaType: "image/jpeg"), .image)
        XCTAssertEqual(KitChatMediaKind(mediaType: "IMAGE/PNG"), .image)
        XCTAssertEqual(KitChatMediaKind(mediaType: "audio/mp4"), .voice)
        XCTAssertEqual(KitChatMediaKind(mediaType: "AUDIO/MP4"), .voice)
        XCTAssertEqual(KitChatMediaKind(mediaType: "audio/aac"), .audio)
        XCTAssertEqual(KitChatMediaKind(mediaType: "audio/mpeg"), .audio)
        XCTAssertEqual(KitChatMediaKind(mediaType: "audio/ogg"), .audio)
        XCTAssertEqual(KitChatMediaKind(mediaType: "video/quicktime"), .video)
        XCTAssertEqual(KitChatMediaKind(mediaType: "application/pdf"), .document)
        XCTAssertEqual(KitChatMediaKind(mediaType: "something/unknown"), .document)
    }

    func testLocalVideoOriginalMayExceedWireLimitOnlyWithinEditorGuard() {
        let aboveWireLimit = KitChatMediaLimits.maximumTransferBytes + 1
        XCTAssertTrue(KitChatMediaLimits.fitsLocalOriginal(
            byteCount: aboveWireLimit,
            mediaType: "VIDEO/QUICKTIME"
        ))
        XCTAssertFalse(KitChatMediaLimits.fits(aboveWireLimit, kind: .video))
        XCTAssertFalse(KitChatMediaLimits.fitsLocalOriginal(
            byteCount: aboveWireLimit,
            mediaType: "application/pdf"
        ))
        XCTAssertFalse(KitChatMediaLimits.fitsLocalOriginal(
            byteCount: KitChatMediaLimits.maximumEditableLocalVideoBytes + 1,
            mediaType: "video/mp4"
        ))
    }

    func testCaptureTempCleanupRemovesOnlyOwnedCameraAndEditorEntries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kit-capture-cleanup-test-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let camera = root.appendingPathComponent("kit-camera-abandoned", isDirectory: true)
        let editor = root.appendingPathComponent("kit-trim-abandoned", isDirectory: true)
        let unrelated = root.appendingPathComponent("other-app-data", isDirectory: true)
        for directory in [camera, editor, unrelated] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: directory.appendingPathComponent("clip.mov"))
        }

        KitCaptureTemporaryFileStore.removeAbandonedFiles(in: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: camera.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: editor.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testPreviewFileUsesProtectionThatRemainsReadableOnlyWhileAlreadyOpen() throws {
        XCTAssertEqual(
            ChatMediaTempFiles.previewFileWritingOptions,
            [.atomic, .completeFileProtectionUnlessOpen]
        )

        let url = try ChatMediaTempFiles.writeTemporaryFile(
            data: Data([1, 2, 3]),
            mediaType: "video/mp4"
        )
        defer { ChatMediaTempFiles.removeTemporaryFile(url) }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
#if targetEnvironment(simulator)
        // Simulator files live on the host filesystem, which may omit NSFileProtectionKey.
        // If the runtime does expose it, it must still agree with the production policy above.
        if let protection = attributes[.protectionKey] as? FileProtectionType {
            XCTAssertEqual(protection, .completeUnlessOpen)
        }
#else
        XCTAssertEqual(
            attributes[.protectionKey] as? FileProtectionType,
            .completeUnlessOpen
        )
#endif
    }

    func testTransferLimitIsTwoHundredMebibytes() {
        XCTAssertEqual(SecureMediaAttachmentCipher.maximumPlaintextBytes, 200 * 1_024 * 1_024)
        XCTAssertEqual(
            SecureMessagingWire.maximumAttachmentCiphertextBytes,
            Int64(200 * 1_024 * 1_024 + 64)
        )
        XCTAssertTrue(KitChatMediaLimits.fits(200 * 1_024 * 1_024, kind: .video))
        XCTAssertFalse(KitChatMediaLimits.fits(200 * 1_024 * 1_024 + 1, kind: .video))
        XCTAssertFalse(KitChatMediaLimits.fits(0, kind: .document))
    }

    func testNestedServerCapabilityEnablesTheExactBoundedIOSProfile() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "api_version": "v1",
            "currency": ["code": "UGX", "scale": "2"],
            "features": ["messaging_rich_media": true],
            "protocols": [
                "messaging": [
                    "ready": true,
                    "version": SecureMessagingWire.protocolVersion,
                    "suite": SecureMessagingWire.protocolSuite,
                    "post_quantum": true,
                    "rich_media": [
                        "ready": true,
                        "profile": MessagingRichMediaCapabilityPolicy.profile,
                        "supported_platforms": ["ios"],
                        "minimum_ios_version": MessagingRichMediaCapabilityPolicy.minimumIOSRelease,
                        "minimum_ciphertext_bytes": SecureMessagingWire.minimumAttachmentCiphertextBytes,
                        "maximum_plaintext_bytes": SecureMediaAttachmentCipher.maximumPlaintextBytes,
                        "maximum_ciphertext_bytes": SecureMessagingWire.maximumAttachmentCiphertextBytes,
                        "large_attachment_capability": MessagingRichMediaCapabilityPolicy
                            .extendedSizeDeviceCapabilityKey,
                        "large_attachment_supported_platforms": ["ios"],
                        "large_attachment_minimum_ios_version": MessagingRichMediaCapabilityPolicy
                            .extendedSizeMinimumIOSRelease,
                        "media_types": SecureMessagingWire.allowedAttachmentMediaTypes.sorted(),
                    ],
                ],
            ],
        ])
        let decoded = try JSONDecoder().decode(CapabilitiesDTO.self, from: data)
        XCTAssertTrue(decoded.enablesMessagingRichMedia)
        XCTAssertEqual(
            MessagingRichMediaCapabilityPolicy.extendedSizeMinimumIOSRelease,
            "1.0.16-r24"
        )
    }

    func testNestedServerCapabilityRejectsARegressiveLargeAttachmentIOSFloor() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "api_version": "v1",
            "currency": ["code": "UGX", "scale": "2"],
            "protocols": [
                "messaging": [
                    "ready": true,
                    "version": SecureMessagingWire.protocolVersion,
                    "suite": SecureMessagingWire.protocolSuite,
                    "post_quantum": true,
                    "rich_media": [
                        "ready": true,
                        "profile": MessagingRichMediaCapabilityPolicy.profile,
                        "supported_platforms": ["ios"],
                        "minimum_ios_version": MessagingRichMediaCapabilityPolicy.minimumIOSRelease,
                        "minimum_ciphertext_bytes": SecureMessagingWire.minimumAttachmentCiphertextBytes,
                        "maximum_plaintext_bytes": SecureMediaAttachmentCipher.maximumPlaintextBytes,
                        "maximum_ciphertext_bytes": SecureMessagingWire.maximumAttachmentCiphertextBytes,
                        "large_attachment_capability": MessagingRichMediaCapabilityPolicy
                            .extendedSizeDeviceCapabilityKey,
                        "large_attachment_supported_platforms": ["ios"],
                        "large_attachment_minimum_ios_version": "1.0.15-r23",
                        "media_types": SecureMessagingWire.allowedAttachmentMediaTypes.sorted(),
                    ],
                ],
            ],
        ])

        let decoded = try JSONDecoder().decode(CapabilitiesDTO.self, from: data)
        XCTAssertFalse(decoded.enablesMessagingRichMedia)
    }

    func testLegacyFlatFeatureCannotEnableRichMedia() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "currency": ["code": "UGX", "scale": "2"],
            "features": ["messaging_rich_media": true],
        ])
        let decoded = try JSONDecoder().decode(CapabilitiesDTO.self, from: data)
        XCTAssertFalse(decoded.enablesMessagingRichMedia)
    }

    func testRichMediaRosterTrustsTheServerCapabilityWithAnIOSVersionFloor() throws {
        XCTAssertFalse(try rosterSupports(version: "0.2.5", build: nil))
        XCTAssertFalse(try rosterSupports(version: "0.2.5", build: 15))
        XCTAssertTrue(try rosterSupports(version: "0.2.5", build: 16))
        XCTAssertTrue(try rosterSupports(version: "0.2.5", build: 29))
        XCTAssertTrue(try rosterSupports(version: "0.2.6", build: nil))
        XCTAssertFalse(try rosterSupports(version: "0.2.4", build: 999))
        // Non-iOS recipients ride the server-attested capability flag: the backend only
        // asserts it for Android 0.2.18+ where the shared kit-media-v1 wire is implemented.
        XCTAssertTrue(try rosterSupports(version: "0.2.18", build: nil, platform: "android"))
        XCTAssertTrue(try rosterSupports(version: "0.2.5", build: 16, platform: "android"))
        XCTAssertFalse(try rosterSupports(version: "0.2.18", build: nil, platform: "android", capable: false))
        XCTAssertFalse(try rosterSupports(version: "0.2.5", build: 16, capable: false))
    }

    func testInlineCachePolicyKeepsOnlySmallBlobsInline() {
        XCTAssertTrue(
            KitChatMediaLimits.shouldCacheInline(byteCount: KitChatMediaLimits.maximumInlineCacheBytes)
        )
        XCTAssertFalse(
            KitChatMediaLimits.shouldCacheInline(
                byteCount: KitChatMediaLimits.maximumInlineCacheBytes + 1
            )
        )
        XCTAssertFalse(KitChatMediaLimits.shouldCacheInline(byteCount: 0))
    }

    func testNewMediaTypesAreAllowedOnTheWire() {
        for mediaType in [
            "audio/mp4", "video/mp4", "video/quicktime",
            "application/pdf", "application/octet-stream",
        ] {
            XCTAssertTrue(
                SecureMessagingWire.allowedAttachmentMediaTypes.contains(mediaType),
                "expected \(mediaType) to be allowed"
            )
        }
    }

    func testDescriptorRoundTripsForVoiceVideoAndDocumentTypes() throws {
        for mediaType in ["audio/mp4", "video/quicktime", "application/pdf"] {
            let descriptor = try makeDescriptor(mediaType: mediaType, caption: "Report 2026.pdf")
            let parsed = KitMediaMessageDescriptor.parse(descriptor.encoded)
            XCTAssertEqual(parsed, descriptor, "round trip failed for \(mediaType)")
        }
    }

    func testDescriptorRejectsPlaintextAboveTransferLimit() {
        XCTAssertThrowsError(
            try makeDescriptor(
                mediaType: "video/mp4",
                plaintextByteSize: SecureMediaAttachmentCipher.maximumPlaintextBytes + 1
            )
        )
    }

    func testPreviewTextDescribesMediaKindsAndCaptions() throws {
        XCTAssertEqual(KitChatMessagePreview.text(for: "hello there"), "hello there")

        let voice = try makeDescriptor(mediaType: "audio/mp4")
        XCTAssertEqual(KitChatMessagePreview.text(for: voice.encoded), "Voice note")
        XCTAssertEqual(KitChatMessagePreview.symbolName(for: voice.encoded), "mic.fill")

        let document = try makeDescriptor(mediaType: "application/pdf", caption: "Report.pdf")
        XCTAssertEqual(KitChatMessagePreview.text(for: document.encoded), "Document · Report.pdf")

        XCTAssertNil(KitChatMessagePreview.symbolName(for: "plain text"))
    }

    func testLocalMediaRecordKeepsPermanentIdentityAndOriginalAcrossUpload() throws {
        let messageID = UUID()
        let conversationID = UUID().uuidString.lowercased()
        let mediaID = UUID().uuidString.lowercased()
        let remoteKey = UUID().uuidString.lowercased()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let outboundKey = Data(
            (0..<SecureMediaAttachmentCipher.keyMaterialBytes).map(UInt8.init)
        )
        guard let record = LocalMediaRecordPolicy.queuedOutgoing(
            id: mediaID,
            messageID: messageID,
            conversationID: conversationID,
            mediaType: "video/mp4",
            fileSize: 8_192,
            duration: 10,
            localStorageKey: mediaID,
            storesInline: false,
            now: createdAt,
            outboundKeyMaterial: outboundKey
        ) else { return XCTFail("valid local media record") }
        var message = LocalMessage(
            id: messageID,
            conversationId: conversationID,
            senderId: UUID().uuidString.lowercased(),
            body: "Video",
            createdAt: createdAt,
            sentAt: nil,
            state: .queued,
            failureReason: nil,
            isOutgoing: true,
            pendingAttachment: LocalPendingAttachment(
                mediaType: "video/mp4",
                caption: nil,
                localStorageKey: mediaID,
                byteCount: 8_192
            ),
            localMediaRecords: [record]
        )

        let restarted = try JSONDecoder().decode(
            LocalMessage.self,
            from: JSONEncoder().encode(message)
        )
        XCTAssertEqual(restarted.localMediaRecords, [record])
        XCTAssertEqual(
            restarted.localMediaRecords?.first?.outboundKeyMaterialBase64,
            outboundKey.base64EncodedString()
        )
        XCTAssertTrue(LocalMediaRecordPolicy.markUploading(&message, attachmentID: mediaID))
        XCTAssertTrue(
            LocalMediaRecordPolicy.markUploaded(
                &message,
                attachmentID: mediaID,
                remoteStorageKey: remoteKey
            )
        )
        let uploaded = try XCTUnwrap(message.localMediaRecords?.first)
        XCTAssertEqual(uploaded.id, mediaID)
        XCTAssertEqual(uploaded.localStorageKey, mediaID, "upload must retain the local original")
        XCTAssertEqual(uploaded.remoteEncryptedObjectID, remoteKey)
        XCTAssertEqual(uploaded.uploadState, .uploaded)
        XCTAssertEqual(uploaded.availabilityState, .localOriginal)
        XCTAssertEqual(uploaded.duration, 10)
    }

    func testDurationMetadataCanArriveAfterQueueWithoutChangingTransferState() throws {
        let messageID = UUID()
        let conversationID = UUID().uuidString.lowercased()
        let mediaID = UUID().uuidString.lowercased()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let record = try XCTUnwrap(LocalMediaRecordPolicy.queuedOutgoing(
            id: mediaID,
            messageID: messageID,
            conversationID: conversationID,
            mediaType: "video/mp4",
            fileSize: 8_192,
            localStorageKey: mediaID,
            storesInline: false,
            now: createdAt,
            localStorageKind: .protectedFile
        ))
        var message = LocalMessage(
            id: messageID,
            conversationId: conversationID,
            senderId: UUID().uuidString.lowercased(),
            body: "Video",
            createdAt: createdAt,
            sentAt: nil,
            state: .queued,
            failureReason: nil,
            isOutgoing: true,
            pendingAttachment: LocalPendingAttachment(
                mediaType: "video/mp4",
                caption: nil,
                localStorageKey: mediaID,
                byteCount: 8_192
            ),
            localMediaRecords: [record]
        )

        XCTAssertTrue(LocalMediaRecordPolicy.setDuration(
            &message,
            attachmentID: mediaID,
            duration: 12.5,
            now: createdAt.addingTimeInterval(1)
        ))
        let updated = try XCTUnwrap(message.localMediaRecords?.first)
        XCTAssertEqual(updated.duration, 12.5)
        XCTAssertEqual(updated.uploadState, .pending)
        XCTAssertEqual(updated.encryptionState, .pending)
        XCTAssertEqual(updated.availabilityState, .localOriginal)
        XCTAssertFalse(LocalMediaRecordPolicy.setDuration(
            &message,
            attachmentID: mediaID,
            duration: 12.5,
            now: createdAt.addingTimeInterval(2)
        ), "re-probing the same duration must not rewrite the message projection")
        XCTAssertTrue(LocalMediaRecordPolicy.markUploading(
            &message,
            attachmentID: mediaID,
            now: createdAt.addingTimeInterval(3)
        ))
        XCTAssertFalse(LocalMediaRecordPolicy.setDuration(
            &message,
            attachmentID: mediaID,
            duration: 13,
            now: createdAt.addingTimeInterval(4)
        ), "duration metadata must not race the upload projection CAS")
        XCTAssertEqual(message.localMediaRecords?.first?.duration, 12.5)
        XCTAssertFalse(LocalMediaRecordPolicy.setDuration(
            &message,
            attachmentID: mediaID,
            duration: .nan
        ))
    }

    func testReceivedMediaStatePromotesOnlyAfterVerifiedLocalCheckpoint() throws {
        let descriptor = try makeDescriptor(mediaType: "application/pdf")
        var message = LocalMessage(
            id: UUID(),
            conversationId: UUID().uuidString.lowercased(),
            senderId: UUID().uuidString.lowercased(),
            body: descriptor.encoded,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            sentAt: Date(timeIntervalSince1970: 1_700_000_001),
            state: .received,
            failureReason: nil,
            isOutgoing: false
        )
        message.localMediaRecords = LocalMediaRecordPolicy.remoteRecords(for: message)
        let remote = try XCTUnwrap(message.localMediaRecords?.first)
        XCTAssertEqual(remote.availabilityState, .remoteOnly)
        XCTAssertEqual(remote.downloadState, .pending)

        XCTAssertTrue(
            LocalMediaRecordPolicy.markDownloading(
                &message,
                attachmentID: descriptor.attachmentID
            )
        )
        XCTAssertEqual(message.localMediaRecords?.first?.downloadState, .downloading)
        XCTAssertTrue(
            LocalMediaRecordPolicy.markDownloaded(
                &message,
                attachmentID: descriptor.attachmentID,
                storageKey: descriptor.storageKey
            )
        )
        let downloaded = try XCTUnwrap(message.localMediaRecords?.first)
        XCTAssertEqual(downloaded.localStorageKey, descriptor.storageKey)
        XCTAssertEqual(downloaded.downloadState, .downloaded)
        XCTAssertEqual(downloaded.availabilityState, .localCached)
        XCTAssertEqual(downloaded.encryptionState, .decrypted)
    }

    func testEvictedReceivedMediaReopensThroughTheSameRemoteIdentity() throws {
        let descriptor = try makeDescriptor(mediaType: "application/pdf")
        var message = LocalMessage(
            id: UUID(),
            conversationId: UUID().uuidString.lowercased(),
            senderId: UUID().uuidString.lowercased(),
            body: descriptor.encoded,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            sentAt: Date(timeIntervalSince1970: 1_700_000_001),
            state: .received,
            failureReason: nil,
            isOutgoing: false
        )
        message.localMediaRecords = LocalMediaRecordPolicy.remoteRecords(for: message)
        XCTAssertTrue(LocalMediaRecordPolicy.markDownloading(
            &message,
            attachmentID: descriptor.attachmentID
        ))
        XCTAssertTrue(LocalMediaRecordPolicy.markDownloadedProtectedFile(
            &message,
            attachmentID: descriptor.attachmentID,
            remoteStorageKey: descriptor.storageKey,
            localStorageKey: descriptor.attachmentID
        ))
        let cached = try XCTUnwrap(message.localMediaRecords?.first)

        XCTAssertTrue(LocalMediaRecordPolicy.markReceivedCacheEvicted(
            &message,
            attachmentID: descriptor.attachmentID,
            expectedLocalStorageKey: descriptor.attachmentID,
            expectedUpdatedAt: cached.updatedAt
        ))
        let evicted = try XCTUnwrap(message.localMediaRecords?.first)
        XCTAssertEqual(evicted.availabilityState, .remoteOnly)
        XCTAssertEqual(evicted.downloadState, .pending)
        XCTAssertEqual(evicted.encryptionState, .encrypted)
        XCTAssertEqual(evicted.remoteEncryptedObjectID, descriptor.storageKey)
        XCTAssertNil(evicted.localStorageKey)
        XCTAssertNotNil(evicted.cacheEvictedAt)
        XCTAssertTrue(evicted.isStructurallyValid)

        XCTAssertTrue(LocalMediaRecordPolicy.markDownloading(
            &message,
            attachmentID: descriptor.attachmentID
        ))
        XCTAssertNil(message.localMediaRecords?.first?.cacheEvictedAt)
        XCTAssertTrue(LocalMediaRecordPolicy.markDownloadedProtectedFile(
            &message,
            attachmentID: descriptor.attachmentID,
            remoteStorageKey: descriptor.storageKey,
            localStorageKey: descriptor.attachmentID
        ))
        XCTAssertEqual(message.localMediaRecords?.first?.availabilityState, .localCached)
        XCTAssertEqual(message.localMediaRecords?.first?.downloadState, .downloaded)
    }

    func testRestartRecoveryResetsInterruptedMediaWorkWithoutChangingIdentity() throws {
        let messageID = UUID()
        let conversationID = UUID().uuidString.lowercased()
        let mediaID = UUID().uuidString.lowercased()
        let outboundKey = Data(
            (0..<SecureMediaAttachmentCipher.keyMaterialBytes).map { UInt8(255 - $0) }
        )
        guard var record = LocalMediaRecordPolicy.queuedOutgoing(
            id: mediaID,
            messageID: messageID,
            conversationID: conversationID,
            mediaType: "audio/mp4",
            fileSize: 1_024,
            localStorageKey: mediaID,
            storesInline: false,
            now: Date(timeIntervalSince1970: 1_700_000_000),
            outboundKeyMaterial: outboundKey
        ) else { return XCTFail("valid local media record") }
        record.processingState = .processing
        record.uploadState = .uploading
        record.encryptionState = .encrypting
        var message = LocalMessage(
            id: messageID,
            conversationId: conversationID,
            senderId: UUID().uuidString.lowercased(),
            body: "Voice note",
            createdAt: record.createdAt,
            sentAt: nil,
            state: .queued,
            failureReason: nil,
            isOutgoing: true,
            localMediaRecords: [record]
        )

        message = try JSONDecoder().decode(
            LocalMessage.self,
            from: JSONEncoder().encode(message)
        )
        XCTAssertTrue(LocalMediaRecordPolicy.migrateAndRecover(&message))
        let recovered = try XCTUnwrap(message.localMediaRecords?.first)
        XCTAssertEqual(recovered.id, mediaID)
        XCTAssertEqual(recovered.localStorageKey, mediaID)
        XCTAssertEqual(recovered.processingState, .ready)
        XCTAssertEqual(recovered.uploadState, .pending)
        XCTAssertEqual(recovered.encryptionState, .pending)
        XCTAssertEqual(recovered.outboundKeyMaterialBase64, outboundKey.base64EncodedString())
    }

    func testLocalAvailabilityLatencyDoesNotIncludeNetworkCompletion() {
        let captured = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(
            LocalMediaLatencyMeasurement.milliseconds(
                from: captured,
                to: captured.addingTimeInterval(0.012)
            ),
            12,
            accuracy: 0.001
        )
    }

    @MainActor
    func testLocalMediaMonitorRecordsIndependentMilestonesAndKeepsFirstObservation() throws {
        let monitor = LocalMediaPerformanceMonitor()
        let mediaID = UUID()
        let captured = Date(timeIntervalSince1970: 100)
        monitor.begin(mediaID: mediaID, at: captured)

        let visible = try XCTUnwrap(
            monitor.markVisible(mediaID: mediaID, at: captured.addingTimeInterval(0.010))
        )
        XCTAssertEqual(
            try XCTUnwrap(visible.captureToVisibleMilliseconds),
            10,
            accuracy: 0.001
        )
        XCTAssertNil(visible.captureToPlayableMilliseconds)

        let playable = try XCTUnwrap(
            monitor.markPlayable(mediaID: mediaID, at: captured.addingTimeInterval(0.014))
        )
        XCTAssertEqual(
            try XCTUnwrap(playable.captureToVisibleMilliseconds),
            10,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(playable.captureToPlayableMilliseconds),
            14,
            accuracy: 0.001
        )

        // A later view/tap cannot inflate the local-availability measurement.
        let repeated = try XCTUnwrap(
            monitor.markPlayable(mediaID: mediaID, at: captured.addingTimeInterval(5))
        )
        XCTAssertEqual(
            try XCTUnwrap(repeated.captureToPlayableMilliseconds),
            14,
            accuracy: 0.001
        )

        let encrypted = try XCTUnwrap(
            monitor.markEncrypted(mediaID: mediaID, at: captured.addingTimeInterval(1))
        )
        XCTAssertEqual(
            try XCTUnwrap(encrypted.captureToEncryptedMilliseconds),
            1_000,
            accuracy: 0.001
        )
        let accepted = try XCTUnwrap(
            monitor.markServerAccepted(mediaID: mediaID, at: captured.addingTimeInterval(2))
        )
        XCTAssertEqual(
            try XCTUnwrap(accepted.captureToServerAcceptedMilliseconds),
            2_000,
            accuracy: 0.001
        )
        XCTAssertNil(monitor.markVisible(mediaID: mediaID, at: captured.addingTimeInterval(3)))
    }

    @MainActor
    func testRecipientHydrationMonitorUsesEarliestDescriptorObservation() throws {
        let monitor = LocalMediaPerformanceMonitor()
        let mediaID = UUID()
        let first = Date(timeIntervalSince1970: 200)
        monitor.beginRecipientHydration(mediaID: mediaID, descriptorObservedAt: first)
        monitor.beginRecipientHydration(
            mediaID: mediaID,
            descriptorObservedAt: first.addingTimeInterval(1)
        )
        let hydrated = try XCTUnwrap(
            monitor.markRecipientHydrated(mediaID: mediaID, at: first.addingTimeInterval(2.5))
        )
        XCTAssertEqual(
            try XCTUnwrap(hydrated.recipientDescriptorToLocalMilliseconds),
            2_500,
            accuracy: 0.001
        )
        XCTAssertNil(monitor.markRecipientHydrated(mediaID: mediaID))
    }

    @MainActor
    func testFastServerAcceptanceDoesNotEraseLaterLocalAvailabilityMetrics() throws {
        let monitor = LocalMediaPerformanceMonitor()
        let mediaID = UUID()
        let captured = Date(timeIntervalSince1970: 300)
        monitor.begin(mediaID: mediaID, at: captured)

        let accepted = try XCTUnwrap(
            monitor.markServerAccepted(mediaID: mediaID, at: captured.addingTimeInterval(0.004))
        )
        XCTAssertEqual(
            try XCTUnwrap(accepted.captureToServerAcceptedMilliseconds),
            4,
            accuracy: 0.001
        )
        let visible = try XCTUnwrap(
            monitor.markVisible(mediaID: mediaID, at: captured.addingTimeInterval(0.009))
        )
        XCTAssertEqual(
            try XCTUnwrap(visible.captureToVisibleMilliseconds),
            9,
            accuracy: 0.001
        )
        let playable = try XCTUnwrap(
            monitor.markPlayable(mediaID: mediaID, at: captured.addingTimeInterval(0.011))
        )
        XCTAssertEqual(
            try XCTUnwrap(playable.captureToPlayableMilliseconds),
            11,
            accuracy: 0.001
        )
        XCTAssertNil(monitor.markVisible(mediaID: mediaID, at: captured.addingTimeInterval(1)))
    }

    func testHydrationPassAdmitsCompleteEightItemMessagesWithBoundedConcurrency() {
        XCTAssertGreaterThanOrEqual(MediaHydrationPolicy.maximumItemsPerPass, 8)
        XCTAssertGreaterThan(MediaHydrationPolicy.maximumConcurrentDownloads, 1)
        XCTAssertLessThanOrEqual(
            MediaHydrationPolicy.maximumConcurrentDownloads,
            MediaHydrationPolicy.maximumItemsPerPass
        )
    }

    func testPreprocessingOverlapsIndependentMessagesWithinABoundedBudget() {
        XCTAssertGreaterThan(MediaPreprocessingPolicy.maximumItemsPerPass, 1)
        XCTAssertGreaterThan(MediaPreprocessingPolicy.maximumConcurrentJobs, 1)
        XCTAssertLessThanOrEqual(
            MediaPreprocessingPolicy.maximumConcurrentJobs,
            MediaPreprocessingPolicy.maximumItemsPerPass
        )
    }

    func testCrashPublishedJPEGRequiresJPEGSignatureAndImageIODecode() async throws {
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image {
            $0.cgContext.setFillColor(UIColor.systemBlue.cgColor)
            $0.cgContext.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        let jpeg = try XCTUnwrap(rendered.jpegData(compressionQuality: 0.9))
        let png = try XCTUnwrap(rendered.pngData())
        let validURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kit-valid-crash-output-\(UUID().uuidString).jpg"
        )
        let wrongFormatURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kit-wrong-crash-output-\(UUID().uuidString).jpg"
        )
        let corruptURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kit-corrupt-crash-output-\(UUID().uuidString).jpg"
        )
        try jpeg.write(to: validURL, options: .atomic)
        try png.write(to: wrongFormatURL, options: .atomic)
        try Data([0xff, 0xd8, 0xff, 0x00, 0x01]).write(to: corruptURL, options: .atomic)
        defer {
            try? FileManager.default.removeItem(at: validURL)
            try? FileManager.default.removeItem(at: wrongFormatURL)
            try? FileManager.default.removeItem(at: corruptURL)
        }
        let sourceKey = UUID().uuidString.lowercased()
        let job = LocalMediaPreprocessingJob(
            kind: .imageJPEG,
            sources: [LocalMediaOriginalSource(
                storageKey: sourceKey,
                mediaType: "image/heic",
                fileSize: 1_024,
                duration: nil
            )],
            outputStorageKey: UUID().uuidString.lowercased(),
            outputMediaType: "image/jpeg"
        )

        let acceptsJPEG = await MediaPreprocessingPolicy.isValidPublishedOutput(
            at: validURL,
            for: job
        )
        let acceptsPNG = await MediaPreprocessingPolicy.isValidPublishedOutput(
            at: wrongFormatURL,
            for: job
        )
        let acceptsCorruptJPEG = await MediaPreprocessingPolicy.isValidPublishedOutput(
            at: corruptURL,
            for: job
        )
        XCTAssertTrue(acceptsJPEG)
        XCTAssertFalse(acceptsPNG, "a decodable non-JPEG must not satisfy an imageJPEG job")
        XCTAssertFalse(acceptsCorruptJPEG, "signature bytes alone are not a decoded image")
    }

    func testCrashPublishedVoiceRequiresMPEG4AudioTrackAndPositiveDuration() async throws {
        let sourceURL = try XCTUnwrap(
            Bundle.main.url(forResource: "knock_brush", withExtension: "caf")
        )
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kit-valid-crash-voice-\(UUID().uuidString).m4a"
        )
        let imageURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kit-wrong-crash-voice-\(UUID().uuidString).m4a"
        )
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: imageURL)
        }
        let sourceAsset = AVURLAsset(url: sourceURL)
        let exporter = try XCTUnwrap(AVAssetExportSession(
            asset: sourceAsset,
            presetName: AVAssetExportPresetAppleM4A
        ))
        exporter.outputURL = outputURL
        exporter.outputFileType = .m4a
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            exporter.exportAsynchronously {
                continuation.resume()
            }
        }
        XCTAssertEqual(exporter.status, .completed)

        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image {
            $0.cgContext.setFillColor(UIColor.systemRed.cgColor)
            $0.cgContext.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        try XCTUnwrap(image.jpegData(compressionQuality: 0.8)).write(
            to: imageURL,
            options: .atomic
        )
        let sourceKey = UUID().uuidString.lowercased()
        let job = LocalMediaPreprocessingJob(
            kind: .voiceAssembly,
            sources: [LocalMediaOriginalSource(
                storageKey: sourceKey,
                mediaType: "audio/mp4",
                fileSize: 1_024,
                duration: 1
            )],
            outputStorageKey: UUID().uuidString.lowercased(),
            outputMediaType: "audio/mp4"
        )

        let acceptsAudio = await MediaPreprocessingPolicy.isValidPublishedOutput(
            at: outputURL,
            for: job
        )
        let acceptsImage = await MediaPreprocessingPolicy.isValidPublishedOutput(
            at: imageURL,
            for: job
        )
        XCTAssertTrue(acceptsAudio)
        XCTAssertFalse(acceptsImage)
    }

    func testProtectedImageLoadedItemDownsamplesFromFileWithoutWholeFileData() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24)).image { context in
            context.cgContext.setFillColor(UIColor.systemGreen.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        }
        let bytes = try XCTUnwrap(image.pngData())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kit-file-backed-image-\(UUID().uuidString).png"
        )
        try bytes.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let item = SecureMediaLoadPolicy.LoadedItem(localFile: .init(
            url: url,
            mediaType: "image/png",
            caption: nil,
            byteCount: bytes.count,
            attachmentID: UUID().uuidString.lowercased()
        ))
        XCTAssertTrue(item.data.isEmpty)
        let thumbnail = try XCTUnwrap(item.downsampledImage(maximumPixelSize: 16))
        XCTAssertLessThanOrEqual(max(thumbnail.size.width, thumbnail.size.height), 16)
    }

    func testMediaBatchUsesComposerMintedPermanentIDsInDisplayOrder() throws {
        let firstID = UUID().uuidString.lowercased()
        let secondID = UUID().uuidString.lowercased()
        let batch = try KitMediaMessageV2OutboundBatch.queued(
            attachments: [
                .init(
                    attachmentID: firstID,
                    mediaType: "image/jpeg",
                    plaintextByteSize: 512,
                    localStorageKey: firstID
                ),
                .init(
                    attachmentID: secondID,
                    mediaType: "application/pdf",
                    plaintextByteSize: 1_024,
                    localStorageKey: secondID
                ),
            ],
            rawCaption: nil,
            keyMaterialFactory: {
                Data(repeating: 7, count: SecureMediaAttachmentCipher.keyMaterialBytes)
            }
        )

        XCTAssertEqual(batch.items.map(\.attachmentID), [firstID, secondID])
        XCTAssertEqual(batch.items.map(\.localStorageKey), [firstID, secondID])
    }

    func testBatchImagePreprocessingAtomicallyRebindsOnlyItsOwnItem() throws {
        let messageID = UUID()
        let conversationID = UUID().uuidString.lowercased()
        let imageID = UUID().uuidString.lowercased()
        let videoID = UUID().uuidString.lowercased()
        let outputKey = UUID().uuidString.lowercased()
        let originalSize = 4_096
        let outputSize = 2_048
        let job = LocalMediaPreprocessingJob(
            kind: .imageJPEG,
            sources: [LocalMediaOriginalSource(
                storageKey: imageID,
                mediaType: "image/heic",
                fileSize: originalSize,
                duration: nil
            )],
            outputStorageKey: outputKey,
            outputMediaType: "image/jpeg"
        )
        let batch = try KitMediaMessageV2OutboundBatch.queued(
            attachments: [
                .init(
                    attachmentID: imageID,
                    mediaType: "image/jpeg",
                    plaintextByteSize: originalSize,
                    localStorageKey: imageID
                ),
                .init(
                    attachmentID: videoID,
                    mediaType: "video/mp4",
                    plaintextByteSize: 8_192,
                    localStorageKey: videoID
                ),
            ],
            rawCaption: "Album",
            keyMaterialFactory: {
                Data(repeating: 0x44, count: SecureMediaAttachmentCipher.keyMaterialBytes)
            }
        )
        let records = try XCTUnwrap(LocalMediaRecordPolicy.queuedOutgoing(
            batch: batch,
            messageID: messageID,
            conversationID: conversationID,
            now: Date(timeIntervalSince1970: 1_700_000_000),
            localStorageKinds: [.protectedFile, .protectedFile],
            preprocessingJobs: [job, nil]
        ))
        var message = LocalMessage(
            id: messageID,
            conversationId: conversationID,
            senderId: UUID().uuidString.lowercased(),
            body: "Album",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            sentAt: nil,
            state: .queued,
            failureReason: nil,
            isOutgoing: true,
            pendingMediaBatch: batch,
            localMediaRecords: records
        )

        XCTAssertTrue(LocalMediaRecordPolicy.completePreprocessing(
            &message,
            attachmentID: imageID,
            expectedJob: job,
            outputByteCount: outputSize
        ))
        let processedBatch = try XCTUnwrap(message.pendingMediaBatch)
        XCTAssertEqual(processedBatch.items[0].attachmentID, imageID)
        XCTAssertEqual(processedBatch.items[0].mediaType, "image/jpeg")
        XCTAssertEqual(processedBatch.items[0].plaintextByteSize, outputSize)
        XCTAssertEqual(processedBatch.items[0].localStorageKey, outputKey)
        XCTAssertEqual(processedBatch.items[1], batch.items[1])
        let imageRecord = try XCTUnwrap(message.localMediaRecords?.first)
        XCTAssertNil(imageRecord.preprocessingJob)
        XCTAssertEqual(imageRecord.localStorageKey, outputKey)
        XCTAssertEqual(imageRecord.originalSources, job.sources)
        XCTAssertTrue(message.localMediaStorageKeys.contains(imageID))
        XCTAssertTrue(message.localMediaStorageKeys.contains(outputKey))
    }

    func testPreprocessingOutputReplacementRequiresOneExactRecordAndNoDraftOwner() throws {
        let messageID = UUID()
        let conversationID = UUID().uuidString.lowercased()
        let targetSource = UUID().uuidString.lowercased()
        let siblingSource = UUID().uuidString.lowercased()
        let outputKey = UUID().uuidString.lowercased()
        func job(source: String) -> LocalMediaPreprocessingJob {
            LocalMediaPreprocessingJob(
                kind: .imageJPEG,
                sources: [LocalMediaOriginalSource(
                    storageKey: source,
                    mediaType: "image/heic",
                    fileSize: 2_048,
                    duration: nil
                )],
                outputStorageKey: outputKey,
                outputMediaType: "image/jpeg"
            )
        }
        func record(
            source: String,
            preprocessingJob: LocalMediaPreprocessingJob
        ) throws -> LocalMediaRecord {
            try XCTUnwrap(LocalMediaRecordPolicy.queuedOutgoing(
                id: source,
                messageID: messageID,
                conversationID: conversationID,
                mediaType: "image/jpeg",
                fileSize: 2_048,
                localStorageKey: source,
                storesInline: false,
                now: Date(timeIntervalSince1970: 1_700_000_000),
                localStorageKind: .protectedFile,
                originalSources: preprocessingJob.sources,
                preprocessingJob: preprocessingJob
            ))
        }
        let targetJob = job(source: targetSource)
        let targetRecord = try record(source: targetSource, preprocessingJob: targetJob)
        let siblingRecord = try record(
            source: siblingSource,
            preprocessingJob: job(source: siblingSource)
        )
        var message = LocalMessage(
            id: messageID,
            conversationId: conversationID,
            senderId: UUID().uuidString.lowercased(),
            body: "Photo",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            sentAt: nil,
            state: .queued,
            failureReason: nil,
            isOutgoing: true,
            localMediaRecords: [targetRecord, siblingRecord]
        )
        var state = PersistedState.empty
        state.messages = [message]

        XCTAssertFalse(MediaPreprocessingPolicy.canReplaceOutput(
            storageKey: outputKey,
            ownedBy: messageID,
            attachmentID: targetSource,
            expectedJob: targetJob,
            in: state
        ), "a sibling record in the same message is an independent owner")

        message.localMediaRecords = [targetRecord]
        state.messages = [message]
        XCTAssertTrue(MediaPreprocessingPolicy.canReplaceOutput(
            storageKey: outputKey,
            ownedBy: messageID,
            attachmentID: targetSource,
            expectedJob: targetJob,
            in: state
        ))

        state.conversationDrafts = [
            UUID().uuidString.lowercased(): ConversationDraft(
                body: "",
                updatedAt: Date(),
                mediaAttachments: [ConversationDraftMediaAttachment(
                    id: UUID(),
                    storageKind: .protectedFile,
                    mediaType: "image/jpeg",
                    originalMediaType: "image/heic",
                    byteCount: 2_048,
                    displayName: "Draft photo",
                    duration: nil,
                    acceptedAt: Date(),
                    clientMessageID: nil,
                    preprocessingOutputStorageKey: outputKey
                )]
            ),
        ]
        XCTAssertFalse(MediaPreprocessingPolicy.canReplaceOutput(
            storageKey: outputKey,
            ownedBy: messageID,
            attachmentID: targetSource,
            expectedJob: targetJob,
            in: state
        ), "preprocessing must never delete an output reserved by a composer draft")
    }

    func testInvalidCrashOutputRekeysOnlyTheExactDurableJob() throws {
        let messageID = UUID()
        let conversationID = UUID().uuidString.lowercased()
        let sourceKey = UUID().uuidString.lowercased()
        let oldOutputKey = UUID().uuidString.lowercased()
        let newOutputKey = UUID().uuidString.lowercased()
        let job = LocalMediaPreprocessingJob(
            kind: .imageJPEG,
            sources: [LocalMediaOriginalSource(
                storageKey: sourceKey,
                mediaType: "image/heic",
                fileSize: 2_048,
                duration: nil
            )],
            outputStorageKey: oldOutputKey,
            outputMediaType: "image/jpeg"
        )
        let record = try XCTUnwrap(LocalMediaRecordPolicy.queuedOutgoing(
            id: sourceKey,
            messageID: messageID,
            conversationID: conversationID,
            mediaType: "image/jpeg",
            fileSize: 2_048,
            localStorageKey: sourceKey,
            storesInline: false,
            now: Date(timeIntervalSince1970: 1_700_000_000),
            localStorageKind: .protectedFile,
            originalSources: job.sources,
            preprocessingJob: job
        ))
        var message = LocalMessage(
            id: messageID,
            conversationId: conversationID,
            senderId: UUID().uuidString.lowercased(),
            body: "Photo",
            createdAt: record.createdAt,
            sentAt: nil,
            state: .queued,
            failureReason: nil,
            isOutgoing: true,
            pendingAttachment: LocalPendingAttachment(
                mediaType: "image/jpeg",
                caption: nil,
                localStorageKey: sourceKey,
                byteCount: 2_048
            ),
            localMediaRecords: [record]
        )
        var state = PersistedState.empty
        state.messages = [message]
        XCTAssertTrue(MediaPreprocessingPolicy.isOutputStorageKeyUnowned(
            newOutputKey,
            in: state
        ))

        let siblingSource = UUID().uuidString.lowercased()
        let sibling = try XCTUnwrap(LocalMediaRecordPolicy.queuedOutgoing(
            id: newOutputKey,
            messageID: messageID,
            conversationID: conversationID,
            mediaType: "application/pdf",
            fileSize: 1_024,
            localStorageKey: siblingSource,
            storesInline: false,
            now: Date(),
            localStorageKind: .protectedFile
        ))
        message.localMediaRecords = [record, sibling]
        XCTAssertFalse(LocalMediaRecordPolicy.rekeyPreprocessingOutput(
            &message,
            attachmentID: sourceKey,
            expectedJob: job,
            newOutputStorageKey: newOutputKey
        ), "a sibling ciphertext-spool id owns the destination inside the same message")
        message.localMediaRecords = [record]

        XCTAssertTrue(LocalMediaRecordPolicy.rekeyPreprocessingOutput(
            &message,
            attachmentID: sourceKey,
            expectedJob: job,
            newOutputStorageKey: newOutputKey,
            now: Date(timeIntervalSince1970: 1_700_000_100)
        ))
        let replacement = try XCTUnwrap(message.localMediaRecords?.first?.preprocessingJob)
        XCTAssertEqual(replacement.kind, job.kind)
        XCTAssertEqual(replacement.sources, job.sources)
        XCTAssertEqual(replacement.outputMediaType, job.outputMediaType)
        XCTAssertEqual(replacement.outputStorageKey, newOutputKey)
        XCTAssertEqual(message.pendingAttachment?.localStorageKey, sourceKey)
        XCTAssertTrue(message.localMediaStorageKeys.contains(sourceKey))
        XCTAssertTrue(message.localMediaStorageKeys.contains(newOutputKey))
        XCTAssertFalse(message.localMediaStorageKeys.contains(oldOutputKey))
        XCTAssertFalse(LocalMediaRecordPolicy.rekeyPreprocessingOutput(
            &message,
            attachmentID: sourceKey,
            expectedJob: job,
            newOutputStorageKey: UUID().uuidString.lowercased()
        ), "the stale processing target cannot mutate the replacement job")
    }

    func testPreprocessingOutputCannotAliasItsOwnCiphertextSpoolIdentity() {
        let sourceKey = UUID().uuidString.lowercased()
        let outputKey = UUID().uuidString.lowercased()
        let job = LocalMediaPreprocessingJob(
            kind: .imageJPEG,
            sources: [LocalMediaOriginalSource(
                storageKey: sourceKey,
                mediaType: "image/heic",
                fileSize: 2_048,
                duration: nil
            )],
            outputStorageKey: outputKey,
            outputMediaType: "image/jpeg"
        )

        XCTAssertNil(LocalMediaRecordPolicy.queuedOutgoing(
            id: outputKey,
            messageID: UUID(),
            conversationID: UUID().uuidString.lowercased(),
            mediaType: "image/jpeg",
            fileSize: 2_048,
            localStorageKey: sourceKey,
            storesInline: false,
            now: Date(),
            localStorageKind: .protectedFile,
            originalSources: job.sources,
            preprocessingJob: job
        ))
    }

    func testPreprocessingRekeyDestinationMustBeGloballyUnowned() throws {
        let candidate = UUID().uuidString.lowercased()
        let conversationID = UUID().uuidString.lowercased()
        var state = PersistedState.empty
        state.messages = [LocalMessage(
            id: UUID(),
            conversationId: conversationID,
            senderId: UUID().uuidString.lowercased(),
            body: "Legacy pending attachment",
            createdAt: Date(),
            sentAt: nil,
            state: .queued,
            failureReason: nil,
            isOutgoing: true,
            pendingAttachment: LocalPendingAttachment(
                mediaType: "image/jpeg",
                caption: nil,
                localStorageKey: candidate.uppercased(),
                byteCount: 1_024
            )
        )]

        XCTAssertFalse(
            MediaPreprocessingPolicy.isOutputStorageKeyUnowned(candidate, in: state),
            "uppercase legacy state aliases the same canonical on-disk key"
        )
        state.messages = []
        XCTAssertTrue(MediaPreprocessingPolicy.isOutputStorageKeyUnowned(candidate, in: state))
        let spoolSource = UUID().uuidString.lowercased()
        let spoolMessageID = UUID()
        let spoolRecord = try XCTUnwrap(LocalMediaRecordPolicy.queuedOutgoing(
            id: candidate,
            messageID: spoolMessageID,
            conversationID: conversationID,
            mediaType: "application/pdf",
            fileSize: 1_024,
            localStorageKey: spoolSource,
            storesInline: false,
            now: Date(),
            localStorageKind: .protectedFile
        ))
        let spoolOwner = LocalMessage(
            id: spoolMessageID,
            conversationId: conversationID,
            senderId: UUID().uuidString.lowercased(),
            body: "Document",
            createdAt: Date(),
            sentAt: nil,
            state: .queued,
            failureReason: nil,
            isOutgoing: true,
            pendingAttachment: LocalPendingAttachment(
                mediaType: "application/pdf",
                caption: nil,
                localStorageKey: spoolSource,
                byteCount: 1_024
            ),
            localMediaRecords: [spoolRecord]
        )
        XCTAssertFalse(spoolOwner.localMediaStorageKeys.contains(candidate))
        XCTAssertTrue(spoolOwner.localMediaOwnershipKeys.contains(candidate))
        state.messages = [spoolOwner]
        XCTAssertFalse(
            MediaPreprocessingPolicy.isOutputStorageKeyUnowned(candidate, in: state),
            "a record id reserves the ciphertext-spool namespace even before the spool exists"
        )
        state.messages = []
        state.conversationDrafts = [
            conversationID: ConversationDraft(
                body: "",
                updatedAt: Date(),
                mediaAttachments: [ConversationDraftMediaAttachment(
                    id: UUID(),
                    storageKind: .protectedFile,
                    mediaType: "image/jpeg",
                    originalMediaType: "image/heic",
                    byteCount: 1_024,
                    displayName: "Draft photo",
                    duration: nil,
                    acceptedAt: Date(),
                    clientMessageID: nil,
                    preprocessingOutputStorageKey: candidate.uppercased()
                )]
            ),
        ]
        XCTAssertFalse(
            MediaPreprocessingPolicy.isOutputStorageKeyUnowned(candidate, in: state),
            "uppercase draft metadata must still reserve the canonical cache key"
        )
    }

    func testSealedLegacyDescriptorReservesAttachmentAndStorageIdentities() throws {
        let descriptor = try makeDescriptor(mediaType: "image/jpeg")
        let message = LocalMessage(
            id: UUID(),
            conversationId: UUID().uuidString.lowercased(),
            senderId: UUID().uuidString.lowercased(),
            body: descriptor.encoded,
            createdAt: Date(),
            sentAt: Date(),
            state: .sent,
            failureReason: nil,
            isOutgoing: true
        )

        XCTAssertTrue(message.localMediaOwnershipKeys.contains(descriptor.attachmentID))
        XCTAssertTrue(message.localMediaOwnershipKeys.contains(descriptor.storageKey))
    }

    func testFreshServerStorageAdmissionRejectsEveryLocalOwnershipRole() throws {
        let targetID = "71000000-0000-4000-8000-000000000001"
        let targetSource = "71000000-0000-4000-8000-000000000002"
        let siblingID = "71000000-0000-4000-8000-000000000003"
        let siblingSource = "71000000-0000-4000-8000-000000000004"
        let siblingOutput = "71000000-0000-4000-8000-000000000005"
        let conversationID = "31000000-0000-4000-8000-000000000001"
        var current = try makeUploadingOwnershipMessage(
            attachmentID: targetID,
            localStorageKey: targetSource,
            conversationID: conversationID
        )
        let siblingJob = LocalMediaPreprocessingJob(
            kind: .imageJPEG,
            sources: [LocalMediaOriginalSource(
                storageKey: siblingSource,
                mediaType: "image/heic",
                fileSize: 1_024,
                duration: nil
            )],
            outputStorageKey: siblingOutput,
            outputMediaType: "image/jpeg"
        )
        let siblingRecord = try XCTUnwrap(LocalMediaRecordPolicy.queuedOutgoing(
            id: siblingID,
            messageID: current.id,
            conversationID: conversationID,
            mediaType: "image/jpeg",
            fileSize: 1_024,
            localStorageKey: siblingSource,
            storesInline: false,
            now: current.createdAt,
            localStorageKind: .protectedFile,
            originalSources: siblingJob.sources,
            preprocessingJob: siblingJob
        ))
        current.localMediaRecords?.append(siblingRecord)
        var state = PersistedState.empty
        state.messages = [current]

        for collision in [
            targetID,
            targetSource,
            siblingID,
            siblingSource,
            siblingOutput,
        ] {
            let proposed = uncheckedCheckpoint(
                current,
                attachmentID: targetID,
                storageKey: collision,
                nextOffset: 0
            )
            XCTAssertFalse(
                LocalMediaStorageOwnershipPolicy.permitsTransition(
                    from: current,
                    to: proposed,
                    in: state
                ),
                "fresh server key must not alias local role \(collision)"
            )
        }

        let freshKey = "71000000-0000-4000-8000-000000000006"
        let proposed = uncheckedCheckpoint(
            current,
            attachmentID: targetID,
            storageKey: freshKey,
            nextOffset: 0
        )
        XCTAssertTrue(LocalMediaStorageOwnershipPolicy.permitsTransition(
            from: current,
            to: proposed,
            in: state
        ))

        let foreignSource = "71000000-0000-4000-8000-000000000007"
        let foreign = try makeQueuedOwnershipMessage(
            attachmentID: freshKey,
            localStorageKey: foreignSource,
            conversationID: "31000000-0000-4000-8000-000000000002"
        )
        state.messages = [current, foreign]
        XCTAssertFalse(LocalMediaStorageOwnershipPolicy.permitsTransition(
            from: current,
            to: proposed,
            in: state
        ), "another message's record/spool id owns the namespace")

        let uppercaseAlias = LocalMessage(
            id: UUID(),
            conversationId: "31000000-0000-4000-8000-000000000003",
            senderId: UUID().uuidString.lowercased(),
            body: "Legacy media",
            createdAt: Date(),
            sentAt: nil,
            state: .queued,
            failureReason: nil,
            isOutgoing: true,
            pendingAttachment: LocalPendingAttachment(
                mediaType: "image/jpeg",
                caption: nil,
                localStorageKey: freshKey.uppercased(),
                byteCount: 1_024
            )
        )
        state.messages = [current, uppercaseAlias]
        XCTAssertFalse(LocalMediaStorageOwnershipPolicy.permitsTransition(
            from: current,
            to: proposed,
            in: state
        ), "uppercase legacy aliases must reserve the canonical storage key")
    }

    func testFreshAndReplacementServerKeysRejectActiveDraftClaims() throws {
        let targetID = "72000000-0000-4000-8000-000000000001"
        let targetSource = "72000000-0000-4000-8000-000000000002"
        let oldServerKey = "72000000-0000-4000-8000-000000000003"
        let candidate = "72000000-0000-4000-8000-000000000004"
        let conversationID = "32000000-0000-4000-8000-000000000001"
        let uploading = try makeUploadingOwnershipMessage(
            attachmentID: targetID,
            localStorageKey: targetSource,
            conversationID: conversationID
        )
        let first = uncheckedCheckpoint(
            uploading,
            attachmentID: targetID,
            storageKey: candidate,
            nextOffset: 0
        )
        var state = PersistedState.empty
        state.messages = [uploading]
        state.conversationDrafts = [
            conversationID: ConversationDraft(
                body: "Still composing",
                updatedAt: Date(),
                mediaAttachments: [ConversationDraftMediaAttachment(
                    id: UUID(uuidString: candidate)!,
                    storageKind: .encryptedBlob,
                    mediaType: "application/pdf",
                    originalMediaType: nil,
                    byteCount: 1_024,
                    displayName: "Statement.pdf",
                    duration: nil,
                    acceptedAt: Date(),
                    clientMessageID: nil,
                    preprocessingOutputStorageKey: nil
                )]
            ),
        ]
        XCTAssertFalse(LocalMediaStorageOwnershipPolicy.permitsTransition(
            from: uploading,
            to: first,
            in: state
        ))

        let checkpointed = uncheckedCheckpoint(
            uploading,
            attachmentID: targetID,
            storageKey: oldServerKey,
            nextOffset: 0
        )
        let replacement = uncheckedCheckpoint(
            checkpointed,
            attachmentID: targetID,
            storageKey: candidate,
            nextOffset: 0
        )
        state.messages = [checkpointed]
        XCTAssertFalse(LocalMediaStorageOwnershipPolicy.permitsTransition(
            from: checkpointed,
            to: replacement,
            in: state
        ), "a replacement lease is a fresh claim and cannot take a draft key")

        let outputOwnerID = UUID()
        state.conversationDrafts = [
            conversationID: ConversationDraft(
                body: "Editing photo",
                updatedAt: Date(),
                mediaAttachments: [ConversationDraftMediaAttachment(
                    id: outputOwnerID,
                    storageKind: .protectedFile,
                    mediaType: "image/jpeg",
                    originalMediaType: "image/heic",
                    byteCount: 1_024,
                    displayName: "Photo",
                    duration: nil,
                    acceptedAt: Date(),
                    clientMessageID: nil,
                    preprocessingOutputStorageKey: candidate
                )]
            ),
        ]
        XCTAssertFalse(LocalMediaStorageOwnershipPolicy.permitsTransition(
            from: checkpointed,
            to: replacement,
            in: state
        ), "active preprocessing outputs reserve their future file key")

        state.conversationDrafts = nil
        XCTAssertTrue(LocalMediaStorageOwnershipPolicy.permitsTransition(
            from: checkpointed,
            to: replacement,
            in: state
        ))
    }

    func testUnchangedCheckpointAdvancesOnlyForItsExactAttachmentOwner() throws {
        let targetID = "73000000-0000-4000-8000-000000000001"
        let targetSource = "73000000-0000-4000-8000-000000000002"
        let serverKey = "73000000-0000-4000-8000-000000000003"
        let conversationID = "33000000-0000-4000-8000-000000000001"
        let uploading = try makeUploadingOwnershipMessage(
            attachmentID: targetID,
            localStorageKey: targetSource,
            conversationID: conversationID
        )
        let checkpointed = uncheckedCheckpoint(
            uploading,
            attachmentID: targetID,
            storageKey: serverKey,
            nextOffset: 0
        )
        let advanced = uncheckedCheckpoint(
            checkpointed,
            attachmentID: targetID,
            storageKey: serverKey,
            nextOffset: 512
        )
        var state = PersistedState.empty
        state.messages = [checkpointed]
        XCTAssertTrue(LocalMediaStorageOwnershipPolicy.permitsTransition(
            from: checkpointed,
            to: advanced,
            in: state
        ))

        let sibling = try makeQueuedOwnershipMessage(
            attachmentID: "73000000-0000-4000-8000-000000000004",
            localStorageKey: serverKey,
            conversationID: conversationID,
            messageID: checkpointed.id
        ).localMediaRecords!.first!
        var aliasedCurrent = checkpointed
        aliasedCurrent.localMediaRecords?.append(sibling)
        var aliasedAdvanced = advanced
        aliasedAdvanced.localMediaRecords?.append(sibling)
        state.messages = [aliasedCurrent]
        XCTAssertFalse(LocalMediaStorageOwnershipPolicy.permitsTransition(
            from: aliasedCurrent,
            to: aliasedAdvanced,
            in: state
        ), "same-message sibling ownership must not be hidden by the message-id exemption")
    }

    func testLegacyV1DescriptorMayStillUseOneRemoteIdentityForReceivedMedia() throws {
        let mediaID = "74000000-0000-4000-8000-000000000001"
        let descriptor = try KitMediaMessageDescriptor(
            attachmentID: mediaID,
            storageKey: mediaID,
            mediaType: "image/jpeg",
            ciphertextByteSize: 1_088,
            ciphertextSHA256: String(repeating: "a", count: 64),
            keyMaterial: Data(repeating: 0x74, count: SecureMediaAttachmentCipher.keyMaterialBytes),
            plaintextByteSize: 1_024,
            caption: nil
        )
        XCTAssertEqual(KitMediaMessageDescriptor.parse(descriptor.encoded), descriptor)
        let incoming = LocalMessage(
            id: UUID(),
            conversationId: "34000000-0000-4000-8000-000000000001",
            senderId: UUID().uuidString.lowercased(),
            body: descriptor.encoded,
            createdAt: Date(),
            sentAt: Date(),
            state: .delivered,
            failureReason: nil,
            isOutgoing: false
        )
        let records = try XCTUnwrap(LocalMediaRecordPolicy.remoteRecords(for: incoming))
        XCTAssertEqual(records.count, 1)
        XCTAssertTrue(records[0].isStructurallyValid)
        XCTAssertEqual(records[0].id, mediaID)
        XCTAssertEqual(records[0].remoteEncryptedObjectID, mediaID)
    }

    func testOutboundServerReferencesCannotAliasClientOrSiblingIdentities() throws {
        let firstID = "75000000-0000-4000-8000-000000000001"
        let firstSource = "75000000-0000-4000-8000-000000000002"
        let secondID = "75000000-0000-4000-8000-000000000003"
        let secondSource = "75000000-0000-4000-8000-000000000004"
        let conversationID = "35000000-0000-4000-8000-000000000001"
        let uploading = try makeUploadingOwnershipMessage(
            attachmentID: firstID,
            localStorageKey: firstSource,
            conversationID: conversationID
        )
        let aliasedRecord = try XCTUnwrap(
            uncheckedCheckpoint(
                uploading,
                attachmentID: firstID,
                storageKey: firstSource,
                nextOffset: 0
            ).localMediaRecords?.first
        )
        XCTAssertFalse(aliasedRecord.isStructurallyValid)

        var batch = try KitMediaMessageV2OutboundBatch.queued(
            attachments: [
                .init(
                    attachmentID: firstID,
                    mediaType: "image/jpeg",
                    plaintextByteSize: 1_024,
                    localStorageKey: firstSource
                ),
                .init(
                    attachmentID: secondID,
                    mediaType: "application/pdf",
                    plaintextByteSize: 1_024,
                    localStorageKey: secondSource
                ),
            ],
            rawCaption: nil,
            keyMaterialFactory: {
                Data(repeating: 0x75, count: SecureMediaAttachmentCipher.keyMaterialBytes)
            }
        )
        batch.items[0] = try XCTUnwrap(batch.items[0].uploaded(
            storageKey: secondID,
            ciphertextByteSize: 1_088,
            ciphertextSHA256: String(repeating: "c", count: 64)
        ))
        XCTAssertFalse(
            batch.isStructurallyValid,
            "a server object may not alias any attachment's permanent spool identity"
        )
    }

    func testRestartKeepsDurablePreprocessingWorkParked() throws {
        let messageID = UUID()
        let conversationID = UUID().uuidString.lowercased()
        let sourceKey = UUID().uuidString.lowercased()
        let job = LocalMediaPreprocessingJob(
            kind: .imageJPEG,
            sources: [LocalMediaOriginalSource(
                storageKey: sourceKey,
                mediaType: "image/png",
                fileSize: 2_048,
                duration: nil
            )],
            outputStorageKey: UUID().uuidString.lowercased(),
            outputMediaType: "image/jpeg"
        )
        let record = try XCTUnwrap(LocalMediaRecordPolicy.queuedOutgoing(
            id: sourceKey,
            messageID: messageID,
            conversationID: conversationID,
            mediaType: "image/jpeg",
            fileSize: 2_048,
            localStorageKey: sourceKey,
            storesInline: false,
            now: Date(timeIntervalSince1970: 1_700_000_000),
            localStorageKind: .protectedFile,
            originalSources: job.sources,
            preprocessingJob: job
        ))
        var message = LocalMessage(
            id: messageID,
            conversationId: conversationID,
            senderId: UUID().uuidString.lowercased(),
            body: "Photo",
            createdAt: record.createdAt,
            sentAt: nil,
            state: .queued,
            failureReason: nil,
            isOutgoing: true,
            pendingAttachment: LocalPendingAttachment(
                mediaType: "image/jpeg",
                caption: nil,
                localStorageKey: sourceKey,
                byteCount: 2_048
            ),
            localMediaRecords: [record]
        )
        message = try JSONDecoder().decode(
            LocalMessage.self,
            from: JSONEncoder().encode(message)
        )

        XCTAssertFalse(LocalMediaRecordPolicy.migrateAndRecover(&message))
        XCTAssertEqual(message.localMediaRecords?.first?.processingState, .processing)
        XCTAssertEqual(message.localMediaRecords?.first?.preprocessingJob, job)
    }

    func testBatchMigrationRetainsClientKeyedOriginalAfterUploadCheckpoint() throws {
        let firstID = "11111111-1111-4111-8111-111111111111"
        let secondID = "22222222-2222-4222-8222-222222222222"
        let remoteKey = "99999999-9999-4999-8999-999999999999"
        let firstSize = 512
        var batch = try KitMediaMessageV2OutboundBatch.queued(
            attachments: [
                .init(
                    attachmentID: firstID,
                    mediaType: "image/jpeg",
                    plaintextByteSize: firstSize,
                    localStorageKey: firstID
                ),
                .init(
                    attachmentID: secondID,
                    mediaType: "application/pdf",
                    plaintextByteSize: 1_024,
                    localStorageKey: secondID
                ),
            ],
            rawCaption: nil,
            keyMaterialFactory: {
                Data(repeating: 7, count: SecureMediaAttachmentCipher.keyMaterialBytes)
            }
        )
        batch.items[0] = try XCTUnwrap(batch.items[0].uploaded(
            storageKey: remoteKey,
            ciphertextByteSize: Int64(firstSize + 64 - (firstSize % 16)),
            ciphertextSHA256: String(repeating: "a", count: 64)
        ))
        var message = LocalMessage(
            id: UUID(),
            conversationId: UUID().uuidString.lowercased(),
            senderId: UUID().uuidString.lowercased(),
            body: "2 attachments",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            sentAt: nil,
            state: .queued,
            failureReason: nil,
            isOutgoing: true,
            pendingMediaBatch: batch
        )

        XCTAssertTrue(LocalMediaRecordPolicy.migrateAndRecover(&message))
        let first = try XCTUnwrap(message.localMediaRecords?.first)
        XCTAssertEqual(first.id, firstID)
        XCTAssertEqual(first.localStorageKey, firstID)
        XCTAssertEqual(first.remoteEncryptedObjectID, remoteKey)
        XCTAssertEqual(first.uploadState, .uploaded)
        XCTAssertEqual(first.availabilityState, .localOriginal)
    }

    func testPermanentMediaIdentityReproducesCiphertextForIdempotentRetry() throws {
        let mediaID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let otherID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let plaintext = Data("offline retry media".utf8)
        let keyMaterial = Data(
            (0..<SecureMediaAttachmentCipher.keyMaterialBytes).map(UInt8.init)
        )

        let first = try SecureMediaAttachmentCipher.encrypt(
            plaintext,
            keyMaterial: keyMaterial,
            attachmentID: mediaID
        )
        let retry = try SecureMediaAttachmentCipher.encrypt(
            plaintext,
            keyMaterial: keyMaterial,
            attachmentID: mediaID
        )
        let other = try SecureMediaAttachmentCipher.encrypt(
            plaintext,
            keyMaterial: keyMaterial,
            attachmentID: otherID
        )

        XCTAssertEqual(first.ciphertext, retry.ciphertext)
        XCTAssertEqual(first.sha256Hex, retry.sha256Hex)
        XCTAssertNotEqual(first.ciphertext, other.ciphertext)
        XCTAssertEqual(
            try SecureMediaAttachmentCipher.decrypt(
                retry.ciphertext,
                keyMaterial: keyMaterial,
                expectedSHA256Hex: retry.sha256Hex
            ),
            plaintext
        )

        XCTAssertThrowsError(
            try SecureMediaAttachmentCipher.encrypt(
                plaintext,
                keyMaterial: keyMaterial,
                attachmentID: mediaID.uppercased()
            )
        )
        XCTAssertThrowsError(
            try SecureMediaAttachmentCipher.encrypt(
                plaintext,
                keyMaterial: keyMaterial,
                attachmentID: "not-a-media-id"
            )
        )
    }

    func testConversationOrderingPutsPinnedFirstThenMostRecent() {
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        let conversations = [
            Conversation(id: "a", title: "A", participantUserIds: [], unreadCount: 0, updatedAt: older),
            Conversation(id: "b", title: "B", participantUserIds: [], unreadCount: 0, updatedAt: newer),
            Conversation(id: "c", title: "C", participantUserIds: [], unreadCount: 0, updatedAt: older),
        ]
        let ordered = ConversationListPolicy.ordered(conversations, pinnedIds: ["c"])
        XCTAssertEqual(ordered.map(\.id), ["c", "b", "a"])
    }

    func testConversationOrderingIsDeterministicOnEqualTimestamps() {
        let date = Date(timeIntervalSince1970: 5_000)
        let conversations = [
            Conversation(id: "z", title: "Z", participantUserIds: [], unreadCount: 0, updatedAt: date),
            Conversation(id: "a", title: "A", participantUserIds: [], unreadCount: 0, updatedAt: date),
        ]
        let ordered = ConversationListPolicy.ordered(conversations, pinnedIds: [])
        XCTAssertEqual(ordered.map(\.id), ["a", "z"])
    }

    func testTogglingMembershipAddsAndRemoves() {
        XCTAssertEqual(ConversationListPolicy.togglingMembership("x", in: nil), ["x"])
        XCTAssertEqual(ConversationListPolicy.togglingMembership("x", in: ["x", "y"]), ["y"])
        XCTAssertEqual(ConversationListPolicy.togglingMembership("z", in: ["x"]), ["x", "z"])
    }

    private func makeQueuedOwnershipMessage(
        attachmentID: String,
        localStorageKey: String,
        conversationID: String,
        messageID: UUID = UUID()
    ) throws -> LocalMessage {
        let createdAt = Date(timeIntervalSince1970: 1_780_000_000)
        let record = try XCTUnwrap(LocalMediaRecordPolicy.queuedOutgoing(
            id: attachmentID,
            messageID: messageID,
            conversationID: conversationID,
            mediaType: "application/pdf",
            fileSize: 1_024,
            localStorageKey: localStorageKey,
            storesInline: false,
            now: createdAt,
            localStorageKind: .protectedFile
        ))
        return LocalMessage(
            id: messageID,
            conversationId: conversationID,
            senderId: "10000000-0000-4000-8000-000000000001",
            body: "Document",
            createdAt: createdAt,
            sentAt: nil,
            state: .queued,
            failureReason: nil,
            isOutgoing: true,
            pendingAttachment: LocalPendingAttachment(
                mediaType: "application/pdf",
                caption: nil,
                localStorageKey: localStorageKey,
                byteCount: 1_024
            ),
            localMediaRecords: [record]
        )
    }

    private func makeUploadingOwnershipMessage(
        attachmentID: String,
        localStorageKey: String,
        conversationID: String
    ) throws -> LocalMessage {
        var message = try makeQueuedOwnershipMessage(
            attachmentID: attachmentID,
            localStorageKey: localStorageKey,
            conversationID: conversationID
        )
        XCTAssertTrue(LocalMediaRecordPolicy.markUploading(
            &message,
            attachmentID: attachmentID
        ))
        XCTAssertTrue(LocalMediaRecordPolicy.setCiphertextSpool(
            &message,
            attachmentID: attachmentID,
            byteSize: 1_088,
            sha256: String(repeating: "b", count: 64)
        ))
        return message
    }

    private func uncheckedCheckpoint(
        _ message: LocalMessage,
        attachmentID: String,
        storageKey: String,
        nextOffset: Int64
    ) -> LocalMessage {
        var proposed = message
        guard var records = proposed.localMediaRecords,
              let index = records.firstIndex(where: { $0.id == attachmentID })
        else {
            XCTFail("ownership fixture is missing its target record")
            return message
        }
        records[index].resumableUpload = LocalMediaResumableUpload(
            uploadID: attachmentID,
            storageKey: storageKey,
            nextOffset: nextOffset,
            maxChunkBytes: 256,
            expiresAt: "2026-09-01T00:00:00Z"
        )
        proposed.localMediaRecords = records
        return proposed
    }

    private func rosterSupports(
        version: String,
        build: Int?,
        platform: String = "ios",
        capable: Bool = true
    ) throws -> Bool {
        let conversationID = "0a1b2c3d-0000-4000-8000-000000000010"
        let currentDeviceID = "0a1b2c3d-0000-4000-8000-000000000011"
        let recipientUserID = "0a1b2c3d-0000-4000-8000-000000000012"
        let recipientDeviceID = "0a1b2c3d-0000-4000-8000-000000000013"
        var client: [String: Any] = [
            "platform": platform,
            "version": version,
            "capabilities": [MessagingRichMediaCapabilityPolicy.deviceCapabilityKey: capable],
        ]
        if let build { client["build"] = build }
        let data = try JSONSerialization.data(withJSONObject: [
            "conversation_id": conversationID,
            "devices": [[
                "device_id": recipientDeviceID,
                "user_id": recipientUserID,
                "client": client,
            ]],
        ])
        let roster = try JSONDecoder().decode(MessagingDeviceRosterDTO.self, from: data)
        return MessagingRichMediaCapabilityPolicy.supports(
            mediaType: "audio/mp4",
            roster: roster,
            conversationID: conversationID,
            currentDeviceID: currentDeviceID,
            recipientUserID: recipientUserID
        )
    }
}
