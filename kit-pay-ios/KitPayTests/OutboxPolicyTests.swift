import XCTest
@testable import KitPay

final class OutboxPolicyTests: XCTestCase {
    func testMediaCapabilityFailurePersistsBoundedWaitWithoutFailingMessage() throws {
        var state = try mediaCapabilityState()
        let originalMessages = state.messages
        let originalCommand = state.outbox[0]
        let error = SecureMessagingExchangeError.mediaMessageCapabilityUnavailable
        XCTAssertTrue(OutboxPolicy.isMediaMessageCapabilityUnavailable(error))
        XCTAssertFalse(OutboxPolicy.isMediaMessageCapabilityUnavailable(URLError(.notConnectedToInternet)))
        var attemptTime = now
        for expectedDelay: TimeInterval in [10, 20, 40, 80, 120, 120] {
            OutboxPolicy.scheduleRetry(
                for: state.outbox[0], in: &state, at: attemptTime,
                waitingForMediaCapability: OutboxPolicy.isMediaMessageCapabilityUnavailable(error)
            )
            XCTAssertEqual(state.outbox[0].nextAttemptAt, attemptTime.addingTimeInterval(expectedDelay))
            XCTAssertEqual(OutboxPolicy.mediaCapabilityWaitingReason(for: state.outbox[0]),
                           "Waiting for multi-attachment support")
            XCTAssertNil(state.outbox[0].failureDisposition)
            XCTAssertEqual(state.messages, originalMessages)
            XCTAssertEqual(state.outbox[0].id, originalCommand.id)
            XCTAssertEqual(state.outbox[0].messageId, originalCommand.messageId)
            XCTAssertEqual(state.outbox[0].recipientUserIds, originalCommand.recipientUserIds)
            attemptTime = state.outbox[0].nextAttemptAt
        }
        XCTAssertEqual(state.outbox[0].attemptCount, 6)
        XCTAssertNil(state.messages[0].failureReason)
        XCTAssertEqual(state.messages[0].state, .queued)
    }

    func testMediaCapabilityWaitingReasonSurvivesCommandCodableRoundTrip() throws {
        var state = try mediaCapabilityState()
        OutboxPolicy.scheduleRetry(for: state.outbox[0], in: &state, at: now, waitingForMediaCapability: true)
        let restored = try JSONDecoder().decode(OfflineCommand.self, from: JSONEncoder().encode(state.outbox[0]))
        XCTAssertEqual(restored, state.outbox[0])
        XCTAssertEqual(OutboxPolicy.mediaCapabilityWaitingReason(for: restored),
                       OutboxPolicy.mediaMessageWaitingReason)
        XCTAssertEqual(OutboxPolicy.nextWakeDate([restored], at: now), now.addingTimeInterval(10))
    }

    func testMediaCapabilityDueRetryRechecksAfterCachedDenial() throws {
        var state = try mediaCapabilityState()
        OutboxPolicy.markKnownUnavailableMediaBatches(in: &state, at: now)
        XCTAssertFalse(OutboxPolicy.shouldRecheckMediaCapability(for: state.outbox[0], at: now))
        OutboxPolicy.scheduleRetry(for: state.outbox[0], in: &state, at: now, waitingForMediaCapability: true)
        let waiting = state.outbox[0]
        XCTAssertFalse(OutboxPolicy.shouldRecheckMediaCapability(
            for: waiting, at: waiting.nextAttemptAt.addingTimeInterval(-0.001)
        ))
        XCTAssertTrue(OutboxPolicy.shouldRecheckMediaCapability(for: waiting, at: waiting.nextAttemptAt))
        XCTAssertTrue(OutboxPolicy.shouldRecheckMediaCapability(
            for: waiting, at: waiting.nextAttemptAt.addingTimeInterval(60)
        ))
        // A fresh server denial reinstates the marker with the next bounded deadline.
        OutboxPolicy.clearMediaCapabilityWaitingReason(for: waiting, in: &state)
        XCTAssertFalse(OutboxPolicy.shouldRecheckMediaCapability(for: state.outbox[0], at: waiting.nextAttemptAt))
        OutboxPolicy.scheduleRetry(for: state.outbox[0], in: &state,
            at: waiting.nextAttemptAt, waitingForMediaCapability: true)
        XCTAssertEqual(state.outbox[0].nextAttemptAt, waiting.nextAttemptAt.addingTimeInterval(20))
        XCTAssertFalse(OutboxPolicy.shouldRecheckMediaCapability(for: state.outbox[0], at: waiting.nextAttemptAt))
        XCTAssertTrue(OutboxPolicy.shouldRecheckMediaCapability(for: state.outbox[0], at: state.outbox[0].nextAttemptAt))
        let due = state.outbox[0].nextAttemptAt
        state.outbox[0].failureDisposition = .awaitingIdentityRefresh
        XCTAssertFalse(OutboxPolicy.shouldRecheckMediaCapability(for: state.outbox[0], at: due))
        state.outbox[0].failureDisposition = nil
        state.outbox[0].secureMessageFanout = mediaCapabilityFanout(for: state.outbox[0])
        XCTAssertFalse(OutboxPolicy.shouldRecheckMediaCapability(for: state.outbox[0], at: due))
    }

    func testMediaCapabilityWaitLetsLaterTextAndSingleAttachmentProgressUntilDeadline() throws {
        var state = try mediaCapabilityState()
        OutboxPolicy.scheduleRetry(for: state.outbox[0], in: &state, at: now, waitingForMediaCapability: true)
        let waiting = state.outbox[0]
        let text = command(id: "06000000-0000-4000-8000-000000000002", kind: .secureMessage,
                           createdAt: now.addingTimeInterval(-2), nextAttemptAt: now)
        let single = command(id: "06000000-0000-4000-8000-000000000003", kind: .secureMessage,
                             createdAt: now.addingTimeInterval(-1), nextAttemptAt: now)
        var singleMessage = message(for: single, conversationId: single.conversationId!)
        singleMessage.pendingAttachment = LocalPendingAttachment(mediaType: "image/jpeg", caption: "single")
        state.outbox += [text, single]
        state.messages += [message(for: text, conversationId: text.conversationId!), singleMessage]

        XCTAssertEqual(OutboxPolicy.readyCommands(state.outbox, at: now).map(\.id), [text.id])
        state.outbox.removeAll { $0.id == text.id }
        XCTAssertEqual(OutboxPolicy.readyCommands(state.outbox, at: now).map(\.id), [single.id])
        XCTAssertEqual(OutboxPolicy.readyCommands(state.outbox, at: waiting.nextAttemptAt).map(\.id), [waiting.id])
        XCTAssertEqual(OutboxPolicy.readyCommands(
            state.outbox, at: waiting.nextAttemptAt, preparingMediaCommandIDs: [waiting.id]
        ).map(\.id), [single.id])
        state.outbox.removeAll { $0.id == single.id }
        XCTAssertTrue(OutboxPolicy.readyCommands(state.outbox, at: now).isEmpty)
        XCTAssertEqual(OutboxPolicy.nextWakeDate(state.outbox, at: now), waiting.nextAttemptAt)
        XCTAssertEqual(OutboxPolicy.readyCommands(state.outbox, at: waiting.nextAttemptAt).map(\.id), [waiting.id])
    }

    func testMediaCapabilityStaleWaitNeverReleasesSealedCiphertext() throws {
        var state = try mediaCapabilityState()
        OutboxPolicy.scheduleRetry(for: state.outbox[0], in: &state, at: now, waitingForMediaCapability: true)
        state.outbox[0].secureMessageFanout = mediaCapabilityFanout(for: state.outbox[0])
        let sealed = state.outbox[0]
        let text = command(id: "06000000-0000-4000-8000-000000000002", kind: .secureMessage,
                           createdAt: now, nextAttemptAt: now)
        XCTAssertNil(OutboxPolicy.mediaCapabilityWaitingReason(for: sealed))
        for reservations: Set<UUID> in [[], [sealed.id]] {
            XCTAssertTrue(OutboxPolicy.readyCommands(
                [sealed, text], at: now, preparingMediaCommandIDs: reservations
            ).isEmpty)
            XCTAssertEqual(OutboxPolicy.nextWakeDate(
                [sealed, text], at: now, preparingMediaCommandIDs: reservations
            ), sealed.nextAttemptAt)
        }
        OutboxPolicy.clearMediaCapabilityWaitingReason(for: sealed, in: &state)
        XCTAssertEqual(state.outbox[0], sealed)
        OutboxPolicy.scheduleRetry(for: sealed, in: &state, at: now, waitingForMediaCapability: true)
        XCTAssertNil(state.outbox[0].lastFailureReason)
        XCTAssertEqual(state.outbox[0].secureMessageFanout, sealed.secureMessageFanout)
    }

    func testMediaCapabilityReasonClearingPreservesExactBatchAndRetryIdentity() throws {
        var state = try mediaCapabilityState()
        state.outbox[0].scheduledAt = now.addingTimeInterval(-60)
        OutboxPolicy.scheduleRetry(for: state.outbox[0], in: &state, at: now, waitingForMediaCapability: true)
        let waiting = state.outbox[0]
        let originalMessages = state.messages
        var expected = waiting
        expected.lastFailureReason = nil
        OutboxPolicy.clearMediaCapabilityWaitingReason(for: waiting, in: &state)
        XCTAssertEqual(state.outbox, [expected])
        XCTAssertEqual(state.messages, originalMessages)
        XCTAssertNil(OutboxPolicy.mediaCapabilityWaitingReason(for: state.outbox[0]))
        // The caller must use the refreshed whole command for the next guarded mutation.
        XCTAssertFalse(state.outbox.contains(waiting))
        XCTAssertTrue(state.outbox.contains(expected))
    }

    func testMediaCapabilityOrdinaryRetryClearsOnlyCapabilityPresentation() throws {
        var state = try mediaCapabilityState()
        OutboxPolicy.scheduleRetry(for: state.outbox[0], in: &state, at: now, waitingForMediaCapability: true)
        let waiting = state.outbox[0]
        let originalMessages = state.messages
        OutboxPolicy.scheduleRetry(for: waiting, in: &state, at: waiting.nextAttemptAt)
        var expected = waiting
        expected.attemptCount += 1
        expected.lastFailureReason = nil
        expected.nextAttemptAt = waiting.nextAttemptAt.addingTimeInterval(20)
        XCTAssertEqual(state.outbox, [expected])
        XCTAssertEqual(state.messages, originalMessages)
        XCTAssertNil(OutboxPolicy.mediaCapabilityWaitingReason(for: state.outbox[0]))
    }

    func testMediaCapabilityLegacyClassificationReleasesExistingBackoffWithoutChangingDeadlines() throws {
        var state = try mediaCapabilityState()
        state.outbox[0].attemptCount = 7
        state.outbox[0].nextAttemptAt = now.addingTimeInterval(113)
        let waiting = state.outbox[0]
        let originalMessages = state.messages
        let text = command(id: "06000000-0000-4000-8000-000000000002", kind: .secureMessage,
                           createdAt: now, nextAttemptAt: now)
        state.outbox.append(text)
        XCTAssertTrue(OutboxPolicy.readyCommands(state.outbox, at: now).isEmpty)
        XCTAssertEqual(OutboxPolicy.unmarkedMediaCapabilityWaitingIDs(in: state, at: now), [waiting.id])
        OutboxPolicy.markKnownUnavailableMediaBatches(in: &state, at: now)
        var expected = waiting
        expected.lastFailureReason = OutboxPolicy.mediaMessageWaitingReason
        XCTAssertEqual(state.outbox, [expected, text])
        XCTAssertEqual(state.messages, originalMessages)
        XCTAssertEqual(OutboxPolicy.readyCommands(state.outbox, at: now).map(\.id), [text.id])
        XCTAssertEqual(OutboxPolicy.nextWakeDate([state.outbox[0]], at: now), waiting.nextAttemptAt)
        XCTAssertTrue(OutboxPolicy.unmarkedMediaCapabilityWaitingIDs(in: state, at: now).isEmpty)
    }

    func testMediaCapabilityLegacyClassificationRejectsUnsafeOrAmbiguousProjections() throws {
        let original = try mediaCapabilityState()
        let exclusions: [(inout PersistedState) -> Void] = [
            { $0.profile = nil },
            { $0.profile = UserProfile(id: "different-user") },
            { $0.outbox[0].conversationId = "different-conversation" },
            { $0.outbox[0].conversationId = nil },
            { $0.outbox[0].messageId = nil },
            { $0.outbox[0].failureDisposition = .requiresUserRetry },
            { $0.outbox[0].failureDisposition = .awaitingSession },
            { $0.outbox[0].failureDisposition = .awaitingIdentityRefresh },
            { $0.outbox[0].lastFailureReason = "Other retry condition" },
            { $0.outbox[0].awaitingMediaPreprocessing = true },
            { $0.outbox[0].scheduledAt = self.now.addingTimeInterval(60)
              $0.outbox[0].nextAttemptAt = self.now.addingTimeInterval(60) },
            { $0.outbox[0].secureMessageFanout = self.mediaCapabilityFanout(for: $0.outbox[0]) },
            { $0.messages[0].isOutgoing = false },
            { $0.messages[0].state = .failed },
            { $0.messages[0].failureReason = "Message failed" },
            { $0.messages[0].serverMessageId = "accepted-message" },
            { $0.messages[0].sentAt = self.now },
            { $0.messages[0].pendingMediaBatch = nil },
            { $0.messages[0].pendingMediaBatch?.items.removeLast() },
            { $0.outbox.append($0.outbox[0]) },
            { $0.messages.append($0.messages[0]) },
            { state in
                var duplicate = self.command(id: "06000000-0000-4000-8000-000000000009",
                    kind: .secureMessage, createdAt: self.now, nextAttemptAt: self.now)
                duplicate.messageId = state.outbox[0].messageId
                state.outbox.append(duplicate)
            },
        ]
        for (index, invalidate) in exclusions.enumerated() {
            var state = original
            invalidate(&state)
            let commands = state.outbox, messages = state.messages
            XCTAssertTrue(OutboxPolicy.unmarkedMediaCapabilityWaitingIDs(in: state, at: now).isEmpty,
                          "Unsafe projection \(index) was classified")
            OutboxPolicy.markKnownUnavailableMediaBatches(in: &state, at: now)
            XCTAssertEqual(state.outbox, commands, "Unsafe projection \(index) was mutated")
            XCTAssertEqual(state.messages, messages)
        }
    }

    func testUnsealedUploadDoesNotDelayLaterTextOrAnotherConversation() {
        let uploading = command(
            id: "01000000-0000-4000-8000-000000000001",
            kind: .secureMessage,
            createdAt: now.addingTimeInterval(-20),
            nextAttemptAt: now.addingTimeInterval(-20)
        )
        let text = command(
            id: "01000000-0000-4000-8000-000000000002",
            kind: .secureMessage,
            createdAt: now.addingTimeInterval(-10),
            nextAttemptAt: now
        )
        var independent = command(
            id: "01000000-0000-4000-8000-000000000003",
            kind: .secureMessage,
            createdAt: now.addingTimeInterval(-5),
            nextAttemptAt: now
        )
        independent.conversationId = "conversation-2"
        let commands = [uploading, text, independent]

        XCTAssertEqual(OutboxPolicy.readyCommands(
            commands, at: now, preparingMediaCommandIDs: [uploading.id]
        ).map(\.id), [text.id, independent.id])
        XCTAssertEqual(OutboxPolicy.nextWakeDate(
            commands, at: now, preparingMediaCommandIDs: [uploading.id]
        ), now)
        // Releasing the worker reservation immediately returns a finished message to FIFO.
        XCTAssertEqual(OutboxPolicy.readyCommands(commands, at: now).map(\.id),
                       [uploading.id, independent.id])
    }

    func testInFlightMediaAloneDoesNotSpinImmediateWakeTimer() {
        let uploading = command(
            id: "02000000-0000-4000-8000-000000000001",
            kind: .secureMessage, createdAt: now, nextAttemptAt: now
        )
        XCTAssertTrue(OutboxPolicy.readyCommands(
            [uploading], at: now, preparingMediaCommandIDs: [uploading.id]
        ).isEmpty)
        XCTAssertNil(OutboxPolicy.nextWakeDate(
            [uploading], at: now, preparingMediaCommandIDs: [uploading.id]
        ))
    }

    func testSealedCiphertextKeepsRetryOrderingEvenWithStaleUploadReservation() {
        var sealed = command(
            id: "03000000-0000-4000-8000-000000000001",
            kind: .secureMessage,
            createdAt: now.addingTimeInterval(-1),
            nextAttemptAt: now.addingTimeInterval(30)
        )
        sealed.secureMessageFanout = SecureMessagingCommittedFanout(
            clientMessageID: sealed.messageId!.uuidString.lowercased(),
            conversationID: sealed.conversationId!,
            rosterRevision: "unchanged-roster",
            replyToMessageID: nil,
            rosterDevices: [],
            envelopes: []
        )
        let text = command(
            id: "03000000-0000-4000-8000-000000000002",
            kind: .secureMessage, createdAt: now, nextAttemptAt: now
        )
        XCTAssertTrue(OutboxPolicy.readyCommands(
            [sealed, text], at: now, preparingMediaCommandIDs: [sealed.id]
        ).isEmpty)
        XCTAssertEqual(OutboxPolicy.nextWakeDate(
            [sealed, text], at: now, preparingMediaCommandIDs: [sealed.id]
        ), sealed.nextAttemptAt)
    }

    func testMediaReservationCannotHideCallTerminationOrScheduledWake() {
        let termination = command(
            id: "04000000-0000-4000-8000-000000000001",
            kind: .callTermination, createdAt: now, nextAttemptAt: now
        )
        var scheduled = command(
            id: "04000000-0000-4000-8000-000000000002",
            kind: .secureMessage, createdAt: now, nextAttemptAt: now.addingTimeInterval(60)
        )
        scheduled.scheduledAt = scheduled.nextAttemptAt
        XCTAssertEqual(OutboxPolicy.readyCommands(
            [termination], at: now, preparingMediaCommandIDs: [termination.id]
        ).map(\.id), [termination.id])
        XCTAssertEqual(OutboxPolicy.nextWakeDate(
            [scheduled], at: now, preparingMediaCommandIDs: [scheduled.id]
        ), scheduled.scheduledAt)
    }

    func testSmallForegroundMediaUsesOneRequestWhileLargeAndBackgroundResume() {
        let limit = MessagingSendSchedulingPolicy.maximumImmediateUploadBytes
        for size: Int64 in [1, 200_000, limit] {
            XCTAssertFalse(MessagingSendSchedulingPolicy.usesResumableUpload(
                ciphertextByteSize: size, hasCheckpoint: false,
                advertisedChunkBytes: 5 * 1_024 * 1_024, isForeground: true
            ))
            XCTAssertTrue(MessagingSendSchedulingPolicy.usesResumableUpload(
                ciphertextByteSize: size, hasCheckpoint: false,
                advertisedChunkBytes: 5 * 1_024 * 1_024, isForeground: false
            ))
        }
        for size: Int64 in [-1, 0, limit + 1, 200 * 1_024 * 1_024] {
            XCTAssertTrue(MessagingSendSchedulingPolicy.usesResumableUpload(
                ciphertextByteSize: size, hasCheckpoint: false,
                advertisedChunkBytes: 5 * 1_024 * 1_024, isForeground: true
            ))
        }
    }

    func testExistingUploadCheckpointAlwaysKeepsItsTransportAndObjectIdentity() {
        for foreground in [true, false] {
            for advertised: Int? in [nil, 5 * 1_024 * 1_024] {
                XCTAssertTrue(MessagingSendSchedulingPolicy.usesResumableUpload(
                    ciphertextByteSize: 32, hasCheckpoint: true,
                    advertisedChunkBytes: advertised, isForeground: foreground
                ))
            }
        }
        XCTAssertFalse(MessagingSendSchedulingPolicy.usesResumableUpload(
            ciphertextByteSize: 200 * 1_024 * 1_024, hasCheckpoint: false,
            advertisedChunkBytes: nil, isForeground: false
        ))
    }

    func testForegroundUploadHintIsScopedAndInheritedByChildWork() async {
        XCTAssertFalse(MessagingSendSchedulingPolicy.isForegroundSend)
        await MessagingSendSchedulingPolicy.$isForegroundSend.withValue(true) {
            let child = Task {
                await Task.yield()
                return MessagingSendSchedulingPolicy.isForegroundSend
            }
            let inherited = await child.value
            XCTAssertTrue(inherited)
        }
        XCTAssertFalse(MessagingSendSchedulingPolicy.isForegroundSend)
    }

    func testNextWakeDateSchedulesDeferredOfflineMessagesForEncryption() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var unsafeMessage = command(
            id: "05000000-0000-0000-0000-000000000001",
            kind: .secureMessage,
            createdAt: now.addingTimeInterval(-2),
            nextAttemptAt: now.addingTimeInterval(-1)
        )
        unsafeMessage.secureMessageFanout = nil
        let call = command(
            id: "05000000-0000-0000-0000-000000000002",
            kind: .callAttempt,
            createdAt: now,
            nextAttemptAt: now.addingTimeInterval(12)
        )

        XCTAssertEqual(OutboxPolicy.nextWakeDate([unsafeMessage, call]), unsafeMessage.nextAttemptAt)
        XCTAssertEqual(OutboxPolicy.nextWakeDate([unsafeMessage]), unsafeMessage.nextAttemptAt)
        XCTAssertNil(OutboxPolicy.nextWakeDate([call]))
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testReadyCommandsExcludeEveryLegacyCallAttemptAndReplayMessagesOldestFirst() {
        let oldest = command(
            id: "10000000-0000-0000-0000-000000000001",
            kind: .secureMessage,
            createdAt: now.addingTimeInterval(-30),
            nextAttemptAt: now.addingTimeInterval(-1)
        )
        let exactBoundary = command(
            id: "10000000-0000-0000-0000-000000000002",
            kind: .callAttempt,
            createdAt: now.addingTimeInterval(-10),
            nextAttemptAt: now,
            expiresAt: now.addingTimeInterval(60)
        )
        let future = command(
            id: "10000000-0000-0000-0000-000000000003",
            kind: .callAttempt,
            createdAt: now.addingTimeInterval(-60),
            nextAttemptAt: now.addingTimeInterval(1),
            expiresAt: now.addingTimeInterval(60)
        )

        let ready = OutboxPolicy.readyCommands([exactBoundary, future, oldest], at: now)

        XCTAssertEqual(ready.map(\.id), [oldest.id])
    }

    func testLegacyCallAttemptsAreRemovedWithoutDeletingAuthenticatedHistory() {
        let legacy = command(
            id: "12000000-0000-0000-0000-000000000001",
            kind: .callAttempt,
            createdAt: now,
            nextAttemptAt: now,
            expiresAt: now.addingTimeInterval(600)
        )
        let messageCommand = command(
            id: "12000000-0000-0000-0000-000000000002",
            kind: .secureMessage,
            createdAt: now,
            nextAttemptAt: now
        )
        let terminalCommand = command(
            id: "12000000-0000-0000-0000-000000000003",
            kind: .callAttempt,
            createdAt: now.addingTimeInterval(-30),
            nextAttemptAt: now
        )
        var terminal = callRecord(for: terminalCommand, state: .completed)
        terminal.isDeferredAttempt = false
        var state = PersistedState.empty
        state.outbox = [legacy, messageCommand]
        state.calls = [callRecord(for: legacy, state: .queued), terminal]

        XCTAssertEqual(OutboxPolicy.removeLegacyCallAttempts(in: &state), 1)
        XCTAssertEqual(state.outbox.map(\.id), [messageCommand.id])
        XCTAssertEqual(state.calls.map(\.id), [terminal.id])
        XCTAssertEqual(OutboxPolicy.removeLegacyCallAttempts(in: &state), 0)
    }

    func testMessagesRemainFIFOWithinConversationAcrossRetryBackoff() {
        var olderRetry = command(
            id: "11000000-0000-0000-0000-000000000001",
            kind: .secureMessage,
            createdAt: now.addingTimeInterval(-30),
            nextAttemptAt: now.addingTimeInterval(30)
        )
        olderRetry.conversationId = "550e8400-e29b-41d4-a716-446655440001"
        var newerReady = command(
            id: "11000000-0000-0000-0000-000000000002",
            kind: .secureMessage,
            createdAt: now.addingTimeInterval(-20),
            nextAttemptAt: now.addingTimeInterval(-1)
        )
        newerReady.conversationId = olderRetry.conversationId
        var independentReady = command(
            id: "11000000-0000-0000-0000-000000000003",
            kind: .secureMessage,
            createdAt: now.addingTimeInterval(-10),
            nextAttemptAt: now.addingTimeInterval(-1)
        )
        independentReady.conversationId = "550e8400-e29b-41d4-a716-446655440002"

        XCTAssertEqual(
            OutboxPolicy.readyCommands(
                [newerReady, independentReady, olderRetry],
                at: now
            ).map(\.id),
            [independentReady.id]
        )
        XCTAssertEqual(
            OutboxPolicy.nextWakeDate([newerReady, olderRetry]),
            olderRetry.nextAttemptAt
        )

        olderRetry.nextAttemptAt = now
        XCTAssertEqual(
            OutboxPolicy.readyCommands([newerReady, olderRetry], at: now).map(\.id),
            [olderRetry.id]
        )
    }

    func testMessagingConversationIDsMustBeServerIssuedUUIDs() {
        XCTAssertEqual(
            OutboxPolicy.canonicalConversationID(" 550E8400-E29B-41D4-A716-446655440000 "),
            "550e8400-e29b-41d4-a716-446655440000"
        )
        XCTAssertNil(OutboxPolicy.canonicalConversationID("direct:550e8400-e29b-41d4-a716-446655440000"))
        XCTAssertNil(OutboxPolicy.canonicalConversationID("conversation-1"))
        XCTAssertNil(OutboxPolicy.canonicalConversationID(nil))
    }

    func testPrototypeMessageWithoutServerConversationIsQuarantined() {
        var invalid = command(
            id: "25000000-0000-0000-0000-000000000001",
            kind: .secureMessage,
            createdAt: now,
            nextAttemptAt: now
        )
        invalid.conversationId = "direct:550e8400-e29b-41d4-a716-446655440000"
        var canonical = command(
            id: "25000000-0000-0000-0000-000000000002",
            kind: .secureMessage,
            createdAt: now,
            nextAttemptAt: now
        )
        canonical.conversationId = "550e8400-e29b-41d4-a716-446655440001"
        var state = PersistedState.empty
        state.outbox = [invalid, canonical]
        state.messages = [
            message(for: invalid, conversationId: invalid.conversationId!),
            message(for: canonical, conversationId: canonical.conversationId!),
        ]

        XCTAssertEqual(
            OutboxPolicy.quarantineMessagesWithoutServerConversation(in: &state),
            1
        )

        XCTAssertEqual(state.outbox.map(\.id), [canonical.id])
        XCTAssertEqual(state.messages[0].state, .failed)
        XCTAssertEqual(state.messages[0].failureReason, OutboxPolicy.unavailableMessageFailure)
        XCTAssertEqual(state.messages[1].state, .queued)
        XCTAssertNil(state.messages[1].failureReason)
    }

    func testRetryUsesExponentialBackoffCappedAtTwoMinutes() {
        let queued = command(
            id: "30000000-0000-0000-0000-000000000001",
            kind: .secureMessage,
            createdAt: now,
            nextAttemptAt: now
        )
        var state = PersistedState.empty
        state.outbox = [queued]
        let expectedDelays: [TimeInterval] = [10, 20, 40, 80, 120, 120]

        for (offset, expectedDelay) in expectedDelays.enumerated() {
            let failureTime = now.addingTimeInterval(TimeInterval(offset * 1_000))
            OutboxPolicy.scheduleRetry(for: queued, in: &state, at: failureTime)
            XCTAssertEqual(state.outbox[0].attemptCount, offset + 1)
            XCTAssertEqual(
                state.outbox[0].nextAttemptAt,
                failureTime.addingTimeInterval(expectedDelay)
            )
        }
    }

    func testRetryHonorsLongerBoundedServerGuidance() {
        let queued = command(
            id: "31000000-0000-0000-0000-000000000001",
            kind: .secureMessage,
            createdAt: now,
            nextAttemptAt: now
        )
        var state = PersistedState.empty
        state.outbox = [queued]

        OutboxPolicy.scheduleRetry(
            for: queued,
            in: &state,
            at: now,
            retryAfter: 45
        )

        XCTAssertEqual(state.outbox[0].nextAttemptAt, now.addingTimeInterval(45))
        XCTAssertEqual(state.outbox[0].attemptCount, 1)
    }

    func testRetryHonorsServerGuidanceBeyondTheClientBackoffCeiling() {
        let queued = command(
            id: "31000000-0000-0000-0000-000000000002",
            kind: .secureMessage,
            createdAt: now,
            nextAttemptAt: now
        )
        var state = PersistedState.empty
        state.outbox = [queued]

        OutboxPolicy.scheduleRetry(for: queued, in: &state, at: now, retryAfter: 600)

        XCTAssertEqual(state.outbox[0].nextAttemptAt, now.addingTimeInterval(600))
    }

    func testRetryBoundsAnImplausibleServerRequestedDelay() {
        let queued = command(
            id: "31000000-0000-0000-0000-000000000003",
            kind: .secureMessage,
            createdAt: now,
            nextAttemptAt: now
        )
        var state = PersistedState.empty
        state.outbox = [queued]

        OutboxPolicy.scheduleRetry(for: queued, in: &state, at: now, retryAfter: 86_400)

        XCTAssertEqual(
            state.outbox[0].nextAttemptAt,
            now.addingTimeInterval(OutboxPolicy.maximumServerRequestedDelay)
        )
    }

    func testRetryIgnoresServerGuidanceShorterThanTheClientBackoff() {
        let queued = command(
            id: "31000000-0000-0000-0000-000000000004",
            kind: .secureMessage,
            createdAt: now,
            nextAttemptAt: now
        )
        var state = PersistedState.empty
        state.outbox = [queued]

        OutboxPolicy.scheduleRetry(for: queued, in: &state, at: now, retryAfter: 1)

        XCTAssertEqual(state.outbox[0].nextAttemptAt, now.addingTimeInterval(10))
    }

    func testPermanentMessageFailureStopsAutomaticReplayWithoutBlockingNewerMessages() {
        var failed = command(
            id: "32000000-0000-0000-0000-000000000001",
            kind: .secureMessage,
            createdAt: now.addingTimeInterval(-10),
            nextAttemptAt: now
        )
        failed.conversationId = "550e8400-e29b-41d4-a716-446655440000"
        var newer = command(
            id: "32000000-0000-0000-0000-000000000002",
            kind: .secureMessage,
            createdAt: now,
            nextAttemptAt: now
        )
        newer.conversationId = failed.conversationId
        var state = PersistedState.empty
        state.outbox = [failed, newer]
        state.messages = [
            message(for: failed, conversationId: failed.conversationId!),
            message(for: newer, conversationId: newer.conversationId!),
        ]

        OutboxPolicy.markPermanentFailure(
            for: failed,
            reason: "This conversation is no longer available.",
            in: &state
        )

        XCTAssertEqual(state.outbox[0].failureDisposition, .requiresUserRetry)
        XCTAssertEqual(state.messages[0].state, .failed)
        XCTAssertEqual(
            OutboxPolicy.readyCommands(state.outbox, at: now).map(\.id),
            [newer.id]
        )
        XCTAssertNil(OutboxPolicy.nextWakeDate([state.outbox[0]]))
    }

    func testExplicitRetryResumesOnlyTheSelectedFailedMessage() {
        let failed = command(
            id: "33000000-0000-0000-0000-000000000001",
            kind: .secureMessage,
            createdAt: now,
            nextAttemptAt: now
        )
        var state = PersistedState.empty
        state.outbox = [failed]
        state.messages = [message(for: failed, conversationId: failed.conversationId!)]
        OutboxPolicy.markPermanentFailure(
            for: failed,
            reason: "Blocked",
            in: &state
        )

        XCTAssertTrue(OutboxPolicy.canRetryMessage(failed.messageId!, in: state.outbox))
        XCTAssertTrue(
            OutboxPolicy.resumeFailedMessage(
                messageID: failed.messageId!,
                in: &state,
                at: now.addingTimeInterval(1)
            )
        )
        XCTAssertNil(state.outbox[0].failureDisposition)
        XCTAssertNil(state.outbox[0].lastFailureReason)
        XCTAssertEqual(state.outbox[0].attemptCount, 0)
        XCTAssertEqual(state.messages[0].state, .queued)
        XCTAssertNil(state.messages[0].failureReason)
    }

    func testSessionFailuresPauseUntilAuthenticatedResume() {
        let queued = command(
            id: "34000000-0000-0000-0000-000000000001",
            kind: .secureMessage,
            createdAt: now,
            nextAttemptAt: now
        )
        var state = PersistedState.empty
        state.outbox = [queued]

        OutboxPolicy.markAwaitingSession(
            for: queued,
            reason: "Sign in again to continue.",
            in: &state
        )

        XCTAssertTrue(OutboxPolicy.readyCommands(state.outbox, at: now).isEmpty)
        XCTAssertNil(OutboxPolicy.nextWakeDate(state.outbox))
        XCTAssertEqual(
            OutboxPolicy.resumeSessionDeferredCommands(
                in: &state,
                at: now.addingTimeInterval(2)
            ),
            1
        )
        XCTAssertEqual(
            OutboxPolicy.readyCommands(state.outbox, at: now.addingTimeInterval(2)).map(\.id),
            [queued.id]
        )
    }

    func testIdentityFailuresResumeOnlyAfterThatRecipientsLifecycleEvent() {
        let changedRecipient = "10000000-0000-4000-8000-000000000001"
        let otherRecipient = "10000000-0000-4000-8000-000000000002"
        var affected = command(
            id: "34000000-0000-0000-0000-000000000011",
            kind: .secureMessage,
            createdAt: now,
            nextAttemptAt: now,
            recipientUserIds: [changedRecipient]
        )
        affected.conversationId = "550e8400-e29b-41d4-a716-446655440011"
        var unrelated = command(
            id: "34000000-0000-0000-0000-000000000012",
            kind: .secureMessage,
            createdAt: now,
            nextAttemptAt: now,
            recipientUserIds: [otherRecipient]
        )
        unrelated.conversationId = "550e8400-e29b-41d4-a716-446655440012"
        var state = PersistedState.empty
        state.outbox = [affected, unrelated]
        state.messages = [
            message(for: affected, conversationId: affected.conversationId!),
            message(for: unrelated, conversationId: unrelated.conversationId!),
        ]
        let reason = SecureMessagingCryptoError.identityChanged.localizedDescription
        OutboxPolicy.markAwaitingIdentityRefresh(for: affected, reason: reason, in: &state)
        OutboxPolicy.markAwaitingIdentityRefresh(for: unrelated, reason: reason, in: &state)

        XCTAssertEqual(
            OutboxPolicy.failureDecision(for: SecureMessagingCryptoError.identityChanged),
            .awaitIdentityRefresh
        )
        XCTAssertEqual(
            OutboxPolicy.resumeIdentityDeferredCommands(
                forRecipientUserID: changedRecipient,
                in: &state,
                at: now.addingTimeInterval(2)
            ),
            1
        )
        XCTAssertNil(state.outbox[0].failureDisposition)
        XCTAssertEqual(state.messages[0].state, .queued)
        XCTAssertEqual(state.outbox[1].failureDisposition, .awaitingIdentityRefresh)
        XCTAssertEqual(state.messages[1].state, .queued)
        XCTAssertNil(state.messages[1].failureReason)
        XCTAssertEqual(
            OutboxPolicy.readyCommands(state.outbox, at: now.addingTimeInterval(2)).map(\.id),
            [affected.id]
        )
    }

    func testFailureClassificationRetriesOnlyTransientConditions() {
        XCTAssertEqual(
            OutboxPolicy.failureDecision(
                for: APIErrorPayload(
                    code: "TOO_MANY_REQUESTS",
                    message: "Wait",
                    httpStatus: 429,
                    retryAfter: 30
                )
            ),
            .retry(after: 30)
        )
        XCTAssertEqual(
            OutboxPolicy.failureDecision(
                for: APIErrorPayload(
                    code: "CONVERSATION_NOT_FOUND",
                    message: "Missing",
                    httpStatus: 404
                )
            ),
            .permanent
        )
        XCTAssertEqual(
            OutboxPolicy.failureDecision(
                for: APIErrorPayload(
                    code: "CALL_ATTEMPT_NOT_EXPIRED",
                    message: "Wait for the original ringing window to close.",
                    httpStatus: 422,
                    retryAfter: 7
                )
            ),
            .retry(after: 7)
        )
        XCTAssertEqual(
            OutboxPolicy.failureDecision(for: APIClientError.signedOut),
            .awaitSession
        )
        XCTAssertEqual(
            OutboxPolicy.failureDecision(
                for: APIErrorPayload(
                    code: "CALL_ATTEMPT_NOT_EXPIRED",
                    message: "Unauthenticated",
                    httpStatus: 401,
                    retryAfter: 30
                )
            ),
            .awaitSession
        )
        XCTAssertEqual(
            OutboxPolicy.failureDecision(for: URLError(.networkConnectionLost)),
            .retry(after: nil)
        )
        XCTAssertEqual(
            OutboxPolicy.failureDecision(for: APIClientError.invalidURL),
            .permanent
        )
        XCTAssertEqual(
            OutboxPolicy.failureDecision(
                for: SecureMessagingActivationError.incompleteServerStatus
            ),
            .retry(after: nil)
        )
        XCTAssertEqual(
            OutboxPolicy.failureDecision(
                for: SecureMessagingActivationError.replenishmentRejected
            ),
            .retry(after: nil)
        )
        XCTAssertEqual(
            OutboxPolicy.failureDecision(
                for: SecureMessagingActivationError.accountChanged
            ),
            .retry(after: nil),
            "A replacement account is already authenticated, so waiting for another login would strand its command."
        )
        for activationError in [
            SecureMessagingActivationError.invalidUser,
            .missingLocalEnrollment,
            .serverEnrollmentChanged,
        ] {
            XCTAssertEqual(
                OutboxPolicy.failureDecision(for: activationError),
                .awaitSession
            )
        }
        XCTAssertEqual(
            OutboxPolicy.failureDecision(
                for: SecureMessagingExchangeError.groupCapabilityUnavailable
            ),
            .retry(after: nil)
        )
        XCTAssertEqual(
            OutboxPolicy.failureDecision(
                for: SecureMessagingExchangeError.richMediaCapabilityUnavailable
            ),
            .retry(after: nil)
        )
        XCTAssertEqual(
            OutboxPolicy.failureDecision(
                for: SecureMessagingExchangeError.mediaMessageCapabilityUnavailable
            ),
            .retry(after: nil)
        )
        XCTAssertEqual(
            OutboxPolicy.failureDecision(for: SecureMediaAttachmentError.incompatibleRecipient),
            .retry(after: nil)
        )
        XCTAssertEqual(
            OutboxPolicy.failureDecision(for: SecureMediaAttachmentError.invalidMedia),
            .permanent
        )
        XCTAssertEqual(
            OutboxPolicy.failureDecision(
                for: SecureMessagingExchangeError.reactionCapabilityUnavailable
            ),
            .permanent
        )
    }

    func testUnsupportedReactionIsRetiredWithoutBlockingLaterText() throws {
        let now = Date(timeIntervalSince1970: 1_777_777_777)
        let reactionMessageID = UUID()
        let laterMessageID = UUID()
        let reaction = try XCTUnwrap(
            KitMessageReaction(
                operation: .add,
                targetServerMessageID: UUID().uuidString.lowercased(),
                emoji: "👍"
            )
        )
        var reactionCommand = command(
            id: reactionMessageID.uuidString,
            kind: .secureMessage,
            createdAt: now,
            nextAttemptAt: now
        )
        reactionCommand.conversationId = "550e8400-e29b-41d4-a716-446655440000"
        var laterCommand = command(
            id: laterMessageID.uuidString,
            kind: .secureMessage,
            createdAt: now.addingTimeInterval(1),
            nextAttemptAt: now.addingTimeInterval(1)
        )
        laterCommand.conversationId = reactionCommand.conversationId
        var state = PersistedState.empty
        state.messages = [
            LocalMessage(
                id: reactionMessageID,
                conversationId: reactionCommand.conversationId!,
                senderId: "current-user",
                body: reaction.encoded,
                createdAt: now,
                sentAt: nil,
                state: .queued,
                failureReason: nil,
                isOutgoing: true
            ),
            LocalMessage(
                id: laterMessageID,
                conversationId: laterCommand.conversationId!,
                senderId: "current-user",
                body: "still sends",
                createdAt: now.addingTimeInterval(1),
                sentAt: nil,
                state: .queued,
                failureReason: nil,
                isOutgoing: true
            ),
        ]
        state.outbox = [reactionCommand, laterCommand]

        OutboxPolicy.markPermanentFailure(
            for: reactionCommand,
            reason: SecureMessagingExchangeError.reactionCapabilityUnavailable.localizedDescription,
            in: &state
        )

        XCTAssertEqual(state.outbox.map(\.id), [laterCommand.id])
        XCTAssertEqual(state.messages.map(\.id), [laterMessageID])
        XCTAssertEqual(
            OutboxPolicy.readyCommands(state.outbox, at: now.addingTimeInterval(2)).map(\.id),
            [laterCommand.id]
        )
    }

    func testLegacyOutboxCommandDecodesWithoutFailureDispositionFields() throws {
        let original = command(
            id: "35000000-0000-0000-0000-000000000001",
            kind: .secureMessage,
            createdAt: now,
            nextAttemptAt: now
        )
        let encoded = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "failureDisposition")
        object.removeValue(forKey: "lastFailureReason")

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let restored = try JSONDecoder().decode(OfflineCommand.self, from: legacyData)

        XCTAssertEqual(restored.id, original.id)
        XCTAssertNil(restored.failureDisposition)
        XCTAssertNil(restored.lastFailureReason)
    }

    func testAcknowledgedTerminationClearsAllMatchingReplaysAndPreservesTerminalHistory() {
        let callID = "550e8400-e29b-41d4-a716-446655440000"
        var decline = command(
            id: "45000000-0000-0000-0000-000000000001",
            kind: .callTermination,
            createdAt: now,
            nextAttemptAt: now
        )
        decline.callId = callID
        decline.terminationKind = .decline
        var staleEnd = command(
            id: "45000000-0000-0000-0000-000000000002",
            kind: .callTermination,
            createdAt: now,
            nextAttemptAt: now
        )
        staleEnd.callId = callID.uppercased()
        staleEnd.terminationKind = .end
        let unrelated = command(
            id: "45000000-0000-0000-0000-000000000003",
            kind: .secureMessage,
            createdAt: now,
            nextAttemptAt: now.addingTimeInterval(30)
        )
        var state = PersistedState.empty
        state.outbox = [decline, staleEnd, unrelated]
        state.calls = [
            CallRecord(
                id: callID,
                name: "Alice",
                participantUserIds: [],
                direction: "incoming",
                type: "voice",
                video: false,
                state: .ringing,
                startedAt: now.addingTimeInterval(-10),
                endedAt: nil,
                isDeferredAttempt: false
            ),
        ]

        OutboxPolicy.acknowledgeTermination(
            callId: callID,
            kind: .decline,
            in: &state,
            at: now
        )

        XCTAssertEqual(state.outbox.map(\.id), [unrelated.id])
        XCTAssertEqual(state.calls[0].state, .declined)
        XCTAssertEqual(state.calls[0].endedAt, now)

        state.calls[0].state = .missed
        let authoritativeEnd = now.addingTimeInterval(-1)
        state.calls[0].endedAt = authoritativeEnd
        OutboxPolicy.acknowledgeTermination(
            callId: callID,
            kind: .decline,
            in: &state,
            at: now.addingTimeInterval(1)
        )
        XCTAssertEqual(state.calls[0].state, .missed)
        XCTAssertEqual(state.calls[0].endedAt, authoritativeEnd)
    }

    private func mediaCapabilityState() throws -> PersistedState {
        let queued = command(id: "06000000-0000-4000-8000-000000000001", kind: .secureMessage,
                             createdAt: now.addingTimeInterval(-3), nextAttemptAt: now)
        var batch = try KitMediaMessageV2OutboundBatch.queued(attachments: [
            .init(attachmentID: "07000000-0000-4000-8000-000000000001", mediaType: "image/jpeg",
                  plaintextByteSize: 128, localStorageKey: "08000000-0000-4000-8000-000000000001"),
            .init(attachmentID: "07000000-0000-4000-8000-000000000002", mediaType: "image/jpeg",
                  plaintextByteSize: 128, localStorageKey: "08000000-0000-4000-8000-000000000002"),
        ], rawCaption: "original caption", keyMaterialFactory: { Data(repeating: 7, count: 64) })
        batch.items[0] = try XCTUnwrap(batch.items[0].uploaded(
            storageKey: "09000000-0000-4000-8000-000000000001", ciphertextByteSize: 192,
            ciphertextSHA256: String(repeating: "a", count: 64)
        ))
        XCTAssertTrue(batch.isStructurallyValid)
        var pending = message(for: queued, conversationId: queued.conversationId!)
        pending.body = "original caption"
        pending.pendingMediaBatch = batch
        var state = PersistedState.empty
        state.profile = UserProfile(id: "current-user")
        state.outbox = [queued]
        state.messages = [pending]
        return state
    }

    private func mediaCapabilityFanout(for command: OfflineCommand) -> SecureMessagingCommittedFanout {
        SecureMessagingCommittedFanout(
            clientMessageID: command.messageId!.uuidString.lowercased(),
            conversationID: command.conversationId!, rosterRevision: "original-roster",
            replyToMessageID: nil, rosterDevices: [],
            envelopes: [.init(recipientDeviceID: "original-device", envelopeType: "message",
                              ciphertext: Data([7, 8, 9]))]
        )
    }

    private func command(
        id: String,
        kind: OfflineCommandKind,
        createdAt: Date,
        nextAttemptAt: Date,
        recipientUserIds: [String]? = ["recipient-1"],
        video: Bool? = false,
        expiresAt: Date? = nil
    ) -> OfflineCommand {
        OfflineCommand(
            id: UUID(uuidString: id)!,
            kind: kind,
            createdAt: createdAt,
            nextAttemptAt: nextAttemptAt,
            attemptCount: 0,
            conversationId: kind == .secureMessage ? "conversation-1" : nil,
            messageId: kind == .secureMessage ? UUID(uuidString: id)! : nil,
            recipientUserIds: recipientUserIds,
            recipientName: kind == .callAttempt ? "Offline recipient" : nil,
            video: video,
            expiresAt: expiresAt
        )
    }

    private func callRecord(for command: OfflineCommand, state: CallState) -> CallRecord {
        CallRecord(
            id: command.id.uuidString.lowercased(),
            name: "Offline recipient",
            participantUserIds: command.recipientUserIds ?? [],
            direction: "outgoing",
            type: command.video == true ? "video" : "voice",
            video: command.video == true,
            state: state,
            startedAt: command.createdAt,
            endedAt: nil,
            isDeferredAttempt: true
        )
    }

    private func message(for command: OfflineCommand, conversationId: String) -> LocalMessage {
        LocalMessage(
            id: command.messageId!,
            conversationId: conversationId,
            senderId: "current-user",
            body: "Locally encrypted text",
            createdAt: command.createdAt,
            sentAt: nil,
            state: .queued,
            failureReason: nil,
            isOutgoing: true
        )
    }

}
