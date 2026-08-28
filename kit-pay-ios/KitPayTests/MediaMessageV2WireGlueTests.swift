import Foundation
import XCTest
@testable import KitPay

/// Wire glue between the Foundation-only KITMEDIA2 core (`MediaMessageV2Models.swift`, pinned by
/// `MediaMessageV2ContractTests` on Linux and in CI) and the messaging wire types that only
/// compile against the app module: content binding, outer-row derivation, §4 rule 4 row
/// authentication, and the §5 send-request order checks. Contract v0.4 (449925d9…).
final class MediaMessageV2WireGlueTests: XCTestCase {
    private let clientMessageId = "55555555-5555-4555-8555-555555555555"
    private let recipientDeviceId = "99999999-9999-4999-8999-999999999999"
    private let rosterRevision = "v1:sha256:" + String(repeating: "a", count: 64)

    // Canonical outer order is ascending id — the display order below is deliberately the
    // reverse, so any code path that confuses the two fails these tests. Digests contain
    // letters so case transformations are never a silent no-op.
    private let idFirst = "11111111-1111-4111-8111-111111111111"
    private let idSecond = "22222222-2222-4222-8222-222222222222"
    private let shaFirst = "abcdef" + String(repeating: "1", count: 58)
    private let shaSecond = "fedcba" + String(repeating: "2", count: 58)

    private func makeItem(
        id: String,
        storageKey: String,
        mediaType: String,
        sha: String,
        keyByte: UInt8,
        plaintextByteSize: Int
    ) -> KitMediaMessageV2Descriptor.Item {
        KitMediaMessageV2Descriptor.Item(
            attachmentID: id,
            storageKey: storageKey,
            mediaType: mediaType,
            ciphertextByteSize: Int64(plaintextByteSize + 64 - (plaintextByteSize % 16)),
            ciphertextSHA256: sha,
            keyMaterial: Data(repeating: keyByte, count: 64),
            plaintextByteSize: plaintextByteSize
        )
    }

    /// Display order [second, first]; canonical outer order [first, second].
    private func makeDescriptor(caption: String? = nil) throws -> KitMediaMessageV2Descriptor {
        let displayedFirst = makeItem(
            id: idSecond,
            storageKey: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            mediaType: "video/mp4",
            sha: shaSecond,
            keyByte: 0x42,
            plaintextByteSize: 2_097_152
        )
        let displayedSecond = makeItem(
            id: idFirst,
            storageKey: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            mediaType: "image/jpeg",
            sha: shaFirst,
            keyByte: 0x41,
            plaintextByteSize: 1_048_576
        )
        return try XCTUnwrap(KitMediaMessageV2Descriptor(
            items: [displayedFirst, displayedSecond],
            caption: caption
        ))
    }

    private func makeV1Body() throws -> String {
        try KitMediaMessageDescriptor(
            attachmentID: idFirst,
            storageKey: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            mediaType: "image/jpeg",
            ciphertextByteSize: 1_048_640,
            ciphertextSHA256: shaFirst,
            keyMaterial: Data(repeating: 0x41, count: 64),
            plaintextByteSize: 1_048_576,
            caption: nil
        ).encoded
    }

    private func dto(
        _ row: EncryptedAttachmentRequest,
        sha: String? = nil,
        byteSize: Int64? = nil,
        mediaType: String? = nil,
        metadataCiphertext: String? = nil
    ) -> EncryptedAttachmentDTO {
        EncryptedAttachmentDTO(
            id: row.id,
            storageKey: row.storageKey,
            mediaType: mediaType ?? row.mediaType,
            byteSize: byteSize ?? row.byteSize,
            ciphertextSha256: sha ?? row.ciphertextSha256,
            encryptionMetadataCiphertext: metadataCiphertext
        )
    }

    private func makeEnvelope() throws -> EncryptedDeviceEnvelopeRequest {
        try EncryptedDeviceEnvelopeRequest(
            recipientDeviceId: recipientDeviceId,
            envelopeType: .message,
            ciphertext: Data([1, 2, 3]).base64EncodedString()
        )
    }

    // MARK: Content binding

    func testBindingBindsCanonicalV2BodyAsOneAttachmentMessage() throws {
        for caption in [nil, "Family photos"] {
            let descriptor = try makeDescriptor(caption: caption)
            let expected = try XCTUnwrap(descriptor.attachmentRequests)
            XCTAssertEqual(
                SecureMessagingContentBindingPolicy.kind(
                    for: descriptor.encoded,
                    replyToMessageID: nil,
                    attachments: expected
                ),
                .encryptedAttachment
            )
            // A media message may itself be a reply, exactly like v1.
            XCTAssertEqual(
                SecureMessagingContentBindingPolicy.kind(
                    for: descriptor.encoded,
                    replyToMessageID: clientMessageId,
                    attachments: expected
                ),
                .encryptedAttachment
            )
        }
    }

    func testBindingRequiresCanonicalOuterOrderRows() throws {
        let descriptor = try makeDescriptor()
        let expected = try XCTUnwrap(descriptor.attachmentRequests)
        // Display order offered where §5 canonical order is required.
        XCTAssertNil(SecureMessagingContentBindingPolicy.kind(
            for: descriptor.encoded,
            replyToMessageID: nil,
            attachments: expected.reversed()
        ))
    }

    func testBindingRejectsRowSetMismatches() throws {
        let descriptor = try makeDescriptor()
        let expected = try XCTUnwrap(descriptor.attachmentRequests)
        let intruder = try EncryptedAttachmentRequest(
            id: "33333333-3333-4333-8333-333333333333",
            storageKey: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
            mediaType: "application/pdf",
            byteSize: 1_088,
            ciphertextSha256: "abc123" + String(repeating: "d", count: 58)
        )
        for rows in [[], Array(expected.dropLast()), expected + [intruder]] {
            XCTAssertNil(SecureMessagingContentBindingPolicy.kind(
                for: descriptor.encoded,
                replyToMessageID: nil,
                attachments: rows
            ))
        }
        let resized = try EncryptedAttachmentRequest(
            id: expected[0].id,
            storageKey: expected[0].storageKey,
            mediaType: expected[0].mediaType,
            byteSize: expected[0].byteSize + 16,
            ciphertextSha256: expected[0].ciphertextSha256
        )
        XCTAssertNil(SecureMessagingContentBindingPolicy.kind(
            for: descriptor.encoded,
            replyToMessageID: nil,
            attachments: [resized, expected[1]]
        ))
    }

    func testBindingClosesRawDescriptorSmuggling() throws {
        let descriptor = try makeDescriptor()
        let expected = try XCTUnwrap(descriptor.attachmentRequests)
        // A valid v2 descriptor — which carries every attachment key — can never bind as a
        // plain `encrypted` text bubble.
        XCTAssertNil(SecureMessagingContentBindingPolicy.kind(
            for: descriptor.encoded,
            replyToMessageID: nil,
            attachments: []
        ))
        // The descriptor is byte-exact: leading whitespace or truncation is a strict-parse
        // failure, and a failed parse binds to no kind even with plausible rows attached.
        for broken in [" " + descriptor.encoded,
                       String(descriptor.encoded.dropLast()),
                       "KITMEDIA2:v=2&n=2"] {
            XCTAssertNil(SecureMessagingContentBindingPolicy.kind(
                for: broken,
                replyToMessageID: nil,
                attachments: expected
            ))
            XCTAssertNil(SecureMessagingContentBindingPolicy.kind(
                for: broken,
                replyToMessageID: nil,
                attachments: []
            ))
        }
        // Family-wide fail-closed (contract test 14): an unknown future family version — and
        // every other reserved-family spelling that fails its strict parse — binds to no wire
        // kind at all, with or without rows. Binding as `encrypted` is exactly how raw protocol
        // text would reach a bubble, a backup, or a retry composer; §4 rule 6 display hardening
        // renders the v2+ spellings as the generic placeholder instead.
        for familyText in ["KITMEDIA3:v=3&n=1",
                           "KITMEDIA999:",
                           KitMediaMessageFamilyPolicy.confinedPlaceholderBody,
                           "KITMEDIA1:"] {
            XCTAssertNil(SecureMessagingContentBindingPolicy.kind(
                for: familyText,
                replyToMessageID: nil,
                attachments: []
            ))
            XCTAssertNil(SecureMessagingContentBindingPolicy.kind(
                for: familyText,
                replyToMessageID: nil,
                attachments: expected
            ))
        }
        XCTAssertTrue(
            KitMediaMessageFamilyPolicy.requiresGenericAttachmentPlaceholder("KITMEDIA3:v=3&n=1")
        )
        XCTAssertTrue(
            KitMediaMessageFamilyPolicy.requiresGenericAttachmentPlaceholder("KITMEDIA999:")
        )
    }

    func testBindingLeavesV1AndPlainTextUntouched() throws {
        let v1Body = try makeV1Body()
        let v1Rows = KitMediaMessageDescriptor.attachments(for: v1Body)
        XCTAssertEqual(v1Rows.count, 1)
        XCTAssertEqual(
            SecureMessagingContentBindingPolicy.kind(
                for: v1Body,
                replyToMessageID: nil,
                attachments: v1Rows
            ),
            .encryptedAttachment
        )
        XCTAssertNil(SecureMessagingContentBindingPolicy.kind(
            for: v1Body,
            replyToMessageID: nil,
            attachments: []
        ))
        XCTAssertEqual(
            SecureMessagingContentBindingPolicy.kind(
                for: "hello",
                replyToMessageID: nil,
                attachments: []
            ),
            .encrypted
        )
        XCTAssertNil(SecureMessagingContentBindingPolicy.kind(
            for: "hello",
            replyToMessageID: nil,
            attachments: v1Rows
        ))
    }

    // MARK: Outer-row derivation

    func testAttachmentRequestsFollowCanonicalOuterOrder() throws {
        let descriptor = try makeDescriptor()
        let rows = try XCTUnwrap(descriptor.attachmentRequests)
        XCTAssertEqual(rows.map(\.id), [idFirst, idSecond])
        XCTAssertNotEqual(rows.map(\.id), descriptor.items.map(\.attachmentID))
        let byID = Dictionary(uniqueKeysWithValues: descriptor.items.map { ($0.attachmentID, $0) })
        for row in rows {
            let item = try XCTUnwrap(byID[row.id])
            XCTAssertEqual(row.storageKey, item.storageKey)
            XCTAssertEqual(row.mediaType, item.mediaType)
            XCTAssertEqual(row.byteSize, item.ciphertextByteSize)
            XCTAssertEqual(row.ciphertextSha256, item.ciphertextSHA256)
            XCTAssertEqual(row.ciphertextSha256, row.ciphertextSha256.lowercased())
        }
    }

    func testFamilyDerivationCoversBothVersionsAndFailsClosed() throws {
        let descriptor = try makeDescriptor()
        XCTAssertEqual(
            KitMediaMessageFamilyPolicy.attachmentRequests(for: descriptor.encoded),
            descriptor.attachmentRequests
        )
        let v1Body = try makeV1Body()
        XCTAssertEqual(
            KitMediaMessageFamilyPolicy.attachmentRequests(for: v1Body),
            KitMediaMessageDescriptor.attachments(for: v1Body)
        )
        for text in ["hello", String(descriptor.encoded.dropLast()), "KITMEDIA3:v=3&n=1"] {
            XCTAssertEqual(KitMediaMessageFamilyPolicy.attachmentRequests(for: text), [])
        }
    }

    // MARK: §4 rule 4 row authentication

    func testWireRowValidationAcceptsAnyPermutationOfTheSet() throws {
        let descriptor = try makeDescriptor()
        let rows = try XCTUnwrap(descriptor.attachmentRequests)
        XCTAssertTrue(descriptor.validates(rows.map { dto($0) }))
        XCTAssertTrue(descriptor.validates(rows.reversed().map { dto($0) }))
        // The receiver lowercases the outer digest before comparing.
        XCTAssertTrue(descriptor.validates(rows.map { dto($0, sha: $0.ciphertextSha256.uppercased()) }))
    }

    func testWireRowValidationRejectsTamperedRows() throws {
        let descriptor = try makeDescriptor()
        let rows = try XCTUnwrap(descriptor.attachmentRequests)
        let tampered: [[EncryptedAttachmentDTO?]?] = [
            nil,
            [],
            [dto(rows[0])],
            [dto(rows[0]), dto(rows[0])],
            [dto(rows[0]), dto(rows[1]), dto(rows[1])],
            [dto(rows[0]), nil],
            [dto(rows[0], sha: rows[1].ciphertextSha256), dto(rows[1], sha: rows[0].ciphertextSha256)],
            [dto(rows[0], byteSize: rows[0].byteSize + 16), dto(rows[1])],
            [dto(rows[0], mediaType: "image/png"), dto(rows[1])],
            [dto(rows[0], metadataCiphertext: "AAAA"), dto(rows[1])],
        ]
        for rowSet in tampered {
            XCTAssertFalse(descriptor.validates(rowSet), String(describing: rowSet))
        }
        let idless = EncryptedAttachmentDTO(
            id: nil,
            storageKey: rows[0].storageKey,
            mediaType: rows[0].mediaType,
            byteSize: rows[0].byteSize,
            ciphertextSha256: rows[0].ciphertextSha256,
            encryptionMetadataCiphertext: nil
        )
        XCTAssertFalse(descriptor.validates([idless, dto(rows[1])]))
    }

    func testFamilyWireRowValidationCoversBothVersionsAndPlainText() throws {
        let descriptor = try makeDescriptor()
        let rows = try XCTUnwrap(descriptor.attachmentRequests)
        XCTAssertTrue(KitMediaMessageFamilyPolicy.validatesWireRows(
            rows.reversed().map { dto($0) },
            forBody: descriptor.encoded
        ))
        XCTAssertFalse(KitMediaMessageFamilyPolicy.validatesWireRows(
            [dto(rows[0])],
            forBody: descriptor.encoded
        ))
        let v1Body = try makeV1Body()
        let v1Row = KitMediaMessageDescriptor.attachments(for: v1Body)[0]
        XCTAssertTrue(KitMediaMessageFamilyPolicy.validatesWireRows([dto(v1Row)], forBody: v1Body))
        XCTAssertFalse(KitMediaMessageFamilyPolicy.validatesWireRows(
            [dto(v1Row, byteSize: v1Row.byteSize + 16)],
            forBody: v1Body
        ))
        XCTAssertTrue(KitMediaMessageFamilyPolicy.validatesWireRows(nil, forBody: "hello"))
        XCTAssertFalse(KitMediaMessageFamilyPolicy.validatesWireRows([dto(v1Row)], forBody: "hello"))
    }

    // MARK: §5 send request

    func testSendRequestEnforcesCanonicalWireOrderForMultiRow() throws {
        let envelope = try makeEnvelope()
        let descriptor = try makeDescriptor()
        let rows = try XCTUnwrap(descriptor.attachmentRequests)

        let request = try SendEncryptedMessageRequest(
            clientMessageId: clientMessageId,
            rosterRevision: rosterRevision,
            kind: .encryptedAttachment,
            envelopes: [envelope],
            attachments: rows
        )
        XCTAssertEqual(request.attachments.map(\.id), [idFirst, idSecond])

        XCTAssertThrowsError(try SendEncryptedMessageRequest(
            clientMessageId: clientMessageId,
            rosterRevision: rosterRevision,
            kind: .encryptedAttachment,
            envelopes: [envelope],
            attachments: rows.reversed()
        ))

        // Multi-row digests must already be lowercase on the wire; the single-row v1 request
        // keeps its historical mixed-case tolerance.
        let uppercased = try rows.map { row in
            try EncryptedAttachmentRequest(
                id: row.id,
                storageKey: row.storageKey,
                mediaType: row.mediaType,
                byteSize: row.byteSize,
                ciphertextSha256: row.ciphertextSha256.uppercased()
            )
        }
        XCTAssertThrowsError(try SendEncryptedMessageRequest(
            clientMessageId: clientMessageId,
            rosterRevision: rosterRevision,
            kind: .encryptedAttachment,
            envelopes: [envelope],
            attachments: uppercased
        ))
        XCTAssertNoThrow(try SendEncryptedMessageRequest(
            clientMessageId: clientMessageId,
            rosterRevision: rosterRevision,
            kind: .encryptedAttachment,
            envelopes: [envelope],
            attachments: [uppercased[0]]
        ))

        // More rows than the v2 ceiling (8) fails even below the legacy wire cap (20).
        let nineRows = try (0 ... 8).map { index in
            try EncryptedAttachmentRequest(
                id: "00000000-0000-4000-8000-00000000000\(index)",
                storageKey: "99999999-9999-4999-8999-99999999900\(index)",
                mediaType: "image/jpeg",
                byteSize: 1_024,
                ciphertextSha256: shaFirst
            )
        }
        XCTAssertThrowsError(try SendEncryptedMessageRequest(
            clientMessageId: clientMessageId,
            rosterRevision: rosterRevision,
            kind: .encryptedAttachment,
            envelopes: [envelope],
            attachments: nineRows
        ))
    }

    // MARK: §6 fixtures

    private let admissionConversationID = "cccccccc-0000-4000-8000-000000000001"
    private let meUserID = "aaaaaaaa-0000-4000-8000-0000000000a1"
    private let meDeviceID = "aaaaaaaa-0000-4000-8000-0000000000d0"
    private let peerUserID = "bbbbbbbb-0000-4000-8000-0000000000b1"
    private let peerDeviceOneID = "bbbbbbbb-0000-4000-8000-0000000000d1"
    private let peerDeviceTwoID = "bbbbbbbb-0000-4000-8000-0000000000d2"

    private var canonicalMediaMessageBlock: [String: Any] {
        [
            "profile": MessagingMediaMessageV2CapabilityPolicy.profile,
            "ready": true,
            "max_attachments": KitMediaMessageV2Descriptor.maximumAttachmentCount,
            "max_descriptor_bytes": KitMediaMessageV2Descriptor.maximumDescriptorUTF8Bytes,
            "max_caption_utf8_bytes": KitMediaMessageV2Descriptor.maximumCaptionUTF8Bytes,
            "min_attachment_ciphertext_bytes":
                KitMediaMessageV2Descriptor.minimumAttachmentCiphertextBytes,
            "max_attachment_ciphertext_bytes":
                KitMediaMessageV2Descriptor.maximumAttachmentCiphertextBytes,
            "max_aggregate_ciphertext_bytes":
                KitMediaMessageV2Descriptor.maximumAggregateCiphertextBytes,
        ]
    }

    private var everyCapability: [String: Bool] {
        [
            MessagingMediaMessageV2CapabilityPolicy.deviceCapabilityKey: true,
            MessagingRichMediaCapabilityPolicy.deviceCapabilityKey: true,
            MessagingRichMediaCapabilityPolicy.extendedSizeDeviceCapabilityKey: true,
        ]
    }

    private func decodedCapabilities(
        features: [String: Any],
        mediaMessage: Any?
    ) throws -> CapabilitiesDTO {
        var messaging: [String: Any] = [
            "ready": true,
            "version": SecureMessagingWire.protocolVersion,
            "suite": SecureMessagingWire.protocolSuite,
            "post_quantum": true,
        ]
        if let mediaMessage { messaging["media_message"] = mediaMessage }
        let data = try JSONSerialization.data(withJSONObject: [
            "api_version": "v1",
            "currency": ["code": "UGX", "scale": "2"],
            "features": features,
            "protocols": ["messaging": messaging],
        ])
        return try JSONDecoder().decode(CapabilitiesDTO.self, from: data)
    }

    private func deviceRow(
        deviceID: String,
        userID: String,
        platform: String = "android",
        version: String = "0.2.31",
        build: Int? = nil,
        capabilities: [String: Bool]
    ) -> [String: Any] {
        var client: [String: Any] = [
            "platform": platform,
            "version": version,
            "capabilities": capabilities,
        ]
        if let build { client["build"] = build }
        return ["device_id": deviceID, "user_id": userID, "client": client]
    }

    private func admits(
        capabilities: CapabilitiesDTO?,
        rows: [[String: Any]],
        memberUserIDs: Set<String>,
        items: [(mediaType: String, plaintextByteSize: Int)]
    ) throws -> Bool {
        let data = try JSONSerialization.data(withJSONObject: [
            "conversation_id": admissionConversationID,
            "devices": rows,
        ])
        let roster = try JSONDecoder().decode(MessagingDeviceRosterDTO.self, from: data)
        return MessagingMediaMessageV2CapabilityPolicy.admitsComposition(
            capabilities: capabilities,
            roster: roster,
            conversationID: admissionConversationID,
            currentDeviceID: meDeviceID,
            currentUserID: meUserID,
            memberUserIDs: memberUserIDs,
            items: items.map {
                .init(mediaType: $0.mediaType, plaintextByteSize: $0.plaintextByteSize)
            }
        )
    }

    // MARK: §6 capabilities decode

    func testCapabilitiesDecodeIsolatesTheMediaMessageBlock() throws {
        let enabled = try decodedCapabilities(
            features: ["messaging_media_message_v2": true],
            mediaMessage: canonicalMediaMessageBlock
        )
        XCTAssertTrue(enabled.enablesMessagingMediaMessageV2)
        XCTAssertEqual(enabled.protocols?.messaging?.supportsReviewedV2, true)

        // §6: a malformed or unexpected block never fails the capabilities document — it only
        // renders this one feature unavailable, and the parent messaging block stays intact.
        let malformedBlocks: [Any] = ["not-an-object", ["max_attachments": "eight"]]
        for malformed in malformedBlocks {
            let capabilities = try decodedCapabilities(
                features: ["messaging_media_message_v2": true],
                mediaMessage: malformed
            )
            XCTAssertNil(capabilities.protocols?.messaging?.mediaMessage)
            XCTAssertFalse(capabilities.enablesMessagingMediaMessageV2)
            XCTAssertEqual(capabilities.protocols?.messaging?.supportsReviewedV2, true)
        }

        // Both server legs must agree. A coherent block cannot enable the feature while the
        // features key is absent, null, or false…
        let withdrawnVariants: [[String: Any]] = [
            [:],
            ["messaging_media_message_v2": false],
            ["messaging_media_message_v2": NSNull()],
        ]
        for features in withdrawnVariants {
            let capabilities = try decodedCapabilities(
                features: features,
                mediaMessage: canonicalMediaMessageBlock
            )
            XCTAssertEqual(capabilities.protocols?.messaging?.mediaMessage?.supportsIOSV2, true)
            XCTAssertFalse(capabilities.enablesMessagingMediaMessageV2)
        }
        // …and the features key cannot enable it without a coherent block.
        XCTAssertFalse(try decodedCapabilities(
            features: ["messaging_media_message_v2": true],
            mediaMessage: nil
        ).enablesMessagingMediaMessageV2)
        var overAdvertised = canonicalMediaMessageBlock
        overAdvertised["max_attachments"] = 9
        XCTAssertFalse(try decodedCapabilities(
            features: ["messaging_media_message_v2": true],
            mediaMessage: overAdvertised
        ).enablesMessagingMediaMessageV2)
    }

    // MARK: §6 sender admission

    func testMediaMessageAdmissionRequiresEveryLegAtOnce() throws {
        let capabilities = try decodedCapabilities(
            features: ["messaging_media_message_v2": true],
            mediaMessage: canonicalMediaMessageBlock
        )
        let members: Set<String> = [meUserID, peerUserID]
        let allCapable = [
            deviceRow(deviceID: meDeviceID, userID: meUserID, capabilities: everyCapability),
            deviceRow(deviceID: peerDeviceOneID, userID: peerUserID, capabilities: everyCapability),
            deviceRow(deviceID: peerDeviceTwoID, userID: peerUserID, capabilities: everyCapability),
        ]
        let twoImages: [(mediaType: String, plaintextByteSize: Int)] = [
            ("image/jpeg", 1_048_576),
            ("image/png", 2_097_152),
        ]
        XCTAssertTrue(try admits(
            capabilities: capabilities, rows: allCapable, memberUserIDs: members, items: twoImages
        ))

        // Server leg: no capabilities snapshot, or a withdrawn features key, refuses.
        XCTAssertFalse(try admits(
            capabilities: nil, rows: allCapable, memberUserIDs: members, items: twoImages
        ))
        let featureOff = try decodedCapabilities(
            features: ["messaging_media_message_v2": false],
            mediaMessage: canonicalMediaMessageBlock
        )
        XCTAssertFalse(try admits(
            capabilities: featureOff, rows: allCapable, memberUserIDs: members, items: twoImages
        ))

        // Roster leg: one stale peer device blocks the whole send; the running device is the
        // only device that may attest by being this binary.
        var withoutV2 = everyCapability
        withoutV2[MessagingMediaMessageV2CapabilityPolicy.deviceCapabilityKey] = false
        let stalePeer = [
            allCapable[0],
            allCapable[1],
            deviceRow(deviceID: peerDeviceTwoID, userID: peerUserID, capabilities: withoutV2),
        ]
        XCTAssertFalse(try admits(
            capabilities: capabilities, rows: stalePeer, memberUserIDs: members, items: twoImages
        ))
        let selfAttesting = [
            deviceRow(deviceID: meDeviceID, userID: meUserID, capabilities: [:]),
            allCapable[1],
            allCapable[2],
        ]
        XCTAssertTrue(try admits(
            capabilities: capabilities, rows: selfAttesting, memberUserIDs: members, items: twoImages
        ))

        // §4 envelope leg: count bounds, media type, plaintext bounds, aggregate ceiling.
        XCTAssertFalse(try admits(
            capabilities: capabilities, rows: allCapable, memberUserIDs: members,
            items: [("image/jpeg", 1_048_576)]
        ))
        let nine: [(mediaType: String, plaintextByteSize: Int)] =
            Array(repeating: ("image/jpeg", 1_024), count: 9)
        XCTAssertFalse(try admits(
            capabilities: capabilities, rows: allCapable, memberUserIDs: members, items: nine
        ))
        XCTAssertFalse(try admits(
            capabilities: capabilities, rows: allCapable, memberUserIDs: members,
            items: [("application/x-shellscript", 16), ("image/jpeg", 16)]
        ))
        XCTAssertFalse(try admits(
            capabilities: capabilities, rows: allCapable, memberUserIDs: members,
            items: [("image/jpeg", 0), ("image/jpeg", 16)]
        ))
        // Two exact halves meet the 256 MiB aggregate ceiling; one more padding block refuses.
        let halfAggregatePlaintext = 128 * 1_024 * 1_024 - 64
        XCTAssertTrue(try admits(
            capabilities: capabilities, rows: allCapable, memberUserIDs: members,
            items: [("video/mp4", halfAggregatePlaintext), ("video/mp4", halfAggregatePlaintext)]
        ))
        XCTAssertFalse(try admits(
            capabilities: capabilities, rows: allCapable, memberUserIDs: members,
            items: [
                ("video/mp4", halfAggregatePlaintext),
                ("video/mp4", halfAggregatePlaintext + 16),
            ]
        ))

        // Per-item v1 keys ride along per §6: non-image items also need the rich-media key on
        // every peer device, and >10 MiB items the extended-size key on every device.
        var withoutRichMedia = everyCapability
        withoutRichMedia[MessagingRichMediaCapabilityPolicy.deviceCapabilityKey] = false
        let textImagePeers = [
            allCapable[0],
            deviceRow(deviceID: peerDeviceOneID, userID: peerUserID, capabilities: withoutRichMedia),
            deviceRow(deviceID: peerDeviceTwoID, userID: peerUserID, capabilities: withoutRichMedia),
        ]
        XCTAssertFalse(try admits(
            capabilities: capabilities, rows: textImagePeers, memberUserIDs: members,
            items: [("audio/mp4", 1_024), ("image/jpeg", 1_024)]
        ))
        XCTAssertTrue(try admits(
            capabilities: capabilities, rows: textImagePeers, memberUserIDs: members,
            items: twoImages
        ))
        var withoutExtendedSize = everyCapability
        withoutExtendedSize[
            MessagingRichMediaCapabilityPolicy.extendedSizeDeviceCapabilityKey
        ] = false
        let broadlyCompatible = [
            deviceRow(deviceID: meDeviceID, userID: meUserID, capabilities: withoutExtendedSize),
            deviceRow(
                deviceID: peerDeviceOneID, userID: peerUserID, capabilities: withoutExtendedSize
            ),
        ]
        XCTAssertFalse(try admits(
            capabilities: capabilities, rows: broadlyCompatible, memberUserIDs: members,
            items: [("image/jpeg", 11 * 1_024 * 1_024), ("image/jpeg", 1_024)]
        ))
        XCTAssertTrue(try admits(
            capabilities: capabilities, rows: broadlyCompatible, memberUserIDs: members,
            items: [("image/jpeg", 10 * 1_024 * 1_024), ("image/jpeg", 1_024)]
        ))

        // The v1 iOS version floors ride along too: an old iOS peer build refuses non-image
        // items even with every capability key set.
        let oldIOSPeer = [
            allCapable[0],
            deviceRow(
                deviceID: peerDeviceOneID, userID: peerUserID, platform: "ios",
                version: "0.2.4", build: 999, capabilities: everyCapability
            ),
        ]
        XCTAssertFalse(try admits(
            capabilities: capabilities, rows: oldIOSPeer, memberUserIDs: members,
            items: [("audio/mp4", 1_024), ("image/jpeg", 1_024)]
        ))
        XCTAssertTrue(try admits(
            capabilities: capabilities, rows: oldIOSPeer, memberUserIDs: members, items: twoImages
        ))
    }

    func testAdmissionRequiresARecipientPeer() throws {
        let capabilities = try decodedCapabilities(
            features: ["messaging_media_message_v2": true],
            mediaMessage: canonicalMediaMessageBlock
        )
        let twoImages: [(mediaType: String, plaintextByteSize: Int)] = [
            ("image/jpeg", 1_024),
            ("image/png", 1_024),
        ]
        // A fully capable self-only roster still refuses: with no recipient peer, the per-item
        // recipient checks would pass vacuously, so the gate fails closed instead.
        let selfOnly = [
            deviceRow(deviceID: meDeviceID, userID: meUserID, capabilities: everyCapability),
        ]
        XCTAssertFalse(try admits(
            capabilities: capabilities, rows: selfOnly, memberUserIDs: [meUserID], items: twoImages
        ))
        // And a member set that does not contain the sender refuses outright.
        XCTAssertFalse(try admits(
            capabilities: capabilities, rows: selfOnly, memberUserIDs: [peerUserID],
            items: twoImages
        ))
    }
}
