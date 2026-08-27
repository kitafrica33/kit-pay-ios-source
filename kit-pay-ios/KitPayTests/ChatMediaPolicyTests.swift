import XCTest
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
        XCTAssertEqual(KitChatMediaKind(mediaType: "video/quicktime"), .video)
        XCTAssertEqual(KitChatMediaKind(mediaType: "application/pdf"), .document)
        XCTAssertEqual(KitChatMediaKind(mediaType: "something/unknown"), .document)
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
