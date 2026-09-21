import XCTest

#if canImport(UIKit)
    @testable import KitPay
#endif

/// The memo behind the conversation timeline's corrected projection.
///
/// The chat-scroll freeze this guards was not a gesture bug: the screen recomputed a fold over
/// every message the account holds on about fifteen reads per `body`, so on the 2 000-message
/// long-history fixture the main thread could not service touch moves. The pan never reached its
/// slop and the timeline moved 0.0 points. These cases pin the three properties the fix depends
/// on — fold once per key, hand back the *same* value so `Array ==` short-circuits on buffer
/// identity, and never answer a changed key from the memo.
///
/// This file also runs on Linux against the same production source (see
/// `.github/scripts/tests/run_conversation_projection_linux_gate.sh`), which is why it declares
/// `allTests` and imports the app module only conditionally. Keep it free of UIKit and of symbols
/// outside `ConversationProjectionCache.swift`.
final class ConversationProjectionCacheTests: XCTestCase {
    private static let conversationID = "44444444-4444-4444-4444-444444444444"

    private func key(
        generation: UInt64 = 7,
        conversationID: String = conversationID,
        scheduled: Set<UUID> = []
    ) -> ConversationProjectionKey {
        ConversationProjectionKey(
            stateGeneration: generation,
            conversationID: conversationID,
            scheduledMessageIDs: scheduled
        )
    }

    func testRepeatedReadsOfOneGenerationFoldExactlyOnce() {
        let cache = ConversationProjectionCache<[Int]>()
        var folds = 0
        // Fifteen reads is what one `body` of the conversation screen actually performs.
        for _ in 0..<15 {
            _ = cache.projection(for: key()) {
                folds += 1
                return [1, 2, 3]
            }
        }
        XCTAssertEqual(folds, 1, "one state generation must fold the thread once")
        XCTAssertEqual(cache.buildCount, 1)
    }

    func testAnUnchangedKeyHandsBackTheSameBufferSoArrayComparisonsStayCheap() {
        let cache = ConversationProjectionCache<[Int]>()
        let first = cache.projection(for: key()) { Array(0..<2_000) }
        let second = cache.projection(for: key()) { Array(0..<2_000) }
        let firstIdentity = first.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
        let secondIdentity = second.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
        XCTAssertEqual(
            firstIdentity,
            secondIdentity,
            "SwiftUI's onChange comparisons only stay O(1) while both sides share one buffer"
        )
    }

    func testANewStateGenerationRefoldsRatherThanAnsweringFromTheMemo() {
        let cache = ConversationProjectionCache<[Int]>()
        XCTAssertEqual(cache.projection(for: key(generation: 1)) { [1] }, [1])
        XCTAssertEqual(cache.projection(for: key(generation: 2)) { [1, 2] }, [1, 2])
        XCTAssertEqual(cache.buildCount, 2)
    }

    func testASecondConversationNeverReadsTheFirstConversationsProjection() {
        let cache = ConversationProjectionCache<[Int]>()
        let other = "55555555-5555-5555-5555-555555555555"
        XCTAssertEqual(cache.projection(for: key()) { [1] }, [1])
        XCTAssertEqual(cache.projection(for: key(conversationID: other)) { [9] }, [9])
        XCTAssertEqual(
            cache.projection(for: key()) { [1] },
            [1],
            "the key carries the conversation, so switching back refolds rather than leaking"
        )
        XCTAssertEqual(cache.buildCount, 3)
    }

    func testAMaturingSendLaterRowRefoldsWithoutAStatePublish() {
        let cache = ConversationProjectionCache<[Int]>()
        let waiting = UUID()
        // The Send Later set moves on the presentation clock; the generation does not change.
        XCTAssertEqual(cache.projection(for: key(scheduled: [waiting])) { [1] }, [1])
        XCTAssertEqual(cache.projection(for: key(scheduled: [])) { [1, 2] }, [1, 2])
        XCTAssertEqual(cache.buildCount, 2)
    }

    func testInvalidationDropsTheMemoForAnUnchangedKey() {
        let cache = ConversationProjectionCache<[Int]>()
        XCTAssertEqual(cache.projection(for: key()) { [1] }, [1])
        cache.invalidate()
        XCTAssertEqual(
            cache.projection(for: key()) { [2] },
            [2],
            "an account teardown must not be answerable from the previous account's fold"
        )
        XCTAssertEqual(cache.buildCount, 2)
    }

    func testTheKeyComparesEveryInputItCarries() {
        let waiting = UUID()
        XCTAssertEqual(key(), key())
        XCTAssertNotEqual(key(), key(generation: 8))
        XCTAssertNotEqual(key(), key(conversationID: "other"))
        XCTAssertNotEqual(key(), key(scheduled: [waiting]))
    }

    static var allTests = [
        ("testRepeatedReadsOfOneGenerationFoldExactlyOnce",
         testRepeatedReadsOfOneGenerationFoldExactlyOnce),
        ("testAnUnchangedKeyHandsBackTheSameBufferSoArrayComparisonsStayCheap",
         testAnUnchangedKeyHandsBackTheSameBufferSoArrayComparisonsStayCheap),
        ("testANewStateGenerationRefoldsRatherThanAnsweringFromTheMemo",
         testANewStateGenerationRefoldsRatherThanAnsweringFromTheMemo),
        ("testASecondConversationNeverReadsTheFirstConversationsProjection",
         testASecondConversationNeverReadsTheFirstConversationsProjection),
        ("testAMaturingSendLaterRowRefoldsWithoutAStatePublish",
         testAMaturingSendLaterRowRefoldsWithoutAStatePublish),
        ("testInvalidationDropsTheMemoForAnUnchangedKey",
         testInvalidationDropsTheMemoForAnUnchangedKey),
        ("testTheKeyComparesEveryInputItCarries", testTheKeyComparesEveryInputItCarries),
    ]
}
