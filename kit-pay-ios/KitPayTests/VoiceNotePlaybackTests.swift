import XCTest
@testable import KitPay

/// What a finger on a voice note means, and when the floating bar is the thing that owns it.
final class VoiceNotePlaybackTests: XCTestCase {

    // MARK: Tap vs slide vs scroll

    func testStationaryTouchIsATap() {
        XCTAssertTrue(VoiceNoteSeekPolicy.isTap(translation: .zero))
        XCTAssertTrue(VoiceNoteSeekPolicy.isTap(translation: CGSize(width: 3, height: -4)))
        XCTAssertFalse(VoiceNoteSeekPolicy.isScrub(translation: CGSize(width: 3, height: -4)))
    }

    func testHorizontalSlidePastTheSlopIsAScrub() {
        let translation = CGSize(width: 40, height: 6)
        XCTAssertFalse(VoiceNoteSeekPolicy.isTap(translation: translation))
        XCTAssertTrue(VoiceNoteSeekPolicy.isScrub(translation: translation))
        XCTAssertTrue(
            VoiceNoteSeekPolicy.isScrub(translation: CGSize(width: -40, height: 6)),
            "Sliding back down the note is as much a scrub as sliding forward"
        )
    }

    /// The waveform's gesture runs alongside the thread's scroll view. A drag that is mostly
    /// vertical is the thread being scrolled past the note, and must not move playback.
    func testMostlyVerticalDragIsNotASeek() {
        let translation = CGSize(width: 12, height: 90)
        XCTAssertFalse(VoiceNoteSeekPolicy.isTap(translation: translation))
        XCTAssertFalse(VoiceNoteSeekPolicy.isScrub(translation: translation))
    }

    // MARK: Where a touch lands

    func testTapPositionIsTheFractionOfTheWaveformTouched() {
        let width = VoiceNoteSeekPolicy.waveformWidth
        XCTAssertEqual(VoiceNoteSeekPolicy.fraction(atX: 0, width: width), 0, accuracy: 0.0001)
        XCTAssertEqual(
            VoiceNoteSeekPolicy.fraction(atX: width / 2, width: width),
            0.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(VoiceNoteSeekPolicy.fraction(atX: width, width: width), 1, accuracy: 0.0001)
    }

    func testTapOutsideTheWaveformRestsAtTheNearestEnd() {
        let width = VoiceNoteSeekPolicy.waveformWidth
        XCTAssertEqual(VoiceNoteSeekPolicy.fraction(atX: -40, width: width), 0, accuracy: 0.0001)
        XCTAssertEqual(
            VoiceNoteSeekPolicy.fraction(atX: width + 40, width: width),
            1,
            accuracy: 0.0001
        )
    }

    func testUnmeasuredWaveformNeverDividesByZero() {
        XCTAssertEqual(VoiceNoteSeekPolicy.fraction(atX: 30, width: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(
            VoiceNoteSeekPolicy.scrubbedFraction(from: 0.4, translationWidth: 30, width: 0),
            0.4,
            accuracy: 0.0001
        )
    }

    // MARK: Scrubbing

    /// A slide moves the note relative to where the finger went down, so a half-played note nudged
    /// a quarter of the waveform forward lands three-quarters in — not at the quarter mark.
    func testSlideMovesRelativeToWhereTheFingerWentDown() {
        let width = VoiceNoteSeekPolicy.waveformWidth
        XCTAssertEqual(
            VoiceNoteSeekPolicy.scrubbedFraction(
                from: 0.5,
                translationWidth: width / 4,
                width: width
            ),
            0.75,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            VoiceNoteSeekPolicy.scrubbedFraction(
                from: 0.5,
                translationWidth: -width / 4,
                width: width
            ),
            0.25,
            accuracy: 0.0001
        )
    }

    func testSlidePastEitherEndRestsAtThatEnd() {
        let width = VoiceNoteSeekPolicy.waveformWidth
        XCTAssertEqual(
            VoiceNoteSeekPolicy.scrubbedFraction(from: 0.9, translationWidth: width, width: width),
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            VoiceNoteSeekPolicy.scrubbedFraction(from: 0.1, translationWidth: -width, width: width),
            0,
            accuracy: 0.0001
        )
    }

    func testNonFiniteFractionsClampPredictably() {
        XCTAssertEqual(VoiceNoteSeekPolicy.clamped(.nan), 0, accuracy: 0.0001)
        XCTAssertEqual(VoiceNoteSeekPolicy.clamped(.infinity), 1, accuracy: 0.0001)
        XCTAssertEqual(VoiceNoteSeekPolicy.clamped(-.infinity), 0, accuracy: 0.0001)
    }

    // MARK: Fraction ↔ time

    func testFractionAndTimeAgree() {
        XCTAssertEqual(
            VoiceNoteSeekPolicy.time(forFraction: 0.25, duration: 40),
            10,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            VoiceNoteSeekPolicy.fraction(forTime: 10, duration: 40),
            0.25,
            accuracy: 0.0001
        )
    }

    func testSkippingPastEitherEndOfTheNoteIsClamped() {
        XCTAssertEqual(VoiceNoteSeekPolicy.fraction(forTime: -15, duration: 40), 0, accuracy: 0.0001)
        XCTAssertEqual(VoiceNoteSeekPolicy.fraction(forTime: 90, duration: 40), 1, accuracy: 0.0001)
    }

    /// A note whose duration is not known yet must not turn a seek into a division by zero.
    func testUnknownDurationSeeksNowhere() {
        XCTAssertEqual(VoiceNoteSeekPolicy.time(forFraction: 0.5, duration: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(VoiceNoteSeekPolicy.fraction(forTime: 12, duration: 0), 0, accuracy: 0.0001)
    }

    // MARK: What the floating bar says

    func testGroupNoteNamesTheSpeakerOverTheGroup() {
        let context = VoiceNotePlaybackContext(
            conversationID: "c1",
            speaker: "Ama",
            conversationTitle: "Family"
        )
        XCTAssertEqual(context.title, "Ama")
        XCTAssertEqual(context.subtitle, "Family")
    }

    /// A one-to-one chat is titled after the person speaking, so repeating the name underneath
    /// would read as a stutter.
    func testDirectChatDoesNotRepeatTheSpeakersName() {
        let context = VoiceNotePlaybackContext(
            conversationID: "c1",
            speaker: "Ama",
            conversationTitle: "Ama"
        )
        XCTAssertEqual(context.title, "Ama")
        XCTAssertEqual(context.subtitle, "Voice note")
    }

    func testUnnamedContextStillReadsAsAVoiceNote() {
        let context = VoiceNotePlaybackContext(
            conversationID: "",
            speaker: "",
            conversationTitle: ""
        )
        XCTAssertEqual(context.title, "Voice note")
        XCTAssertEqual(context.subtitle, "Voice note")
    }

    func testChatContextResolvesTheSpeakerThroughTheThread() {
        let context = VoiceNoteChatContext(
            conversationID: "c1",
            conversationTitle: "Family",
            displayName: { $0 == "me" ? "You" : "Ama" }
        )
        XCTAssertEqual(context.playbackContext(senderUserID: "me").title, "You")
        XCTAssertEqual(context.playbackContext(senderUserID: "other").title, "Ama")
        XCTAssertEqual(context.playbackContext(senderUserID: "other").subtitle, "Family")
    }

    // MARK: When the bar is on screen

    func testBarStaysAwayWhileTheNotesOwnBubbleIsVisible() {
        XCTAssertFalse(
            VoiceNoteMiniBarPolicy.isVisible(hasPlayback: true, isSourceOnScreen: true)
        )
    }

    func testBarTakesOverOnceTheBubbleIsGone() {
        XCTAssertTrue(
            VoiceNoteMiniBarPolicy.isVisible(hasPlayback: true, isSourceOnScreen: false)
        )
    }

    func testNothingPlayingShowsNoBar() {
        XCTAssertFalse(
            VoiceNoteMiniBarPolicy.isVisible(hasPlayback: false, isSourceOnScreen: false)
        )
        XCTAssertFalse(
            VoiceNoteMiniBarPolicy.isVisible(hasPlayback: false, isSourceOnScreen: true)
        )
    }

    // MARK: Video Picture in Picture handoff

    func testPictureInPictureRetainsTeardownWhileStartIsStillPending() {
        XCTAssertTrue(
            ChatVideoPictureInPictureHandoffPolicy.shouldRetainTeardown(
                ownerMatches: true,
                hasController: true,
                startRequested: true,
                isActive: false,
                alreadyRetained: false
            ),
            "The gallery may disappear before AVKit flips isPictureInPictureActive"
        )
    }

    func testPictureInPictureRetainsTeardownAfterItBecomesActive() {
        XCTAssertTrue(
            ChatVideoPictureInPictureHandoffPolicy.shouldRetainTeardown(
                ownerMatches: true,
                hasController: true,
                startRequested: false,
                isActive: true,
                alreadyRetained: false
            )
        )
    }

    func testPictureInPictureNeverRetainsAnUnrelatedOrDuplicateTeardown() {
        XCTAssertFalse(
            ChatVideoPictureInPictureHandoffPolicy.shouldRetainTeardown(
                ownerMatches: false,
                hasController: true,
                startRequested: true,
                isActive: false,
                alreadyRetained: false
            )
        )
        XCTAssertFalse(
            ChatVideoPictureInPictureHandoffPolicy.shouldRetainTeardown(
                ownerMatches: true,
                hasController: true,
                startRequested: true,
                isActive: false,
                alreadyRetained: true
            )
        )
        XCTAssertFalse(
            ChatVideoPictureInPictureHandoffPolicy.shouldRetainTeardown(
                ownerMatches: true,
                hasController: false,
                startRequested: true,
                isActive: false,
                alreadyRetained: false
            )
        )
    }

    // MARK: Video playback failure boundary

    func testVideoStallRemainsOwnedByAVFoundationWithoutReplacingTheLiveItem() {
        XCTAssertEqual(
            ChatVideoPlaybackFailurePolicy.action(for: .stalled),
            .letPlayerRecover
        )
        XCTAssertFalse(ChatVideoPlaybackFailurePolicy.permitsAutomaticPlayerItemReplacement)
    }

    func testVideoFailureStopsAndReportsWithoutReplacingTheLiveItem() {
        XCTAssertEqual(
            ChatVideoPlaybackFailurePolicy.action(for: .failed),
            .stopAndReport
        )
        XCTAssertFalse(ChatVideoPlaybackFailurePolicy.permitsAutomaticPlayerItemReplacement)
    }
}
