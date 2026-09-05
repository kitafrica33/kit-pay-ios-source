import XCTest
import AVFoundation
import Combine
import UIKit
@testable import KitPay

final class ChatMediaPolicyTests: XCTestCase {
    @MainActor
    func testStoppingAnIdleVoicePlayerDoesNotInvalidateSwiftUIAgain() {
        let player = VoiceNotePlayer.shared
        player.stop()
        var updates = 0
        let subscription = player.objectWillChange.sink { updates += 1 }

        player.stop()
        player.stop()

        XCTAssertEqual(updates, 0,
                       "Repeated video-layer updates must not create an idle-player render loop")
        withExtendedLifetime(subscription) {}
    }

    @MainActor
    func testStoppingPausedPlaybackClearsStateOnce() {
        let player = VoiceNotePlayer.shared
        player.toggle(data: AndroidCallToneRenderer.ringbackWAV, id: UUID(),
                      context: VoiceNotePlaybackContext(
                        conversationID: UUID().uuidString, speaker: "Test", conversationTitle: "Test"
                      ))
        player.pause()
        XCTAssertNotNil(player.playingID)
        var updates = 0
        let subscription = player.objectWillChange.sink { updates += 1 }
        player.stop()
        XCTAssertNil(player.playingID)
        XCTAssertGreaterThan(updates, 0)
        let firstStopUpdates = updates

        player.stop()

        XCTAssertEqual(updates, firstStopUpdates)
        withExtendedLifetime(subscription) {}
    }

    @MainActor
    func testRetiredVoicePlayerCallbacksCannotStopReplacementPlayback() async throws {
        let bytes = AndroidCallToneRenderer.ringbackWAV
        let retiredPlayer = try AVAudioPlayer(data: bytes)
        let replacementID = UUID()
        let player = VoiceNotePlayer.shared
        defer { player.stop() }
        player.toggle(data: bytes, id: replacementID, context: VoiceNotePlaybackContext(
            conversationID: UUID().uuidString, speaker: "Test", conversationTitle: "Test"
        ))
        player.pause()
        XCTAssertEqual(player.playingID, replacementID)

        player.audioPlayerDidFinishPlaying(retiredPlayer, successfully: true)
        player.audioPlayerDecodeErrorDidOccur(retiredPlayer, error: nil)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(player.playingID, replacementID)
        XCTAssertTrue(player.isPaused)
    }

    func testMediaClockRejectsUnrepresentableDurationsWithoutTrapping() {
        for invalid in [Double.nan, .infinity, -.infinity, -1, Double(Int.max), .greatestFiniteMagnitude] {
            XCTAssertEqual(ChatMediaPlaybackClock.label(invalid), "--:--")
        }
        XCTAssertEqual(ChatMediaPlaybackClock.label(0), "0:00")
        XCTAssertEqual(ChatMediaPlaybackClock.label(59.6), "1:00")
        XCTAssertEqual(ChatMediaPlaybackClock.label(125), "2:05")
        XCTAssertEqual(ChatMediaPlaybackClock.label(3600), "60:00")
    }

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
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: url.deletingLastPathComponent().path
        )
#if targetEnvironment(simulator)
        // Simulator files live on the host filesystem, which may omit NSFileProtectionKey.
        // If the runtime does expose it, it must still agree with the production policy above.
        if let protection = attributes[.protectionKey] as? FileProtectionType {
            XCTAssertEqual(protection, .completeUnlessOpen)
        }
        if let protection = directoryAttributes[.protectionKey] as? FileProtectionType {
            XCTAssertEqual(protection, .completeUnlessOpen)
        }
#else
        XCTAssertEqual(
            attributes[.protectionKey] as? FileProtectionType,
            .completeUnlessOpen
        )
        XCTAssertEqual(
            directoryAttributes[.protectionKey] as? FileProtectionType,
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

    func testLegacyReceivedVideoMigrationStreamsLargeFilesAndBoundsOfflineFallback() {
        let large = KitChatMediaLimits.maximumInlineCacheBytes + 1
        XCTAssertEqual(
            LegacyReceivedVideoMigrationPolicy.source(
                plaintextByteCount: large,
                allowsDownload: true,
                isOnline: true,
                secureMessagingAvailable: true,
                hasRemoteStorageKey: true,
                hasAuthenticatedSession: true
            ),
            .streamedRemote
        )
        XCTAssertEqual(
            LegacyReceivedVideoMigrationPolicy.source(
                plaintextByteCount: large,
                allowsDownload: true,
                isOnline: false,
                secureMessagingAvailable: true,
                hasRemoteStorageKey: true,
                hasAuthenticatedSession: true
            ),
            .unavailable
        )
        XCTAssertEqual(
            LegacyReceivedVideoMigrationPolicy.source(
                plaintextByteCount: KitChatMediaLimits.maximumInlineCacheBytes,
                allowsDownload: false,
                isOnline: false,
                secureMessagingAvailable: false,
                hasRemoteStorageKey: true,
                hasAuthenticatedSession: false
            ),
            .smallLocalBlob
        )
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

    func testLegacyInlineReceivedVideoPromotionClearsBytesAndKeepsExactIdentity() throws {
        let bytes = Data(repeating: 0x4e, count: 4_000)
        let descriptor = try makeDescriptor(
            mediaType: "video/mp4",
            plaintextByteSize: bytes.count,
            caption: "A received clip"
        )
        var message = LocalMessage(
            id: UUID(),
            conversationId: UUID().uuidString.lowercased(),
            senderId: UUID().uuidString.lowercased(),
            body: descriptor.encoded,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            sentAt: Date(timeIntervalSince1970: 1_700_000_001),
            state: .received,
            failureReason: nil,
            isOutgoing: false,
            attachmentData: bytes
        )

        XCTAssertTrue(LocalMediaRecordPolicy.migrateAndRecover(&message))
        XCTAssertEqual(message.localMediaRecords?.first?.localStorageKind, .encryptedState)
        XCTAssertEqual(message.localMediaRecords?.first?.downloadState, .downloaded)

        XCTAssertTrue(LocalMediaRecordPolicy.promoteInlineReceivedToProtectedFile(
            &message,
            attachmentID: descriptor.attachmentID,
            remoteStorageKey: descriptor.storageKey,
            localStorageKey: descriptor.attachmentID,
            expectedInlineData: bytes,
            now: Date(timeIntervalSince1970: 1_700_000_002)
        ))
        XCTAssertNil(message.attachmentData)
        let promoted = try XCTUnwrap(message.localMediaRecords?.first)
        XCTAssertEqual(promoted.localStorageKind, .protectedFile)
        XCTAssertEqual(promoted.localStorageKey, descriptor.attachmentID)
        XCTAssertEqual(promoted.remoteEncryptedObjectID, descriptor.storageKey)
        XCTAssertEqual(promoted.availabilityState, .localCached)
        XCTAssertEqual(promoted.downloadState, .downloaded)
        XCTAssertEqual(promoted.encryptionState, .decrypted)
        XCTAssertTrue(promoted.isStructurallyValid)
        XCTAssertFalse(LocalMediaRecordPolicy.promoteInlineReceivedToProtectedFile(
            &message,
            attachmentID: descriptor.attachmentID,
            remoteStorageKey: descriptor.storageKey,
            localStorageKey: descriptor.attachmentID,
            expectedInlineData: bytes
        ))
    }

    func testLegacyInlineReceivedVideoPromotionRejectsStaleEqualSizedBytesAtomically() throws {
        let currentBytes = Data(repeating: 0x1a, count: 4_000)
        let staleBytes = Data(repeating: 0x2b, count: currentBytes.count)
        let descriptor = try makeDescriptor(
            mediaType: "video/mp4",
            plaintextByteSize: currentBytes.count
        )
        var message = LocalMessage(
            id: UUID(),
            conversationId: UUID().uuidString.lowercased(),
            senderId: UUID().uuidString.lowercased(),
            body: descriptor.encoded,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            sentAt: Date(timeIntervalSince1970: 1_700_000_001),
            state: .received,
            failureReason: nil,
            isOutgoing: false,
            attachmentData: currentBytes
        )
        XCTAssertTrue(LocalMediaRecordPolicy.migrateAndRecover(&message))
        let original = message

        XCTAssertFalse(LocalMediaRecordPolicy.promoteInlineReceivedToProtectedFile(
            &message,
            attachmentID: descriptor.attachmentID,
            remoteStorageKey: descriptor.storageKey,
            localStorageKey: descriptor.attachmentID,
            expectedInlineData: staleBytes
        ))
        XCTAssertEqual(message, original)
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
        monitor.begin(
            mediaID: mediaID,
            at: captured,
            producerScope: monitor.captureProducerScope()
        )

        let visible = try XCTUnwrap(
            monitor.markVisible(
                mediaID: mediaID,
                at: captured.addingTimeInterval(0.010),
                producerScope: monitor.captureProducerScope()
            )
        )
        XCTAssertEqual(
            try XCTUnwrap(visible.captureToVisibleMilliseconds),
            10,
            accuracy: 0.001
        )
        XCTAssertNil(visible.captureToPlayableMilliseconds)

        let playable = try XCTUnwrap(
            monitor.markPlayable(
                mediaID: mediaID,
                at: captured.addingTimeInterval(0.014),
                producerScope: monitor.captureProducerScope()
            )
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
            monitor.markPlayable(
                mediaID: mediaID,
                at: captured.addingTimeInterval(5),
                producerScope: monitor.captureProducerScope()
            )
        )
        XCTAssertEqual(
            try XCTUnwrap(repeated.captureToPlayableMilliseconds),
            14,
            accuracy: 0.001
        )

        let encrypted = try XCTUnwrap(
            monitor.markEncrypted(
                mediaID: mediaID,
                at: captured.addingTimeInterval(1),
                producerScope: monitor.captureProducerScope()
            )
        )
        XCTAssertEqual(
            try XCTUnwrap(encrypted.captureToEncryptedMilliseconds),
            1_000,
            accuracy: 0.001
        )
        let accepted = try XCTUnwrap(
            monitor.markServerAccepted(
                mediaID: mediaID,
                at: captured.addingTimeInterval(2),
                producerScope: monitor.captureProducerScope()
            )
        )
        XCTAssertEqual(
            try XCTUnwrap(accepted.captureToServerAcceptedMilliseconds),
            2_000,
            accuracy: 0.001
        )
        XCTAssertNil(monitor.markVisible(
            mediaID: mediaID,
            at: captured.addingTimeInterval(3),
            producerScope: monitor.captureProducerScope()
        ))
    }

    @MainActor
    func testRecipientHydrationMonitorUsesEarliestDescriptorObservation() throws {
        let monitor = LocalMediaPerformanceMonitor()
        let mediaID = UUID()
        let first = Date(timeIntervalSince1970: 200)
        monitor.beginRecipientHydration(
            mediaID: mediaID,
            descriptorObservedAt: first,
            producerScope: monitor.captureProducerScope()
        )
        monitor.beginRecipientHydration(
            mediaID: mediaID,
            descriptorObservedAt: first.addingTimeInterval(1),
            producerScope: monitor.captureProducerScope()
        )
        let hydrated = try XCTUnwrap(
            monitor.markRecipientHydrated(
                mediaID: mediaID,
                at: first.addingTimeInterval(2.5),
                producerScope: monitor.captureProducerScope()
            )
        )
        XCTAssertEqual(
            try XCTUnwrap(hydrated.recipientDescriptorToLocalMilliseconds),
            2_500,
            accuracy: 0.001
        )
        XCTAssertNil(monitor.markRecipientHydrated(
            mediaID: mediaID,
            producerScope: monitor.captureProducerScope()
        ))
    }

    @MainActor
    func testFastServerAcceptanceDoesNotEraseLaterLocalAvailabilityMetrics() throws {
        let monitor = LocalMediaPerformanceMonitor()
        let mediaID = UUID()
        let captured = Date(timeIntervalSince1970: 300)
        monitor.begin(
            mediaID: mediaID,
            at: captured,
            producerScope: monitor.captureProducerScope()
        )

        let accepted = try XCTUnwrap(
            monitor.markServerAccepted(
                mediaID: mediaID,
                at: captured.addingTimeInterval(0.004),
                producerScope: monitor.captureProducerScope()
            )
        )
        XCTAssertEqual(
            try XCTUnwrap(accepted.captureToServerAcceptedMilliseconds),
            4,
            accuracy: 0.001
        )
        let visible = try XCTUnwrap(
            monitor.markVisible(
                mediaID: mediaID,
                at: captured.addingTimeInterval(0.009),
                producerScope: monitor.captureProducerScope()
            )
        )
        XCTAssertEqual(
            try XCTUnwrap(visible.captureToVisibleMilliseconds),
            9,
            accuracy: 0.001
        )
        let playable = try XCTUnwrap(
            monitor.markPlayable(
                mediaID: mediaID,
                at: captured.addingTimeInterval(0.011),
                producerScope: monitor.captureProducerScope()
            )
        )
        XCTAssertEqual(
            try XCTUnwrap(playable.captureToPlayableMilliseconds),
            11,
            accuracy: 0.001
        )
        XCTAssertNil(monitor.markVisible(
            mediaID: mediaID,
            at: captured.addingTimeInterval(1),
            producerScope: monitor.captureProducerScope()
        ))
    }

    @MainActor
    func testMediaDiagnosticExportContainsMeasurementsButNoMediaIdentifier() throws {
        let monitor = LocalMediaPerformanceMonitor()
        let mediaID = UUID()
        let captured = Date(timeIntervalSince1970: 500)
        monitor.begin(
            mediaID: mediaID,
            at: captured,
            producerScope: monitor.captureProducerScope()
        )
        monitor.begin(
            mediaID: mediaID,
            at: captured.addingTimeInterval(1),
            kind: .video,
            byteCount: 4_096,
            duration: 12.5,
            producerScope: monitor.captureProducerScope()
        )
        monitor.markVisible(
            mediaID: mediaID,
            at: captured.addingTimeInterval(0.010),
            producerScope: monitor.captureProducerScope()
        )
        monitor.markPlayable(
            mediaID: mediaID,
            at: captured.addingTimeInterval(0.020),
            producerScope: monitor.captureProducerScope()
        )
        monitor.markEncrypted(
            mediaID: mediaID,
            at: captured.addingTimeInterval(1),
            producerScope: monitor.captureProducerScope()
        )
        monitor.markServerAccepted(
            mediaID: mediaID,
            at: captured.addingTimeInterval(2),
            producerScope: monitor.captureProducerScope()
        )
        let playbackOutcomes: [(LocalMediaPlaybackOutcome, Double?)] = [
            (.preparationFailed, nil),
            (.started, 0.25),
            (.stalled, 3),
            (.failedToEnd, 8),
            (.completed, 12.5)
        ]
        for (outcome, position) in playbackOutcomes {
            monitor.recordPlayback(
                outcome: outcome,
                mediaID: mediaID,
                isOutgoing: true,
                byteCount: 4_096,
                expectedDuration: 12.5,
                position: position,
                producerScope: monitor.captureProducerScope()
            )
        }

        let report = monitor.exportReport()
        XCTAssertFalse(report.localizedCaseInsensitiveContains(mediaID.uuidString))
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(report.utf8)) as? [String: Any]
        )
        XCTAssertEqual(root["schemaVersion"] as? Int, 1)
        XCTAssertEqual(root["recordCount"] as? Int, 6)
        let records = try XCTUnwrap(root["records"] as? [[String: Any]])
        let timing = try XCTUnwrap(records.first)
        XCTAssertEqual(timing["event"] as? String, "media_timing")
        XCTAssertEqual(timing["direction"] as? String, "outgoing")
        XCTAssertEqual(timing["kind"] as? String, "video")
        XCTAssertEqual(timing["byteCount"] as? Int, 4_096)
        XCTAssertEqual(timing["durationSeconds"] as? Double, 12.5)
        XCTAssertEqual(
            try XCTUnwrap(timing["captureToVisibleMilliseconds"] as? Double),
            10,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(timing["captureToPlayableMilliseconds"] as? Double),
            20,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(timing["captureToEncryptedMilliseconds"] as? Double),
            1_000,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(timing["captureToServerAcceptedMilliseconds"] as? Double),
            2_000,
            accuracy: 0.001
        )
        XCTAssertEqual(
            records.dropFirst().compactMap { $0["playbackOutcome"] as? String },
            ["preparation_failed", "started", "stalled", "failed_to_end", "completed"]
        )
    }

    @MainActor
    func testPlaybackFailureDiagnosticsPersistOnlySanitizedAVPlayerFacts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kit-video-diagnostics-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        let persistenceURL = directory.appendingPathComponent("report.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let secret = "https://media.example/private/customer-video.mp4?token=secret"
        let diagnostic = LocalMediaPlaybackDiagnostic.sanitized(
            failureSource: .failedToEndNotification,
            itemStatus: .failed,
            errorDomain: "NSURLErrorDomain",
            errorCode: -1_005,
            errorLogDomain: secret,
            errorLogStatusCode: -12_345,
            errorLogEventCount: 8_000
        )

        XCTAssertEqual(diagnostic.errorDomain, .urlLoading)
        XCTAssertEqual(diagnostic.errorLogDomain, .other)
        XCTAssertEqual(diagnostic.errorLogEventCount, 32)
        XCTAssertFalse(diagnostic.supportReference.contains(secret))

        let monitor = LocalMediaPerformanceMonitor(persistenceURL: persistenceURL)
        let mediaID = UUID()
        monitor.recordPlayback(
            outcome: .failedToEnd,
            mediaID: mediaID,
            isOutgoing: false,
            byteCount: 8_192,
            expectedDuration: 9,
            position: 1.1,
            diagnostic: diagnostic,
            producerScope: monitor.captureProducerScope()
        )
        monitor.flushPendingPersistence()

        let persisted = try String(contentsOf: persistenceURL, encoding: .utf8)
        let exported = monitor.exportReport()
        for text in [persisted, exported] {
            XCTAssertFalse(text.contains(secret))
            XCTAssertFalse(text.localizedCaseInsensitiveContains(mediaID.uuidString))
        }
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(exported.utf8)) as? [String: Any]
        )
        let record = try XCTUnwrap((root["records"] as? [[String: Any]])?.last)
        XCTAssertEqual(record["playbackFailureSource"] as? String, "failed_to_end_notification")
        XCTAssertEqual(record["playbackItemStatus"] as? String, "failed")
        XCTAssertEqual(record["playbackErrorDomain"] as? String, "url_loading")
        XCTAssertEqual(record["playbackErrorCode"] as? Int, -1_005)
        XCTAssertEqual(record["playbackErrorLogDomain"] as? String, "other")
        XCTAssertEqual(record["playbackErrorLogStatusCode"] as? Int, -12_345)
        XCTAssertEqual(record["playbackErrorLogEventCount"] as? Int, 32)
    }

    @MainActor
    func testMediaDiagnosticsPersistAcrossMonitorRecreationAndCanBeCleared() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kit-media-diagnostics-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        let persistenceURL = directory.appendingPathComponent("report.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaID = UUID()

        let first = LocalMediaPerformanceMonitor(persistenceURL: persistenceURL)
        first.beginRecipientHydration(
            mediaID: mediaID,
            descriptorObservedAt: Date(timeIntervalSince1970: 700),
            kind: .voice,
            byteCount: 8_192,
            duration: 4,
            producerScope: first.captureProducerScope()
        )
        first.markRecipientHydrated(
            mediaID: mediaID,
            at: Date(timeIntervalSince1970: 701.5),
            producerScope: first.captureProducerScope()
        )
        first.flushPendingPersistence()
        let persistedText = try String(contentsOf: persistenceURL, encoding: .utf8)
        XCTAssertFalse(persistedText.localizedCaseInsensitiveContains(mediaID.uuidString))
        let attributes = try FileManager.default.attributesOfItem(atPath: persistenceURL.path)
#if targetEnvironment(simulator)
        if let protection = attributes[.protectionKey] as? FileProtectionType {
            XCTAssertEqual(protection, .completeUntilFirstUserAuthentication)
        }
#else
        XCTAssertEqual(
            attributes[.protectionKey] as? FileProtectionType,
            .completeUntilFirstUserAuthentication
        )
#endif
        let persistedRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(persistedText.utf8)) as? [String: Any]
        )
        let persistedRecords = try XCTUnwrap(
            persistedRoot["records"] as? [[String: Any]]
        )
        XCTAssertNil(persistedRecords.first?["id"])
        let correlationToken = try XCTUnwrap(
            persistedRecords.first?["localCorrelationTokenSHA256"] as? String
        )
        XCTAssertEqual(correlationToken.count, 64)
        XCTAssertTrue(correlationToken.allSatisfy { $0.isHexDigit })

        let relaunched = LocalMediaPerformanceMonitor(persistenceURL: persistenceURL)
        XCTAssertEqual(relaunched.reportRecordCount, 1)
        // The raw media ID is never persisted. Playback supplies its own coarse metadata, and the
        // protected one-way correlation token is still omitted from the exported report.
        relaunched.recordPlayback(
            outcome: .started,
            mediaID: mediaID,
            isOutgoing: false,
            byteCount: 8_192,
            expectedDuration: 4,
            position: 0.25,
            producerScope: relaunched.captureProducerScope()
        )
        let report = relaunched.exportReport()
        XCTAssertFalse(report.localizedCaseInsensitiveContains(mediaID.uuidString))
        XCTAssertTrue(report.contains("recipientDescriptorToLocalMilliseconds"))
        XCTAssertTrue(report.contains("1500"))
        let reportRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(report.utf8)) as? [String: Any]
        )
        let reportRecords = try XCTUnwrap(reportRoot["records"] as? [[String: Any]])
        XCTAssertEqual(reportRecords.last?["byteCount"] as? Int, 8_192)
        XCTAssertEqual(reportRecords.last?["direction"] as? String, "incoming")

        XCTAssertTrue(relaunched.clearReport())
        XCTAssertEqual(relaunched.reportRecordCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: persistenceURL.path))
        XCTAssertEqual(
            LocalMediaPerformanceMonitor(persistenceURL: persistenceURL).reportRecordCount,
            0
        )
    }

    @MainActor
    func testMediaDiagnosticsCompleteOutgoingTimingAfterMonitorRecreation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kit-media-diagnostics-relaunch-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        let persistenceURL = directory.appendingPathComponent("report.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaID = UUID()
        let captured = Date(timeIntervalSince1970: 900)

        let first = LocalMediaPerformanceMonitor(persistenceURL: persistenceURL)
        first.begin(
            mediaID: mediaID,
            at: captured,
            kind: .video,
            byteCount: 16_384,
            duration: 20,
            producerScope: first.captureProducerScope()
        )
        first.markVisible(
            mediaID: mediaID,
            at: captured.addingTimeInterval(0.010),
            producerScope: first.captureProducerScope()
        )
        first.markPlayable(
            mediaID: mediaID,
            at: captured.addingTimeInterval(0.020),
            producerScope: first.captureProducerScope()
        )
        first.flushPendingPersistence()

        let relaunched = LocalMediaPerformanceMonitor(persistenceURL: persistenceURL)
        let encrypted = try XCTUnwrap(
            relaunched.markEncrypted(
                mediaID: mediaID,
                at: captured.addingTimeInterval(5),
                producerScope: relaunched.captureProducerScope()
            )
        )
        XCTAssertEqual(
            try XCTUnwrap(encrypted.captureToEncryptedMilliseconds),
            5_000,
            accuracy: 0.001
        )
        let accepted = try XCTUnwrap(
            relaunched.markServerAccepted(
                mediaID: mediaID,
                at: captured.addingTimeInterval(8),
                producerScope: relaunched.captureProducerScope()
            )
        )
        XCTAssertEqual(
            try XCTUnwrap(accepted.captureToServerAcceptedMilliseconds),
            8_000,
            accuracy: 0.001
        )

        relaunched.flushPendingPersistence()
        let report = relaunched.exportReport()
        XCTAssertFalse(report.localizedCaseInsensitiveContains(mediaID.uuidString))
        XCTAssertFalse(report.contains("localCorrelationTokenSHA256"))
        let reportRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(report.utf8)) as? [String: Any]
        )
        let records = try XCTUnwrap(reportRoot["records"] as? [[String: Any]])
        let timing = try XCTUnwrap(records.first)
        XCTAssertEqual(
            try XCTUnwrap(timing["captureToVisibleMilliseconds"] as? Double),
            10,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(timing["captureToPlayableMilliseconds"] as? Double),
            20,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(timing["captureToEncryptedMilliseconds"] as? Double),
            5_000,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(timing["captureToServerAcceptedMilliseconds"] as? Double),
            8_000,
            accuracy: 0.001
        )
    }

    @MainActor
    func testTextSendDiagnosticsUseMonotonicOrderedMilestonesAndDoNotRestartOnRetry() throws {
        let monitor = LocalMediaPerformanceMonitor()
        let messageID = UUID()
        let scope = monitor.captureProducerScope()
        let start: UInt64 = 1_000_000_000
        monitor.beginTextSend(
            messageID: messageID,
            atUptimeNanoseconds: start,
            recordedAt: Date(timeIntervalSince1970: 1_000),
            producerScope: scope
        )

        // A retry with the same idempotency UUID must retain the original action timestamp.
        monitor.beginTextSend(
            messageID: messageID,
            atUptimeNanoseconds: start + 9_000_000,
            recordedAt: Date(timeIntervalSince1970: 2_000),
            producerScope: scope
        )
        XCTAssertEqual(monitor.reportRecordCount, 1)
        XCTAssertNil(monitor.markTextBubbleVisible(
            messageID: messageID,
            atUptimeNanoseconds: start + 10_000_000,
            producerScope: scope
        ))

        let committed = try XCTUnwrap(monitor.markTextOutboxCommitted(
            messageID: messageID,
            atUptimeNanoseconds: start + 12_400_000,
            producerScope: scope
        ))
        XCTAssertEqual(committed.actionToDurableOutboxCommitMilliseconds, 12)
        XCTAssertNil(committed.actionToVisibleLocalBubbleMilliseconds)

        let visible = try XCTUnwrap(monitor.markTextBubbleVisible(
            messageID: messageID,
            atUptimeNanoseconds: start + 18_600_000,
            producerScope: scope
        ))
        XCTAssertEqual(visible.actionToDurableOutboxCommitMilliseconds, 12)
        XCTAssertEqual(visible.actionToVisibleLocalBubbleMilliseconds, 19)

        // Re-renders and idempotent queue replays keep the first two observations.
        let repeatedCommit = try XCTUnwrap(monitor.markTextOutboxCommitted(
            messageID: messageID,
            atUptimeNanoseconds: start + 200_000_000,
            producerScope: scope
        ))
        let repeatedVisible = try XCTUnwrap(monitor.markTextBubbleVisible(
            messageID: messageID,
            atUptimeNanoseconds: start + 300_000_000,
            producerScope: scope
        ))
        XCTAssertEqual(repeatedCommit, visible)
        XCTAssertEqual(repeatedVisible, visible)
        XCTAssertEqual(monitor.reportRecordCount, 1)
    }

    @MainActor
    func testTextSendDiagnosticSerializationIsBoundedAndContainsNoMessageIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kit-text-send-diagnostics-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        let persistenceURL = directory.appendingPathComponent("report.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let monitor = LocalMediaPerformanceMonitor(persistenceURL: persistenceURL)
        let scope = monitor.captureProducerScope()
        var messageIDs: [UUID] = []

        for index in 0..<300 {
            let messageID = UUID()
            messageIDs.append(messageID)
            let start = UInt64(index + 1) * 1_000_000_000
            monitor.beginTextSend(
                messageID: messageID,
                atUptimeNanoseconds: start,
                recordedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                producerScope: scope
            )
            monitor.markTextOutboxCommitted(
                messageID: messageID,
                atUptimeNanoseconds: start + 7_400_000,
                producerScope: scope
            )
            monitor.markTextBubbleVisible(
                messageID: messageID,
                atUptimeNanoseconds: start + 11_600_000,
                producerScope: scope
            )
        }

        XCTAssertEqual(monitor.reportRecordCount, 256)
        monitor.flushPendingPersistence()
        let persisted = try String(contentsOf: persistenceURL, encoding: .utf8)
        let exported = monitor.exportReport()
        for messageID in messageIDs {
            XCTAssertFalse(persisted.localizedCaseInsensitiveContains(messageID.uuidString))
            XCTAssertFalse(exported.localizedCaseInsensitiveContains(messageID.uuidString))
        }
        XCTAssertFalse(persisted.contains("localCorrelationTokenSHA256"))
        XCTAssertFalse(exported.contains("localCorrelationTokenSHA256"))

        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(exported.utf8)) as? [String: Any]
        )
        let records = try XCTUnwrap(root["records"] as? [[String: Any]])
        XCTAssertEqual(records.count, 256)
        XCTAssertTrue(records.allSatisfy { $0["event"] as? String == "text_send_timing" })
        XCTAssertTrue(records.allSatisfy {
            $0["actionToDurableOutboxCommitMilliseconds"] as? Double == 7
                && $0["actionToVisibleLocalBubbleMilliseconds"] as? Double == 12
                && $0["kind"] == nil
                && $0["byteCount"] == nil
                && $0["durationSeconds"] == nil
        })
    }

    @MainActor
    func testTextSendDiagnosticsAreClearedAndFencedAcrossAccounts() throws {
        let monitor = LocalMediaPerformanceMonitor()
        let messageID = UUID()
        let staleScope = monitor.captureProducerScope()
        monitor.beginTextSend(
            messageID: messageID,
            atUptimeNanoseconds: 1_000_000_000,
            producerScope: staleScope
        )
        monitor.markTextOutboxCommitted(
            messageID: messageID,
            atUptimeNanoseconds: 1_010_000_000,
            producerScope: staleScope
        )
        XCTAssertEqual(monitor.reportRecordCount, 1)

        XCTAssertTrue(monitor.suspendRecordingAndClearReport())
        XCTAssertEqual(monitor.reportRecordCount, 0)
        monitor.resumeRecordingForFreshAccount()
        let freshScope = monitor.captureProducerScope()
        monitor.beginTextSend(
            messageID: messageID,
            atUptimeNanoseconds: 2_000_000_000,
            producerScope: freshScope
        )
        XCTAssertNil(monitor.markTextOutboxCommitted(
            messageID: messageID,
            atUptimeNanoseconds: 2_010_000_000,
            producerScope: staleScope
        ))
        XCTAssertNil(monitor.markTextBubbleVisible(
            messageID: messageID,
            atUptimeNanoseconds: 2_020_000_000,
            producerScope: staleScope
        ))

        let committed = try XCTUnwrap(monitor.markTextOutboxCommitted(
            messageID: messageID,
            atUptimeNanoseconds: 2_015_000_000,
            producerScope: freshScope
        ))
        XCTAssertEqual(committed.actionToDurableOutboxCommitMilliseconds, 15)
        let visible = try XCTUnwrap(monitor.markTextBubbleVisible(
            messageID: messageID,
            atUptimeNanoseconds: 2_025_000_000,
            producerScope: freshScope
        ))
        XCTAssertEqual(visible.actionToVisibleLocalBubbleMilliseconds, 25)
        XCTAssertEqual(monitor.reportRecordCount, 1)
    }

    @MainActor
    func testMediaDiagnosticsSuspendAcrossAccountBoundaryUntilFreshGenerationBegins() throws {
        let monitor = LocalMediaPerformanceMonitor()
        let mediaID = UUID()
        let freshCaptured = Date(timeIntervalSince1970: 900)
        let staleScope = monitor.captureProducerScope()
        monitor.begin(
            mediaID: mediaID,
            kind: .image,
            byteCount: 1_024,
            producerScope: staleScope
        )
        XCTAssertEqual(monitor.reportRecordCount, 1)

        XCTAssertTrue(monitor.suspendRecordingAndClearReport())
        monitor.begin(
            mediaID: mediaID,
            kind: .video,
            byteCount: 2_048,
            producerScope: staleScope
        )
        XCTAssertEqual(monitor.reportRecordCount, 0)

        monitor.resumeRecordingForFreshAccount()
        let freshScope = monitor.captureProducerScope()
        monitor.begin(
            mediaID: mediaID,
            at: freshCaptured,
            kind: .document,
            byteCount: 4_096,
            duration: 12,
            producerScope: freshScope
        )

        // An attachment UUID can legitimately recur under a different account. Every mutation
        // must reject the prior producer generation even when a fresh row has the same UUID.
        monitor.begin(
            mediaID: mediaID,
            at: freshCaptured.addingTimeInterval(-100),
            direction: .incoming,
            kind: .video,
            byteCount: 2_048,
            duration: 3,
            producerScope: staleScope
        )
        monitor.updateMetadata(
            mediaID: mediaID,
            direction: .incoming,
            kind: .voice,
            byteCount: 8_192,
            duration: 4,
            producerScope: staleScope
        )
        XCTAssertNil(monitor.markVisible(
            mediaID: mediaID,
            at: freshCaptured.addingTimeInterval(1),
            producerScope: staleScope
        ))
        XCTAssertNil(monitor.markPlayable(
            mediaID: mediaID,
            at: freshCaptured.addingTimeInterval(2),
            producerScope: staleScope
        ))
        XCTAssertNil(monitor.markEncrypted(
            mediaID: mediaID,
            at: freshCaptured.addingTimeInterval(3),
            producerScope: staleScope
        ))
        XCTAssertNil(monitor.markServerAccepted(
            mediaID: mediaID,
            at: freshCaptured.addingTimeInterval(4),
            producerScope: staleScope
        ))
        monitor.beginRecipientHydration(
            mediaID: mediaID,
            descriptorObservedAt: freshCaptured.addingTimeInterval(5),
            kind: .audio,
            byteCount: 16_384,
            duration: 5,
            producerScope: staleScope
        )
        XCTAssertNil(monitor.markRecipientHydrated(
            mediaID: mediaID,
            at: freshCaptured.addingTimeInterval(6),
            producerScope: staleScope
        ))
        monitor.recordPlayback(
            outcome: .started,
            mediaID: mediaID,
            isOutgoing: true,
            byteCount: 2_048,
            expectedDuration: 3,
            position: 0.25,
            producerScope: staleScope
        )

        let freshVisible = try XCTUnwrap(monitor.markVisible(
            mediaID: mediaID,
            at: freshCaptured.addingTimeInterval(0.010),
            producerScope: freshScope
        ))
        XCTAssertEqual(
            try XCTUnwrap(freshVisible.captureToVisibleMilliseconds),
            10,
            accuracy: 0.001
        )
        XCTAssertEqual(monitor.reportRecordCount, 1)

        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(monitor.exportReport().utf8))
                as? [String: Any]
        )
        let records = try XCTUnwrap(root["records"] as? [[String: Any]])
        let timing = try XCTUnwrap(records.first)
        XCTAssertEqual(timing["direction"] as? String, "outgoing")
        XCTAssertEqual(timing["kind"] as? String, "document")
        XCTAssertEqual(timing["byteCount"] as? Int, 4_096)
        XCTAssertEqual(timing["durationSeconds"] as? Double, 12)
        XCTAssertNil(timing["captureToPlayableMilliseconds"])
        XCTAssertNil(timing["captureToEncryptedMilliseconds"])
        XCTAssertNil(timing["captureToServerAcceptedMilliseconds"])
        XCTAssertNil(timing["recipientDescriptorToLocalMilliseconds"])
    }

    @MainActor
    func testMediaDiagnosticsKeepOnlyNewestBoundedRecords() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kit-media-diagnostics-bound-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        let persistenceURL = directory.appendingPathComponent("report.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let monitor = LocalMediaPerformanceMonitor(persistenceURL: persistenceURL)
        for index in 0..<300 {
            monitor.begin(
                mediaID: UUID(),
                at: Date(timeIntervalSince1970: TimeInterval(index)),
                kind: .image,
                byteCount: index + 1,
                producerScope: monitor.captureProducerScope()
            )
        }
        XCTAssertEqual(monitor.reportRecordCount, 256)
        monitor.flushPendingPersistence()
        XCTAssertEqual(
            LocalMediaPerformanceMonitor(persistenceURL: persistenceURL).reportRecordCount,
            256
        )
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

    func testVideoPlaybackInspectionUsesContainerBytesInsteadOfAnIncorrectMIME() throws {
        let inspected = try ChatVideoPlaybackAssetPolicy.inspect(
            header: isoBaseMediaHeader(majorBrand: "qt  "),
            declaredMediaType: "video/mp4",
            sourcePathExtension: "mp4"
        )

        XCTAssertEqual(inspected.container, .quickTime)
        XCTAssertEqual(inspected.playbackMediaType, "video/quicktime")
        XCTAssertTrue(inspected.requiresCanonicalExtension)
    }

    func testVideoPlaybackInspectionRecognizesMP4AndWebM() throws {
        let mp4 = try ChatVideoPlaybackAssetPolicy.inspect(
            header: isoBaseMediaHeader(majorBrand: "mp42"),
            declaredMediaType: "video/mp4",
            sourcePathExtension: "mp4"
        )
        XCTAssertEqual(mp4.container, .isoBaseMedia)
        XCTAssertEqual(mp4.playbackMediaType, "video/mp4")
        XCTAssertFalse(mp4.requiresCanonicalExtension)

        let webM = try ChatVideoPlaybackAssetPolicy.inspect(
            header: Data([0x1a, 0x45, 0xdf, 0xa3, 0x01, 0x00]),
            declaredMediaType: "video/webm",
            sourcePathExtension: "webm"
        )
        XCTAssertEqual(webM.container, .webM)
        XCTAssertFalse(webM.requiresCanonicalExtension)
    }

    func testVideoPlaybackInspectionRejectsBytesThatAreNotAVideoContainer() {
        XCTAssertThrowsError(try ChatVideoPlaybackAssetPolicy.inspect(
            header: Data("not a video".utf8),
            declaredMediaType: "video/mp4",
            sourcePathExtension: "mp4"
        )) { error in
            XCTAssertEqual(error as? ChatVideoPlaybackPreparationError, .invalidFile)
        }
    }

    func testVideoPlaybackPreparationRejectsAFileWhoseAuthenticatedSizeDoesNotMatch() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kit-video-size-mismatch-\(UUID().uuidString).mp4"
        )
        try isoBaseMediaHeader(majorBrand: "mp42").write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            _ = try await ChatVideoPlaybackAssetPolicy.prepare(
                fileURL: url,
                declaredMediaType: "video/mp4",
                expectedByteCount: 999
            )
            XCTFail("A partial or replaced local file must not reach AVPlayer")
        } catch {
            XCTAssertEqual(error as? ChatVideoPlaybackPreparationError, .invalidFile)
        }
    }

    func testCompleteMP4PassesThePlaybackProbe() async throws {
        let url = try await makePlayableVideo(fileType: .mp4, pathExtension: "mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let byteCount = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
                .intValue
        )

        let prepared = try await ChatVideoPlaybackAssetPolicy.prepare(
            fileURL: url,
            declaredMediaType: "video/mp4",
            expectedByteCount: byteCount
        )
        defer { prepared.playbackFileLease.release() }

        XCTAssertGreaterThan(prepared.duration, 0)
        XCTAssertNotEqual(prepared.playbackURL, url)
        XCTAssertEqual(prepared.playbackURL.pathExtension, "mp4")
        XCTAssertTrue(prepared.playbackFileLease.isValid())
    }

    func testQuickTimeBytesMislabeledAsMP4GetAPlayableMOVAlias() async throws {
        let source = try await makePlayableVideo(fileType: .mov, pathExtension: "mov")
        let mislabeled = try ChatMediaTempFiles.linkTemporaryFile(
            from: source,
            mediaType: "video/mp4"
        )
        defer {
            try? FileManager.default.removeItem(at: source)
            ChatMediaTempFiles.removeTemporaryFile(mislabeled)
        }
        let byteCount = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: mislabeled.path)[.size] as? NSNumber)?
                .intValue
        )

        let prepared = try await ChatVideoPlaybackAssetPolicy.prepare(
            fileURL: mislabeled,
            declaredMediaType: "video/mp4",
            expectedByteCount: byteCount
        )
        defer { prepared.playbackFileLease.release() }

        XCTAssertEqual(prepared.playbackURL.pathExtension, "mov")
        XCTAssertEqual(prepared.asset.url, prepared.playbackURL)
        XCTAssertNotEqual(prepared.asset.url, mislabeled)
        XCTAssertGreaterThan(prepared.duration, 0)
    }

    @MainActor
    func testPlaybackAliasSurvivesParentCleanupUntilPlayerLeaseReleases() async throws {
        let generated = try await makePlayableVideo(fileType: .mp4, pathExtension: "mp4")
        defer { try? FileManager.default.removeItem(at: generated) }
        let parentURL = try ChatMediaTempFiles.linkTemporaryFile(
            from: generated,
            mediaType: "video/mp4"
        )
        let byteCount = try fileByteCount(parentURL)
        let prepared = try await ChatVideoPlaybackAssetPolicy.prepare(
            fileURL: parentURL,
            declaredMediaType: "video/mp4",
            expectedByteCount: byteCount
        )
        let playerOwnedURL = prepared.playbackURL

        // This is the real SwiftUI ordering hazard: a cover's parent binding can clean up its
        // source before the child receives onDisappear and tears down AVPlayer.
        ChatMediaTempFiles.removeTemporaryFile(parentURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: parentURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: playerOwnedURL.path))
        XCTAssertTrue(prepared.playbackFileLease.isValid())
        let isPlayable = try await prepared.asset.load(.isPlayable)
        XCTAssertTrue(isPlayable)

        prepared.playbackFileLease.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: playerOwnedURL.path))
    }

    func testPlaybackArtifactRejectsTruncationAndEqualSizedPathReplacement() throws {
        let truncatedURL = try ChatMediaTempFiles.writeTemporaryFile(
            data: Data(repeating: 0x31, count: 4_096),
            mediaType: "video/mp4"
        )
        defer { ChatMediaTempFiles.removeTemporaryFile(truncatedURL) }
        let truncatedIdentity = try ChatVideoPlaybackArtifactPolicy.identity(
            at: truncatedURL,
            expectedByteCount: 4_096
        )
        let writer = try FileHandle(forWritingTo: truncatedURL)
        try writer.truncate(atOffset: 1_024)
        try writer.close()
        XCTAssertFalse(ChatVideoPlaybackArtifactPolicy.matches(
            fileURL: truncatedURL,
            expectedIdentity: truncatedIdentity
        ))

        let replacedURL = try ChatMediaTempFiles.writeTemporaryFile(
            data: Data(repeating: 0x41, count: 4_096),
            mediaType: "video/mp4"
        )
        defer { ChatMediaTempFiles.removeTemporaryFile(replacedURL) }
        let retainedHandle = try FileHandle(forReadingFrom: replacedURL)
        defer { try? retainedHandle.close() }
        let replacedIdentity = try ChatVideoPlaybackArtifactPolicy.identity(
            at: replacedURL,
            expectedByteCount: 4_096
        )
        try FileManager.default.removeItem(at: replacedURL)
        try Data(repeating: 0x42, count: 4_096).write(to: replacedURL, options: .atomic)
        XCTAssertFalse(ChatVideoPlaybackArtifactPolicy.matches(
            fileURL: replacedURL,
            expectedIdentity: replacedIdentity
        ))
    }

    @MainActor
    func testFileBackedPosterNeverGivesMislabeledQuickTimeURLToGenerator() async throws {
        let source = try await makePlayableVideo(fileType: .mov, pathExtension: "mov")
        let mislabeled = try ChatMediaTempFiles.linkTemporaryFile(
            from: source,
            mediaType: "video/mp4"
        )
        defer {
            try? FileManager.default.removeItem(at: source)
            ChatMediaTempFiles.removeTemporaryFile(mislabeled)
        }
        let byteCount = try fileByteCount(mislabeled)
        let probeImage = try onePixelCGImage()
        var generatorURL: URL?

        let thumbnail = await ChatVideoPosterGenerator.thumbnail(
            forKey: UUID().uuidString,
            fileURL: mislabeled,
            declaredMediaType: "video/mp4",
            expectedByteCount: byteCount,
            protectedOriginalLease: nil,
            maximumSize: CGSize(width: 32, height: 32)
        ) { asset, _ in
            generatorURL = asset.url
            return probeImage
        }

        XCTAssertNotNil(thumbnail)
        let canonicalURL = try XCTUnwrap(generatorURL)
        XCTAssertEqual(canonicalURL.pathExtension, "mov")
        XCTAssertNotEqual(canonicalURL, mislabeled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: canonicalURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mislabeled.path))
    }

    @MainActor
    func testDataBackedPosterCanonicalizesQuickTimeAndRemovesAllTemporaryFiles() async throws {
        let source = try await makePlayableVideo(fileType: .mov, pathExtension: "mov")
        defer { try? FileManager.default.removeItem(at: source) }
        let data = try Data(contentsOf: source)
        let directoriesBefore = try previewTemporaryDirectories()
        let probeImage = try onePixelCGImage()
        var generatorURL: URL?

        let thumbnail = await ChatVideoPosterGenerator.thumbnail(
            forKey: UUID().uuidString,
            data: data,
            declaredMediaType: "video/mp4",
            expectedByteCount: data.count,
            maximumSize: CGSize(width: 32, height: 32)
        ) { asset, _ in
            generatorURL = asset.url
            return probeImage
        }

        XCTAssertNotNil(thumbnail)
        let canonicalURL = try XCTUnwrap(generatorURL)
        XCTAssertEqual(canonicalURL.pathExtension, "mov")
        XCTAssertFalse(FileManager.default.fileExists(atPath: canonicalURL.path))
        XCTAssertEqual(try previewTemporaryDirectories(), directoriesBefore)
    }

    @MainActor
    func testPosterRejectsWrongSizeAndTruncatedVideoBeforeStartingGenerator() async throws {
        let source = try await makePlayableVideo(fileType: .mov, pathExtension: "mov")
        defer { try? FileManager.default.removeItem(at: source) }
        let data = try Data(contentsOf: source)
        let probeImage = try onePixelCGImage()
        var generationCount = 0
        let generation: ChatVideoPosterGenerator.ImageGeneration = { _, _ in
            generationCount += 1
            return probeImage
        }

        let wrongSize = await ChatVideoPosterGenerator.thumbnail(
            forKey: UUID().uuidString,
            data: data,
            declaredMediaType: "video/mp4",
            expectedByteCount: data.count + 1,
            maximumSize: CGSize(width: 32, height: 32),
            generateImage: generation
        )
        let truncated = Data(data.prefix(24))
        let truncatedResult = await ChatVideoPosterGenerator.thumbnail(
            forKey: UUID().uuidString,
            data: truncated,
            declaredMediaType: "video/mp4",
            expectedByteCount: truncated.count,
            maximumSize: CGSize(width: 32, height: 32),
            generateImage: generation
        )

        XCTAssertNil(wrongSize)
        XCTAssertNil(truncatedResult)
        XCTAssertEqual(generationCount, 0)
    }

    @MainActor
    func testPosterRemovesCanonicalAliasAfterFailureAndCancellation() async throws {
        let source = try await makePlayableVideo(fileType: .mov, pathExtension: "mov")
        let mislabeled = try ChatMediaTempFiles.linkTemporaryFile(
            from: source,
            mediaType: "video/mp4"
        )
        defer {
            try? FileManager.default.removeItem(at: source)
            ChatMediaTempFiles.removeTemporaryFile(mislabeled)
        }
        let byteCount = try fileByteCount(mislabeled)
        var generatorURLs: [URL] = []

        let failed = await ChatVideoPosterGenerator.thumbnail(
            forKey: UUID().uuidString,
            fileURL: mislabeled,
            declaredMediaType: "video/mp4",
            expectedByteCount: byteCount,
            protectedOriginalLease: nil,
            maximumSize: CGSize(width: 32, height: 32)
        ) { asset, _ in
            generatorURLs.append(asset.url)
            throw PosterProbeError.expectedFailure
        }
        let cancelled = await ChatVideoPosterGenerator.thumbnail(
            forKey: UUID().uuidString,
            fileURL: mislabeled,
            declaredMediaType: "video/mp4",
            expectedByteCount: byteCount,
            protectedOriginalLease: nil,
            maximumSize: CGSize(width: 32, height: 32)
        ) { asset, _ in
            generatorURLs.append(asset.url)
            throw CancellationError()
        }

        XCTAssertNil(failed)
        XCTAssertNil(cancelled)
        XCTAssertEqual(generatorURLs.count, 2)
        XCTAssertTrue(generatorURLs.allSatisfy { $0.pathExtension == "mov" })
        XCTAssertTrue(generatorURLs.allSatisfy {
            !FileManager.default.fileExists(atPath: $0.path)
        })
    }

    @MainActor
    func testConcurrentPosterRequestsShareOneGeneratorProbe() async throws {
        let source = try await makePlayableVideo(fileType: .mp4, pathExtension: "mp4")
        defer { try? FileManager.default.removeItem(at: source) }
        let byteCount = try fileByteCount(source)
        let probeImage = try onePixelCGImage()
        let contentKey = UUID().uuidString
        var generationCount = 0
        let generation: ChatVideoPosterGenerator.ImageGeneration = { _, _ in
            generationCount += 1
            try await Task.sleep(nanoseconds: 20_000_000)
            return probeImage
        }

        async let first = ChatVideoPosterGenerator.thumbnail(
            forKey: contentKey,
            fileURL: source,
            declaredMediaType: "video/mp4",
            expectedByteCount: byteCount,
            protectedOriginalLease: nil,
            maximumSize: CGSize(width: 32, height: 32),
            generateImage: generation
        )
        async let second = ChatVideoPosterGenerator.thumbnail(
            forKey: contentKey,
            fileURL: source,
            declaredMediaType: "video/mp4",
            expectedByteCount: byteCount,
            protectedOriginalLease: nil,
            maximumSize: CGSize(width: 32, height: 32),
            generateImage: generation
        )
        let results = await (first, second)

        XCTAssertNotNil(results.0)
        XCTAssertNotNil(results.1)
        XCTAssertEqual(generationCount, 1)
    }

    func testGalleryVideoPreparationIsAdmittedOnlyForTheActivePage() {
        XCTAssertTrue(GalleryVideoActivationPolicy.permitsPreparation(isActive: true))
        XCTAssertFalse(GalleryVideoActivationPolicy.permitsPreparation(isActive: false))
    }

    @MainActor
    func testGalleryReplacementIgnoresCallbacksQueuedByItsPreviousPlayer() async throws {
        let source = try await makePlayableVideo(fileType: .mp4, pathExtension: "mp4")
        defer { try? FileManager.default.removeItem(at: source) }
        let byteCount = try fileByteCount(source)
        let controller = GalleryVideoController()
        defer { controller.teardown(allowsPictureInPictureRetention: false) }
        let identity = ChatVideoGalleryIdentity(messageID: UUID(), itemIndex: 0)
        let contentKey = UUID().uuidString
        let firstPrepared = await controller.prepare(
            fileURL: source,
            ownsFile: false,
            protectedOriginalLease: nil,
            mediaType: "video/mp4",
            expectedByteCount: byteCount,
            contentKey: contentKey,
            mediaID: UUID(),
            isOutgoing: false,
            galleryIdentity: identity,
            restoreFromPictureInPicture: { _ in }
        )
        XCTAssertTrue(firstPrepared)
        let oldItem = try XCTUnwrap(controller.player?.currentItem)

        controller.toggleMute()
        controller.setScrubbing(true)
        controller.deactivatePage()

        let replacementPrepared = await controller.prepare(
            fileURL: source,
            ownsFile: false,
            protectedOriginalLease: nil,
            mediaType: "video/mp4",
            expectedByteCount: byteCount,
            contentKey: contentKey,
            mediaID: UUID(),
            isOutgoing: false,
            galleryIdentity: identity,
            restoreFromPictureInPicture: { _ in }
        )
        XCTAssertTrue(replacementPrepared)
        let replacementItem = try XCTUnwrap(controller.player?.currentItem)
        XCTAssertFalse(oldItem === replacementItem)
        XCTAssertTrue(controller.isMuted)
        XCTAssertTrue(try XCTUnwrap(controller.player).isMuted,
                      "Revisiting a muted page must not restart its audio behind a muted icon")
        controller.togglePlayback()
        controller.receivePlaybackTime(CMTime(seconds: 0.5, preferredTimescale: 600),
                                       from: replacementItem)
        XCTAssertEqual(controller.currentTime, 0.5,
                       "A page left during scrubbing must accept its replacement's progress")

        // These deliveries represent actor tasks already queued before observer removal. They
        // must be rejected at delivery even though a replacement player is now active.
        controller.receivePlaybackTime(CMTime(seconds: 1, preferredTimescale: 600), from: oldItem)
        controller.handlePlaybackEnded(item: oldItem)
        XCTAssertEqual(controller.currentTime, 0.5)
        XCTAssertTrue(controller.isPlaying,
                      "An old end notification must not pause, rewind or close the new player")

        controller.handlePlaybackEnded(item: replacementItem)
        XCTAssertTrue(controller.isPlaying,
                      "A queued end callback cannot finish an item that is now near its start")
        controller.pause()

        ChatMediaAccountLifetime.invalidate()
        controller.togglePlayback()
        XCTAssertFalse(controller.isPlaying,
                       "A retained gallery from the previous account cannot restart playback")
        let stalePrepared = await controller.prepare(
            fileURL: source, ownsFile: false, protectedOriginalLease: nil,
            mediaType: "video/mp4", expectedByteCount: byteCount, contentKey: contentKey,
            mediaID: UUID(), isOutgoing: false, galleryIdentity: identity,
            restoreFromPictureInPicture: { _ in XCTFail("Retired account restored PiP") }
        )
        XCTAssertFalse(stalePrepared)
    }

    @MainActor
    func testReceivedVideoPlaysToEndAndReplaysAfterParentFileCleanup() async throws {
        for fileType in [AVFileType.mp4, .mov] {
            let generated = try await makePlayableVideo(
                fileType: fileType, pathExtension: fileType == .mp4 ? "mp4" : "mov",
                frameCount: 72, framesPerSecond: 24
            )
            defer { try? FileManager.default.removeItem(at: generated) }
            // Some Android providers label QuickTime bytes as MP4. Exercise the same protected
            // received-file boundary for both containers, including that historical mismatch.
            let received = try ChatMediaTempFiles.copyTemporaryFile(
                from: generated, mediaType: "video/mp4"
            )
            defer { ChatMediaTempFiles.removeTemporaryFile(received) }
            let controller = GalleryVideoController()
            defer { controller.teardown(allowsPictureInPictureRetention: false) }
            let prepared = await controller.prepare(
                fileURL: received, ownsFile: false, protectedOriginalLease: nil,
                mediaType: "video/mp4", expectedByteCount: try fileByteCount(received),
                contentKey: UUID().uuidString, mediaID: UUID(), isOutgoing: false,
                galleryIdentity: .init(messageID: UUID(), itemIndex: 1),
                restoreFromPictureInPicture: { _ in }
            )
            XCTAssertTrue(prepared)
            let player = try XCTUnwrap(controller.player)
            let item = try XCTUnwrap(player.currentItem)
            let playbackURL = try XCTUnwrap(controller.playbackURL)
            let decodedFrames = VideoDecodeProbe()
            item.add(decodedFrames.output)
            let frameObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(value: 1, timescale: 24), queue: .main
            ) { time in
                Task { @MainActor in decodedFrames.consume(at: time) }
            }
            defer {
                player.removeTimeObserver(frameObserver)
                item.remove(decodedFrames.output)
            }
            XCTAssertEqual(controller.duration, 3, accuracy: 0.1)
            controller.toggleMute()
            ChatMediaTempFiles.removeTemporaryFile(received)
            try FileManager.default.removeItem(at: generated)
            XCTAssertFalse(FileManager.default.fileExists(atPath: received.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: playbackURL.path))

            for _ in 0 ..< 2 {
                let previousFrameCount = decodedFrames.count
                let ended = expectation(
                    forNotification: .AVPlayerItemDidPlayToEndTime, object: item
                )
                controller.togglePlayback()
                await fulfillment(of: [ended], timeout: 12)
                let completed = try await waitForVideoCondition { controller.hasReachedEnd }
                XCTAssertTrue(completed)
                XCTAssertFalse(controller.isPlaying)
                XCTAssertNil(controller.errorMessage)
                XCTAssertNil(item.error)
                XCTAssertGreaterThan(decodedFrames.count, previousFrameCount,
                                     "Playback must decode frames, not only advance a timeline")
                XCTAssertEqual(controller.currentTime, controller.duration, accuracy: 0.1)
                XCTAssertGreaterThanOrEqual(item.currentTime().seconds, controller.duration - 0.1,
                                            "Completion must leave the final frame visible")
                controller.receivePlaybackTime(.zero, from: item)
                XCTAssertEqual(controller.currentTime, controller.duration,
                               "A queued progress callback cannot reset completed progress")
            }
            controller.teardown(allowsPictureInPictureRetention: false)
            XCTAssertFalse(FileManager.default.fileExists(atPath: playbackURL.path))
        }
    }

    @MainActor
    func testGalleryScrubbingRejectsInvalidTimesAndPreservesPauseIntent() async throws {
        let source = try await makePlayableVideo(
            fileType: .mp4, pathExtension: "mp4", frameCount: 72, framesPerSecond: 24
        )
        defer { try? FileManager.default.removeItem(at: source) }
        let controller = GalleryVideoController()
        defer { controller.teardown(allowsPictureInPictureRetention: false) }
        let prepared = await controller.prepare(
            fileURL: source, ownsFile: false, protectedOriginalLease: nil,
            mediaType: "video/mp4", expectedByteCount: try fileByteCount(source),
            contentKey: UUID().uuidString, mediaID: UUID(), isOutgoing: false,
            galleryIdentity: .init(messageID: UUID(), itemIndex: nil),
            restoreFromPictureInPicture: { _ in }
        )
        XCTAssertTrue(prepared)
        let player = try XCTUnwrap(controller.player)
        let item = try XCTUnwrap(player.currentItem)
        controller.toggleMute()
        controller.togglePlayback()
        controller.setScrubbing(true)
        controller.scrub(to: 1)
        XCTAssertEqual(player.rate, 0, "Scrubbing must suspend decoding at playback speed")
        for invalid in [Double.nan, .infinity, -.infinity] {
            controller.scrub(to: invalid)
            XCTAssertEqual(controller.currentTime, 1)
        }
        controller.scrub(to: -1)
        XCTAssertEqual(controller.currentTime, 0)
        controller.scrub(to: .greatestFiniteMagnitude)
        XCTAssertEqual(controller.currentTime, controller.duration)
        controller.scrub(to: 1)
        controller.receivePlaybackTime(CMTime(seconds: 2, preferredTimescale: 600), from: item)
        controller.handlePlaybackEnded(item: item)
        XCTAssertEqual(controller.currentTime, 1)
        XCTAssertTrue(controller.isPlaying)
        XCTAssertFalse(controller.hasReachedEnd)
        controller.setScrubbing(false)
        controller.pause()
        let sought = try await waitForVideoCondition {
            abs(item.currentTime().seconds - 1) < 0.1
        }
        XCTAssertTrue(sought)
        XCTAssertFalse(controller.isPlaying, "Seek completion cannot undo an explicit pause")
        XCTAssertEqual(player.rate, 0)

        // VoiceOver changes Slider values without starting a drag. It must seek the real item.
        controller.scrub(to: 2)
        let accessibleSeek = try await waitForVideoCondition {
            abs(item.currentTime().seconds - 2) < 0.1
        }
        XCTAssertTrue(accessibleSeek)
        XCTAssertFalse(controller.isPlaying)
        XCTAssertEqual(player.rate, 0)
    }

    @MainActor
    private final class VideoDecodeProbe {
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        ])
        private(set) var count = 0

        func consume(at time: CMTime) {
            guard output.hasNewPixelBuffer(forItemTime: time),
                  output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) != nil
            else { return }
            count += 1
        }
    }

    @MainActor
    private func waitForVideoCondition(_ condition: () -> Bool) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @MainActor
    func testGalleryVideoActivationUsesOnlyAnAlreadyCachedPoster() throws {
        let contentKey = UUID().uuidString
        XCTAssertNil(GalleryVideoActivationPolicy.cachedPoster(forKey: contentKey))
        XCTAssertFalse(ChatVideoPosterGenerator.hasInFlightPoster(forKey: contentKey))

        let bubblePoster = UIImage(cgImage: try onePixelCGImage())
        ChatMediaThumbnailStore.shared.store(
            bubblePoster,
            forKey: contentKey,
            maxPixel: GalleryVideoActivationPolicy.conversationPosterMaxPixel
        )

        XCTAssertTrue(
            GalleryVideoActivationPolicy.cachedPoster(forKey: contentKey) === bubblePoster
        )
        XCTAssertFalse(ChatVideoPosterGenerator.hasInFlightPoster(forKey: contentKey))
    }

    @MainActor
    func testPlaybackClaimCancelsAndDrainsPosterThenSuppressesNewDecodes() async throws {
        let source = try await makePlayableVideo(fileType: .mp4, pathExtension: "mp4")
        defer { try? FileManager.default.removeItem(at: source) }
        let byteCount = try fileByteCount(source)
        let probeImage = try onePixelCGImage()
        let contentKey = UUID().uuidString
        var generationCount = 0
        var firstGenerationFinished = false
        let generationStarted = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )

        let posterTask = Task { @MainActor in
            await ChatVideoPosterGenerator.thumbnail(
                forKey: contentKey,
                fileURL: source,
                declaredMediaType: "video/mp4",
                expectedByteCount: byteCount,
                protectedOriginalLease: nil,
                maximumSize: CGSize(width: 32, height: 32)
            ) { _, _ in
                generationCount += 1
                generationStarted.continuation.yield(())
                defer { firstGenerationFinished = true }
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return probeImage
            }
        }
        var generationIterator = generationStarted.stream.makeAsyncIterator()
        _ = await generationIterator.next()
        generationStarted.continuation.finish()
        XCTAssertTrue(ChatVideoPosterGenerator.hasInFlightPoster(forKey: contentKey))

        let acquiredClaim = await ChatVideoPosterGenerator.acquirePlayback(forKey: contentKey)
        let claim = try XCTUnwrap(acquiredClaim)
        defer { ChatVideoPosterGenerator.releasePlayback(claim) }
        let cancelledPoster = await posterTask.value
        XCTAssertNil(cancelledPoster)
        XCTAssertTrue(firstGenerationFinished)

        let suppressed = await ChatVideoPosterGenerator.thumbnail(
            forKey: contentKey,
            fileURL: source,
            declaredMediaType: "video/mp4",
            expectedByteCount: byteCount,
            protectedOriginalLease: nil,
            maximumSize: CGSize(width: 32, height: 32)
        ) { _, _ in
            generationCount += 1
            return probeImage
        }
        XCTAssertNil(suppressed)
        XCTAssertEqual(generationCount, 1)

        ChatVideoPosterGenerator.releasePlayback(claim)
        let resumed = await ChatVideoPosterGenerator.thumbnail(
            forKey: contentKey,
            fileURL: source,
            declaredMediaType: "video/mp4",
            expectedByteCount: byteCount,
            protectedOriginalLease: nil,
            maximumSize: CGSize(width: 32, height: 32)
        ) { _, _ in
            generationCount += 1
            return probeImage
        }
        XCTAssertNotNil(resumed)
        XCTAssertEqual(generationCount, 2)
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

    private func isoBaseMediaHeader(majorBrand: String) -> Data {
        var bytes = Data([0, 0, 0, 24])
        bytes.append(Data("ftyp".utf8))
        bytes.append(Data(majorBrand.utf8))
        bytes.append(Data([0, 0, 0, 0]))
        bytes.append(Data("isom".utf8))
        bytes.append(Data("mp42".utf8))
        return bytes
    }

    private enum PosterProbeError: Error {
        case expectedFailure
    }

    private func fileByteCount(_ url: URL) throws -> Int {
        try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
                .intValue
        )
    }

    @MainActor
    private func onePixelCGImage() throws -> CGImage {
        try XCTUnwrap(
            UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
                .image { context in
                    UIColor.black.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
                }
                .cgImage
        )
    }

    private func previewTemporaryDirectories() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(
            at: FileManager.default.temporaryDirectory,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix("kit-preview-")
        }.map(\.path))
    }

    private func makePlayableVideo(
        fileType: AVFileType,
        pathExtension: String,
        frameCount: Int = 2,
        framesPerSecond: Int32 = 1
    ) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kit-playback-probe-\(UUID().uuidString).\(pathExtension)"
        )
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 16,
                AVVideoHeightKey: 16,
            ]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: 16,
                kCVPixelBufferHeightKey as String: 16,
            ]
        )
        guard writer.canAdd(input) else {
            throw ChatVideoPlaybackPreparationError.unsupportedVideo
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? ChatVideoPlaybackPreparationError.unsupportedVideo
        }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else {
            throw ChatVideoPlaybackPreparationError.unsupportedVideo
        }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
              let buffer
        else { throw ChatVideoPlaybackPreparationError.unsupportedVideo }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0, CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        for frame in 0 ..< frameCount {
            while !input.isReadyForMoreMediaData, writer.status == .writing, clock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            guard input.isReadyForMoreMediaData,
                  adaptor.append(
                      buffer,
                      withPresentationTime: CMTime(value: Int64(frame), timescale: framesPerSecond)
                  )
            else { throw writer.error ?? ChatVideoPlaybackPreparationError.unsupportedVideo }
        }
        writer.endSession(atSourceTime: CMTime(value: Int64(frameCount), timescale: framesPerSecond))
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw writer.error ?? ChatVideoPlaybackPreparationError.unsupportedVideo
        }
        return url
    }
}
