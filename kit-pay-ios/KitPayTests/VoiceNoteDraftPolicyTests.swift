import XCTest
@testable import KitPay

/// The complete transition table for a voice-note draft. A draft is plaintext audio that
/// exists only on this device until Send, so the two properties every row here defends
/// are: nothing leaves the device except through an explicit Send, and nothing is thrown
/// away except through an explicit discard.
final class VoiceNoteDraftPolicyTests: XCTestCase {
    private let allPhases: [VoiceNoteDraftPhase] = [.idle, .recording, .paused, .previewing]

    func testAFreshRecordingBeginsOnlyWhenNoDraftExists() {
        XCTAssertEqual(VoiceNoteDraftPolicy.startRecording(.idle), .recording)
        XCTAssertNil(VoiceNoteDraftPolicy.startRecording(.recording))
        XCTAssertNil(VoiceNoteDraftPolicy.startRecording(.paused))
        XCTAssertNil(VoiceNoteDraftPolicy.startRecording(.previewing))
    }

    func testPausingIsOnlyMeaningfulWhileTheMicrophoneIsLive() {
        XCTAssertEqual(VoiceNoteDraftPolicy.pause(.recording), .paused)
        XCTAssertNil(VoiceNoteDraftPolicy.pause(.idle))
        XCTAssertNil(VoiceNoteDraftPolicy.pause(.paused))
        XCTAssertNil(VoiceNoteDraftPolicy.pause(.previewing))
    }

    func testAPausedDraftResumesAndHearingItFirstDoesNotCostTheResume() {
        XCTAssertEqual(VoiceNoteDraftPolicy.resume(.paused, recorded: 5), .recording)
        // Listen, decide to keep talking: the flow this whole feature exists for.
        XCTAssertEqual(VoiceNoteDraftPolicy.resume(.previewing, recorded: 5), .recording)
        XCTAssertNil(VoiceNoteDraftPolicy.resume(.idle, recorded: 5))
        XCTAssertNil(VoiceNoteDraftPolicy.resume(.recording, recorded: 5))
    }

    func testADraftAtTheMaximumLengthNeverResumes() {
        let max = VoiceNoteDraftPolicy.maximumDuration

        XCTAssertNil(VoiceNoteDraftPolicy.resume(.paused, recorded: max))
        XCTAssertNil(VoiceNoteDraftPolicy.resume(.paused, recorded: max + 1))
        XCTAssertEqual(VoiceNoteDraftPolicy.resume(.paused, recorded: max - 1), .recording)
    }

    func testListeningBackRequiresAPausedDraftWithSomethingToPlay() {
        XCTAssertEqual(
            VoiceNoteDraftPolicy.beginPreview(.paused, hasSegments: true),
            .previewing
        )
        XCTAssertNil(VoiceNoteDraftPolicy.beginPreview(.paused, hasSegments: false))
        XCTAssertNil(VoiceNoteDraftPolicy.beginPreview(.recording, hasSegments: true))
        XCTAssertNil(VoiceNoteDraftPolicy.beginPreview(.idle, hasSegments: true))
        XCTAssertNil(VoiceNoteDraftPolicy.beginPreview(.previewing, hasSegments: true))
    }

    func testAPreviewEndsBackOnThePausedDraftAndNowhereElse() {
        XCTAssertEqual(VoiceNoteDraftPolicy.endPreview(.previewing), .paused)
        XCTAssertNil(VoiceNoteDraftPolicy.endPreview(.idle))
        XCTAssertNil(VoiceNoteDraftPolicy.endPreview(.recording))
        XCTAssertNil(VoiceNoteDraftPolicy.endPreview(.paused))
    }

    func testSendTakesAnyDraftThatHasReachedTheOneSecondMinimum() {
        let min = VoiceNoteDraftPolicy.minimumDuration

        // From live recording, from paused, and from mid-listen alike.
        XCTAssertTrue(VoiceNoteDraftPolicy.sendable(.recording, recorded: min))
        XCTAssertTrue(VoiceNoteDraftPolicy.sendable(.paused, recorded: min))
        XCTAssertTrue(VoiceNoteDraftPolicy.sendable(.previewing, recorded: min))

        XCTAssertFalse(VoiceNoteDraftPolicy.sendable(.recording, recorded: min - 0.01))
        // No draft, nothing to send, whatever a stale counter claims.
        XCTAssertFalse(VoiceNoteDraftPolicy.sendable(.idle, recorded: min))
    }

    func testTheCapPausesTheDraftInsteadOfSendingIt() {
        let max = VoiceNoteDraftPolicy.maximumDuration

        XCTAssertFalse(VoiceNoteDraftPolicy.capacityReached(max - 0.01))
        XCTAssertTrue(VoiceNoteDraftPolicy.capacityReached(max))
        XCTAssertTrue(VoiceNoteDraftPolicy.capacityReached(max + 1))
        // The capped draft stays a draft: still listenable, still explicitly the user's
        // to send or discard. There is no transition from the cap to "sent".
        XCTAssertNil(VoiceNoteDraftPolicy.resume(.paused, recorded: max))
        XCTAssertTrue(VoiceNoteDraftPolicy.sendable(.paused, recorded: max))
    }

    func testAnOrdinaryInterruptionPausesADraftAndNeverDiscardsOne() {
        // Navigation, backgrounding, a read-only flip: the microphone stops, the audio stays.
        XCTAssertEqual(VoiceNoteDraftPolicy.phaseAfterInterruption(.recording), .paused)
        XCTAssertEqual(VoiceNoteDraftPolicy.phaseAfterInterruption(.previewing), .paused)
        XCTAssertEqual(VoiceNoteDraftPolicy.phaseAfterInterruption(.paused), .paused)
        XCTAssertEqual(VoiceNoteDraftPolicy.phaseAfterInterruption(.idle), .idle)
    }

    func testFinalizedSingleSegmentSkipsVoiceAssembly() {
        let source = LocalMediaOriginalSource(
            storageKey: UUID().uuidString.lowercased(),
            mediaType: "audio/mp4",
            fileSize: 4_096,
            duration: 120
        )

        XCTAssertNil(VoiceNoteSendPreparationPolicy.preprocessingJob(
            for: [source],
            outputStorageKey: UUID().uuidString.lowercased()
        ))
    }

    func testPausedAndResumedVoiceNoteKeepsOrderedPassthroughAssembly() throws {
        let sources = [
            LocalMediaOriginalSource(
                storageKey: UUID().uuidString.lowercased(),
                mediaType: "audio/mp4",
                fileSize: 2_048,
                duration: 30
            ),
            LocalMediaOriginalSource(
                storageKey: UUID().uuidString.lowercased(),
                mediaType: "audio/mp4",
                fileSize: 3_072,
                duration: 45
            ),
        ]
        let outputStorageKey = UUID().uuidString.lowercased()

        let job = try XCTUnwrap(VoiceNoteSendPreparationPolicy.preprocessingJob(
            for: sources,
            outputStorageKey: outputStorageKey
        ))
        XCTAssertEqual(job.kind, .voiceAssembly)
        XCTAssertEqual(job.sources, sources)
        XCTAssertEqual(job.outputStorageKey, outputStorageKey)
        XCTAssertEqual(job.outputMediaType, "audio/mp4")
        XCTAssertTrue(job.isStructurallyValid)
    }

    func testEveryPhaseAcceptsExactlyTheTransitionsTheTablePromises() {
        // The exhaustive sweep: a phase added later without a decision fails here.
        XCTAssertEqual(
            allPhases.filter { VoiceNoteDraftPolicy.startRecording($0) != nil },
            [.idle]
        )
        XCTAssertEqual(
            allPhases.filter { VoiceNoteDraftPolicy.pause($0) != nil },
            [.recording]
        )
        XCTAssertEqual(
            allPhases.filter { VoiceNoteDraftPolicy.resume($0, recorded: 5) != nil },
            [.paused, .previewing]
        )
        XCTAssertEqual(
            allPhases.filter { VoiceNoteDraftPolicy.beginPreview($0, hasSegments: true) != nil },
            [.paused]
        )
        XCTAssertEqual(
            allPhases.filter { VoiceNoteDraftPolicy.endPreview($0) != nil },
            [.previewing]
        )
    }
}
