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

    func testDraftRestoreCannotConfuseSealedAndProtectedRepresentations() async throws {
        let sealedKey = UUID().uuidString.lowercased()
        let sealed = Data("sealed draft".utf8)
        let insert = await cache.insertIfAbsent(
            sealed,
            forStorageKey: sealedKey,
            userID: userID
        )
        XCTAssertEqual(insert, .stored)
        let restoredSealed = await cache.encryptedBlobData(
            forStorageKey: sealedKey,
            userID: userID,
            expectedByteCount: sealed.count
        )
        XCTAssertEqual(restoredSealed, sealed)
        let sealedAsProtected = await cache.protectedOriginalURL(
            forStorageKey: sealedKey,
            userID: userID,
            expectedByteCount: sealed.count
        )
        XCTAssertNil(sealedAsProtected)

        let protectedKey = UUID().uuidString.lowercased()
        let source = temporaryDirectory.appendingPathComponent("draft.pdf")
        let protected = Data("protected draft".utf8)
        try protected.write(to: source)
        let url = try await cache.importProtectedOriginal(
            from: source,
            forStorageKey: protectedKey,
            userID: userID,
            mediaType: "application/pdf",
            expectedByteCount: protected.count,
            moveSource: true
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let protectedAsSealed = await cache.encryptedBlobData(
            forStorageKey: protectedKey,
            userID: userID,
            expectedByteCount: protected.count
        )
        XCTAssertNil(protectedAsSealed)
    }

    func testLegacyEncryptedVideoPromotesToProtectedLeaseBeforePlayback() async throws {
        let storageKey = UUID().uuidString.lowercased()
        // Large enough to exercise the file-backed path without making every hosted CI run pay
        // the 200 MiB production ceiling. The production invariant is structural: playback gets
        // an empty-Data LocalFileItem regardless of whether the source is 32 MiB or 200 MiB.
        let videoBytes = Data(repeating: 0x6d, count: 32 * 1_024 * 1_024)
        let insertion = await cache.insertIfAbsent(
            videoBytes,
            forStorageKey: storageKey,
            userID: userID
        )
        XCTAssertEqual(insertion, .stored)

        let proposedLease = try await cache.promoteEncryptedBlobToProtectedOriginal(
            forStorageKey: storageKey,
            userID: userID,
            mediaType: "video/mp4",
            expectedByteCount: videoBytes.count
        )
        let lease = try XCTUnwrap(proposedLease)
        XCTAssertEqual(lease.fileURL.pathExtension, "mp4")
        XCTAssertEqual(try Data(contentsOf: lease.fileURL), videoBytes)
        let retainedSealed = await cache.encryptedBlobData(
            forStorageKey: storageKey,
            userID: userID,
            expectedByteCount: videoBytes.count
        )
        XCTAssertEqual(
            retainedSealed,
            videoBytes,
            "the sealed source must survive until protected state commits its new storage kind"
        )

        let proposedRetryLease = try await cache.promoteEncryptedBlobToProtectedOriginal(
            forStorageKey: storageKey,
            userID: userID,
            mediaType: "video/mp4",
            expectedByteCount: videoBytes.count
        )
        let retryLease = try XCTUnwrap(proposedRetryLease)
        XCTAssertEqual(retryLease.fileURL, lease.fileURL)

        await cache.removeEncryptedBlobRepresentation(
            forStorageKey: storageKey,
            userID: userID
        )
        let removedSealed = await cache.encryptedBlobData(
            forStorageKey: storageKey,
            userID: userID,
            expectedByteCount: videoBytes.count
        )
        XCTAssertNil(removedSealed)
        let protectedURL = await cache.protectedOriginalURL(
            forStorageKey: storageKey,
            userID: userID,
            expectedByteCount: videoBytes.count
        )
        XCTAssertEqual(protectedURL, lease.fileURL)
        await cache.releaseProtectedOriginalLease(retryLease)
        await cache.releaseProtectedOriginalLease(lease)
    }

    func testLegacyInlineReceivedMediaCompactsAsOneFileBackedBatch() async throws {
        let videoBytes = Data(repeating: 0x31, count: 96 * 1_024)
        let documentBytes = Data(repeating: 0x42, count: 48 * 1_024)
        let video = try makeLegacyInlineReceivedMessage(
            mediaType: "video/mp4",
            bytes: videoBytes
        )
        let document = try makeLegacyInlineReceivedMessage(
            mediaType: "application/pdf",
            bytes: documentBytes
        )
        let originalState = legacyInlineReceivedState(messages: [video.message, document.message])
        let originalEncodedSize = try JSONEncoder().encode(originalState).count

        let prepared = await LegacyInlineReceivedMediaCompactionPolicy.prepare(
            state: originalState,
            forUserID: userID,
            cache: cache,
            now: Date(timeIntervalSince1970: 1_800_000_001)
        )

        XCTAssertEqual(prepared.eligibleCount, 2)
        XCTAssertEqual(prepared.promotedCount, 2)
        XCTAssertEqual(
            prepared.promotedByteCount,
            Int64(videoBytes.count + documentBytes.count)
        )
        XCTAssertTrue(prepared.state.messages.allSatisfy { $0.attachmentData == nil })
        XCTAssertLessThan(try JSONEncoder().encode(prepared.state).count, originalEncodedSize)

        for expected in [video, document] {
            let message = try XCTUnwrap(prepared.state.messages.first(where: {
                $0.id == expected.message.id
            }))
            let record = try XCTUnwrap(message.localMediaRecords?.first)
            XCTAssertEqual(record.id, expected.descriptor.attachmentID)
            XCTAssertEqual(record.localStorageKind, .protectedFile)
            XCTAssertEqual(record.localStorageKey, expected.descriptor.attachmentID)
            XCTAssertEqual(record.remoteEncryptedObjectID, expected.descriptor.storageKey)
            XCTAssertEqual(record.availabilityState, .localCached)
            XCTAssertEqual(record.downloadState, .downloaded)
            XCTAssertEqual(record.encryptionState, .decrypted)

            let playbackLease = await cache.protectedOriginalLease(
                forStorageKey: expected.descriptor.attachmentID,
                userID: userID,
                expectedByteCount: expected.descriptor.plaintextByteSize
            )
            let lease = try XCTUnwrap(playbackLease)
            let loaded = SecureMediaLoadPolicy.LoadedItem(localFile: .init(
                url: lease.fileURL,
                mediaType: expected.descriptor.mediaType,
                caption: expected.descriptor.caption,
                byteCount: expected.descriptor.plaintextByteSize,
                attachmentID: expected.descriptor.attachmentID,
                accessLease: lease
            ))
            XCTAssertTrue(loaded.data.isEmpty)
            XCTAssertEqual(loaded.localFileURL, lease.fileURL)
            XCTAssertEqual(try Data(contentsOf: lease.fileURL), expected.bytes)
            await cache.releaseProtectedOriginalLease(lease)
        }
        await prepared.releaseProtectedOriginalLeases(using: cache)
    }

    func testLegacyInlineCompactionLeavesMismatchedRowsUnchanged() async throws {
        let bytes = Data(repeating: 0x53, count: 8 * 1_024)
        var fixture = try makeLegacyInlineReceivedMessage(
            mediaType: "video/mp4",
            bytes: bytes
        )
        _ = LocalMediaRecordPolicy.migrateAndRecover(&fixture.message)
        fixture.message.localMediaRecords?[0].mediaType = "image/jpeg"
        let originalMessage = fixture.message

        let prepared = await LegacyInlineReceivedMediaCompactionPolicy.prepare(
            state: legacyInlineReceivedState(messages: [originalMessage]),
            forUserID: userID,
            cache: cache
        )

        XCTAssertEqual(prepared.eligibleCount, 1)
        XCTAssertEqual(prepared.promotedCount, 0)
        XCTAssertEqual(prepared.promotedByteCount, 0)
        XCTAssertEqual(prepared.state.messages, [originalMessage])
        let protectedURL = await cache.protectedOriginalURL(
            forStorageKey: fixture.descriptor.attachmentID,
            userID: userID,
            expectedByteCount: bytes.count
        )
        XCTAssertNil(protectedURL)
        await prepared.releaseProtectedOriginalLeases(using: cache)
    }

    func testLegacyInlineCompactionDoesNotClearBytesWhenCachePublicationFails() async throws {
        let bytes = Data(repeating: 0x64, count: 8 * 1_024)
        var fixture = try makeLegacyInlineReceivedMessage(
            mediaType: "video/quicktime",
            bytes: bytes
        )
        _ = LocalMediaRecordPolicy.migrateAndRecover(&fixture.message)
        let originalMessage = fixture.message
        let occupied = Data("an existing sealed representation".utf8)
        let insertion = await cache.insertIfAbsent(
            occupied,
            forStorageKey: fixture.descriptor.attachmentID,
            userID: userID
        )
        XCTAssertEqual(insertion, .stored)

        let prepared = await LegacyInlineReceivedMediaCompactionPolicy.prepare(
            state: legacyInlineReceivedState(messages: [originalMessage]),
            forUserID: userID,
            cache: cache
        )

        XCTAssertEqual(prepared.eligibleCount, 1)
        XCTAssertEqual(prepared.promotedCount, 0)
        XCTAssertEqual(prepared.state.messages, [originalMessage])
        XCTAssertEqual(prepared.state.messages.first?.attachmentData, bytes)
        let retained = await cache.encryptedBlobData(
            forStorageKey: fixture.descriptor.attachmentID,
            userID: userID,
            expectedByteCount: occupied.count
        )
        XCTAssertEqual(retained, occupied)
        await prepared.releaseProtectedOriginalLeases(using: cache)
    }

    func testStreamedLegacyVideoMayCoexistWithSealedBlobUntilStateCommit() async throws {
        let storageKey = UUID().uuidString.lowercased()
        let videoBytes = Data((0 ..< 64 * 1_024).map { UInt8($0 % 251) })
        let plaintextURL = temporaryDirectory.appendingPathComponent("legacy-video.mp4")
        let ciphertextURL = temporaryDirectory.appendingPathComponent("legacy-video.ciphertext")
        let keyMaterial = Data(
            (0 ..< SecureMediaAttachmentCipher.keyMaterialBytes).map(UInt8.init)
        )
        try videoBytes.write(to: plaintextURL, options: .atomic)
        let encrypted = try SecureMediaAttachmentCipher.encryptFile(
            plaintextURL: plaintextURL,
            ciphertextURL: ciphertextURL,
            expectedPlaintextByteSize: videoBytes.count,
            keyMaterial: keyMaterial,
            attachmentID: storageKey,
            chunkBytes: 4_093
        )
        let sealedInsertion = await cache.insertIfAbsent(
            videoBytes,
            forStorageKey: storageKey,
            userID: userID
        )
        XCTAssertEqual(sealedInsertion, .stored)

        let streamed = try await cache.storeVerifiedReceivedOriginal(
            ciphertextURL: ciphertextURL,
            forStorageKey: storageKey,
            userID: userID,
            mediaType: "video/mp4",
            ciphertextByteCount: encrypted.ciphertextByteSize,
            ciphertextSHA256: encrypted.ciphertextSHA256,
            plaintextByteCount: encrypted.plaintextByteSize,
            keyMaterial: keyMaterial
        )
        XCTAssertEqual(streamed.insertion, .stored)
        XCTAssertEqual(try Data(contentsOf: streamed.fileURL), videoBytes)
        let retainedSealed = await cache.encryptedBlobData(
            forStorageKey: storageKey,
            userID: userID,
            expectedByteCount: videoBytes.count
        )
        XCTAssertEqual(
            retainedSealed,
            videoBytes,
            "the old representation must remain available until the state CAS succeeds"
        )

        let proposedLease = await cache.protectedOriginalLease(
            forStorageKey: storageKey,
            userID: userID,
            expectedByteCount: videoBytes.count
        )
        let lease = try XCTUnwrap(proposedLease)
        await cache.removeEncryptedBlobRepresentation(
            forStorageKey: storageKey,
            userID: userID
        )
        let removedSealed = await cache.encryptedBlobData(
            forStorageKey: storageKey,
            userID: userID,
            expectedByteCount: videoBytes.count
        )
        XCTAssertNil(removedSealed)
        let retainedProtected = await cache.protectedOriginalURL(
            forStorageKey: storageKey,
            userID: userID,
            expectedByteCount: videoBytes.count
        )
        XCTAssertEqual(
            retainedProtected,
            lease.fileURL
        )
        await cache.releaseProtectedOriginalLease(lease)
    }

    func testLegacyInlineVideoPromotesToProtectedLeaseBeforePlayback() async throws {
        let storageKey = UUID().uuidString.lowercased()
        let videoBytes = Data(repeating: 0x3c, count: 8 * 1_024 * 1_024)

        let proposedLease = try await cache.promoteInlineDataToProtectedOriginal(
            videoBytes,
            forStorageKey: storageKey,
            userID: userID,
            mediaType: "video/mp4",
            expectedByteCount: videoBytes.count
        )
        let lease = try XCTUnwrap(proposedLease)
        XCTAssertEqual(lease.fileURL.pathExtension, "mp4")
        XCTAssertEqual(try Data(contentsOf: lease.fileURL), videoBytes)
        let sealedAfterPromotion = await cache.encryptedBlobData(
            forStorageKey: storageKey,
            userID: userID,
            expectedByteCount: videoBytes.count
        )
        XCTAssertNil(
            sealedAfterPromotion,
            "inline promotion must not create a second whole-file encrypted-blob allocation"
        )

        let proposedRetryLease = try await cache.promoteInlineDataToProtectedOriginal(
            videoBytes,
            forStorageKey: storageKey,
            userID: userID,
            mediaType: "video/mp4",
            expectedByteCount: videoBytes.count
        )
        let retryLease = try XCTUnwrap(proposedRetryLease)
        XCTAssertEqual(retryLease.fileURL, lease.fileURL)
        await cache.releaseProtectedOriginalLease(retryLease)
        await cache.releaseProtectedOriginalLease(lease)
    }

    func testLegacyInlineVideoPromotionRejectsSizeAndRepresentationConflicts() async throws {
        let storageKey = UUID().uuidString.lowercased()
        let videoBytes = Data(repeating: 0x5d, count: 4_096)

        let wrongSize = try await cache.promoteInlineDataToProtectedOriginal(
            videoBytes,
            forStorageKey: storageKey,
            userID: userID,
            mediaType: "video/mp4",
            expectedByteCount: videoBytes.count + 1
        )
        XCTAssertNil(wrongSize)
        let missingProtected = await cache.protectedOriginalURL(
            forStorageKey: storageKey,
            userID: userID,
            expectedByteCount: videoBytes.count
        )
        XCTAssertNil(missingProtected)

        let sealedInsertion = await cache.insertIfAbsent(
            videoBytes,
            forStorageKey: storageKey,
            userID: userID
        )
        XCTAssertEqual(sealedInsertion, .stored)
        do {
            _ = try await cache.promoteInlineDataToProtectedOriginal(
                videoBytes,
                forStorageKey: storageKey,
                userID: userID,
                mediaType: "video/mp4",
                expectedByteCount: videoBytes.count
            )
            XCTFail("an unrelated sealed representation must fail closed")
        } catch {
            let retainedSealed = await cache.encryptedBlobData(
                forStorageKey: storageKey,
                userID: userID,
                expectedByteCount: videoBytes.count
            )
            XCTAssertEqual(retainedSealed, videoBytes)
        }
    }

    func testLegacyVideoPromotionRejectsWrongSizeWithoutRemovingSealedSource() async throws {
        let storageKey = UUID().uuidString.lowercased()
        let videoBytes = Data(repeating: 0x4b, count: 4_096)
        let insertion = await cache.insertIfAbsent(
            videoBytes,
            forStorageKey: storageKey,
            userID: userID
        )
        XCTAssertEqual(insertion, .stored)

        do {
            _ = try await cache.promoteEncryptedBlobToProtectedOriginal(
                forStorageKey: storageKey,
                userID: userID,
                mediaType: "video/mp4",
                expectedByteCount: videoBytes.count + 1
            )
            XCTFail("a mismatched authenticated size must not publish a playback file")
        } catch {
            // Expected: the caller can continue to recover from the untouched sealed source.
        }

        let protectedURL = await cache.protectedOriginalURL(
            forStorageKey: storageKey,
            userID: userID,
            expectedByteCount: videoBytes.count
        )
        XCTAssertNil(protectedURL)
        let sealed = await cache.encryptedBlobData(
            forStorageKey: storageKey,
            userID: userID,
            expectedByteCount: videoBytes.count
        )
        XCTAssertEqual(sealed, videoBytes)
    }

    func testPreprocessingProbeNeverMaterializesASealedCollision() async throws {
        let missingKey = UUID().uuidString.lowercased()
        let missing = await cache.probeProtectedOriginal(
            forStorageKey: missingKey,
            userID: userID
        )
        XCTAssertEqual(missing, .absent)

        let sealedKey = UUID().uuidString.lowercased()
        let sealed = Data(repeating: 0x61, count: 2 * 1_024 * 1_024)
        let sealedInsertion = await cache.insertIfAbsent(
            sealed,
            forStorageKey: sealedKey,
            userID: userID
        )
        XCTAssertEqual(sealedInsertion, .stored)
        let sealedProbe = await cache.probeProtectedOriginal(
            forStorageKey: sealedKey,
            userID: userID
        )
        XCTAssertEqual(sealedProbe, .occupiedInvalid)

        let protectedKey = UUID().uuidString.lowercased()
        let protectedBytes = Data(repeating: 0x62, count: 4_096)
        let sourceURL = temporaryDirectory.appendingPathComponent("preprocessed.jpg")
        try protectedBytes.write(to: sourceURL, options: .atomic)
        let protectedURL = try await cache.importProtectedOriginal(
            from: sourceURL,
            forStorageKey: protectedKey,
            userID: userID,
            mediaType: "image/jpeg",
            expectedByteCount: protectedBytes.count,
            moveSource: true
        )
        let protectedProbe = await cache.probeProtectedOriginal(
            forStorageKey: protectedKey,
            userID: userID
        )
        XCTAssertEqual(
            protectedProbe,
            .candidate(fileURL: protectedURL, byteSize: protectedBytes.count)
        )
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

    func testDuplicateSupportsEncryptedBlobAndProtectedFileRepresentations() async throws {
        let sealedSource = UUID().uuidString.lowercased()
        let sealedDestination = UUID().uuidString.lowercased()
        let sealedBytes = Data("small encrypted-state cache item".utf8)
        let sealedInsertion = await cache.insertIfAbsent(
            sealedBytes,
            forStorageKey: sealedSource,
            userID: userID
        )
        XCTAssertEqual(sealedInsertion, .stored)
        let sealedDuplication = await cache.duplicate(
            fromStorageKey: sealedSource,
            toStorageKey: sealedDestination,
            userID: userID
        )
        XCTAssertEqual(sealedDuplication, .stored)
        let duplicatedSealed = await cache.data(
            forStorageKey: sealedDestination,
            userID: userID
        )
        XCTAssertEqual(duplicatedSealed, sealedBytes)

        let fileSource = UUID().uuidString.lowercased()
        let fileDestination = UUID().uuidString.lowercased()
        let fileBytes = Data(repeating: 0x7a, count: 4_096)
        let sourceURL = temporaryDirectory.appendingPathComponent("protected-source.bin")
        try fileBytes.write(to: sourceURL, options: .atomic)
        _ = try await cache.importProtectedOriginal(
            from: sourceURL,
            forStorageKey: fileSource,
            userID: userID,
            mediaType: "application/octet-stream",
            expectedByteCount: fileBytes.count,
            moveSource: false
        )
        let fileDuplication = await cache.duplicate(
            fromStorageKey: fileSource,
            toStorageKey: fileDestination,
            userID: userID
        )
        XCTAssertEqual(fileDuplication, .stored)
        let duplicatedFileURL = await cache.protectedOriginalURL(
            forStorageKey: fileDestination,
            userID: userID,
            expectedByteCount: fileBytes.count
        )
        XCTAssertNotNil(duplicatedFileURL)
        let duplicatedFileBytes = try duplicatedFileURL.map { try Data(contentsOf: $0) }
        XCTAssertEqual(duplicatedFileBytes, fileBytes)
    }

    func testSharedInboxStyleImportRequiresIndependentCopyOnWriteClone() async throws {
        let storageKey = UUID().uuidString.lowercased()
        let sourceURL = temporaryDirectory.appendingPathComponent("shared-inbox-source.bin")
        let bytes = Data(repeating: 0x6b, count: 4 * 1_024 * 1_024)
        try bytes.write(to: sourceURL, options: .atomic)

        let importedURL = try await cache.importProtectedOriginal(
            from: sourceURL,
            forStorageKey: storageKey,
            userID: userID,
            mediaType: "application/octet-stream",
            expectedByteCount: bytes.count,
            moveSource: false,
            requiresConstantTimeClone: true
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        try FileManager.default.removeItem(at: sourceURL)
        XCTAssertEqual(try Data(contentsOf: importedURL), bytes)
    }

    func testOrphanSweepKeepsReferencedAndRecentMedia() async throws {
        let retainedKey = UUID().uuidString.lowercased()
        let orphanKey = UUID().uuidString.lowercased()
        let recentKey = UUID().uuidString.lowercased()
        for key in [retainedKey, orphanKey, recentKey] {
            let insertion = await cache.insertIfAbsent(
                Data("bytes-\(key)".utf8),
                forStorageKey: key,
                userID: userID
            )
            XCTAssertEqual(insertion, .stored)
        }
        let accountID = UUID(uuidString: userID)!.uuidString.lowercased()
        let oldDate = Date(timeIntervalSinceNow: -48 * 60 * 60)
        for key in [retainedKey, orphanKey] {
            let url = temporaryDirectory
                .appendingPathComponent(accountID, isDirectory: true)
                .appendingPathComponent("\(key).sealed")
            try FileManager.default.setAttributes(
                [.modificationDate: oldDate],
                ofItemAtPath: url.path
            )
        }

        let removed = await cache.removeUnreferenced(
            retainingStorageKeys: [retainedKey],
            forUserID: userID,
            modifiedBefore: Date(timeIntervalSinceNow: -24 * 60 * 60),
            maximumRemovals: 64
        )

        XCTAssertEqual(removed, 1)
        let retained = await cache.data(forStorageKey: retainedKey, userID: userID)
        let orphan = await cache.data(forStorageKey: orphanKey, userID: userID)
        let recent = await cache.data(forStorageKey: recentKey, userID: userID)
        XCTAssertNotNil(retained)
        XCTAssertNil(orphan)
        XCTAssertNotNil(recent)
    }

    func testRestartVerifiesCiphertextSpoolOnceThenReusesFingerprintLease() async throws {
        let mediaID = UUID().uuidString.lowercased()
        let source = temporaryDirectory.appendingPathComponent("source.bin")
        let plaintext = Data(repeating: 0x5a, count: 2 * 1_024 * 1_024)
        try plaintext.write(to: source, options: .atomic)
        _ = try await cache.importProtectedOriginal(
            from: source,
            forStorageKey: mediaID,
            userID: userID,
            mediaType: "application/octet-stream",
            expectedByteCount: plaintext.count,
            moveSource: false
        )
        let keyMaterial = Data(repeating: 0x33, count: SecureMediaAttachmentCipher.keyMaterialBytes)
        let created = try await cache.prepareCiphertextSpool(
            forStorageKey: mediaID,
            userID: userID,
            expectedPlaintextByteCount: plaintext.count,
            keyMaterial: keyMaterial,
            attachmentID: mediaID
        )
        let spool = try XCTUnwrap(created)

        // A fresh actor simulates process restart: the first open hashes the complete spool,
        // while repeated transport retries validate only its cheap path/size/mtime fingerprint.
        let restarted = SecureMediaFileCache(
            directoryURL: temporaryDirectory,
            keyAccount: "kit-pay-media-cache-key-tests-restarted-\(UUID().uuidString)"
        )
        let first = await restarted.ciphertextSpool(
            forStorageKey: mediaID,
            userID: userID,
            expectedByteCount: spool.byteSize,
            expectedSHA256: spool.sha256Hex
        )
        let second = await restarted.ciphertextSpool(
            forStorageKey: mediaID,
            userID: userID,
            expectedByteCount: spool.byteSize,
            expectedSHA256: spool.sha256Hex
        )

        XCTAssertNotNil(first)
        XCTAssertEqual(first, second)
        let verificationCount = await restarted.ciphertextSpoolDigestVerificationCount(
            forStorageKey: mediaID,
            userID: userID
        )
        XCTAssertEqual(verificationCount, 1)
    }

    func testReceivedCacheEvictsLRUWithoutEverSelectingSenderOriginals() async throws {
        let senderKey = UUID().uuidString.lowercased()
        let oldestReceivedKey = UUID().uuidString.lowercased()
        let newestReceivedKey = UUID().uuidString.lowercased()
        let bytes = 40
        try await importOriginal(key: senderKey, byte: 0x11, count: bytes)
        try await importOriginal(key: oldestReceivedKey, byte: 0x22, count: bytes)
        try await importOriginal(key: newestReceivedKey, byte: 0x33, count: bytes)

        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = old.addingTimeInterval(60)
        try setOriginalModificationDate(old, storageKey: senderKey)
        try setOriginalModificationDate(old, storageKey: oldestReceivedKey)
        try setOriginalModificationDate(newer, storageKey: newestReceivedKey)
        let messageID = UUID()
        let conversationID = UUID().uuidString.lowercased()
        func candidate(
            _ key: String,
            ownership: SecureMediaCacheOwnership,
            accessed: Date
        ) -> SecureMediaCacheEvictionCandidate {
            SecureMediaCacheEvictionCandidate(
                messageID: messageID,
                conversationID: conversationID,
                attachmentID: key,
                storageKey: key,
                expectedPlaintextByteCount: bytes,
                storageKind: .protectedFile,
                ownership: ownership,
                lastAccessedAt: accessed
            )
        }

        let proposed = await cache.reserveReceivedCacheEviction(
            candidates: [
                candidate(senderKey, ownership: .senderOriginal, accessed: old),
                candidate(oldestReceivedKey, ownership: .receivedCache, accessed: old),
                candidate(newestReceivedKey, ownership: .receivedCache, accessed: newer),
            ],
            forUserID: userID,
            maximumBytes: 60,
            targetBytes: 40,
            recentAccessProtection: 0,
            now: newer.addingTimeInterval(60)
        )
        let reservation = try XCTUnwrap(proposed)

        XCTAssertEqual(reservation.candidates.map(\.storageKey), [oldestReceivedKey])
        let removed = await cache.commitEviction(reservation, forUserID: userID)
        XCTAssertEqual(removed, Set([oldestReceivedKey]))
        let evictedURL = await cache.protectedOriginalURL(
            forStorageKey: oldestReceivedKey,
            userID: userID,
            expectedByteCount: bytes
        )
        let senderURL = await cache.protectedOriginalURL(
            forStorageKey: senderKey,
            userID: userID,
            expectedByteCount: bytes
        )
        let newestURL = await cache.protectedOriginalURL(
            forStorageKey: newestReceivedKey,
            userID: userID,
            expectedByteCount: bytes
        )
        XCTAssertNil(evictedURL)
        XCTAssertNotNil(senderURL)
        XCTAssertNotNil(newestURL)
    }

    func testActiveReceivedFileLeaseDefersEvictionUntilReleased() async throws {
        let oldestKey = UUID().uuidString.lowercased()
        let fallbackKey = UUID().uuidString.lowercased()
        let bytes = 40
        try await importOriginal(key: oldestKey, byte: 0x44, count: bytes)
        try await importOriginal(key: fallbackKey, byte: 0x55, count: bytes)
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        try setOriginalModificationDate(old, storageKey: oldestKey)
        try setOriginalModificationDate(old.addingTimeInterval(60), storageKey: fallbackKey)
        let leaseNow = old.addingTimeInterval(120)
        let proposedLease = await cache.protectedOriginalLease(
            forStorageKey: oldestKey,
            userID: userID,
            expectedByteCount: bytes,
            now: leaseNow
        )
        let lease = try XCTUnwrap(proposedLease)
        let messageID = UUID()
        let conversationID = UUID().uuidString.lowercased()
        let candidates = [oldestKey, fallbackKey].enumerated().map { index, key in
            SecureMediaCacheEvictionCandidate(
                messageID: messageID,
                conversationID: conversationID,
                attachmentID: key,
                storageKey: key,
                expectedPlaintextByteCount: bytes,
                storageKind: .protectedFile,
                ownership: .receivedCache,
                lastAccessedAt: old.addingTimeInterval(Double(index * 60))
            )
        }
        let proposedFirst = await cache.reserveReceivedCacheEviction(
            candidates: candidates,
            forUserID: userID,
            maximumBytes: 60,
            targetBytes: 40,
            recentAccessProtection: 0,
            now: leaseNow.addingTimeInterval(1)
        )
        let first = try XCTUnwrap(proposedFirst)
        XCTAssertEqual(first.candidates.map(\.storageKey), [fallbackKey])
        _ = await cache.commitEviction(first, forUserID: userID)
        let protectedURL = await cache.protectedOriginalURL(
            forStorageKey: oldestKey,
            userID: userID,
            expectedByteCount: bytes
        )
        XCTAssertNotNil(protectedURL)

        await cache.releaseProtectedOriginalLease(lease)
        let proposedSecond = await cache.reserveReceivedCacheEviction(
            candidates: [candidates[0]],
            forUserID: userID,
            maximumBytes: 20,
            targetBytes: 0,
            recentAccessProtection: 0,
            now: Date().addingTimeInterval(1)
        )
        let second = try XCTUnwrap(proposedSecond)
        XCTAssertEqual(second.candidates.map(\.storageKey), [oldestKey])
        let removed = await cache.commitEviction(second, forUserID: userID)
        XCTAssertEqual(removed, Set([oldestKey]))
    }

    private func importOriginal(key: String, byte: UInt8, count: Int) async throws {
        let source = temporaryDirectory.appendingPathComponent("source-\(key).bin")
        try Data(repeating: byte, count: count).write(to: source, options: .atomic)
        _ = try await cache.importProtectedOriginal(
            from: source,
            forStorageKey: key,
            userID: userID,
            mediaType: "application/octet-stream",
            expectedByteCount: count,
            moveSource: false
        )
    }

    private func setOriginalModificationDate(_ date: Date, storageKey: String) throws {
        let accountID = UUID(uuidString: userID)!.uuidString.lowercased()
        let url = temporaryDirectory
            .appendingPathComponent(accountID, isDirectory: true)
            .appendingPathComponent("\(storageKey).original.bin", isDirectory: false)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func makeLegacyInlineReceivedMessage(
        mediaType: String,
        bytes: Data
    ) throws -> (
        message: LocalMessage,
        descriptor: KitMediaMessageDescriptor,
        bytes: Data
    ) {
        let descriptor = try KitMediaMessageDescriptor(
            attachmentID: UUID().uuidString.lowercased(),
            storageKey: UUID().uuidString.lowercased(),
            mediaType: mediaType,
            ciphertextByteSize: Int64(bytes.count) + 64,
            ciphertextSHA256: String(repeating: "ab", count: 32),
            keyMaterial: Data(
                repeating: 0x75,
                count: SecureMediaAttachmentCipher.keyMaterialBytes
            ),
            plaintextByteSize: bytes.count,
            caption: "Legacy received attachment"
        )
        let message = LocalMessage(
            id: UUID(),
            conversationId: UUID().uuidString.lowercased(),
            senderId: UUID().uuidString.lowercased(),
            body: descriptor.encoded,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            sentAt: Date(timeIntervalSince1970: 1_800_000_000),
            state: .received,
            failureReason: nil,
            isOutgoing: false,
            attachmentData: bytes
        )
        return (message, descriptor, bytes)
    }

    private func legacyInlineReceivedState(messages: [LocalMessage]) -> PersistedState {
        var state = PersistedState.empty
        state.profile = UserProfile(
            id: userID,
            name: "Media Recipient",
            email: "media-recipient@example.test",
            phone: "+256700000000",
            tag: "media_recipient",
            kycStatus: "verified",
            paymentPinSet: true,
            mfaEnabled: true,
            profileSetupRequired: false
        )
        state.communicationOwnerUserID = userID
        state.messages = messages
        return state
    }
}
