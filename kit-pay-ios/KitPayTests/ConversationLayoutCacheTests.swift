import XCTest

#if canImport(UIKit)
    @testable import KitPay
#endif

/// The second memo on the conversation screen: the six whole-thread folds the *layout* needs.
///
/// The projection memo (see `ConversationProjectionCacheTests`) stopped the corrected-message
/// fold running fifteen times per `body`. It did not stop what came after it: `conversationLayout`
/// still folded the projection six more times on every render — date separators and call rows,
/// album membership, the id index, suppressed reactions, reaction tallies, sender runs — and
/// `timelineItems`, `reactionTallies` and `galleryItems` re-ran those same folds from a dozen
/// further call sites. On a 300-message mixed-media thread that is the per-frame cost the owner
/// felt as *"still some lagging between chats"* on 1.0.17 build 105.
///
/// Runs on Linux through `.github/scripts/tests/run_chat_media_bucket_linux_gate.sh`.
final class ConversationLayoutCacheTests: XCTestCase {
    private static let conversationID = "55555555-5555-5555-5555-555555555555"
    private static let day = Date(timeIntervalSince1970: 1_758_412_800)

    private func key(
        generation: UInt64 = 11,
        conversationID: String = conversationID,
        scheduled: Set<UUID> = [],
        isSelectingMessages: Bool = false,
        isGroupConversation: Bool = false,
        currentUserID: String? = "me",
        separatorDay: Date = day,
        localeIdentifier: String = "en_GB"
    ) -> ConversationLayoutKey {
        ConversationLayoutKey(
            projection: ConversationProjectionKey(
                stateGeneration: generation,
                conversationID: conversationID,
                scheduledMessageIDs: scheduled
            ),
            isSelectingMessages: isSelectingMessages,
            isGroupConversation: isGroupConversation,
            currentUserID: currentUserID,
            separatorDay: separatorDay,
            localeIdentifier: localeIdentifier
        )
    }

    func testTenRendersOfOneStateFoldOnce() {
        let cache = ConversationLayoutCache<[Int]>()
        for _ in 0 ..< 10 {
            XCTAssertEqual(cache.derivation(for: key()) { [1, 2, 3] }, [1, 2, 3])
        }
        XCTAssertEqual(
            cache.buildCount,
            1,
            "ten renders of an unchanged thread must fold the thread once"
        )
    }

    func testAnUnchangedKeyHandsBackTheSameBuffer() {
        let cache = ConversationLayoutCache<[Int]>()
        let first = cache.derivation(for: key()) { Array(0 ..< 300) }
        let second = cache.derivation(for: key()) { Array(0 ..< 300) }
        first.withUnsafeBufferPointer { lhs in
            second.withUnsafeBufferPointer { rhs in
                XCTAssertEqual(
                    lhs.baseAddress,
                    rhs.baseAddress,
                    "sharing the buffer is what makes SwiftUI's `onChange(of:)` comparisons cheap"
                )
            }
        }
        XCTAssertEqual(cache.buildCount, 1)
    }

    func testANewMessageRefolds() {
        let cache = ConversationLayoutCache<[Int]>()
        XCTAssertEqual(cache.derivation(for: key(generation: 11)) { [1] }, [1])
        XCTAssertEqual(cache.derivation(for: key(generation: 12)) { [1, 2] }, [1, 2])
        XCTAssertEqual(cache.buildCount, 2)
    }

    func testEnteringSelectionModeRefoldsBecauseTheRowsChangeShape() {
        let cache = ConversationLayoutCache<[Int]>()
        _ = cache.derivation(for: key(isSelectingMessages: false)) { [1] }
        _ = cache.derivation(for: key(isSelectingMessages: true)) { [2] }
        XCTAssertEqual(cache.buildCount, 2)
    }

    func testMidnightRefoldsTheDateSeparators() {
        let cache = ConversationLayoutCache<[Int]>()
        _ = cache.derivation(for: key(separatorDay: Self.day)) { [1] }
        let tomorrow = Self.day.addingTimeInterval(86_400)
        _ = cache.derivation(for: key(separatorDay: tomorrow)) { [2] }
        XCTAssertEqual(
            cache.buildCount,
            2,
            "\"Today\" must stop saying Today at midnight, with no state publish to prompt it"
        )
    }

    func testALocaleChangeRefoldsEvenThoughAppStateDidNotPublish() {
        let cache = ConversationLayoutCache<[Int]>()
        _ = cache.derivation(for: key(localeIdentifier: "en_GB")) { [1] }
        _ = cache.derivation(for: key(localeIdentifier: "sw_KE")) { [2] }
        XCTAssertEqual(cache.buildCount, 2)
    }

    func testAnotherConversationNeverReadsThisOnesLayout() {
        let cache = ConversationLayoutCache<[Int]>()
        XCTAssertEqual(cache.derivation(for: key(conversationID: "a")) { [1] }, [1])
        XCTAssertEqual(cache.derivation(for: key(conversationID: "b")) { [2] }, [2])
        XCTAssertEqual(cache.buildCount, 2)
    }

    func testSignOutInvalidatesRatherThanWaitingForAKeyChange() {
        let cache = ConversationLayoutCache<[Int]>()
        _ = cache.derivation(for: key()) { [1] }
        cache.invalidate()
        XCTAssertEqual(
            cache.derivation(for: key()) { [2] },
            [2],
            "one account's layout must never be answerable to the next"
        )
        XCTAssertEqual(cache.buildCount, 2)
    }

    func testTheKeyComparesEveryInputItCarries() {
        XCTAssertEqual(key(), key())
        XCTAssertNotEqual(key(), key(generation: 12))
        XCTAssertNotEqual(key(), key(conversationID: "other"))
        XCTAssertNotEqual(key(), key(scheduled: [UUID()]))
        XCTAssertNotEqual(key(), key(isSelectingMessages: true))
        XCTAssertNotEqual(key(), key(isGroupConversation: true))
        XCTAssertNotEqual(key(), key(currentUserID: "someone-else"))
        XCTAssertNotEqual(key(), key(currentUserID: nil))
        XCTAssertNotEqual(key(), key(separatorDay: Self.day.addingTimeInterval(86_400)))
        XCTAssertNotEqual(key(), key(localeIdentifier: "sw_KE"))
    }

    static var allTests = [
        ("testTenRendersOfOneStateFoldOnce", testTenRendersOfOneStateFoldOnce),
        ("testAnUnchangedKeyHandsBackTheSameBuffer", testAnUnchangedKeyHandsBackTheSameBuffer),
        ("testANewMessageRefolds", testANewMessageRefolds),
        ("testEnteringSelectionModeRefoldsBecauseTheRowsChangeShape",
         testEnteringSelectionModeRefoldsBecauseTheRowsChangeShape),
        ("testMidnightRefoldsTheDateSeparators", testMidnightRefoldsTheDateSeparators),
        ("testALocaleChangeRefoldsEvenThoughAppStateDidNotPublish",
         testALocaleChangeRefoldsEvenThoughAppStateDidNotPublish),
        ("testAnotherConversationNeverReadsThisOnesLayout",
         testAnotherConversationNeverReadsThisOnesLayout),
        ("testSignOutInvalidatesRatherThanWaitingForAKeyChange",
         testSignOutInvalidatesRatherThanWaitingForAKeyChange),
        ("testTheKeyComparesEveryInputItCarries", testTheKeyComparesEveryInputItCarries),
    ]
}
