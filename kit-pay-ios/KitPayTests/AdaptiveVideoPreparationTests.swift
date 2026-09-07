import Foundation
import XCTest
@testable import KitPay

final class AdaptiveVideoPreparationTests: XCTestCase {
    private let sourceKey = "11111111-1111-4111-8111-111111111111"
    private let outputKey = "22222222-2222-4222-8222-222222222222"
    private let largeSize = 20 * 1_024 * 1_024

    private func metadata(
        width: Double = 1_920, height: Double = 1_080, rate: Double = 6_000_000,
        duration: TimeInterval = 30, end: TimeInterval? = nil, hasAudio: Bool = true
    ) -> AdaptiveVideoPreparationPolicy.Metadata {
        .init(width: width, height: height, estimatedBitsPerSecond: rate,
              duration: duration, videoStart: 0, videoEnd: end ?? duration, hasAudio: hasAudio)
    }

    private func source(
        size: Int? = nil, duration: TimeInterval? = 30, mediaType: String = "video/quicktime"
    ) -> LocalMediaOriginalSource {
        LocalMediaOriginalSource(storageKey: sourceKey, mediaType: mediaType,
                                 fileSize: size ?? largeSize, duration: duration)
    }

    private func job(
        source: LocalMediaOriginalSource? = nil, hasAudio: Bool? = true,
        output: String? = nil
    ) -> LocalMediaPreprocessingJob {
        let original = source ?? self.source()
        return LocalMediaPreprocessingJob(kind: .video1080p, sources: [original],
                                  outputStorageKey: output ?? outputKey, outputMediaType: original.mediaType,
                                  videoSourceHasAudio: hasAudio, videoSourceWidth: 3_840,
                                  videoSourceHeight: 2_160)
    }

    func testSmallHighResolutionClipDoesNotNeedAnotherExport() {
        let highResolution = metadata(width: 3_840, height: 2_160, rate: 30_000_000)
        XCTAssertFalse(AdaptiveVideoPreparationPolicy.shouldOptimize(
            byteCount: 12 * 1_024 * 1_024, metadata: highResolution))
        XCTAssertTrue(AdaptiveVideoPreparationPolicy.shouldOptimize(
            byteCount: 12 * 1_024 * 1_024 + 1, metadata: highResolution))
    }

    func testLargeEfficientVideoAndOriginalFileIntentRemainUntouched() {
        XCTAssertFalse(AdaptiveVideoPreparationPolicy.shouldOptimize(byteCount: largeSize, metadata: metadata()))
        XCTAssertFalse(AdaptiveVideoPreparationPolicy.shouldOptimize(
            byteCount: largeSize, metadata: metadata(rate: 8_000_000)))
        XCTAssertFalse(AdaptiveVideoPreparationPolicy.shouldOptimize(
            byteCount: largeSize, metadata: metadata(width: 3_840, height: 2_160), preserveOriginal: true))
        XCTAssertTrue(AdaptiveVideoPreparationPolicy.shouldOptimize(
            byteCount: largeSize, metadata: metadata(rate: 8_000_001)))
    }

    func testPortraitAndSquareDimensionsUseBothEdges() {
        XCTAssertFalse(AdaptiveVideoPreparationPolicy.shouldOptimize(
            byteCount: largeSize, metadata: metadata(width: 1_080, height: 1_920)))
        XCTAssertFalse(AdaptiveVideoPreparationPolicy.shouldOptimize(
            byteCount: largeSize, metadata: metadata(width: 1_080, height: 1_080)))
        XCTAssertTrue(AdaptiveVideoPreparationPolicy.shouldOptimize(
            byteCount: largeSize, metadata: metadata(width: 1_440, height: 1_440)))
        XCTAssertTrue(AdaptiveVideoPreparationPolicy.shouldOptimize(
            byteCount: largeSize, metadata: metadata(width: 2_160, height: 3_840)))
    }

    func testInvalidOrOversizedSourceIsNeverQueuedForOptimization() {
        XCTAssertFalse(AdaptiveVideoPreparationPolicy.shouldOptimize(
            byteCount: largeSize, metadata: metadata(width: .infinity)))
        XCTAssertFalse(AdaptiveVideoPreparationPolicy.shouldOptimize(
            byteCount: largeSize, metadata: metadata(rate: .nan)))
        XCTAssertFalse(AdaptiveVideoPreparationPolicy.shouldOptimize(
            byteCount: largeSize, metadata: metadata(duration: 0)))
        XCTAssertFalse(AdaptiveVideoPreparationPolicy.shouldOptimize(
            byteCount: 201 * 1_024 * 1_024, metadata: metadata(width: 3_840, height: 2_160)))
    }

    func testOutputRejectsMissingAudioOrMissingTail() {
        XCTAssertTrue(AdaptiveVideoPreparationPolicy.outputMatches(metadata(), sourceDuration: 30, sourceHasAudio: true))
        XCTAssertFalse(AdaptiveVideoPreparationPolicy.outputMatches(
            metadata(hasAudio: false), sourceDuration: 30, sourceHasAudio: true))
        XCTAssertFalse(AdaptiveVideoPreparationPolicy.outputMatches(
            metadata(duration: 29), sourceDuration: 30, sourceHasAudio: true))
        XCTAssertFalse(AdaptiveVideoPreparationPolicy.outputMatches(
            metadata(end: 28), sourceDuration: 30, sourceHasAudio: true))
        XCTAssertFalse(AdaptiveVideoPreparationPolicy.outputMatches(
            metadata(width: 3_840, height: 2_160), sourceDuration: 30, sourceHasAudio: true))
    }

    func testSilentVideoStaysSilentAndLongClipsGetNoPercentageTailAllowance() {
        XCTAssertTrue(AdaptiveVideoPreparationPolicy.outputMatches(
            metadata(hasAudio: false), sourceDuration: 30, sourceHasAudio: false))
        XCTAssertFalse(AdaptiveVideoPreparationPolicy.outputMatches(
            metadata(), sourceDuration: 30, sourceHasAudio: false))
        XCTAssertTrue(AdaptiveVideoPreparationPolicy.outputMatches(
            metadata(duration: 29.95), sourceDuration: 30, sourceHasAudio: true))
        XCTAssertFalse(AdaptiveVideoPreparationPolicy.outputMatches(
            metadata(duration: 1_795), sourceDuration: 1_800, sourceHasAudio: true))
    }

    func testOriginalFallbackKeepsFullSourceGeometryDurationAndAudio() {
        let original = metadata(width: 3_840, height: 2_160)
        XCTAssertTrue(AdaptiveVideoPreparationPolicy.sourceCopyMatches(
            original, sourceDuration: 30, sourceHasAudio: true, sourceWidth: 3_840, sourceHeight: 2_160))
        XCTAssertFalse(AdaptiveVideoPreparationPolicy.sourceCopyMatches(
            metadata(), sourceDuration: 30, sourceHasAudio: true, sourceWidth: 3_840, sourceHeight: 2_160))
        XCTAssertFalse(AdaptiveVideoPreparationPolicy.sourceCopyMatches(
            original, sourceDuration: 32, sourceHasAudio: true, sourceWidth: 3_840, sourceHeight: 2_160))
        XCTAssertFalse(AdaptiveVideoPreparationPolicy.sourceCopyMatches(
            original, sourceDuration: 30, sourceHasAudio: false, sourceWidth: 3_840, sourceHeight: 2_160))
    }

    func testDurableVideoJobRequiresSourceDurationAudioAndSeparateOutput() {
        XCTAssertTrue(job().isStructurallyValid)
        XCTAssertTrue(job(hasAudio: false).isStructurallyValid)
        XCTAssertFalse(job(hasAudio: nil).isStructurallyValid)
        XCTAssertFalse(job(source: source(duration: nil)).isStructurallyValid)
        XCTAssertFalse(job(source: source(size: 12 * 1_024 * 1_024)).isStructurallyValid)
        XCTAssertFalse(job(source: source(mediaType: "audio/mp4")).isStructurallyValid)
        XCTAssertFalse(job(output: sourceKey).isStructurallyValid)
    }

    func testJobRoundTripPreservesIdentityAndLegacyImageJobsStillDecode() throws {
        let expected = job()
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(LocalMediaPreprocessingJob.self,
                                         from: JSONEncoder().encode(expected)), expected)
        let image = LocalMediaPreprocessingJob(
            kind: .imageJPEG, sources: [source(size: 1_024, duration: nil, mediaType: "image/heic")],
            outputStorageKey: outputKey, outputMediaType: "image/jpeg"
        )
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(image)) as? [String: Any])
        object.removeValue(forKey: "videoSourceHasAudio")
        let decoded = try decoder.decode(LocalMediaPreprocessingJob.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded, image)
        XCTAssertTrue(decoded.isStructurallyValid)
    }

    func testDraftRestoresOriginalAndReservedOutputWithoutRelabelingTheSource() throws {
        let original = ConversationDraftMediaAttachment(
            id: UUID(uuidString: sourceKey)!, storageKind: .protectedFile,
            mediaType: "video/quicktime", originalMediaType: "video/quicktime", byteCount: largeSize,
            displayName: "Video", duration: 30, acceptedAt: Date(timeIntervalSince1970: 1_800_000_000),
            clientMessageID: nil, preprocessingOutputStorageKey: outputKey
        )
        XCTAssertTrue(original.isStructurallyValid)
        let restored = try JSONDecoder().decode(ConversationDraftMediaAttachment.self,
                                               from: JSONEncoder().encode(original))
        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.originalMediaType, "video/quicktime")
        XCTAssertEqual(restored.preprocessingOutputStorageKey, outputKey)
        XCTAssertNotEqual(restored.storageKey, restored.preprocessingOutputStorageKey)
    }

    func testVideoOutputRecoveryRetainsAudioContractAndRejectsStaleJob() throws {
        let job = job()
        let messageID = UUID()
        let conversationID = UUID().uuidString.lowercased()
        let record = try XCTUnwrap(LocalMediaRecordPolicy.queuedOutgoing(
            id: sourceKey, messageID: messageID, conversationID: conversationID,
            mediaType: "video/quicktime", fileSize: largeSize, localStorageKey: sourceKey,
            storesInline: false, now: Date(), localStorageKind: .protectedFile,
            originalSources: job.sources, preprocessingJob: job
        ))
        var message = LocalMessage(
            id: messageID, conversationId: conversationID, senderId: UUID().uuidString.lowercased(),
            body: "Video", createdAt: record.createdAt, sentAt: nil, state: .queued,
            failureReason: nil, isOutgoing: true,
            pendingAttachment: LocalPendingAttachment(mediaType: "video/quicktime", caption: nil,
                                                       localStorageKey: sourceKey, byteCount: largeSize),
            localMediaRecords: [record]
        )
        let newOutput = UUID().uuidString.lowercased()
        XCTAssertTrue(LocalMediaRecordPolicy.rekeyPreprocessingOutput(
            &message, attachmentID: sourceKey, expectedJob: job, newOutputStorageKey: newOutput))
        let replacement = try XCTUnwrap(message.localMediaRecords?.first?.preprocessingJob)
        XCTAssertTrue(replacement.isStructurallyValid)
        XCTAssertEqual(replacement.videoSourceHasAudio, true)
        XCTAssertEqual(replacement.videoSourceWidth, 3_840)
        XCTAssertEqual(replacement.videoSourceHeight, 2_160)
        XCTAssertEqual(replacement.sources, job.sources)
        XCTAssertEqual(replacement.outputStorageKey, newOutput)
        XCTAssertTrue(message.localMediaStorageKeys.contains(sourceKey))
        XCTAssertFalse(message.localMediaStorageKeys.contains(outputKey))
        XCTAssertFalse(LocalMediaRecordPolicy.rekeyPreprocessingOutput(
            &message, attachmentID: sourceKey, expectedJob: job,
            newOutputStorageKey: UUID().uuidString.lowercased()))
    }

    func testPublishedOutputRejectsAnMP4HeaderWithoutPlayableVideo() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("invalid-video-\(UUID()).mp4")
        try Data([0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70, 0, 0, 0, 0]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let valid = await AdaptiveVideoPreparation.isValidPublishedOutput(at: url, for: job())
        XCTAssertFalse(valid)
    }
}
