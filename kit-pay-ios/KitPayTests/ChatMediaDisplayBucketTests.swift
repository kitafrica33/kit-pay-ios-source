import XCTest

#if canImport(UIKit)
    @testable import KitPay
#endif

/// The decode-size policy behind the owner's *"scrolling through chat messages lags"* report on
/// 1.0.17 build 105.
///
/// These cases are deliberately written as *budget* assertions rather than as golden numbers:
/// what matters is not that a photo bubble asks for 1 024 pixels, it is that a 64 MB cache can
/// hold a screenful of what the chat asks for, and that nothing asks ImageIO for an order of
/// magnitude more pixels than it can draw. Build 105 failed both, which is why the cache could
/// not keep a single scroll's worth of thumbnails and every pass re-decoded on the main thread.
///
/// Runs on Linux against the production source through
/// `.github/scripts/tests/run_chat_media_bucket_linux_gate.sh`, which is why `allTests` is
/// declared and the app module is imported only where UIKit exists.
final class ChatMediaDisplayBucketTests: XCTestCase {
    /// The thumbnail cache's `totalCostLimit`, mirrored from `ChatMediaThumbnails.swift`.
    private static let cacheBudgetBytes = 64 * 1_024 * 1_024

    // MARK: The ladder itself

    func testTheLadderIsAscendingAndEndsAtTheStatedMaximum() {
        XCTAssertFalse(ChatMediaDisplayBucket.ladder.isEmpty)
        XCTAssertEqual(
            ChatMediaDisplayBucket.ladder,
            ChatMediaDisplayBucket.ladder.sorted(),
            "the ladder is searched with `first { $0 >= ceiling }`; out of order it would lie"
        )
        XCTAssertEqual(Set(ChatMediaDisplayBucket.ladder).count, ChatMediaDisplayBucket.ladder.count)
        XCTAssertEqual(ChatMediaDisplayBucket.ladder.last, ChatMediaDisplayBucket.maximumEdge)
    }

    func testNoRungIsMoreThanHalfAgainTheRungBelowIt() {
        for (lower, upper) in zip(
            ChatMediaDisplayBucket.ladder,
            ChatMediaDisplayBucket.ladder.dropFirst()
        ) {
            XCTAssertLessThanOrEqual(
                Double(upper) / Double(lower),
                1.5 + 1e-9,
                "rung \(lower) -> \(upper) quantises to more than 2.25x in area"
            )
        }
    }

    // MARK: Quantisation

    func testEveryRequestLandsOnARung() {
        for points in stride(from: 1.0, through: 1_400.0, by: 7.0) {
            for scale in [1.0, 2.0, 3.0] {
                let pixels = ChatMediaDisplayBucket.pixels(forDisplayEdge: points, scale: scale)
                XCTAssertTrue(
                    ChatMediaDisplayBucket.ladder.contains(pixels),
                    "\(points)pt @\(scale)x produced \(pixels), which is not a rung"
                )
            }
        }
    }

    func testARequestIsNeverSmallerThanWhatTheSurfaceDraws() {
        for points in stride(from: 1.0, through: 1_300.0, by: 3.0) {
            for scale in [1.0, 2.0, 3.0] {
                let pixels = ChatMediaDisplayBucket.pixels(forDisplayEdge: points, scale: scale)
                XCTAssertGreaterThanOrEqual(
                    Double(pixels),
                    points * scale,
                    "\(points)pt @\(scale)x would be upscaled from \(pixels)px by scaledToFill"
                )
            }
        }
    }

    func testTwoAlbumLayoutsOfTheSamePhotoShareOneCacheEntry() {
        // `ChatMediaAlbumGridView` asks for `max(cell.width, cell.height)`, which depends on the
        // album's item count and the screen width. Before the ladder those arbitrary floats each
        // minted their own cache entry for the same photo.
        let awkwardCellEdges = [108.0, 109.5, 110.0, 112.333_333, 118.75]
        let requests = Set(
            awkwardCellEdges.map { ChatMediaDisplayBucket.pixels(forDisplayEdge: $0, scale: 3) }
        )
        XCTAssertEqual(
            requests.count,
            1,
            "five near-identical album cells fragmented the cache into \(requests.count) copies"
        )
    }

    func testAbsurdOrBrokenInputsCannotProduceAnAbsurdDecode() {
        XCTAssertEqual(
            ChatMediaDisplayBucket.pixels(forDisplayEdge: .nan, scale: 3),
            ChatMediaDisplayBucket.ladder[0]
        )
        XCTAssertEqual(ChatMediaDisplayBucket.pixels(forDisplayEdge: 0, scale: 3), ChatMediaDisplayBucket.ladder[0])
        XCTAssertEqual(ChatMediaDisplayBucket.pixels(forDisplayEdge: -20, scale: 3), ChatMediaDisplayBucket.ladder[0])
        XCTAssertEqual(
            ChatMediaDisplayBucket.pixels(forDisplayEdge: 99_999, scale: 3),
            ChatMediaDisplayBucket.maximumEdge,
            "nothing may ask for more than the stated ceiling, whatever the layout claims"
        )
    }

    func testDisplayScaleIsClamped() {
        XCTAssertEqual(ChatMediaDisplayBucket.clampedScale(0), 1)
        XCTAssertEqual(ChatMediaDisplayBucket.clampedScale(-4), 1)
        XCTAssertEqual(ChatMediaDisplayBucket.clampedScale(2), 2)
        XCTAssertEqual(ChatMediaDisplayBucket.clampedScale(9), 3)
        XCTAssertEqual(ChatMediaDisplayBucket.clampedScale(.nan), 1)
        XCTAssertEqual(
            ChatMediaDisplayBucket.pixels(forDisplayEdge: 300, scale: 12),
            ChatMediaDisplayBucket.pixels(forDisplayEdge: 300, scale: 3),
            "an unclamped scale would quadruple every decode in the app"
        )
    }

    // MARK: The three reported surfaces

    /// The table in `ChatMediaDisplayBucket`'s own documentation, asserted.
    func testNoChatBubbleOversamplesByMoreThanTwoAndAHalfTimesInArea() {
        let surfaces: [(String, Double)] = [
            ("photo bubble", ChatMediaDisplayBucket.photoBubbleEdge),
            ("album item", ChatMediaDisplayBucket.albumItemEdge),
            ("video poster", ChatMediaDisplayBucket.videoPosterEdge),
        ]
        for (name, edge) in surfaces {
            let pixels = ChatMediaDisplayBucket.pixels(forDisplayEdge: edge, scale: 3)
            let oversampling = ChatMediaDisplayBucket.oversampling(
                requestedPixels: pixels,
                displayEdge: edge,
                scale: 3
            )
            XCTAssertGreaterThanOrEqual(oversampling, 1.0, "\(name) would be upscaled")
            XCTAssertLessThanOrEqual(
                oversampling,
                2.5,
                "\(name) asks for \(pixels)px to draw \(edge)pt @3x: \(oversampling)x in area"
            )
        }
    }

    /// Cost per *vertical point of thread*, which is the only figure that says whether a cache
    /// survives a scroll: a screen is a fixed number of points tall whatever it is showing.
    private func costPerThreadPoint(edge: Double) -> Double {
        let pixels = ChatMediaDisplayBucket.pixels(forDisplayEdge: edge, scale: 3)
        // The bubbles are wider than they are tall except the photo bubble, which is 248 x 300;
        // charging the full square decode against the drawn height is the worst case.
        return Double(ChatMediaDisplayBucket.bytes(forSquareEdge: pixels)) / drawnHeight(edge: edge)
    }

    private func drawnHeight(edge: Double) -> Double {
        switch edge {
        case ChatMediaDisplayBucket.photoBubbleEdge: return 300
        case ChatMediaDisplayBucket.albumItemEdge: return 168
        default: return 186
        }
    }

    func testBuildOneOhFiveCouldNotCacheOneScreenfulAndThisOneHoldsSeveral() {
        // A 6.9-inch iPhone shows about 900 points of thread at once.
        let screenPoints = 900.0

        // What build 105 asked a photo bubble for: 1 024 points at 3x, unquantised.
        let beforePerPoint = Double(ChatMediaDisplayBucket.bytes(forSquareEdge: 3_072)) / 300
        XCTAssertGreaterThan(
            beforePerPoint * screenPoints,
            Double(Self.cacheBudgetBytes),
            """
            the defect: one screenful of photo bubbles cost more than the whole 64MB budget, \
            so every scroll pass evicted what the pass before it had just decoded
            """
        )

        let worstPerPoint = [
            ChatMediaDisplayBucket.photoBubbleEdge,
            ChatMediaDisplayBucket.albumItemEdge,
            ChatMediaDisplayBucket.videoPosterEdge,
        ].map(costPerThreadPoint).max() ?? .infinity
        let screenfuls = Double(Self.cacheBudgetBytes) / (worstPerPoint * screenPoints)
        XCTAssertGreaterThanOrEqual(
            screenfuls,
            4,
            "the budget holds \(screenfuls) screenfuls of the densest possible media"
        )
    }

    func testTheDensestScreenfulIsASmallFractionOfTheBudget() {
        // The two densest ways to fill the ~900 points a 6.9-inch iPhone shows: three photo
        // bubbles at 300pt, or an album of four 168pt items with a 186pt video poster above it.
        let threePhotoBubbles = 3 * ChatMediaDisplayBucket.bytes(
            forSquareEdge: ChatMediaDisplayBucket.pixels(
                forDisplayEdge: ChatMediaDisplayBucket.photoBubbleEdge, scale: 3))
        let albumAndAPoster =
            4 * ChatMediaDisplayBucket.bytes(
                forSquareEdge: ChatMediaDisplayBucket.pixels(
                    forDisplayEdge: ChatMediaDisplayBucket.albumItemEdge, scale: 3))
            + ChatMediaDisplayBucket.bytes(
                forSquareEdge: ChatMediaDisplayBucket.pixels(
                    forDisplayEdge: ChatMediaDisplayBucket.videoPosterEdge, scale: 3))
        let cost = max(threePhotoBubbles, albumAndAPoster)
        XCTAssertLessThan(
            cost,
            Self.cacheBudgetBytes / 3,
            "a screenful costs \(cost) bytes of a \(Self.cacheBudgetBytes) byte budget"
        )
    }

    func testBytesAndFittingAreConsistentAndRefuseNonsense() {
        XCTAssertEqual(ChatMediaDisplayBucket.bytes(forSquareEdge: 512), 512 * 512 * 4)
        XCTAssertEqual(ChatMediaDisplayBucket.bytes(forSquareEdge: 0), 0)
        XCTAssertEqual(ChatMediaDisplayBucket.bytes(forSquareEdge: -1), 0)
        XCTAssertEqual(
            ChatMediaDisplayBucket.entriesFitting(inBudgetBytes: 0, edgePixels: 256),
            0
        )
        XCTAssertEqual(
            ChatMediaDisplayBucket.entriesFitting(inBudgetBytes: 1_024, edgePixels: 0),
            0
        )
        XCTAssertEqual(
            ChatMediaDisplayBucket.oversampling(requestedPixels: 0, displayEdge: 300, scale: 3),
            0
        )
        XCTAssertEqual(
            ChatMediaDisplayBucket.oversampling(requestedPixels: 900, displayEdge: 0, scale: 3),
            0
        )
    }

    func testFullScreenViewingStillGetsTheFullResolutionCeiling() {
        // The gallery and the standalone viewers are allowed the maximum: they fill the screen
        // and the customer can pinch into them. The point of the policy is the *bubbles*.
        XCTAssertEqual(ChatMediaDisplayBucket.maximumEdge, ChatMediaDisplayBucket.ladder.last)
        XCTAssertGreaterThanOrEqual(
            ChatMediaDisplayBucket.maximumEdge,
            Int(1_366 * 2),
            "the 12.9-inch iPad's long edge at 2x must not be upscaled in the viewer"
        )
        XCTAssertGreaterThanOrEqual(
            ChatMediaDisplayBucket.maximumEdge,
            Int(956 * 3),
            "the tallest iPhone at 3x must not be upscaled in the viewer"
        )
    }

    static var allTests = [
        ("testTheLadderIsAscendingAndEndsAtTheStatedMaximum",
         testTheLadderIsAscendingAndEndsAtTheStatedMaximum),
        ("testNoRungIsMoreThanHalfAgainTheRungBelowIt", testNoRungIsMoreThanHalfAgainTheRungBelowIt),
        ("testEveryRequestLandsOnARung", testEveryRequestLandsOnARung),
        ("testARequestIsNeverSmallerThanWhatTheSurfaceDraws",
         testARequestIsNeverSmallerThanWhatTheSurfaceDraws),
        ("testTwoAlbumLayoutsOfTheSamePhotoShareOneCacheEntry",
         testTwoAlbumLayoutsOfTheSamePhotoShareOneCacheEntry),
        ("testAbsurdOrBrokenInputsCannotProduceAnAbsurdDecode",
         testAbsurdOrBrokenInputsCannotProduceAnAbsurdDecode),
        ("testDisplayScaleIsClamped", testDisplayScaleIsClamped),
        ("testNoChatBubbleOversamplesByMoreThanTwoAndAHalfTimesInArea",
         testNoChatBubbleOversamplesByMoreThanTwoAndAHalfTimesInArea),
        ("testBuildOneOhFiveCouldNotCacheOneScreenfulAndThisOneHoldsSeveral",
         testBuildOneOhFiveCouldNotCacheOneScreenfulAndThisOneHoldsSeveral),
        ("testTheDensestScreenfulIsASmallFractionOfTheBudget",
         testTheDensestScreenfulIsASmallFractionOfTheBudget),
        ("testBytesAndFittingAreConsistentAndRefuseNonsense",
         testBytesAndFittingAreConsistentAndRefuseNonsense),
        ("testFullScreenViewingStillGetsTheFullResolutionCeiling",
         testFullScreenViewingStillGetsTheFullResolutionCeiling),
    ]
}
