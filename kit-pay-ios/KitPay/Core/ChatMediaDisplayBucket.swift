import Foundation

/// How many pixels a chat surface is allowed to ask ImageIO for.
///
/// Owner report, 1.0.17 build 105: *"scrolling through chat messages lags"*. Three of the chat's
/// media surfaces asked for a thumbnail an order of magnitude larger than the bubble they draw
/// into, which cost both the decode and — because the decoded pixels are what the thumbnail cache
/// is budgeted in — the cache itself:
///
/// | Surface | Frame | Asked for | Could draw | Oversampled by |
/// | --- | --- | --- | --- | --- |
/// | `SecureImageMessageView` | 248 x 300 pt | 3 072 px (1 024 pt x 3) | 900 px | **11.6x area** |
/// | `SecureMediaBatchItemView` | 224 x 168 pt | 1 024 px | 672 px | 2.3x area |
/// | `PendingSecureMediaMessageView` | 224 x 168 pt | 2 048 px | 672 px | **9.3x area** |
///
/// A 3 072 px square decodes to 37.7 MB of pixels. The bubble cache is budgeted at 64 MB, so a
/// thread with **three** photos in it could not hold its own thumbnails: every scroll pass evicted
/// and re-decoded, on the main thread, inside `body`. Right-sizing the request is what turns the
/// cache back into a cache.
///
/// The ladder exists for a second reason. `ChatMediaAlbumGridView` asks for
/// `max(cell.width, cell.height)` — an arbitrary float that depends on the album's shape and the
/// screen width, so two albums holding the *same photo* fragmented the cache into two entries.
/// Quantising to a rung makes the cache key a property of the photo and its rough display size,
/// not of one particular layout pass.
///
/// Pure Foundation, no UIKit: the policy is exercised on Linux by
/// `.github/scripts/tests/run_chat_media_bucket_linux_gate.sh`.
enum ChatMediaDisplayBucket {
    /// Requestable pixel ceilings, ascending. Roughly half-stops, so a rung is never more than
    /// 1.5x the edge below it and quantising can never cost more than 2.25x in area.
    static let ladder: [Int] = [128, 192, 256, 384, 512, 768, 1_024, 1_536, 2_048, 3_072, 4_096]

    /// The largest edge any chat surface may request. Full-screen viewing on the widest iPad in
    /// portrait at 3x is under this; nothing in a bubble comes close.
    static let maximumEdge = 4_096

    // MARK: Bubble geometry
    //
    // The drawn sizes, kept here so the tests can compare what a surface asks for against what it
    // can actually put on screen. Each is the *larger* edge of the frame, because every one of
    // these surfaces uses `scaledToFill`.

    /// `SecureImageMessageView` draws `maxWidth: 248, maxHeight: 300`.
    static let photoBubbleEdge: Double = 300
    /// `SecureMediaBatchItemView.imageCell` and `PendingSecureMediaMessageView` draw 224 x 168.
    static let albumItemEdge: Double = 224
    /// `VideoMessageBubbleView` draws a 248 x 186 poster.
    static let videoPosterEdge: Double = 248

    /// Display scale is clamped: there is no 4x iPhone, and an unclamped scale from a test double
    /// or a future device must not be able to quadruple every decode in the app.
    static func clampedScale(_ scale: Double) -> Double {
        guard scale.isFinite else { return 1 }
        return min(max(scale, 1), 3)
    }

    /// The pixel ceiling for a surface whose larger edge is `points` at `scale`.
    ///
    /// Always rounds *up* to a rung, so `scaledToFill` never upscales a thumbnail, and always
    /// returns a rung, so the cache cannot be fragmented by sub-point layout differences.
    static func pixels(forDisplayEdge points: Double, scale: Double) -> Int {
        guard points.isFinite, points > 0 else { return ladder[0] }
        let wanted = points * clampedScale(scale)
        guard wanted.isFinite, wanted > 0 else { return ladder[0] }
        let ceiling = Int(wanted.rounded(.up))
        return ladder.first { $0 >= ceiling } ?? maximumEdge
    }

    /// Decoded cost of a square thumbnail at `edgePixels`, in bytes (8-bit RGBA).
    static func bytes(forSquareEdge edgePixels: Int) -> Int {
        guard edgePixels > 0 else { return 0 }
        return edgePixels * edgePixels * 4
    }

    /// How many square thumbnails of `edgePixels` fit in a cache budget. The thumbnail cache is
    /// only a cache if this is comfortably more than a screenful.
    static func entriesFitting(inBudgetBytes budget: Int, edgePixels: Int) -> Int {
        let cost = bytes(forSquareEdge: edgePixels)
        guard cost > 0, budget > 0 else { return 0 }
        return budget / cost
    }

    /// Requested area over drawable area. 1.0 is exact; below 1.0 would upscale.
    ///
    /// Quantising to the ladder means a well-sized request still lands somewhat above 1.0; the
    /// tests hold every chat surface under 2.5, which no rung gap can breach on its own.
    static func oversampling(
        requestedPixels: Int,
        displayEdge points: Double,
        scale: Double
    ) -> Double {
        let drawable = points * clampedScale(scale)
        guard drawable > 0, requestedPixels > 0 else { return 0 }
        let ratio = Double(requestedPixels) / drawable
        return ratio * ratio
    }
}
