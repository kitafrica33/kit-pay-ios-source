import XCTest

#if canImport(UIKit)
    @testable import KitPay
#endif

/// The voice-note waveform, after it stopped allocating two arrays per frame.
///
/// The shape is a *published visual*: customers recognise their own notes by it, so the point of
/// these cases is that moving the computation out of `body` changed nothing anyone can see. The
/// heights are pinned against an explicitly-written expected form, not against a re-implementation
/// of the function under test.
///
/// Runs on Linux through `.github/scripts/tests/run_chat_media_bucket_linux_gate.sh`.
final class ChatWaveformShapeTests: XCTestCase {
    private static let seed = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00CF4FC964FF")!

    func testTheShapeIsStableForASeed() {
        let first = (0 ..< ChatWaveformShape.barCount).map {
            ChatWaveformShape.height(seed: Self.seed, at: $0)
        }
        let second = (0 ..< ChatWaveformShape.barCount).map {
            ChatWaveformShape.height(seed: Self.seed, at: $0)
        }
        XCTAssertEqual(first, second, "a note must not re-roll its waveform between renders")
    }

    func testTheHeightsMatchTheBuildOneOhFiveFormula() {
        // Build 105 built `[UInt8](seed.uuid bytes)` then, per bar,
        // `6 + CGFloat((bytes[i % 16] &+ UInt8(truncatingIfNeeded: i * 37)) % 16)`.
        let bytes = withUnsafeBytes(of: Self.seed.uuid) { Array($0) }
        XCTAssertEqual(bytes.count, 16)
        for index in 0 ..< ChatWaveformShape.barCount {
            let expected =
                6.0
                + Double(
                    (bytes[index % 16] &+ UInt8(truncatingIfNeeded: index &* 37)) % 16
                )
            XCTAssertEqual(
                ChatWaveformShape.height(seed: Self.seed, at: index),
                expected,
                accuracy: 1e-9,
                "bar \(index) changed shape when the allocation was removed"
            )
        }
    }

    func testEveryBarIsDrawableAndBounded() {
        for index in 0 ..< (ChatWaveformShape.barCount * 4) {
            let height = ChatWaveformShape.height(seed: Self.seed, at: index)
            XCTAssertGreaterThanOrEqual(height, ChatWaveformShape.minimumHeight)
            XCTAssertLessThanOrEqual(
                height,
                ChatWaveformShape.minimumHeight + Double(ChatWaveformShape.heightSteps) - 1
            )
        }
    }

    func testANegativeIndexCannotProduceACrashOrAnInvisibleBar() {
        XCTAssertEqual(
            ChatWaveformShape.height(seed: Self.seed, at: -1),
            ChatWaveformShape.minimumHeight
        )
    }

    func testDifferentNotesUsuallyLookDifferent() {
        let shapes = Set(
            (0 ..< 64).map { _ -> [Double] in
                let seed = UUID()
                return (0 ..< ChatWaveformShape.barCount).map {
                    ChatWaveformShape.height(seed: seed, at: $0)
                }
            }.map { $0.map { "\($0)" }.joined(separator: ",") }
        )
        XCTAssertGreaterThan(shapes.count, 60, "the waveform stopped distinguishing notes")
    }

    // MARK: Playhead

    func testAnUnplayedNoteTintsNothing() {
        for index in 0 ..< ChatWaveformShape.barCount {
            XCTAssertFalse(
                ChatWaveformShape.isPlayed(
                    index: index, count: ChatWaveformShape.barCount, progress: 0
                ),
                "bar \(index) looked played before playback started"
            )
        }
    }

    func testTheTintAdvancesMonotonicallyAndCompletes() {
        let count = ChatWaveformShape.barCount
        var previous = 0
        for step in 1 ... 20 {
            let progress = Double(step) / 20
            let played = (0 ..< count).filter {
                ChatWaveformShape.isPlayed(index: $0, count: count, progress: progress)
            }
            XCTAssertEqual(
                played,
                Array(0 ..< played.count),
                "the played bars must be a prefix, never a scatter"
            )
            XCTAssertGreaterThanOrEqual(played.count, previous)
            previous = played.count
        }
        XCTAssertEqual(previous, count, "a finished note must show every bar played")
    }

    func testBrokenProgressIsRefusedRatherThanRendered() {
        XCTAssertFalse(
            ChatWaveformShape.isPlayed(index: 0, count: ChatWaveformShape.barCount, progress: .nan)
        )
        XCTAssertFalse(ChatWaveformShape.isPlayed(index: 0, count: 0, progress: 0.5))
        XCTAssertFalse(
            ChatWaveformShape.isPlayed(index: 0, count: ChatWaveformShape.barCount, progress: -1)
        )
    }

    static var allTests = [
        ("testTheShapeIsStableForASeed", testTheShapeIsStableForASeed),
        ("testTheHeightsMatchTheBuildOneOhFiveFormula",
         testTheHeightsMatchTheBuildOneOhFiveFormula),
        ("testEveryBarIsDrawableAndBounded", testEveryBarIsDrawableAndBounded),
        ("testANegativeIndexCannotProduceACrashOrAnInvisibleBar",
         testANegativeIndexCannotProduceACrashOrAnInvisibleBar),
        ("testDifferentNotesUsuallyLookDifferent", testDifferentNotesUsuallyLookDifferent),
        ("testAnUnplayedNoteTintsNothing", testAnUnplayedNoteTintsNothing),
        ("testTheTintAdvancesMonotonicallyAndCompletes",
         testTheTintAdvancesMonotonicallyAndCompletes),
        ("testBrokenProgressIsRefusedRatherThanRendered",
         testBrokenProgressIsRefusedRatherThanRendered),
    ]
}
