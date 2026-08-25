import XCTest
@testable import KitPay

final class SecureMessagingCoordinatorTests: XCTestCase {
    private var temporaryDirectory: URL!

    func testVisibleConversationMessagingUsesAndroidForegroundCadence() {
        XCTAssertEqual(
            VisibleConversationMessagingPolicy.foregroundSyncInterval,
            2,
            accuracy: 0.001
        )
    }

    func testVisibleConversationReceiptRetryWaitsForCadenceUnlessSyncFindsNewBoundary() {
        let attempted = "20000000-0000-4000-8000-000000000001"
        let newer = "20000000-0000-4000-8000-000000000002"

        XCTAssertFalse(VisibleConversationMessagingPolicy.shouldPublishAfterSync(
            attemptedBoundary: attempted,
            currentBoundary: attempted
        ))
        XCTAssertTrue(VisibleConversationMessagingPolicy.shouldPublishAfterSync(
            attemptedBoundary: attempted,
            currentBoundary: newer
        ))
        XCTAssertTrue(VisibleConversationMessagingPolicy.shouldPublishAfterSync(
            attemptedBoundary: nil,
            currentBoundary: newer
        ))
        XCTAssertFalse(VisibleConversationMessagingPolicy.shouldPublishAfterSync(
            attemptedBoundary: attempted,
            currentBoundary: nil
        ))
    }

    func testVisibleConversationReadBoundaryUsesDurableUnreadProjection() throws {
        let conversationID = "10000000-0000-4000-8000-000000000010"
        let otherConversationID = "10000000-0000-4000-8000-000000000011"
        let olderID = "20000000-0000-4000-8000-000000000001"
        let newestID = "20000000-0000-4000-8000-000000000002"
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var conversation = Conversation(
            id: conversationID,
            title: "ExampleContact",
            participantUserIds: [],
            unreadCount: 2,
            updatedAt: base
        )
        let messages = [
            LocalMessage(
                id: try XCTUnwrap(UUID(uuidString: olderID)),
                serverMessageId: olderID,
                conversationId: conversationID,
                senderId: "peer",
                body: "older",
                createdAt: base,
                sentAt: base,
                state: .received,
                failureReason: nil,
                isOutgoing: false
            ),
            LocalMessage(
                id: UUID(),
                serverMessageId: "20000000-0000-4000-8000-000000000003",
                conversationId: conversationID,
                senderId: "owner",
                body: "outgoing",
                createdAt: base.addingTimeInterval(30),
                sentAt: nil,
                state: .sent,
                failureReason: nil,
                isOutgoing: true
            ),
            LocalMessage(
                id: UUID(),
                serverMessageId: "20000000-0000-4000-8000-000000000004",
                conversationId: otherConversationID,
                senderId: "other-peer",
                body: "other chat",
                createdAt: base.addingTimeInterval(40),
                sentAt: base.addingTimeInterval(40),
                state: .received,
                failureReason: nil,
                isOutgoing: false
            ),
            LocalMessage(
                id: try XCTUnwrap(UUID(uuidString: newestID)),
                serverMessageId: newestID,
                conversationId: conversationID,
                senderId: "peer",
                body: "newest",
                createdAt: base,
                sentAt: base,
                state: .received,
                failureReason: nil,
                isOutgoing: false
            ),
        ]

        XCTAssertEqual(
            VisibleConversationMessagingPolicy.newestUnreadIncomingServerMessageID(
                conversationID: conversationID,
                conversations: [conversation],
                messages: messages
            ),
            newestID
        )

        conversation.unreadCount = 0
        XCTAssertNil(
            VisibleConversationMessagingPolicy.newestUnreadIncomingServerMessageID(
                conversationID: conversationID,
                conversations: [conversation],
                messages: messages
            ),
            "A successful receipt clears the durable retry signal and stops duplicate POSTs"
        )
    }

    func testReadReceiptPreservesNewerInboundArrivingWhileResponseIsSuspended() async throws {
        let userID = "10000000-0000-4000-8000-000000000020"
        let peerID = "10000000-0000-4000-8000-000000000021"
        let conversationID = "30000000-0000-4000-8000-000000000020"
        let requestedID = "40000000-0000-4000-8000-000000000020"
        let concurrentID = "40000000-0000-4000-8000-000000000021"
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let store = try await makeStore(userID: userID)
        try await store.update { state in
            state.communicationOwnerUserID = userID
            state.conversations = [Conversation(
                id: conversationID,
                title: "ExampleContact",
                participantUserIds: [userID, peerID],
                unreadCount: 1,
                updatedAt: base
            )]
            state.messages = [LocalMessage(
                id: UUID(uuidString: requestedID)!,
                serverMessageId: requestedID,
                conversationId: conversationID,
                senderId: peerID,
                body: "first",
                createdAt: base,
                sentAt: base,
                state: .received,
                failureReason: nil,
                isOutgoing: false
            )]
        }
        let transport = SuspendedMessagingExchangeTransport(scenario: .readReceipt(
            MessagingReadReceiptDTO(
                conversationId: conversationID,
                userId: userID,
                lastReadMessageId: requestedID,
                readAt: "2026-08-20T12:00:00Z"
            )
        ))
        let coordinator = SecureMessagingExchangeCoordinator(
            transport: transport,
            store: store,
            engine: SecureMessagingCryptoEngine(),
            provisioningPreKeyCount: 1
        )

        let publication = Task {
            try await coordinator.markConversationRead(
                conversationID: conversationID,
                throughServerMessageID: requestedID,
                forUserID: userID
            )
        }
        try await transport.waitUntilRequestStarted()
        try await store.update { state in
            state.messages.append(LocalMessage(
                id: UUID(uuidString: concurrentID)!,
                serverMessageId: concurrentID,
                conversationId: conversationID,
                senderId: peerID,
                body: "arrived during receipt",
                createdAt: base.addingTimeInterval(1),
                sentAt: base.addingTimeInterval(1),
                state: .received,
                failureReason: nil,
                isOutgoing: false
            ))
            state.conversations[0].unreadCount += 1
            state.conversations[0].updatedAt = base.addingTimeInterval(1)
        }
        await transport.releaseRequest()
        try await publication.value

        let snapshot = await store.snapshot()
        let readRequestMessageIDs = await transport.readRequestMessageIDs()
        XCTAssertEqual(readRequestMessageIDs, [requestedID])
        XCTAssertEqual(snapshot.conversations.count, 1)
        XCTAssertEqual(snapshot.conversations.first?.unreadCount, 1)
        XCTAssertEqual(
            snapshot.messages.first(where: { $0.serverMessageId == requestedID })?.state,
            .read
        )
        XCTAssertEqual(
            snapshot.messages.first(where: { $0.serverMessageId == concurrentID })?.state,
            .received
        )
    }

    func testReadReceiptAcceptsKnownNewerCanonicalServerMarker() async throws {
        let userID = "10000000-0000-4000-8000-000000000030"
        let peerID = "10000000-0000-4000-8000-000000000031"
        let conversationID = "30000000-0000-4000-8000-000000000030"
        let requestedID = "40000000-0000-4000-8000-000000000030"
        let canonicalID = "40000000-0000-4000-8000-000000000031"
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let store = try await makeStore(userID: userID)
        try await store.update { state in
            state.communicationOwnerUserID = userID
            state.conversations = [Conversation(
                id: conversationID,
                title: "ExampleContact",
                participantUserIds: [userID, peerID],
                unreadCount: 2,
                updatedAt: base.addingTimeInterval(1)
            )]
            state.messages = [
                LocalMessage(
                    id: UUID(uuidString: requestedID)!,
                    serverMessageId: requestedID,
                    conversationId: conversationID,
                    senderId: peerID,
                    body: "first",
                    createdAt: base,
                    sentAt: base,
                    state: .received,
                    failureReason: nil,
                    isOutgoing: false
                ),
                LocalMessage(
                    id: UUID(uuidString: canonicalID)!,
                    serverMessageId: canonicalID,
                    conversationId: conversationID,
                    senderId: peerID,
                    body: "second",
                    createdAt: base.addingTimeInterval(1),
                    sentAt: base.addingTimeInterval(1),
                    state: .received,
                    failureReason: nil,
                    isOutgoing: false
                ),
            ]
        }
        let transport = SuspendedMessagingExchangeTransport(scenario: .readReceipt(
            MessagingReadReceiptDTO(
                conversationId: conversationID,
                userId: userID,
                lastReadMessageId: canonicalID,
                readAt: "2026-08-20T12:00:00Z"
            )
        ))
        await transport.releaseRequest()
        let coordinator = SecureMessagingExchangeCoordinator(
            transport: transport,
            store: store,
            engine: SecureMessagingCryptoEngine(),
            provisioningPreKeyCount: 1
        )

        try await coordinator.markConversationRead(
            conversationID: conversationID,
            throughServerMessageID: requestedID,
            forUserID: userID
        )

        let snapshot = await store.snapshot()
        let readRequestMessageIDs = await transport.readRequestMessageIDs()
        XCTAssertEqual(readRequestMessageIDs, [requestedID])
        XCTAssertEqual(snapshot.conversations.count, 1)
        XCTAssertEqual(snapshot.conversations.first?.unreadCount, 0)
        XCTAssertTrue(snapshot.messages.allSatisfy { $0.state == .read })
    }

    func testAuthenticatedCompanionDeviceMessageProjectsAsOutgoingWithoutUnreadState() throws {
        let userID = "10000000-0000-4000-8000-000000000040"
        let conversationID = "30000000-0000-4000-8000-000000000040"
        let messageID = "40000000-0000-4000-8000-000000000040"
        let clientMessageID = "50000000-0000-4000-8000-000000000040"
        let rosterRevision = "v1:sha256:\(String(repeating: "a", count: 64))"
        let sender = SecureMessagingRosterDevice(
            address: SecureMessagingAddress(
                userID: userID,
                serverDeviceID: "20000000-0000-4000-8000-000000000041",
                signalDeviceID: 2
            ),
            registrationID: 42,
            identityKeySHA256: String(repeating: "b", count: 64)
        )
        let envelope = SecureMessagingInboundEnvelope(
            messageID: messageID,
            clientMessageID: clientMessageID,
            conversationID: conversationID,
            rosterRevision: rosterRevision,
            replyToMessageID: nil,
            sender: sender,
            localRecipient: SecureMessagingAddress(
                userID: userID,
                serverDeviceID: "20000000-0000-4000-8000-000000000040",
                signalDeviceID: 1
            ),
            envelopeType: SecureMessagingEnvelopeType.message.rawValue,
            ciphertext: Data([1])
        )
        let dto = EncryptedMessageDTO(
            id: messageID,
            conversationId: conversationID,
            clientMessageId: clientMessageID,
            sender: EncryptedMessageSenderDTO(id: userID, name: "Secure User"),
            senderDeviceId: sender.address.serverDeviceID,
            senderEnrollmentEpoch: 2,
            senderSignalDeviceId: Int(sender.address.signalDeviceID),
            senderRegistrationId: Int(sender.registrationID),
            senderProtocolVersion: SecureMessagingWire.protocolVersion,
            senderBundleVersion: 1,
            senderIdentityKeySha256: sender.identityKeySHA256,
            rosterRevision: rosterRevision,
            kind: SecureMessagingMessageKind.encrypted.rawValue,
            replyToMessageId: nil,
            envelope: nil,
            attachments: [],
            reactions: [],
            sentAt: "2026-08-20T12:00:00Z",
            revokedAt: nil
        )

        let projected = try XCTUnwrap(
            SecureMessagingExchangeCoordinator.projectedInboundMessage(
                dto: dto,
                envelope: envelope,
                plaintext: "sent from my other phone",
                sentAt: Date(timeIntervalSince1970: 1_755_691_200),
                currentUserID: userID
            )
        )

        XCTAssertTrue(projected.isOutgoing)
        XCTAssertEqual(projected.state, .sent)
        XCTAssertEqual(projected.senderId, userID)
        XCTAssertEqual(projected.serverMessageId, messageID)
        XCTAssertEqual(projected.secureMessagingHistory?.senderDeviceID, sender.address.serverDeviceID)
    }

    func testAuthenticatedInboundAttachmentMismatchIsSuppressedAfterDecryption() throws {
        let currentUserID = "10000000-0000-4000-8000-000000000050"
        let peerUserID = "10000000-0000-4000-8000-000000000051"
        let conversationID = "30000000-0000-4000-8000-000000000050"
        let messageID = "40000000-0000-4000-8000-000000000050"
        let clientMessageID = "50000000-0000-4000-8000-000000000050"
        let rosterRevision = "v1:sha256:\(String(repeating: "c", count: 64))"
        let sender = SecureMessagingRosterDevice(
            address: SecureMessagingAddress(
                userID: peerUserID,
                serverDeviceID: "20000000-0000-4000-8000-000000000051",
                signalDeviceID: 2
            ),
            registrationID: 43,
            identityKeySHA256: String(repeating: "d", count: 64)
        )
        let envelope = SecureMessagingInboundEnvelope(
            messageID: messageID,
            clientMessageID: clientMessageID,
            conversationID: conversationID,
            rosterRevision: rosterRevision,
            replyToMessageID: nil,
            sender: sender,
            localRecipient: SecureMessagingAddress(
                userID: currentUserID,
                serverDeviceID: "20000000-0000-4000-8000-000000000050",
                signalDeviceID: 1
            ),
            envelopeType: SecureMessagingEnvelopeType.message.rawValue,
            ciphertext: Data([1])
        )
        let dto = EncryptedMessageDTO(
            id: messageID,
            conversationId: conversationID,
            clientMessageId: clientMessageID,
            sender: EncryptedMessageSenderDTO(id: peerUserID, name: "Peer"),
            senderDeviceId: sender.address.serverDeviceID,
            senderEnrollmentEpoch: 1,
            senderSignalDeviceId: Int(sender.address.signalDeviceID),
            senderRegistrationId: Int(sender.registrationID),
            senderProtocolVersion: SecureMessagingWire.protocolVersion,
            senderBundleVersion: 1,
            senderIdentityKeySha256: sender.identityKeySHA256,
            rosterRevision: rosterRevision,
            kind: SecureMessagingMessageKind.encryptedAttachment.rawValue,
            replyToMessageId: nil,
            envelope: nil,
            attachments: [],
            reactions: [],
            sentAt: "2026-08-20T12:00:00Z",
            revokedAt: nil
        )

        XCTAssertNil(try SecureMessagingExchangeCoordinator.projectedInboundMessage(
            dto: dto,
            envelope: envelope,
            plaintext: "the authenticated body contains no media descriptor",
            sentAt: Date(timeIntervalSince1970: 1_755_691_200),
            currentUserID: currentUserID
        ))
    }

    func testAuthenticatedInboundWhitespaceCannotDisguiseMediaWireMaterialAsText() throws {
        let currentUserID = "10000000-0000-4000-8000-000000000060"
        let peerUserID = "10000000-0000-4000-8000-000000000061"
        let conversationID = "30000000-0000-4000-8000-000000000060"
        let messageID = "40000000-0000-4000-8000-000000000060"
        let clientMessageID = "50000000-0000-4000-8000-000000000060"
        let rosterRevision = "v1:sha256:\(String(repeating: "e", count: 64))"
        let sender = SecureMessagingRosterDevice(
            address: SecureMessagingAddress(
                userID: peerUserID,
                serverDeviceID: "20000000-0000-4000-8000-000000000061",
                signalDeviceID: 2
            ),
            registrationID: 44,
            identityKeySHA256: String(repeating: "f", count: 64)
        )
        let envelope = SecureMessagingInboundEnvelope(
            messageID: messageID,
            clientMessageID: clientMessageID,
            conversationID: conversationID,
            rosterRevision: rosterRevision,
            replyToMessageID: nil,
            sender: sender,
            localRecipient: SecureMessagingAddress(
                userID: currentUserID,
                serverDeviceID: "20000000-0000-4000-8000-000000000060",
                signalDeviceID: 1
            ),
            envelopeType: SecureMessagingEnvelopeType.message.rawValue,
            ciphertext: Data([1])
        )
        let dto = EncryptedMessageDTO(
            id: messageID,
            conversationId: conversationID,
            clientMessageId: clientMessageID,
            sender: EncryptedMessageSenderDTO(id: peerUserID, name: "Peer"),
            senderDeviceId: sender.address.serverDeviceID,
            senderEnrollmentEpoch: 1,
            senderSignalDeviceId: Int(sender.address.signalDeviceID),
            senderRegistrationId: Int(sender.registrationID),
            senderProtocolVersion: SecureMessagingWire.protocolVersion,
            senderBundleVersion: 1,
            senderIdentityKeySha256: sender.identityKeySHA256,
            rosterRevision: rosterRevision,
            kind: SecureMessagingMessageKind.encrypted.rawValue,
            replyToMessageId: nil,
            envelope: nil,
            attachments: [],
            reactions: [],
            sentAt: "2026-08-20T12:00:00Z",
            revokedAt: nil
        )

        XCTAssertNil(try SecureMessagingExchangeCoordinator.projectedInboundMessage(
            dto: dto,
            envelope: envelope,
            plaintext: " \n\tKITMEDIA1:v=2&sk=private&key=do-not-display",
            sentAt: Date(timeIntervalSince1970: 1_755_691_200),
            currentUserID: currentUserID
        ))
    }

    func testProtectedCommunicationAdmissionInvalidatesEveryPreQuarantineLease() throws {
        let gate = ProtectedCommunicationAdmissionGate()
        let userID = "10000000-0000-4000-8000-000000000001"
        gate.restore(forAccountID: userID)
        let original = try XCTUnwrap(gate.lease(forAccountID: userID))
        XCTAssertTrue(gate.permits(original))

        gate.quarantine()
        XCTAssertFalse(gate.permits(original))
        XCTAssertThrowsError(try gate.withAuthorizedCommit(original) { true })

        gate.restore(forAccountID: userID)
        let recovered = try XCTUnwrap(gate.lease(forAccountID: userID))
        XCTAssertFalse(gate.permits(original))
        XCTAssertTrue(gate.permits(recovered))
        XCTAssertTrue(try gate.withAuthorizedCommit(recovered) { true })
    }

    func testTestFlightReleaseEnablesReviewedSecureMessagingPath() {
        XCTAssertTrue(SecureMessagingReleaseGate.enabled)
    }

    func testSuccessfulSyncClearsOnlyItsOwnVisibleError() {
        var ownership = SecureMessagingSyncErrorOwnership()
        let attempt = ownership.begin()
        let message = ownership.record(
            "Kit could not load this conversation. Please try again.",
            for: attempt
        )

        XCTAssertNil(ownership.resolve(attempt, visibleMessage: message))
        XCTAssertNil(ownership.errorMessage)
    }

    func testSuccessfulSyncPreservesAnewerUnrelatedVisibleError() {
        var ownership = SecureMessagingSyncErrorOwnership()
        let attempt = ownership.begin()
        _ = ownership.record(
            "Kit could not load this conversation. Please try again.",
            for: attempt
        )

        XCTAssertEqual(
            ownership.resolve(
                attempt,
                visibleMessage: "Connect to the internet to continue."
            ),
            "Connect to the internet to continue."
        )
        XCTAssertNil(ownership.errorMessage)
    }

    func testAccountChangeDiscardsPriorSyncErrorOwnership() {
        var ownership = SecureMessagingSyncErrorOwnership()
        let attempt = ownership.begin()
        let message = ownership.record(
            "Kit could not load this conversation. Please try again.",
            for: attempt
        )
        ownership.reset()

        XCTAssertEqual(ownership.resolve(attempt, visibleMessage: message), message)
        XCTAssertNil(ownership.errorMessage)
    }

    func testOlderSyncSuccessCannotClearNewerSyncFailure() {
        var ownership = SecureMessagingSyncErrorOwnership()
        let olderAttempt = ownership.begin()
        let newerAttempt = ownership.begin()
        let message = ownership.record(
            "Kit could not load this conversation. Please try again.",
            for: newerAttempt
        )

        XCTAssertEqual(
            ownership.resolve(olderAttempt, visibleMessage: message),
            message
        )
        XCTAssertEqual(ownership.errorAttempt, newerAttempt)
        XCTAssertEqual(ownership.errorMessage, message)
    }

    func testOlderSyncFailureCannotReplaceAnewerSuccessfulResult() {
        var ownership = SecureMessagingSyncErrorOwnership()
        let olderAttempt = ownership.begin()
        let newerAttempt = ownership.begin()
        XCTAssertNil(ownership.resolve(newerAttempt, visibleMessage: nil))

        XCTAssertNil(ownership.record(
            "Kit could not load this conversation. Please try again.",
            for: olderAttempt
        ))
        XCTAssertNil(ownership.errorMessage)
    }

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KitPayMessagingCoordinator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
        temporaryDirectory = nil
    }

    func testEnsureDirectConversationPersistsValidatedProjectionAndPreservesUnreadCount() async throws {
        let userID = "10000000-0000-4000-8000-000000000071"
        let peerID = "10000000-0000-4000-8000-000000000072"
        let conversationID = "30000000-0000-4000-8000-000000000071"
        let store = try await makeStore(userID: userID)
        var crypto = SecureMessagingPersistentState.empty
        crypto.enrollment = raceEnrollment(userID: userID)
        try await store.update { state in
            state.communicationOwnerUserID = userID
            state.secureMessaging = crypto
            state.conversations = [Conversation(
                id: conversationID,
                title: "Saved ExampleContact",
                participantUserIds: [userID, peerID],
                unreadCount: 9,
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )]
        }
        let response = directConversationDTO(
            id: conversationID,
            userID: userID,
            peerID: peerID,
            peerName: "ExampleContact"
        )
        let transport = SuspendedMessagingExchangeTransport(
            scenario: .createConversation(response)
        )
        let coordinator = SecureMessagingExchangeCoordinator(
            transport: transport,
            store: store,
            engine: SecureMessagingCryptoEngine(),
            provisioningPreKeyCount: 1
        )

        let conversation = try await coordinator.ensureDirectConversation(
            forUserID: userID,
            recipientUserID: peerID,
            title: "Fallback"
        )

        XCTAssertEqual(conversation.id, conversationID)
        XCTAssertEqual(conversation.title, "ExampleContact")
        XCTAssertEqual(conversation.unreadCount, 9)
        let createdMemberIDs = await transport.createdMemberIDs()
        XCTAssertEqual(createdMemberIDs, [[peerID]])
        let storedSnapshot = await store.snapshot()
        let stored = storedSnapshot.conversations
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].id, conversationID)
        XCTAssertEqual(stored[0].unreadCount, 9)
    }

    func testEnsureDirectConversationRejectsUnexpectedBoundConversationIDWithoutPersisting() async throws {
        let userID = "10000000-0000-4000-8000-000000000073"
        let peerID = "10000000-0000-4000-8000-000000000074"
        let returnedConversationID = "30000000-0000-4000-8000-000000000073"
        let expectedConversationID = "30000000-0000-4000-8000-000000000074"
        let store = try await makeStore(userID: userID)
        var crypto = SecureMessagingPersistentState.empty
        crypto.enrollment = raceEnrollment(userID: userID)
        try await store.update { state in
            state.communicationOwnerUserID = userID
            state.secureMessaging = crypto
        }
        let transport = SuspendedMessagingExchangeTransport(
            scenario: .createConversation(directConversationDTO(
                id: returnedConversationID,
                userID: userID,
                peerID: peerID,
                peerName: "ExampleContact"
            ))
        )
        let coordinator = SecureMessagingExchangeCoordinator(
            transport: transport,
            store: store,
            engine: SecureMessagingCryptoEngine(),
            provisioningPreKeyCount: 1
        )

        do {
            _ = try await coordinator.ensureDirectConversation(
                forUserID: userID,
                recipientUserID: peerID,
                title: "ExampleContact",
                expectedConversationID: expectedConversationID
            )
            XCTFail("A call-bound chat must not navigate to a different server conversation")
        } catch let error as SecureMessagingExchangeError {
            XCTAssertEqual(error, .invalidConversation)
        }
        let storedSnapshot = await store.snapshot()
        XCTAssertTrue(storedSnapshot.conversations.isEmpty)
    }

    func testFailedPublicationLeavesExactCrashRecoverableBundleForRepublish() async throws {
        let userID = "10000000-0000-0000-0000-000000000001"
        let store = try await makeStore(userID: userID)
        let firstTransport = ActivationTransportStub(
            statuses: [unenrolledStatus()],
            publications: [.failure]
        )
        let firstCoordinator = SecureMessagingCoordinator(
            transport: firstTransport,
            store: store,
            engine: SecureMessagingCryptoEngine(),
            provisioningPreKeyCount: 2
        )

        do {
            _ = try await firstCoordinator.activate(forUserID: userID)
            XCTFail("The injected publication failure must escape activation")
        } catch is ActivationTransportStub.Failure {
            // Expected. The durable pending bundle is asserted below.
        }

        let interrupted = await store.snapshot()
        let pendingState = try XCTUnwrap(interrupted.secureMessaging)
        let pendingBundle = try XCTUnwrap(pendingState.pendingPublication)
        XCTAssertNil(pendingState.enrollment)
        XCTAssertEqual(pendingState.transactionRevision, 1)
        let firstRequests = await firstTransport.publishedRequests()
        let firstRequest = try XCTUnwrap(firstRequests.first)

        let success = enrolledStatus(bundle: pendingBundle)
        let secondTransport = ActivationTransportStub(
            statuses: [unenrolledStatus()],
            publications: [.success(success)]
        )
        let restoredCoordinator = SecureMessagingCoordinator(
            transport: secondTransport,
            store: store,
            engine: SecureMessagingCryptoEngine(),
            provisioningPreKeyCount: 2
        )
        let activated = try await restoredCoordinator.activate(forUserID: userID)

        let secondRequests = await secondTransport.publishedRequests()
        let secondRequest = try XCTUnwrap(secondRequests.first)
        XCTAssertEqual(secondRequest, firstRequest)
        XCTAssertNil(activated.pendingPublication)
        XCTAssertNotNil(activated.enrollment)
        XCTAssertEqual(activated.transactionRevision, 2)
    }

    func testEnrolledServerWithoutLocalPrivateStateRequiresExactResetBeforeReplacement() async throws {
        let userID = "10000000-0000-0000-0000-000000000002"
        let store = try await makeStore(userID: userID)
        let transport = ActivationTransportStub(
            statuses: [recoverableEnrolledStatus()],
            publications: [.failure],
            resets: [.success(ResetMessagingEnrollmentDTO(
                deviceId: "20000000-0000-0000-0000-000000000002",
                previousEnrollmentEpoch: 4,
                enrollmentEpoch: 5,
                enrolled: false,
                resetApplied: true
            ))]
        )
        let coordinator = SecureMessagingCoordinator(
            transport: transport,
            store: store,
            engine: SecureMessagingCryptoEngine()
        )

        do {
            _ = try await coordinator.activate(forUserID: userID)
            XCTFail("The injected publication failure must escape after reset")
        } catch is ActivationTransportStub.Failure {
            // Expected.
        }
        let persisted = await store.snapshot()
        XCTAssertNotNil(persisted.secureMessaging?.pendingPublication)
        XCTAssertNil(persisted.secureMessaging?.enrollment)
        let resetRequests = await transport.resetRequests()
        XCTAssertEqual(resetRequests.first, try ResetMessagingEnrollmentRequest(
            expectedEnrollmentEpoch: 4,
            expectedRegistrationId: 42,
            expectedIdentityKeySha256: String(repeating: "a", count: 64),
            expectedBundleVersion: 7
        ))
        let publishedRequests = await transport.publishedRequests()
        XCTAssertEqual(publishedRequests.count, 1)
    }

    func testIdleSyncPageMayRepeatCursorButNonEmptyPageMayNot() throws {
        let cursor = "opaque-cursor"
        let empty = MessagingSyncDTO(
            events: [],
            page: CursorPage(nextCursor: cursor, hasMore: false, limit: 100)
        )
        let validated = try SecureMessagingExchangeCoordinator.validateSyncPage(
            empty,
            after: cursor
        )
        XCTAssertTrue(validated.events.isEmpty)
        XCTAssertEqual(validated.nextCursor, cursor)
        XCTAssertFalse(validated.hasMore)

        let replayedEvent = MessagingSyncDTO(
            events: [MessagingSyncEventDTO(
                id: "30000000-0000-0000-0000-000000000001",
                type: "conversation.created",
                conversationId: "40000000-0000-0000-0000-000000000001",
                resourceType: "conversation",
                resourceId: "40000000-0000-0000-0000-000000000001",
                data: nil,
                occurredAt: "2026-08-18T15:00:00Z"
            )],
            page: CursorPage(nextCursor: cursor, hasMore: false, limit: 100)
        )
        XCTAssertThrowsError(
            try SecureMessagingExchangeCoordinator.validateSyncPage(
                replayedEvent,
                after: cursor
            )
        )
    }

    func testSyncEventIDsMatchBackendPositiveDecimalContract() {
        for accepted in ["1", "9", "10", "9876543210123456789"] {
            XCTAssertTrue(
                SecureMessagingValidation.isCanonicalPositiveDecimalID(accepted),
                "Expected to accept \(accepted)"
            )
        }

        for rejected in ["", "0", "00", "01", "+1", "-1", "1.0", "1a", " 1", "1 "] {
            XCTAssertFalse(
                SecureMessagingValidation.isCanonicalPositiveDecimalID(rejected),
                "Expected to reject \(rejected)"
            )
        }
    }

    func testMessagingWakeAcceptsOnlyTheOpaqueBackendShape() throws {
        let notificationID = "50000000-0000-0000-0000-000000000001"
        let backgroundAPS: [AnyHashable: Any] = [
            "content-available": NSNumber(value: 1),
        ]
        let exact: [AnyHashable: Any] = [
            "scope": "messaging",
            "notification_id": notificationID,
            "type": "messaging.sync",
            "aps": backgroundAPS,
        ]
        XCTAssertEqual(
            SecureMessagingRemoteWake(exact)?.notificationID,
            UUID(uuidString: notificationID)
        )

        var unsafe = exact
        unsafe["sender_name"] = "Leaked sender"
        XCTAssertNil(SecureMessagingRemoteWake(unsafe))
        let alertAPS: [AnyHashable: Any] = [
            "alert": ["body": "Leaked message"],
        ]
        XCTAssertNil(SecureMessagingRemoteWake([
            "scope": "messaging",
            "notification_id": notificationID,
            "type": "messaging.sync",
            "aps": alertAPS,
        ] as [AnyHashable: Any]))
    }

    func testMessagingCapabilityRequiresTheExactReviewedSuite() {
        XCTAssertTrue(MessagingProtocolCapabilityDTO(
            ready: true,
            version: SecureMessagingWire.protocolVersion,
            suite: SecureMessagingWire.protocolSuite,
            postQuantum: true
        ).supportsReviewedV2)
        XCTAssertFalse(MessagingProtocolCapabilityDTO(
            ready: true,
            version: SecureMessagingWire.protocolVersion,
            suite: "signal-double-ratchet-v2",
            postQuantum: true
        ).supportsReviewedV2)
    }

    func testDeferredTextUpdatesChatOrderAndSurvivesRelaunchWithoutNetwork() async throws {
        let localUserID = "10000000-0000-0000-0000-000000000011"
        let recipientUserID = "10000000-0000-0000-0000-000000000012"
        let conversationID = "30000000-0000-0000-0000-000000000011"
        let store = try await makeStore(userID: localUserID)
        let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
        let draftWriterID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let draftClearVersion = ConversationDraftWriteVersion(
            writerID: draftWriterID,
            sequence: 2
        )
        var crypto = SecureMessagingPersistentState.empty
        crypto.enrollment = SecureMessagingEnrollmentBinding(
            userID: localUserID,
            serverDeviceID: "20000000-0000-0000-0000-000000000011",
            signalDeviceID: 1,
            registrationID: 42,
            enrollmentEpoch: 1,
            identityKeySHA256: String(repeating: "a", count: 64),
            bundleVersion: 1,
            signedPreKeyID: 5,
            signedPreKeySHA256: String(repeating: "b", count: 64),
            pqLastResortPreKeyID: 6,
            pqLastResortPreKeySHA256: String(repeating: "c", count: 64)
        )
        try await store.update { state in
            state.communicationOwnerUserID = localUserID
            state.secureMessaging = crypto
            state.conversations = [Conversation(
                id: conversationID,
                title: "ExampleContact",
                participantUserIds: [localUserID, recipientUserID],
                unreadCount: 0,
                updatedAt: originalDate
            )]
            state.conversationDrafts = [
                conversationID: ConversationDraft(
                    body: "  queued while offline  ",
                    updatedAt: originalDate,
                    writeVersion: ConversationDraftWriteVersion(
                        writerID: draftWriterID,
                        sequence: 1
                    )
                ),
            ]
        }
        let transport = OfflineExchangeTransport()
        let coordinator = SecureMessagingExchangeCoordinator(
            transport: transport,
            store: store,
            engine: SecureMessagingCryptoEngine(),
            provisioningPreKeyCount: 1
        )

        let result = try await coordinator.queueDeferredText(
            forUserID: localUserID,
            conversationID: conversationID,
            expectedRecipientUserID: recipientUserID,
            title: "ExampleContact",
            text: "  queued while offline  ",
            submittedDraftBody: "  queued while offline  ",
            draftClearVersion: draftClearVersion
        )
        let replay = try await coordinator.queueDeferredText(
            forUserID: localUserID,
            conversationID: conversationID,
            expectedRecipientUserID: recipientUserID,
            title: "ExampleContact",
            text: "queued while offline",
            clientMessageID: result.clientMessageID
        )
        do {
            _ = try await coordinator.queueDeferredText(
                forUserID: localUserID,
                conversationID: conversationID,
                expectedRecipientUserID: recipientUserID,
                title: "ExampleContact",
                text: "different reply using the same client ID",
                clientMessageID: result.clientMessageID
            )
            XCTFail("A stable client ID must never alias different plaintext")
        } catch let error as SecureMessagingExchangeError {
            XCTAssertEqual(error, .invalidConversation)
        }
        for invalidText in ["unsafe\u{0}message", String(repeating: "x", count: 8_001)] {
            do {
                _ = try await coordinator.queueDeferredText(
                    forUserID: localUserID,
                    conversationID: conversationID,
                    expectedRecipientUserID: recipientUserID,
                    title: "ExampleContact",
                    text: invalidText
                )
                XCTFail("Content rejected by the encrypted wire must not enter the outbox")
            } catch let error as SecureMessagingCryptoError {
                XCTAssertEqual(error, .invalidContent)
            }
        }

        let transportCallCount = await transport.networkCallCount()
        XCTAssertEqual(transportCallCount, 0)
        let snapshot = await store.snapshot()
        let message = try XCTUnwrap(snapshot.messages.first)
        let command = try XCTUnwrap(snapshot.outbox.first)
        let conversation = try XCTUnwrap(snapshot.conversations.first)
        XCTAssertEqual(result.clientMessageID, message.id)
        XCTAssertEqual(replay.clientMessageID, result.clientMessageID)
        XCTAssertEqual(snapshot.messages.count, 1)
        XCTAssertEqual(snapshot.outbox.count, 1)
        XCTAssertEqual(result.conversation.updatedAt, conversation.updatedAt)
        XCTAssertEqual(message.body, "queued while offline")
        XCTAssertEqual(message.state, .queued)
        XCTAssertEqual(command.messageId, message.id)
        XCTAssertNil(command.secureMessageFanout)
        XCTAssertGreaterThan(conversation.updatedAt, originalDate)
        XCTAssertEqual(snapshot.conversationDrafts?[conversationID]?.body, "")
        XCTAssertEqual(
            snapshot.conversationDrafts?[conversationID]?.writeVersion,
            draftClearVersion
        )

        let reopened = SecureLocalStore(
            stateURL: temporaryDirectory.appendingPathComponent("state.secure"),
            keyData: Data(repeating: 0x91, count: 32)
        )
        let restored = await reopened.snapshot()
        XCTAssertEqual(restored.messages.count, snapshot.messages.count)
        XCTAssertEqual(restored.conversationDrafts?[conversationID]?.body, "")
        XCTAssertEqual(
            restored.conversationDrafts?[conversationID]?.writeVersion,
            draftClearVersion
        )
        let restoredMessage = try XCTUnwrap(restored.messages.first(where: {
            $0.id == message.id
        }))
        XCTAssertEqual(restoredMessage.id, message.id)
        XCTAssertEqual(restoredMessage.serverMessageId, message.serverMessageId)
        XCTAssertEqual(restoredMessage.conversationId, message.conversationId)
        XCTAssertEqual(restoredMessage.senderId, message.senderId)
        XCTAssertEqual(restoredMessage.body, message.body)
        XCTAssertEqual(restoredMessage.sentAt, message.sentAt)
        XCTAssertEqual(restoredMessage.state, message.state)
        XCTAssertEqual(restoredMessage.failureReason, message.failureReason)
        XCTAssertEqual(restoredMessage.isOutgoing, message.isOutgoing)
        XCTAssertEqual(restoredMessage.attachmentData, message.attachmentData)
        XCTAssertLessThan(
            abs(restoredMessage.createdAt.timeIntervalSince(message.createdAt)),
            1
        )

        XCTAssertEqual(restored.outbox.count, snapshot.outbox.count)
        let restoredCommand = try XCTUnwrap(restored.outbox.first(where: {
            $0.id == command.id
        }))
        XCTAssertEqual(restoredCommand.id, command.id)
        XCTAssertEqual(restoredCommand.kind, command.kind)
        XCTAssertEqual(restoredCommand.attemptCount, command.attemptCount)
        XCTAssertEqual(restoredCommand.conversationId, command.conversationId)
        XCTAssertEqual(restoredCommand.messageId, command.messageId)
        XCTAssertEqual(restoredCommand.recipientUserIds, command.recipientUserIds)
        XCTAssertEqual(restoredCommand.recipientName, command.recipientName)
        XCTAssertEqual(restoredCommand.video, command.video)
        XCTAssertEqual(restoredCommand.expiresAt, command.expiresAt)
        XCTAssertEqual(restoredCommand.callId, command.callId)
        XCTAssertEqual(restoredCommand.terminationKind, command.terminationKind)
        XCTAssertEqual(restoredCommand.terminationReason, command.terminationReason)
        XCTAssertEqual(restoredCommand.secureMessageFanout, command.secureMessageFanout)
        XCTAssertLessThan(
            abs(restoredCommand.createdAt.timeIntervalSince(command.createdAt)),
            1
        )
        XCTAssertLessThan(
            abs(restoredCommand.nextAttemptAt.timeIntervalSince(command.nextAttemptAt)),
            1
        )

        XCTAssertEqual(restored.conversations.count, snapshot.conversations.count)
        let restoredConversation = try XCTUnwrap(restored.conversations.first(where: {
            $0.id == conversation.id
        }))
        XCTAssertEqual(restoredConversation.id, conversation.id)
        XCTAssertEqual(restoredConversation.title, conversation.title)
        XCTAssertEqual(
            restoredConversation.participantUserIds,
            conversation.participantUserIds
        )
        XCTAssertEqual(restoredConversation.unreadCount, conversation.unreadCount)
        XCTAssertLessThan(
            abs(restoredConversation.updatedAt.timeIntervalSince(conversation.updatedAt)),
            1
        )
    }

    func testFailedDurableQueueKeepsDraftAndDoesNotCreateMessageOrOutboxCommand() async throws {
        let localUserID = "10000000-0000-0000-0000-000000000021"
        let recipientUserID = "10000000-0000-0000-0000-000000000022"
        let conversationID = "30000000-0000-0000-0000-000000000021"
        let writerID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let store = try await makeStore(userID: localUserID)
        var crypto = SecureMessagingPersistentState.empty
        crypto.enrollment = raceEnrollment(
            userID: localUserID,
            serverDeviceID: "20000000-0000-4000-8000-000000000021"
        )
        try await store.update { state in
            state.communicationOwnerUserID = localUserID
            state.secureMessaging = crypto
            state.conversations = [Conversation(
                id: conversationID,
                title: "ExampleContact",
                participantUserIds: [localUserID, recipientUserID],
                unreadCount: 0,
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )]
            state.conversationDrafts = [
                conversationID: ConversationDraft(
                    body: "Keep this unsent draft",
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_001),
                    writeVersion: ConversationDraftWriteVersion(
                        writerID: writerID,
                        sequence: 1
                    )
                ),
            ]
        }
        let transport = OfflineExchangeTransport()
        let coordinator = SecureMessagingExchangeCoordinator(
            transport: transport,
            store: store,
            engine: SecureMessagingCryptoEngine(),
            provisioningPreKeyCount: 1
        )
        let stateURL = temporaryDirectory.appendingPathComponent("state.secure")
        try FileManager.default.removeItem(at: stateURL)
        try FileManager.default.createDirectory(
            at: stateURL,
            withIntermediateDirectories: false
        )

        do {
            _ = try await coordinator.queueDeferredText(
                forUserID: localUserID,
                conversationID: conversationID,
                expectedRecipientUserID: recipientUserID,
                title: "ExampleContact",
                text: "Keep this unsent draft",
                submittedDraftBody: "Keep this unsent draft",
                draftClearVersion: ConversationDraftWriteVersion(
                    writerID: writerID,
                    sequence: 2
                )
            )
            XCTFail("A failed encrypted state write must not report a durable queue")
        } catch {
            // Expected: the draft, message projection, and outbox command commit atomically.
        }

        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.conversationDrafts?[conversationID]?.body, "Keep this unsent draft")
        XCTAssertEqual(snapshot.conversationDrafts?[conversationID]?.writeVersion?.sequence, 1)
        XCTAssertTrue(snapshot.messages.isEmpty)
        XCTAssertTrue(snapshot.outbox.isEmpty)
        let networkCallCount = await transport.networkCallCount()
        XCTAssertEqual(networkCallCount, 0)
    }

    func testDeferredImagePersistsEncryptedLocalDraftWithoutNetwork() async throws {
        let localUserID = "10000000-0000-0000-0000-000000000013"
        let recipientUserID = "10000000-0000-0000-0000-000000000014"
        let conversationID = "30000000-0000-0000-0000-000000000013"
        let store = try await makeStore(userID: localUserID)
        var crypto = SecureMessagingPersistentState.empty
        crypto.enrollment = SecureMessagingEnrollmentBinding(
            userID: localUserID,
            serverDeviceID: "20000000-0000-0000-0000-000000000013",
            signalDeviceID: 1,
            registrationID: 42,
            enrollmentEpoch: 1,
            identityKeySHA256: String(repeating: "a", count: 64),
            bundleVersion: 1,
            signedPreKeyID: 5,
            signedPreKeySHA256: String(repeating: "b", count: 64),
            pqLastResortPreKeyID: 6,
            pqLastResortPreKeySHA256: String(repeating: "c", count: 64)
        )
        try await store.update { state in
            state.secureMessaging = crypto
            state.conversations = [Conversation(
                id: conversationID,
                title: "ExampleContact",
                participantUserIds: [localUserID, recipientUserID],
                unreadCount: 0,
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )]
        }
        let transport = OfflineExchangeTransport()
        let coordinator = SecureMessagingExchangeCoordinator(
            transport: transport,
            store: store,
            engine: SecureMessagingCryptoEngine(),
            provisioningPreKeyCount: 1
        )
        let jpeg = Data([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0xff, 0xd9])

        let result = try await coordinator.queueDeferredImage(
            forUserID: localUserID,
            conversationID: conversationID,
            expectedRecipientUserID: recipientUserID,
            title: "ExampleContact",
            mediaData: jpeg,
            mediaType: "image/jpeg",
            caption: "  Offline receipt  "
        )

        let networkCallCount = await transport.networkCallCount()
        XCTAssertEqual(networkCallCount, 0)
        let snapshot = await store.snapshot()
        let message = try XCTUnwrap(snapshot.messages.first)
        let command = try XCTUnwrap(snapshot.outbox.first)
        XCTAssertEqual(result.clientMessageID, message.id)
        XCTAssertEqual(message.body, "Offline receipt")
        XCTAssertEqual(message.attachmentData, jpeg)
        XCTAssertEqual(
            message.pendingAttachment,
            LocalPendingAttachment(
                mediaType: "image/jpeg",
                caption: "Offline receipt",
                byteCount: jpeg.count
            )
        )
        XCTAssertEqual(message.state, .queued)
        XCTAssertEqual(command.messageId, message.id)
        XCTAssertNil(command.secureMessageFanout)

        let reopened = SecureLocalStore(
            stateURL: temporaryDirectory.appendingPathComponent("state.secure"),
            keyData: Data(repeating: 0x91, count: 32)
        )
        let restored = await reopened.snapshot()
        XCTAssertEqual(restored.messages.count, 1)
        let restoredMessage = try XCTUnwrap(restored.messages.first)
        XCTAssertEqual(restoredMessage.id, message.id)
        XCTAssertEqual(restoredMessage.serverMessageId, message.serverMessageId)
        XCTAssertEqual(restoredMessage.conversationId, message.conversationId)
        XCTAssertEqual(restoredMessage.senderId, message.senderId)
        XCTAssertEqual(restoredMessage.body, message.body)
        XCTAssertEqual(restoredMessage.sentAt, message.sentAt)
        XCTAssertEqual(restoredMessage.state, message.state)
        XCTAssertEqual(restoredMessage.failureReason, message.failureReason)
        XCTAssertEqual(restoredMessage.isOutgoing, message.isOutgoing)
        XCTAssertEqual(restoredMessage.attachmentData, message.attachmentData)
        XCTAssertEqual(restoredMessage.pendingAttachment, message.pendingAttachment)
        XCTAssertLessThan(
            abs(restoredMessage.createdAt.timeIntervalSince(message.createdAt)),
            1
        )

        XCTAssertEqual(restored.outbox.count, 1)
        let restoredCommand = try XCTUnwrap(restored.outbox.first)
        XCTAssertEqual(restoredCommand.id, command.id)
        XCTAssertEqual(restoredCommand.kind, command.kind)
        XCTAssertEqual(restoredCommand.attemptCount, command.attemptCount)
        XCTAssertEqual(restoredCommand.conversationId, command.conversationId)
        XCTAssertEqual(restoredCommand.messageId, command.messageId)
        XCTAssertEqual(restoredCommand.recipientUserIds, command.recipientUserIds)
        XCTAssertEqual(restoredCommand.recipientName, command.recipientName)
        XCTAssertEqual(restoredCommand.video, command.video)
        XCTAssertEqual(restoredCommand.expiresAt, command.expiresAt)
        XCTAssertEqual(restoredCommand.callId, command.callId)
        XCTAssertEqual(restoredCommand.terminationKind, command.terminationKind)
        XCTAssertEqual(restoredCommand.terminationReason, command.terminationReason)
        XCTAssertEqual(restoredCommand.secureMessageFanout, command.secureMessageFanout)
        XCTAssertLessThan(
            abs(restoredCommand.createdAt.timeIntervalSince(command.createdAt)),
            1
        )
        XCTAssertLessThan(
            abs(restoredCommand.nextAttemptAt.timeIntervalSince(command.nextAttemptAt)),
            1
        )
    }

    func testDeferredImageCheckpointSurvivesRelaunchWithoutUploadingTwice() async throws {
        let localUserID = "10000000-0000-4000-8000-000000000017"
        let recipientUserID = "10000000-0000-4000-8000-000000000018"
        let conversationID = "30000000-0000-4000-8000-000000000017"
        let store = try await makeStore(userID: localUserID)
        let engine = SecureMessagingCryptoEngine()
        let provisioned = try await engine.provision(from: .empty, preKeyCount: 1)
        let status = enrolledStatus(bundle: provisioned.bundle)
        let binding = try SecureMessagingMapper.enrollmentBinding(
            from: status,
            userID: localUserID
        )
        let enrolled = try await engine.bindEnrollment(binding, to: provisioned.state)
        let localConversation = Conversation(
            id: conversationID,
            title: "ExampleContact",
            participantUserIds: [localUserID, recipientUserID],
            unreadCount: 0,
            updatedAt: Date(timeIntervalSince1970: 1_755_604_800)
        )
        try await store.update { state in
            state.secureMessaging = enrolled
            state.conversations = [localConversation]
        }
        let remoteConversation = MessagingConversationDTO(
            id: conversationID,
            type: SecureMessagingWire.directConversationType,
            title: nil,
            parentId: nil,
            createdBy: localUserID,
            role: "owner",
            members: [
                MessagingConversationMemberDTO(
                    userId: localUserID,
                    name: "Secure User",
                    role: "owner",
                    joinedAt: "2026-08-19T12:00:00Z"
                ),
                MessagingConversationMemberDTO(
                    userId: recipientUserID,
                    name: "ExampleContact",
                    role: "member",
                    joinedAt: "2026-08-19T12:00:00Z"
                ),
            ],
            createdAt: "2026-08-19T12:00:00Z",
            updatedAt: "2026-08-19T12:00:00Z"
        )
        let transport = DeferredImageCheckpointTransport(
            status: status,
            conversation: remoteConversation
        )
        let image = Data([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0xff, 0xd9])
        let coordinator = SecureMessagingExchangeCoordinator(
            transport: transport,
            store: store,
            engine: engine,
            provisioningPreKeyCount: 1
        )
        let queued = try await coordinator.queueDeferredImage(
            forUserID: localUserID,
            conversationID: conversationID,
            expectedRecipientUserID: recipientUserID,
            title: "ExampleContact",
            mediaData: image,
            mediaType: "image/jpeg",
            caption: "Receipt"
        )

        let queuedSnapshot = await store.snapshot()
        let queuedCommandID = try XCTUnwrap(queuedSnapshot.outbox.first?.id)
        do {
            _ = try await coordinator.prepareDeferredMessage(
                commandID: queuedCommandID,
                forUserID: localUserID
            )
            XCTFail("The injected roster outage must stop preparation after checkpointing")
        } catch let error as APIErrorPayload {
            XCTAssertEqual(error.code, "MESSAGING_TEMPORARILY_UNAVAILABLE")
        }

        let checkpointed = await store.snapshot()
        let message = try XCTUnwrap(checkpointed.messages.first(where: {
            $0.id == queued.clientMessageID
        }))
        let command = try XCTUnwrap(checkpointed.outbox.first)
        XCTAssertNil(message.pendingAttachment)
        XCTAssertNotNil(KitMediaMessageDescriptor.parse(message.body))
        XCTAssertEqual(message.attachmentData, image)
        XCTAssertNil(command.secureMessageFanout)
        let firstUploadCount = await transport.uploadCount()
        XCTAssertEqual(firstUploadCount, 1)

        let reopened = SecureLocalStore(
            stateURL: temporaryDirectory.appendingPathComponent("state.secure"),
            keyData: Data(repeating: 0x91, count: 32)
        )
        let restoredCoordinator = SecureMessagingExchangeCoordinator(
            transport: transport,
            store: reopened,
            engine: SecureMessagingCryptoEngine(),
            provisioningPreKeyCount: 1
        )
        do {
            _ = try await restoredCoordinator.prepareDeferredMessage(
                commandID: command.id,
                forUserID: localUserID
            )
            XCTFail("The injected roster outage must remain active after relaunch")
        } catch let error as APIErrorPayload {
            XCTAssertEqual(error.code, "MESSAGING_TEMPORARILY_UNAVAILABLE")
        }
        let restoredUploadCount = await transport.uploadCount()
        XCTAssertEqual(restoredUploadCount, 1)
        let restored = await reopened.snapshot()
        XCTAssertNil(restored.messages.first?.pendingAttachment)
        XCTAssertEqual(restored.messages.first?.body, message.body)
    }

    func testDeferredMediaCopyFailureKeepsOriginalPendingBlobReferenced() async throws {
        let localUserID = "10000000-0000-4000-8000-000000000019"
        let recipientUserID = "10000000-0000-4000-8000-000000000020"
        let conversationID = "30000000-0000-4000-8000-000000000019"
        let localStorageKey = "70000000-0000-4000-8000-000000000019"
        let messageID = UUID(uuidString: "80000000-0000-4000-8000-000000000019")!
        let commandID = UUID(uuidString: "90000000-0000-4000-8000-000000000019")!
        let media = Data([0xff, 0xd8, 0xff, 0xd9])
        let createdAt = Date(timeIntervalSince1970: 1_755_604_800)
        let store = try await makeStore(userID: localUserID)
        let engine = SecureMessagingCryptoEngine()
        let provisioned = try await engine.provision(from: .empty, preKeyCount: 1)
        let status = enrolledStatus(bundle: provisioned.bundle)
        let binding = try SecureMessagingMapper.enrollmentBinding(
            from: status,
            userID: localUserID
        )
        let enrolled = try await engine.bindEnrollment(binding, to: provisioned.state)
        let localConversation = Conversation(
            id: conversationID,
            title: "ExampleContact",
            participantUserIds: [localUserID, recipientUserID],
            unreadCount: 0,
            updatedAt: createdAt
        )
        let pendingMessage = LocalMessage(
            id: messageID,
            conversationId: conversationID,
            senderId: localUserID,
            body: "Photo",
            createdAt: createdAt,
            sentAt: nil,
            state: .queued,
            failureReason: nil,
            isOutgoing: true,
            attachmentData: nil,
            pendingAttachment: LocalPendingAttachment(
                mediaType: "image/jpeg",
                caption: nil,
                localStorageKey: localStorageKey,
                byteCount: media.count
            )
        )
        let pendingCommand = OfflineCommand(
            id: commandID,
            kind: .secureMessage,
            createdAt: createdAt,
            nextAttemptAt: createdAt,
            attemptCount: 0,
            conversationId: conversationID,
            messageId: messageID,
            recipientUserIds: [recipientUserID],
            recipientName: "ExampleContact",
            video: nil,
            expiresAt: nil,
            secureMessageFanout: nil
        )
        try await store.update { state in
            state.secureMessaging = enrolled
            state.conversations = [localConversation]
            state.messages = [pendingMessage]
            state.outbox = [pendingCommand]
        }
        let remoteConversation = MessagingConversationDTO(
            id: conversationID,
            type: SecureMessagingWire.directConversationType,
            title: nil,
            parentId: nil,
            createdBy: localUserID,
            role: "owner",
            members: [
                MessagingConversationMemberDTO(
                    userId: localUserID,
                    name: "Secure User",
                    role: "owner",
                    joinedAt: "2026-08-19T12:00:00Z"
                ),
                MessagingConversationMemberDTO(
                    userId: recipientUserID,
                    name: "ExampleContact",
                    role: "member",
                    joinedAt: "2026-08-19T12:00:00Z"
                ),
            ],
            createdAt: "2026-08-19T12:00:00Z",
            updatedAt: "2026-08-19T12:00:00Z"
        )
        let transport = DeferredImageCheckpointTransport(
            status: status,
            conversation: remoteConversation
        )
        let removals = BlobRemovalRecorder()
        let coordinator = SecureMessagingExchangeCoordinator(
            transport: transport,
            store: store,
            engine: engine,
            provisioningPreKeyCount: 1,
            mediaBlobs: SecureMediaBlobStoreAccess(
                read: { key, userID in
                    key == localStorageKey && userID == localUserID ? media : nil
                },
                copy: { _, _, _ in throw InjectedBlobCopyFailure.failed },
                remove: { key, _ in await removals.record(key) }
            )
        )

        do {
            _ = try await coordinator.prepareDeferredMessage(
                commandID: commandID,
                forUserID: localUserID
            )
            XCTFail("A failed cache copy must stop the descriptor checkpoint")
        } catch InjectedBlobCopyFailure.failed {
            // Expected.
        }

        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.messages, [pendingMessage])
        XCTAssertEqual(snapshot.outbox, [pendingCommand])
        let removedKeys = await removals.keys()
        XCTAssertTrue(removedKeys.isEmpty)
        let uploadCount = await transport.uploadCount()
        XCTAssertEqual(uploadCount, 1)
    }

    func testDeferredImageRejectsOversizedCaptionBeforeAnyNetworkOrWrite() async throws {
        let localUserID = "10000000-0000-0000-0000-000000000015"
        let recipientUserID = "10000000-0000-0000-0000-000000000016"
        let conversationID = "30000000-0000-0000-0000-000000000015"
        let store = try await makeStore(userID: localUserID)
        var crypto = SecureMessagingPersistentState.empty
        crypto.enrollment = SecureMessagingEnrollmentBinding(
            userID: localUserID,
            serverDeviceID: "20000000-0000-0000-0000-000000000015",
            signalDeviceID: 1,
            registrationID: 42,
            enrollmentEpoch: 1,
            identityKeySHA256: String(repeating: "a", count: 64),
            bundleVersion: 1,
            signedPreKeyID: 5,
            signedPreKeySHA256: String(repeating: "b", count: 64),
            pqLastResortPreKeyID: 6,
            pqLastResortPreKeySHA256: String(repeating: "c", count: 64)
        )
        try await store.update { state in
            state.secureMessaging = crypto
            state.conversations = [Conversation(
                id: conversationID,
                title: "ExampleContact",
                participantUserIds: [localUserID, recipientUserID],
                unreadCount: 0,
                updatedAt: Date()
            )]
        }
        let transport = OfflineExchangeTransport()
        let coordinator = SecureMessagingExchangeCoordinator(
            transport: transport,
            store: store,
            engine: SecureMessagingCryptoEngine(),
            provisioningPreKeyCount: 1
        )

        do {
            _ = try await coordinator.queueDeferredImage(
                forUserID: localUserID,
                conversationID: conversationID,
                expectedRecipientUserID: recipientUserID,
                title: "ExampleContact",
                mediaData: Data([1]),
                mediaType: "image/jpeg",
                caption: String(repeating: "x", count: 2_049)
            )
            XCTFail("An oversized caption must not enter the durable outbox")
        } catch SecureMediaAttachmentError.invalidMedia {
            // Expected.
        }

        let expandingCaption = String(repeating: "🧾", count: 512)
        XCTAssertEqual(
            expandingCaption.utf8.count,
            KitMediaMessageDescriptor.maximumCaptionUTF8Bytes
        )
        do {
            _ = try await coordinator.queueDeferredImage(
                forUserID: localUserID,
                conversationID: conversationID,
                expectedRecipientUserID: recipientUserID,
                title: "ExampleContact",
                mediaData: Data([1]),
                mediaType: "image/jpeg",
                caption: expandingCaption
            )
            XCTFail("A caption that cannot fit the canonical descriptor must fail before upload")
        } catch SecureMediaAttachmentError.invalidMedia {
            // Expected.
        }

        let networkCallCount = await transport.networkCallCount()
        XCTAssertEqual(networkCallCount, 0)
        let snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.messages.isEmpty)
        XCTAssertTrue(snapshot.outbox.isEmpty)
    }

    func testDeferredPreparationCannotCommitAfterItsCommandChanges() async throws {
        let fixture = try await makeDeferredPreparationRaceFixture()
        let preparation = Task {
            try await fixture.coordinator.prepareDeferredMessage(
                commandID: fixture.command.id,
                forUserID: fixture.userID
            )
        }
        try await fixture.transport.waitUntilRequestStarted()

        var replacementCommand = fixture.command
        replacementCommand.attemptCount += 1
        replacementCommand.nextAttemptAt = fixture.command.nextAttemptAt.addingTimeInterval(30)
        try await fixture.store.update { state in
            let index = try XCTUnwrap(state.outbox.firstIndex(where: {
                $0.id == fixture.command.id
            }))
            state.outbox[index] = replacementCommand
        }
        await fixture.transport.releaseRequest()

        do {
            _ = try await preparation.value
            XCTFail("A stale conversation response must not prepare a replaced command")
        } catch is CancellationError {
            // Expected: the delayed response no longer owns the pending projection.
        }

        let snapshot = await fixture.store.snapshot()
        XCTAssertEqual(snapshot.outbox, [replacementCommand])
        XCTAssertEqual(snapshot.messages, [fixture.message])
        XCTAssertNil(snapshot.outbox.first?.secureMessageFanout)
        let unexpectedCalls = await fixture.transport.unexpectedNetworkCallCount()
        XCTAssertEqual(unexpectedCalls, 0)
    }

    func testDeferredPreparationFailureCannotEscapeAfterItsCommandChanges() async throws {
        let fixture = try await makeDeferredPreparationRaceFixture(fails: true)
        let preparation = Task {
            try await fixture.coordinator.prepareDeferredMessage(
                commandID: fixture.command.id,
                forUserID: fixture.userID
            )
        }
        try await fixture.transport.waitUntilRequestStarted()

        var replacementCommand = fixture.command
        replacementCommand.attemptCount += 1
        replacementCommand.nextAttemptAt = fixture.command.nextAttemptAt.addingTimeInterval(30)
        try await fixture.store.update { state in
            let index = try XCTUnwrap(state.outbox.firstIndex(where: {
                $0.id == fixture.command.id
            }))
            state.outbox[index] = replacementCommand
        }
        await fixture.transport.releaseRequest()

        do {
            _ = try await preparation.value
            XCTFail("A stale preparation failure must not escape for a replaced command")
        } catch is CancellationError {
            // Expected: outer retry handling must ignore the obsolete failure.
        }

        let snapshot = await fixture.store.snapshot()
        XCTAssertEqual(snapshot.outbox, [replacementCommand])
        XCTAssertEqual(snapshot.messages, [fixture.message])
        XCTAssertNil(snapshot.outbox.first?.secureMessageFanout)
    }

    func testSuccessfulSendResponseCannotOverwriteNewerCommandAndMessage() async throws {
        let fixture = try await makeSendRaceFixture(response: .success)
        let send = Task {
            try await fixture.coordinator.sendQueuedMessage(
                commandID: fixture.command.id,
                forUserID: fixture.userID
            )
        }
        try await fixture.transport.waitUntilRequestStarted()

        var replacementCommand = fixture.command
        replacementCommand.attemptCount += 1
        replacementCommand.nextAttemptAt = fixture.command.nextAttemptAt.addingTimeInterval(30)
        replacementCommand.lastFailureReason = "A newer replay owns this command."
        var replacementMessage = fixture.message
        replacementMessage.state = .failed
        replacementMessage.failureReason = "A newer replay owns this message."
        try await fixture.store.update { state in
            let commandIndex = try XCTUnwrap(state.outbox.firstIndex(where: {
                $0.id == fixture.command.id
            }))
            let messageIndex = try XCTUnwrap(state.messages.firstIndex(where: {
                $0.id == fixture.message.id
            }))
            state.outbox[commandIndex] = replacementCommand
            state.messages[messageIndex] = replacementMessage
        }
        await fixture.transport.releaseRequest()

        do {
            _ = try await send.value
            XCTFail("An old success response must not acknowledge a replaced command")
        } catch is CancellationError {
            // Expected: neither the command nor its visible message is overwritten.
        }

        let snapshot = await fixture.store.snapshot()
        XCTAssertEqual(snapshot.outbox, [replacementCommand])
        XCTAssertEqual(snapshot.messages, [replacementMessage])
    }

    func testMatchingSuccessfulSendResponseAcknowledgesExactProjection() async throws {
        let fixture = try await makeSendRaceFixture(response: .success)
        let send = Task {
            try await fixture.coordinator.sendQueuedMessage(
                commandID: fixture.command.id,
                forUserID: fixture.userID
            )
        }
        try await fixture.transport.waitUntilRequestStarted()
        await fixture.transport.releaseRequest()

        let response = try await send.value

        XCTAssertEqual(response.id, "70000000-0000-4000-8000-000000000031")
        let snapshot = await fixture.store.snapshot()
        XCTAssertTrue(snapshot.outbox.isEmpty)
        let message = try XCTUnwrap(snapshot.messages.first)
        XCTAssertEqual(message.serverMessageId, response.id)
        XCTAssertEqual(message.state, .sent)
        XCTAssertNil(message.failureReason)
    }

    func testStaleRosterResponseCannotAbandonNewerCommand() async throws {
        let fixture = try await makeSendRaceFixture(response: .staleRoster)
        let send = Task {
            try await fixture.coordinator.sendQueuedMessage(
                commandID: fixture.command.id,
                forUserID: fixture.userID
            )
        }
        try await fixture.transport.waitUntilRequestStarted()

        var replacementCommand = fixture.command
        replacementCommand.attemptCount += 1
        replacementCommand.nextAttemptAt = fixture.command.nextAttemptAt.addingTimeInterval(30)
        try await fixture.store.update { state in
            let index = try XCTUnwrap(state.outbox.firstIndex(where: {
                $0.id == fixture.command.id
            }))
            state.outbox[index] = replacementCommand
        }
        await fixture.transport.releaseRequest()

        do {
            _ = try await send.value
            XCTFail("An old stale-roster response must not abandon a replaced command")
        } catch is CancellationError {
            // Expected: the newer replay remains authoritative.
        }

        let snapshot = await fixture.store.snapshot()
        XCTAssertEqual(snapshot.outbox, [replacementCommand])
        XCTAssertEqual(snapshot.messages, [fixture.message])
        XCTAssertEqual(snapshot.messages.first?.state, .queued)
        XCTAssertNil(snapshot.messages.first?.failureReason)
    }

    func testMatchingStaleRosterResponseAbandonsExactProjection() async throws {
        let fixture = try await makeSendRaceFixture(response: .staleRoster)
        let recipientUserID = "10000000-0000-4000-8000-000000000032"
        let send = Task {
            try await fixture.coordinator.sendQueuedMessage(
                commandID: fixture.command.id,
                forUserID: fixture.userID
            )
        }
        try await fixture.transport.waitUntilRequestStarted()
        await fixture.transport.releaseRequest()

        do {
            _ = try await send.value
            XCTFail("The stale roster response must fail the exact queued fanout")
        } catch let error as SecureMessagingExchangeError {
            XCTAssertEqual(error, .staleOutboundFanout)
        }

        let snapshot = await fixture.store.snapshot()
        XCTAssertTrue(snapshot.outbox.isEmpty)
        let message = try XCTUnwrap(snapshot.messages.first)
        XCTAssertEqual(message.state, .failed)
        XCTAssertEqual(
            message.failureReason,
            SecureMessagingExchangeError.staleOutboundFanout.localizedDescription
        )

        XCTAssertTrue(SecureMessagingExchangeCoordinator.canRetryFailedTextMessage(
            in: snapshot,
            messageID: message.id,
            userID: fixture.userID,
            conversationID: message.conversationId,
            recipientUserID: recipientUserID
        ))
        let firstRetry = try await fixture.coordinator.retryFailedTextMessage(
            messageID: message.id,
            forUserID: fixture.userID,
            conversationID: message.conversationId,
            expectedRecipientUserID: recipientUserID
        )
        let repeatedRetry = try await fixture.coordinator.retryFailedTextMessage(
            messageID: message.id,
            forUserID: fixture.userID,
            conversationID: message.conversationId,
            expectedRecipientUserID: recipientUserID
        )

        XCTAssertEqual(repeatedRetry, firstRetry)
        let unexpectedNetworkCallCount = await fixture.transport.unexpectedNetworkCallCount()
        XCTAssertEqual(unexpectedNetworkCallCount, 0)
        let retried = await fixture.store.snapshot()
        XCTAssertEqual(retried.messages.count, 1)
        XCTAssertEqual(retried.outbox.count, 1)
        let retriedMessage = try XCTUnwrap(retried.messages.first)
        let retryCommand = try XCTUnwrap(retried.outbox.first)
        XCTAssertEqual(retriedMessage.id, message.id)
        XCTAssertEqual(retriedMessage.body, message.body)
        XCTAssertEqual(retriedMessage.createdAt, message.createdAt)
        XCTAssertEqual(retriedMessage.state, .queued)
        XCTAssertNil(retriedMessage.failureReason)
        XCTAssertNotEqual(retryCommand.id, message.id)
        XCTAssertEqual(retryCommand.kind, .secureMessage)
        XCTAssertEqual(retryCommand.createdAt, message.createdAt)
        XCTAssertEqual(retryCommand.messageId, message.id)
        XCTAssertEqual(retryCommand.conversationId, message.conversationId)
        XCTAssertEqual(retryCommand.recipientUserIds, [recipientUserID])
        XCTAssertEqual(retryCommand.attemptCount, 0)
        XCTAssertNil(retryCommand.secureMessageFanout)
        XCTAssertNil(retryCommand.failureDisposition)
        XCTAssertFalse(SecureMessagingExchangeCoordinator.canRetryFailedTextMessage(
            in: retried,
            messageID: message.id,
            userID: fixture.userID,
            conversationID: message.conversationId,
            recipientUserID: recipientUserID
        ))

        let reopened = SecureLocalStore(
            stateURL: temporaryDirectory.appendingPathComponent("state.secure"),
            keyData: Data(repeating: 0x91, count: 32)
        )
        let restored = await reopened.snapshot()
        XCTAssertEqual(restored.messages.first?.id, message.id)
        XCTAssertEqual(restored.messages.first?.state, .queued)
        XCTAssertEqual(restored.outbox.first?.id, retryCommand.id)
        XCTAssertEqual(restored.outbox.first?.messageId, message.id)
        XCTAssertNil(restored.outbox.first?.secureMessageFanout)
    }

    func testFailedTextRetryRejectsInvalidOrConflictingLocalStateWithoutNetwork() async throws {
        let localUserID = "10000000-0000-4000-8000-000000000041"
        let recipientUserID = "10000000-0000-4000-8000-000000000042"
        let otherUserID = "10000000-0000-4000-8000-000000000043"
        let conversationID = "30000000-0000-4000-8000-000000000041"
        let otherConversationID = "30000000-0000-4000-8000-000000000042"
        let messageID = UUID(uuidString: "40000000-0000-4000-8000-000000000041")!
        let createdAt = Date(timeIntervalSince1970: 1_700_000_200)
        typealias Mutation = (inout PersistedState) -> Void
        let cases: [(
            name: String,
            userID: String,
            conversationID: String,
            recipientUserID: String,
            mutate: Mutation
        )] = [
            ("wrong account", otherUserID, conversationID, recipientUserID, { _ in }),
            ("wrong owner", localUserID, conversationID, recipientUserID, {
                $0.communicationOwnerUserID = otherUserID
            }),
            ("wrong conversation", localUserID, otherConversationID, recipientUserID, { _ in }),
            ("wrong recipient", localUserID, conversationID, otherUserID, { _ in }),
            ("missing enrollment", localUserID, conversationID, recipientUserID, {
                $0.secureMessaging = nil
            }),
            ("nonfailed message", localUserID, conversationID, recipientUserID, {
                $0.messages[0].state = .queued
            }),
            ("sent message", localUserID, conversationID, recipientUserID, {
                $0.messages[0].serverMessageId = "50000000-0000-4000-8000-000000000041"
            }),
            ("media message", localUserID, conversationID, recipientUserID, {
                $0.messages[0].attachmentData = Data([0x01])
            }),
            ("pending media", localUserID, conversationID, recipientUserID, {
                $0.messages[0].pendingAttachment = LocalPendingAttachment(
                    mediaType: "image/jpeg",
                    caption: nil,
                    byteCount: 1
                )
            }),
            ("reserved payment event", localUserID, conversationID, recipientUserID, {
                $0.messages[0].body = "KITPAY1:untrusted"
            }),
            ("conflicting outbox", localUserID, conversationID, recipientUserID, {
                $0.outbox = [OfflineCommand(
                    id: UUID(uuidString: "50000000-0000-4000-8000-000000000042")!,
                    kind: .secureMessage,
                    createdAt: createdAt,
                    nextAttemptAt: createdAt,
                    attemptCount: 0,
                    conversationId: conversationID,
                    messageId: messageID,
                    recipientUserIds: [recipientUserID],
                    recipientName: "Peer",
                    video: nil,
                    expiresAt: nil,
                    secureMessageFanout: nil
                )]
            }),
        ]

        for (index, testCase) in cases.enumerated() {
            var state = failedTextRetryState(
                localUserID: localUserID,
                recipientUserID: recipientUserID,
                conversationID: conversationID,
                messageID: messageID,
                createdAt: createdAt
            )
            testCase.mutate(&state)
            let store = SecureLocalStore(
                stateURL: temporaryDirectory.appendingPathComponent(
                    "retry-reject-\(index).secure"
                ),
                keyData: Data(repeating: UInt8(0xA0 + index), count: 32)
            )
            try await store.replace(state)
            let transport = OfflineExchangeTransport()
            let coordinator = SecureMessagingExchangeCoordinator(
                transport: transport,
                store: store,
                engine: SecureMessagingCryptoEngine(),
                provisioningPreKeyCount: 1
            )

            XCTAssertFalse(
                SecureMessagingExchangeCoordinator.canRetryFailedTextMessage(
                    in: state,
                    messageID: messageID,
                    userID: testCase.userID,
                    conversationID: testCase.conversationID,
                    recipientUserID: testCase.recipientUserID
                ),
                testCase.name
            )
            do {
                _ = try await coordinator.retryFailedTextMessage(
                    messageID: messageID,
                    forUserID: testCase.userID,
                    conversationID: testCase.conversationID,
                    expectedRecipientUserID: testCase.recipientUserID
                )
                XCTFail("Expected \(testCase.name) to be rejected")
            } catch {
                XCTAssertEqual(
                    error as? SecureMessagingExchangeError,
                    .messageNotRetryable,
                    testCase.name
                )
            }
            let networkCallCount = await transport.networkCallCount()
            XCTAssertEqual(networkCallCount, 0, testCase.name)
        }
    }

    func testDetachedCurrentDeviceEchoAdvancesCursorWithoutResurrectingMessage() async throws {
        let fixture = try await makeDetachedEchoFixture(retainedMessage: nil)

        let result = try await fixture.coordinator.sync(forUserID: fixture.userID)

        XCTAssertEqual(result.pages, 1)
        XCTAssertEqual(result.receivedMessages, 0)
        let snapshot = await fixture.store.snapshot()
        XCTAssertEqual(snapshot.secureMessaging?.syncCursor, fixture.nextCursor)
        XCTAssertTrue(snapshot.messages.isEmpty)
        XCTAssertEqual(snapshot.conversations.map(\.id), [fixture.conversationID])
        XCTAssertTrue(snapshot.secureMessaging?.pendingDeliveryAcknowledgementIDs.isEmpty == true)
    }

    func testDetachedCurrentDeviceTextEchoAlsoAdvancesWithoutResurrectingMessage() async throws {
        let fixture = try await makeDetachedEchoFixture(
            retainedMessage: nil,
            includesAttachment: false
        )

        let result = try await fixture.coordinator.sync(forUserID: fixture.userID)

        XCTAssertEqual(result.pages, 1)
        XCTAssertEqual(result.receivedMessages, 0)
        let snapshot = await fixture.store.snapshot()
        XCTAssertEqual(snapshot.secureMessaging?.syncCursor, fixture.nextCursor)
        XCTAssertTrue(snapshot.messages.isEmpty)
        XCTAssertEqual(snapshot.conversations.map(\.id), [fixture.conversationID])
        XCTAssertTrue(snapshot.secureMessaging?.pendingDeliveryAcknowledgementIDs.isEmpty == true)
    }

    func testCurrentDeviceEnrollmentAdvancesButOnlyCompanionEnrollmentCreatesHistoryTask()
        async throws {
        let userID = "10000000-0000-0000-0000-000000000001"
        let peerUserID = "10000000-0000-4000-8000-000000000002"
        let conversationID = "30000000-0000-4000-8000-000000000041"
        let targetDeviceID = "20000000-0000-4000-8000-000000000041"
        let nextCursor = "cursor-after-history-target"
        let store = try await makeStore(userID: userID)
        let engine = SecureMessagingCryptoEngine()
        let provisioned = try await engine.provision(from: .empty, preKeyCount: 1)
        try await store.update { $0.secureMessaging = provisioned.state }
        let status = enrolledStatus(bundle: provisioned.bundle)
        let currentDeviceID = try XCTUnwrap(status.deviceId)
        let responseObject: [String: Any] = [
            "events": [
                [
                    "id": "40",
                    "type": "device.enrolled",
                    "conversation_id": conversationID,
                    "resource_type": "messaging_device",
                    "resource_id": currentDeviceID,
                    "occurred_at": "2026-08-20T12:59:59Z",
                    "data": [
                        "device_id": currentDeviceID,
                        "user_id": userID,
                        "enrollment_epoch": try XCTUnwrap(status.enrollmentEpoch),
                        "signal_device_id": try XCTUnwrap(status.signalDeviceId),
                        "registration_id": try XCTUnwrap(status.registrationId),
                        "protocol_version": SecureMessagingWire.protocolVersion,
                        "bundle_version": try XCTUnwrap(status.bundleVersion),
                        "identity_key_sha256": try XCTUnwrap(status.identityKeySha256),
                        "roster_refresh_required": true,
                        "transitioned_at": "2026-08-20T12:59:59Z",
                        "transition_hash": String(repeating: "c", count: 64),
                    ],
                ],
                [
                    "id": "41",
                    "type": "device.enrolled",
                    "conversation_id": conversationID,
                    "resource_type": "messaging_device",
                    "resource_id": targetDeviceID,
                    "occurred_at": "2026-08-20T13:00:00Z",
                    "data": [
                        "device_id": targetDeviceID,
                        "user_id": userID,
                        "enrollment_epoch": 9,
                        "signal_device_id": 9,
                        "registration_id": 1_009,
                        "protocol_version": SecureMessagingWire.protocolVersion,
                        "bundle_version": 1,
                        "identity_key_sha256": String(repeating: "d", count: 64),
                        "roster_refresh_required": true,
                        "transitioned_at": "2026-08-20T13:00:00Z",
                        "transition_hash": String(repeating: "e", count: 64),
                    ],
                ],
            ],
            "page": [
                "next_cursor": nextCursor,
                "has_more": false,
                "limit": SecureMessagingWire.maximumSyncPage,
            ],
        ]
        let response = try JSONDecoder().decode(
            MessagingSyncDTO.self,
            from: JSONSerialization.data(withJSONObject: responseObject)
        )
        let conversation = MessagingConversationDTO(
            id: conversationID,
            type: SecureMessagingWire.directConversationType,
            title: nil,
            parentId: nil,
            createdBy: userID,
            role: "owner",
            members: [
                MessagingConversationMemberDTO(
                    userId: userID,
                    name: "Secure User",
                    role: "owner",
                    joinedAt: "2026-08-20T12:00:00Z"
                ),
                MessagingConversationMemberDTO(
                    userId: peerUserID,
                    name: "Peer",
                    role: "member",
                    joinedAt: "2026-08-20T12:00:00Z"
                ),
            ],
            createdAt: "2026-08-20T12:00:00Z",
            updatedAt: "2026-08-20T13:00:00Z"
        )
        let transport = DetachedEchoTransport(
            status: status,
            conversation: conversation,
            response: response
        )
        let coordinator = SecureMessagingExchangeCoordinator(
            transport: transport,
            store: store,
            engine: engine,
            provisioningPreKeyCount: 1
        )

        let result = try await coordinator.sync(forUserID: userID)

        XCTAssertEqual(result.appliedTransitions, 2)
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.secureMessaging?.syncCursor, nextCursor)
        XCTAssertEqual(snapshot.secureMessaging?.historyBackfillTasks, [
            SecureMessagingHistoryBackfillTask(
                conversationID: conversationID,
                targetDeviceID: targetDeviceID,
                targetEnrollmentEpoch: 9,
                nextCursor: nil
            ),
        ])
    }

    func testHistoryCiphertextSurvivesCrashReplayUntilCursorAdvancesAtomically() throws {
        let conversationID = "30000000-0000-4000-8000-000000000051"
        let targetDeviceID = "20000000-0000-4000-8000-000000000051"
        let messageID = "70000000-0000-4000-8000-000000000051"
        let transferID = "90000000-0000-4000-8000-000000000051"
        let task = SecureMessagingHistoryBackfillTask(
            conversationID: conversationID,
            targetDeviceID: targetDeviceID,
            targetEnrollmentEpoch: 5,
            nextCursor: nil
        )
        let outbound = SecureMessagingHistoryOutboundEnvelope(
            originalMessageID: messageID,
            targetDeviceID: targetDeviceID,
            targetEnrollmentEpoch: 5,
            fanout: SecureMessagingCommittedFanout(
                clientMessageID: transferID,
                conversationID: conversationID,
                rosterRevision: "v1:sha256:\(String(repeating: "a", count: 64))",
                replyToMessageID: nil,
                rosterDevices: [],
                envelopes: [SecureMessagingOutboundEnvelope(
                    recipientDeviceID: targetDeviceID,
                    envelopeType: SecureMessagingEnvelopeType.message.rawValue,
                    ciphertext: Data([0, 1, 2, 3, 254, 255])
                )]
            )
        )
        var beforeCrash = SecureMessagingPersistentState.empty
        beforeCrash.historyBackfillTasks = [task]
        beforeCrash.historyOutboundEnvelopes = [transferID: outbound]

        let replayed = try JSONDecoder().decode(
            SecureMessagingPersistentState.self,
            from: JSONEncoder().encode(beforeCrash)
        )
        XCTAssertEqual(
            replayed.historyOutboundEnvelopes[transferID]?.fanout.envelopes.first?.ciphertext,
            outbound.fanout.envelopes.first?.ciphertext,
            "A crash before cursor commit must preserve the exact retry bytes"
        )
        XCTAssertEqual(replayed.historyBackfillTasks, [task])

        let advanced = try SecureMessagingExchangeCoordinator.historyStateByAdvancingCommittedPage(
            replayed,
            taskIndex: 0,
            task: task,
            nextCursor: "history-page-2",
            hasMore: true,
            completedMessageIDs: [messageID]
        )
        XCTAssertEqual(advanced.historyBackfillTasks.first?.nextCursor, "history-page-2")
        XCTAssertNil(advanced.historyOutboundEnvelopes[transferID])

        let strandedTransferID = "90000000-0000-4000-8000-000000000059"
        let unrelatedTransferID = "90000000-0000-4000-8000-000000000060"
        let unrelatedTargetID = "20000000-0000-4000-8000-000000000059"
        func envelope(
            transferID: String,
            originalMessageID: String,
            target: String
        ) -> SecureMessagingHistoryOutboundEnvelope {
            SecureMessagingHistoryOutboundEnvelope(
                originalMessageID: originalMessageID,
                targetDeviceID: target,
                targetEnrollmentEpoch: 5,
                fanout: SecureMessagingCommittedFanout(
                    clientMessageID: transferID,
                    conversationID: conversationID,
                    rosterRevision: "v1:sha256:\(String(repeating: "a", count: 64))",
                    replyToMessageID: nil,
                    rosterDevices: [],
                    envelopes: []
                )
            )
        }
        var beforeFinalPage = advanced
        beforeFinalPage.historyOutboundEnvelopes[strandedTransferID] = envelope(
            transferID: strandedTransferID,
            originalMessageID: "70000000-0000-4000-8000-000000000059",
            target: targetDeviceID
        )
        beforeFinalPage.historyOutboundEnvelopes[unrelatedTransferID] = envelope(
            transferID: unrelatedTransferID,
            originalMessageID: "70000000-0000-4000-8000-000000000060",
            target: unrelatedTargetID
        )
        let finalTask = try XCTUnwrap(beforeFinalPage.historyBackfillTasks.first)
        let completed = try SecureMessagingExchangeCoordinator
            .historyStateByAdvancingCommittedPage(
                beforeFinalPage,
                taskIndex: 0,
                task: finalTask,
                nextCursor: nil,
                hasMore: false,
                completedMessageIDs: []
            )
        XCTAssertTrue(completed.historyBackfillTasks.isEmpty)
        XCTAssertNil(completed.historyOutboundEnvelopes[strandedTransferID])
        XCTAssertNotNil(completed.historyOutboundEnvelopes[unrelatedTransferID])
    }

    func testPersistedCurrentDeviceHistoryWorkIsDiscardedWithoutDroppingCompanionWork() {
        let conversationID = "30000000-0000-4000-8000-000000000052"
        let currentDeviceID = "20000000-0000-4000-8000-000000000052"
        let companionDeviceID = "20000000-0000-4000-8000-000000000053"
        let selfTask = SecureMessagingHistoryBackfillTask(
            conversationID: conversationID,
            targetDeviceID: currentDeviceID,
            targetEnrollmentEpoch: 2,
            nextCursor: nil
        )
        let companionTask = SecureMessagingHistoryBackfillTask(
            conversationID: conversationID,
            targetDeviceID: companionDeviceID,
            targetEnrollmentEpoch: 3,
            nextCursor: nil
        )
        func outbound(_ transferID: String, target: String) -> SecureMessagingHistoryOutboundEnvelope {
            SecureMessagingHistoryOutboundEnvelope(
                originalMessageID: "70000000-0000-4000-8000-000000000052",
                targetDeviceID: target,
                targetEnrollmentEpoch: target == currentDeviceID ? 2 : 3,
                fanout: SecureMessagingCommittedFanout(
                    clientMessageID: transferID,
                    conversationID: conversationID,
                    rosterRevision: "v1:sha256:\(String(repeating: "b", count: 64))",
                    replyToMessageID: nil,
                    rosterDevices: [],
                    envelopes: []
                )
            )
        }
        let selfTransferID = "90000000-0000-4000-8000-000000000052"
        let companionTransferID = "90000000-0000-4000-8000-000000000053"
        var initial = SecureMessagingPersistentState.empty
        initial.historyBackfillTasks = [selfTask, companionTask]
        initial.historyOutboundEnvelopes = [
            selfTransferID: outbound(selfTransferID, target: currentDeviceID),
            companionTransferID: outbound(companionTransferID, target: companionDeviceID),
        ]

        let cleaned = SecureMessagingExchangeCoordinator.historyStateDiscardingCurrentDeviceWork(
            initial,
            currentDeviceID: currentDeviceID
        )

        XCTAssertEqual(cleaned.historyBackfillTasks, [companionTask])
        XCTAssertNil(cleaned.historyOutboundEnvelopes[selfTransferID])
        XCTAssertEqual(
            cleaned.historyOutboundEnvelopes[companionTransferID],
            initial.historyOutboundEnvelopes[companionTransferID]
        )
    }

    func testRosterReconciliationCreatesMissedTargetAndRetiresStaleEpochWork() throws {
        let conversationID = "30000000-0000-4000-8000-000000000061"
        let removedConversationID = "30000000-0000-4000-8000-000000000062"
        let currentDeviceID = "20000000-0000-4000-8000-000000000061"
        let companionDeviceID = "20000000-0000-4000-8000-000000000062"
        let staleTask = SecureMessagingHistoryBackfillTask(
            conversationID: conversationID,
            targetDeviceID: companionDeviceID,
            targetEnrollmentEpoch: 4,
            nextCursor: "stale_cursor"
        )
        let removedConversationTask = SecureMessagingHistoryBackfillTask(
            conversationID: removedConversationID,
            targetDeviceID: companionDeviceID,
            targetEnrollmentEpoch: 5,
            nextCursor: nil
        )
        let transferID = "90000000-0000-4000-8000-000000000061"
        var initial = SecureMessagingPersistentState.empty
        initial.historyBackfillTasks = [staleTask, removedConversationTask]
        initial.historyOutboundEnvelopes[transferID] = SecureMessagingHistoryOutboundEnvelope(
            originalMessageID: "70000000-0000-4000-8000-000000000061",
            targetDeviceID: companionDeviceID,
            targetEnrollmentEpoch: 4,
            fanout: SecureMessagingCommittedFanout(
                clientMessageID: transferID,
                conversationID: conversationID,
                rosterRevision: "v1:sha256:\(String(repeating: "a", count: 64))",
                replyToMessageID: nil,
                rosterDevices: [],
                envelopes: []
            )
        )

        let reconciled = try SecureMessagingExchangeCoordinator
            .historyStateByReconcilingCurrentTargets(
                initial,
                activeConversationIDs: [conversationID],
                targets: [SecureMessagingHistoryBackfillTarget(
                    conversationID: conversationID,
                    deviceID: companionDeviceID,
                    enrollmentEpoch: 5
                )],
                currentDeviceID: currentDeviceID
            )

        XCTAssertEqual(reconciled.historyBackfillTasks, [
            SecureMessagingHistoryBackfillTask(
                conversationID: conversationID,
                targetDeviceID: companionDeviceID,
                targetEnrollmentEpoch: 5,
                nextCursor: nil
            ),
        ])
        XCTAssertTrue(reconciled.historyOutboundEnvelopes.isEmpty)
    }

    func testHistoryDrainDoesNotLetFourFailingTasksStarveTheFifth() {
        let conversationID = "30000000-0000-4000-8000-000000000063"
        let tasks = (1...5).map { index in
            SecureMessagingHistoryBackfillTask(
                conversationID: conversationID,
                targetDeviceID: String(
                    format: "20000000-0000-4000-8000-%012d",
                    index
                ),
                targetEnrollmentEpoch: Int64(index),
                nextCursor: nil
            )
        }
        var drain = SecureMessagingHistoryDrainState(
            maximumWorkUnits: 5,
            batchSize: 4
        )

        let firstBatch = drain.nextBatch(from: tasks)
        XCTAssertEqual(firstBatch, Array(tasks.prefix(4)))
        firstBatch.forEach { drain.recordAttempt(of: $0, madeProgress: false) }
        XCTAssertFalse(drain.madeProgress)

        let secondBatch = drain.nextBatch(from: tasks)
        XCTAssertEqual(secondBatch, [tasks[4]])
        drain.recordAttempt(of: tasks[4], madeProgress: true)
        XCTAssertEqual(drain.workUnits, 5)
        XCTAssertTrue(drain.madeProgress)
        XCTAssertEqual(drain.failedTaskKeys, Set(tasks.prefix(4).map(\.key)))
        let exhaustedBatch = drain.nextBatch(from: tasks)
        XCTAssertTrue(exhaustedBatch.isEmpty)
    }

    func testHistoryContinuationPolicyYieldsAfterProgressAndBacksOffAfterFailure() {
        XCTAssertNil(SecureMessagingHistoryContinuationPolicy.delayNanoseconds(
            pending: false,
            madeProgress: true
        ))
        XCTAssertEqual(
            SecureMessagingHistoryContinuationPolicy.delayNanoseconds(
                pending: true,
                madeProgress: true
            ),
            0
        )
        XCTAssertEqual(
            SecureMessagingHistoryContinuationPolicy.delayNanoseconds(
                pending: true,
                madeProgress: false
            ),
            SecureMessagingHistoryContinuationPolicy.failureRetryNanoseconds
        )
    }

    func testHistoryAttemptDispositionCompletesTerminalTargetAndRestartsInvalidCursor() throws {
        let task = SecureMessagingHistoryBackfillTask(
            conversationID: "30000000-0000-4000-8000-000000000064",
            targetDeviceID: "20000000-0000-4000-8000-000000000064",
            targetEnrollmentEpoch: 7,
            nextCursor: "expired_cursor"
        )
        XCTAssertEqual(
            SecureMessagingExchangeCoordinator.historyAttemptDisposition(
                for: APIErrorPayload(
                    code: "MESSAGING_HISTORY_TARGET_STALE",
                    message: "Target changed."
                ),
                task: task
            ),
            .complete
        )
        XCTAssertEqual(
            SecureMessagingExchangeCoordinator.historyAttemptDisposition(
                for: APIErrorPayload(
                    code: "MESSAGING_HISTORY_CURSOR_INVALID",
                    message: "Cursor expired."
                ),
                task: task
            ),
            .restartFromFirstPage
        )
        XCTAssertEqual(
            SecureMessagingExchangeCoordinator.historyAttemptDisposition(
                for: APIErrorPayload(code: "TEMPORARY_FAILURE", message: "Retry."),
                task: task
            ),
            .retryLater
        )

        var initial = SecureMessagingPersistentState.empty
        initial.historyBackfillTasks = [task]
        let restarted = try SecureMessagingExchangeCoordinator.historyStateByResolvingTask(
            initial,
            task: task,
            disposition: .restartFromFirstPage
        )
        XCTAssertNil(restarted.historyBackfillTasks.first?.nextCursor)
        let completed = try SecureMessagingExchangeCoordinator.historyStateByResolvingTask(
            initial,
            task: task,
            disposition: .complete
        )
        XCTAssertTrue(completed.historyBackfillTasks.isEmpty)
    }

    func testMalformedPostDecryptionHistoryDescriptorIsSuppressedAndAcknowledged() throws {
        let fixture = try makeHistoryDescriptorFixture()
        let malformedDescriptor = fixture.descriptor.replacingOccurrences(
            of: "\"text\":\"history text\"",
            with: "\"text\":truth"
        )
        XCTAssertNotEqual(malformedDescriptor, fixture.descriptor)

        switch try SecureMessagingExchangeCoordinator.historyDescriptorDisposition(
            malformedDescriptor,
            incoming: fixture.incoming
        ) {
        case .suppressed(let acknowledgementMessageID):
            XCTAssertEqual(acknowledgementMessageID, fixture.incoming.original.messageID)
        case .authenticated:
            XCTFail("Malformed authenticated wrapper content must not be materialized")
        }
    }

    func testInvalidEscapeInPostDecryptionHistoryDescriptorIsSuppressedAndAcknowledged() throws {
        let fixture = try makeHistoryDescriptorFixture()
        let invalidEscape = fixture.descriptor.replacingOccurrences(
            of: "\"text\":\"history text\"",
            with: "\"text\":\"history\\qtext\""
        )
        XCTAssertNotEqual(invalidEscape, fixture.descriptor)

        switch try SecureMessagingExchangeCoordinator.historyDescriptorDisposition(
            invalidEscape,
            incoming: fixture.incoming
        ) {
        case .suppressed(let acknowledgementMessageID):
            XCTAssertEqual(acknowledgementMessageID, fixture.incoming.original.messageID)
        case .authenticated:
            XCTFail("A JSON parser failure after Signal decryption must not pin sync")
        }
    }

    func testRecoveredHistoryReconcilesCurrentDeviceOutboundByClientID() throws {
        let userID = "10000000-0000-4000-8000-000000000057"
        let currentDeviceID = "20000000-0000-4000-8000-000000000057"
        let conversationID = "30000000-0000-4000-8000-000000000057"
        let clientID = "80000000-0000-4000-8000-000000000057"
        let serverID = "70000000-0000-4000-8000-000000000057"
        let clientUUID = try XCTUnwrap(UUID(uuidString: clientID))
        let queuedAt = Date(timeIntervalSince1970: 1_755_604_800)
        let sentAt = queuedAt.addingTimeInterval(2)
        let metadata = SecureMessagingRetainedMessageMetadata(
            clientMessageID: clientID,
            senderDeviceID: currentDeviceID,
            senderEnrollmentEpoch: 2,
            senderSignalDeviceID: 1,
            rosterRevision: "v1:sha256:\(String(repeating: "f", count: 64))",
            kind: .encrypted,
            replyToMessageID: nil
        )
        let local = LocalMessage(
            id: clientUUID,
            conversationId: conversationID,
            senderId: userID,
            body: "receipt recovered from companion device",
            createdAt: queuedAt,
            sentAt: nil,
            state: .sending,
            failureReason: "awaiting receipt",
            isOutgoing: true
        )
        let recovered = LocalMessage(
            id: clientUUID,
            serverMessageId: serverID,
            conversationId: conversationID,
            senderId: userID,
            body: local.body,
            createdAt: sentAt,
            sentAt: sentAt,
            state: .sent,
            failureReason: nil,
            isOutgoing: true,
            secureMessagingHistory: metadata
        )
        let command = OfflineCommand(
            id: UUID(uuidString: "90000000-0000-4000-8000-000000000057")!,
            kind: .secureMessage,
            createdAt: queuedAt,
            nextAttemptAt: queuedAt,
            attemptCount: 1,
            conversationId: conversationID,
            messageId: clientUUID,
            recipientUserIds: ["10000000-0000-4000-8000-000000000058"],
            recipientName: "Peer",
            video: nil,
            expiresAt: nil
        )
        var state = PersistedState.empty
        state.messages = [local]
        state.outbox = [command]
        state.conversations = [Conversation(
            id: conversationID,
            title: "Peer",
            participantUserIds: [userID],
            unreadCount: 0,
            updatedAt: queuedAt
        )]

        SecureMessagingExchangeCoordinator.reconcileRecoveredHistoryMessages(
            [recovered],
            currentDeviceID: currentDeviceID,
            into: &state
        )

        XCTAssertEqual(state.messages.count, 1)
        XCTAssertEqual(state.messages[0].serverMessageId, serverID)
        XCTAssertEqual(state.messages[0].sentAt, sentAt)
        XCTAssertEqual(state.messages[0].state, .sent)
        XCTAssertNil(state.messages[0].failureReason)
        XCTAssertEqual(state.messages[0].secureMessagingHistory, metadata)
        XCTAssertTrue(state.outbox.isEmpty)

        var otherDeviceState = PersistedState.empty
        otherDeviceState.messages = [local]
        var otherDeviceMetadata = metadata
        otherDeviceMetadata = SecureMessagingRetainedMessageMetadata(
            clientMessageID: metadata.clientMessageID,
            senderDeviceID: "20000000-0000-4000-8000-000000000058",
            senderEnrollmentEpoch: metadata.senderEnrollmentEpoch,
            senderSignalDeviceID: metadata.senderSignalDeviceID,
            rosterRevision: metadata.rosterRevision,
            kind: metadata.kind,
            replyToMessageID: metadata.replyToMessageID
        )
        var collision = recovered
        collision.secureMessagingHistory = otherDeviceMetadata
        SecureMessagingExchangeCoordinator.reconcileRecoveredHistoryMessages(
            [collision],
            currentDeviceID: currentDeviceID,
            into: &otherDeviceState
        )
        XCTAssertNil(otherDeviceState.messages[0].serverMessageId)
        XCTAssertEqual(otherDeviceState.messages.count, 1)
    }

    func testMalformedDetachedCurrentDeviceEchoFailsWithoutAdvancingCursor() async throws {
        let fixture = try await makeDetachedEchoFixture(
            retainedMessage: nil,
            senderIdentityOverride: String(repeating: "f", count: 64)
        )

        do {
            _ = try await fixture.coordinator.sync(forUserID: fixture.userID)
            XCTFail("A detached echo with another identity commitment must be rejected")
        } catch SecureMessagingExchangeError.invalidServerResponse {
            // Expected.
        }

        let snapshot = await fixture.store.snapshot()
        XCTAssertNil(snapshot.secureMessaging?.syncCursor)
        XCTAssertTrue(snapshot.messages.isEmpty)
        XCTAssertTrue(snapshot.conversations.isEmpty)
    }

    func testRetainedMessageAttachmentMismatchStillFailsWithoutAdvancingCursor() async throws {
        let clientMessageID = UUID(uuidString: "80000000-0000-4000-8000-000000000001")!
        let retained = LocalMessage(
            id: clientMessageID,
            conversationId: "30000000-0000-4000-8000-000000000001",
            senderId: "10000000-0000-4000-8000-000000000001",
            body: "retained text does not authenticate the outer attachment",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            sentAt: nil,
            state: .queued,
            failureReason: nil,
            isOutgoing: true
        )
        let fixture = try await makeDetachedEchoFixture(retainedMessage: retained)

        do {
            _ = try await fixture.coordinator.sync(forUserID: fixture.userID)
            XCTFail("A retained plaintext/attachment mismatch must remain fail-closed")
        } catch SecureMessagingExchangeError.invalidServerResponse {
            // Expected.
        }

        let snapshot = await fixture.store.snapshot()
        XCTAssertNil(snapshot.secureMessaging?.syncCursor)
        XCTAssertEqual(snapshot.messages, [retained])
        XCTAssertTrue(snapshot.conversations.isEmpty)
    }

    private func makeHistoryDescriptorFixture() throws -> (
        incoming: SecureMessagingHistoryInboundEnvelope,
        descriptor: String
    ) {
        let messageID = "70000000-0000-4000-8000-000000000054"
        let original = SecureMessagingHistoryMessageIdentity(
            messageID: messageID,
            clientMessageID: "80000000-0000-4000-8000-000000000054",
            conversationID: "30000000-0000-4000-8000-000000000054",
            senderUserID: "10000000-0000-4000-8000-000000000054",
            senderDeviceID: "20000000-0000-4000-8000-000000000054",
            senderEnrollmentEpoch: 1,
            senderSignalDeviceID: 1,
            rosterRevision: "v1:sha256:\(String(repeating: "c", count: 64))",
            kind: .encrypted,
            replyToMessageID: nil,
            sentAt: Date(timeIntervalSince1970: 1_755_604_800)
        )
        let local = SecureMessagingAddress(
            userID: "10000000-0000-4000-8000-000000000055",
            serverDeviceID: "20000000-0000-4000-8000-000000000055",
            signalDeviceID: 2
        )
        let incoming = SecureMessagingHistoryInboundEnvelope(
            cryptoEnvelope: SecureMessagingInboundEnvelope(
                messageID: messageID,
                clientMessageID: "90000000-0000-4000-8000-000000000054",
                conversationID: original.conversationID,
                rosterRevision: "v1:sha256:\(String(repeating: "d", count: 64))",
                replyToMessageID: nil,
                sender: SecureMessagingRosterDevice(
                    address: SecureMessagingAddress(
                        userID: local.userID,
                        serverDeviceID: "20000000-0000-4000-8000-000000000056",
                        signalDeviceID: 3
                    ),
                    registrationID: 42,
                    identityKeySHA256: String(repeating: "e", count: 64)
                ),
                localRecipient: local,
                envelopeType: SecureMessagingEnvelopeType.message.rawValue,
                ciphertext: Data([1])
            ),
            original: original,
            targetDeviceID: local.serverDeviceID,
            targetEnrollmentEpoch: 2,
            transferClientMessageID: "90000000-0000-4000-8000-000000000054",
            transferRosterRevision: "v1:sha256:\(String(repeating: "d", count: 64))",
            rawAttachments: []
        )
        let retained = LocalMessage(
            id: try XCTUnwrap(UUID(uuidString: messageID)),
            serverMessageId: messageID,
            conversationId: original.conversationID,
            senderId: original.senderUserID,
            body: "history text",
            createdAt: original.sentAt,
            sentAt: original.sentAt,
            state: .received,
            failureReason: nil,
            isOutgoing: false,
            secureMessagingHistory: original.retainedMetadata
        )
        return (
            incoming,
            try SecureMessagingHistoryBackfillCodec.encode(
                transferClientMessageID: incoming.transferClientMessageID,
                targetDeviceID: incoming.targetDeviceID,
                targetEnrollmentEpoch: incoming.targetEnrollmentEpoch,
                transferRosterRevision: incoming.transferRosterRevision,
                candidate: original,
                rawSentAt: "2025-08-19T12:00:00Z",
                retained: retained
            )
        )
    }

    private func makeDetachedEchoFixture(
        retainedMessage: LocalMessage?,
        senderIdentityOverride: String? = nil,
        includesAttachment: Bool = true
    ) async throws -> DetachedEchoFixture {
        let userID = "10000000-0000-4000-8000-000000000001"
        let recipientUserID = "10000000-0000-4000-8000-000000000002"
        let conversationID = "30000000-0000-4000-8000-000000000001"
        let serverMessageID = "70000000-0000-4000-8000-000000000001"
        let clientMessageID = "80000000-0000-4000-8000-000000000001"
        let nextCursor = "cursor-after-detached-self-echo"
        let store = try await makeStore(userID: userID)
        let engine = SecureMessagingCryptoEngine()
        let provisioned = try await engine.provision(from: .empty, preKeyCount: 1)
        try await store.update { state in
            state.secureMessaging = provisioned.state
            if let retainedMessage { state.messages = [retainedMessage] }
        }
        let status = enrolledStatus(bundle: provisioned.bundle)
        let senderIdentity = senderIdentityOverride ?? status.identityKeySha256!
        let attachment: [String: Any] = [
            "id": "90000000-0000-4000-8000-000000000001",
            "storage_key": "90000000-0000-4000-8000-000000000002",
            "media_type": "image/jpeg",
            "byte_size": 1_049_744,
            "ciphertext_sha256": String(repeating: "a", count: 64),
            "encryption_metadata_ciphertext": NSNull(),
        ]
        let data: [String: Any] = [
            "id": serverMessageID,
            "conversation_id": conversationID,
            "client_message_id": clientMessageID,
            "sender": ["id": userID, "name": "Secure User"],
            "sender_device_id": status.deviceId!,
            "sender_enrollment_epoch": status.enrollmentEpoch!,
            "sender_signal_device_id": status.signalDeviceId!,
            "sender_registration_id": status.registrationId!,
            "sender_protocol_version": SecureMessagingWire.protocolVersion,
            "sender_bundle_version": status.bundleVersion!,
            "sender_identity_key_sha256": senderIdentity,
            "roster_revision": "v1:sha256:\(String(repeating: "b", count: 64))",
            "kind": includesAttachment
                ? SecureMessagingMessageKind.encryptedAttachment.rawValue
                : SecureMessagingMessageKind.encrypted.rawValue,
            "reply_to_message_id": NSNull(),
            "envelope": NSNull(),
            "attachments": includesAttachment ? [attachment] : [],
            "reactions": [],
            "sent_at": "2026-08-19T11:51:16Z",
            "revoked_at": NSNull(),
        ]
        let responseObject: [String: Any] = [
            "events": [[
                "id": "1",
                "type": "message.created",
                "conversation_id": conversationID,
                "resource_type": "message",
                "resource_id": serverMessageID,
                "data": data,
                "occurred_at": "2026-08-19T11:51:16Z",
            ]],
            "page": [
                "next_cursor": nextCursor,
                "has_more": false,
                "limit": 100,
            ],
        ]
        let responseData = try JSONSerialization.data(withJSONObject: responseObject)
        let response = try JSONDecoder().decode(MessagingSyncDTO.self, from: responseData)
        let conversation = MessagingConversationDTO(
            id: conversationID,
            type: SecureMessagingWire.directConversationType,
            title: nil,
            parentId: nil,
            createdBy: userID,
            role: "owner",
            members: [
                MessagingConversationMemberDTO(
                    userId: userID,
                    name: "Secure User",
                    role: "owner",
                    joinedAt: "2026-08-19T11:00:00Z"
                ),
                MessagingConversationMemberDTO(
                    userId: recipientUserID,
                    name: "Peer",
                    role: "member",
                    joinedAt: "2026-08-19T11:00:00Z"
                ),
            ],
            createdAt: "2026-08-19T11:00:00Z",
            updatedAt: "2026-08-19T11:51:16Z"
        )
        let transport = DetachedEchoTransport(
            status: status,
            conversation: conversation,
            response: response
        )
        return DetachedEchoFixture(
            userID: userID,
            conversationID: conversationID,
            nextCursor: nextCursor,
            store: store,
            coordinator: SecureMessagingExchangeCoordinator(
                transport: transport,
                store: store,
                engine: engine,
                provisioningPreKeyCount: 1
            )
        )
    }

    private func makeDeferredPreparationRaceFixture(
        fails: Bool = false
    ) async throws -> MessagingRaceFixture {
        let userID = "10000000-0000-4000-8000-000000000021"
        let recipientUserID = "10000000-0000-4000-8000-000000000022"
        let conversationID = "30000000-0000-4000-8000-000000000021"
        let messageID = UUID(uuidString: "80000000-0000-4000-8000-000000000021")!
        let createdAt = Date(timeIntervalSince1970: 1_755_604_800)
        let store = try await makeStore(userID: userID)
        let message = LocalMessage(
            id: messageID,
            conversationId: conversationID,
            senderId: userID,
            body: "Deferred race fence",
            createdAt: createdAt,
            sentAt: nil,
            state: .queued,
            failureReason: nil,
            isOutgoing: true
        )
        let command = OfflineCommand(
            id: UUID(uuidString: "90000000-0000-4000-8000-000000000021")!,
            kind: .secureMessage,
            createdAt: createdAt,
            nextAttemptAt: createdAt,
            attemptCount: 0,
            conversationId: conversationID,
            messageId: messageID,
            recipientUserIds: [recipientUserID],
            recipientName: "Peer",
            video: nil,
            expiresAt: nil,
            secureMessageFanout: nil
        )
        var crypto = SecureMessagingPersistentState.empty
        crypto.enrollment = raceEnrollment(userID: userID)
        try await store.update { state in
            state.secureMessaging = crypto
            state.conversations = [Conversation(
                id: conversationID,
                title: "Peer",
                participantUserIds: [userID, recipientUserID],
                unreadCount: 0,
                updatedAt: createdAt
            )]
            state.messages = [message]
            state.outbox = [command]
        }
        let conversation = MessagingConversationDTO(
            id: conversationID,
            type: SecureMessagingWire.directConversationType,
            title: nil,
            parentId: nil,
            createdBy: userID,
            role: "owner",
            members: [
                MessagingConversationMemberDTO(
                    userId: userID,
                    name: "Secure User",
                    role: "owner",
                    joinedAt: "2026-08-19T12:00:00Z"
                ),
                MessagingConversationMemberDTO(
                    userId: recipientUserID,
                    name: "Peer",
                    role: "member",
                    joinedAt: "2026-08-19T12:00:00Z"
                ),
            ],
            createdAt: "2026-08-19T12:00:00Z",
            updatedAt: "2026-08-19T12:00:00Z"
        )
        let scenario: SuspendedMessagingExchangeTransport.Scenario = fails
            ? .conversationFailure(conversationID: conversationID)
            : .conversation(conversation)
        let transport = SuspendedMessagingExchangeTransport(scenario: scenario)
        return MessagingRaceFixture(
            userID: userID,
            store: store,
            coordinator: SecureMessagingExchangeCoordinator(
                transport: transport,
                store: store,
                engine: SecureMessagingCryptoEngine(),
                provisioningPreKeyCount: 1
            ),
            transport: transport,
            command: command,
            message: message
        )
    }

    private func makeSendRaceFixture(
        response: MessagingRaceResponse
    ) async throws -> MessagingRaceFixture {
        let userID = "10000000-0000-4000-8000-000000000031"
        let recipientUserID = "10000000-0000-4000-8000-000000000032"
        let localDeviceID = "20000000-0000-4000-8000-000000000031"
        let recipientDeviceID = "20000000-0000-4000-8000-000000000032"
        let conversationID = "30000000-0000-4000-8000-000000000031"
        let clientMessageID = "80000000-0000-4000-8000-000000000031"
        let rosterRevision = "v1:sha256:\(String(repeating: "b", count: 64))"
        let createdAt = Date(timeIntervalSince1970: 1_755_604_800)
        let fanout = SecureMessagingCommittedFanout(
            clientMessageID: clientMessageID,
            conversationID: conversationID,
            rosterRevision: rosterRevision,
            replyToMessageID: nil,
            rosterDevices: [],
            envelopes: [SecureMessagingOutboundEnvelope(
                recipientDeviceID: recipientDeviceID,
                envelopeType: SecureMessagingEnvelopeType.message.rawValue,
                ciphertext: Data([1, 2, 3])
            )]
        )
        let message = LocalMessage(
            id: UUID(uuidString: clientMessageID)!,
            conversationId: conversationID,
            senderId: userID,
            body: "Send response race fence",
            createdAt: createdAt,
            sentAt: nil,
            state: .queued,
            failureReason: nil,
            isOutgoing: true
        )
        let command = OfflineCommand(
            id: UUID(uuidString: "90000000-0000-4000-8000-000000000031")!,
            kind: .secureMessage,
            createdAt: createdAt,
            nextAttemptAt: createdAt,
            attemptCount: 0,
            conversationId: conversationID,
            messageId: message.id,
            recipientUserIds: [recipientUserID],
            recipientName: "Peer",
            video: nil,
            expiresAt: nil,
            secureMessageFanout: fanout
        )
        let store = try await makeStore(userID: userID)
        var crypto = SecureMessagingPersistentState.empty
        crypto.enrollment = raceEnrollment(
            userID: userID,
            serverDeviceID: localDeviceID
        )
        try await store.update { state in
            state.communicationOwnerUserID = userID
            state.secureMessaging = crypto
            state.conversations = [Conversation(
                id: conversationID,
                title: "Peer",
                participantUserIds: [userID, recipientUserID],
                unreadCount: 0,
                updatedAt: createdAt
            )]
            state.messages = [message]
            state.outbox = [command]
        }
        let serverResponse = EncryptedMessageDTO(
            id: "70000000-0000-4000-8000-000000000031",
            conversationId: conversationID,
            clientMessageId: clientMessageID,
            sender: EncryptedMessageSenderDTO(id: userID, name: "Secure User"),
            senderDeviceId: localDeviceID,
            senderEnrollmentEpoch: 1,
            senderSignalDeviceId: 1,
            senderRegistrationId: 42,
            senderProtocolVersion: SecureMessagingWire.protocolVersion,
            senderBundleVersion: 1,
            senderIdentityKeySha256: String(repeating: "a", count: 64),
            rosterRevision: rosterRevision,
            kind: SecureMessagingMessageKind.encrypted.rawValue,
            replyToMessageId: nil,
            envelope: nil,
            attachments: [],
            reactions: [],
            sentAt: "2026-08-19T12:00:15Z",
            revokedAt: nil
        )
        let scenario: SuspendedMessagingExchangeTransport.Scenario
        switch response {
        case .success:
            scenario = .sendSuccess(serverResponse)
        case .staleRoster:
            scenario = .sendStaleRoster(conversationID: conversationID)
        }
        let transport = SuspendedMessagingExchangeTransport(scenario: scenario)
        return MessagingRaceFixture(
            userID: userID,
            store: store,
            coordinator: SecureMessagingExchangeCoordinator(
                transport: transport,
                store: store,
                engine: SecureMessagingCryptoEngine(),
                provisioningPreKeyCount: 1
            ),
            transport: transport,
            command: command,
            message: message
        )
    }

    private func raceEnrollment(
        userID: String,
        serverDeviceID: String = "20000000-0000-4000-8000-000000000021"
    ) -> SecureMessagingEnrollmentBinding {
        SecureMessagingEnrollmentBinding(
            userID: userID,
            serverDeviceID: serverDeviceID,
            signalDeviceID: 1,
            registrationID: 42,
            enrollmentEpoch: 1,
            identityKeySHA256: String(repeating: "a", count: 64),
            bundleVersion: 1,
            signedPreKeyID: 5,
            signedPreKeySHA256: String(repeating: "b", count: 64),
            pqLastResortPreKeyID: 6,
            pqLastResortPreKeySHA256: String(repeating: "c", count: 64)
        )
    }

    private func failedTextRetryState(
        localUserID: String,
        recipientUserID: String,
        conversationID: String,
        messageID: UUID,
        createdAt: Date
    ) -> PersistedState {
        var state = PersistedState.empty
        state.profile = UserProfile(
            id: localUserID,
            name: "Secure User",
            email: nil,
            phone: "+256700000001",
            tag: nil,
            kycStatus: nil,
            paymentPinSet: nil,
            mfaEnabled: nil,
            profileSetupRequired: false
        )
        state.communicationOwnerUserID = localUserID
        var crypto = SecureMessagingPersistentState.empty
        crypto.enrollment = raceEnrollment(userID: localUserID)
        state.secureMessaging = crypto
        state.conversations = [Conversation(
            id: conversationID,
            title: "Peer",
            participantUserIds: [localUserID, recipientUserID],
            unreadCount: 0,
            updatedAt: createdAt.addingTimeInterval(-10)
        )]
        state.messages = [LocalMessage(
            id: messageID,
            conversationId: conversationID,
            senderId: localUserID,
            body: "Keep this exact body",
            createdAt: createdAt,
            sentAt: nil,
            state: .failed,
            failureReason: "The recipient's devices changed. Retry the message.",
            isOutgoing: true
        )]
        return state
    }

    private func directConversationDTO(
        id: String,
        userID: String,
        peerID: String,
        peerName: String
    ) -> MessagingConversationDTO {
        MessagingConversationDTO(
            id: id,
            type: SecureMessagingWire.directConversationType,
            title: nil,
            parentId: nil,
            createdBy: userID,
            role: "owner",
            members: [
                MessagingConversationMemberDTO(
                    userId: userID,
                    name: "Secure User",
                    role: "owner",
                    joinedAt: "2026-08-22T10:00:00Z"
                ),
                MessagingConversationMemberDTO(
                    userId: peerID,
                    name: peerName,
                    role: "member",
                    joinedAt: "2026-08-22T10:00:00Z"
                ),
            ],
            createdAt: "2026-08-22T10:00:00Z",
            updatedAt: "2026-08-22T10:01:00Z"
        )
    }

    private func makeStore(userID: String) async throws -> SecureLocalStore {
        let store = SecureLocalStore(
            stateURL: temporaryDirectory.appendingPathComponent("state.secure"),
            keyData: Data(repeating: 0x91, count: 32)
        )
        var state = PersistedState.empty
        state.profile = UserProfile(
            id: userID,
            name: "Secure User",
            email: nil,
            phone: "+256700000001",
            tag: nil,
            kycStatus: nil,
            paymentPinSet: nil,
            mfaEnabled: nil,
            profileSetupRequired: false
        )
        try await store.replace(state)
        return store
    }

    private func unenrolledStatus() -> MessagingKeyStatusDTO {
        MessagingKeyStatusDTO(
            enrolled: false,
            enrollmentEpoch: 1,
            deviceId: "20000000-0000-0000-0000-000000000001",
            signalDeviceId: nil,
            protocolVersion: nil,
            registrationId: nil,
            identityKeySha256: nil,
            signedPrekeyId: nil,
            signedPrekeySha256: nil,
            pqLastResortPrekeyId: nil,
            pqLastResortPrekeySha256: nil,
            bundleVersion: nil,
            availableOneTimePrekeys: nil,
            availableEcOneTimePrekeys: nil,
            availablePqOneTimePrekeys: nil,
            replenishAt: 20,
            needsReplenishment: nil,
            publishedAt: nil,
            rotatedAt: nil,
            transparency: nil
        )
    }

    private func recoverableEnrolledStatus() -> MessagingKeyStatusDTO {
        MessagingKeyStatusDTO(
            enrolled: true,
            enrollmentEpoch: 4,
            deviceId: "20000000-0000-0000-0000-000000000002",
            signalDeviceId: 2,
            protocolVersion: SecureMessagingWire.protocolVersion,
            registrationId: 42,
            identityKeySha256: String(repeating: "a", count: 64),
            signedPrekeyId: 5,
            signedPrekeySha256: String(repeating: "b", count: 64),
            pqLastResortPrekeyId: 6,
            pqLastResortPrekeySha256: String(repeating: "c", count: 64),
            bundleVersion: 7,
            availableOneTimePrekeys: nil,
            availableEcOneTimePrekeys: nil,
            availablePqOneTimePrekeys: nil,
            replenishAt: nil,
            needsReplenishment: nil,
            publishedAt: nil,
            rotatedAt: nil,
            transparency: nil
        )
    }

    private func enrolledStatus(
        bundle: SecureMessagingLocalPublicBundle
    ) -> MessagingKeyStatusDTO {
        MessagingKeyStatusDTO(
            enrolled: true,
            enrollmentEpoch: 1,
            deviceId: "20000000-0000-0000-0000-000000000001",
            signalDeviceId: 1,
            protocolVersion: SecureMessagingWire.protocolVersion,
            registrationId: Int(bundle.registrationID),
            identityKeySha256: SecureMessagingValidation.sha256Hex(bundle.identityKey),
            signedPrekeyId: Int(bundle.signedPreKey.id),
            signedPrekeySha256: SecureMessagingValidation.sha256Hex(
                bundle.signedPreKey.publicKey
            ),
            pqLastResortPrekeyId: Int(bundle.pqLastResortPreKey.id),
            pqLastResortPrekeySha256: SecureMessagingValidation.sha256Hex(
                bundle.pqLastResortPreKey.publicKey
            ),
            bundleVersion: 1,
            availableOneTimePrekeys: bundle.oneTimePreKeys.count,
            availableEcOneTimePrekeys: bundle.oneTimePreKeys.count,
            availablePqOneTimePrekeys: bundle.pqPreKeys.count,
            replenishAt: 20,
            needsReplenishment: false,
            publishedAt: "2026-08-18T15:00:00Z",
            rotatedAt: nil,
            transparency: nil
        )
    }
}

private enum MessagingRaceResponse {
    case success
    case staleRoster
}

private struct MessagingRaceFixture {
    let userID: String
    let store: SecureLocalStore
    let coordinator: SecureMessagingExchangeCoordinator
    let transport: SuspendedMessagingExchangeTransport
    let command: OfflineCommand
    let message: LocalMessage
}

private actor SuspendedMessagingExchangeTransport: SecureMessagingExchangeTransport {
    enum Scenario: Sendable {
        case conversation(MessagingConversationDTO)
        case conversationFailure(conversationID: String)
        case createConversation(MessagingConversationDTO)
        case sendSuccess(EncryptedMessageDTO)
        case sendStaleRoster(conversationID: String)
        case readReceipt(MessagingReadReceiptDTO)
    }

    enum Failure: Error {
        case unexpectedNetworkCall
        case expectedRequestDidNotStart
    }

    private let scenario: Scenario
    private var requestStarted = false
    private var requestReleased = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var unexpectedCalls = 0
    private var requestedReadMessageIDs: [String] = []
    private var requestedDirectMemberIDs: [[String]] = []

    init(scenario: Scenario) {
        self.scenario = scenario
    }

    func waitUntilRequestStarted() async throws {
        for _ in 0..<500 {
            if requestStarted { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw Failure.expectedRequestDidNotStart
    }

    func releaseRequest() {
        requestReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func unexpectedNetworkCallCount() -> Int { unexpectedCalls }
    func readRequestMessageIDs() -> [String] { requestedReadMessageIDs }
    func createdMemberIDs() -> [[String]] { requestedDirectMemberIDs }

    private func suspendExpectedRequest() async {
        requestStarted = true
        if requestReleased { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    private func reject<T>() throws -> T {
        unexpectedCalls += 1
        throw Failure.unexpectedNetworkCall
    }

    func messagingConversation(id: String) async throws -> MessagingConversationDTO {
        switch scenario {
        case .conversation(let conversation):
            guard id == conversation.id else { return try reject() }
            await suspendExpectedRequest()
            return conversation
        case .conversationFailure(let expectedConversationID):
            guard id == expectedConversationID else { return try reject() }
            await suspendExpectedRequest()
            throw APIErrorPayload(
                code: "MESSAGING_TEMPORARILY_UNAVAILABLE",
                message: "Please retry.",
                httpStatus: 503
            )
        case .createConversation, .sendSuccess, .sendStaleRoster, .readReceipt:
            return try reject()
        }
    }

    func sendEncryptedMessage(
        conversationId: String,
        request: SendEncryptedMessageRequest
    ) async throws -> EncryptedMessageDTO {
        switch scenario {
        case .sendSuccess(let response):
            guard conversationId == response.conversationId else { return try reject() }
            await suspendExpectedRequest()
            return response
        case .sendStaleRoster(let expectedConversationID):
            guard conversationId == expectedConversationID else { return try reject() }
            await suspendExpectedRequest()
            throw APIErrorPayload(
                code: "MESSAGING_ROSTER_CHANGED",
                message: "The roster changed.",
                httpStatus: 409
            )
        case .conversation, .conversationFailure, .createConversation, .readReceipt:
            return try reject()
        }
    }

    func messagingKeyStatus() async throws -> MessagingKeyStatusDTO { try reject() }

    func publishMessagingKeyBundle(
        _ request: PublishMessagingKeyBundleRequest
    ) async throws -> MessagingKeyStatusDTO { try reject() }

    func resetMessagingEnrollment(
        _ request: ResetMessagingEnrollmentRequest
    ) async throws -> ResetMessagingEnrollmentDTO { try reject() }

    func messagingConversations() async throws -> MessagingConversationListDTO { try reject() }

    func createDirectMessagingConversation(
        _ request: CreateDirectMessagingConversationRequest
    ) async throws -> MessagingConversationDTO {
        guard case .createConversation(let response) = scenario else {
            return try reject()
        }
        requestedDirectMemberIDs.append(request.memberIds)
        return response
    }

    func messagingDeviceRoster(
        conversationId: String
    ) async throws -> MessagingDeviceRosterDTO { try reject() }

    func historicalMessagingDeviceRoster(
        conversationId: String,
        rosterRevision: String
    ) async throws -> MessagingDeviceRosterDTO { try reject() }

    func consumeMessagingKeyBundles(
        conversationId: String,
        request: ConsumeMessagingKeyBundlesRequest
    ) async throws -> ConsumedMessagingKeyBundlesDTO { try reject() }

    func uploadMessagingAttachment(
        mediaType: String,
        ciphertext: Data
    ) async throws -> MessagingAttachmentUploadDTO { try reject() }

    func downloadMessagingAttachment(
        storageKey: String,
        expectedByteSize: Int64
    ) async throws -> Data { try reject() }

    func syncEncryptedMessages(
        cursor: String?,
        limit: Int
    ) async throws -> MessagingSyncDTO { try reject() }

    func acknowledgeMessageDelivery(
        _ request: AcknowledgeMessageDeliveryRequest
    ) async throws -> MessageDeliveryAcknowledgementDTO { try reject() }

    func markMessagingConversationRead(
        conversationId: String,
        request: MarkMessagingConversationReadRequest
    ) async throws -> MessagingReadReceiptDTO {
        guard case .readReceipt(let response) = scenario,
              response.conversationId == conversationId,
              !request.messageId.isEmpty
        else { return try reject() }
        requestedReadMessageIDs.append(request.messageId)
        await suspendExpectedRequest()
        return response
    }
}

private struct DetachedEchoFixture {
    let userID: String
    let conversationID: String
    let nextCursor: String
    let store: SecureLocalStore
    let coordinator: SecureMessagingExchangeCoordinator
}

private actor DetachedEchoTransport: SecureMessagingExchangeTransport {
    enum Failure: Error { case unexpectedNetworkCall }

    let status: MessagingKeyStatusDTO
    let conversation: MessagingConversationDTO
    let response: MessagingSyncDTO

    init(
        status: MessagingKeyStatusDTO,
        conversation: MessagingConversationDTO,
        response: MessagingSyncDTO
    ) {
        self.status = status
        self.conversation = conversation
        self.response = response
    }

    func messagingKeyStatus() async throws -> MessagingKeyStatusDTO { status }

    func messagingConversation(id: String) async throws -> MessagingConversationDTO {
        guard id == conversation.id else { throw Failure.unexpectedNetworkCall }
        return conversation
    }

    func syncEncryptedMessages(
        cursor: String?,
        limit: Int
    ) async throws -> MessagingSyncDTO {
        guard cursor == nil, limit == SecureMessagingWire.maximumSyncPage else {
            throw Failure.unexpectedNetworkCall
        }
        return response
    }

    private func reject<T>() throws -> T { throw Failure.unexpectedNetworkCall }

    func publishMessagingKeyBundle(
        _ request: PublishMessagingKeyBundleRequest
    ) async throws -> MessagingKeyStatusDTO { try reject() }

    func resetMessagingEnrollment(
        _ request: ResetMessagingEnrollmentRequest
    ) async throws -> ResetMessagingEnrollmentDTO { try reject() }

    func messagingConversations() async throws -> MessagingConversationListDTO { try reject() }

    func createDirectMessagingConversation(
        _ request: CreateDirectMessagingConversationRequest
    ) async throws -> MessagingConversationDTO { try reject() }

    func messagingDeviceRoster(
        conversationId: String
    ) async throws -> MessagingDeviceRosterDTO { try reject() }

    func historicalMessagingDeviceRoster(
        conversationId: String,
        rosterRevision: String
    ) async throws -> MessagingDeviceRosterDTO { try reject() }

    func consumeMessagingKeyBundles(
        conversationId: String,
        request: ConsumeMessagingKeyBundlesRequest
    ) async throws -> ConsumedMessagingKeyBundlesDTO { try reject() }

    func sendEncryptedMessage(
        conversationId: String,
        request: SendEncryptedMessageRequest
    ) async throws -> EncryptedMessageDTO { try reject() }

    func uploadMessagingAttachment(
        mediaType: String,
        ciphertext: Data
    ) async throws -> MessagingAttachmentUploadDTO { try reject() }

    func downloadMessagingAttachment(
        storageKey: String,
        expectedByteSize: Int64
    ) async throws -> Data { try reject() }

    func acknowledgeMessageDelivery(
        _ request: AcknowledgeMessageDeliveryRequest
    ) async throws -> MessageDeliveryAcknowledgementDTO { try reject() }

    func markMessagingConversationRead(
        conversationId: String,
        request: MarkMessagingConversationReadRequest
    ) async throws -> MessagingReadReceiptDTO { try reject() }
}

private enum InjectedBlobCopyFailure: Error {
    case failed
}

private actor BlobRemovalRecorder {
    private var recordedKeys: [String] = []

    func record(_ key: String) {
        recordedKeys.append(key)
    }

    func keys() -> [String] {
        recordedKeys
    }
}

private actor DeferredImageCheckpointTransport: SecureMessagingExchangeTransport {
    enum Failure: Error { case unexpectedNetworkCall }

    let status: MessagingKeyStatusDTO
    let conversation: MessagingConversationDTO
    private var uploads = 0

    init(status: MessagingKeyStatusDTO, conversation: MessagingConversationDTO) {
        self.status = status
        self.conversation = conversation
    }

    func uploadCount() -> Int { uploads }

    func messagingKeyStatus() async throws -> MessagingKeyStatusDTO { status }

    func messagingConversation(id: String) async throws -> MessagingConversationDTO {
        guard id == conversation.id else { throw Failure.unexpectedNetworkCall }
        return conversation
    }

    func uploadMessagingAttachment(
        mediaType: String,
        ciphertext: Data
    ) async throws -> MessagingAttachmentUploadDTO {
        guard mediaType == "image/jpeg", !ciphertext.isEmpty else {
            throw Failure.unexpectedNetworkCall
        }
        uploads += 1
        return MessagingAttachmentUploadDTO(
            storageKey: "90000000-0000-4000-8000-000000000017",
            byteSize: Int64(ciphertext.count),
            ciphertextSha256: SecureMessagingValidation.sha256Hex(ciphertext)
        )
    }

    func messagingDeviceRoster(
        conversationId: String
    ) async throws -> MessagingDeviceRosterDTO {
        guard conversationId == conversation.id else { throw Failure.unexpectedNetworkCall }
        throw APIErrorPayload(
            code: "MESSAGING_TEMPORARILY_UNAVAILABLE",
            message: "Please retry.",
            httpStatus: 503
        )
    }

    private func reject<T>() throws -> T { throw Failure.unexpectedNetworkCall }

    func publishMessagingKeyBundle(
        _ request: PublishMessagingKeyBundleRequest
    ) async throws -> MessagingKeyStatusDTO { try reject() }

    func resetMessagingEnrollment(
        _ request: ResetMessagingEnrollmentRequest
    ) async throws -> ResetMessagingEnrollmentDTO { try reject() }

    func messagingConversations() async throws -> MessagingConversationListDTO { try reject() }

    func createDirectMessagingConversation(
        _ request: CreateDirectMessagingConversationRequest
    ) async throws -> MessagingConversationDTO { try reject() }

    func historicalMessagingDeviceRoster(
        conversationId: String,
        rosterRevision: String
    ) async throws -> MessagingDeviceRosterDTO { try reject() }

    func consumeMessagingKeyBundles(
        conversationId: String,
        request: ConsumeMessagingKeyBundlesRequest
    ) async throws -> ConsumedMessagingKeyBundlesDTO { try reject() }

    func sendEncryptedMessage(
        conversationId: String,
        request: SendEncryptedMessageRequest
    ) async throws -> EncryptedMessageDTO { try reject() }

    func downloadMessagingAttachment(
        storageKey: String,
        expectedByteSize: Int64
    ) async throws -> Data { try reject() }

    func syncEncryptedMessages(
        cursor: String?,
        limit: Int
    ) async throws -> MessagingSyncDTO { try reject() }

    func acknowledgeMessageDelivery(
        _ request: AcknowledgeMessageDeliveryRequest
    ) async throws -> MessageDeliveryAcknowledgementDTO { try reject() }

    func markMessagingConversationRead(
        conversationId: String,
        request: MarkMessagingConversationReadRequest
    ) async throws -> MessagingReadReceiptDTO { try reject() }
}

private actor OfflineExchangeTransport: SecureMessagingExchangeTransport {
    enum Failure: Error { case unexpectedNetworkCall }

    private var calls = 0

    func networkCallCount() -> Int { calls }

    private func reject<T>() throws -> T {
        calls += 1
        throw Failure.unexpectedNetworkCall
    }

    func messagingKeyStatus() async throws -> MessagingKeyStatusDTO { try reject() }

    func publishMessagingKeyBundle(
        _ request: PublishMessagingKeyBundleRequest
    ) async throws -> MessagingKeyStatusDTO { try reject() }

    func resetMessagingEnrollment(
        _ request: ResetMessagingEnrollmentRequest
    ) async throws -> ResetMessagingEnrollmentDTO { try reject() }

    func messagingConversations() async throws -> MessagingConversationListDTO { try reject() }

    func messagingConversation(id: String) async throws -> MessagingConversationDTO { try reject() }

    func createDirectMessagingConversation(
        _ request: CreateDirectMessagingConversationRequest
    ) async throws -> MessagingConversationDTO { try reject() }

    func messagingDeviceRoster(
        conversationId: String
    ) async throws -> MessagingDeviceRosterDTO { try reject() }

    func historicalMessagingDeviceRoster(
        conversationId: String,
        rosterRevision: String
    ) async throws -> MessagingDeviceRosterDTO { try reject() }

    func consumeMessagingKeyBundles(
        conversationId: String,
        request: ConsumeMessagingKeyBundlesRequest
    ) async throws -> ConsumedMessagingKeyBundlesDTO { try reject() }

    func sendEncryptedMessage(
        conversationId: String,
        request: SendEncryptedMessageRequest
    ) async throws -> EncryptedMessageDTO { try reject() }

    func uploadMessagingAttachment(
        mediaType: String,
        ciphertext: Data
    ) async throws -> MessagingAttachmentUploadDTO { try reject() }

    func downloadMessagingAttachment(
        storageKey: String,
        expectedByteSize: Int64
    ) async throws -> Data { try reject() }

    func syncEncryptedMessages(
        cursor: String?,
        limit: Int
    ) async throws -> MessagingSyncDTO { try reject() }

    func acknowledgeMessageDelivery(
        _ request: AcknowledgeMessageDeliveryRequest
    ) async throws -> MessageDeliveryAcknowledgementDTO { try reject() }

    func markMessagingConversationRead(
        conversationId: String,
        request: MarkMessagingConversationReadRequest
    ) async throws -> MessagingReadReceiptDTO { try reject() }
}

private actor ActivationTransportStub: SecureMessagingActivationTransport {
    enum Failure: Error { case publication }

    enum Publication: Sendable {
        case success(MessagingKeyStatusDTO)
        case failure
    }

    enum Reset: Sendable {
        case success(ResetMessagingEnrollmentDTO)
        case failure
    }

    private var statuses: [MessagingKeyStatusDTO]
    private var publications: [Publication]
    private var requests: [PublishMessagingKeyBundleRequest] = []
    private var resets: [Reset]
    private var recordedResetRequests: [ResetMessagingEnrollmentRequest] = []

    init(
        statuses: [MessagingKeyStatusDTO],
        publications: [Publication],
        resets: [Reset] = []
    ) {
        self.statuses = statuses
        self.publications = publications
        self.resets = resets
    }

    func messagingKeyStatus() async throws -> MessagingKeyStatusDTO {
        guard !statuses.isEmpty else { throw Failure.publication }
        return statuses.removeFirst()
    }

    func publishMessagingKeyBundle(
        _ request: PublishMessagingKeyBundleRequest
    ) async throws -> MessagingKeyStatusDTO {
        requests.append(request)
        guard !publications.isEmpty else { throw Failure.publication }
        switch publications.removeFirst() {
        case .success(let status): return status
        case .failure: throw Failure.publication
        }
    }

    func resetMessagingEnrollment(
        _ request: ResetMessagingEnrollmentRequest
    ) async throws -> ResetMessagingEnrollmentDTO {
        recordedResetRequests.append(request)
        guard !resets.isEmpty else { throw Failure.publication }
        switch resets.removeFirst() {
        case .success(let result): return result
        case .failure: throw Failure.publication
        }
    }

    func publishedRequests() -> [PublishMessagingKeyBundleRequest] { requests }
    func resetRequests() -> [ResetMessagingEnrollmentRequest] { recordedResetRequests }
}
