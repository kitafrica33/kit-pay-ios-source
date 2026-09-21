#if canImport(UIKit)
    import XCTest

    @testable import KitPay

    /// What the chat-scroll fix is worth, measured rather than asserted.
    ///
    /// The freeze was a main-thread budget problem: on the 2 000-message long-history fixture the
    /// first pan sample arrived 644 ms after touch-down against 106 ms on a short thread, and in
    /// the failing pass none arrived at all before the finger lifted, so the timeline moved
    /// exactly 0.0 points. The cost was `ConversationView.correctedProjection` — filter, apply
    /// corrections, sort, copy, over every message the account holds — recomputed on each of the
    /// roughly fifteen reads a single `body` performs.
    ///
    /// These cases run the real fold over a realistic thread and compare it with the memoised
    /// route, and they compare the two `onChange(of: messages)` array comparisons the screen
    /// performs per render. They assert generous ratios, not absolute milliseconds: a shared CI
    /// Mac cannot promise wall-clock numbers, but a memo that has stopped memoising loses an
    /// order of magnitude and cannot hide inside any reasonable margin. The measured values are
    /// attached to the result bundle so a regression can be read off, not guessed at.
    final class ConversationProjectionPerformanceTests: XCTestCase {
        private static let conversationID = "44444444-4444-4444-4444-444444444444"
        /// The fixture the failing UI test uses.
        private static let messageCount = 2_000
        /// Reads of `correctedProjection` in one `body` of the conversation screen.
        private static let readsPerRender = 15
        private static let renders = 10

        private func thread() -> [LocalMessage] {
            let start = Date(timeIntervalSince1970: 1_700_000_000)
            // A tenth of the thread carries attachment bytes, which is what made the deep
            // `[LocalMessage]` comparisons in `onChange` expensive as well as the fold.
            let payload = Data(repeating: 0xAB, count: 4_096)
            return (0..<Self.messageCount).map { index in
                LocalMessage(
                    id: UUID(),
                    serverMessageId: UUID().uuidString.lowercased(),
                    conversationId: Self.conversationID,
                    senderId: index.isMultiple(of: 2) ? "me" : "them",
                    body: "Long history \(index)",
                    createdAt: start.addingTimeInterval(Double(index)),
                    sentAt: start.addingTimeInterval(Double(index)),
                    state: index.isMultiple(of: 2) ? .read : .received,
                    failureReason: nil,
                    isOutgoing: index.isMultiple(of: 2),
                    attachmentData: index.isMultiple(of: 10) ? payload : nil
                )
            }
        }

        /// The production fold, verbatim, so the measurement is of real work.
        private func fold(
            _ messages: [LocalMessage],
            conversationID: String,
            waiting: Set<UUID>
        ) -> (messages: [LocalMessage], editedAt: [UUID: Date]) {
            let visible = messages.filter {
                $0.conversationId == conversationID && !waiting.contains($0.id)
            }
            let corrections = MessageEditAggregationPolicy.appliedEdits(in: visible)
            let instructions = MessageEditAggregationPolicy.suppressedMessageIDs(in: visible)
            var editedAt: [UUID: Date] = [:]
            var projected: [LocalMessage] = []
            projected.reserveCapacity(visible.count)
            for message in visible where !instructions.contains(message.id) {
                guard let serverMessageID = message.serverMessageId?.lowercased(),
                      let correction = corrections[serverMessageID]
                else {
                    projected.append(message)
                    continue
                }
                var corrected = message
                corrected.body = correction.body
                editedAt[message.id] = correction.editedAt
                projected.append(corrected)
            }
            projected.sort { $0.timelineDate < $1.timelineDate }
            return (projected, editedAt)
        }

        private func elapsed(_ work: () -> Void) -> TimeInterval {
            let start = Date()
            work()
            return Date().timeIntervalSince(start)
        }

        func testMemoisingTheProjectionCutsTheRenderBudgetByAnOrderOfMagnitude() {
            let messages = thread()
            let waiting: Set<UUID> = []
            var sink = 0

            let unmemoised = elapsed {
                for _ in 0..<Self.renders {
                    for _ in 0..<Self.readsPerRender {
                        sink += fold(
                            messages, conversationID: Self.conversationID, waiting: waiting
                        ).messages.count
                    }
                }
            }

            let cache = ConversationProjectionCache<(
                messages: [LocalMessage], editedAt: [UUID: Date]
            )>()
            let memoised = elapsed {
                for render in 0..<Self.renders {
                    // One published state generation per render, as the screen sees it.
                    let key = ConversationProjectionKey(
                        stateGeneration: UInt64(render),
                        conversationID: Self.conversationID,
                        scheduledMessageIDs: waiting
                    )
                    for _ in 0..<Self.readsPerRender {
                        sink += cache.projection(for: key) {
                            fold(messages, conversationID: Self.conversationID, waiting: waiting)
                        }.messages.count
                    }
                }
            }

            XCTAssertEqual(
                cache.buildCount,
                Self.renders,
                "one fold per state generation, not one per read"
            )
            XCTAssertGreaterThan(sink, 0)
            let report = """
                Thread: \(Self.messageCount) messages, \
                \(Self.renders) renders x \(Self.readsPerRender) reads.
                Folds: \(Self.renders * Self.readsPerRender) before, \(cache.buildCount) after.
                Elapsed: \(Int(unmemoised * 1000)) ms before, \(Int(memoised * 1000)) ms after.
                """
            let attachment = XCTAttachment(string: report)
            attachment.name = "conversation-projection-render-budget"
            attachment.lifetime = .keepAlways
            add(attachment)
            print("[KitPayProjectionBudget] \(report)")
            XCTAssertLessThan(
                memoised,
                unmemoised / 5,
                "The memo must remove most of the per-render projection cost; a fold per read is "
                    + "what starved touch handling on long threads. \(report)"
            )
        }

        func testAnUnchangedProjectionMakesTheOnChangeComparisonsFree() {
            let messages = thread()
            let waiting: Set<UUID> = []
            let cache = ConversationProjectionCache<(
                messages: [LocalMessage], editedAt: [UUID: Date]
            )>()
            let key = ConversationProjectionKey(
                stateGeneration: 1,
                conversationID: Self.conversationID,
                scheduledMessageIDs: waiting
            )
            let memoisedFirst = cache.projection(for: key) {
                fold(messages, conversationID: Self.conversationID, waiting: waiting)
            }.messages
            let memoisedSecond = cache.projection(for: key) {
                fold(messages, conversationID: Self.conversationID, waiting: waiting)
            }.messages
            let freshFirst = fold(
                messages, conversationID: Self.conversationID, waiting: waiting
            ).messages
            let freshSecond = fold(
                messages, conversationID: Self.conversationID, waiting: waiting
            ).messages

            // SwiftUI runs this comparison for every `onChange(of: messages)` on the screen —
            // twice per render — and the elements carry optional attachment `Data`. Each round
            // compares against a different array so the optimizer cannot hoist one invariant
            // comparison out of the loop and measure nothing.
            let rounds = Self.renders * 2
            let distinctBuffers = (0..<rounds).map { _ in freshSecond.map { $0 } }
            let sharedBuffers = (0..<rounds).map { _ in memoisedSecond }
            XCTAssertEqual(freshFirst, freshSecond, "the two projections describe the same thread")
            var matches = 0
            let deep = elapsed {
                for candidate in distinctBuffers where freshFirst == candidate { matches += 1 }
            }
            let shared = elapsed {
                for candidate in sharedBuffers where memoisedFirst == candidate { matches += 1 }
            }
            XCTAssertEqual(matches, rounds * 2, "every round must have compared equal")
            let report = "onChange comparisons (\(Self.renders * 2)): "
                + "\(Int(deep * 1000)) ms deep, \(Int(shared * 1000)) ms shared-buffer."
            let attachment = XCTAttachment(string: report)
            attachment.name = "conversation-projection-onchange-comparisons"
            attachment.lifetime = .keepAlways
            add(attachment)
            print("[KitPayProjectionBudget] \(report)")
            XCTAssertLessThan(
                shared,
                deep / 5,
                "Handing back the same array is what makes `Array ==` short-circuit on buffer "
                    + "identity; without it every render deep-compares the whole thread. \(report)"
            )
        }
    }
#endif
