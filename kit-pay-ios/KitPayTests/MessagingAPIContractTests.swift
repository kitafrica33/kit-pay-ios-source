import Foundation
import XCTest
@testable import KitPay

final class MessagingAPIContractTests: XCTestCase {
    private let conversationId = "11111111-1111-4111-8111-111111111111"
    private let recipientDeviceId = "22222222-2222-4222-8222-222222222222"
    private let messageId = "33333333-3333-4333-8333-333333333333"
    private let rosterRevision = "v1:sha256:" + String(repeating: "a", count: 64)

    func testBackgroundEventsCompletionGateRejectsReplacedAndDuplicateCallbacks() {
        var gate = MessagingBackgroundEventsCompletionGate()
        let replaced = gate.install()
        let current = gate.install()

        XCTAssertFalse(gate.consume(replaced))
        XCTAssertTrue(gate.consume(current))
        XCTAssertFalse(gate.consume(current))
    }

    func testBackgroundUploadTaskDescriptionRoundTripsWithoutCredentials() throws {
        let accountID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let sessionID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let accessToken = "secret-access-token"
        let uploadID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        let digest = String(repeating: "d", count: 64)
        let context = try XCTUnwrap(MessagingBackgroundUploadContext(
            accountID: accountID,
            sessionID: sessionID,
            accessToken: accessToken,
            uploadID: uploadID,
            byteOffset: 5 * 1_024 * 1_024,
            byteSize: 512,
            ciphertextSHA256: digest
        ))
        let description = try XCTUnwrap(context.taskDescription)

        XCTAssertEqual(
            MessagingBackgroundUploadContext.decode(taskDescription: description),
            context
        )
        XCTAssertFalse(description.contains(accountID))
        XCTAssertFalse(description.contains(sessionID))
        XCTAssertFalse(description.contains(accessToken))
        XCTAssertTrue(context.isStructurallyValid)
    }

    func testBackgroundUploadSerializesOneOffsetAcrossTokenRotation() throws {
        func context(token: String, offset: Int64 = 0) throws -> MessagingBackgroundUploadContext {
            try XCTUnwrap(MessagingBackgroundUploadContext(
                accountID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                sessionID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
                accessToken: token,
                uploadID: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
                byteOffset: offset,
                byteSize: 512,
                ciphertextSHA256: String(repeating: "d", count: 64)
            ))
        }
        let rejectedToken = try context(token: "old-token")
        let refreshedToken = try context(token: "new-token")
        let nextChunk = try context(token: "new-token", offset: 512)

        XCTAssertTrue(rejectedToken.describesSameTransfer(as: refreshedToken))
        XCTAssertEqual(rejectedToken.logicalTransferID, refreshedToken.logicalTransferID)
        XCTAssertNotEqual(rejectedToken.attemptID, refreshedToken.attemptID)
        XCTAssertFalse(refreshedToken.describesSameTransfer(as: nextChunk))
    }

    func testBackgroundUploadResultRequiresBoundedResponseOrTransportError() throws {
        let context = try XCTUnwrap(MessagingBackgroundUploadContext(
            accountID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            sessionID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            accessToken: "token",
            uploadID: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
            byteOffset: 0,
            byteSize: 512,
            ciphertextSHA256: String(repeating: "d", count: 64)
        ))
        XCTAssertTrue(MessagingBackgroundUploadResult(
            context: context,
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data("{}".utf8),
            errorDomain: nil,
            errorCode: nil,
            completedAt: Date()
        ).isStructurallyValid)
        XCTAssertFalse(MessagingBackgroundUploadResult(
            context: context,
            statusCode: nil,
            headers: [:],
            body: Data(),
            errorDomain: nil,
            errorCode: nil,
            completedAt: Date()
        ).isStructurallyValid)
        XCTAssertFalse(MessagingBackgroundUploadResult(
            context: context,
            statusCode: 200,
            headers: [:],
            body: Data(count: MessagingBackgroundUploadResult.maximumResponseBytes + 1),
            errorDomain: nil,
            errorCode: nil,
            completedAt: Date()
        ).isStructurallyValid)
    }

    func testAttachmentUploadDTOConditionallyDecodesClientMediaIdentity() throws {
        let mediaID = "44444444-4444-4444-8444-444444444444"
        let modern = try JSONDecoder().decode(
            MessagingAttachmentUploadDTO.self,
            from: Data(
                #"{"storage_key":"55555555-5555-4555-8555-555555555555","byte_size":96,"ciphertext_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","client_media_id":"\#(mediaID)"}"#.utf8
            )
        )
        XCTAssertEqual(modern.clientMediaId, mediaID)

        let legacy = try JSONDecoder().decode(
            MessagingAttachmentUploadDTO.self,
            from: Data(
                #"{"storage_key":"55555555-5555-4555-8555-555555555555","byte_size":96,"ciphertext_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#.utf8
            )
        )
        XCTAssertNil(legacy.clientMediaId)
    }

    func testUploadResponseRequiresExactClientMediaIdentityEcho() {
        let mediaID = "44444444-4444-4444-8444-444444444444"
        let storageKey = "55555555-5555-4555-8555-555555555555"
        let digest = String(repeating: "a", count: 64)
        let bytes: Int64 = 96
        let valid = MessagingAttachmentUploadDTO(
            storageKey: storageKey,
            byteSize: bytes,
            ciphertextSha256: digest,
            clientMediaId: mediaID
        )
        XCTAssertEqual(
            SecureMessagingAttachmentUploadResponsePolicy.validate(
                valid,
                attachmentID: mediaID,
                ciphertextByteSize: bytes,
                ciphertextSHA256: digest
            ),
            ValidatedMessagingAttachmentUpload(
                storageKey: storageKey,
                byteSize: bytes,
                ciphertextSHA256: digest
            )
        )

        for rejected in [
            MessagingAttachmentUploadDTO(
                storageKey: storageKey,
                byteSize: bytes,
                ciphertextSha256: digest,
                clientMediaId: nil
            ),
            MessagingAttachmentUploadDTO(
                storageKey: storageKey,
                byteSize: bytes,
                ciphertextSha256: digest,
                clientMediaId: "66666666-6666-4666-8666-666666666666"
            ),
        ] {
            XCTAssertNil(SecureMessagingAttachmentUploadResponsePolicy.validate(
                rejected,
                attachmentID: mediaID,
                ciphertextByteSize: bytes,
                ciphertextSHA256: digest
            ))
        }
    }

    func testResumableChunkRequiresExplicitReplayField() throws {
        let digest = String(repeating: "b", count: 64)
        let upload = try JSONDecoder().decode(
            MessagingAttachmentUploadSessionDTO.self,
            from: Data(
                #"{"client_media_id":"44444444-4444-4444-8444-444444444444","storage_key":"55555555-5555-4555-8555-555555555555","media_type":"image/jpeg","byte_size":96,"ciphertext_sha256":"\#(digest)","state":"pending","next_offset":32,"max_chunk_bytes":5242880,"complete":false}"#.utf8
            )
        )
        func response(_ replayJSON: String) throws -> MessagingAttachmentUploadChunkResultDTO {
            try JSONDecoder().decode(
                MessagingAttachmentUploadChunkResultDTO.self,
                from: Data(
                    #"{"upload":{"client_media_id":"44444444-4444-4444-8444-444444444444","storage_key":"55555555-5555-4555-8555-555555555555","media_type":"image/jpeg","byte_size":96,"ciphertext_sha256":"\#(digest)","state":"pending","next_offset":32,"max_chunk_bytes":5242880,"complete":false},"chunk":{"byte_offset":0,"byte_size":32,"ciphertext_sha256":"\#(digest)"\#(replayJSON)}}"#.utf8
                )
            )
        }

        let missing = try response("")
        XCTAssertNil(MessagingResumableAttachmentPolicy.validatedChunkUpload(
            missing,
            expectedOffset: 0,
            expectedByteSize: 32,
            expectedSHA256: digest
        ))
        for value in [false, true] {
            let explicit = try response(",\"replayed\":\(value)")
            XCTAssertEqual(
                MessagingResumableAttachmentPolicy.validatedChunkUpload(
                    explicit,
                    expectedOffset: 0,
                    expectedByteSize: 32,
                    expectedSHA256: digest
                ),
                upload
            )
        }

        let wrongOffset = try JSONDecoder().decode(
            MessagingAttachmentUploadChunkResultDTO.self,
            from: Data(
                #"{"upload":{"client_media_id":"44444444-4444-4444-8444-444444444444","storage_key":"55555555-5555-4555-8555-555555555555","media_type":"image/jpeg","byte_size":96,"ciphertext_sha256":"\#(digest)","state":"pending","next_offset":32,"max_chunk_bytes":5242880,"complete":false},"chunk":{"byte_offset":1,"byte_size":32,"ciphertext_sha256":"\#(digest)","replayed":true}}"#.utf8
            )
        )
        XCTAssertNil(MessagingResumableAttachmentPolicy.validatedChunkUpload(
            wrongOffset,
            expectedOffset: 0,
            expectedByteSize: 32,
            expectedSHA256: digest
        ))
    }

    func testResumableCheckpointPersistsAuthoritativeRestartOffset() throws {
        let mediaID = "44444444-4444-4444-8444-444444444444"
        let storageKey = "55555555-5555-4555-8555-555555555555"
        let digest = String(repeating: "b", count: 64)
        let response = try resumableSession(
            mediaID: mediaID,
            storageKey: storageKey,
            digest: digest,
            state: "pending",
            nextOffset: 5 * 1_024 * 1_024,
            complete: false
        )

        let checkpoint = try SecureMessagingExchangeCoordinator.validatedResumableCheckpoint(
            response,
            attachmentID: mediaID,
            mediaType: "video/mp4",
            byteSize: 12 * 1_024 * 1_024,
            digest: digest,
            advertisedChunkBytes: 5 * 1_024 * 1_024,
            expectedUploadID: mediaID,
            expectedStorageKey: storageKey
        )
        let restored = try JSONDecoder().decode(
            LocalMediaResumableUpload.self,
            from: JSONEncoder().encode(checkpoint)
        )

        XCTAssertEqual(restored.uploadID, mediaID)
        XCTAssertEqual(restored.storageKey, storageKey)
        XCTAssertEqual(restored.nextOffset, 5 * 1_024 * 1_024)
        XCTAssertEqual(
            MessagingResumableAttachmentPolicy.chunkLength(
                remaining: 12 * 1_024 * 1_024 - restored.nextOffset,
                serverMaximum: restored.maxChunkBytes
            ),
            5 * 1_024 * 1_024
        )
    }

    func testResumableCompletionRejectsEveryBoundMetadataMismatch() throws {
        let mediaID = "44444444-4444-4444-8444-444444444444"
        let storageKey = "55555555-5555-4555-8555-555555555555"
        let digest = String(repeating: "b", count: 64)
        let byteSize: Int64 = 96

        let valid = try resumableSession(
            mediaID: mediaID,
            storageKey: storageKey,
            digest: digest,
            state: "ready",
            nextOffset: byteSize,
            complete: true,
            byteSize: byteSize
        )
        XCTAssertNoThrow(try SecureMessagingExchangeCoordinator.validatedResumableCheckpoint(
            valid,
            attachmentID: mediaID,
            mediaType: "video/mp4",
            byteSize: byteSize,
            digest: digest,
            advertisedChunkBytes: 5 * 1_024 * 1_024,
            expectedUploadID: mediaID,
            expectedStorageKey: storageKey,
            requiresComplete: true
        ))

        let mismatches = [
            try resumableSession(
                mediaID: mediaID,
                storageKey: "66666666-6666-4666-8666-666666666666",
                digest: digest,
                state: "ready",
                nextOffset: byteSize,
                complete: true,
                byteSize: byteSize
            ),
            try resumableSession(
                mediaID: mediaID,
                storageKey: storageKey,
                digest: digest,
                state: "ready",
                nextOffset: byteSize - 1,
                complete: true,
                byteSize: byteSize
            ),
            try resumableSession(
                mediaID: mediaID,
                storageKey: storageKey,
                digest: String(repeating: "c", count: 64),
                state: "ready",
                nextOffset: byteSize,
                complete: true,
                byteSize: byteSize
            ),
        ]
        for mismatch in mismatches {
            XCTAssertThrowsError(try SecureMessagingExchangeCoordinator.validatedResumableCheckpoint(
                mismatch,
                attachmentID: mediaID,
                mediaType: "video/mp4",
                byteSize: byteSize,
                digest: digest,
                advertisedChunkBytes: 5 * 1_024 * 1_024,
                expectedUploadID: mediaID,
                expectedStorageKey: storageKey,
                requiresComplete: true
            ))
        }
    }

    func testResumableLeaseReplacementIsLimitedToMissingOrExpiredLeaseResponses() {
        XCTAssertTrue(SecureMessagingExchangeCoordinator.resumableLeaseMayRestart(after:
            APIErrorPayload(
                code: "ATTACHMENT_UPLOAD_NOT_FOUND",
                message: "gone",
                httpStatus: 404
            )
        ))
        XCTAssertTrue(SecureMessagingExchangeCoordinator.resumableLeaseMayRestart(after:
            APIErrorPayload(
                code: "ATTACHMENT_UPLOAD_EXPIRED",
                message: "expired",
                httpStatus: 410
            )
        ))
        XCTAssertFalse(SecureMessagingExchangeCoordinator.resumableLeaseMayRestart(after:
            APIErrorPayload(code: "NOT_FOUND", message: "wrong resource", httpStatus: 404)
        ))
        XCTAssertFalse(SecureMessagingExchangeCoordinator.resumableLeaseMayRestart(after:
            APIClientError.httpResponse(status: 401, retryAfter: nil)
        ))
    }

    func testReadyLeasePreflightRenewsInPlaceOrAcceptsOnlyFreshEmptyReplacement() throws {
        let mediaID = "44444444-4444-4444-8444-444444444444"
        let oldStorageKey = "55555555-5555-4555-8555-555555555555"
        let replacementStorageKey = "66666666-6666-4666-8666-666666666666"
        let digest = String(repeating: "b", count: 64)
        let byteSize: Int64 = 96

        let renewed = try SecureMessagingExchangeCoordinator
            .validatedResumableLeasePreflight(
                try resumableSession(
                    mediaID: mediaID,
                    storageKey: oldStorageKey,
                    digest: digest,
                    state: "ready",
                    nextOffset: byteSize,
                    complete: true,
                    byteSize: byteSize
                ),
                attachmentID: mediaID,
                mediaType: "video/mp4",
                byteSize: byteSize,
                digest: digest,
                advertisedChunkBytes: 5 * 1_024 * 1_024,
                previousStorageKey: oldStorageKey
            )
        XCTAssertEqual(renewed.storageKey, oldStorageKey)
        XCTAssertEqual(renewed.nextOffset, byteSize)

        let replacement = try SecureMessagingExchangeCoordinator
            .validatedResumableLeasePreflight(
                try resumableSession(
                    mediaID: mediaID,
                    storageKey: replacementStorageKey,
                    digest: digest,
                    state: "pending",
                    nextOffset: 0,
                    complete: false,
                    byteSize: byteSize
                ),
                attachmentID: mediaID,
                mediaType: "video/mp4",
                byteSize: byteSize,
                digest: digest,
                advertisedChunkBytes: 5 * 1_024 * 1_024,
                previousStorageKey: oldStorageKey
            )
        XCTAssertEqual(replacement.storageKey, replacementStorageKey)
        XCTAssertEqual(replacement.nextOffset, 0)

        for invalid in [
            try resumableSession(
                mediaID: mediaID,
                storageKey: replacementStorageKey,
                digest: digest,
                state: "ready",
                nextOffset: byteSize,
                complete: true,
                byteSize: byteSize
            ),
            try resumableSession(
                mediaID: mediaID,
                storageKey: replacementStorageKey,
                digest: digest,
                state: "pending",
                nextOffset: 1,
                complete: false,
                byteSize: byteSize
            ),
            try resumableSession(
                mediaID: mediaID,
                storageKey: oldStorageKey,
                digest: digest,
                state: "pending",
                nextOffset: 0,
                complete: false,
                byteSize: byteSize
            ),
        ] {
            XCTAssertThrowsError(try SecureMessagingExchangeCoordinator
                .validatedResumableLeasePreflight(
                    invalid,
                    attachmentID: mediaID,
                    mediaType: "video/mp4",
                    byteSize: byteSize,
                    digest: digest,
                    advertisedChunkBytes: 5 * 1_024 * 1_024,
                    previousStorageKey: oldStorageKey
                ))
        }
    }

    private func resumableSession(
        mediaID: String,
        storageKey: String,
        digest: String,
        state: String,
        nextOffset: Int64,
        complete: Bool,
        byteSize: Int64 = 12 * 1_024 * 1_024
    ) throws -> MessagingAttachmentUploadSessionDTO {
        try JSONDecoder().decode(
            MessagingAttachmentUploadSessionDTO.self,
            from: try JSONSerialization.data(withJSONObject: [
                "client_media_id": mediaID,
                "storage_key": storageKey,
                "media_type": "video/mp4",
                "byte_size": byteSize,
                "ciphertext_sha256": digest,
                "state": state,
                "next_offset": nextOffset,
                "max_chunk_bytes": 5 * 1_024 * 1_024,
                "complete": complete,
            ], options: [.sortedKeys])
        )
    }

    private struct MapperDeviceFixture {
        let userID: String
        let deviceID: String
        let signalDeviceID: UInt32
        let registrationID: UInt32
        let enrollmentEpoch: Int64
        let bundleVersion: Int
        let identityKey: Data
        let signedPreKeyID: UInt32
        let signedPreKey: Data
        let signedPreKeySignature: Data
    }

    func testGroupDescriptionPolicyCanonicalizesAndBoundsLikeTheServer() {
        // Edge whitespace goes; the interior newline — the one control character a paragraph
        // keeps — stays; bidirectional overrides are stripped wherever they appear.
        XCTAssertEqual(
            MessagingGroupDescriptionPolicy.normalized("\u{3000}What we ship\nand when\u{00A0}"),
            "What we ship\nand when"
        )
        XCTAssertEqual(
            MessagingGroupDescriptionPolicy.normalized("safe\u{202E}txt.exe"),
            "safetxt.exe"
        )
        XCTAssertEqual(
            MessagingGroupDescriptionPolicy.normalized("a\u{0007}b\u{0000}c"),
            "abc"
        )

        XCTAssertTrue(
            MessagingGroupDescriptionPolicy.isValid(String(repeating: "a", count: 512))
        )
        XCTAssertFalse(
            MessagingGroupDescriptionPolicy.isValid(String(repeating: "a", count: 513))
        )
        // 400 three-byte scalars pass the scalar cap and break the 1024-byte cap.
        XCTAssertFalse(
            MessagingGroupDescriptionPolicy.isValid(String(repeating: "€", count: 400))
        )
        XCTAssertFalse(MessagingGroupDescriptionPolicy.isValid("\u{00A0}\u{3000}"))
    }

    func testGroupDescriptionRequestAlwaysCarriesTheKeyAndClearsWithExplicitNull() throws {
        let encoder = JSONEncoder()
        let cleared = try encoder.encode(
            UpdateMessagingGroupDescriptionRequest(description: nil)
        )
        XCTAssertEqual(String(data: cleared, encoding: .utf8), #"{"description":null}"#)

        let set = try encoder.encode(
            UpdateMessagingGroupDescriptionRequest(description: "Ships weekly")
        )
        XCTAssertEqual(
            String(data: set, encoding: .utf8),
            #"{"description":"Ships weekly"}"#
        )

        // Non-canonical input never reaches the wire.
        XCTAssertThrowsError(
            try UpdateMessagingGroupDescriptionRequest(description: " padded ")
        )
        XCTAssertThrowsError(
            try UpdateMessagingGroupDescriptionRequest(
                description: String(repeating: "a", count: 513)
            )
        )
    }

    func testGroupPhotoRequestAndURLPolicyFailClosed() throws {
        XCTAssertNoThrow(
            try AttachMessagingGroupPhotoRequest(
                assetId: "3b47a1f0-90c7-4b7e-8f3c-2f4a5b6c7d8e"
            )
        )
        XCTAssertThrowsError(try AttachMessagingGroupPhotoRequest(assetId: "not-an-asset"))
        XCTAssertThrowsError(
            try AttachMessagingGroupPhotoRequest(
                assetId: "3B47A1F0-90C7-4B7E-8F3C-2F4A5B6C7D8E"
            )
        )

        XCTAssertTrue(
            MessagingGroupPhotoURLPolicy.isValid(
                "https://pay.kit.africa/conversations/\(conversationId)/photo/\(messageId)"
            )
        )
        XCTAssertFalse(MessagingGroupPhotoURLPolicy.isValid("http://pay.kit.africa/photo"))
        XCTAssertFalse(MessagingGroupPhotoURLPolicy.isValid("https://"))
        XCTAssertFalse(MessagingGroupPhotoURLPolicy.isValid("https://pay.kit.africa/a photo"))
        XCTAssertFalse(MessagingGroupPhotoURLPolicy.isValid("javascript:alert(1)"))
        XCTAssertFalse(
            MessagingGroupPhotoURLPolicy.isValid(
                "https://pay.kit.africa/" + String(repeating: "a", count: 2_048)
            )
        )
    }

    func testConversationDTODecodesGroupIdentityAndOldPayloadsWithoutIt() throws {
        let decoder = JSONDecoder()
        let modern = try decoder.decode(
            MessagingConversationDTO.self,
            from: Data(#"{"id":"c","type":"group","description":"d","photo_url":"u"}"#.utf8)
        )
        XCTAssertEqual(modern.description, "d")
        XCTAssertEqual(modern.photoUrl, "u")

        // An old server omits both keys entirely; the DTO must not invent them.
        let legacy = try decoder.decode(
            MessagingConversationDTO.self,
            from: Data(#"{"id":"c","type":"group","title":"t"}"#.utf8)
        )
        XCTAssertNil(legacy.description)
        XCTAssertNil(legacy.photoUrl)
    }

    func testConversationMemberDecodesPublicIdentityAndFailsClosedPerField() throws {
        let decoder = JSONDecoder()
        let member = try decoder.decode(
            MessagingConversationMemberDTO.self,
            from: Data(#"{"user_id":"11111111-1111-4111-8111-111111111111","name":"Amina","role":"member","avatar_url":"https://pay.kit.africa/amina.jpg","verification":{"designation":"official","since":"2026-08-29T08:00:00Z"}}"#.utf8)
        )
        XCTAssertEqual(member.avatarUrl, "https://pay.kit.africa/amina.jpg")
        XCTAssertEqual(member.verification?.designation, .official)

        let malformed = try decoder.decode(
            MessagingConversationMemberDTO.self,
            from: Data(#"{"user_id":"11111111-1111-4111-8111-111111111111","name":"Amina","role":"member","avatar_url":42,"verification":"verified"}"#.utf8)
        )
        XCTAssertEqual(malformed.name, "Amina")
        XCTAssertNil(malformed.avatarUrl)
        XCTAssertNil(malformed.verification)
    }

    func testConversationModelDecodesStateWrittenBeforeGroupIdentity() throws {
        // The PersistedState rule: every added field is Optional with a default, so encrypted
        // state written by earlier builds keeps decoding. This is that rule, held by a test.
        let legacy = #"{"id":"c1","title":"Team","participantUserIds":["a","b"],"# +
            #""unreadCount":0,"updatedAt":700000000}"#
        let decoded = try JSONDecoder().decode(Conversation.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.groupDescription)
        XCTAssertNil(decoded.groupPhotoURL)
        XCTAssertNil(decoded.memberIdentities)
    }

    func testConversationFiltersMatchAllAndUnreadSemantics() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let readDirect = Conversation(
            id: "read",
            title: "Read direct chat",
            participantUserIds: ["current", "peer"],
            unreadCount: 0,
            updatedAt: now
        )
        let unreadDirect = Conversation(
            id: "unread",
            title: "Unread direct chat",
            participantUserIds: ["current", "other"],
            unreadCount: 3,
            updatedAt: now
        )
        let conversations = [readDirect, unreadDirect]

        XCTAssertEqual(
            ConversationListFilterPolicy.apply(.all, to: conversations).map(\.id),
            ["read", "unread"]
        )
        XCTAssertEqual(
            ConversationListFilterPolicy.apply(.unread, to: conversations).map(\.id),
            ["unread"]
        )
    }

    func testCustomerFacingMessagingCopyKeepsTransportStatePrivate() {
        let messages = [
            CustomerFacingMessagingCopy.encryptionAssurance,
            CustomerFacingMessagingCopy.sendFailure,
            CustomerFacingMessagingCopy.draftSaveFailure,
            CustomerFacingMessagingCopy.paymentRequestShareFailure,
            CustomerFacingMessagingCopy.deliveryUnconfirmedBeforeSignOut,
            CustomerFacingMessagingCopy.legacyConversationFailure,
        ]
        let implementationTerms = [
            "secure messaging", "available", "signal", "wire v2", "provider",
        ]

        for message in messages {
            let normalized = message.lowercased()
            for term in implementationTerms {
                XCTAssertFalse(normalized.contains(term), "Customer copy exposed \(term): \(message)")
            }
        }
        XCTAssertEqual(
            OutboxPolicy.unavailableMessageFailure,
            CustomerFacingMessagingCopy.legacyConversationFailure
        )
        XCTAssertTrue(
            CustomerFacingMessagingCopy.encryptionAssurance
                .localizedCaseInsensitiveContains("end-to-end encrypted")
        )
        XCTAssertTrue(
            CustomerFacingMessagingCopy.sendFailure
                .localizedCaseInsensitiveContains("could not confirm")
        )
        XCTAssertFalse(
            CustomerFacingMessagingCopy.sendFailure
                .localizedCaseInsensitiveContains("nothing was sent")
        )
        XCTAssertTrue(
            CustomerFacingMessagingCopy.paymentRequestShareFailure
                .localizedCaseInsensitiveContains("could not confirm")
        )
        XCTAssertFalse(
            CustomerFacingMessagingCopy.paymentRequestShareFailure
                .localizedCaseInsensitiveContains("nothing was")
        )
        XCTAssertTrue(
            CustomerFacingMessagingCopy.draftSaveFailure
                .localizedCaseInsensitiveContains("keep this chat open")
        )
        XCTAssertTrue(
            CustomerFacingMessagingCopy.deliveryUnconfirmedBeforeSignOut
                .localizedCaseInsensitiveContains("could not be confirmed")
        )
        XCTAssertFalse(
            CustomerFacingMessagingCopy.deliveryUnconfirmedBeforeSignOut
                .localizedCaseInsensitiveContains("was not sent")
        )
    }

    func testChatPresentationNeverExposesPaymentWireDescriptors() throws {
        let request = try XCTUnwrap(KitPaymentMessage(
            action: .request,
            paymentRequestId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            amountMinor: 50_000,
            currencyCode: "UGX",
            currencyScale: 0,
            note: "Lunch"
        ))
        let paid = try XCTUnwrap(request.changingAction(to: .paid))

        let requestMessage = localMessage(body: request.encoded)
        XCTAssertEqual(
            ChatMessagePresentationPolicy.previewText(for: requestMessage),
            "💰 Payment request"
        )
        let requestSearchText = try XCTUnwrap(
            ChatMessagePresentationPolicy.searchableText(for: requestMessage)
        )
        XCTAssertEqual(requestSearchText, "💰 Payment request · Lunch")
        XCTAssertFalse(requestSearchText.contains(KitPaymentMessage.prefix))
        XCTAssertFalse(requestSearchText.contains(request.paymentRequestId))

        let paidMessage = localMessage(body: paid.encoded)
        XCTAssertEqual(ChatMessagePresentationPolicy.previewText(for: paidMessage), "💸 Payment")
        XCTAssertEqual(
            ChatMessagePresentationPolicy.searchableText(for: paidMessage),
            "💸 Payment · Lunch"
        )
    }

    func testChatPresentationFailsClosedForUnsupportedPaymentDescriptor() {
        let unsupported = localMessage(
            body: "KITPAY1:v=2&a=request&private_wire_value=do-not-display"
        )

        XCTAssertEqual(ChatMessagePresentationPolicy.previewText(for: unsupported), "💸 Payment")
        XCTAssertEqual(ChatMessagePresentationPolicy.searchableText(for: unsupported), "💸 Payment")
        XCTAssertFalse(
            ChatMessagePresentationPolicy.previewText(for: unsupported).contains("KITPAY1")
        )

        let ordinary = localMessage(body: "Please review KITPAY1: after lunch")
        XCTAssertEqual(
            ChatMessagePresentationPolicy.previewText(for: ordinary),
            ordinary.body
        )
        XCTAssertEqual(
            ChatMessagePresentationPolicy.searchableText(for: ordinary),
            ordinary.body
        )

        let disguisedPayment = localMessage(
            body: " \n\tKITPAY1:v=2&private_wire_value=do-not-display"
        )
        XCTAssertEqual(
            ChatMessagePresentationPolicy.previewText(for: disguisedPayment),
            "💸 Payment"
        )
        XCTAssertEqual(
            ChatMessagePresentationPolicy.searchableText(for: disguisedPayment),
            "💸 Payment"
        )

        let disguisedMedia = localMessage(
            body: "\n KITMEDIA1:v=2&sk=private&key=do-not-display"
        )
        // A malformed or future-version media family body has no trustworthy kind; the shared
        // fail-closed presentation policy confines it to the generic placeholder.
        XCTAssertEqual(ChatMessagePresentationPolicy.previewText(for: disguisedMedia), "Attachment")
        XCTAssertNil(ChatMessagePresentationPolicy.searchableText(for: disguisedMedia))
    }

    func testNewMessageSubmissionGateRejectsDoubleTapAndReusesIDAfterFailure() {
        let firstID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let unusedID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        let key = NewMessageSubmissionKey(
            recipientUserID: recipientDeviceId,
            body: " Hello "
        )!
        var gate = NewMessageSubmissionGate()

        XCTAssertEqual(gate.begin(key: key) { firstID }, firstID)
        XCTAssertTrue(gate.isSubmitting)
        XCTAssertNil(gate.begin(key: key) { unusedID })

        gate.finish(clientMessageID: firstID, succeeded: false)
        XCTAssertFalse(gate.isSubmitting)
        XCTAssertEqual(gate.begin(key: key) { unusedID }, firstID)

        gate.finish(clientMessageID: firstID, succeeded: true)
        XCTAssertFalse(gate.isSubmitting)
        XCTAssertNil(gate.retainedClientMessageID)
        XCTAssertEqual(gate.begin(key: key) { unusedID }, unusedID)
    }

    func testSubmissionIdentityUsesCanonicalRecipientAndTrimmedBody() throws {
        let firstID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let editedDraftID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        let original = try XCTUnwrap(NewMessageSubmissionKey(
            recipientUserID: recipientDeviceId.uppercased(),
            body: " ExampleContact \n"
        ))
        let whitespaceOnlyEdit = try XCTUnwrap(NewMessageSubmissionKey(
            recipientUserID: recipientDeviceId,
            body: "ExampleContact"
        ))
        let contentEdit = try XCTUnwrap(NewMessageSubmissionKey(
            recipientUserID: recipientDeviceId,
            body: "ExampleContact, hello"
        ))
        var gate = NewMessageSubmissionGate()

        XCTAssertEqual(original, whitespaceOnlyEdit)
        XCTAssertEqual(gate.begin(key: original) { firstID }, firstID)
        gate.finish(clientMessageID: firstID, succeeded: false)
        XCTAssertEqual(gate.begin(key: whitespaceOnlyEdit) { editedDraftID }, firstID)
        gate.finish(clientMessageID: firstID, succeeded: false)

        XCTAssertEqual(gate.begin(key: contentEdit) { editedDraftID }, editedDraftID)
    }

    func testNewMessageComposerUsesLocalQueueWithoutCurrentEnrollmentAndHonorsPrivacy() {
        let localUserID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1"
        let recipientUserID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2"
        let conversation = Conversation(
            id: "cccccccc-cccc-4ccc-8ccc-ccccccccccc3",
            title: "Existing direct thread",
            participantUserIds: [localUserID, recipientUserID],
            unreadCount: 0,
            updatedAt: Date(timeIntervalSince1970: 1_756_800_000),
            conversationType: SecureMessagingWire.directConversationType
        )

        // No enrollment is an input: the UI consumes the protected-local-queue gate, whose
        // release policy is deliberately independent of network discovery and key activation.
        let localQueueAvailableWithoutEnrollment = SecureMessagingLocalQueueReleasePolicy.permits(
            buildEnabled: true
        )
        XCTAssertTrue(NewMessageComposerPolicy.canSubmit(
            appMutationsAllowed: true,
            localQueueAvailable: localQueueAvailableWithoutEnrollment,
            body: "Visible locally first"
        ))
        XCTAssertFalse(NewMessageComposerPolicy.canSubmit(
            appMutationsAllowed: true,
            localQueueAvailable: true,
            body: "  \n "
        ))
        XCTAssertEqual(
            NewMessageComposerPolicy.directRoute(
                conversations: [conversation],
                currentUserID: localUserID,
                recipientUserID: recipientUserID,
                privacyAllowsLocalQueue: true
            ),
            .existing(conversation)
        )
        XCTAssertEqual(
            NewMessageComposerPolicy.directRoute(
                conversations: [],
                currentUserID: localUserID,
                recipientUserID: recipientUserID,
                privacyAllowsLocalQueue: true
            ),
            .create
        )
        XCTAssertEqual(
            NewMessageComposerPolicy.directRoute(
                conversations: [conversation],
                currentUserID: localUserID,
                recipientUserID: recipientUserID,
                privacyAllowsLocalQueue: false
            ),
            .blocked
        )

        var unknownType = conversation
        unknownType.conversationType = "channel"
        XCTAssertEqual(
            NewMessageComposerPolicy.directRoute(
                conversations: [unknownType],
                currentUserID: localUserID,
                recipientUserID: recipientUserID,
                privacyAllowsLocalQueue: true
            ),
            .invalid
        )
    }

    func testNewMessageComposerNavigatesOnlyAfterDurableQueueResult() {
        let conversation = Conversation(
            id: conversationId,
            title: "Queued conversation",
            participantUserIds: [],
            unreadCount: 0,
            updatedAt: Date(timeIntervalSince1970: 1_756_800_000)
        )
        XCTAssertNil(NewMessageComposerPolicy.navigationConversation(after: nil))

        let result = SecureMessagingQueueResult(
            conversation: conversation,
            clientMessageID: UUID(uuidString: messageId)!
        )
        XCTAssertEqual(
            NewMessageComposerPolicy.navigationConversation(after: result),
            conversation
        )
    }

    func testKeyPublicationEncodesOnlyReviewedV2PublicMaterial() throws {
        let request = try keyPublication()

        let object = try jsonObject(request)
        XCTAssertEqual(object["protocol_version"] as? String, "v2")
        XCTAssertEqual(object["registration_id"] as? Int, 42)
        XCTAssertEqual(object["identity_key_change"] as? Bool, false)
        XCTAssertNotNil(object["signed_prekey"])
        XCTAssertNotNil(object["one_time_prekeys"])
        XCTAssertNotNil(object["pq_prekeys"])
        XCTAssertNotNil(object["pq_last_resort_prekey"])
        XCTAssertNil(object["private_key"])
        XCTAssertNil(object["identity_private_key"])
        XCTAssertEqual(
            Set(object.keys),
            [
                "protocol_version",
                "registration_id",
                "identity_key",
                "identity_key_change",
                "signed_prekey",
                "one_time_prekeys",
                "pq_prekeys",
                "pq_last_resort_prekey",
            ]
        )
    }

    func testKeyPublicationRejectsDuplicateOrNonCanonicalMaterial() throws {
        let pq = MessagingPQPrekeyRequest(
            prekeyId: 7,
            publicKey: base64(count: 1_569, byte: 7),
            signature: base64(count: 64, byte: 8)
        )
        XCTAssertThrowsError(
            try PublishMessagingKeyBundleRequest(
                registrationId: 42,
                identityKey: base64(count: 33, byte: 1),
                signedPrekey: MessagingSignedPrekeyRequest(
                    prekeyId: 1,
                    publicKey: base64(count: 33, byte: 2),
                    signature: base64(count: 64, byte: 3)
                ),
                oneTimePrekeys: [],
                pqPrekeys: [pq],
                pqLastResortPrekey: pq
            )
        )
        XCTAssertFalse(SecureMessagingWirePolicy.canonicalBase64("not base64"))
    }

    func testEncryptedMessageRequestContainsCiphertextRoutingOnly() throws {
        let envelope = try EncryptedDeviceEnvelopeRequest(
            recipientDeviceId: recipientDeviceId,
            envelopeType: .prekey,
            ciphertext: Data("opaque".utf8).base64EncodedString()
        )
        let request = try SendEncryptedMessageRequest(
            clientMessageId: messageId,
            rosterRevision: rosterRevision,
            kind: .encrypted,
            envelopes: [envelope]
        )

        let object = try jsonObject(request)
        XCTAssertEqual(object["client_message_id"] as? String, messageId)
        XCTAssertEqual(object["roster_revision"] as? String, rosterRevision)
        XCTAssertEqual(object["kind"] as? String, "encrypted")
        XCTAssertEqual((object["attachments"] as? [Any])?.count, 0)
        XCTAssertNil(object["plaintext"])
        XCTAssertNil(object["text"])
        XCTAssertNil(object["body"])
        XCTAssertNil(object["message"])

        let envelopes = try XCTUnwrap(object["envelopes"] as? [[String: Any]])
        XCTAssertEqual(envelopes.count, 1)
        XCTAssertEqual(envelopes[0]["recipient_device_id"] as? String, recipientDeviceId)
        XCTAssertEqual(envelopes[0]["envelope_type"] as? String, "signal-prekey-v2")
        XCTAssertEqual(Set(envelopes[0].keys), ["recipient_device_id", "envelope_type", "ciphertext"])
    }

    func testEncryptedReactionRequestRequiresTargetAndForbidsAttachments() throws {
        let envelope = try EncryptedDeviceEnvelopeRequest(
            recipientDeviceId: recipientDeviceId,
            envelopeType: .message,
            ciphertext: Data([1, 2, 3]).base64EncodedString()
        )
        let request = try SendEncryptedMessageRequest(
            clientMessageId: messageId,
            rosterRevision: rosterRevision,
            kind: .encryptedReaction,
            replyToMessageId: conversationId,
            envelopes: [envelope]
        )
        XCTAssertEqual(try jsonObject(request)["kind"] as? String, "encrypted_reaction")
        XCTAssertThrowsError(try SendEncryptedMessageRequest(
            clientMessageId: messageId,
            rosterRevision: rosterRevision,
            kind: .encryptedReaction,
            envelopes: [envelope]
        ))
        let attachment = try EncryptedAttachmentRequest(
            id: "44444444-4444-4444-8444-444444444444",
            storageKey: "55555555-5555-4555-8555-555555555555",
            mediaType: "image/jpeg",
            byteSize: 1_024,
            ciphertextSha256: String(repeating: "b", count: 64)
        )
        XCTAssertThrowsError(try SendEncryptedMessageRequest(
            clientMessageId: messageId,
            rosterRevision: rosterRevision,
            kind: .encryptedReaction,
            replyToMessageId: conversationId,
            envelopes: [envelope],
            attachments: [attachment]
        ))
    }

    func testEncryptedMessageRequestFailsClosedOnInvalidFanout() throws {
        let envelope = try EncryptedDeviceEnvelopeRequest(
            recipientDeviceId: recipientDeviceId,
            envelopeType: .message,
            ciphertext: Data([1, 2, 3]).base64EncodedString()
        )
        XCTAssertThrowsError(
            try SendEncryptedMessageRequest(
                clientMessageId: messageId,
                rosterRevision: rosterRevision,
                kind: .encrypted,
                envelopes: [envelope, envelope]
            )
        )
        XCTAssertThrowsError(
            try SendEncryptedMessageRequest(
                clientMessageId: messageId,
                rosterRevision: "not-a-roster",
                kind: .encrypted,
                envelopes: [envelope]
            )
        )
        XCTAssertNil(SecureMessagingEnvelopeType(rawValue: "signal-prekey-v1"))
    }

    func testAttachmentCipherMatchesAuthenticatedFrameAndRejectsTampering() throws {
        let plaintext = Data("photo bytes shared by Android and iOS".utf8)
        var nextByte: UInt8 = 1
        let encrypted = try SecureMediaAttachmentCipher.encrypt(plaintext) { count in
            let bytes = (0..<count).map { _ -> UInt8 in
                defer { nextByte &+= 1 }
                return nextByte
            }
            return Data(bytes)
        }

        XCTAssertEqual(encrypted.keyMaterial.count, 64)
        XCTAssertGreaterThanOrEqual(encrypted.ciphertext.count, 64)
        XCTAssertEqual(encrypted.sha256Hex.count, 64)
        XCTAssertEqual(
            try SecureMediaAttachmentCipher.decrypt(
                encrypted.ciphertext,
                keyMaterial: encrypted.keyMaterial,
                expectedSHA256Hex: encrypted.sha256Hex
            ),
            plaintext
        )

        var tampered = encrypted.ciphertext
        tampered[tampered.startIndex + 20] ^= 0x01
        XCTAssertThrowsError(
            try SecureMediaAttachmentCipher.decrypt(
                tampered,
                keyMaterial: encrypted.keyMaterial,
                expectedSHA256Hex: encrypted.sha256Hex
            )
        )
    }

    func testStreamingAttachmentCipherRoundTripsAcrossDifferentChunkBoundaries() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kit-streaming-cipher-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let plaintextURL = directory.appendingPathComponent("plain.bin")
        let ciphertextURL = directory.appendingPathComponent("cipher.bin")
        let decryptedURL = directory.appendingPathComponent("decrypted.bin")
        let plaintext = Data((0 ..< 70_013).map { UInt8($0 % 251) })
        let keyMaterial = Data(
            (0 ..< SecureMediaAttachmentCipher.keyMaterialBytes).map(UInt8.init)
        )
        try plaintext.write(to: plaintextURL, options: .atomic)

        let encrypted = try SecureMediaAttachmentCipher.encryptFile(
            plaintextURL: plaintextURL,
            ciphertextURL: ciphertextURL,
            expectedPlaintextByteSize: plaintext.count,
            keyMaterial: keyMaterial,
            attachmentID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            chunkBytes: 4_093
        )
        try SecureMediaAttachmentCipher.decryptFile(
            ciphertextURL: ciphertextURL,
            plaintextURL: decryptedURL,
            expectedCiphertextByteSize: encrypted.ciphertextByteSize,
            expectedCiphertextSHA256: encrypted.ciphertextSHA256,
            expectedPlaintextByteSize: plaintext.count,
            keyMaterial: keyMaterial,
            chunkBytes: 997
        )

        XCTAssertEqual(try Data(contentsOf: decryptedURL), plaintext)
    }

    func testStreamingAttachmentCipherDeletesOutputAfterTamperingOrTruncation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kit-streaming-cipher-invalid-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let plaintextURL = directory.appendingPathComponent("plain.bin")
        let ciphertextURL = directory.appendingPathComponent("cipher.bin")
        let tamperedURL = directory.appendingPathComponent("tampered.bin")
        let truncatedURL = directory.appendingPathComponent("truncated.bin")
        let tamperedOutputURL = directory.appendingPathComponent("tampered-output.bin")
        let truncatedOutputURL = directory.appendingPathComponent("truncated-output.bin")
        let plaintext = Data((0 ..< 32_777).map { UInt8($0 % 239) })
        let keyMaterial = Data(repeating: 0x5c, count: SecureMediaAttachmentCipher.keyMaterialBytes)
        try plaintext.write(to: plaintextURL, options: .atomic)
        let encrypted = try SecureMediaAttachmentCipher.encryptFile(
            plaintextURL: plaintextURL,
            ciphertextURL: ciphertextURL,
            expectedPlaintextByteSize: plaintext.count,
            keyMaterial: keyMaterial,
            attachmentID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            chunkBytes: 2_047
        )

        var tampered = try Data(contentsOf: ciphertextURL)
        tampered[tampered.startIndex + 20] ^= 0x01
        try tampered.write(to: tamperedURL, options: .atomic)
        XCTAssertThrowsError(try SecureMediaAttachmentCipher.decryptFile(
            ciphertextURL: tamperedURL,
            plaintextURL: tamperedOutputURL,
            expectedCiphertextByteSize: encrypted.ciphertextByteSize,
            expectedCiphertextSHA256: encrypted.ciphertextSHA256,
            expectedPlaintextByteSize: plaintext.count,
            keyMaterial: keyMaterial,
            chunkBytes: 1_021
        )) { error in
            XCTAssertEqual(error as? SecureMediaAttachmentError, .invalidCiphertext)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tamperedOutputURL.path))

        let truncated = Data((try Data(contentsOf: ciphertextURL)).dropLast())
        try truncated.write(to: truncatedURL, options: .atomic)
        XCTAssertThrowsError(try SecureMediaAttachmentCipher.decryptFile(
            ciphertextURL: truncatedURL,
            plaintextURL: truncatedOutputURL,
            expectedCiphertextByteSize: Int64(truncated.count),
            expectedCiphertextSHA256: encrypted.ciphertextSHA256,
            expectedPlaintextByteSize: plaintext.count,
            keyMaterial: keyMaterial,
            chunkBytes: 1_021
        )) { error in
            XCTAssertEqual(error as? SecureMediaAttachmentError, .invalidCiphertext)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: truncatedOutputURL.path))
    }

    func testMediaDescriptorIsCanonicalAndKeepsKeysOutOfServerMetadata() throws {
        let key = Data((0..<64).map { UInt8($0) })
        let descriptor = try KitMediaMessageDescriptor(
            attachmentID: "44444444-4444-4444-8444-444444444444",
            storageKey: "55555555-5555-4555-8555-555555555555",
            mediaType: "image/jpeg",
            ciphertextByteSize: 1_024,
            ciphertextSHA256: String(repeating: "a", count: 64),
            keyMaterial: key,
            plaintextByteSize: 900,
            caption: "  ExampleContact & Kit Pay *~é  "
        )
        let encoded = descriptor.encoded
        XCTAssertEqual(KitMediaMessageDescriptor.parse(encoded), descriptor)
        XCTAssertEqual(descriptor.caption, "ExampleContact & Kit Pay *~é")
        XCTAssertTrue(encoded.hasPrefix("KITMEDIA1:v=1&id="))
        XCTAssertTrue(encoded.contains(
            "cap=ExampleContact%20%26%20Kit%20Pay%20*%7E%C3%A9"
        ))
        XCTAssertNil(KitMediaMessageDescriptor.parse(encoded.replacingOccurrences(
            of: "v=1&id=",
            with: "id=44444444-4444-4444-8444-444444444444&v=1&ignored="
        )))

        let attachment = try XCTUnwrap(descriptor.attachmentRequest)
        let object = try jsonObject(attachment)
        XCTAssertEqual(object["storage_key"] as? String, descriptor.storageKey)
        XCTAssertEqual(object["media_type"] as? String, "image/jpeg")
        XCTAssertNil(object["key"])
        XCTAssertNil(object["key_material"])
        XCTAssertNil(object["caption"])
    }

    func testMapperPublishesAttachmentKindAndExactMetadata() throws {
        let attachment = try EncryptedAttachmentRequest(
            id: "44444444-4444-4444-8444-444444444444",
            storageKey: "55555555-5555-4555-8555-555555555555",
            mediaType: "image/jpeg",
            byteSize: 1_024,
            ciphertextSha256: String(repeating: "b", count: 64)
        )
        let fanout = SecureMessagingCommittedFanout(
            clientMessageID: messageId,
            conversationID: conversationId,
            rosterRevision: rosterRevision,
            replyToMessageID: nil,
            rosterDevices: [],
            envelopes: [SecureMessagingOutboundEnvelope(
                recipientDeviceID: recipientDeviceId,
                envelopeType: SecureMessagingEnvelopeType.message.rawValue,
                ciphertext: Data("opaque signal envelope".utf8)
            )]
        )
        let request = try SecureMessagingMapper.sendRequest(
            from: fanout,
            plaintext: try KitMediaMessageDescriptor(
                attachmentID: attachment.id,
                storageKey: attachment.storageKey,
                mediaType: attachment.mediaType,
                ciphertextByteSize: attachment.byteSize,
                ciphertextSHA256: attachment.ciphertextSha256,
                keyMaterial: Data(repeating: 7, count: SecureMediaAttachmentCipher.keyMaterialBytes),
                plaintextByteSize: 100,
                caption: nil
            ).encoded,
            attachments: [attachment]
        )
        let object = try jsonObject(request)
        XCTAssertEqual(object["kind"] as? String, "encrypted_attachment")
        let attachments = try XCTUnwrap(object["attachments"] as? [[String: Any]])
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments[0]["storage_key"] as? String, attachment.storageKey)
        XCTAssertEqual(Set(attachments[0].keys), [
            "id", "storage_key", "media_type", "byte_size", "ciphertext_sha256",
        ])
    }

    func testMapperBindsReactionPlaintextToOuterKindAndExactTarget() throws {
        let target = "70000000-0000-4000-8000-000000000001"
        let reaction = try XCTUnwrap(KitMessageReaction(
            operation: .add,
            targetServerMessageID: target,
            emoji: "👍"
        ))
        let fanout = SecureMessagingCommittedFanout(
            clientMessageID: messageId,
            conversationID: conversationId,
            rosterRevision: rosterRevision,
            replyToMessageID: target,
            rosterDevices: [],
            envelopes: [SecureMessagingOutboundEnvelope(
                recipientDeviceID: recipientDeviceId,
                envelopeType: SecureMessagingEnvelopeType.message.rawValue,
                ciphertext: Data([1, 2, 3])
            )]
        )
        let request = try SecureMessagingMapper.sendRequest(
            from: fanout,
            plaintext: reaction.encoded
        )
        XCTAssertEqual(request.kind, .encryptedReaction)
        XCTAssertEqual(request.replyToMessageId, target)

        let wrongTargetFanout = SecureMessagingCommittedFanout(
            clientMessageID: fanout.clientMessageID,
            conversationID: fanout.conversationID,
            rosterRevision: fanout.rosterRevision,
            replyToMessageID: conversationId,
            rosterDevices: fanout.rosterDevices,
            envelopes: fanout.envelopes
        )
        XCTAssertThrowsError(try SecureMessagingMapper.sendRequest(
            from: wrongTargetFanout,
            plaintext: reaction.encoded
        ))
        XCTAssertThrowsError(try SecureMessagingMapper.sendRequest(
            from: fanout,
            plaintext: "KITRXN1:not-valid"
        ))
        XCTAssertThrowsError(try SecureMessagingMapper.sendRequest(
            from: fanout,
            plaintext: "  \n\(reaction.encoded)"
        ))
    }

    func testDirectConversationAndReceiptIDsMustBeCanonical() throws {
        let direct = try CreateDirectMessagingConversationRequest(memberId: recipientDeviceId)
        let object = try jsonObject(direct)
        XCTAssertEqual(Set(object.keys), ["member_ids", "type"])
        XCTAssertEqual(object["member_ids"] as? [String], [recipientDeviceId])
        XCTAssertEqual(object["type"] as? String, "direct")

        XCTAssertThrowsError(
            try CreateDirectMessagingConversationRequest(
                memberId: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
            )
        )
        XCTAssertThrowsError(
            try AcknowledgeMessageDeliveryRequest(messageIds: [messageId, messageId])
        )
    }

    func testDirectConversationClientIdentityIsAnAdditiveCanonicalUUIDv4Field() throws {
        // Include a hexadecimal letter so the uppercase rejection below is a genuinely
        // different, non-canonical wire value rather than the same all-numeric UUID.
        let clientConversationID = "4a444444-4444-4444-8444-444444444444"
        let request = try CreateDirectMessagingConversationRequest(
            memberId: recipientDeviceId,
            clientConversationId: clientConversationID
        )
        let object = try jsonObject(request)

        XCTAssertEqual(Set(object.keys), ["client_conversation_id", "member_ids", "type"])
        XCTAssertEqual(object["client_conversation_id"] as? String, clientConversationID)
        XCTAssertEqual(object["member_ids"] as? [String], [recipientDeviceId])
        XCTAssertEqual(object["type"] as? String, "direct")

        for rejected in [
            clientConversationID.uppercased(),
            "44444444-4444-1444-8444-444444444444",
            "44444444-4444-4444-7444-444444444444",
            "not-a-uuid",
        ] {
            XCTAssertThrowsError(try CreateDirectMessagingConversationRequest(
                memberId: recipientDeviceId,
                clientConversationId: rejected
            ))
        }

        let group = try CreateDirectMessagingConversationRequest(
            groupMemberIds: [
                recipientDeviceId,
                "55555555-5555-4555-8555-555555555555",
            ],
            title: "Trip"
        )
        XCTAssertNil(try jsonObject(group)["client_conversation_id"])
    }

    func testOfflineDirectCreationRequiresTheExactReviewedCapability() throws {
        func capabilities(
            feature: Any = true,
            block: Any? = [
                "profile": "kit-direct-conversation-v1",
                "ready": true,
                "request_field": "client_conversation_id",
                "canonical_id_on_create": true,
                "existing_pair_wins": true,
            ]
        ) throws -> CapabilitiesDTO {
            var messaging: [String: Any] = [
                "ready": true,
                "version": SecureMessagingWire.protocolVersion,
                "suite": SecureMessagingWire.protocolSuite,
                "post_quantum": true,
            ]
            if let block { messaging["offline_direct_creation"] = block }
            return try decode(CapabilitiesDTO.self, object: [
                "api_version": "v1",
                "currency": ["code": "UGX", "scale": "2"],
                "features": ["messaging": feature],
                "protocols": ["messaging": messaging],
            ])
        }

        XCTAssertTrue(try capabilities().enablesMessagingOfflineDirectCreation)
        XCTAssertFalse(try capabilities(feature: false).enablesMessagingOfflineDirectCreation)
        XCTAssertFalse(try capabilities(block: nil).enablesMessagingOfflineDirectCreation)
        XCTAssertFalse(try capabilities(block: [
            "profile": "kit-direct-conversation-v2",
            "ready": true,
            "request_field": "client_conversation_id",
            "canonical_id_on_create": true,
            "existing_pair_wins": true,
        ]).enablesMessagingOfflineDirectCreation)
        XCTAssertFalse(try capabilities(block: [
            "profile": "kit-direct-conversation-v1",
            "ready": false,
            "request_field": "client_conversation_id",
            "canonical_id_on_create": true,
            "existing_pair_wins": true,
        ]).enablesMessagingOfflineDirectCreation)

        let malformed = try capabilities(block: "not-an-object")
        XCTAssertFalse(malformed.enablesMessagingOfflineDirectCreation)
        XCTAssertEqual(malformed.protocols?.messaging?.supportsReviewedV2, true)
    }

    func testOfflineDirectReceiptBridgesColdOfflineRelaunchForItsExactOwner() throws {
        let ownerUserID = "10000000-0000-4000-8000-000000000011"
        let sessionID = "20000000-0000-4000-8000-000000000011"
        let scope = MessagingDeferredFeatureScope(
            accountEpoch: UUID(uuidString: "30000000-0000-4000-8000-000000000011")!,
            userID: ownerUserID,
            sessionID: sessionID
        )
        let receipt = try XCTUnwrap(MessagingOfflineDirectCreationCapabilityReceipt(
            ownerUserID: ownerUserID.uppercased(),
            sessionID: sessionID.uppercased(),
            authoritativeCapabilities: offlineDirectCreationCapabilities(enabled: true),
            accountMutationsAllowed: true
        ))
        // Encoding/decoding represents process death and protected-state restoration. There is
        // deliberately no live capabilities document on the restored/offline side.
        let restored = try JSONDecoder().decode(
            MessagingOfflineDirectCreationCapabilityReceipt.self,
            from: JSONEncoder().encode(receipt)
        )

        XCTAssertTrue(MessagingOfflineDirectCreationCapabilityPolicy.allowsLocalQueue(
            authoritativeCapabilities: nil,
            receipt: restored,
            in: scope
        ))
        XCTAssertFalse(MessagingOfflineDirectCreationCapabilityPolicy.allowsLocalQueue(
            authoritativeCapabilities: nil,
            receipt: nil,
            in: scope
        ), "a fresh install/account has no authority to create a provisional thread")

        let replacementAccount = MessagingDeferredFeatureScope(
            accountEpoch: scope.accountEpoch,
            userID: "10000000-0000-4000-8000-000000000012",
            sessionID: sessionID
        )
        let replacementSession = MessagingDeferredFeatureScope(
            accountEpoch: scope.accountEpoch,
            userID: ownerUserID,
            sessionID: "20000000-0000-4000-8000-000000000012"
        )
        for foreignScope in [replacementAccount, replacementSession] {
            XCTAssertFalse(MessagingOfflineDirectCreationCapabilityPolicy.allowsLocalQueue(
                authoritativeCapabilities: nil,
                receipt: restored,
                in: foreignScope
            ))
        }
    }

    func testOfflineDirectAuthoritativeRevocationOverridesAndClearsPriorGrant() throws {
        let ownerUserID = "10000000-0000-4000-8000-000000000021"
        let sessionID = "20000000-0000-4000-8000-000000000021"
        let scope = MessagingDeferredFeatureScope(
            accountEpoch: UUID(uuidString: "30000000-0000-4000-8000-000000000021")!,
            userID: ownerUserID,
            sessionID: sessionID
        )
        let enabled = try offlineDirectCreationCapabilities(enabled: true)
        let disabled = try offlineDirectCreationCapabilities(enabled: false)
        let previousGrant = try XCTUnwrap(MessagingOfflineDirectCreationCapabilityReceipt(
            ownerUserID: ownerUserID,
            sessionID: sessionID,
            authoritativeCapabilities: enabled,
            accountMutationsAllowed: true
        ))

        XCTAssertFalse(MessagingOfflineDirectCreationCapabilityPolicy.allowsLocalQueue(
            authoritativeCapabilities: disabled,
            receipt: previousGrant,
            in: scope
        ), "the current authenticated response must beat a stale affirmative receipt")

        let durableRevocation = MessagingOfflineDirectCreationCapabilityReceipt(
            ownerUserID: ownerUserID,
            sessionID: sessionID,
            authoritativeCapabilities: disabled,
            accountMutationsAllowed: true
        )
        XCTAssertNil(durableRevocation)
        XCTAssertFalse(MessagingOfflineDirectCreationCapabilityPolicy.allowsLocalQueue(
            authoritativeCapabilities: nil,
            receipt: durableRevocation,
            in: scope
        ), "a later transient failure must not resurrect an authoritatively revoked grant")

        let readOnlyAccountReceipt = MessagingOfflineDirectCreationCapabilityReceipt(
            ownerUserID: ownerUserID,
            sessionID: sessionID,
            authoritativeCapabilities: enabled,
            accountMutationsAllowed: false
        )
        XCTAssertNil(readOnlyAccountReceipt)
        XCTAssertFalse(MessagingOfflineDirectCreationCapabilityPolicy.allowsLocalQueue(
            authoritativeCapabilities: nil,
            receipt: readOnlyAccountReceipt,
            in: scope
        ), "a read-only App Review account must not gain offline write authority")
    }

    func testConversationDecodesStateWrittenBeforeProvisionalDirectFields() throws {
        let original = Conversation(
            id: conversationId,
            title: "Existing conversation",
            participantUserIds: [
                "44444444-4444-4444-8444-444444444444",
                "55555555-5555-4555-8555-555555555555",
            ],
            unreadCount: 1,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        var object = try jsonObject(original)
        object.removeValue(forKey: "pendingDirectRecipientUserID")
        object.removeValue(forKey: "localConversationAliases")
        let decoded = try decode(Conversation.self, object: object)

        XCTAssertNil(decoded.pendingDirectRecipientUserID)
        XCTAssertNil(decoded.localConversationAliases)
        XCTAssertFalse(decoded.isProvisionalDirect)
    }

    func testPendingDeliveryPresentationIsExplicitAndOutgoingOnly() {
        XCTAssertEqual(
            MessageDeliveryPresentationPolicy.statusLabel(for: .queued, isOutgoing: true),
            "Pending"
        )
        XCTAssertEqual(
            MessageDeliveryPresentationPolicy.statusLabel(for: .encrypting, isOutgoing: true),
            "Pending"
        )
        XCTAssertEqual(
            MessageDeliveryPresentationPolicy.statusLabel(for: .sending, isOutgoing: true),
            "Sending"
        )
        XCTAssertEqual(
            MessageDeliveryPresentationPolicy.statusLabel(for: .failed, isOutgoing: true),
            "Not sent"
        )
        XCTAssertNil(
            MessageDeliveryPresentationPolicy.statusLabel(for: .sent, isOutgoing: true)
        )
        XCTAssertNil(
            MessageDeliveryPresentationPolicy.statusLabel(for: .queued, isOutgoing: false)
        )
    }

    func testEndpointContractMatchesProductionV2Routes() throws {
        XCTAssertEqual(MessagingAPIEndpoint.keyStatus.path, "messaging/keys/status")
        XCTAssertEqual(MessagingAPIEndpoint.keyStatus.method, "GET")
        XCTAssertEqual(MessagingAPIEndpoint.publishKeys.method, "PUT")
        XCTAssertEqual(MessagingAPIEndpoint.deliveryAcknowledgements.method, "POST")
        XCTAssertEqual(MessagingAPIEndpoint.attachments.path, "messaging/attachments")

        let update = try MessagingAPIEndpoint.updateConversation(conversationId)
        XCTAssertEqual(update.path, "messaging/conversations/\(conversationId)")
        XCTAssertEqual(update.method, "PATCH")
        let members = try MessagingAPIEndpoint.conversationMembers(conversationId)
        XCTAssertEqual(members.path, "messaging/conversations/\(conversationId)/members")
        XCTAssertEqual(members.method, "POST")
        let removal = try MessagingAPIEndpoint.conversationMember(
            conversationId: conversationId,
            userId: recipientDeviceId
        )
        XCTAssertEqual(
            removal.path,
            "messaging/conversations/\(conversationId)/members/\(recipientDeviceId)"
        )
        XCTAssertEqual(removal.method, "DELETE")

        let roster = try MessagingAPIEndpoint.roster(conversationId)
        XCTAssertEqual(
            roster.path,
            "messaging/conversations/\(conversationId)/device-roster"
        )
        let historical = try MessagingAPIEndpoint.historicalRoster(
            conversationId: conversationId,
            rosterRevision: rosterRevision
        )
        XCTAssertEqual(
            historical.path,
            "messaging/conversations/\(conversationId)/device-roster/\(rosterRevision)"
        )
        XCTAssertThrowsError(try MessagingAPIEndpoint.roster("../wallets"))
    }

    func testSyncAndHistoryQueriesUseTypedURLItemsAndServerLimits() throws {
        let sync = try MessagingAPIEndpoint.sync(cursor: "next/value+", limit: 100)
        XCTAssertEqual(sync.path, "messaging/sync")
        XCTAssertEqual(sync.queryItems.map(\.name), ["cursor", "limit"])
        XCTAssertEqual(sync.queryItems.map(\.value), ["next/value+", "100"])
        XCTAssertThrowsError(try MessagingAPIEndpoint.sync(cursor: nil, limit: 101))

        let history = try MessagingAPIEndpoint.historyCandidates(
            conversationId: conversationId,
            targetDeviceId: recipientDeviceId,
            targetEnrollmentEpoch: 9,
            cursor: "after",
            limit: 50
        )
        XCTAssertEqual(
            history.queryItems.map(\.name),
            ["target_device_id", "target_enrollment_epoch", "after", "limit"]
        )
        XCTAssertThrowsError(
            try MessagingAPIEndpoint.historyCandidates(
                conversationId: conversationId,
                targetDeviceId: recipientDeviceId,
                targetEnrollmentEpoch: 0,
                cursor: nil,
                limit: 50
            )
        )
    }

    func testHistoryEnvelopeRequestUsesExactAndroidWireMembers() throws {
        let request = try StoreMessagingHistoryEnvelopeRequest(
            targetDeviceId: recipientDeviceId,
            targetEnrollmentEpoch: 9,
            transferClientMessageId: messageId,
            rosterRevision: rosterRevision,
            envelopeType: .message,
            ciphertext: Data("history ciphertext".utf8).base64EncodedString()
        )
        let object = try jsonObject(request)
        XCTAssertEqual(Set(object.keys), [
            "target_device_id", "target_enrollment_epoch", "transfer_client_message_id",
            "roster_revision", "envelope_type", "ciphertext",
        ])
        XCTAssertEqual(object["target_device_id"] as? String, recipientDeviceId)
        XCTAssertEqual(object["target_enrollment_epoch"] as? Int, 9)
        XCTAssertEqual(object["transfer_client_message_id"] as? String, messageId)
        XCTAssertThrowsError(try StoreMessagingHistoryEnvelopeRequest(
            targetDeviceId: recipientDeviceId,
            targetEnrollmentEpoch: 0,
            transferClientMessageId: messageId,
            rosterRevision: rosterRevision,
            envelopeType: .message,
            ciphertext: Data([1]).base64EncodedString()
        ))
    }

    func testHistoryDescriptorMatchesAndroidTransferIdentityAndAuthenticatesOuterMetadata() throws {
        let originalMessageID = "70000000-0000-4000-8000-000000000001"
        let targetDeviceID = "20000000-0000-4000-8000-000000000002"
        let donorDeviceID = "20000000-0000-4000-8000-000000000001"
        let transferRosterRevision = "v1:sha256:\(String(repeating: "a", count: 64))"
        let transferID = try SecureMessagingHistoryBackfillCodec.deterministicTransferID(
            messageID: originalMessageID,
            targetDeviceID: targetDeviceID,
            targetEnrollmentEpoch: 9,
            donorDeviceID: donorDeviceID,
            donorEnrollmentEpoch: 4,
            transferRosterRevision: transferRosterRevision
        )
        XCTAssertEqual(transferID, "dfa913b8-98a6-546e-ac9c-a3ce7bc15f34")

        let sentAt = try XCTUnwrap(
            SecureMessagingHistoryBackfillCodec.parseDate("2026-08-20T12:34:56.789Z")
        )
        let original = SecureMessagingHistoryMessageIdentity(
            messageID: originalMessageID,
            clientMessageID: "80000000-0000-4000-8000-000000000001",
            conversationID: conversationId,
            senderUserID: "10000000-0000-4000-8000-000000000002",
            senderDeviceID: "20000000-0000-4000-8000-000000000003",
            senderEnrollmentEpoch: 3,
            senderSignalDeviceID: 7,
            rosterRevision: rosterRevision,
            kind: .encrypted,
            replyToMessageID: nil,
            sentAt: sentAt
        )
        let retained = LocalMessage(
            id: UUID(uuidString: originalMessageID)!,
            serverMessageId: originalMessageID,
            conversationId: conversationId,
            senderId: original.senderUserID,
            body: "authenticated history text",
            createdAt: sentAt,
            sentAt: sentAt,
            state: .received,
            failureReason: nil,
            isOutgoing: false,
            secureMessagingHistory: original.retainedMetadata
        )
        let descriptor = try SecureMessagingHistoryBackfillCodec.encode(
            transferClientMessageID: transferID,
            targetDeviceID: targetDeviceID,
            targetEnrollmentEpoch: 9,
            transferRosterRevision: transferRosterRevision,
            candidate: original,
            rawSentAt: "2026-08-20T12:34:56.789Z",
            retained: retained
        )
        let incoming = SecureMessagingHistoryInboundEnvelope(
            cryptoEnvelope: SecureMessagingInboundEnvelope(
                messageID: originalMessageID,
                clientMessageID: transferID,
                conversationID: conversationId,
                rosterRevision: transferRosterRevision,
                replyToMessageID: nil,
                sender: SecureMessagingRosterDevice(
                    address: SecureMessagingAddress(
                        userID: "10000000-0000-4000-8000-000000000001",
                        serverDeviceID: donorDeviceID,
                        signalDeviceID: 5
                    ),
                    registrationID: 42,
                    identityKeySHA256: String(repeating: "c", count: 64)
                ),
                localRecipient: SecureMessagingAddress(
                    userID: "10000000-0000-4000-8000-000000000001",
                    serverDeviceID: targetDeviceID,
                    signalDeviceID: 6
                ),
                envelopeType: SecureMessagingEnvelopeType.message.rawValue,
                ciphertext: Data([1])
            ),
            original: original,
            targetDeviceID: targetDeviceID,
            targetEnrollmentEpoch: 9,
            transferClientMessageID: transferID,
            transferRosterRevision: transferRosterRevision,
            rawAttachments: []
        )
        XCTAssertEqual(
            try SecureMessagingHistoryBackfillCodec.authenticate(
                descriptor,
                incoming: incoming
            ).text,
            retained.body
        )
        XCTAssertThrowsError(try SecureMessagingHistoryBackfillCodec.authenticate(
            descriptor.replacingOccurrences(
                of: "\"target_enrollment_epoch\":9",
                with: "\"target_enrollment_epoch\":10"
            ),
            incoming: incoming
        ))
        XCTAssertThrowsError(try SecureMessagingHistoryBackfillCodec.authenticate(
            descriptor.replacingOccurrences(
                of: "\"text\":",
                with: "\"text\":\"forged duplicate\",\"text\":"
            ),
            incoming: incoming
        ))
        XCTAssertThrowsError(try SecureMessagingHistoryBackfillCodec.authenticate(
            descriptor.replacingOccurrences(
                of: "\"text\":",
                with: "\"te\\u0078t\":\"escaped duplicate\",\"text\":"
            ),
            incoming: incoming
        ))

        let reactionTarget = "70000000-0000-4000-8000-000000000002"
        let reaction = try XCTUnwrap(KitMessageReaction(
            operation: .add,
            targetServerMessageID: reactionTarget,
            emoji: "👍"
        ))
        let reactionOriginal = SecureMessagingHistoryMessageIdentity(
            messageID: original.messageID,
            clientMessageID: original.clientMessageID,
            conversationID: original.conversationID,
            senderUserID: original.senderUserID,
            senderDeviceID: original.senderDeviceID,
            senderEnrollmentEpoch: original.senderEnrollmentEpoch,
            senderSignalDeviceID: original.senderSignalDeviceID,
            rosterRevision: original.rosterRevision,
            kind: .encryptedReaction,
            replyToMessageID: reactionTarget,
            sentAt: original.sentAt
        )
        let retainedReaction = LocalMessage(
            id: retained.id,
            serverMessageId: retained.serverMessageId,
            conversationId: retained.conversationId,
            senderId: retained.senderId,
            body: reaction.encoded,
            createdAt: retained.createdAt,
            sentAt: retained.sentAt,
            state: retained.state,
            failureReason: nil,
            isOutgoing: false,
            secureMessagingHistory: reactionOriginal.retainedMetadata
        )
        let reactionDescriptor = try SecureMessagingHistoryBackfillCodec.encode(
            transferClientMessageID: transferID,
            targetDeviceID: targetDeviceID,
            targetEnrollmentEpoch: 9,
            transferRosterRevision: transferRosterRevision,
            candidate: reactionOriginal,
            rawSentAt: "2026-08-20T12:34:56.789Z",
            retained: retainedReaction
        )
        let reactionIncoming = SecureMessagingHistoryInboundEnvelope(
            cryptoEnvelope: incoming.cryptoEnvelope,
            original: reactionOriginal,
            targetDeviceID: incoming.targetDeviceID,
            targetEnrollmentEpoch: incoming.targetEnrollmentEpoch,
            transferClientMessageID: incoming.transferClientMessageID,
            transferRosterRevision: incoming.transferRosterRevision,
            rawAttachments: []
        )
        XCTAssertEqual(
            try SecureMessagingHistoryBackfillCodec.authenticate(
                reactionDescriptor,
                incoming: reactionIncoming
            ).text,
            reaction.encoded
        )

        let wrongTargetOriginal = SecureMessagingHistoryMessageIdentity(
            messageID: reactionOriginal.messageID,
            clientMessageID: reactionOriginal.clientMessageID,
            conversationID: reactionOriginal.conversationID,
            senderUserID: reactionOriginal.senderUserID,
            senderDeviceID: reactionOriginal.senderDeviceID,
            senderEnrollmentEpoch: reactionOriginal.senderEnrollmentEpoch,
            senderSignalDeviceID: reactionOriginal.senderSignalDeviceID,
            rosterRevision: reactionOriginal.rosterRevision,
            kind: .encryptedReaction,
            replyToMessageID: "70000000-0000-4000-8000-000000000003",
            sentAt: reactionOriginal.sentAt
        )
        var wrongTargetRetained = retainedReaction
        wrongTargetRetained.secureMessagingHistory = wrongTargetOriginal.retainedMetadata
        XCTAssertThrowsError(try SecureMessagingHistoryBackfillCodec.encode(
            transferClientMessageID: transferID,
            targetDeviceID: targetDeviceID,
            targetEnrollmentEpoch: 9,
            transferRosterRevision: transferRosterRevision,
            candidate: wrongTargetOriginal,
            rawSentAt: "2026-08-20T12:34:56.789Z",
            retained: wrongTargetRetained
        ))
    }

    func testSyncResponseDecodesOpaqueEnvelopeAndReceiptTransitions() throws {
        let json = """
        {
          "events": [
            {
              "id": "44444444-4444-4444-8444-444444444444",
              "type": "message.created",
              "conversation_id": "\(conversationId)",
              "resource_type": "message",
              "resource_id": "\(messageId)",
              "occurred_at": "2026-08-18T12:00:00Z",
              "data": {
                "id": "\(messageId)",
                "conversation_id": "\(conversationId)",
                "roster_revision": "\(rosterRevision)",
                "kind": "encrypted",
                "sender_device_id": "55555555-5555-4555-8555-555555555555",
                "sender_enrollment_epoch": 2,
                "envelope": {
                  "recipient_device_id": "\(recipientDeviceId)",
                  "recipient_enrollment_epoch": 9,
                  "envelope_type": "signal-message-v2",
                  "ciphertext": "AQID",
                  "ciphertext_sha256": "\(String(repeating: "b", count: 64))"
                }
              }
            },
            null,
            {
              "id": "66666666-6666-4666-8666-666666666666",
              "type": "message.delivery.updated",
              "data": {
                "message_id": "\(messageId)",
                "delivery_state": "delivered_to_peer",
                "delivered_at": "2026-08-18T12:00:01Z"
              }
            }
          ],
          "page": {"next_cursor": "cursor-2", "has_more": true, "limit": 50}
        }
        """

        let decoded = try JSONDecoder().decode(MessagingSyncDTO.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.events?.count, 3)
        XCTAssertNil(decoded.events?[1])
        XCTAssertEqual(decoded.events?[0]?.data?.envelope?.ciphertext, "AQID")
        XCTAssertEqual(decoded.events?[2]?.data?.deliveryState, "delivered_to_peer")
        XCTAssertEqual(decoded.page?.nextCursor, "cursor-2")
        XCTAssertEqual(decoded.page?.hasMore, true)
    }

    func testRemoteBundlesRequireTheExactRequestedNonLocalDeviceSet() throws {
        let roster = mapperRoster(use: .current)
        let companion = mapperCompanionDevice
        let peer = mapperPeerDevice
        let expectedIDs: Set<String> = [companion.deviceID, peer.deviceID]
        let exact = try consumedBundlesDTO([
            consumedBundleObject(peer),
            consumedBundleObject(companion),
        ])

        let mapped = try SecureMessagingMapper.remoteBundles(
            from: exact,
            roster: roster,
            requestedRemoteDeviceIDs: expectedIDs,
            localDeviceID: mapperLocalDevice.deviceID
        )
        XCTAssertEqual(Set(mapped.map(\.device.address.serverDeviceID)), expectedIDs)

        let missing = try consumedBundlesDTO([consumedBundleObject(peer)])
        XCTAssertThrowsError(
            try SecureMessagingMapper.remoteBundles(
                from: missing,
                roster: roster,
                requestedRemoteDeviceIDs: expectedIDs,
                localDeviceID: mapperLocalDevice.deviceID
            )
        )

        let duplicate = try consumedBundlesDTO([
            consumedBundleObject(companion),
            consumedBundleObject(peer),
            consumedBundleObject(peer),
        ])
        XCTAssertThrowsError(
            try SecureMessagingMapper.remoteBundles(
                from: duplicate,
                roster: roster,
                requestedRemoteDeviceIDs: expectedIDs,
                localDeviceID: mapperLocalDevice.deviceID
            )
        )

        let forgedLocal = try consumedBundlesDTO([
            consumedBundleObject(companion),
            consumedBundleObject(peer),
            consumedBundleObject(mapperLocalDevice),
        ])
        XCTAssertThrowsError(
            try SecureMessagingMapper.remoteBundles(
                from: forgedLocal,
                roster: roster,
                requestedRemoteDeviceIDs: expectedIDs,
                localDeviceID: mapperLocalDevice.deviceID
            )
        )

        XCTAssertThrowsError(
            try SecureMessagingMapper.remoteBundles(
                from: forgedLocal,
                roster: roster,
                requestedRemoteDeviceIDs: expectedIDs.union([mapperLocalDevice.deviceID]),
                localDeviceID: mapperLocalDevice.deviceID
            )
        )
        XCTAssertThrowsError(
            try SecureMessagingMapper.remoteBundles(
                from: exact,
                roster: mapperRoster(use: .historical),
                requestedRemoteDeviceIDs: expectedIDs,
                localDeviceID: mapperLocalDevice.deviceID
            )
        )
    }

    func testRemoteBundlesMustMatchFrozenBundleAndSignedPrekeyCommitment() throws {
        let roster = mapperRoster(use: .current)
        let companion = mapperCompanionDevice
        let peer = mapperPeerDevice
        let expectedIDs: Set<String> = [companion.deviceID, peer.deviceID]

        var wrongVersion = consumedBundleObject(peer)
        wrongVersion["bundle_version"] = peer.bundleVersion + 1

        var missingVersion = consumedBundleObject(peer)
        missingVersion.removeValue(forKey: "bundle_version")

        var wrongCurrentFlag = consumedBundleObject(peer)
        wrongCurrentFlag["is_current_device"] = true

        var missingCurrentFlag = consumedBundleObject(peer)
        missingCurrentFlag.removeValue(forKey: "is_current_device")

        var wrongSignedID = consumedBundleObject(peer)
        var signed = try XCTUnwrap(wrongSignedID["signed_prekey"] as? [String: Any])
        signed["prekey_id"] = Int(peer.signedPreKeyID) + 1
        wrongSignedID["signed_prekey"] = signed

        var wrongSignedPublic = consumedBundleObject(peer)
        signed = try XCTUnwrap(wrongSignedPublic["signed_prekey"] as? [String: Any])
        signed["public_key"] = signalPublicKey(0xE1).base64EncodedString()
        wrongSignedPublic["signed_prekey"] = signed

        var wrongSignedSignature = consumedBundleObject(peer)
        signed = try XCTUnwrap(wrongSignedSignature["signed_prekey"] as? [String: Any])
        signed["signature"] = Data(repeating: 0xE2, count: 64).base64EncodedString()
        wrongSignedSignature["signed_prekey"] = signed

        for badPeer in [
            wrongVersion,
            missingVersion,
            wrongCurrentFlag,
            missingCurrentFlag,
            wrongSignedID,
            wrongSignedPublic,
            wrongSignedSignature,
        ] {
            let dto = try consumedBundlesDTO([consumedBundleObject(companion), badPeer])
            XCTAssertThrowsError(
                try SecureMessagingMapper.remoteBundles(
                    from: dto,
                    roster: roster,
                    requestedRemoteDeviceIDs: expectedIDs,
                    localDeviceID: mapperLocalDevice.deviceID
                )
            )
        }
    }

    func testInboundEnvelopeRequiresRecipientEpochAndCompleteCryptoSender() throws {
        let roster = mapperRoster(use: .current)
        let valid = inboundMessageObject(senderEnrollmentEpoch: mapperPeerDevice.enrollmentEpoch)

        let mapped = try mapInbound(valid, roster: roster)
        XCTAssertEqual(mapped.sender.address.serverDeviceID, mapperPeerDevice.deviceID)
        XCTAssertEqual(mapped.localRecipient.serverDeviceID, mapperLocalDevice.deviceID)

        let missingCryptoSender = replacing(
            valid,
            at: ["envelope", "crypto_sender"],
            with: nil
        )
        XCTAssertThrowsError(try mapInbound(missingCryptoSender, roster: roster))

        let missingRecipientEpoch = replacing(
            valid,
            at: ["envelope", "recipient_enrollment_epoch"],
            with: nil
        )
        XCTAssertThrowsError(try mapInbound(missingRecipientEpoch, roster: roster))

        let staleRecipientEpoch = replacing(
            valid,
            at: ["envelope", "recipient_enrollment_epoch"],
            with: mapperLocalDevice.enrollmentEpoch + 1
        )
        XCTAssertThrowsError(try mapInbound(staleRecipientEpoch, roster: roster))

        let cryptoEpochMismatch = replacing(
            valid,
            at: ["envelope", "crypto_sender", "enrollment_epoch"],
            with: mapperPeerDevice.enrollmentEpoch + 1
        )
        XCTAssertThrowsError(try mapInbound(cryptoEpochMismatch, roster: roster))

        let cryptoBundleMismatch = replacing(
            valid,
            at: ["envelope", "crypto_sender", "bundle_version"],
            with: mapperPeerDevice.bundleVersion + 1
        )
        XCTAssertThrowsError(try mapInbound(cryptoBundleMismatch, roster: roster))
    }

    func testInboundEnvelopeBindsCurrentSenderEpochAndBundleToRoster() throws {
        let roster = mapperRoster(use: .current)
        let valid = inboundMessageObject(senderEnrollmentEpoch: mapperPeerDevice.enrollmentEpoch)
        XCTAssertNoThrow(try mapInbound(valid, roster: roster))

        let encryptedAttachment = replacing(
            valid,
            at: ["kind"],
            with: SecureMessagingMessageKind.encryptedAttachment.rawValue
        )
        XCTAssertThrowsError(try mapInbound(encryptedAttachment, roster: roster))

        var encryptedReaction = replacing(
            valid,
            at: ["kind"],
            with: SecureMessagingMessageKind.encryptedReaction.rawValue
        )
        encryptedReaction["reply_to_message_id"] =
            "70000000-0000-4000-8000-000000000002"
        XCTAssertNoThrow(try mapInbound(encryptedReaction, roster: roster))
        encryptedReaction["reply_to_message_id"] = nil
        XCTAssertThrowsError(try mapInbound(encryptedReaction, roster: roster))

        var wrongEpoch = replacing(
            valid,
            at: ["sender_enrollment_epoch"],
            with: mapperPeerDevice.enrollmentEpoch + 1
        )
        wrongEpoch = replacing(
            wrongEpoch,
            at: ["envelope", "crypto_sender", "enrollment_epoch"],
            with: mapperPeerDevice.enrollmentEpoch + 1
        )
        XCTAssertThrowsError(try mapInbound(wrongEpoch, roster: roster))

        var wrongBundle = replacing(
            valid,
            at: ["sender_bundle_version"],
            with: mapperPeerDevice.bundleVersion + 1
        )
        wrongBundle = replacing(
            wrongBundle,
            at: ["envelope", "crypto_sender", "bundle_version"],
            with: mapperPeerDevice.bundleVersion + 1
        )
        XCTAssertThrowsError(try mapInbound(wrongBundle, roster: roster))

        let wrongRosterRevision = replacing(
            valid,
            at: ["roster_revision"],
            with: "v1:sha256:" + String(repeating: "b", count: 64)
        )
        XCTAssertThrowsError(try mapInbound(wrongRosterRevision, roster: roster))
    }

    func testInboundHistoricalRosterUsesServerSenderEpochButRetainsFrozenBundleBinding() throws {
        let historical = mapperRoster(use: .historical)
        let oldSenderEpoch: Int64 = 4
        let validHistorical = inboundMessageObject(senderEnrollmentEpoch: oldSenderEpoch)

        let mapped = try mapInbound(validHistorical, roster: historical)
        XCTAssertEqual(mapped.sender.address.serverDeviceID, mapperPeerDevice.deviceID)

        XCTAssertThrowsError(
            try mapInbound(validHistorical, roster: mapperRoster(use: .current))
        )

        let epochCopyMismatch = replacing(
            validHistorical,
            at: ["envelope", "crypto_sender", "enrollment_epoch"],
            with: oldSenderEpoch + 1
        )
        XCTAssertThrowsError(try mapInbound(epochCopyMismatch, roster: historical))

        var wrongBundle = replacing(
            validHistorical,
            at: ["sender_bundle_version"],
            with: mapperPeerDevice.bundleVersion + 1
        )
        wrongBundle = replacing(
            wrongBundle,
            at: ["envelope", "crypto_sender", "bundle_version"],
            with: mapperPeerDevice.bundleVersion + 1
        )
        XCTAssertThrowsError(try mapInbound(wrongBundle, roster: historical))
    }

    func testHistoryEnvelopeUsesSameAccountDonorAndExactTargetEnrollment() throws {
        let donor = mapperCompanionDevice
        var object = inboundMessageObject(senderEnrollmentEpoch: mapperPeerDevice.enrollmentEpoch)
        object["attachments"] = []
        object["reactions"] = []
        object["sent_at"] = "2026-08-20T12:34:56.789Z"
        object = replacing(object, at: ["envelope", "is_history_backfill"], with: true)
        object = replacing(
            object,
            at: ["envelope", "transfer_client_message_id"],
            with: "90000000-0000-4000-8000-000000000001"
        )
        object = replacing(
            object,
            at: ["envelope", "transfer_roster_revision"],
            with: rosterRevision
        )
        object = replacing(object, at: ["envelope", "crypto_sender"], with: [
            "user_id": donor.userID,
            "device_id": donor.deviceID,
            "enrollment_epoch": donor.enrollmentEpoch,
            "signal_device_id": Int(donor.signalDeviceID),
            "registration_id": Int(donor.registrationID),
            "protocol_version": "v2",
            "bundle_version": donor.bundleVersion,
            "identity_key_sha256": SecureMessagingValidation.sha256Hex(donor.identityKey),
        ])
        let dto = try decode(EncryptedMessageDTO.self, object: object)
        let localAddress = SecureMessagingAddress(
            userID: mapperLocalEnrollment.userID,
            serverDeviceID: mapperLocalEnrollment.serverDeviceID,
            signalDeviceID: mapperLocalEnrollment.signalDeviceID
        )
        let mapped = try SecureMessagingMapper.historyInboundEnvelope(
            from: dto,
            localRecipient: localAddress,
            localEnrollment: mapperLocalEnrollment,
            transferRoster: mapperRoster(use: .historical)
        )
        XCTAssertEqual(mapped.cryptoEnvelope.sender.address.serverDeviceID, donor.deviceID)
        XCTAssertEqual(mapped.targetEnrollmentEpoch, mapperLocalDevice.enrollmentEpoch)
        XCTAssertThrowsError(try mapInbound(object, roster: mapperRoster(use: .historical)))

        let wrongTarget = replacing(
            object,
            at: ["envelope", "recipient_enrollment_epoch"],
            with: mapperLocalDevice.enrollmentEpoch + 1
        )
        XCTAssertThrowsError(try SecureMessagingMapper.historyInboundEnvelope(
            from: decode(EncryptedMessageDTO.self, object: wrongTarget),
            localRecipient: localAddress,
            localEnrollment: mapperLocalEnrollment,
            transferRoster: mapperRoster(use: .historical)
        ))
        let peerDonor = replacing(
            object,
            at: ["envelope", "crypto_sender", "user_id"],
            with: mapperPeerDevice.userID
        )
        XCTAssertThrowsError(try SecureMessagingMapper.historyInboundEnvelope(
            from: decode(EncryptedMessageDTO.self, object: peerDonor),
            localRecipient: localAddress,
            localEnrollment: mapperLocalEnrollment,
            transferRoster: mapperRoster(use: .historical)
        ))
        var missingAttachments = object
        missingAttachments.removeValue(forKey: "attachments")
        XCTAssertThrowsError(try SecureMessagingMapper.historyInboundEnvelope(
            from: decode(EncryptedMessageDTO.self, object: missingAttachments),
            localRecipient: localAddress,
            localEnrollment: mapperLocalEnrollment,
            transferRoster: mapperRoster(use: .historical)
        ))
    }

    func testGroupConversationCreateRequestEncodesMembersTypeAndTitle() throws {
        let members = [
            "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
        ]
        let group = try CreateDirectMessagingConversationRequest(
            groupMemberIds: members,
            title: "  Weekend Trip  "
        )
        let object = try jsonObject(group)
        XCTAssertEqual(Set(object.keys), ["member_ids", "type", "title"])
        XCTAssertEqual(object["member_ids"] as? [String], members)
        XCTAssertEqual(object["type"] as? String, "group")
        XCTAssertEqual(object["title"] as? String, "Weekend Trip")

        // The direct wire body remains byte-compatible: no title key at all.
        let direct = try CreateDirectMessagingConversationRequest(memberId: members[0])
        XCTAssertEqual(Set(try jsonObject(direct).keys), ["member_ids", "type"])

        XCTAssertThrowsError(
            try CreateDirectMessagingConversationRequest(groupMemberIds: [], title: "Trip")
        )
        XCTAssertThrowsError(
            try CreateDirectMessagingConversationRequest(
                groupMemberIds: [members[0], members[0]],
                title: "Trip"
            )
        )
        XCTAssertThrowsError(
            try CreateDirectMessagingConversationRequest(
                groupMemberIds: members + ["not-a-uuid"],
                title: "Trip"
            )
        )
        XCTAssertThrowsError(
            try CreateDirectMessagingConversationRequest(groupMemberIds: members, title: "   ")
        )
        XCTAssertNoThrow(
            try CreateDirectMessagingConversationRequest(groupMemberIds: members, title: "Hi")
        )
        XCTAssertThrowsError(
            try CreateDirectMessagingConversationRequest(
                groupMemberIds: members,
                title: String(repeating: "t", count: 121)
            )
        )
        XCTAssertNoThrow(
            try CreateDirectMessagingConversationRequest(
                groupMemberIds: members,
                title: String(repeating: "🟢", count: 30)
            ),
            "Thirty four-byte emoji exactly fill the 120-byte wire budget"
        )
        XCTAssertThrowsError(
            try CreateDirectMessagingConversationRequest(
                groupMemberIds: members,
                title: String(repeating: "🟢", count: 31)
            ),
            "Character count alone must not bypass the UTF-8 wire limit"
        )
        let tooMany = (0 ..< SecureMessagingWire.maximumGroupMembers).map {
            String(format: "dddddddd-0000-4000-8000-%012d", $0)
        }
        XCTAssertThrowsError(
            try CreateDirectMessagingConversationRequest(groupMemberIds: tooMany, title: "Trip")
        )

        XCTAssertEqual(
            try jsonObject(RenameMessagingGroupRequest(title: "  A  "))["title"] as? String,
            "A"
        )
        let add = try AddMessagingGroupMemberRequest(userId: members[0])
        XCTAssertEqual(Set(try jsonObject(add).keys), ["user_id"])
        XCTAssertThrowsError(try AddMessagingGroupMemberRequest(userId: "not-a-uuid"))
        XCTAssertTrue(MessagingGroupRole.owner.canManageGroup)
        XCTAssertTrue(MessagingGroupRole.admin.canRemove(.member))
        XCTAssertFalse(MessagingGroupRole.admin.canRemove(.owner))
        XCTAssertFalse(MessagingGroupRole.member.canManageGroup)
    }

    func testExtendedMediaRequiresCapabilityOnEveryRosterDevice() throws {
        let conversationID = "0a1b2c3d-0000-4000-8000-000000000030"
        let currentDeviceID = "0a1b2c3d-0000-4000-8000-000000000031"
        let peerDeviceID = "0a1b2c3d-0000-4000-8000-000000000032"
        let localUserID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let peerUserID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let members: Set<String> = [localUserID, peerUserID]

        func device(
            id: String,
            userID: String,
            platform: String,
            capability: Bool?,
            version: String? = nil,
            build: Int? = nil
        ) -> [String: Any] {
            var value: [String: Any] = ["device_id": id, "user_id": userID]
            if let capability {
                var client: [String: Any] = [
                    "platform": platform,
                    "capabilities": [
                        MessagingRichMediaCapabilityPolicy.extendedSizeDeviceCapabilityKey:
                            capability,
                    ],
                ]
                if let version { client["version"] = version }
                if let build { client["build"] = build }
                value["client"] = client
            }
            return value
        }

        func supports(
            local: Bool?,
            peer: Bool?,
            localVersion: String = "1.0.16",
            localBuild: Int = 24,
            includeNull: Bool = false
        ) throws -> Bool {
            var devices: [Any] = [
                device(
                    id: currentDeviceID,
                    userID: localUserID,
                    platform: "ios",
                    capability: local,
                    version: localVersion,
                    build: localBuild
                ),
                device(id: peerDeviceID, userID: peerUserID, platform: "android", capability: peer),
            ]
            if includeNull { devices.append(NSNull()) }
            let roster = try decode(MessagingDeviceRosterDTO.self, object: [
                "conversation_id": conversationID,
                "devices": devices,
            ])
            return MessagingRichMediaCapabilityPolicy.supportsPlaintextByteSize(
                MessagingRichMediaCapabilityPolicy.broadlyCompatibleMaximumPlaintextBytes + 1,
                roster: roster,
                conversationID: conversationID,
                currentDeviceID: currentDeviceID,
                memberUserIDs: members
            )
        }

        XCTAssertTrue(try supports(local: true, peer: true))
        XCTAssertFalse(try supports(
            local: true,
            peer: true,
            localVersion: "1.0.15",
            localBuild: 23
        ))
        XCTAssertFalse(try supports(
            local: true,
            peer: true,
            localVersion: "1.0.16",
            localBuild: 23
        ))
        XCTAssertFalse(try supports(local: nil, peer: true))
        XCTAssertFalse(try supports(local: true, peer: false))
        XCTAssertFalse(try supports(local: true, peer: nil))
        XCTAssertFalse(try supports(local: true, peer: true, includeNull: true))

        let malformed = try decode(MessagingDeviceRosterDTO.self, object: [:])
        XCTAssertTrue(MessagingRichMediaCapabilityPolicy.supportsPlaintextByteSize(
            MessagingRichMediaCapabilityPolicy.broadlyCompatibleMaximumPlaintextBytes,
            roster: malformed,
            conversationID: conversationID,
            currentDeviceID: currentDeviceID,
            memberUserIDs: members
        ))
        XCTAssertFalse(MessagingRichMediaCapabilityPolicy.supportsPlaintextByteSize(
            SecureMediaAttachmentCipher.maximumPlaintextBytes + 1,
            roster: malformed,
            conversationID: conversationID,
            currentDeviceID: currentDeviceID,
            memberUserIDs: members
        ))
    }

    func testGroupCapabilityWithdrawalMakesOnlyGroupMutationsReadOnly() {
        XCTAssertTrue(MessagingGroupCapabilityPolicy.allowsConversationMutation(
            isGroup: false,
            groupCapabilityEnabled: false
        ))
        XCTAssertTrue(MessagingGroupCapabilityPolicy.allowsConversationMutation(
            isGroup: true,
            groupCapabilityEnabled: true
        ))
        XCTAssertFalse(MessagingGroupCapabilityPolicy.allowsConversationMutation(
            isGroup: true,
            groupCapabilityEnabled: false
        ))
    }

    func testDeferredFeaturePolicyAllowsUnknownButDeniesExplicitFalse() {
        XCTAssertTrue(MessagingDeferredFeaturePolicy.allowsDeferredLocalQueue(
            advertisedCapability: true
        ))
        XCTAssertFalse(MessagingDeferredFeaturePolicy.allowsDeferredLocalQueue(
            advertisedCapability: false
        ), "an explicit authenticated withdrawal must win")
        XCTAssertTrue(MessagingDeferredFeaturePolicy.allowsDeferredLocalQueue(
            advertisedCapability: nil
        ), "a discovery failure must not disable the protected local outbox")
    }

    func testDeferredFeatureSnapshotAllowsNilWithoutPriorDecision() {
        var snapshot = MessagingDeferredFeatureSnapshot()
        let scope = MessagingDeferredFeatureScope(
            accountEpoch: UUID(uuidString: "10000000-0000-4000-8000-000000000001")!,
            userID: "20000000-0000-4000-8000-000000000001",
            sessionID: "30000000-0000-4000-8000-000000000001"
        )
        snapshot.bind(to: scope)

        for feature in MessagingDeferredFeature.allCases {
            XCTAssertTrue(snapshot.allowsLocalQueue(
                feature,
                advertisedCapability: nil,
                in: scope
            ))
        }
    }

    func testDeferredFeatureSnapshotRetainsTrueAcrossNil() {
        var snapshot = MessagingDeferredFeatureSnapshot()
        let scope = MessagingDeferredFeatureScope(
            accountEpoch: UUID(uuidString: "10000000-0000-4000-8000-000000000002")!,
            userID: "20000000-0000-4000-8000-000000000002",
            sessionID: "30000000-0000-4000-8000-000000000002"
        )
        snapshot.confirm(groups: true, reactions: true, messageEdits: true, for: scope)

        for feature in MessagingDeferredFeature.allCases {
            XCTAssertTrue(snapshot.allowsLocalQueue(
                feature,
                advertisedCapability: nil,
                in: scope
            ))
        }
    }

    func testDeferredFeatureSnapshotRetainsFalseAcrossNil() {
        var snapshot = MessagingDeferredFeatureSnapshot()
        let scope = MessagingDeferredFeatureScope(
            accountEpoch: UUID(uuidString: "10000000-0000-4000-8000-000000000003")!,
            userID: "20000000-0000-4000-8000-000000000003",
            sessionID: "30000000-0000-4000-8000-000000000003"
        )
        snapshot.confirm(groups: false, reactions: false, messageEdits: false, for: scope)

        for feature in MessagingDeferredFeature.allCases {
            XCTAssertFalse(snapshot.allowsLocalQueue(
                feature,
                advertisedCapability: nil,
                in: scope
            ))
        }
    }

    func testDeferredFeatureSnapshotDoesNotCrossAccountOrSessionScope() {
        let original = MessagingDeferredFeatureScope(
            accountEpoch: UUID(uuidString: "10000000-0000-4000-8000-000000000004")!,
            userID: "20000000-0000-4000-8000-000000000004",
            sessionID: "30000000-0000-4000-8000-000000000004"
        )
        let replacementAccount = MessagingDeferredFeatureScope(
            accountEpoch: UUID(uuidString: "10000000-0000-4000-8000-000000000005")!,
            userID: "20000000-0000-4000-8000-000000000005",
            sessionID: "30000000-0000-4000-8000-000000000005"
        )
        let replacementSession = MessagingDeferredFeatureScope(
            accountEpoch: original.accountEpoch,
            userID: original.userID,
            sessionID: "30000000-0000-4000-8000-000000000006"
        )

        for replacementScope in [replacementAccount, replacementSession] {
            var snapshot = MessagingDeferredFeatureSnapshot()
            snapshot.confirm(groups: false, reactions: false, messageEdits: false, for: original)
            snapshot.bind(to: replacementScope)
            XCTAssertEqual(snapshot.scope, replacementScope)
            for feature in MessagingDeferredFeature.allCases {
                XCTAssertTrue(snapshot.allowsLocalQueue(
                    feature,
                    advertisedCapability: nil,
                    in: replacementScope
                ))
            }
        }
    }

    func testConversationDecodesWithoutConversationTypeAndFlagsGroups() throws {
        var conversation = Conversation(
            id: "11111111-1111-4111-8111-111111111111",
            title: "Weekend Trip",
            participantUserIds: ["a", "b", "c"],
            unreadCount: 0,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        // Old encrypted state never wrote the key; the optional must round-trip as absent.
        let legacyEncoded = try JSONEncoder().encode(conversation)
        let legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: legacyEncoded) as? [String: Any]
        )
        XCTAssertNil(legacyObject["conversationType"])
        let legacyDecoded = try JSONDecoder().decode(Conversation.self, from: legacyEncoded)
        XCTAssertNil(legacyDecoded.conversationType)
        XCTAssertFalse(legacyDecoded.isGroup)

        conversation.conversationType = SecureMessagingWire.groupConversationType
        let groupDecoded = try JSONDecoder().decode(
            Conversation.self,
            from: try JSONEncoder().encode(conversation)
        )
        XCTAssertTrue(groupDecoded.isGroup)

        conversation.conversationType = SecureMessagingWire.directConversationType
        let directDecoded = try JSONDecoder().decode(
            Conversation.self,
            from: try JSONEncoder().encode(conversation)
        )
        XCTAssertFalse(directDecoded.isGroup)
    }

    func testKitSystemMessageRoundTripAndStrictParseRejection() throws {
        let subject = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let actor = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let withActor = try XCTUnwrap(KitSystemMessage(
            kind: .memberAdded,
            subjectUserID: subject,
            actorUserID: actor
        ))
        XCTAssertEqual(
            withActor.encoded,
            "KITSYS1:v=1&k=member_added&u=\(subject)&a=\(actor)"
        )
        XCTAssertEqual(KitSystemMessage.parse(withActor.encoded), withActor)

        let withoutActor = try XCTUnwrap(KitSystemMessage(
            kind: .memberLeft,
            subjectUserID: subject,
            actorUserID: nil
        ))
        XCTAssertEqual(withoutActor.encoded, "KITSYS1:v=1&k=member_left&u=\(subject)")
        XCTAssertEqual(KitSystemMessage.parse(withoutActor.encoded), withoutActor)

        XCTAssertNil(KitSystemMessage(kind: .memberAdded, subjectUserID: "x", actorUserID: nil))
        XCTAssertNil(KitSystemMessage.parse("KITSYS1:v=2&k=member_left&u=\(subject)"))
        XCTAssertNil(KitSystemMessage.parse("KITSYS1:v=1&k=member_evicted&u=\(subject)"))
        XCTAssertNil(KitSystemMessage.parse("KITSYS1:v=1&k=member_left&u=not-a-uuid"))
        XCTAssertNil(KitSystemMessage.parse("KITSYS1:v=1&k=member_left&u=\(subject)&u=\(subject)"))
        XCTAssertNil(KitSystemMessage.parse("KITSYS1:k=member_left&v=1&u=\(subject)"))
        XCTAssertNil(KitSystemMessage.parse(
            "KITSYS1:v=1&k=member_left&u=\(subject.uppercased())"
        ))
        XCTAssertNil(KitSystemMessage.parse(" KITSYS1:v=1&k=member_left&u=\(subject)"))

        // The composer boundary reserves the namespace exactly like KITPAY1.
        XCTAssertFalse(SecureMessageReservedPrefixPolicy.allowsUserAuthoredText(
            withActor.encoded
        ))
        XCTAssertFalse(SecureMessageReservedPrefixPolicy.allowsUserAuthoredText(
            "  \nKITSYS1:not-even-valid"
        ))
        XCTAssertTrue(SecureMessageReservedPrefixPolicy.allowsUserAuthoredText(
            "About KITSYS1: mid-sentence is fine"
        ))
    }

    func testBuild24FeaturesShareTheExactIOSReleaseFloor() {
        let expected = "1.0.16-r24"
        XCTAssertEqual(MessagingBuild24CompatibilityPolicy.minimumIOSRelease, expected)
        XCTAssertEqual(MessagingRichMediaCapabilityPolicy.extendedSizeMinimumIOSRelease, expected)
        XCTAssertEqual(MessagingGroupCapabilityPolicy.minimumIOSRelease, expected)
        XCTAssertEqual(MessagingReactionCapabilityPolicy.minimumIOSRelease, expected)
        XCTAssertEqual(KitRealtimeConfiguration.minimumIOSRelease, expected)

        XCTAssertFalse(MessagingBuild24CompatibilityPolicy.supportsIOS(
            version: "1.0.15",
            build: 23
        ))
        XCTAssertFalse(MessagingBuild24CompatibilityPolicy.supportsIOS(
            version: "1.0.16",
            build: 23
        ))
        XCTAssertTrue(MessagingBuild24CompatibilityPolicy.supportsIOS(
            version: "1.0.16",
            build: 24
        ))
        XCTAssertTrue(MessagingBuild24CompatibilityPolicy.supportsIOS(
            version: "1.0.17",
            build: 1
        ))
    }

    func testGroupCapabilityPolicyRequiresEveryMemberDeviceAttested() throws {
        let conversationID = "0a1b2c3d-0000-4000-8000-000000000020"
        let currentDeviceID = "0a1b2c3d-0000-4000-8000-000000000021"
        let localUserID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let peerUserID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let thirdUserID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        let members: Set<String> = [localUserID, peerUserID, thirdUserID]

        func device(
            id: String,
            userID: String,
            attested: Bool?,
            platform: String = "android",
            version: String? = "0.3.0",
            build: Int? = nil
        ) -> [String: Any] {
            var object: [String: Any] = ["device_id": id, "user_id": userID]
            if let attested {
                var client: [String: Any] = [
                    "platform": platform,
                    "capabilities": [MessagingGroupCapabilityPolicy.deviceCapabilityKey: attested],
                ]
                if let version { client["version"] = version }
                if let build { client["build"] = build }
                object["client"] = client
            }
            return object
        }
        func supports(_ devices: [[String: Any]], memberUserIDs: Set<String> = members) throws -> Bool {
            let roster = try decode(MessagingDeviceRosterDTO.self, object: [
                "conversation_id": conversationID,
                "devices": devices,
            ])
            return MessagingGroupCapabilityPolicy.supports(
                roster: roster,
                conversationID: conversationID,
                currentDeviceID: currentDeviceID,
                memberUserIDs: memberUserIDs
            )
        }

        let local = device(id: currentDeviceID, userID: localUserID, attested: nil)
        let peer = device(
            id: "0a1b2c3d-0000-4000-8000-000000000022",
            userID: peerUserID,
            attested: true
        )
        let third = device(
            id: "0a1b2c3d-0000-4000-8000-000000000023",
            userID: thirdUserID,
            attested: true
        )
        XCTAssertTrue(try supports([local, peer, third]))
        XCTAssertFalse(try supports([
            local,
            device(
                id: "0a1b2c3d-0000-4000-8000-000000000022",
                userID: peerUserID,
                attested: true,
                platform: "ios",
                version: "1.0.15",
                build: 23
            ),
            third,
        ]))
        XCTAssertTrue(try supports([
            local,
            device(
                id: "0a1b2c3d-0000-4000-8000-000000000022",
                userID: peerUserID,
                attested: true,
                platform: "ios",
                version: "1.0.16",
                build: 24
            ),
            third,
        ]))
        XCTAssertFalse(try supports([
            local,
            device(
                id: "0a1b2c3d-0000-4000-8000-000000000022",
                userID: peerUserID,
                attested: true,
                platform: "ios",
                version: "1.0.16"
            ),
            third,
        ]), "An iOS peer with missing build metadata must fail closed")
        XCTAssertFalse(try supports([
            local,
            device(
                id: "0a1b2c3d-0000-4000-8000-000000000022",
                userID: peerUserID,
                attested: true,
                platform: "ios",
                version: nil,
                build: 24
            ),
            third,
        ]), "An iOS peer with missing version metadata must fail closed")
        // One stale device anywhere in the roster blocks the group send.
        XCTAssertFalse(try supports([
            local,
            peer,
            device(id: "0a1b2c3d-0000-4000-8000-000000000023", userID: thirdUserID, attested: false),
        ]))
        XCTAssertFalse(try supports([
            local,
            peer,
            device(id: "0a1b2c3d-0000-4000-8000-000000000023", userID: thirdUserID, attested: nil),
        ]))
        // Every member must be present, and nobody outside the member set may appear.
        XCTAssertFalse(try supports([local, peer]))
        XCTAssertFalse(try supports([
            local, peer, third,
            device(
                id: "0a1b2c3d-0000-4000-8000-000000000024",
                userID: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
                attested: true
            ),
        ]))
        // A valid group may shrink to one active member after removal; an empty or mismatched
        // roster still fails closed.
        XCTAssertTrue(try supports([local], memberUserIDs: [localUserID]))
        XCTAssertFalse(try supports([local, peer, third], memberUserIDs: []))
        XCTAssertFalse(try {
            let roster = try decode(MessagingDeviceRosterDTO.self, object: [
                "conversation_id": "0a1b2c3d-0000-4000-8000-00000000ffff",
                "devices": [local, peer, third],
            ])
            return MessagingGroupCapabilityPolicy.supports(
                roster: roster,
                conversationID: conversationID,
                currentDeviceID: currentDeviceID,
                memberUserIDs: members
            )
        }())
    }

    func testReactionCapabilityRequiresEveryDestinationDeviceButExemptsCurrentDevice() throws {
        let conversationID = "0a1b2c3d-0000-4000-8000-000000000020"
        let currentDeviceID = "0a1b2c3d-0000-4000-8000-000000000021"
        let localUserID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let peerUserID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let peerDeviceID = "0a1b2c3d-0000-4000-8000-000000000022"
        let members: Set<String> = [localUserID, peerUserID]

        func roster(
            peerCapability: Bool?,
            platform: String = "android",
            version: String = "1.0.16",
            build: Int = 24,
            includeNull: Bool = false
        ) throws
            -> MessagingDeviceRosterDTO {
            var peer: [String: Any] = [
                "device_id": peerDeviceID,
                "user_id": peerUserID,
            ]
            if let peerCapability {
                peer["client"] = [
                    "platform": platform,
                    "version": version,
                    "build": build,
                    "capabilities": [
                        MessagingReactionCapabilityPolicy.deviceCapabilityKey: peerCapability,
                    ],
                ]
            }
            var devices: [Any] = [
                ["device_id": currentDeviceID, "user_id": localUserID],
                peer,
            ]
            if includeNull { devices.append(NSNull()) }
            return try decode(MessagingDeviceRosterDTO.self, object: [
                "conversation_id": conversationID,
                "devices": devices,
            ])
        }

        XCTAssertTrue(MessagingReactionCapabilityPolicy.supports(
            roster: try roster(peerCapability: true),
            conversationID: conversationID,
            currentDeviceID: currentDeviceID,
            memberUserIDs: members
        ))
        for unsupported in [false, nil] as [Bool?] {
            XCTAssertFalse(MessagingReactionCapabilityPolicy.supports(
                roster: try roster(peerCapability: unsupported),
                conversationID: conversationID,
                currentDeviceID: currentDeviceID,
                memberUserIDs: members
            ))
        }
        XCTAssertFalse(MessagingReactionCapabilityPolicy.supports(
            roster: try roster(peerCapability: true, includeNull: true),
            conversationID: conversationID,
            currentDeviceID: currentDeviceID,
            memberUserIDs: members
        ))
        XCTAssertFalse(MessagingReactionCapabilityPolicy.supports(
            roster: try roster(
                peerCapability: true,
                platform: "ios",
                version: "1.0.15",
                build: 23
            ),
            conversationID: conversationID,
            currentDeviceID: currentDeviceID,
            memberUserIDs: members
        ))
        XCTAssertTrue(MessagingReactionCapabilityPolicy.supports(
            roster: try roster(
                peerCapability: true,
                platform: "ios",
                version: "1.0.16",
                build: 24
            ),
            conversationID: conversationID,
            currentDeviceID: currentDeviceID,
            memberUserIDs: members
        ))
    }

    func testRosterMapperAcceptsGroupMemberRangeAndRejectsOutOfRange() throws {
        let members = [
            groupRosterMember(
                userID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                deviceID: "10000000-0000-4000-8000-000000000001",
                registrationID: 1_001,
                seed: 0x11
            ),
            groupRosterMember(
                userID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
                deviceID: "20000000-0000-4000-8000-000000000001",
                registrationID: 2_001,
                seed: 0x21
            ),
            groupRosterMember(
                userID: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
                deviceID: "30000000-0000-4000-8000-000000000001",
                registrationID: 3_001,
                seed: 0x31
            ),
        ]
        let dto = try groupRosterDTO(members: members)
        let expected = Set(members.map(\.userID))

        let roster = try SecureMessagingMapper.roster(
            from: dto,
            use: .current,
            expectedConversationID: conversationId,
            currentDeviceID: members[0].deviceID,
            currentUserID: members[0].userID,
            expectedMemberUserIDs: expected
        )
        XCTAssertEqual(roster.devices.count, 3)
        XCTAssertEqual(Set(roster.devices.map(\.address.userID)), expected)

        // A single-member expectation and an over-limit expectation both fail closed.
        XCTAssertThrowsError(try SecureMessagingMapper.roster(
            from: dto,
            use: .current,
            expectedConversationID: conversationId,
            currentDeviceID: members[0].deviceID,
            currentUserID: members[0].userID,
            expectedMemberUserIDs: [members[0].userID]
        ))
        var oversized = expected
        for index in 0 ..< (SecureMessagingWire.maximumGroupMembers + 1 - expected.count) {
            oversized.insert(String(format: "dddddddd-0000-4000-8000-%012d", index))
        }
        XCTAssertEqual(oversized.count, SecureMessagingWire.maximumGroupMembers + 1)
        XCTAssertThrowsError(try SecureMessagingMapper.roster(
            from: dto,
            use: .current,
            expectedConversationID: conversationId,
            currentDeviceID: members[0].deviceID,
            currentUserID: members[0].userID,
            expectedMemberUserIDs: oversized
        ))
        // Device-set equality against the member set is preserved.
        XCTAssertThrowsError(try SecureMessagingMapper.roster(
            from: dto,
            use: .current,
            expectedConversationID: conversationId,
            currentDeviceID: members[0].deviceID,
            currentUserID: members[0].userID,
            expectedMemberUserIDs: [
                members[0].userID,
                members[1].userID,
                "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
            ]
        ))

        let singleCurrentDTO = try groupRosterDTO(members: [members[0]])
        XCTAssertThrowsError(try SecureMessagingMapper.roster(
            from: singleCurrentDTO,
            use: .current,
            expectedConversationID: conversationId,
            currentDeviceID: members[0].deviceID,
            currentUserID: members[0].userID,
            expectedMemberUserIDs: [members[0].userID]
        ))
        let singleHistoricalDTO = try groupRosterDTO(
            members: [members[0]],
            includesEnrollmentEpoch: false
        )
        let historical = try SecureMessagingMapper.roster(
            from: singleHistoricalDTO,
            use: .historical,
            expectedConversationID: conversationId,
            currentDeviceID: members[0].deviceID,
            currentUserID: members[0].userID,
            expectedMemberUserIDs: [members[0].userID],
            allowHistoricalGroupMembershipChurn: true
        )
        XCTAssertEqual(historical.devices.map(\.address.userID), [members[0].userID])
    }

    private struct GroupRosterMember {
        let userID: String
        let deviceID: String
        let registrationID: Int
        let identityKey: Data
        let signedPreKey: Data
        let signedPreKeySignature: Data
    }

    private func groupRosterMember(
        userID: String,
        deviceID: String,
        registrationID: Int,
        seed: UInt8
    ) -> GroupRosterMember {
        GroupRosterMember(
            userID: userID,
            deviceID: deviceID,
            registrationID: registrationID,
            identityKey: signalPublicKey(seed),
            signedPreKey: signalPublicKey(seed &+ 1),
            signedPreKeySignature: Data(repeating: seed &+ 2, count: 64)
        )
    }

    /// Rebuilds the pinned cross-platform `kit.messaging.device-roster.v1` canonical bytes so a
    /// contract change in either the schema or the mapper hash check fails this test.
    private func groupRosterDTO(
        members: [GroupRosterMember],
        includesEnrollmentEpoch: Bool = true
    ) throws -> MessagingDeviceRosterDTO {
        let publishedAt = "2026-08-20T10:00:00Z"
        var canonical = "{\"schema\":\"kit.messaging.device-roster.v1\",\"conversation_id\":"
        canonical += "\"\(conversationId)\",\"devices\":["
        var deviceObjects: [[String: Any]] = []
        for (index, member) in members.enumerated() {
            let identityHash = SecureMessagingValidation.sha256Hex(member.identityKey)
            let signedHash = SecureMessagingValidation.sha256Hex(member.signedPreKey)
            if index > 0 { canonical += "," }
            canonical += "{\"device_id\":\"\(member.deviceID)\""
            canonical += ",\"user_id\":\"\(member.userID)\""
            canonical += ",\"signal_device_id\":1"
            canonical += ",\"registration_id\":\(member.registrationID)"
            canonical += ",\"protocol_version\":\"v2\""
            canonical += ",\"bundle_version\":11"
            canonical += ",\"identity_key\":\"\(member.identityKey.base64EncodedString())\""
            canonical += ",\"identity_key_sha256\":\"\(identityHash)\""
            canonical += ",\"signed_prekey\":{\"prekey_id\":101"
            canonical += ",\"public_key\":\"\(member.signedPreKey.base64EncodedString())\""
            canonical += ",\"public_key_sha256\":\"\(signedHash)\""
            canonical +=
                ",\"signature\":\"\(member.signedPreKeySignature.base64EncodedString())\"}"
            canonical += ",\"published_at\":\"\(publishedAt)\""
            canonical += ",\"rotated_at\":null"
            canonical += ",\"identity_key_changed_at\":\"\(publishedAt)\""
            canonical += ",\"bundle_version_changed_at\":\"\(publishedAt)\"}"
            var deviceObject: [String: Any] = [
                "device_id": member.deviceID,
                "user_id": member.userID,
                "signal_device_id": 1,
                "registration_id": member.registrationID,
                "protocol_version": "v2",
                "bundle_version": 11,
                "identity_key": member.identityKey.base64EncodedString(),
                "identity_key_sha256": identityHash,
                "signed_prekey": [
                    "prekey_id": 101,
                    "public_key": member.signedPreKey.base64EncodedString(),
                    "public_key_sha256": signedHash,
                    "signature": member.signedPreKeySignature.base64EncodedString(),
                ],
                "published_at": publishedAt,
                "identity_key_changed_at": publishedAt,
                "bundle_version_changed_at": publishedAt,
            ]
            if includesEnrollmentEpoch { deviceObject["enrollment_epoch"] = 7 }
            deviceObjects.append(deviceObject)
        }
        canonical += "]}"
        let hash = SecureMessagingValidation.sha256Hex(Data(canonical.utf8))
        return try decode(MessagingDeviceRosterDTO.self, object: [
            "conversation_id": conversationId,
            "roster_revision": "v1:sha256:\(hash)",
            "roster_hash": hash,
            "hash_algorithm": "sha256",
            "devices": deviceObjects,
        ])
    }

    private var mapperLocalDevice: MapperDeviceFixture {
        MapperDeviceFixture(
            userID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            deviceID: "10000000-0000-4000-8000-000000000001",
            signalDeviceID: 1,
            registrationID: 1_001,
            enrollmentEpoch: 7,
            bundleVersion: 11,
            identityKey: signalPublicKey(0x11),
            signedPreKeyID: 101,
            signedPreKey: signalPublicKey(0x12),
            signedPreKeySignature: Data(repeating: 0x13, count: 64)
        )
    }

    private var mapperCompanionDevice: MapperDeviceFixture {
        MapperDeviceFixture(
            userID: mapperLocalDevice.userID,
            deviceID: "10000000-0000-4000-8000-000000000002",
            signalDeviceID: 2,
            registrationID: 1_002,
            enrollmentEpoch: 8,
            bundleVersion: 12,
            identityKey: signalPublicKey(0x21),
            signedPreKeyID: 102,
            signedPreKey: signalPublicKey(0x22),
            signedPreKeySignature: Data(repeating: 0x23, count: 64)
        )
    }

    private var mapperPeerDevice: MapperDeviceFixture {
        MapperDeviceFixture(
            userID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            deviceID: "20000000-0000-4000-8000-000000000001",
            signalDeviceID: 1,
            registrationID: 2_001,
            enrollmentEpoch: 9,
            bundleVersion: 21,
            identityKey: signalPublicKey(0x31),
            signedPreKeyID: 201,
            signedPreKey: signalPublicKey(0x32),
            signedPreKeySignature: Data(repeating: 0x33, count: 64)
        )
    }

    private func mapperRoster(use: SecureMessagingRosterUse) -> SecureMessagingRosterSnapshot {
        let fixtures = [mapperLocalDevice, mapperCompanionDevice, mapperPeerDevice]
        let devices = fixtures.map { fixture in
            SecureMessagingRosterDevice(
                address: SecureMessagingAddress(
                    userID: fixture.userID,
                    serverDeviceID: fixture.deviceID,
                    signalDeviceID: fixture.signalDeviceID
                ),
                registrationID: fixture.registrationID,
                identityKeySHA256: SecureMessagingValidation.sha256Hex(fixture.identityKey)
            )
        }
        let frozen = Dictionary(uniqueKeysWithValues: fixtures.map { fixture in
            (
                fixture.deviceID,
                SecureMessagingFrozenRosterDevice(
                    enrollmentEpoch: use == .current ? fixture.enrollmentEpoch : nil,
                    bundleVersion: fixture.bundleVersion,
                    signedPreKeyID: fixture.signedPreKeyID,
                    signedPreKeyPublicKey: fixture.signedPreKey,
                    signedPreKeySHA256: SecureMessagingValidation.sha256Hex(
                        fixture.signedPreKey
                    ),
                    signedPreKeySignature: fixture.signedPreKeySignature
                )
            )
        })
        return SecureMessagingRosterSnapshot(
            use: use,
            conversationID: conversationId,
            rosterRevision: rosterRevision,
            devices: devices,
            frozenDevices: frozen
        )
    }

    private func consumedBundleObject(_ fixture: MapperDeviceFixture) -> [String: Any] {
        [
            "device_id": fixture.deviceID,
            "signal_device_id": Int(fixture.signalDeviceID),
            "user_id": fixture.userID,
            "protocol_version": "v2",
            "registration_id": Int(fixture.registrationID),
            "identity_key": fixture.identityKey.base64EncodedString(),
            "identity_key_sha256": SecureMessagingValidation.sha256Hex(fixture.identityKey),
            "signed_prekey": [
                "prekey_id": Int(fixture.signedPreKeyID),
                "public_key": fixture.signedPreKey.base64EncodedString(),
                "signature": fixture.signedPreKeySignature.base64EncodedString(),
            ],
            "one_time_prekey": [
                "prekey_id": 301,
                "public_key": signalPublicKey(0x41).base64EncodedString(),
            ],
            "pq_prekey": [
                "prekey_id": 401,
                "public_key": pqPublicKey(0x42).base64EncodedString(),
                "signature": Data(repeating: 0x43, count: 64).base64EncodedString(),
            ],
            "bundle_version": fixture.bundleVersion,
            "is_current_device": false,
        ]
    }

    private func consumedBundlesDTO(
        _ bundles: [[String: Any]]
    ) throws -> ConsumedMessagingKeyBundlesDTO {
        try decode(ConsumedMessagingKeyBundlesDTO.self, object: ["bundles": bundles])
    }

    private func inboundMessageObject(senderEnrollmentEpoch: Int64) -> [String: Any] {
        let sender = mapperPeerDevice
        let ciphertext = Data("opaque authenticated ciphertext".utf8)
        let cryptoSender: [String: Any] = [
            "user_id": sender.userID,
            "device_id": sender.deviceID,
            "enrollment_epoch": senderEnrollmentEpoch,
            "signal_device_id": Int(sender.signalDeviceID),
            "registration_id": Int(sender.registrationID),
            "protocol_version": "v2",
            "bundle_version": sender.bundleVersion,
            "identity_key_sha256": SecureMessagingValidation.sha256Hex(sender.identityKey),
        ]
        return [
            "id": "70000000-0000-4000-8000-000000000001",
            "conversation_id": conversationId,
            "client_message_id": "80000000-0000-4000-8000-000000000001",
            "sender": ["id": sender.userID, "name": "Peer"],
            "sender_device_id": sender.deviceID,
            "sender_enrollment_epoch": senderEnrollmentEpoch,
            "sender_signal_device_id": Int(sender.signalDeviceID),
            "sender_registration_id": Int(sender.registrationID),
            "sender_protocol_version": "v2",
            "sender_bundle_version": sender.bundleVersion,
            "sender_identity_key_sha256": SecureMessagingValidation.sha256Hex(sender.identityKey),
            "roster_revision": rosterRevision,
            "kind": "encrypted",
            "attachments": [],
            "reactions": [],
            "envelope": [
                "recipient_device_id": mapperLocalDevice.deviceID,
                "recipient_enrollment_epoch": mapperLocalDevice.enrollmentEpoch,
                "envelope_type": "signal-message-v2",
                "ciphertext": ciphertext.base64EncodedString(),
                "ciphertext_sha256": SecureMessagingValidation.sha256Hex(ciphertext),
                "is_history_backfill": false,
                "crypto_sender": cryptoSender,
            ],
        ]
    }

    private func mapInbound(
        _ object: [String: Any],
        roster: SecureMessagingRosterSnapshot
    ) throws -> SecureMessagingInboundEnvelope {
        try SecureMessagingMapper.inboundEnvelope(
            from: decode(EncryptedMessageDTO.self, object: object),
            localRecipient: SecureMessagingAddress(
                userID: mapperLocalDevice.userID,
                serverDeviceID: mapperLocalDevice.deviceID,
                signalDeviceID: mapperLocalDevice.signalDeviceID
            ),
            localEnrollment: mapperLocalEnrollment,
            roster: roster
        )
    }

    private var mapperLocalEnrollment: SecureMessagingEnrollmentBinding {
        let local = mapperLocalDevice
        return SecureMessagingEnrollmentBinding(
            userID: local.userID,
            serverDeviceID: local.deviceID,
            signalDeviceID: local.signalDeviceID,
            registrationID: local.registrationID,
            enrollmentEpoch: local.enrollmentEpoch,
            identityKeySHA256: SecureMessagingValidation.sha256Hex(local.identityKey),
            bundleVersion: local.bundleVersion,
            signedPreKeyID: local.signedPreKeyID,
            signedPreKeySHA256: SecureMessagingValidation.sha256Hex(local.signedPreKey),
            pqLastResortPreKeyID: 501,
            pqLastResortPreKeySHA256: SecureMessagingValidation.sha256Hex(
                Data(repeating: 0x51, count: 1_569)
            )
        )
    }

    private func replacing(
        _ object: [String: Any],
        at path: [String],
        with value: Any?
    ) -> [String: Any] {
        precondition(!path.isEmpty)
        var copy = object
        let key = path[0]
        if path.count == 1 {
            if let value {
                copy[key] = value
            } else {
                copy.removeValue(forKey: key)
            }
            return copy
        }
        guard let child = copy[key] as? [String: Any] else {
            preconditionFailure("Fixture path does not contain an object at \(key)")
        }
        copy[key] = replacing(child, at: Array(path.dropFirst()), with: value)
        return copy
    }

    private func decode<Value: Decodable>(
        _ type: Value.Type,
        object: Any
    ) throws -> Value {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(type, from: data)
    }

    private func offlineDirectCreationCapabilities(enabled: Bool) throws -> CapabilitiesDTO {
        var messaging: [String: Any] = [
            "ready": true,
            "version": SecureMessagingWire.protocolVersion,
            "suite": SecureMessagingWire.protocolSuite,
            "post_quantum": true,
        ]
        if enabled {
            messaging["offline_direct_creation"] = [
                "profile": MessagingOfflineDirectCreationCapabilityDTO.reviewedProfile,
                "ready": true,
                "request_field": MessagingOfflineDirectCreationCapabilityDTO
                    .reviewedRequestField,
                "canonical_id_on_create": true,
                "existing_pair_wins": true,
            ]
        }
        return try decode(CapabilitiesDTO.self, object: [
            "api_version": "v1",
            "currency": ["code": "UGX", "scale": "2"],
            "features": ["messaging": true],
            "protocols": ["messaging": messaging],
        ])
    }

    private func signalPublicKey(_ byte: UInt8) -> Data {
        Data([5]) + Data(repeating: byte, count: 32)
    }

    private func pqPublicKey(_ byte: UInt8) -> Data {
        Data([8]) + Data(repeating: byte, count: 1_568)
    }

    private func keyPublication() throws -> PublishMessagingKeyBundleRequest {
        try PublishMessagingKeyBundleRequest(
            registrationId: 42,
            identityKey: base64(count: 33, byte: 1),
            signedPrekey: MessagingSignedPrekeyRequest(
                prekeyId: 1,
                publicKey: base64(count: 33, byte: 2),
                signature: base64(count: 64, byte: 3)
            ),
            oneTimePrekeys: [
                MessagingOneTimePrekeyRequest(
                    prekeyId: 2,
                    publicKey: base64(count: 33, byte: 4)
                ),
            ],
            pqPrekeys: [
                MessagingPQPrekeyRequest(
                    prekeyId: 3,
                    publicKey: base64(count: 1_569, byte: 5),
                    signature: base64(count: 64, byte: 6)
                ),
            ],
            pqLastResortPrekey: MessagingPQPrekeyRequest(
                prekeyId: 4,
                publicKey: base64(count: 1_569, byte: 7),
                signature: base64(count: 64, byte: 8)
            )
        )
    }

    private func base64(count: Int, byte: UInt8) -> String {
        Data(repeating: byte, count: count).base64EncodedString()
    }

    private func localMessage(body: String) -> LocalMessage {
        LocalMessage(
            id: UUID(),
            conversationId: conversationId,
            senderId: "44444444-4444-4444-8444-444444444444",
            body: body,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            sentAt: nil,
            state: .received,
            failureReason: nil,
            isOutgoing: false
        )
    }

    private func jsonObject<Value: Encodable>(_ value: Value) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
